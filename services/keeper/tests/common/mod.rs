//! Shared harness for the keeper's anvil edge tests (make backend-edge-infra): BE-chain's `DeployCoreLocal` on a
//! scratch anvil (the real market, pool and auction house; the Solidity stand-in engine with an injected weekend
//! safe LTV, premium and a zero joint column) on the real XNYS calendar, a scratch Postgres database, and a
//! `Stack` that runs one tick of a brand-new `Keeper` at a warped chain time. Fri 2026-10-09 / Mon 2026-10-12.
#![allow(dead_code)]

pub mod fault_proxy;

use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};

use alloy::{
    network::EthereumWallet,
    primitives::{Address, B256, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    signers::{local::PrivateKeySigner, SignerSync},
    sol,
};
use credence_keeper::{
    clock::ManualClock,
    config::{load_calendars, tracked},
    core::abi::ICredenceMarket,
    core_jobs::{auction_stacks, from_book, CoreJobs},
    metrics::Metrics,
    rpc::Rpc,
    tasks::{Keeper, TickReport},
    tx::TxManager,
};
use sqlx::PgPool;

pub const DEPLOYER: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
pub const PRIYA: &str = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"; // anvil 4
pub const DEV: &str = "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"; // anvil 5
pub const COMMITTEE: [&str; 3] = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];
/// Fri 2026-10-09: open 13:30Z, Bell window 18:00Z, bellAt 19:45Z, close 20:00Z; Mon 2026-10-12 open 13:30Z.
pub const FRI_OPEN: u64 = 1_791_552_600;
pub const FRI_CLOSE: u64 = 1_791_576_000;
pub const MON_OPEN: u64 = 1_791_811_800;
pub const SAFE_LTV: u128 = 712_580_117_506_000_000;
pub const PREMIUM: u64 = 35_950_000;
pub const WAD: u128 = 1_000_000_000_000_000_000;

sol! {
    #[sol(rpc)]
    interface IMintable {
        function mint(address to, uint256 amount) external;
        function approve(address spender, uint256 amount) external returns (bool);
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
    #[sol(rpc)]
    interface IPoke { function poke(bytes32 assetId) external returns (uint8); }
    #[sol(rpc)]
    interface IClockState { function state(bytes32 assetId) external view returns (uint8); }
}

pub fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

pub async fn provider(rpc: &str, key: &str) -> DynProvider {
    ProviderBuilder::new()
        .with_simple_nonce_management()
        .wallet(EthereumWallet::from(
            key.parse::<PrivateKeySigner>().unwrap(),
        ))
        .connect_http(rpc.parse().unwrap())
        .erased()
}

/// The next block at `t`, or one second after the head if `t` is already past (a tx mined meanwhile).
pub async fn set_time(p: &DynProvider, t: u64) {
    let head = p
        .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    let _: serde_json::Value = p
        .raw_request("evm_setNextBlockTimestamp".into(), (t.max(head + 1),))
        .await
        .unwrap();
    let _: serde_json::Value = p.raw_request("evm_mine".into(), ()).await.unwrap();
}

pub struct Anvil(pub std::process::Child);
impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.0.kill();
    }
}

