//! Sprint 1 jobs.
//!
//! **J1 clock tick**: at every calendar boundary (+1 s) and every 60 s, `AssetClock.poke(asset)`.
//! Idempotency key `J1:<asset>:<boundary>` (or `J1:<asset>:hb:<minute>`). When several keys of one asset
//! are due in the same tick (e.g. after a restart), one poke covers them all: `poke` is lazy and brings
//! the clock fully up to date, so the newest key sends and the others are marked covered by it.
//!
//! **J12 housekeeping** (daily): calendar coverage < 30 days, wallet balances below the floor, and the
//! Stylus `programTimeLeft` < 30 days (ArbWasm precompile, `shared.riskEngine`). Alerts go to
//! `ALERT_WEBHOOK_URL` (PagerDuty / Opsgenie-style JSON) and the `keeper_alerts_total` metric.

use crate::{
    bindings::{venue_id, IArbWasm, IAssetClock, ICalendarStore, IRiskEngineRouter, ARB_WASM},
    clock::Clock,
    jobs::{self, Claim},
    metrics::Metrics,
    rpc::Rpc,
    schedule::{self, Tracked},
    tx::{Reconciled, TxManager},
};
use alloy::{
    primitives::{Address, Bytes},
    providers::Provider,
    sol_types::SolCall,
};
use anyhow::Result;
use sqlx::postgres::PgConnection;
use std::{collections::BTreeSet, sync::Arc};

pub const COVERAGE_ALERT_DAYS: u64 = 30;
pub const STYLUS_ALERT_DAYS: u64 = 30;

pub struct Keeper {
    pub instance: String,
    pub rpc: Arc<Rpc>,
    pub tx: TxManager,
    pub clock_addr: Address,
    pub assets: Vec<Tracked>,
    pub clock: Arc<dyn Clock>,
    pub metrics: Metrics,
    pub lookback_s: u64,
    pub alert_webhook: Option<String>,
    pub watch_wallets: Vec<(String, Address)>,
    pub min_balance_wei: u128,
    /// Stylus programs whose activation J12 watches: (label, address), e.g. ("riskEngine", shared.riskEngine).
    pub stylus_programs: Vec<(String, Address)>,
    /// Lending-core jobs (J2, J3/J4 dry-run, J8, allowlist) once a core stack is in the address book.
    pub core: Option<crate::core_jobs::SharedCore>,
    /// J7 σ updates (snapshot, committee, SigmaOracle), once the oracle is in the address book.
    pub sigma: Option<Arc<crate::sigma_runner::SigmaRunner>>,
    /// The AssetClock's Bell offsets (read at startup; the §8.2.2 defaults until then).
    pub bell: schedule::BellLeads,
    http: reqwest::Client,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TickReport {
    pub pokes: Vec<(String, String)>, // (asset label, key)
    pub covered: usize,
    pub reconciled: usize,
    pub failed: usize,
    pub alerts: Vec<String>,
}

impl Keeper {
    /// Page ops (severity `page`).
    pub(crate) async fn page(&self, check: &str, message: String, rep: &mut TickReport) {
        self.alert(check, "page", message, rep).await
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        instance: String,
        rpc: Arc<Rpc>,
        tx: TxManager,
        clock_addr: Address,
        assets: Vec<Tracked>,
        clock: Arc<dyn Clock>,
        metrics: Metrics,
        lookback_s: u64,
    ) -> Self {
        Self {
            instance,
            rpc,
            tx,
            clock_addr,
            assets,
            clock,
            metrics,
            lookback_s,
            alert_webhook: None,
            watch_wallets: Vec::new(),
            min_balance_wei: 0,
            stylus_programs: Vec::new(),
            core: None,
            sigma: None,
            bell: schedule::BellLeads::default(),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .expect("reqwest"),
        }
    }

