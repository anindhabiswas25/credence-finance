//! Keeper acceptance (Sprint 1 item 6), run with `make keeper-e2e`:
//!
//! * `j1_pokes_on_schedule`: the real `AssetClock` (deployed by BE-chain's `DeployClockLocal.s.sol`
//!   with the repo's XNYS/USBANK calendars) on anvil, with chain time set to Wed 2026-10-07. J1 pokes
//!   at the heartbeat, at the 09:30 ET open boundary (+1 s) and at the Bell-window boundary, never twice
//!   for one key, and the open poke emits `StateChanged`.
//! * `leader_failover_no_duplicates`: two instances on one Postgres. (a) The leader is killed: the
//!   follower takes over at once. (b) The leader hangs holding the lock: the follower fences it after
//!   15 s of missed heartbeats. (c) A leader crashes after broadcasting a poke but before marking the
//!   job: the new leader reconciles the recorded tx and does not send it again.
//!
//! Needs `anvil`, `forge` and `TEST_DATABASE_URL` (e.g. `postgres://credence:credence@127.0.0.1:5433/credence`).

use alloy::{
    network::EthereumWallet,
    primitives::{Address, Bytes, B256},
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
    sol_types::{SolCall, SolEvent},
};
use credence_keeper::{
    bindings::IAssetClock,
    clock::ManualClock,
    config::{load_calendars, tracked},
    jobs,
    leader::Leader,
    metrics::Metrics,
    rpc::Rpc,
    schedule,
    tasks::Keeper,
    tx::TxManager,
};
use sqlx::PgPool;
use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};

const ANVIL0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
/// Wed 2026-10-07 09:30 ET (13:30Z): the regular open.
const OPEN: u64 = 1_791_379_800;
const CLOSE: u64 = OPEN + 23_400;

fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

struct Anvil {
    rpc: String,
    child: std::process::Child,
}
impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

