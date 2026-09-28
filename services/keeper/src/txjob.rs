//! One transaction per idempotency key, restart-safe (§10.2 operational rules).
//!
//! `tx_job` claims the key and then:
//! * **Run**: builds the calldata (the job's native pre-check happens before this) and sends it; the tx
//!   is written ahead to `ops.keeper_tx` before broadcast (`TxManager::send`);
//! * **Reconcile**: a previous leader (or this process before a restart) broadcast a tx for the key:
//!   its receipt decides, it is never re-sent blindly; a dropped tx makes the key retryable;
//! * **Skip**: done, backing off, or out of attempts.
//!
//! A send that times out leaves the key `submitted` for the next tick's reconciliation. A mined tx that
//! reverted is a keeper bug (every job pre-checks natively): it is counted in
//! `keeper_failed_txs_total{reason="reverted"}` and alerted on.

use alloy::primitives::{Address, Bytes};
use anyhow::Result;
use serde_json::Value;
use sqlx::postgres::PgConnection;

use crate::{
    jobs::{self, Claim},
    tasks::{Keeper, TickReport},
    tx::{Mined, Reconciled},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TxJob {
    /// Mined successfully (now or, for a reconciled key, earlier).
    Done(Mined),
    /// Broadcast and not mined yet: the next tick reconciles it.
    Pending,
    /// Nothing to do for this key now.
    Skipped,
    /// Reverted, refused at estimation, or dropped; retried with back-off.
    Failed(String),
}

impl TxJob {
    pub fn is_done(&self) -> bool {
        matches!(self, TxJob::Done(_))
    }
}

fn job_label(key: &str) -> &str {
    key.split(':').next().unwrap_or("?")
}

impl Keeper {
    /// Claim `key` and send `data` to `to` once (see the module docs). `data` is only built when the
    /// key actually runs.
    pub async fn tx_job(
        &self,
        conn: &mut PgConnection,
        key: &str,
        payload: &Value,
        to: Address,
        data: impl FnOnce() -> Result<Bytes>,
        rep: &mut TickReport,
    ) -> Result<TxJob> {
        match jobs::claim(conn, key, job_label(key), payload, &self.instance).await? {
            Claim::Skip => Ok(TxJob::Skipped),
            Claim::Reconcile => self.reconcile_key(conn, key, rep).await,
            Claim::Run { .. } => {
                let data = match data() {
                    Ok(d) => d,
                    Err(e) => {
                        jobs::mark(conn, key, "failed", Some(&e.to_string())).await?;
                        return Ok(TxJob::Failed(e.to_string()));
                    }
                };
                self.send_key(conn, key, to, data, rep).await
            }
        }
    }

    /// Reconcile every key left `submitted` (by a killed process or a timed-out send), whether or not
    /// its job is still due. Run at the start of every tick; usually a no-op.
    pub async fn reconcile_submitted(
        &self,
        conn: &mut PgConnection,
        rep: &mut TickReport,
    ) -> Result<()> {
        let keys: Vec<String> = sqlx::query_scalar(
            "select key from ops.keeper_job where status = 'submitted' order by updated_at limit 50",
        )
        .fetch_all(&mut *conn)
        .await?;
        for k in keys {
            let r = self.reconcile_key(conn, &k, rep).await?;
            tracing::info!(key = %k, result = ?r, "reconciled a submitted job");
        }
        Ok(())
    }

    /// Reconcile a key left `submitted`.
    pub async fn reconcile_key(
        &self,
        conn: &mut PgConnection,
        key: &str,
        rep: &mut TickReport,
    ) -> Result<TxJob> {
        match self.tx.reconcile_job(conn, key).await? {
            Reconciled::Mined(m) => {
                rep.reconciled += 1;
                self.finish(conn, key, m, rep).await
            }
            Reconciled::Pending => Ok(TxJob::Pending),
            Reconciled::Dropped => {
                jobs::mark(conn, key, "failed", Some("tx dropped")).await?;
                Ok(TxJob::Failed("tx dropped".into()))
            }
        }
    }

    async fn finish(
        &self,
        conn: &mut PgConnection,
        key: &str,
        m: Mined,
        rep: &mut TickReport,
    ) -> Result<TxJob> {
        if m.success {
            jobs::mark(conn, key, "done", None).await?;
            self.metrics
                .jobs
                .with_label_values(&[job_label(key), "done"])
                .inc();
            return Ok(TxJob::Done(m));
        }
        rep.failed += 1;
        self.metrics
            .failed_txs
            .with_label_values(&[job_label(key), "reverted"])
            .inc();
        let msg = format!("reverted in {}", m.hash);
        tracing::error!(key, tx = %m.hash, "keeper tx REVERTED (the native pre-check disagreed with the chain)");
        jobs::mark(conn, key, "failed", Some(&msg)).await?;
        Ok(TxJob::Failed(msg))
    }

    async fn send_key(
        &self,
        conn: &mut PgConnection,
        key: &str,
        to: Address,
        data: Bytes,
        rep: &mut TickReport,
    ) -> Result<TxJob> {
        match self.tx.send(conn, key, to, data).await {
            Ok(m) => self.finish(conn, key, m, rep).await,
            Err(e) => {
                let msg = format!("{e:#}");
                if jobs::status(conn, key).await?.as_deref() == Some("submitted") {
                    // broadcast but not mined in time: reconciled next tick, never re-sent
                    tracing::warn!(key, error = %msg, "tx not mined yet: left for reconciliation");
                    return Ok(TxJob::Pending);
                }
                if msg.contains("estimate_gas") {
                    self.metrics
                        .failed_txs
                        .with_label_values(&[job_label(key), "estimate"])
                        .inc();
                }
                rep.failed += 1;
                jobs::mark(conn, key, "failed", Some(&msg)).await?;
                tracing::warn!(key, error = %msg, "keeper tx not sent");
                Ok(TxJob::Failed(msg))
            }
        }
    }
}
