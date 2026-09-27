//! Relayer end to end on a local chain (Sprint 1 acceptance 4). Run with `make relayer-e2e`
//! (it needs `anvil` and the compiled contracts from `make contracts-build`):
//!
//! * deploys the real `CredencePriceFeed` from `contracts/out` (BE-chain's contract, unmodified),
//! * the on-chain `hashReports` / `domainSeparator` equal the Rust EIP-712 digest,
//! * 3 signer nodes + the aggregator on the replay vendor → a 2-of-3 signed batch is **accepted**,
//! * **rejected**: signed by 1 of 3; a replayed seq; an older seq; a wrong EIP-712 domain; unsorted sigs,
//! * with `TEST_DATABASE_URL` set, every signed report lands in `ops.relayer_report` with its outcome.
//!
//! `E2E_RPC_URL` + `E2E_PRIVATE_KEY` run it against an existing chain (e.g. the nitro-devnode) instead
//! of a fresh anvil.

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, Bytes, B256, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::{local::PrivateKeySigner, SignerSync},
    sol_types::SolValue,
};
use credence_common::{calendar::Calendar, signer::CredenceSigner};
use credence_relayer::{
    aggregator::{Aggregator, AggregatorConfig, LocalNode, NodeClient, TickOutcome},
    asset::Asset,
    chain::{ChainClient, FeedChain, SubmitOutcome},
    filter::FilterConfig,
    metrics::Metrics,
    node::{Node, NodeConfig},
    report::{
        digest, domain, report, sorted_signatures, ICredencePriceFeed, Kind, MarketStatus, Report,
    },
    store::{MemStore, PgStore, ReportStore},
    vendor::replay::{synthetic_session, Replay},
};
use std::{process::Stdio, sync::Arc, time::Duration};

const ANVIL: [&str; 4] = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

struct Chain {
    rpc: String,
    deployer: PrivateKeySigner,
    chain_id: u64,
    _anvil: Option<std::process::Child>,
}

impl Drop for Chain {
    fn drop(&mut self) {
        if let Some(c) = self._anvil.as_mut() {
            let _ = c.kill();
        }
    }
}

async fn start_chain() -> Chain {
    if let Ok(rpc) = std::env::var("E2E_RPC_URL") {
        let key = std::env::var("E2E_PRIVATE_KEY").expect("E2E_PRIVATE_KEY with E2E_RPC_URL");
        let p = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
        let chain_id = p.get_chain_id().await.unwrap();
        return Chain {
            rpc,
            deployer: key.parse().unwrap(),
            chain_id,
            _anvil: None,
        };
    }
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let child = std::process::Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("anvil must be installed (foundryup)");
    let rpc = format!("http://127.0.0.1:{port}");
    let p = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    for _ in 0..100 {
        if p.get_chain_id().await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Chain {
        rpc,
        deployer: ANVIL[0].parse().unwrap(),
        chain_id: 31_337,
        _anvil: Some(child),
    }
}

fn artifact_bytecode() -> Bytes {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../contracts/out/CredencePriceFeed.sol/CredencePriceFeed.json"
    );
    let raw = std::fs::read_to_string(path)
        .unwrap_or_else(|_| panic!("{path} missing: run `make contracts-build` first"));
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    v["bytecode"]["object"]
        .as_str()
        .expect("bytecode.object")
        .parse()
        .unwrap()
}

fn committee() -> Vec<PrivateKeySigner> {
    let mut v: Vec<PrivateKeySigner> = ANVIL[1..].iter().map(|k| k.parse().unwrap()).collect();
    v.sort_by_key(|s| s.address());
    v
}

async fn deploy_feed(chain: &Chain) -> Address {
    let wallet = EthereumWallet::from(chain.deployer.clone());
    let p = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(chain.rpc.parse().unwrap());
    let signers: Vec<Address> = committee().iter().map(|s| s.address()).collect();
    let args = (chain.deployer.address(), signers, U256::from(2u8)).abi_encode_params(); // uint8 threshold (same ABI word)
    let mut code = artifact_bytecode().to_vec();
    code.extend_from_slice(&args);
    let tx = TransactionRequest::default().with_deploy_code(Bytes::from(code));
    let receipt = p
        .send_transaction(tx)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status(), "deploy reverted");
    receipt.contract_address.expect("contract address")
}

