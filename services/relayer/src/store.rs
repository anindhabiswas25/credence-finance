//! Persistence of every signed report in `ops.relayer_report` (§11.3): an audit trail of what the
//! committee signed and what the chain accepted, and the seq high-water mark across restarts.

use crate::report::{Report, ReportDto};
use alloy::primitives::{Address, B256};
use anyhow::Result;
use async_trait::async_trait;
use sqlx::PgPool;
use std::collections::HashMap;

#[async_trait]
pub trait ReportStore: Send + Sync {
    /// Highest seq ever signed per asset for this feed.
    async fn max_seqs(&self, feed: &str) -> Result<HashMap<B256, u64>>;
    async fn record_signed(&self, feed: &str, reports: &[Report], signers: &[Address]) -> Result<()>;
    async fn record_outcome(&self, feed: &str, reports: &[Report], tx_hash: Option<B256>, status: &str) -> Result<()>;
}

pub struct PgStore {
    pool: PgPool,
}

impl PgStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ReportStore for PgStore {
    async fn max_seqs(&self, feed: &str) -> Result<HashMap<B256, u64>> {
        let rows: Vec<(Vec<u8>, i64)> =
            sqlx::query_as("select asset_id, max(seq) from ops.relayer_report where feed = $1 group by asset_id")
                .bind(feed)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows.into_iter().filter(|(a, _)| a.len() == 32).map(|(a, s)| (B256::from_slice(&a), s as u64)).collect())
    }

    async fn record_signed(&self, feed: &str, reports: &[Report], signers: &[Address]) -> Result<()> {
        let signers: Vec<String> = signers.iter().map(|a| a.to_checksum(None)).collect();
        let mut tx = self.pool.begin().await?;
        for r in reports {
            let d = ReportDto::from(r);
            sqlx::query(
                "insert into ops.relayer_report
                   (feed, asset_id, seq, kind, price, observed_at, session_date, market_status, signers, status)
                 values ($1, $2, $3, $4, $5::numeric, to_timestamp($6), $7, $8, $9, 'signed')
                 on conflict (feed, asset_id, seq) do nothing",
            )
            .bind(feed)
            .bind(d.asset_id.as_slice())
            .bind(d.seq as i64)
            .bind(d.kind as i16)
            .bind(&d.price)
            .bind(d.observed_at as f64)
            .bind(d.session_date as i32)
            .bind(d.market_status as i16)
            .bind(&signers)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn record_outcome(&self, feed: &str, reports: &[Report], tx_hash: Option<B256>, status: &str) -> Result<()> {
        let assets: Vec<Vec<u8>> = reports.iter().map(|r| r.assetId.to_vec()).collect();
        let seqs: Vec<i64> = reports.iter().map(|r| r.seq as i64).collect();
        sqlx::query(
            "update ops.relayer_report r set status = $2, tx_hash = coalesce($3, r.tx_hash)
               from unnest($4::bytea[], $5::bigint[]) as u(asset_id, seq)
              where r.feed = $1 and r.asset_id = u.asset_id and r.seq = u.seq",
        )
        .bind(feed)
        .bind(status)
        .bind(tx_hash.map(|h| h.to_vec()))
        .bind(&assets)
        .bind(&seqs)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

/// In-memory store (tests and `--no-db` dev runs).
#[derive(Default)]
pub struct MemStore {
    pub rows: tokio::sync::Mutex<Vec<(String, Report, String, Option<B256>)>>,
}

#[async_trait]
impl ReportStore for MemStore {
    async fn max_seqs(&self, feed: &str) -> Result<HashMap<B256, u64>> {
        let mut m = HashMap::new();
        for (f, r, _, _) in self.rows.lock().await.iter() {
            if f == feed {
                let e = m.entry(r.assetId).or_insert(0);
                *e = (*e).max(r.seq);
            }
        }
        Ok(m)
    }
    async fn record_signed(&self, feed: &str, reports: &[Report], _signers: &[Address]) -> Result<()> {
        let mut g = self.rows.lock().await;
        for r in reports {
            g.push((feed.into(), r.clone(), "signed".into(), None));
        }
        Ok(())
    }
    async fn record_outcome(&self, feed: &str, reports: &[Report], tx: Option<B256>, status: &str) -> Result<()> {
        let mut g = self.rows.lock().await;
        for row in g.iter_mut() {
            if row.0 == feed && reports.iter().any(|r| r.assetId == row.1.assetId && r.seq == row.1.seq) {
                row.2 = status.into();
                row.3 = tx.or(row.3);
            }
        }
        Ok(())
    }
}
