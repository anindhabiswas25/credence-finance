//! The aggregator of one feed (§10.1). Every tick it collects the nodes' observations, proposes the
//! median per asset, applies the cadence rules, gets ≥ threshold signatures on one batch, and submits
//! all assets in **one** `submit` transaction. Every signed report is persisted before submission.

use crate::{
    cadence::{AssetCadence, CadenceConfig},
    chain::{FeedChain, SubmitOutcome},
    metrics::Metrics,
    node::{Node, SignResponse},
    ocr::{choose_quorum, propose_asset, Draft, NodeSnapshot},
    price::rel_diff_ppm,
    report::{report, sorted_signatures, Kind, MarketStatus, Report, ReportDto},
    store::ReportStore,
};
use alloy::primitives::{Address, Bytes, Signature, B256};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use std::{collections::HashMap, sync::Arc, time::Duration};

/// How the aggregator reaches a signer node.
#[async_trait]
pub trait NodeClient: Send + Sync {
    fn name(&self) -> String;
    async fn observations(&self) -> Result<NodeSnapshot>;
    async fn sign(&self, reports: &[ReportDto]) -> Result<SignResponse>;
}

/// In-process node (all-in-one dev mode and tests).
pub struct LocalNode(pub Arc<Node>);

#[async_trait]
impl NodeClient for LocalNode {
    fn name(&self) -> String {
        self.0.cfg.id.clone()
    }
    async fn observations(&self) -> Result<NodeSnapshot> {
        Ok(self.0.snapshot().await)
    }
    async fn sign(&self, reports: &[ReportDto]) -> Result<SignResponse> {
        Ok(self.0.sign(reports).await)
    }
}

/// Node over HTTP (production topology: separate hosts / accounts).
pub struct HttpNode {
    pub url: String,
    pub token: Option<String>,
    http: reqwest::Client,
}

impl HttpNode {
    pub fn new(url: String, token: Option<String>) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_millis(1500))
            .build()
            .expect("reqwest");
        Self { url, token, http }
    }
    fn req(&self, r: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match &self.token {
            Some(t) => r.bearer_auth(t),
            None => r,
        }
    }
}

#[async_trait]
impl NodeClient for HttpNode {
    fn name(&self) -> String {
        self.url.clone()
    }
    async fn observations(&self) -> Result<NodeSnapshot> {
        let r = self
            .req(self.http.get(format!("{}/v1/observations", self.url)))
            .send()
            .await?
            .error_for_status()?;
        Ok(r.json().await?)
    }
    async fn sign(&self, reports: &[ReportDto]) -> Result<SignResponse> {
        let body = serde_json::json!({ "reports": reports });
        let r = self
            .req(self.http.post(format!("{}/v1/sign", self.url)).json(&body))
            .send()
            .await?
            .error_for_status()?;
        Ok(r.json().await?)
    }
}

#[derive(Debug, Clone)]
pub struct AggregatorConfig {
    pub feed: String,
    pub threshold: usize,
    pub tick: Duration,
    /// Committee addresses, if known: signatures from other addresses are ignored.
    pub committee: Option<Vec<Address>>,
    pub assets: Vec<(B256, String)>, // id, symbol (metrics labels)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TickOutcome {
    Idle,
    NoQuorum(String),
    Submitted {
        reports: usize,
        outcome: SubmitOutcome,
    },
}

pub struct Aggregator {
    cfg: AggregatorConfig,
    nodes: Vec<Arc<dyn NodeClient>>,
    chain: Arc<dyn FeedChain>,
    store: Arc<dyn ReportStore>,
    metrics: Metrics,
    cadence: HashMap<B256, AssetCadence>,
    cadence_cfg: CadenceConfig,
    next_seq: HashMap<B256, u64>,
    clock: fn() -> u64,
}

impl Aggregator {
    pub fn new(
        cfg: AggregatorConfig,
        nodes: Vec<Arc<dyn NodeClient>>,
        chain: Arc<dyn FeedChain>,
        store: Arc<dyn ReportStore>,
        metrics: Metrics,
    ) -> Self {
        let tick_s = cfg.tick.as_secs().max(1);
        Self {
            cfg,
            nodes,
            chain,
            store,
            metrics,
            cadence_cfg: CadenceConfig {
                tick_s,
                ..Default::default()
            },
            cadence: HashMap::new(),
            next_seq: HashMap::new(),
            clock: crate::node::now_s,
        }
    }

    pub fn with_clock(mut self, clock: fn() -> u64) -> Self {
        self.clock = clock;
        self
    }