/// One report on one feed, signed by 2 of the 3 committee keys.
pub async fn push(
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

/// Extra keeper setup before each tick.
pub type Prep = Box<dyn Fn(&mut Keeper) + Send + Sync>;

pub struct Stack {
    pub rpc: String,
    pub d: DynProvider,
    pub book: serde_json::Value,
    pub clock: Address,
    pub feeds: [Address; 2],
    pub nvda: B256,
    pub id: B256,
    pub db: PgPool,
    pub now: ManualClock,
    pub ticks: usize,
    /// The keeper's RPC list (default: the anvil url); a test puts a fault proxy first.
    pub rpcs: Vec<String>,
    /// J3 batch size (default `BELL_BATCH`).
    pub j3_batch: Option<usize>,
    /// Extra keeper setup before each tick (wallet floor, alert webhook…).
    pub prep: Option<Prep>,
    pub _anvil: Option<Anvil>,
}

impl Stack {
    pub fn addr(&self, ptr: &str) -> Address {
        self.book
            .pointer(ptr)
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| panic!("{ptr}"))
            .parse()
            .unwrap()
    }

    /// Chain time `t`, and fresh LIVE prices while the session is open.
    pub async fn at(&self, t: u64, price: u128, session_open: u64) {
        set_time(&self.d, t).await;
        self.now.set(t + 1);
        if t >= session_open && t < session_open + 6 * 3600 + 1800 {
            for f in self.feeds {
                push(
                    &self.d,
                    f,
                    self.nvda,
                    credence_relayer::report::Kind::Live,
                    t,
                    price,
                    session_open,
                )
                .await;
            }
        }
    }

    /// One tick of a **new** keeper process: fresh `Keeper`, `TxManager` and `CoreJobs`; only Postgres is shared.
    pub async fn restart_and_tick(&mut self) -> TickReport {
        let cals = load_calendars().unwrap();
        let assets = tracked(&["NVDA:XNAS".to_string()], &cals).unwrap();
        let metrics = Metrics::detached();
        let rpc = Arc::new(Rpc::connect(&self.rpcs, None).unwrap());
        let signer: PrivateKeySigner = DEPLOYER.parse().unwrap();
        let tx = TxManager::new(
            rpc.clone(),
            EthereumWallet::from(signer.clone()),
            signer.address(),
            31_337,
            metrics.clone(),
        );
        let mut k = Keeper::new(
            format!("edge-restart-{}", self.ticks),
            rpc,
            tx,
            self.clock,
            assets,
            Arc::new(self.now.clone()),
            metrics,
            900,
        );
        let (markets, vaults) = from_book(&self.book);
        let mut core = CoreJobs::new(
            markets.into_iter().filter(|m| m.id == self.id).collect(),
            vaults,
            "ix".into(),
        );
        core.j3_live = true;
        core.j4_live = true;
        core.auction_stacks = auction_stacks(&self.book)
            .into_iter()
            .filter(|s| s.stack == "equity")
            .collect();
        core.from_block = self.book["startBlock"].as_u64().unwrap_or(0);
        if let Some(b) = self.j3_batch {
            core.j3_batch = b;
        }
        k.core = Some(Arc::new(core));
        if let Some(f) = &self.prep {
            f(&mut k);
        }
        let mut conn = self.db.acquire().await.unwrap();
        let rep = k.tick(&mut conn).await.unwrap();
        self.ticks += 1;
        rep
    }

    pub async fn state(&self) -> u8 {
        IClockState::new(self.clock, &self.d)
            .state(self.nvda)
            .call()
            .await
            .unwrap()
    }

    pub async fn keys(&self, like: &str) -> Vec<(String, String)> {
        sqlx::query_as("select key, status from ops.keeper_job where key like $1 order by key")
            .bind(like)
            .fetch_all(&self.db)
            .await
            .unwrap()
    }
}

pub async fn borrow(s: &Stack, key: &str, qty: u128, debt: u64) -> Address {
    let who: PrivateKeySigner = key.parse().unwrap();
    let w = provider(&s.rpc, key).await;
    let tnvda = s.addr("/tokens/tNVDA");
    let market = s.addr("/equity/market");
    IMintable::new(tnvda, &s.d)
        .mint(who.address(), U256::from(qty))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    IMintable::new(tnvda, &w)
        .approve(market, U256::MAX)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let m = ICredenceMarket::new(market, &w);
    m.addCollateral(s.id, who.address(), U256::from(qty))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let r = m
        .borrow(s.id, U256::from(debt), who.address())
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(r.status(), "borrow reverted");
    sqlx::query("insert into ix.position values ($1, $2, 1)")
        .bind(s.id.to_string())
        .bind(format!("{:#x}", who.address()))
        .execute(&s.db)
        .await
        .unwrap();
    who.address()
}