    /// One scheduler pass. `conn` is the leader's fenced connection.
    pub async fn tick(&self, conn: &mut PgConnection) -> Result<TickReport> {
        let mut rep = TickReport::default();
        if let Err(e) = self.reconcile_submitted(conn, &mut rep).await {
            tracing::warn!(error = %e, "reconciling submitted jobs failed");
        }
        self.j1(conn, &mut rep).await?;
        if let Err(e) = self.j12(conn, &mut rep).await {
            tracing::warn!(error = %e, "J12 housekeeping failed");
        }
        if let Err(e) = self.j7(conn, &mut rep).await {
            tracing::warn!(error = %e, "J7 failed");
        }
        if let Err(e) = self.core_tick(conn, &mut rep).await {
            tracing::warn!(error = %e, "core jobs failed");
        }
        Ok(rep)
    }

    async fn j1(&self, conn: &mut PgConnection, rep: &mut TickReport) -> Result<()> {
        let now = self.clock.now();
        for a in &self.assets {
            let due = schedule::due(&a.calendar, now, self.lookback_s, self.bell);
            let mut keys: BTreeSet<(u64, String, &'static str)> = due
                .iter()
                .map(|b| (*b, schedule::j1_key(&a.id, *b), "boundary"))
                .collect();
            keys.insert((
                now / schedule::HEARTBEAT_S * schedule::HEARTBEAT_S,
                schedule::j1_heartbeat_key(&a.id, now),
                "heartbeat",
            ));
            // drop keys already done
            let mut open = Vec::new();
            for k in keys {
                if !jobs::exists(conn, &k.1).await? {
                    open.push(k);
                }
            }
            // prefer a boundary key over the heartbeat as the one that sends
            let Some(primary) = open
                .iter()
                .rev()
                .find(|k| k.2 == "boundary")
                .or_else(|| open.last())
                .cloned()
            else {
                continue;
            };
            let payload =
                serde_json::json!({ "asset": a.label, "at": primary.0, "trigger": primary.2 });
            match jobs::claim(conn, &primary.1, "J1", &payload, &self.instance).await? {
                Claim::Skip => continue,
                Claim::Reconcile => {
                    match self.tx.reconcile_job(conn, &primary.1).await? {
                        Reconciled::Mined(m) => {
                            jobs::mark(
                                conn,
                                &primary.1,
                                if m.success { "done" } else { "failed" },
                                None,
                            )
                            .await?;
                            rep.reconciled += 1;
                        }
                        Reconciled::Pending => {}
                        Reconciled::Dropped => {
                            jobs::mark(conn, &primary.1, "failed", Some("tx dropped")).await?
                        }
                    }
                    continue;
                }
                Claim::Run { .. } => {}
            }
            let data = Bytes::from(IAssetClock::pokeCall { assetId: a.id }.abi_encode());
            match self.tx.send(conn, &primary.1, self.clock_addr, data).await {
                Ok(m) if m.success => {
                    jobs::mark(conn, &primary.1, "done", None).await?;
                    let others: Vec<String> = open
                        .iter()
                        .filter(|k| k.1 != primary.1)
                        .map(|k| k.1.clone())
                        .collect();
                    jobs::mark_covered(conn, &others, "J1", &primary.1, &self.instance).await?;
                    rep.covered += others.len();
                    rep.pokes.push((a.label.clone(), primary.1.clone()));
                    self.metrics
                        .pokes
                        .with_label_values(&[&a.label, primary.2])
                        .inc();
                    self.metrics.jobs.with_label_values(&["J1", "done"]).inc();
                    tracing::info!(asset = %a.label, key = %primary.1, tx = %m.hash, block = m.block, "poked");
                }
                Ok(m) => {
                    jobs::mark(
                        conn,
                        &primary.1,
                        "failed",
                        Some(&format!("reverted in {}", m.hash)),
                    )
                    .await?;
                    rep.failed += 1;
                    self.metrics
                        .jobs
                        .with_label_values(&["J1", "reverted"])
                        .inc();
                    self.metrics
                        .failed_txs
                        .with_label_values(&["J1", "reverted"])
                        .inc();
                }
                Err(e) => {
                    // a tx that timed out stays `submitted` and is reconciled next tick
                    let submitted: bool = sqlx::query_scalar(
                        "select status = 'submitted' from ops.keeper_job where key = $1",
                    )
                    .bind(&primary.1)
                    .fetch_one(&mut *conn)
                    .await
                    .unwrap_or(false);
                    if !submitted {
                        jobs::mark(conn, &primary.1, "failed", Some(&e.to_string())).await?;
                    }
                    rep.failed += 1;
                    self.metrics.jobs.with_label_values(&["J1", "error"]).inc();
                    tracing::warn!(asset = %a.label, key = %primary.1, error = %e, "poke failed");
                }
            }
        }
        Ok(())
    }

    pub(crate) async fn alert(
        &self,
        check: &str,
        severity: &str,
        message: String,
        rep: &mut TickReport,
    ) {
        self.metrics
            .alerts
            .with_label_values(&[check, severity])
            .inc();
        tracing::warn!(check, severity, %message, "ALERT");
        rep.alerts.push(format!("{check}: {message}"));
        if let Some(url) = &self.alert_webhook {
            let body = serde_json::json!({ "source": "credence-keeper", "instance": self.instance, "check": check, "severity": severity, "message": message });
            if let Err(e) = self.http.post(url).json(&body).send().await {
                tracing::error!(error = %e, "alert webhook failed");
            }
        }
    }

    /// J12: each check runs on its own, so one failing read (an RPC hiccup, an undeployed contract)
    /// never hides the others.
    async fn j12(&self, conn: &mut PgConnection, rep: &mut TickReport) -> Result<()> {
        let now = self.clock.now();
        if let Err(e) = self.j12_calendar(conn, rep, now).await {
            tracing::warn!(error = %e, "J12 calendar coverage failed");
        }
        if let Err(e) = self.j12_wallets(conn, rep, now).await {
            tracing::warn!(error = %e, "J12 wallet balances failed");
        }
        self.j12_stylus(conn, rep, now).await
    }

    async fn j12_calendar(
        &self,
        conn: &mut PgConnection,
        rep: &mut TickReport,
        now: u64,
    ) -> Result<()> {
        if self.assets.is_empty() {
            return Ok(());
        }
        // calendar coverage, per venue, from the on-chain CalendarStore
        let key = schedule::j12_key("calendar-coverage", now);
        if matches!(
            jobs::claim(conn, &key, "J12", &serde_json::json!({}), &self.instance).await?,
            Claim::Run { .. }
        ) {
            let clock = self.clock_addr;
            let calendar = self
                .rpc
                .with_failover("clock.calendar", |p| async move {
                    Ok(IAssetClock::new(clock, p).calendar().call().await?)
                })
                .await?;
            let venues: BTreeSet<String> = self.assets.iter().map(|a| a.venue.clone()).collect();
            for v in venues {
                let vid = venue_id(&v);
                let end = self
                    .rpc
                    .with_failover("coverageEnd", |p| async move {
                        Ok(ICalendarStore::new(calendar, p)
                            .coverageEnd(vid)
                            .call()
                            .await?)
                    })
                    .await?
                    .to::<u64>();
                let days = end.saturating_sub(now) / 86_400;
                self.metrics
                    .calendar_coverage_days
                    .with_label_values(&[&v])
                    .set(days as i64);
                if days < COVERAGE_ALERT_DAYS {
                    self.alert(
                        "calendar-coverage",
                        "P2",
                        format!("{v} calendar covers only {days} more days (RB-08)"),
                        rep,
                    )
                    .await;
                }
            }
            jobs::mark(conn, &key, "done", None).await?;
        }

        Ok(())
    }

    async fn j12_wallets(
        &self,
        conn: &mut PgConnection,
        rep: &mut TickReport,
        now: u64,
    ) -> Result<()> {
        // wallet balances (keeper sender + watched relayer wallets)
        let key = schedule::j12_key("wallet-balances", now);
        if matches!(
            jobs::claim(conn, &key, "J12", &serde_json::json!({}), &self.instance).await?,
            Claim::Run { .. }
        ) {
            let mut wallets = vec![("keeper".to_owned(), self.tx.sender)];
            wallets.extend(self.watch_wallets.iter().cloned());
            for (label, addr) in wallets {
                let bal = self
                    .rpc
                    .with_failover("balance", |p| async move { Ok(p.get_balance(addr).await?) })
                    .await?;
                let wei: u128 = bal.try_into().unwrap_or(u128::MAX);
                self.metrics
                    .wallet_balance_gwei
                    .with_label_values(&[&label])
                    .set((wei / 1_000_000_000).min(i64::MAX as u128) as i64);
                if wei < self.min_balance_wei {
                    self.alert(
                        "wallet-balance",
                        "P2",
                        format!("{label} {addr} has {wei} wei (< {})", self.min_balance_wei),
                        rep,
                    )
                    .await;
                }
            }
            jobs::mark(conn, &key, "done", None).await?;
        }

        Ok(())
    }

    async fn j12_stylus(
        &self,
        conn: &mut PgConnection,
        rep: &mut TickReport,
        now: u64,
    ) -> Result<()> {
        // Stylus programTimeLeft (RB-10): ArbWasm reverts ProgramNotActivated for an expired program
        let key = schedule::j12_key("stylus-program-time-left", now);
        if matches!(
            jobs::claim(conn, &key, "J12", &serde_json::json!({}), &self.instance).await?,
            Claim::Run { .. }
        ) {
            if self.stylus_programs.is_empty() {
                jobs::mark(
                    conn,
                    &key,
                    "skipped",
                    Some("no Stylus program in the address book"),
                )
                .await?;
            } else {
                for (label, program) in self.stylus_targets().await {
                    let left = self
                        .rpc
                        .with_failover("programTimeLeft", |p| async move {
                            Ok(IArbWasm::new(ARB_WASM, p)
                                .programTimeLeft(program)
                                .call()
                                .await?)
                        })
                        .await;
                    let secs = match left {
                        Ok(s) => s,
                        Err(e) => {
                            // not activated (or expired): time left is zero
                            tracing::warn!(program = %program, error = %e, "programTimeLeft failed");
                            0
                        }
                    };
                    self.metrics
                        .program_time_left
                        .with_label_values(&[&label])
                        .set(secs.min(i64::MAX as u64) as i64);
                    let days = secs / 86_400;
                    if days < STYLUS_ALERT_DAYS {
                        self.alert(
                            "stylus-activation",
                            "P2",
                            format!("{label} {program}: programTimeLeft {days} days (RB-10: cargo stylus activate)"),
                            rep,
                        )
                        .await;
                    }
                }
                jobs::mark(conn, &key, "done", None).await?;
            }
        }
        Ok(())
    }

    /// The Stylus programs J12 watches. `shared.riskEngine` is the Solidity RiskEngineRouter (R-24, ADR-0108),
    /// not a program: ArbWasm answers `ProgramNotActivated` for it, which raised a false RB-10 alert
    /// ("programTimeLeft 0 days") in the S3 run. A configured address that is not a program but answers the
    /// router's `pricing()` / `auction()` is replaced by those two programs; anything else is checked as is.
    pub(crate) async fn stylus_targets(&self) -> Vec<(String, Address)> {
        let mut out = Vec::new();
        for (label, addr) in &self.stylus_programs {
            let addr = *addr;
            let is_program = self
                .rpc
                .with_failover("programVersion", |p| async move {
                    Ok(IArbWasm::new(ARB_WASM, p)
                        .programVersion(addr)
                        .call()
                        .await?)
                })
                .await
                .is_ok();
            let routed = if is_program {
                None
            } else {
                self.rpc
                    .with_failover("router.programs", |p| async move {
                        let r = IRiskEngineRouter::new(addr, &p);
                        Ok((r.pricing().call().await?, r.auction().call().await?))
                    })
                    .await
                    .ok()
                    .filter(|(a, b)| !a.is_zero() && !b.is_zero())
            };
            match routed {
                Some((pricing, auction)) => {
                    out.push((format!("{label}.pricing"), pricing));
                    out.push((format!("{label}.auctionMath"), auction));
                }
                None => out.push((label.clone(), addr)),
            }
        }
        out
    }
}
