//! Keeper metrics (§16.1: "Keeper leader missing", calendar coverage, balances).

use prometheus::{IntCounterVec, IntGauge, IntGaugeVec, Opts, Registry};

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
        };
        r.register(Box::new(m.is_leader.clone()))?;
        r.register(Box::new(m.failed_txs.clone()))?;
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