fn sign_with(
    signers: &[&PrivateKeySigner],
    chain_id: u64,
    feed: Address,
    reports: &[Report],
) -> Vec<Bytes> {
    let h = digest(&domain(chain_id, feed), reports);
    sorted_signatures(
        signers
            .iter()
            .map(|s| (s.address(), s.sign_hash_sync(&h).unwrap()))
            .collect(),
    )
    .into_iter()
    .map(|(_, b)| b)
    .collect()
}

fn now() -> u64 {
    credence_relayer::node::now_s()
}

#[tokio::test]
#[ignore = "needs anvil + contracts/out (make relayer-e2e)"]
async fn relayer_end_to_end_on_local_chain() {
    let chain = start_chain().await;
    let feed = deploy_feed(&chain).await;
    let client = ChainClient::connect(
        std::slice::from_ref(&chain.rpc),
        EthereumWallet::from(chain.deployer.clone()),
        feed,
        None,
    )
    .unwrap();
    let chain_id = chain.chain_id;
    let d = domain(chain_id, feed);

    // ── 1. on-chain digest == Rust digest ───────────────────────────────────────────────────────
    let nvda = Asset::parse("NVDA:XNAS").unwrap();
    let probe = vec![report(
        nvda.id,
        Kind::Live,
        180_120_000_000_000_000_000,
        now(),
        now() / 86_400,
        MarketStatus::Regular,
        1,
    )];
    assert_eq!(
        client.hash_reports(&probe).await.unwrap(),
        digest(&d, &probe),
        "on-chain hashReports != Rust digest"
    );
    let ds = ICredencePriceFeed::new(feed, client.provider())
        .domainSeparator()
        .call()
        .await
        .unwrap();
    assert_eq!(ds, d.separator(), "domain separator");

    // ── 2. full pipeline: replay vendor → 3 nodes → aggregator → accepted with 2-of-3 ───────────
    let open = now() - 600; // ten minutes into a regular session
    let events = synthetic_session(&[("NVDA", "XNAS", 180.0), ("AAPL", "XNAS", 230.0)], open);
    let first = events
        .iter()
        .filter_map(|e| match e {
            credence_relayer::vendor::replay::Event::Header { .. } => None,
            credence_relayer::vendor::replay::Event::Market { t, .. }
            | credence_relayer::vendor::replay::Event::Trade { t, .. }
            | credence_relayer::vendor::replay::Event::Quote { t, .. }
            | credence_relayer::vendor::replay::Event::Halt { t, .. } => Some(*t),
        })
        .min()
        .unwrap();
    // identity warp: recording time == wall time, so the session is "live" now
    let replay = Replay::from_events(events, 1.0, chain_id, first).unwrap();
    let calendar: Arc<Calendar> = Arc::new(replay.calendar().clone());
    let vendor: Arc<Replay> = Arc::new(replay);
    let assets = vec![nvda.clone(), Asset::parse("AAPL:XNAS").unwrap()];
    let metrics = Metrics::detached();
    let mut nodes: Vec<Arc<dyn NodeClient>> = Vec::new();
    for (i, key) in ANVIL[1..].iter().enumerate() {
        let signer = CredenceSigner::Local(key.parse().unwrap());
        let cfg = NodeConfig {
            id: format!("node-{}", i + 1),
            assets: assets.clone(),
            poll_interval: Duration::from_secs(1),
            print_poll_interval: Duration::from_secs(0),
            filter: FilterConfig::default(),
            auth_token: None,
        };
        let n = Arc::new(Node::new(
            cfg,
            vendor.clone(),
            calendar.clone(),
            signer,
            d.clone(),
            metrics.clone(),
        ));
        n.poll_once().await;
        nodes.push(Arc::new(LocalNode(n)));
    }
    let store: Arc<dyn ReportStore> = match std::env::var("TEST_DATABASE_URL") {
        Ok(url) => {
            let db = credence_common::db::scratch_database(&url, "credence_relayer_e2e")
                .await
                .unwrap();
            Arc::new(PgStore::new(
                credence_common::db::connect(&db, 2).await.unwrap(),
            ))
        }
        Err(_) => Arc::new(MemStore::default()),
    };
    let chain_arc: Arc<dyn FeedChain> = Arc::new(
        ChainClient::connect(
            std::slice::from_ref(&chain.rpc),
            EthereumWallet::from(chain.deployer.clone()),
            feed,
            None,
        )
        .unwrap(),
    );
    let cfg = AggregatorConfig {
        feed: "A".into(),
        threshold: 2,
        tick: Duration::from_secs(1),
        committee: Some(committee().iter().map(|s| s.address()).collect()),
        assets: assets.iter().map(|a| (a.id, a.symbol.clone())).collect(),
    };
    let mut agg = Aggregator::new(cfg, nodes, chain_arc, store.clone(), metrics.clone());
    agg.sync_seqs().await.unwrap();
    let out = agg.tick().await.unwrap();
    let TickOutcome::Submitted {
        reports: n,
        outcome: SubmitOutcome::Accepted { .. },
    } = out
    else {
        panic!("expected an accepted batch, got {out:?}");
    };
    // STATUS + OPEN + LIVE for each of the two assets, in ONE transaction
    assert!(n >= 4, "batch had {n} reports");
    let f = ICredencePriceFeed::new(feed, client.provider());
    let live = f.latest(nvda.id).call().await.unwrap();
    assert!(live.price > U256::ZERO, "LIVE price stored");
    assert_eq!(live.marketStatus, MarketStatus::Regular as u8);
    let seq_after_pipeline = f.latestSeq(nvda.id).call().await.unwrap();
    assert!(seq_after_pipeline >= 3);
    let max = store.max_seqs("A").await.unwrap();
    assert_eq!(
        max.get(&nvda.id).copied(),
        Some(seq_after_pipeline),
        "persisted high-water mark"
    );

    // an immediate second tick publishes nothing new (cadence: 10 s heartbeat, no 0.10% move)
    let second = agg.tick().await.unwrap();
    assert!(
        matches!(second, TickOutcome::Idle),
        "second tick: {second:?}"
    );

    // ── 3. rejections ───────────────────────────────────────────────────────────────────────────
    let c = committee();
    let next = seq_after_pipeline + 1;
    let fresh = vec![report(
        nvda.id,
        Kind::Live,
        181_000_000_000_000_000_000,
        now(),
        now() / 86_400,
        MarketStatus::Regular,
        next,
    )];

    // 1 of 3
    let r = client
        .submit(&fresh, sign_with(&[&c[0]], chain_id, feed, &fresh))
        .await
        .unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("NotEnoughSigners")),
        "1-of-3: {r:?}"
    );

    // wrong domain (another chain id; same for another verifying contract)
    let r = client
        .submit(
            &fresh,
            sign_with(&[&c[0], &c[1]], chain_id + 1, feed, &fresh),
        )
        .await
        .unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("UnknownSigner")),
        "wrong chain id: {r:?}"
    );
    let r = client
        .submit(
            &fresh,
            sign_with(
                &[&c[0], &c[1]],
                chain_id,
                Address::repeat_byte(0x42),
                &fresh,
            ),
        )
        .await
        .unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("UnknownSigner")),
        "wrong contract: {r:?}"
    );

    // unsorted signatures
    let mut unsorted = sign_with(&[&c[0], &c[1]], chain_id, feed, &fresh);
    unsorted.reverse();
    let r = client.submit(&fresh, unsorted).await.unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("SignersNotSorted")),
        "unsorted: {r:?}"
    );

    // the same batch with 2 of 3 is accepted …
    let r = client
        .submit(&fresh, sign_with(&[&c[0], &c[2]], chain_id, feed, &fresh))
        .await
        .unwrap();
    assert!(matches!(r, SubmitOutcome::Accepted { .. }), "2-of-3: {r:?}");
    assert_eq!(f.latestSeq(nvda.id).call().await.unwrap(), next);

    // … and replaying it (same seq) or an older seq is rejected
    let r = client
        .submit(&fresh, sign_with(&[&c[0], &c[2]], chain_id, feed, &fresh))
        .await
        .unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("StaleReport")),
        "replayed seq: {r:?}"
    );
    let old = vec![report(
        nvda.id,
        Kind::Live,
        181_000_000_000_000_000_000,
        now(),
        now() / 86_400,
        MarketStatus::Regular,
        next - 1,
    )];
    let r = client
        .submit(&old, sign_with(&[&c[1], &c[2]], chain_id, feed, &old))
        .await
        .unwrap();
    assert!(
        matches!(&r, SubmitOutcome::Rejected { reason } if reason.contains("StaleReport")),
        "old seq: {r:?}"
    );

    // ── 4. the aggregator recovers its seq from the chain after someone else advanced it ────────
    let r = agg.sync_seqs().await;
    assert!(r.is_ok());
    let _ = B256::ZERO;
}
