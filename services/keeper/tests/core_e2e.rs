//! Keeper acceptance 5 on BE-chain's `DeployCoreLocal` (anvil; `make keeper-core-e2e`). Anvil has no
//! Stylus, so the stack's engine is the Solidity stand-in with an injected safe LTV (the scenario A
//! weekend value, G-10) and the pool stand-in quotes a fixed premium ($35.95). The keeper computes the
//! Bell natively, so every check compares it with the contracts' own answer:
//!
//! * **J2** (Thu, T−26 h before Friday's WEEKEND close): one `bell_headsup` for the borrower above the
//!   safe LTV; at Friday T−2 h its cures and premium equal `CredenceMarket.bellStatus` at the job's block.
//! * **J3** dry-run (Fri, after `bellAt`): the planned batch and outcome; `enforceBell` then emits
//!   `BellEnforced` with exactly the predicted outcome.
//! * **J4** dry-run (price falls in REGULAR): planned `flagForAuction` iff `healthFactor < 1`.
//! * **J8**: `claimFees` and `SeniorVault.processQueue` land (`FeesClaimed`, `RedeemProcessed`).
//! * **Allowlist**: a queued request becomes `ComplianceRegistry.isAllowed`.
//!
//! The positions a real deployment reads from the indexer come from a scratch `position` table here
//! (the indexer itself is covered by `make indexer-e2e`).

use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};

use alloy::{
    network::EthereumWallet,
    primitives::{Address, B256, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    signers::{local::PrivateKeySigner, SignerSync},
    sol,
    sol_types::{SolCall, SolEvent},
};
use credence_keeper::{
    clock::ManualClock,
    config::{load_calendars, tracked},
    core::abi::{ComplianceRegistry, ICredenceMarket, ISeniorVault},
    core_jobs::{from_book, CoreJobs},
    metrics::Metrics,
    rpc::Rpc,
    tasks::Keeper,
    tx::TxManager,
};
use sqlx::{PgPool, Row};

const DEPLOYER: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const PRIYA: &str = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"; // anvil 4
const COMMITTEE: [&str; 3] = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];
/// Thu 2026-10-08 13:30 ET (17:30Z), Thu 18:05Z (T−26 h window of Friday's close), Fri 18:05Z (T−2 h),
/// Fri 19:46Z (after bellAt 19:45Z), Fri close 20:00Z.
const THU_1730: u64 = 1_791_479_400;
const THU_1805: u64 = 1_791_482_700;
const FRI_OPEN: u64 = 1_791_552_600; // Fri 09:30 ET
const FRI_1805: u64 = 1_791_569_100;
const FRI_1946: u64 = 1_791_575_160;
const SAFE_LTV_G10: u128 = 712_580_117_506_000_000;
const PREMIUM: u64 = 35_950_000; // $35.95

sol! {
    #[sol(rpc)]
    interface IMintable {
        function mint(address to, uint256 amount) external;
        function approve(address spender, uint256 amount) external returns (bool);
        function balanceOf(address a) external view returns (uint256);
    }
    #[sol(rpc)]
    interface IMockEngine {
        function setSafeLtv(bytes32 assetId, uint8 closureType, uint256 v) external;
        function setQuote(uint256 premium, uint256 el, uint256 es) external;
        function setJointColumn(bytes32 assetId, uint256[] calldata packedZ) external;
        struct MockRiskParams {
            uint64 alpha; uint64 kappa; uint64 theta; uint64 costOfCap; uint64 eta; uint64 beta; uint64 uMax;
            uint64 minPremium; uint32 kStress;
        }
        function params() external view returns (MockRiskParams memory);
    }
}

fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

fn wallet(key: &str) -> EthereumWallet {
    EthereumWallet::from(key.parse::<PrivateKeySigner>().unwrap())
}

async fn provider(rpc: &str, key: &str) -> DynProvider {
    ProviderBuilder::new()
        .with_simple_nonce_management()
        .wallet(wallet(key))
        .connect_http(rpc.parse().unwrap())
        .erased()
}

