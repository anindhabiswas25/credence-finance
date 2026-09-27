//! Streaming path end to end, without a chain: a mock Alpaca WebSocket server → 3 signer nodes, each
//! with its own stream connection (production topology) → the aggregator → a recording `FeedChain`.
//!
//! * A ≥ 0.10% move pushed by the vendor is submitted in **under one second** (§10.1 "immediately on a
//!   ≥ 0.10% move"; the REST poll alone needs 2 s + a tick).
//! * A 0.01% move is not submitted before the 10 s heartbeat.
//! * When the stream drops, `live` falls back to REST, and a halt on the stream reaches `status`.

use alloy::primitives::{Address, Bytes, B256};
use anyhow::Result;
use async_trait::async_trait;
use credence_common::{
    calendar::{Calendar, ClosureType, Session},
    signer::CredenceSigner,
};
use credence_relayer::{
    aggregator::{Aggregator, AggregatorConfig, LocalNode, NodeClient},
    asset::{Asset, Plan},
    chain::{FeedChain, SubmitOutcome},
    filter::FilterConfig,
    metrics::Metrics,
    node::{now_s, Node, NodeConfig},
    report::{domain, Kind, Report},
    store::MemStore,
    vendor::{
        alpaca_ws::AlpacaStream,
        stream::{run_stream, StreamCache, StreamOptions, Streaming},
        DynVendor, HaltInfo, LiveInput, MarketDataVendor, OfficialPrint, StatusInput, VendorError,
        VendorMarket, VendorResult,
    },
};
use futures::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

const ANVIL: [&str; 3] = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

/// REST side: market open, no halt; LIVE always fails (so every LIVE price must come from the stream).
#[derive(Default)]
struct Rest {
    live_calls: AtomicUsize,
}

#[async_trait]
impl MarketDataVendor for Rest {
    fn name(&self) -> &'static str {
        "alpaca"
    }
    async fn live(&self, _a: &Asset, _s: u64) -> VendorResult<LiveInput> {
        self.live_calls.fetch_add(1, Ordering::SeqCst);
        Err(VendorError::Other("rest live disabled in this test".into()))
    }
    async fn official_open(&self, _a: &Asset, _s: &Session) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn official_close(
        &self,
        _a: &Asset,
        _s: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn status(&self, _a: &Asset) -> VendorResult<StatusInput> {
        Ok(StatusInput {
            market: VendorMarket::Open,
            halt: Some(HaltInfo {
                halted: false,
                reason: None,
            }),
        })
    }
}

#[derive(Default)]
struct Chain {
    submits: Mutex<Vec<(Instant, Vec<Report>)>>,
}

#[async_trait]
impl FeedChain for Chain {
    async fn latest_seq(&self, _a: B256) -> Result<u64> {
        Ok(0)
    }
    async fn submit(&self, reports: &[Report], _s: Vec<Bytes>) -> Result<SubmitOutcome> {
        self.submits
            .lock()
            .unwrap()
            .push((Instant::now(), reports.to_vec()));
        Ok(SubmitOutcome::Accepted {
            tx_hash: B256::ZERO,
            block: 1,
        })
    }
}

/// Mock Alpaca stream: handshake, then forwards every frame the test publishes. `kill` drops all
/// connections (and refuses new ones while set).
struct MockAlpaca {
    url: String,
    frames: broadcast::Sender<String>,
    kill: broadcast::Sender<()>,
    refuse: Arc<std::sync::atomic::AtomicBool>,
}

