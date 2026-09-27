//! Leader election with a Postgres advisory lock (§10.2: two instances in different regions; the
//! follower takes over after 15 s of missed heartbeats).
//!
//! * The leader holds `pg_try_advisory_lock(key)` on a **dedicated connection** and heartbeats through
//!   it. Every job-store write and every transaction write-ahead goes through that same connection, so
//!   an instance that lost the lock cannot record or broadcast anything (fencing).
//! * A leader that dies releases the lock with its connection, and the follower takes over on its next
//!   attempt (≈1 s).
//! * A leader that hangs but keeps its connection is fenced: once its heartbeat is older than
//!   `stale_after` (15 s), the follower calls `pg_terminate_backend` on the lock holder's backend,
//!   which releases the lock.

use anyhow::{Context, Result};
use sqlx::{postgres::PgConnection, Connection, PgPool};
use std::time::Duration;

pub struct Leader {
    url: String,
    pool: PgPool,
    pub instance: String,
    chain_id: u64,
    key: i64,
    stale_after: Duration,
    conn: Option<PgConnection>,
}

/// Stable 64-bit lock key per chain: "credence-keeper:<chainId>".
pub fn lock_key(chain_id: u64) -> i64 {
    // FNV-1a, fixed so every instance and version agrees
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in format!("credence-keeper:{chain_id}").bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h as i64
}

impl Leader {
    pub fn new(url: &str, pool: PgPool, instance: &str, chain_id: u64) -> Self {
        Self {
            url: url.into(),
            pool,
            instance: instance.into(),
            chain_id,
            key: lock_key(chain_id),
            stale_after: Duration::from_secs(15),
            conn: None,
        }
    }

    pub fn with_stale_after(mut self, d: Duration) -> Self {
        self.stale_after = d;
        self
    }

    pub fn is_leader(&self) -> bool {
        self.conn.is_some()
    }

    /// The fenced connection. `None` unless this instance currently holds the lock.
    pub fn conn(&mut self) -> Option<&mut PgConnection> {
        self.conn.as_mut()
    }

    /// Drop leadership (the lock is released with the connection).
    pub async fn step_down(&mut self) {
        if let Some(c) = self.conn.take() {
            let _ = c.close().await;
        }
    }

    /// One election round. Returns whether this instance is the leader afterwards.
    pub async fn tick(&mut self) -> Result<bool> {
        if let Some(c) = self.conn.as_mut() {
            let beat = sqlx::query(
                "insert into ops.keeper_instance (instance_id, is_leader, heartbeat_at, backend_pid, chain_id)
                 values ($1, true, now(), pg_backend_pid(), $2)
                 on conflict (instance_id) do update
                   set is_leader = true, heartbeat_at = now(), backend_pid = pg_backend_pid(), chain_id = $2",
            )
            .bind(&self.instance)
            .bind(self.chain_id as i64)
            .execute(&mut *c)
            .await;
            match beat {
                Ok(_) => return Ok(true),
                Err(e) => {
                    tracing::warn!(instance = %self.instance, error = %e, "lost the leader connection: stepping down");
                    self.conn = None;
                }
            }
        }
        // follower heartbeat (through the pool)
        sqlx::query(
            "insert into ops.keeper_instance (instance_id, is_leader, heartbeat_at, chain_id)
             values ($1, false, now(), $2)
             on conflict (instance_id) do update set is_leader = false, heartbeat_at = now(), chain_id = $2",
        )
        .bind(&self.instance)
        .bind(self.chain_id as i64)
        .execute(&self.pool)
        .await?;

        let mut c = PgConnection::connect(&self.url)
            .await
            .context("leader connection")?;
        let got: bool = sqlx::query_scalar("select pg_try_advisory_lock($1)")
            .bind(self.key)
            .fetch_one(&mut c)
            .await?;
        if got {
            tracing::info!(instance = %self.instance, "acquired keeper leadership");
            self.conn = Some(c);
            return Box::pin(self.tick()).await; // write the leader heartbeat now
        }
        let _ = c.close().await;
        self.fence_stale_holder().await?;
        Ok(false)
    }

    /// Terminate the backend holding the lock if its instance's heartbeat is stale (hung leader).
    async fn fence_stale_holder(&self) -> Result<()> {
        let hi = ((self.key as u64) >> 32) as i64;
        let lo = ((self.key as u64) & 0xffff_ffff) as i64;
        let holder: Option<(i32,)> = sqlx::query_as(
            "select pid from pg_locks
              where locktype = 'advisory' and granted and database = (select oid from pg_database where datname = current_database())
                and classid::bigint = $1 and objid::bigint = $2 and objsubid = 1
              limit 1",
        )
        .bind(hi)
        .bind(lo)
        .fetch_optional(&self.pool)
        .await?;
        let Some((pid,)) = holder else { return Ok(()) };
        let age: Option<(String, f64)> = sqlx::query_as(
            "select instance_id, extract(epoch from now() - heartbeat_at)::float8
               from ops.keeper_instance where backend_pid = $1 and is_leader order by heartbeat_at desc limit 1",
        )
        .bind(pid)
        .fetch_optional(&self.pool)
        .await?;
        let stale = match &age {
            Some((_, secs)) => *secs > self.stale_after.as_secs_f64(),
            None => false, // holder never heartbeated yet: give it time (it heartbeats right after acquiring)
        };
        if stale {
            let (who, secs) = age.expect("stale implies a row");
            tracing::warn!(instance = %self.instance, leader = %who, pid, heartbeat_age_s = secs, "leader heartbeat stale: fencing it");
            sqlx::query("select pg_terminate_backend($1)")
                .bind(pid)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn lock_key_is_stable_per_chain() {
        assert_eq!(super::lock_key(412_346), super::lock_key(412_346));
        assert_ne!(super::lock_key(412_346), super::lock_key(421_614));
    }
}