    /// Heartbeats, age limits and coalescing (the tick is taken from the aggregator's config).
    pub fn with_cadence(mut self, c: CadenceConfig) -> Self {
        self.cadence_cfg = CadenceConfig {
            tick_s: self.cadence_cfg.tick_s,
            ..c
        };
        self
    }

    fn symbol(&self, id: &B256) -> String {
        self.cfg
            .assets
            .iter()
            .find(|(a, _)| a == id)
            .map(|(_, s)| s.clone())
            .unwrap_or_else(|| id.to_string())
    }

    /// Seq high-water mark per asset: max(chain, db) + 1. Called at start and after a stale-seq reject.
    pub async fn sync_seqs(&mut self) -> Result<()> {
        let db = self.store.max_seqs(&self.cfg.feed).await?;
        for (id, _) in self.cfg.assets.clone() {
            let chain = self.chain.latest_seq(id).await?;
            let next = chain.max(db.get(&id).copied().unwrap_or(0)) + 1;
            self.next_seq.insert(id, next);
        }
        Ok(())
    }

    async fn collect(&self) -> Vec<NodeSnapshot> {
        let futs = self.nodes.iter().map(|n| {
            let n = n.clone();
            async move {
                (
                    n.name(),
                    tokio::time::timeout(Duration::from_secs(2), n.observations()).await,
                )
            }
        });
        futures::future::join_all(futs)
            .await
            .into_iter()
            .filter_map(|(name, r)| match r {
                Ok(Ok(s)) => Some(s),
                Ok(Err(e)) => {
                    tracing::warn!(node = %name, error = %e, "observations failed");
                    None
                }
                Err(_) => {
                    tracing::warn!(node = %name, "observations timed out");
                    None
                }
            })
            .collect()
    }

    /// Drafts due now under the cadence rules, in batch order (STATUS, OPEN, CLOSE, LIVE per asset). Once anything
    /// is due, LIVE and STATUS reports due within `coalesce_s` join the batch (one transaction for every asset).
    fn due_drafts(&self, snaps: &[NodeSnapshot], now: u64) -> Vec<Draft> {
        let all: Vec<(Draft, AssetCadence)> = self
            .cfg
            .assets
            .iter()
            .flat_map(|(id, _)| {
                let cad = self.cadence.get(id).cloned().unwrap_or_default();
                let mut drafts = propose_asset(*id, snaps, self.cfg.threshold);
                drafts.sort_by_key(|d| match d.kind {
                    Kind::Status => 0,
                    Kind::Open => 1,
                    Kind::Close => 2,
                    Kind::Live => 3,
                    Kind::Nav => 4,
                });
                drafts.into_iter().map(move |d| (d, cad.clone()))
            })
            .collect();
        let c = &self.cadence_cfg;
        let due = |d: &Draft, cad: &AssetCadence, lead: u64| match d.kind {
            Kind::Status => cad.status_due_with(c, d.status, now, lead),
            Kind::Live => cad.live_due_with(c, d.status, d.price_wad, now, lead),
            Kind::Open => cad.open_due(d.session_date),
            Kind::Close => cad.close_due(d.session_date),
            Kind::Nav => false,
        };
        let lead = if all.iter().any(|(d, cad)| due(d, cad, 0)) {
            c.coalesce_s
        } else {
            return Vec::new();
        };
        all.into_iter()
            .filter(|(d, cad)| due(d, cad, lead))
            .map(|(d, _)| d)
            .collect()
    }

    fn node_spread(&self, snaps: &[NodeSnapshot]) {
        for (id, sym) in &self.cfg.assets {
            let prices: Vec<u128> = snaps
                .iter()
                .filter_map(|s| {
                    s.assets
                        .iter()
                        .find(|a| a.asset_id == *id)?
                        .live
                        .as_ref()
                        .map(|l| l.price_wad)
                })
                .collect();
            if let (Some(lo), Some(hi)) = (prices.iter().min(), prices.iter().max()) {
                let ppm = rel_diff_ppm(*lo, *hi).min(i64::MAX as u128) as i64;
                self.metrics
                    .node_spread_ppm
                    .with_label_values(&[&self.cfg.feed, sym])
                    .set(ppm);
            }
        }
    }

    fn assign_seqs(&mut self, drafts: &[Draft]) -> Vec<Report> {
        drafts
            .iter()
            .map(|d| {
                let seq = self.next_seq.entry(d.asset_id).or_insert(1);
                let r = report(
                    d.asset_id,
                    d.kind,
                    d.price_wad,
                    d.observed_at,
                    d.session_date,
                    d.status,
                    *seq,
                );
                *seq += 1;
                r
            })
            .collect()
    }