async fn mock_alpaca() -> MockAlpaca {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/v2", listener.local_addr().unwrap());
    let (frames, _) = broadcast::channel::<String>(1024);
    let (kill, _) = broadcast::channel::<()>(4);
    let refuse = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (f, k, r) = (frames.clone(), kill.clone(), refuse.clone());
    tokio::spawn(async move {
        loop {
            let (sock, _) = listener.accept().await.unwrap();
            if r.load(Ordering::SeqCst) {
                drop(sock);
                continue;
            }
            let mut frames = f.subscribe();
            let mut kill = k.subscribe();
            tokio::spawn(async move {
                let Ok(ws) = tokio_tungstenite::accept_async(sock).await else {
                    return;
                };
                let (mut tx, mut rx) = ws.split();
                tx.send(Message::text(r#"[{"T":"success","msg":"connected"}]"#))
                    .await
                    .ok();
                loop {
                    tokio::select! {
                        m = rx.next() => {
                            let Some(Ok(Message::Text(t))) = m else {
                                if matches!(m, Some(Ok(_))) { continue; }
                                return;
                            };
                            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                            let reply = match v["action"].as_str() {
                                Some("auth") => r#"[{"T":"success","msg":"authenticated"}]"#,
                                Some("subscribe") => r#"[{"T":"subscription","trades":["NVDA"],"quotes":["NVDA"],"statuses":["NVDA"],"lulds":["NVDA"]}]"#,
                                _ => continue,
                            };
                            tx.send(Message::text(reply)).await.ok();
                        }
                        f = frames.recv() => {
                            let Ok(f) = f else { return };
                            if tx.send(Message::text(f)).await.is_err() { return; }
                        }
                        _ = kill.recv() => { tx.send(Message::Close(None)).await.ok(); return; }
                    }
                }
            });
        }
    });
    MockAlpaca {
        url,
        frames,
        kill,
        refuse,
    }
}

fn rfc3339_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Nanos, true)
}

fn push_price(m: &MockAlpaca, price: f64) {
    let t = rfc3339_now();
    let frame = serde_json::json!([
        {"T":"q","S":"NVDA","bx":"Q","bp":price - 0.01,"bs":1,"ax":"Q","ap":price + 0.01,"as":1,"c":["R"],"t":t,"z":"C"},
        {"T":"t","S":"NVDA","i":1,"x":"Q","p":price,"s":100,"c":["@"],"t":t,"z":"C"},
    ]);
    m.frames.send(frame.to_string()).unwrap();
}

fn streaming_vendor(m: &MockAlpaca, rest: Arc<Rest>) -> (DynVendor, Arc<StreamCache>) {
    let proto = AlpacaStream::new(
        &m.url,
        "sip",
        "key".into(),
        "secret".into(),
        HashMap::from([("NVDA".to_string(), Plan::Utp)]),
    );
    let cache = StreamCache::new("alpaca");
    let opts = StreamOptions {
        backoff_min: Duration::from_millis(100),
        backoff_max: Duration::from_millis(200),
        ..Default::default()
    };
    tokio::spawn(run_stream(
        Arc::new(proto),
        vec!["NVDA".into()],
        cache.clone(),
        opts,
        None,
    ));
    (
        Arc::new(Streaming::new(rest, cache.clone(), Duration::from_secs(5))),
        cache,
    )
}

fn live_prices(reports: &[Report]) -> Vec<u128> {
    reports
        .iter()
        .filter(|r| r.kind == Kind::Live as u8)
        .map(|r| r.price)
        .collect()
}