async fn set_time(p: &DynProvider, t: u64) {
    let _: serde_json::Value = p
        .raw_request("evm_setNextBlockTimestamp".into(), (t,))
        .await
        .unwrap();
    let _: serde_json::Value = p.raw_request("evm_mine".into(), ()).await.unwrap();
}

struct Anvil(std::process::Child);
impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.0.kill();
    }
}

/// A LIVE report at `price` on one feed, signed by 2 of the 3 committee keys.
async fn push_price(
    p: &DynProvider,
    feed: Address,
    asset: B256,
    at: u64,
    price: u128,
    session_open: u64,
) {
    push_report(
        p,
        feed,
        asset,
        credence_relayer::report::Kind::Live,
        at,
        price,
        session_open,
    )
    .await
}

/// One report of `kind` on one feed, signed by 2 of the 3 committee keys.
async fn push_report(
    p: &DynProvider,
    feed: Address,
    asset: B256,
    kind: credence_relayer::report::Kind,
    at: u64,
    price: u128,
    session_open: u64,
) {
    use credence_relayer::report::{
        digest, domain, report, sorted_signatures, ICredencePriceFeed, MarketStatus,
    };
    let f = ICredencePriceFeed::new(feed, p);
    let seq = f.latestSeq(asset).call().await.unwrap() + 1;
    let r = vec![report(
        asset,
        kind,
        price,
        at,
        session_open / 86_400,
        MarketStatus::Regular,
        seq,
    )];
    let h = digest(&domain(31_337, feed), &r);
    let sigs = sorted_signatures(
        COMMITTEE[..2]
            .iter()
            .map(|k| k.parse::<PrivateKeySigner>().unwrap())
            .map(|s| (s.address(), s.sign_hash_sync(&h).unwrap()))
            .collect(),
    );
    let rc = f
        .submit(r, sigs.into_iter().map(|(_, b)| b).collect())
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(rc.status(), "price submit reverted");
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make keeper-core-e2e)"]
async fn core_jobs_match_the_contracts() {
    credence_common::telemetry::init("keeper-core-e2e");
    std::env::set_current_dir(repo()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let _anvil = Anvil(
        std::process::Command::new("anvil")
            .args([
                "--port",
                &port.to_string(),
                "--timestamp",
                &THU_1730.to_string(),
                "--silent",
                "--code-size-limit",
                "200000",
                "--gas-limit",
                "100000000",
            ])
            .stdout(Stdio::null())
            .spawn()
            .expect("anvil"),
    );
    let rpc = format!("http://127.0.0.1:{port}");
    let d = provider(&rpc, DEPLOYER).await;
    for _ in 0..100 {
        if d.get_chain_id().await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // ── BE-chain's DeployCoreLocal ──
    let out = repo().join(format!(
        "deployments/31337.core-e2e-{}.local.json",
        std::process::id()
    ));
    let committee = COMMITTEE
        .iter()
        .map(|k| k.parse::<PrivateKeySigner>().unwrap().address().to_string())
        .collect::<Vec<_>>()
        .join(",");
    let status = std::process::Command::new("forge")
        .current_dir(repo().join("contracts"))
        .args([
            "script",
            "script/DeployCoreLocal.s.sol:DeployCoreLocal",
            "--rpc-url",
            &rpc,
            "--broadcast",
            "--slow",
            "-q",
        ])
        .env("PRIVATE_KEY", DEPLOYER)
        .env("RELAYER_A_SIGNERS", &committee)
        .env("RELAYER_B_SIGNERS", &committee)
        .env(
            "XNYS_CALENDAR",
            repo().join("calibration/out/calendars/XNYS-20261001-20271031.json"),
        )
        .env(
            "USBANK_CALENDAR",
            repo().join("calibration/out/calendars/USBANK-20261001-20271031.json"),
        )
        .env("COVER_PREMIUM", PREMIUM.to_string())
        .env("OUT", &out)
        .stdout(Stdio::null())
        .status()
        .expect("forge");
    assert!(
        status.success(),
        "DeployCoreLocal failed (make contracts-build)"
    );
    let book: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
    let _ = std::fs::remove_file(&out);
    let a = |ptr: &str| -> Address {
        book.pointer(ptr)
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| panic!("{ptr}"))
            .parse()
            .unwrap()
    };
    let (market, vault, engine, pool, registry) = (
        a("/equity/market"),
        a("/equity/vault"),
        a("/shared/riskEngine"),
        a("/equity/pool"),
        a("/shared/registry"),
    );
    let (feed_a, feed_b, clock) = (a("/shared/feedA"), a("/shared/feedB"), a("/shared/clock"));
    let (tnvda, usdc) = (a("/tokens/tNVDA"), a("/tokens/usdc"));
    let nvda: B256 = book
        .pointer("/assetIds/NVDA")
        .unwrap()
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let id: B256 = book
        .pointer("/equity/markets/NVDA")
        .unwrap()
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let (markets, vaults) = from_book(&book);
    assert!(markets.iter().any(|m| m.id == id) && vaults.len() == 2);

    // ── scenario A inputs: weekend safe LTV (G-10) injected, NVDA at $180, Priya at 500 tNVDA ──
    let thu_open = THU_1730 - 4 * 3600; // 13:30Z
    IMockEngine::new(engine, &d)
        .setSafeLtv(nvda, 2, U256::from(SAFE_LTV_G10))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    // the real UnderwriterPool (S3+) prices cover with the engine's quoteCover and checks capacity with its
    // joint stress column: inject the premium, and an all-zero column (no stress loss) for NVDA
    let _ = pool;
    let me = IMockEngine::new(engine, &d);
    let k_stress = me.params().call().await.unwrap().kStress as usize;
    // capacity sums the uncovered exposure of every listed equity asset, so each needs a column
    for (t, v) in book["assetIds"].as_object().unwrap() {
        if t == "TBILL" {
            continue;
        }
        me.setJointColumn(
            v.as_str().unwrap().parse::<B256>().unwrap(),
            vec![U256::ZERO; k_stress.div_ceil(16)],
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    }
    IMockEngine::new(engine, &d)
        .setQuote(
            U256::from(PREMIUM),
            U256::from(PREMIUM / 2),
            U256::from(PREMIUM),
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    // at the chain's own time: the deploy can take a minute, and a price older than the 60 s
    // REGULAR limit pauses borrowing (the feeds cannot be cross-checked)
    let chain_now = d
        .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    for f in [feed_a, feed_b] {
        push_price(
            &d,
            f,
            nvda,
            chain_now,
            180_000_000_000_000_000_000,
            thu_open,
        )
        .await;
    }
    sol! { #[sol(rpc)] interface IPoke { function poke(bytes32 assetId) external returns (uint8); } }
    IPoke::new(clock, &d)
        .poke(nvda)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let priya: PrivateKeySigner = PRIYA.parse().unwrap();
    let pw = provider(&rpc, PRIYA).await;
    IMintable::new(tnvda, &d)
        .mint(
            priya.address(),
            U256::from(500u64) * U256::from(10u64).pow(U256::from(18u64)),
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    IMintable::new(tnvda, &pw)
        .approve(market, U256::MAX)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let m = ICredenceMarket::new(market, &pw);
    m.addCollateral(
        id,
        priya.address(),
        U256::from(500u64) * U256::from(10u64).pow(U256::from(18u64)),
    )
    .send()
    .await
    .unwrap()
    .get_receipt()
    .await
    .unwrap();
    let borrow = U256::from(67_000_000_000u64); // $67,000 at $90,000 of collateral: LTV 74.4% > 71.26%
    let r = m
        .borrow(id, borrow, priya.address())
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(r.status(), "borrow reverted");

    // ── Postgres: scratch DB with the migrations, and the indexer's `position` for this market ──
    let admin = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
    let url = credence_common::db::scratch_database(&admin, "credence_keeper_core_e2e")
        .await
        .unwrap();
    let pool_db: PgPool = credence_common::db::connect_chain(&url, 4, 31_337)
        .await
        .unwrap();
    sqlx::raw_sql("create schema if not exists ix; create table if not exists ix.position (market_id text, owner text, borrow_shares numeric)").execute(&pool_db).await.unwrap();
    sqlx::query("insert into ix.position values ($1, $2, 1)")
        .bind(id.to_string())
        .bind(format!("{:#x}", priya.address()))
        .execute(&pool_db)
        .await
        .unwrap();

    // ── the keeper (leader connection = one pooled connection) ──
    let cals = load_calendars().unwrap();
    let assets = tracked(&["NVDA:XNAS".to_string()], &cals).unwrap();
    let metrics = Metrics::detached();
    let rpc_c = Arc::new(Rpc::connect(std::slice::from_ref(&rpc), None).unwrap());
    let signer: PrivateKeySigner = DEPLOYER.parse().unwrap();
    let tx = TxManager::new(
        rpc_c.clone(),
        EthereumWallet::from(signer.clone()),
        signer.address(),
        31_337,
        metrics.clone(),
    );
    let now = ManualClock::new(THU_1805);
    let mut k = Keeper::new(
        "core-e2e".into(),
        rpc_c,
        tx,
        clock,
        assets,
        Arc::new(now.clone()),
        metrics,
        900,
    );
    let mut core = CoreJobs::new(
        markets.into_iter().filter(|m| m.id == id).collect(),
        vaults,
        "ix".into(),
    );
    core.registry = Some(registry);
    k.core = Some(Arc::new(core));
    let mut conn = pool_db.acquire().await.unwrap();

    // ── J2 on Thursday: T−26 h before Friday's WEEKEND close (the overnight is not binding) ──
    set_time(&d, THU_1805).await;
    // a fresh price, or the clock halts the asset as stale (REGULAR staleness limit)
    for f in [feed_a, feed_b] {
        push_price(&d, f, nvda, THU_1805, 180_000_000_000_000_000_000, thu_open).await;
    }
    k.tx.reset_nonce().await;
    k.tick(&mut conn).await.unwrap();
    let jobs = sqlx::query("select dedupe_key, payload from app.notification_job order by id")
        .fetch_all(&pool_db)
        .await
        .unwrap();
    assert_eq!(jobs.len(), 1, "one heads-up (Friday T-26h)");
    let p: serde_json::Value = jobs[0].get("payload");
    assert_eq!(
        (
            p["stage"].as_str(),
            p["closureType"].as_u64(),
            p["safeLtv"].as_str()
        ),
        (
            Some("T-26h"),
            Some(2),
            Some(SAFE_LTV_G10.to_string().as_str())
        )
    );
    assert_eq!(p["premium"].as_str(), Some(PREMIUM.to_string().as_str()));
    assert_eq!(p["default"]["kind"], "autoCover");
    println!("J2 T-26h payload: {p}");

    // ── Friday's reopen after Thursday night (the S3 reopen driver's job, emulated): OPEN print at
    //    09:30 ET, then the auction house marks the reopen complete so the clock returns to REGULAR ──
    set_time(&d, FRI_OPEN + 2).await;
    for f in [feed_a, feed_b] {
        push_report(
            &d,
            f,
            nvda,
            credence_relayer::report::Kind::Open,
            FRI_OPEN + 1,
            180_000_000_000_000_000_000,
            FRI_OPEN,
        )
        .await;
        push_price(
            &d,
            f,
            nvda,
            FRI_OPEN + 2,
            180_000_000_000_000_000_000,
            FRI_OPEN,
        )
        .await;
    }
    IPoke::new(clock, &d)
        .poke(nvda)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let auction_house = a("/equity/auctionHouse");
    let _: serde_json::Value = d
        .raw_request("anvil_impersonateAccount".into(), (auction_house,))
        .await
        .unwrap();
    let _: serde_json::Value = d
        .raw_request(
            "anvil_setBalance".into(),
            (auction_house, U256::from(10u64).pow(U256::from(18u64))),
        )
        .await
        .unwrap();
    let plain = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let closure_id = credence_keeper::core::abi::IAssetClockV1::new(clock, &plain)
        .closureInfo(nvda)
        .call()
        .await
        .unwrap()
        .closureId;
    let tx = alloy::rpc::types::TransactionRequest::default()
        .from(auction_house)
        .to(clock)
        .input(
            credence_keeper::core::abi::IAssetClockV1::markReopenCompleteCall {
                assetId: nvda,
                closureId: closure_id,
            }
            .abi_encode()
            .into(),
        );
    let rc = plain
        .send_transaction(tx)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(rc.status(), "markReopenComplete reverted");
    assert_eq!(
        credence_keeper::core::abi::IAssetClockV1::new(clock, &plain)
            .state(nvda)
            .call()
            .await
            .unwrap(),
        0,
        "REGULAR after the reopen"
    );

    // ── J2 on Friday T−2 h: equal to the market's own bellStatus at the job's block ──
    set_time(&d, FRI_1805).await;
    for f in [feed_a, feed_b] {
        push_price(
            &d,
            f,
            nvda,
            FRI_1805 - 5,
            180_000_000_000_000_000_000,
            FRI_1805 - 16_200,
        )
        .await;
    }
    now.set(FRI_1805 + 5);
    set_time(&d, FRI_1805 + 5).await;
    k.tx.reset_nonce().await;
    k.tick(&mut conn).await.unwrap();
    let row =
        sqlx::query("select payload from app.notification_job where dedupe_key like '%:T-2h' ")
            .fetch_one(&pool_db)
            .await
            .unwrap();
    let p: serde_json::Value = row.get("payload");
    let job = sqlx::query(
        // Friday's WEEKEND closure (2); since the S3 J2 fix Thursday's own overnight (closure 1) has a T-2h job too
        "select payload from ops.keeper_job where key like 'J2:%:2:T-2h' and payload ? 'block'",
    )
    .fetch_one(&pool_db)
    .await
    .unwrap();
    let block = job.get::<serde_json::Value, _>("payload")["block"]
        .as_u64()
        .unwrap();
    let onchain = ICredenceMarket::new(market, &d)
        .bellStatus(id, priya.address())
        .block(block.into())
        .call()
        .await
        .unwrap();
    assert_eq!(onchain._0, 1, "NEEDS_ACTION on-chain");
    assert_eq!(
        p["cureRepay"].as_str().unwrap(),
        onchain._1.to_string(),
        "cure repay == market.bellStatus"
    );
    assert_eq!(
        p["cureCollateral"].as_str().unwrap(),
        onchain._2.to_string(),
        "cure collateral == market.bellStatus"
    );
    assert_eq!(
        p["premium"].as_str().unwrap(),
        onchain._3.to_string(),
        "premium == market.bellStatus"
    );
    println!(
        "J2 T-2h == bellStatus @{block}: repay {} collateral {} premium {}",
        onchain._1, onchain._2, onchain._3
    );

    // ── J3 dry-run after bellAt, then the real enforceBell emits the predicted outcome ──
    now.set(FRI_1946);
    set_time(&d, FRI_1946).await;
    for f in [feed_a, feed_b] {
        push_price(
            &d,
            f,
            nvda,
            FRI_1946,
            180_000_000_000_000_000_000,
            FRI_1805 - 16_200,
        )
        .await;
    }
    k.tx.reset_nonce().await;
    k.tick(&mut conn).await.unwrap();
    let j3 = sqlx::query("select payload from ops.keeper_job where key like 'J3:%' and job = 'J3'")
        .fetch_one(&pool_db)
        .await
        .unwrap();
    let plan: serde_json::Value = j3.get("payload");
    let expected = &plan["plan"]["expected"];
    assert_eq!(expected.as_array().unwrap().len(), 1);
    let predicted = expected[0]["outcome"].as_u64().unwrap();
    let batch: Vec<Address> =
        serde_json::from_value(plan["plan"]["calls"][0]["borrowers"].clone()).unwrap();
    assert_eq!(batch, vec![priya.address()]);
    let rc = ICredenceMarket::new(market, &d)
        .enforceBell(id, batch)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let outcome = rc
        .inner
        .logs()
        .iter()
        .find_map(|l| ICredenceMarket::BellEnforced::decode_log_data(l.data()).ok())
        .expect("BellEnforced")
        .outcome;
    assert_eq!(
        outcome as u64, predicted,
        "J3 dry-run outcome == BellEnforced.outcome"
    );
    println!("J3 predicted outcome {predicted} == BellEnforced {outcome}");

    // ── J4 dry-run: the price falls in REGULAR → flag iff HF < 1 ──
    set_time(&d, FRI_1946 + 30).await;
    for f in [feed_a, feed_b] {
        push_price(
            &d,
            f,
            nvda,
            FRI_1946 + 30,
            140_000_000_000_000_000_000,
            FRI_1805 - 16_200,
        )
        .await;
    }
    now.set(FRI_1946 + 60);
    set_time(&d, FRI_1946 + 60).await;
    k.tx.reset_nonce().await;
    k.tick(&mut conn).await.unwrap();
    let hf = ICredenceMarket::new(market, &d)
        .healthFactor(id, priya.address())
        .call()
        .await
        .unwrap();
    let j4 = sqlx::query("select count(*) as n from ops.keeper_job where job = 'J4'")
        .fetch_one(&pool_db)
        .await
        .unwrap()
        .get::<i64, _>("n");
    assert_eq!(
        j4 == 1,
        hf < U256::from(1_000_000_000_000_000_000u128),
        "J4 flags iff healthFactor < 1 (hf {hf})"
    );
    println!("J4: healthFactor {hf}, planned flags {j4}");

    // ── J8: fees accrued since Thursday are claimed; a queued redeem is processed ──
    let v = ISeniorVault::new(vault, &d);
    let shares = U256::from(1_000_000u64);
    v.requestRedeem(shares, signer.address())
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert_eq!(v.queueLength().call().await.unwrap(), U256::from(1u64));
    // ── Allowlist: one queued request ──
    let newcomer = Address::with_last_byte(0x77);
    sqlx::query("insert into app.account (address) values ($1)")
        .bind(newcomer.as_slice())
        .execute(&pool_db)
        .await
        .unwrap();
    sqlx::query("insert into app.allowlist_request (address) values ($1)")
        .bind(newcomer.as_slice())
        .execute(&pool_db)
        .await
        .unwrap();
    now.set(FRI_1946 + 3_600);
    set_time(&d, FRI_1946 + 3_600).await;
    k.tx.reset_nonce().await;
    k.tick(&mut conn).await.unwrap();
    let from = rc.block_number.unwrap();
    let logs = d
        .get_logs(
            &alloy::rpc::types::Filter::new()
                .address(vec![market, vault])
                .from_block(from),
        )
        .await
        .unwrap();
    assert!(
        logs.iter()
            .any(|l| l.topic0() == Some(&ICredenceMarket::FeesClaimed::SIGNATURE_HASH)),
        "J8 claimFees"
    );
    assert!(
        logs.iter()
            .any(|l| l.topic0() == Some(&ISeniorVault::RedeemProcessed::SIGNATURE_HASH)),
        "J8 processQueue"
    );
    assert_eq!(v.queueLength().call().await.unwrap(), U256::ZERO);
    assert!(
        ComplianceRegistry::new(registry, &d)
            .isAllowed(newcomer)
            .call()
            .await
            .unwrap(),
        "allowlist tx sent"
    );
    let st: String = sqlx::query("select status from app.allowlist_request where address = $1")
        .bind(newcomer.as_slice())
        .fetch_one(&pool_db)
        .await
        .unwrap()
        .get("status");
    assert_eq!(st, "done");
    let _ = (
        usdc,
        IMintable::new(usdc, &d)
            .balanceOf(priya.address())
            .call()
            .await
            .unwrap(),
    );
}
