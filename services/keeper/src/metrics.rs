//! Keeper metrics (§16.1: "Keeper leader missing", calendar coverage, balances).

use prometheus::{GaugeVec, IntCounterVec, IntGauge, IntGaugeVec, Opts, Registry};

#[derive(Clone)]
pub struct Metrics {
    pub is_leader: IntGauge,
    pub jobs: IntCounterVec,
    pub pokes: IntCounterVec,
    pub txs: IntCounterVec,
    pub tx_replacements: IntCounterVec,
    pub rpc_failovers: IntCounterVec,
    pub calendar_coverage_days: IntGaugeVec,
    pub wallet_balance_gwei: IntGaugeVec,
    pub program_time_left: IntGaugeVec,
    pub alerts: IntCounterVec,
    /// Mined-but-reverted txs (every job pre-checks natively, so any is a bug) and sends refused by
    /// the node's gas estimate.
    pub failed_txs: IntCounterVec,
    /// Core markets whose reads revert `NoReferencePrice` (no price yet: not live, S4 A).
    pub markets_unpriced: IntGauge,
    /// Core market reads that failed for any other reason, by market.
    pub market_read_errors: IntCounterVec,
    /// Bell offsets the keeper uses, read from the AssetClock (S4 A): window / deadline lead in seconds.
    pub bell_lead_seconds: IntGaugeVec,
    // §16.1 alert inputs (S4 F)
    /// NEEDS_ACTION positions still open from bellAt + 10 min (0 otherwise), per asset: "Bell not enforced".
    pub bell_unenforced: IntGaugeVec,
    /// Seconds since the open print (net of the R-20 extension) while an asset is in REOPEN: "Reopen stuck".
    pub reopen_pending_seconds: IntGaugeVec,
    /// Seconds since reopenAt of the pool's unsettled epoch (0 before it): "Epoch not settled".
    pub epoch_unsettled_seconds: IntGaugeVec,
    /// The active epoch's utilisation u (ratio), per pool stack: "Pool utilisation".
    pub pool_utilisation: GaugeVec,
    /// Shortfalls since the book's start block that reached a loss layer beyond the pool (layer=reserve|senior).
    pub shortfall_escalations: IntGaugeVec,
}

impl Metrics {
    pub fn new(r: &Registry) -> anyhow::Result<Self> {
        let m = Self {
            is_leader: IntGauge::new(
                "keeper_is_leader",
                "1 while this instance holds the leader lock",
            )?,
            jobs: IntCounterVec::new(
                Opts::new("keeper_jobs_total", "jobs by result"),
                &["job", "result"],
            )?,
            pokes: IntCounterVec::new(
                Opts::new("keeper_pokes_total", "AssetClock.poke sent"),
                &["asset", "trigger"],
            )?,
            txs: IntCounterVec::new(
                Opts::new("keeper_txs_total", "transactions by outcome"),
                &["outcome"],
            )?,
            tx_replacements: IntCounterVec::new(
                Opts::new("keeper_tx_replacements_total", "stuck tx replaced"),
                &["job"],
            )?,
            rpc_failovers: IntCounterVec::new(
                Opts::new(
                    "keeper_rpc_failovers_total",
                    "calls served by a fallback RPC",
                ),
                &["rpc"],
            )?,
            calendar_coverage_days: IntGaugeVec::new(
                Opts::new(
                    "keeper_calendar_coverage_days",
                    "days until CalendarStore.coverageEnd",
                ),
                &["venue"],
            )?,
            wallet_balance_gwei: IntGaugeVec::new(
                Opts::new("keeper_wallet_balance_gwei", "watched wallet balances"),
                &["wallet"],
            )?,
            program_time_left: IntGaugeVec::new(
                Opts::new(
                    "keeper_stylus_program_time_left_seconds",
                    "ArbWasm programTimeLeft of each Stylus program (RB-10)",
                ),
                &["program"],
            )?,
            alerts: IntCounterVec::new(
                Opts::new("keeper_alerts_total", "alerts raised"),
                &["check", "severity"],
            )?,
            failed_txs: IntCounterVec::new(
                Opts::new(
                    "keeper_failed_txs_total",
                    "keeper txs that reverted on chain (reason=reverted) or were refused at estimation (reason=estimate)",
                ),
                &["job", "reason"],
            )?,
            markets_unpriced: IntGauge::new(
                "keeper_markets_unpriced",
                "core markets with no reference price yet (NoReferencePrice): not live, skipped",
            )?,
            market_read_errors: IntCounterVec::new(
                Opts::new(
                    "keeper_market_read_errors_total",
                    "core market reads that failed for a reason other than NoReferencePrice",
                ),
                &["market"],
            )?,
            bell_lead_seconds: IntGaugeVec::new(
                Opts::new(
                    "keeper_bell_lead_seconds",
                    "Bell offsets before the close, read from AssetClock (kind=window|deadline)",
                ),
                &["kind"],
            )?,
            bell_unenforced: IntGaugeVec::new(
                Opts::new(
                    "keeper_bell_unenforced_positions",
                    "NEEDS_ACTION positions left at or after bellAt + 10 min (§16.1 Bell not enforced)",
                ),
                &["asset"],
            )?,
            reopen_pending_seconds: IntGaugeVec::new(
                Opts::new(
                    "keeper_reopen_pending_seconds",
                    "seconds since the open print while the asset is in REOPEN (§16.1 Reopen stuck)",
                ),
                &["asset"],
            )?,
            epoch_unsettled_seconds: IntGaugeVec::new(
                Opts::new(
                    "keeper_epoch_unsettled_seconds",
                    "seconds since reopenAt of the pool's unsettled epoch (§16.1 Epoch not settled)",
                ),
                &["pool"],
            )?,
            pool_utilisation: GaugeVec::new(
                Opts::new(
                    "keeper_pool_utilisation_ratio",
                    "the active epoch's utilisation u (§16.1 Pool utilisation)",
                ),
                &["pool"],
            )?,
            shortfall_escalations: IntGaugeVec::new(
                Opts::new(
                    "keeper_shortfall_escalations",
                    "Shortfall events that reached the reserve or the senior vault since the start block",
                ),
                &["layer"],
            )?,
        };
        r.register(Box::new(m.is_leader.clone()))?;
        r.register(Box::new(m.failed_txs.clone()))?;
        r.register(Box::new(m.markets_unpriced.clone()))?;
        r.register(Box::new(m.market_read_errors.clone()))?;
        r.register(Box::new(m.bell_lead_seconds.clone()))?;
        r.register(Box::new(m.bell_unenforced.clone()))?;
        r.register(Box::new(m.reopen_pending_seconds.clone()))?;
        r.register(Box::new(m.epoch_unsettled_seconds.clone()))?;
        r.register(Box::new(m.pool_utilisation.clone()))?;
        r.register(Box::new(m.shortfall_escalations.clone()))?;
        r.register(Box::new(m.jobs.clone()))?;
        r.register(Box::new(m.pokes.clone()))?;
        r.register(Box::new(m.txs.clone()))?;
        r.register(Box::new(m.tx_replacements.clone()))?;
        r.register(Box::new(m.rpc_failovers.clone()))?;
        r.register(Box::new(m.calendar_coverage_days.clone()))?;
        r.register(Box::new(m.wallet_balance_gwei.clone()))?;
        r.register(Box::new(m.program_time_left.clone()))?;
        r.register(Box::new(m.alerts.clone()))?;
        Ok(m)
    }

    pub fn detached() -> Self {
        Self::new(&Registry::new()).expect("fresh registry")
    }
}