/// Anvil + DeployCoreLocal + the stand-in engine + a scratch database named `db_name`.
pub async fn deploy(db_name: &str) -> Stack {
    std::env::set_current_dir(repo()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let start = FRI_OPEN + 60;
    let anvil = Anvil(
        std::process::Command::new("anvil")
            .args([
                "--port",
                &port.to_string(),
                "--timestamp",
                &start.to_string(),
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

    // ── DeployCoreLocal on the real calendars ──
    let out = repo().join(format!(
        "deployments/31337.edge-restart-{}.local.json",
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
    let b = |ptr: &str| -> Address {
        book.pointer(ptr)
            .unwrap()
            .as_str()
            .unwrap()
            .parse()
            .unwrap()
    };
    let h = |ptr: &str| -> B256 {
        book.pointer(ptr)
            .unwrap()
            .as_str()
            .unwrap()
            .parse()
            .unwrap()
    };
    let (engine, clock) = (b("/shared/riskEngine"), b("/shared/clock"));
    let feeds = [b("/shared/feedA"), b("/shared/feedB")];
    let (nvda, id) = (h("/assetIds/NVDA"), h("/equity/markets/NVDA"));

    // ── the stand-in engine: weekend safe LTV, a premium, a zero joint column per equity asset ──
    let me = IMockEngine::new(engine, &d);
    me.setSafeLtv(nvda, 2, U256::from(SAFE_LTV))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    me.setQuote(
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
    let k_stress = me.params().call().await.unwrap().kStress as usize;
    for (t, v) in book["assetIds"].as_object().unwrap() {
        if t != "TBILL" {
            me.setJointColumn(
                v.as_str().unwrap().parse().unwrap(),
                vec![U256::ZERO; k_stress.div_ceil(16)],
            )
            .send()
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        }
    }

    // ── Postgres: a scratch DB with the migrations, and the indexer's `position` for this market ──
    let admin = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
    let url = credence_common::db::scratch_database(&admin, db_name)
        .await
        .unwrap();
    let db: PgPool = credence_common::db::connect(&url, 4).await.unwrap();
    sqlx::raw_sql("create schema if not exists ix; create table if not exists ix.position (market_id text, owner text, borrow_shares numeric)")
        .execute(&db)
        .await
        .unwrap();

    Stack {
        rpcs: vec![rpc.clone()],
        j3_batch: None,
        prep: None,
        _anvil: Some(anvil),
        rpc: rpc.clone(),
        d: d.clone(),
        book: book.clone(),
        clock,
        feeds,
        nvda,
        id,
        db,
        now: ManualClock::new(start),
        ticks: 0,
    }
}

/// The post-deploy REOPEN on Friday (open print $180 at 09:30 ET), ended by the keeper's J5; returns the chain
/// time after it.
pub async fn friday_reopen(s: &mut Stack) -> u64 {
    // ── Friday: the post-deploy reopen (open print at 09:30 ET), ended by the keeper's J5 completeReopen ──
    let chain_now = s.d.get_block_number().await.unwrap();
    let t0 =
        s.d.get_block_by_number(chain_now.into())
            .await
            .unwrap()
            .unwrap()
            .header
            .timestamp;
    for f in s.feeds {
        push(
            &s.d,
            f,
            s.nvda,
            credence_relayer::report::Kind::Open,
            FRI_OPEN + 1,
            180 * WAD,
            FRI_OPEN,
        )
        .await;
    }
    s.at(t0 + 1, 180 * WAD, FRI_OPEN).await;
    IPoke::new(s.clock, &s.d)
        .poke(s.nvda)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    for dt in [5, 130, 140] {
        s.at(t0 + dt, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    assert_eq!(
        s.state().await,
        0,
        "REGULAR after the keeper's completeReopen"
    );

    t0 + 150
}
