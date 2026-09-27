//! Relayer metrics (§10.1, §16.1): report latency, disagreement between nodes and between vendors
//! (feed A vs feed B), and the submit success rate.

use prometheus::{
    exponential_buckets, Histogram, HistogramOpts, HistogramVec, IntCounterVec, IntGaugeVec, Opts, Registry,
};

#[derive(Clone)]
pub struct Metrics {
    /// Seconds from the print's exchange time to on-chain acceptance, by kind.
    pub report_latency: HistogramVec,
    /// Seconds from tick start to the mined submit.
    pub tick_latency: Histogram,
    /// submits by result: ok | reverted | error | no_quorum.
    pub submits: IntCounterVec,
    /// reports accepted on-chain, by kind.
    pub reports_accepted: IntCounterVec,
    /// max−min spread of the nodes' LIVE observations, ppm, per asset.
    pub node_spread_ppm: IntGaugeVec,
    /// |this feed − other feed| / min, ppm, per asset (vendor A vs vendor B).
    pub vendor_disagreement_ppm: IntGaugeVec,
    /// vendor call failures by vendor and error kind.
    pub vendor_errors: IntCounterVec,
    /// observations rejected by the filter, by reason.
    pub rejections: IntCounterVec,
    /// node signature refusals, by reason.
    pub refusals: IntCounterVec,
    /// last seq submitted per asset.
    pub last_seq: IntGaugeVec,
}

impl Metrics {
    pub fn new(registry: &Registry) -> anyhow::Result<Self> {
        let m = Self {
            report_latency: HistogramVec::new(
                HistogramOpts::new("relayer_report_latency_seconds", "exchange time → on-chain acceptance")
                    .buckets(exponential_buckets(0.25, 2.0, 12)?),
                &["feed", "kind"],
            )?,
            tick_latency: Histogram::with_opts(
                HistogramOpts::new("relayer_tick_seconds", "aggregator tick: collect → sign → mined")
                    .buckets(exponential_buckets(0.05, 2.0, 12)?),
            )?,
            submits: IntCounterVec::new(Opts::new("relayer_submits_total", "submit transactions by result"), &["feed", "result"])?,
            reports_accepted: IntCounterVec::new(
                Opts::new("relayer_reports_accepted_total", "reports accepted on-chain"),
                &["feed", "kind"],
            )?,
            node_spread_ppm: IntGaugeVec::new(
                Opts::new("relayer_node_spread_ppm", "spread of node LIVE observations"),
                &["feed", "asset"],
            )?,
            vendor_disagreement_ppm: IntGaugeVec::new(
                Opts::new("relayer_vendor_disagreement_ppm", "this feed vs the other feed on-chain"),
                &["feed", "asset"],
            )?,
            vendor_errors: IntCounterVec::new(
                Opts::new("relayer_vendor_errors_total", "vendor call failures"),
                &["vendor", "kind"],
            )?,
            rejections: IntCounterVec::new(
                Opts::new("relayer_observation_rejections_total", "filtered observations"),
                &["node", "reason"],
            )?,
            refusals: IntCounterVec::new(Opts::new("relayer_sign_refusals_total", "node refusals"), &["node", "reason"])?,
            last_seq: IntGaugeVec::new(Opts::new("relayer_last_seq", "last submitted seq"), &["feed", "asset"])?,
        };
        registry.register(Box::new(m.report_latency.clone()))?;
        registry.register(Box::new(m.tick_latency.clone()))?;
        registry.register(Box::new(m.submits.clone()))?;
        registry.register(Box::new(m.reports_accepted.clone()))?;
        registry.register(Box::new(m.node_spread_ppm.clone()))?;
        registry.register(Box::new(m.vendor_disagreement_ppm.clone()))?;
        registry.register(Box::new(m.vendor_errors.clone()))?;
        registry.register(Box::new(m.rejections.clone()))?;
        registry.register(Box::new(m.refusals.clone()))?;
        registry.register(Box::new(m.last_seq.clone()))?;
        Ok(m)
    }

    /// Unregistered metrics (tests).
    pub fn detached() -> Self {
        Self::new(&Registry::new()).expect("fresh registry")
    }
}

/// Short label for an error enum variant.
pub fn kind_label(e: &crate::vendor::VendorError) -> &'static str {
    use crate::vendor::VendorError::*;
    match e {
        NotEntitled { .. } => "not_entitled",
        Unauthorized { .. } => "unauthorized",
        RateLimited { .. } => "rate_limited",
        Http { .. } => "http",
        Parse { .. } => "parse",
        Other(_) => "other",
    }
}
