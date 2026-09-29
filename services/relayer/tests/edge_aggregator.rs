//! S4 H edge cases (make backend-edge), relayer end to end without a chain: 3 real signer nodes per feed on a
//! programmable REST vendor → the aggregator → a mock `FeedChain` that enforces the feed's seq rule and can fail.
//!
//! * R-05 one vendor down for every node: that feed publishes nothing, the other feed continues.
//! * R-06 both vendors down: nothing is published at all (the chain's feeds go stale → HALT, E-O-03).
//! * R-07 feeds 6 % apart: each feed publishes its own median as-is (the chain decides, E-O-01).
//! * R-08 an RPC outage at submission: the feed does not stall; every accepted seq is higher than the last (a
//!   gap after the failed submission is allowed by the feed, which only needs seq > stored).

use alloy::primitives::{Address, Bytes, B256};
use anyhow::Result;
use async_trait::async_trait;
use credence_common::{
    calendar::{Calendar, ClosureType, Session},
    signer::CredenceSigner,
};
use credence_relayer::{
    aggregator::{Aggregator, AggregatorConfig, LocalNode, NodeClient, TickOutcome},
    asset::{Asset, Plan},
    chain::{FeedChain, SubmitOutcome},
    filter::FilterConfig,
    metrics::Metrics,
    node::{now_s, Node, NodeConfig},
    report::{domain, Kind, Report},
    store::MemStore,
    vendor::{
        DynVendor, HaltInfo, LiveInput, MarketDataVendor, OfficialPrint, Quote, StatusInput, Trade,
        VendorError, VendorMarket, VendorResult,
    },
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

const KEYS: [&str; 3] = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];
const WAD: u128 = 1_000_000_000_000_000_000;

/// A vendor whose price the test sets; `None` = the vendor is down (every call fails).
struct Vendor {
    price_wad: Mutex<Option<u128>>,
}

impl Vendor {
    fn new(p: Option<u128>) -> Arc<Self> {
        Arc::new(Self {
            price_wad: Mutex::new(p),
        })
    }
    fn get(&self) -> VendorResult<u128> {
        self.price_wad
            .lock()
            .unwrap()
            .ok_or_else(|| VendorError::Other("vendor down".into()))
    }
}

#[async_trait]
impl MarketDataVendor for Vendor {
    fn name(&self) -> &'static str {
        "mock"
    }
    async fn live(&self, _a: &Asset, _s: u64) -> VendorResult<LiveInput> {
        let p = self.get()?;
        let ts_ns = now_s() * 1_000_000_000;
        Ok(LiveInput {
            trades: vec![Trade {
                price_wad: p,
                size: 100,
                ts_ns,
                exchange: "XNAS".into(),
                conditions: vec!["@".into()],
                plan: Plan::Utp,
            }],
            nbbo: Some(Quote {
                bid_wad: p - WAD / 100,
                ask_wad: p + WAD / 100,
                ts_ns,
            }),
        })
    }
    async fn official_open(&self, _a: &Asset, _s: &Session) -> VendorResult<Option<OfficialPrint>> {
        self.get()?;
        Ok(None)
    }
    async fn official_close(
        &self,
        _a: &Asset,
        _s: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        self.get()?;
        Ok(None)
    }
    async fn status(&self, _a: &Asset) -> VendorResult<StatusInput> {
        self.get()?;
        Ok(StatusInput {
            market: VendorMarket::Open,
            halt: Some(HaltInfo {
                halted: false,
                reason: None,
            }),
        })
    }
}

/// The feed contract's seq rule (seq > stored per asset), plus a switch that fails the next submissions
/// like an RPC outage.
#[derive(Default)]
struct Chain {
    stored: Mutex<HashMap<B256, u64>>,
    accepted: Mutex<Vec<Report>>,
    fail: AtomicBool,
    attempts: AtomicUsize,
}

#[async_trait]
impl FeedChain for Chain {
    async fn latest_seq(&self, a: B256) -> Result<u64> {
        if self.fail.load(Ordering::SeqCst) {
            anyhow::bail!("rpc down");
        }
        Ok(self.stored.lock().unwrap().get(&a).copied().unwrap_or(0))
    }
    async fn submit(&self, reports: &[Report], _s: Vec<Bytes>) -> Result<SubmitOutcome> {
        self.attempts.fetch_add(1, Ordering::SeqCst);
        if self.fail.load(Ordering::SeqCst) {
            anyhow::bail!("rpc down: connection refused");
        }
        let mut st = self.stored.lock().unwrap();
        for r in reports {
            if r.seq <= st.get(&r.assetId).copied().unwrap_or(0) {
                return Ok(SubmitOutcome::Rejected {
                    reason: format!("StaleReport seq {}", r.seq),
                });
            }
        }
        for r in reports {
            st.insert(r.assetId, r.seq);
        }
        self.accepted.lock().unwrap().extend_from_slice(reports);
        Ok(SubmitOutcome::Accepted {
            tx_hash: B256::ZERO,
            block: 1,
        })
    }
}

fn calendar() -> Arc<Calendar> {
    let now = now_s();
    Arc::new(
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
    )
}