async fn anvil_at(ts: u64) -> Anvil {
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let child = std::process::Command::new("anvil")
        .args([
            "--port",
            &port.to_string(),
            "--timestamp",
            &ts.to_string(),
            "--silent",
            "--code-size-limit",
            "100000",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("anvil must be installed");
    let rpc = format!("http://127.0.0.1:{port}");
    let p = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    for _ in 0..100 {
        if p.get_chain_id().await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Anvil { rpc, child }
}

/// Deploy the clock stack with BE-chain's script; returns (clock, NVDA asset id, feed A).
fn deploy_clock(rpc: &str, tag: &str) -> (Address, B256, Address) {
    // forge's fs_permissions allow writes only under deployments/; *.local.json is git-ignored there
    let out = repo().join(format!(
        "deployments/31337.keeper-test-{tag}-{}.local.json",
        std::process::id()
    ));
    let cal = |v: &str| {
        credence_common::calendar::find_latest(v).unwrap_or_else(|_| {
            repo().join(format!(
                "calibration/out/calendars/{v}-20261001-20271031.json"
            ))
        })
    };
    let status = std::process::Command::new("forge")
        .current_dir(repo().join("contracts"))
        .args(["script", "script/DeployClockLocal.s.sol:DeployClockLocal", "--rpc-url", rpc, "--broadcast", "--slow", "-q"])
        .env("PRIVATE_KEY", ANVIL0)
        .env("RELAYER_A_SIGNERS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906")
        .env("RELAYER_B_SIGNERS", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906")
        .env("XNYS_CALENDAR", cal("XNYS"))
        .env("USBANK_CALENDAR", cal("USBANK"))
        .env("OUT", &out)
        .stdout(Stdio::null())
        .status()
        .expect("forge must be installed");
    assert!(
        status.success(),
        "DeployClockLocal failed (run `make contracts-build` first)"
    );
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
    let _ = std::fs::remove_file(&out);
    (
        v["shared"]["clock"].as_str().unwrap().parse().unwrap(),
        v["assetIds"]["NVDA"].as_str().unwrap().parse().unwrap(),
        v["shared"]["feedA"].as_str().unwrap().parse().unwrap(),
    )
}

/// Submit one 2-of-3 signed LIVE report to `feed` (committee = anvil keys 1–3, as deployed above).
async fn push_price(
    rpc: &str,
    feed: Address,
    asset: B256,
    at: u64,
    status: credence_relayer::report::MarketStatus,
) {
    use alloy::signers::SignerSync;
    use credence_relayer::report::{
        digest, domain, report, sorted_signatures, ICredencePriceFeed, Kind,
    };
    let signer: PrivateKeySigner = ANVIL0.parse().unwrap();
    let p = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc.parse().unwrap());
    let f = ICredencePriceFeed::new(feed, &p);
    let seq = f.latestSeq(asset).call().await.unwrap() + 1;
    let r = vec![report(
        asset,
        Kind::Live,
        180_000_000_000_000_000_000,
        at,
        OPEN / 86_400,
        status,
        seq,
    )];
    let h = digest(&domain(31_337, feed), &r);
    let keys = [
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    ];
    let sigs = sorted_signatures(
        keys.iter()
            .map(|k| k.parse::<PrivateKeySigner>().unwrap())
            .map(|s| (s.address(), s.sign_hash_sync(&h).unwrap()))
            .collect(),
    );
    let receipt = f
        .submit(r, sigs.into_iter().map(|(_, b)| b).collect())
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status(), "price submit reverted");
}

async fn db(name: &str) -> (String, PgPool) {
    let admin = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL (see test docs)");
    let url = credence_common::db::scratch_database(&admin, name)
        .await
        .unwrap();
    let pool = credence_common::db::connect(&url, 4).await.unwrap();
    (url, pool)
}

async fn set_chain_time(rpc: &str, t: u64) {
    let p = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: serde_json::Value = p
        .raw_request("evm_setNextBlockTimestamp".into(), (t,))
        .await
        .unwrap();
}

fn keeper(instance: &str, rpc: &str, clock_addr: Address, clock: &ManualClock) -> Keeper {
    let cals = load_calendars_from_repo();
    let assets = tracked(&["NVDA:XNAS".to_string()], &cals).unwrap();
    let metrics = Metrics::detached();
    let rpc = Arc::new(Rpc::connect(&[rpc.to_string()], None).unwrap());
    let signer: PrivateKeySigner = ANVIL0.parse().unwrap();
    let tx = TxManager::new(
        rpc.clone(),
        EthereumWallet::from(signer.clone()),
        signer.address(),
        31_337,
        metrics.clone(),
    );
    Keeper::new(
        instance.into(),
        rpc,
        tx,
        clock_addr,
        assets,
        Arc::new(clock.clone()),
        metrics,
        900,
    )
}

fn load_calendars_from_repo(
) -> std::collections::HashMap<String, Arc<credence_common::calendar::Calendar>> {
    std::env::set_current_dir(repo()).unwrap();
    load_calendars().unwrap()
}

async fn tx_count(pool: &PgPool, key: &str) -> i64 {
    sqlx::query_scalar("select count(*) from ops.keeper_tx where job_key = $1")
        .bind(key)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn mined_pokes(pool: &PgPool) -> i64 {
    sqlx::query_scalar("select count(*) from ops.keeper_tx where status = 'mined'")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make keeper-e2e)"]
async fn j1_pokes_on_schedule() {
    let anvil = anvil_at(OPEN - 300).await;
    let (clock_addr, nvda, feed_a) = deploy_clock(&anvil.rpc, "sched");
    let (url, pool) = db("credence_keeper_sched").await;
    let clock = ManualClock::new(OPEN - 30);
    let k = keeper("keeper-a", &anvil.rpc, clock_addr, &clock);
    let mut leader = Leader::new(&url, pool.clone(), "keeper-a", 31_337);
    assert!(leader.tick().await.unwrap());

    // a fresh pre-market price from feed A, so the clock can leave its fail-closed state
    set_chain_time(&anvil.rpc, OPEN - 40).await;
    push_price(
        &anvil.rpc,
        feed_a,
        nvda,
        OPEN - 40,
        credence_relayer::report::MarketStatus::Pre,
    )
    .await;

    // 09:29:30 ET: only the heartbeat is due
    set_chain_time(&anvil.rpc, OPEN - 30).await;
    let r = k.tick(leader.conn().unwrap()).await.unwrap();
    assert_eq!(r.pokes.len(), 1, "{r:?}");
    assert!(r.pokes[0].1.contains(":hb:"));

    // 09:30:01 ET: the open boundary fires (+1 s); this minute's heartbeat is covered by it
    clock.set(OPEN + 1);
    set_chain_time(&anvil.rpc, OPEN + 1).await;
    let r = k.tick(leader.conn().unwrap()).await.unwrap();
    assert_eq!(
        r.pokes,
        vec![("NVDA:XNAS".to_string(), schedule::j1_key(&nvda, OPEN))]
    );
    assert_eq!(r.covered, 1);
    // the open poke moved the clock and emitted StateChanged
    let hash: Vec<u8> = sqlx::query_scalar(
        "select hash from ops.keeper_tx where job_key = $1 and status = 'mined'",
    )
    .bind(schedule::j1_key(&nvda, OPEN))
    .fetch_one(&pool)
    .await
    .unwrap();
    let p = ProviderBuilder::new().connect_http(anvil.rpc.parse().unwrap());
    let receipt = p
        .get_transaction_receipt(B256::from_slice(&hash))
        .await
        .unwrap()
        .unwrap();
    let blk = p
        .get_block_by_number(receipt.block_number.unwrap().into())
        .await
        .unwrap()
        .unwrap();
    let st = IAssetClock::new(clock_addr, &p)
        .state(nvda)
        .call()
        .await
        .unwrap();
    assert_eq!(blk.header.timestamp, OPEN + 1, "poked at boundary + 1 s");
    let _ = st;
    let changed: Vec<_> = receipt
        .inner
        .logs()
        .iter()
        .filter_map(|l| IAssetClock::StateChanged::decode_log(&l.inner).ok())
        .collect();
    assert_eq!(changed.len(), 1, "StateChanged at the open");
    assert_eq!(changed[0].asset, nvda);
    assert_ne!(changed[0].from, changed[0].to);

    // same minute again: nothing due, nothing sent
    clock.set(OPEN + 5);
    let r = k.tick(leader.conn().unwrap()).await.unwrap();
    assert!(r.pokes.is_empty(), "{r:?}");

    // 14:00:01 ET: Bell window (close − 2 h)
    let bell_window = CLOSE - 7200;
    clock.set(bell_window + 1);
    set_chain_time(&anvil.rpc, bell_window + 1).await;
    let r = k.tick(leader.conn().unwrap()).await.unwrap();
    assert_eq!(
        r.pokes,
        vec![(
            "NVDA:XNAS".to_string(),
            schedule::j1_key(&nvda, bell_window)
        )]
    );

    // exactly one tx per poked key, all mined
    for key in [
        schedule::j1_key(&nvda, OPEN),
        schedule::j1_key(&nvda, bell_window),
    ] {
        assert_eq!(tx_count(&pool, &key).await, 1, "{key}");
    }
    assert_eq!(mined_pokes(&pool).await, 3);
    // J12 ran once today: coverage checked on-chain, Stylus check stubbed
    let j12: Vec<(String, String)> =
        sqlx::query_as("select key, status from ops.keeper_job where job = 'J12' order by key")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(j12.len(), 3, "{j12:?}");
    assert!(j12
        .iter()
        .any(|(k, s)| k.contains("stylus") && s == "skipped"));
    assert!(j12
        .iter()
        .any(|(k, s)| k.contains("calendar-coverage") && s == "done"));
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make keeper-e2e)"]
async fn leader_failover_no_duplicates() {
    let anvil = anvil_at(OPEN - 300).await;
    let (clock_addr, nvda, _) = deploy_clock(&anvil.rpc, "failover");
    let (url, pool) = db("credence_keeper_failover").await;
    let clock = ManualClock::new(OPEN + 1);
    set_chain_time(&anvil.rpc, OPEN + 1).await;

    // A leads, B follows
    let ka = keeper("keeper-a", &anvil.rpc, clock_addr, &clock);
    let kb = keeper("keeper-b", &anvil.rpc, clock_addr, &clock);
    let mut la = Leader::new(&url, pool.clone(), "keeper-a", 31_337);
    let mut lb = Leader::new(&url, pool.clone(), "keeper-b", 31_337);
    assert!(la.tick().await.unwrap());
    assert!(!lb.tick().await.unwrap());
    let r = ka.tick(la.conn().unwrap()).await.unwrap();
    assert_eq!(r.pokes.len(), 1);

    // (a) kill A (its connection goes away with the process): B takes over on its next attempt
    drop(ka);
    la.step_down().await;
    drop(la);
    let t0 = std::time::Instant::now();
    let mut took_over = false;
    for _ in 0..15 {
        if lb.tick().await.unwrap() {
            took_over = true;
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    assert!(
        took_over && t0.elapsed() < Duration::from_secs(15),
        "takeover after kill took {:?}",
        t0.elapsed()
    );
    // B re-runs the same minute: the open key is done → no duplicate side effect
    let r = kb.tick(lb.conn().unwrap()).await.unwrap();
    assert!(
        r.pokes.is_empty(),
        "B must not re-poke keys A completed: {r:?}"
    );
    assert_eq!(tx_count(&pool, &schedule::j1_key(&nvda, OPEN)).await, 1);

    // (b) B hangs while holding the lock (no more heartbeats); C fences it after 15 s
    let mut lc = Leader::new(&url, pool.clone(), "keeper-c", 31_337);
    let t0 = std::time::Instant::now();
    let mut c_leads = false;
    for _ in 0..25 {
        if lc.tick().await.unwrap() {
            c_leads = true;
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let waited = t0.elapsed();
    assert!(c_leads, "C never took over from the hung leader");
    assert!(
        waited >= Duration::from_secs(14) && waited <= Duration::from_secs(20),
        "fenced after {waited:?} (want ≈15 s)"
    );
    assert!(
        !lb.tick().await.unwrap(),
        "the fenced leader must see it lost the lock"
    );

    // (c) C broadcasts a poke for the Bell-window key, then "crashes" before marking the job done
    let key = schedule::j1_key(&nvda, CLOSE - 7200);
    clock.set(CLOSE - 7200 + 1);
    set_chain_time(&anvil.rpc, CLOSE - 7200 + 1).await;
    let kc = keeper("keeper-c", &anvil.rpc, clock_addr, &clock);
    {
        let conn = lc.conn().unwrap();
        assert!(matches!(
            jobs::claim(conn, &key, "J1", &serde_json::json!({}), "keeper-c")
                .await
                .unwrap(),
            jobs::Claim::Run { .. }
        ));
        let data = Bytes::from(IAssetClock::pokeCall { assetId: nvda }.abi_encode());
        let m = kc.tx.send(conn, &key, clock_addr, data).await.unwrap();
        assert!(m.success);
    }
    drop(kc);
    lc.step_down().await;
    // D takes over and reconciles the recorded tx instead of sending another poke
    let mut ld = Leader::new(&url, pool.clone(), "keeper-d", 31_337);
    assert!(ld.tick().await.unwrap());
    let kd = keeper("keeper-d", &anvil.rpc, clock_addr, &clock);
    let r = kd.tick(ld.conn().unwrap()).await.unwrap();
    assert_eq!(r.reconciled, 1, "{r:?}");
    assert!(r.pokes.is_empty(), "{r:?}");
    assert_eq!(
        tx_count(&pool, &key).await,
        1,
        "exactly one tx for the key across the crash"
    );
    let status: String = sqlx::query_scalar("select status from ops.keeper_job where key = $1")
        .bind(&key)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(status, "done");
}