async fn wait_for<F: Fn() -> bool>(max: Duration, f: F) -> bool {
    let start = Instant::now();
    while start.elapsed() < max {
        if f() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    f()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn streamed_move_is_submitted_within_one_second() {
    let now = now_s();
    let cal = Arc::new(
        Calendar::from_sessions(
            "XNYS",
            vec![Session {
                ext_open: now - 4 * 3600,
                open: now - 3600,
                close: now + 5 * 3600,
                ext_close: now + 8 * 3600,
                closure_type_after: ClosureType::Overnight,
            }],
        )
        .unwrap(),
    );
    let mock = mock_alpaca().await;
    let asset = Asset::parse("NVDA:XNAS").unwrap();
    let metrics = Metrics::detached();
    let d = domain(412_346, Address::repeat_byte(0xfe));
    let mut nodes: Vec<Arc<dyn NodeClient>> = Vec::new();
    let mut caches = Vec::new();
    let rest = Arc::new(Rest::default());
    for (i, key) in ANVIL.iter().enumerate() {
        let (vendor, cache) = streaming_vendor(&mock, rest.clone());
        caches.push(cache);
        let n = Arc::new(Node::new(
            NodeConfig {
                id: format!("node-{}", i + 1),
                assets: vec![asset.clone()],
                // the REST poll is slow on purpose: anything sub-second must come from the stream
                poll_interval: Duration::from_secs(5),
                print_poll_interval: Duration::from_secs(60),
                filter: FilterConfig::default(),
                auth_token: None,
            },
            vendor,
            cal.clone(),
            CredenceSigner::Local(key.parse().unwrap()),
            d.clone(),
            metrics.clone(),
        ));
        tokio::spawn(n.clone().run());
        nodes.push(Arc::new(LocalNode(n)));
    }
    assert!(
        wait_for(Duration::from_secs(5), || caches
            .iter()
            .all(|c| c.healthy()))
        .await,
        "all three streams authenticated and subscribed"
    );

    let chain = Arc::new(Chain::default());
    let mut agg = Aggregator::new(
        AggregatorConfig {
            feed: "A".into(),
            threshold: 2,
            tick: Duration::from_millis(250),
            committee: None,
            assets: vec![(asset.id, asset.symbol.clone())],
        },
        nodes,
        chain.clone(),
        Arc::new(MemStore::default()),
        metrics,
    );
    agg.sync_seqs().await.unwrap();
    tokio::spawn(async move {
        let mut t = tokio::time::interval(Duration::from_millis(250));
        loop {
            t.tick().await;
            agg.tick().await.ok();
        }
    });

    // 1. first print → first LIVE
    push_price(&mock, 180.00);
    let wad = |p: f64| (p * 1e6).round() as u128 * 1_000_000_000_000;
    assert!(
        wait_for(Duration::from_secs(3), || chain
            .submits
            .lock()
            .unwrap()
            .iter()
            .any(|(_, r)| live_prices(r).contains(&wad(180.00))))
        .await,
        "first LIVE submitted"
    );
    // the nodes' first poll ran before any stream data (REST warm-up); from here on the stream serves LIVE
    let rest_calls = rest.live_calls.load(Ordering::SeqCst);
    assert!(rest_calls <= 3, "at most the warm-up poll per node");

    // 2. a 0.01% move is not published before the heartbeat
    tokio::time::sleep(Duration::from_millis(300)).await;
    let before = chain.submits.lock().unwrap().len();
    push_price(&mock, 180.018);
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(
        chain.submits.lock().unwrap().len(),
        before,
        "0.01% move: nothing submitted before the 10 s heartbeat"
    );

    // 3. a 0.20% move is submitted in under a second
    let pushed = Instant::now();
    push_price(&mock, 180.40);
    assert!(
        wait_for(Duration::from_secs(3), || chain
            .submits
            .lock()
            .unwrap()
            .iter()
            .any(|(_, r)| live_prices(r).contains(&wad(180.40))))
        .await,
        "moved LIVE submitted"
    );
    let at = chain
        .submits
        .lock()
        .unwrap()
        .iter()
        .find(|(_, r)| live_prices(r).contains(&wad(180.40)))
        .map(|(t, _)| *t)
        .unwrap();
    let reaction = at.duration_since(pushed);
    println!("vendor push → submit: {} ms", reaction.as_millis());
    assert_eq!(
        rest.live_calls.load(Ordering::SeqCst),
        rest_calls,
        "no REST LIVE call while the stream is healthy"
    );
    assert!(
        reaction < Duration::from_secs(1),
        "reaction {reaction:?} must be sub-second"
    );

    // 4. a halt on the stream reaches status (fail closed), and a dropped stream falls back to REST
    let t = rfc3339_now();
    mock.frames
        .send(
            serde_json::json!([{"T":"s","S":"NVDA","sc":"H","sm":"Trading Halt","rc":"T1","rm":"News pending","t":t,"z":"C"}])
                .to_string(),
        )
        .unwrap();
    let (probe, probe_cache) = streaming_vendor(&mock, rest.clone());
    assert!(wait_for(Duration::from_secs(3), || probe_cache.healthy()).await);
    mock.frames
        .send(
            serde_json::json!([{"T":"s","S":"NVDA","sc":"H","sm":"Trading Halt","rc":"T1","rm":"News pending","t":t,"z":"C"}])
                .to_string(),
        )
        .unwrap();
    assert!(
        wait_for(Duration::from_secs(2), || probe_cache
            .halt("NVDA")
            .is_some_and(|h| h.halted))
        .await
    );
    assert!(probe.status(&asset).await.unwrap().halt.unwrap().halted);

    mock.refuse.store(true, Ordering::SeqCst);
    mock.kill.send(()).unwrap();
    assert!(wait_for(Duration::from_secs(2), || !probe_cache.healthy()).await);
    let calls = rest.live_calls.load(Ordering::SeqCst);
    assert!(probe.live(&asset, 0).await.is_err(), "REST fallback used");
    assert_eq!(rest.live_calls.load(Ordering::SeqCst), calls + 1);
}