/// One feed: 3 nodes on `vendor`, an aggregator on `chain`.
fn feed(name: &str, vendor: Arc<Vendor>, chain: Arc<Chain>) -> Aggregator {
    let asset = Asset::parse("NVDA:XNAS").unwrap();
    let metrics = Metrics::detached();
    let d = domain(412_346, Address::repeat_byte(0xfe));
    let cal = calendar();
    let nodes: Vec<Arc<dyn NodeClient>> = KEYS
        .iter()
        .enumerate()
        .map(|(i, k)| {
            let n = Arc::new(Node::new(
                NodeConfig {
                    id: format!("{name}-node-{}", i + 1),
                    assets: vec![asset.clone()],
                    poll_interval: Duration::from_millis(100),
                    print_poll_interval: Duration::from_secs(60),
                    filter: FilterConfig::default(),
                    auth_token: None,
                },
                vendor.clone() as DynVendor,
                cal.clone(),
                CredenceSigner::Local(k.parse().unwrap()),
                d.clone(),
                metrics.clone(),
            ));
            tokio::spawn(n.clone().run());
            Arc::new(LocalNode(n)) as Arc<dyn NodeClient>
        })
        .collect();
    Aggregator::new(
        AggregatorConfig {
            feed: name.into(),
            threshold: 2,
            tick: Duration::from_millis(200),
            committee: None,
            assets: vec![(asset.id, asset.symbol.clone())],
        },
        nodes,
        chain,
        Arc::new(MemStore::default()),
        metrics,
    )
}

fn lives(c: &Chain) -> Vec<u128> {
    c.accepted
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r.kind == Kind::Live as u8)
        .map(|r| r.price)
        .collect()
}

/// Tick every aggregator for `ms`, every 200 ms.
async fn run(aggs: &mut [&mut Aggregator], ms: u64) {
    for _ in 0..ms / 200 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        for a in aggs.iter_mut() {
            let _ = a.tick().await;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn edge_r05_one_vendor_down_for_every_node_silences_that_feed_only() {
    let (ca, cb) = (Arc::new(Chain::default()), Arc::new(Chain::default()));
    let mut a = feed("A", Vendor::new(Some(180 * WAD)), ca.clone());
    let mut b = feed("B", Vendor::new(None), cb.clone());
    run(&mut [&mut a, &mut b], 1_600).await;
    assert_eq!(lives(&ca), vec![180 * WAD], "feed A publishes");
    assert!(
        cb.accepted.lock().unwrap().is_empty(),
        "feed B publishes nothing"
    );
    assert!(matches!(
        b.tick().await.unwrap(),
        TickOutcome::Idle | TickOutcome::NoQuorum(_)
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn edge_r06_both_vendors_down_nothing_is_published() {
    let (ca, cb) = (Arc::new(Chain::default()), Arc::new(Chain::default()));
    let mut a = feed("A", Vendor::new(None), ca.clone());
    let mut b = feed("B", Vendor::new(None), cb.clone());
    run(&mut [&mut a, &mut b], 1_600).await;
    assert!(ca.accepted.lock().unwrap().is_empty() && cb.accepted.lock().unwrap().is_empty());
    assert_eq!(
        ca.attempts.load(Ordering::SeqCst) + cb.attempts.load(Ordering::SeqCst),
        0,
        "not even an attempt"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn edge_r07_feeds_six_percent_apart_are_each_published_as_is() {
    let (ca, cb) = (Arc::new(Chain::default()), Arc::new(Chain::default()));
    let mut a = feed("A", Vendor::new(Some(100 * WAD)), ca.clone());
    let mut b = feed("B", Vendor::new(Some(106 * WAD)), cb.clone());
    run(&mut [&mut a, &mut b], 1_600).await;
    // > 5 %: the relayer neither blocks nor averages; the oracle adapter compares the feeds (E-O-01)
    assert_eq!(lives(&ca), vec![100 * WAD]);
    assert_eq!(lives(&cb), vec![106 * WAD]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn edge_r08_rpc_outage_at_submission_does_not_stall_the_feed() {
    let vendor = Vendor::new(Some(180 * WAD));
    let chain = Arc::new(Chain::default());
    let mut a = feed("A", vendor.clone(), chain.clone());
    run(&mut [&mut a], 1_000).await;
    assert_eq!(lives(&chain), vec![180 * WAD]);
    let seq_before = chain.accepted.lock().unwrap().last().unwrap().seq;

    // the RPC goes down while a ≥ 0.10 % move is due: submissions fail, nothing is accepted
    chain.fail.store(true, Ordering::SeqCst);
    *vendor.price_wad.lock().unwrap() = Some(181 * WAD);
    let before = chain.attempts.load(Ordering::SeqCst);
    run(&mut [&mut a], 1_000).await;
    assert!(
        chain.attempts.load(Ordering::SeqCst) > before,
        "it kept trying"
    );
    assert_eq!(lives(&chain), vec![180 * WAD]);

    // back up: the move is published, with a higher seq; the feed's seq rule never rejects it
    chain.fail.store(false, Ordering::SeqCst);
    run(&mut [&mut a], 1_200).await;
    assert_eq!(lives(&chain), vec![180 * WAD, 181 * WAD]);
    let acc = chain.accepted.lock().unwrap();
    let seqs: Vec<u64> = acc
        .iter()
        .filter(|r| r.kind == Kind::Live as u8)
        .map(|r| r.seq)
        .collect();
    assert!(seqs.windows(2).all(|w| w[1] > w[0]));
    assert!(acc.last().unwrap().seq > seq_before);
    assert!(
        acc.last().unwrap().seq - seq_before <= 64,
        "a small gap at most (OFF-01 window, QA-08 step)"
    );
}
