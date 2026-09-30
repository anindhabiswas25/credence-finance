//! `ops.keeper_job`: one row per idempotency key (§10.2 table). Every write goes through the leader's
//! fenced connection (see `leader`).
//!
//! Lifecycle: `running` (claimed) → `submitted` (tx written ahead, broadcast) → `done` | `failed`.
//! A job left `running` or `submitted` by a previous leader is recovered by the next one: `submitted`
//! jobs are reconciled against their recorded transaction, never re-sent blindly.

use anyhow::Result;
use sqlx::postgres::PgConnection;

pub const MAX_ATTEMPTS: i32 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Claim {
    /// Fresh or retryable: run it.
    Run { attempts: i32 },
    /// A previous leader broadcast a tx for it: reconcile that tx first.
    Reconcile,
    /// Done, skipped, still backing off, or out of attempts.
    Skip,
}

/// Claim `key` for `instance`. Orphaned `running` jobs (from a dead leader) are re-claimed.
pub async fn claim(
    conn: &mut PgConnection,
    key: &str,
    job: &str,
    payload: &serde_json::Value,
    instance: &str,
) -> Result<Claim> {
    let row: Option<(String, i32)> = sqlx::query_as(
        "insert into ops.keeper_job (key, job, status, attempts, next_run_at, payload, claimed_by, updated_at)
         values ($1, $2, 'running', 1, now(), $3, $4, now())
         on conflict (chain_id, key) do update
           set status = 'running', attempts = ops.keeper_job.attempts + 1, claimed_by = $4, updated_at = now()
         where (ops.keeper_job.status in ('pending', 'failed') and ops.keeper_job.attempts < $5
                and coalesce(ops.keeper_job.next_run_at, now()) <= now())
            or (ops.keeper_job.status = 'running' and ops.keeper_job.claimed_by is distinct from $4)
         returning status, attempts",
    )
    .bind(key)
    .bind(job)
    .bind(payload)
    .bind(instance)
    .bind(MAX_ATTEMPTS)
    .fetch_optional(&mut *conn)
    .await?;
    if let Some((_, attempts)) = row {
        return Ok(Claim::Run { attempts });
    }
    let status: Option<String> = sqlx::query_scalar(
        "select status from ops.keeper_job where chain_id = ops.chain() and key = $1",
    )
    .bind(key)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(if status.as_deref() == Some("submitted") {
        Claim::Reconcile
    } else {
        Claim::Skip
    })
}

/// On becoming leader: jobs left `running` were claimed by a leader that died mid-job (only the
/// leader runs jobs, through its fenced connection), so they are released to run again. `submitted`
/// jobs stay as they are: their recorded tx is reconciled, never re-sent blindly.
pub async fn release_orphans(conn: &mut PgConnection) -> Result<u64> {
    Ok(sqlx::query(
        "update ops.keeper_job set status = 'pending', updated_at = now() where chain_id = ops.chain() and status = 'running'",
    )
    .execute(&mut *conn)
    .await?
    .rows_affected())
}

pub async fn status(conn: &mut PgConnection, key: &str) -> Result<Option<String>> {
    Ok(sqlx::query_scalar(
        "select status from ops.keeper_job where chain_id = ops.chain() and key = $1",
    )
    .bind(key)
    .fetch_optional(&mut *conn)
    .await?)
}

pub async fn mark(
    conn: &mut PgConnection,
    key: &str,
    status: &str,
    error: Option<&str>,
) -> Result<()> {
    sqlx::query(
        "update ops.keeper_job set status = $2, last_error = $3, updated_at = now(),
                next_run_at = case when $2 = 'failed' then now() + make_interval(secs => least(300, 5 * power(2, attempts))) else next_run_at end
          where chain_id = ops.chain() and key = $1",
    )
    .bind(key)
    .bind(status)
    .bind(error)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Mark a set of keys done without a transaction of their own (e.g. covered by another key's poke).
pub async fn mark_covered(
    conn: &mut PgConnection,
    keys: &[String],
    job: &str,
    by: &str,
    instance: &str,
) -> Result<()> {
    for k in keys {
        sqlx::query(
            "insert into ops.keeper_job (key, job, status, attempts, payload, claimed_by, updated_at)
             values ($1, $2, 'done', 0, jsonb_build_object('coveredBy', $3::text), $4, now())
             on conflict (chain_id, key) do nothing",
        )
        .bind(k)
        .bind(job)
        .bind(by)
        .bind(instance)
        .execute(&mut *conn)
        .await?;
    }
    Ok(())
}

pub async fn exists(conn: &mut PgConnection, key: &str) -> Result<bool> {
    Ok(sqlx::query_scalar::<_, i64>(
        "select count(*) from ops.keeper_job where chain_id = ops.chain() and key = $1 and status in ('done', 'skipped')",
    )
    .bind(key)
    .fetch_one(&mut *conn)
    .await?
        > 0)
}

/// Attach a result (e.g. a dry-run plan) to a job's payload.
pub async fn set_payload(
    conn: &mut PgConnection,
    key: &str,
    payload: &serde_json::Value,
) -> Result<()> {
    sqlx::query(
        "update ops.keeper_job set payload = payload || $2, updated_at = now() where chain_id = ops.chain() and key = $1",
    )
    .bind(key)
    .bind(payload)
    .execute(&mut *conn)
    .await?;
    Ok(())
}