    async fn request_signatures(
        &self,
        reports: &[Report],
        only: Option<&[usize]>,
    ) -> Vec<(usize, Result<SignResponse>)> {
        let dtos: Vec<ReportDto> = reports.iter().map(ReportDto::from).collect();
        let futs = self
            .nodes
            .iter()
            .enumerate()
            .filter(|(i, _)| only.is_none_or(|o| o.contains(i)))
            .map(|(i, n)| {
                let n = n.clone();
                let dtos = dtos.clone();
                async move {
                    let r = tokio::time::timeout(Duration::from_secs(3), n.sign(&dtos))
                        .await
                        .map_err(|_| anyhow!("sign timed out"))
                        .and_then(|r| r);
                    (i, r)
                }
            });
        futures::future::join_all(futs).await
    }

    fn valid_signatures(
        &self,
        reports: &[Report],
        resps: &[(usize, Result<SignResponse>)],
    ) -> Vec<(Address, Signature)> {
        let digest_ok = |resp: &SignResponse| -> Option<(Address, Signature)> {
            let sig = Signature::try_from(resp.signature.as_ref()?.as_ref()).ok()?;
            Some((resp.signer, sig))
        };
        let _ = reports;
        resps
            .iter()
            .filter_map(|(_, r)| r.as_ref().ok())
            .filter_map(digest_ok)
            .filter(|(a, _)| self.cfg.committee.as_ref().is_none_or(|c| c.contains(a)))
            .collect()
    }

    /// One tick: collect → propose → sign → submit → persist.
    pub async fn tick(&mut self) -> Result<TickOutcome> {
        let started = std::time::Instant::now();
        let now = (self.clock)();
        let snaps = self.collect().await;
        if snaps.len() < self.cfg.threshold {
            self.metrics
                .submits
                .with_label_values(&[&self.cfg.feed, "no_quorum"])
                .inc();
            return Ok(TickOutcome::NoQuorum(format!(
                "{} of {} nodes answered",
                snaps.len(),
                self.nodes.len()
            )));
        }
        self.node_spread(&snaps);
        let drafts = self.due_drafts(&snaps, now);
        if drafts.is_empty() {
            return Ok(TickOutcome::Idle);
        }
        if self.next_seq.is_empty() {
            self.sync_seqs().await?;
        }

        // Round 1: every node checks the full batch.
        let mut reports = self.assign_seqs(&drafts);
        let resps = self.request_signatures(&reports, None).await;
        let mut sigs = self.valid_signatures(&reports, &resps);

        if sigs.len() < self.cfg.threshold {
            // Round 2: keep the largest sub-batch a quorum accepts, re-sign it with that quorum.
            let answered: Vec<(usize, &SignResponse)> = resps
                .iter()
                .filter_map(|(i, r)| r.as_ref().ok().map(|r| (*i, r)))
                .collect();
            let accepts: Vec<Vec<bool>> = answered
                .iter()
                .map(|(_, r)| {
                    (0..reports.len())
                        .map(|k| !r.refused.iter().any(|(i, _)| *i == k))
                        .collect()
                })
                .collect();
            let Some((node_idx, keep)) = choose_quorum(&accepts, self.cfg.threshold) else {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "no_quorum"])
                    .inc();
                for (i, r) in &answered {
                    tracing::info!(node = %self.nodes[*i].name(), refused = ?r.refused, "node refused");
                }
                return Ok(TickOutcome::NoQuorum(
                    "no quorum agrees on any report".into(),
                ));
            };
            reports = keep.iter().map(|&k| reports[k].clone()).collect();
            let chosen: Vec<usize> = node_idx.iter().map(|&j| answered[j].0).collect();
            let resps = self.request_signatures(&reports, Some(&chosen)).await;
            sigs = self.valid_signatures(&reports, &resps);
            if sigs.len() < self.cfg.threshold {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "no_quorum"])
                    .inc();
                return Ok(TickOutcome::NoQuorum(
                    "quorum did not sign the reduced batch".into(),
                ));
            }
        }

        let sorted = sorted_signatures(sigs);
        let signers: Vec<Address> = sorted.iter().map(|(a, _)| *a).collect();
        let sig_bytes: Vec<Bytes> = sorted.into_iter().map(|(_, s)| s).collect();
        self.store
            .record_signed(&self.cfg.feed, &reports, &signers)
            .await?;

        let outcome = match self.chain.submit(&reports, sig_bytes).await {
            Ok(o) => o,
            Err(e) => {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "error"])
                    .inc();
                self.store
                    .record_outcome(&self.cfg.feed, &reports, None, "rejected")
                    .await
                    .ok();
                return Err(e);
            }
        };
        match &outcome {
            SubmitOutcome::Accepted { tx_hash, .. } => {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "ok"])
                    .inc();
                self.store
                    .record_outcome(&self.cfg.feed, &reports, Some(*tx_hash), "accepted")
                    .await?;
                self.on_accepted(&reports, now).await;
            }
            SubmitOutcome::Reverted { tx_hash, .. } => {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "reverted"])
                    .inc();
                self.store
                    .record_outcome(&self.cfg.feed, &reports, Some(*tx_hash), "rejected")
                    .await?;
                self.sync_seqs().await.ok();
            }
            SubmitOutcome::Rejected { reason } => {
                self.metrics
                    .submits
                    .with_label_values(&[&self.cfg.feed, "reverted"])
                    .inc();
                tracing::warn!(feed = %self.cfg.feed, %reason, "submit rejected at estimation");
                self.store
                    .record_outcome(&self.cfg.feed, &reports, None, "rejected")
                    .await?;
                self.sync_seqs().await.ok();
            }
        }
        self.metrics
            .tick_latency
            .observe(started.elapsed().as_secs_f64());
        Ok(TickOutcome::Submitted {
            reports: reports.len(),
            outcome,
        })
    }

    async fn on_accepted(&mut self, reports: &[Report], now: u64) {
        let wall = crate::node::now_s();
        for r in reports {
            let kind = Kind::from_u8(r.kind).unwrap_or(Kind::Nav);
            let status = MarketStatus::from_u8(r.marketStatus).unwrap_or(MarketStatus::Closed);
            let c = self.cadence.entry(r.assetId).or_default();
            match kind {
                Kind::Live => c.mark_live(r.price, now, status, r.observedAt.to::<u64>()),
                Kind::Status => c.mark_status(status, now),
                Kind::Open => {
                    c.opens.insert(r.sessionDate.to::<u64>());
                }
                Kind::Close => {
                    c.closes.insert(r.sessionDate.to::<u64>());
                }
                Kind::Nav => {}
            }
            let latency = wall.saturating_sub(r.observedAt.to::<u64>()) as f64;
            self.metrics
                .report_latency
                .with_label_values(&[&self.cfg.feed, kind.label()])
                .observe(latency);
            self.metrics
                .reports_accepted
                .with_label_values(&[&self.cfg.feed, kind.label()])
                .inc();
            let sym = self.symbol(&r.assetId);
            self.metrics
                .last_seq
                .with_label_values(&[&self.cfg.feed, &sym])
                .set(r.seq as i64);
            if matches!(kind, Kind::Live | Kind::Status) {
                self.metrics
                    .market_status
                    .with_label_values(&[&self.cfg.feed, &sym])
                    .set(r.marketStatus as i64);
            }
            if kind == Kind::Live {
                self.metrics
                    .last_live_at
                    .with_label_values(&[&self.cfg.feed, &sym])
                    .set(r.observedAt.to::<u64>() as i64);
                if let Ok(Some(other)) = self.chain.other_feed_latest(r.assetId).await {
                    if other > 0 {
                        let ppm = rel_diff_ppm(r.price, other).min(i64::MAX as u128) as i64;
                        self.metrics
                            .vendor_disagreement_ppm
                            .with_label_values(&[&self.cfg.feed, &sym])
                            .set(ppm);
                    }
                }
            }
        }
    }

    /// Tick forever.
    pub async fn run(mut self, ready: credence_common::ops::OpsState) {
        let mut tick = tokio::time::interval(self.cfg.tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            match self.tick().await {
                Ok(TickOutcome::Submitted { reports, outcome }) => {
                    ready.set_ready(matches!(outcome, SubmitOutcome::Accepted { .. }));
                    tracing::info!(feed = %self.cfg.feed, reports, ?outcome, "tick");
                }
                Ok(TickOutcome::Idle) => ready.set_ready(true),
                Ok(TickOutcome::NoQuorum(why)) => {
                    ready.set_ready(false);
                    tracing::warn!(feed = %self.cfg.feed, %why, "no quorum");
                }
                Err(e) => {
                    ready.set_ready(false);
                    tracing::error!(feed = %self.cfg.feed, error = %e, "tick failed");
                }
            }
        }
    }
}
