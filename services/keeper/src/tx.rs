//! Transaction manager (§10.2 operational rules):
//!
//! * **one sender per chain** with a local nonce counter, synced from the chain's pending nonce whenever
//!   this instance becomes leader or a send reports a nonce problem;
//! * gas = `eth_estimateGas × 1.3`; a failing estimate means the call would revert, so nothing is sent
//!   ("no failed txs");
//! * every transaction is signed locally and **written ahead** to `ops.keeper_tx` (through the leader's
//!   fenced connection) before it is broadcast, so a new leader can always reconcile what the old one
//!   sent instead of sending it again;
//! * a transaction not mined after 3 blocks is replaced (same nonce) with fees +20%.

use crate::{metrics::Metrics, rpc::Rpc};
use alloy::{
    consensus::TxEnvelope,
    eips::eip2718::Encodable2718,
    network::{Ethereum, EthereumWallet, NetworkTransactionBuilder, TransactionBuilder},
    primitives::{Address, Bytes, B256},
    providers::Provider,
    rpc::types::{TransactionReceipt, TransactionRequest},
};
use anyhow::{anyhow, bail, Context, Result};
use sqlx::postgres::PgConnection;
use std::{sync::Arc, time::Duration};
use tokio::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mined {
    pub hash: B256,
    pub success: bool,
    pub block: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reconciled {
    /// A recorded tx was mined.
    Mined(Mined),
    /// Still in the mempool: wait.
    Pending,
    /// None of the recorded txs exists any more: the job may run again.
    Dropped,
}

pub struct TxManager {
    rpc: Arc<Rpc>,
    wallet: EthereumWallet,
    pub sender: Address,
    pub chain_id: u64,
    nonce: Mutex<Option<u64>>,
    metrics: Metrics,
    pub replace_after_blocks: u64,
    pub timeout: Duration,
    /// Gas limit = estimate × this / 10 (§10.2: 13 = ×1.3; `KEEPER_GAS_MULTIPLIER_X10`).
    pub gas_x10: u64,
    /// OFF-09 (§15.1 hot-wallet caps): the highest max fee per gas a replacement may reach (`KEEPER_MAX_FEE_GWEI`);
    /// `None` = uncapped.
    pub max_fee_cap_wei: Option<u128>,
}

/// The +20 % replacement fees of a stuck tx, capped at `cap` (OFF-09). Equal to the input once at the cap: the
/// caller then keeps waiting instead of re-broadcasting an underpriced replacement.
pub fn bump_fees(max_fee: u128, tip: u128, cap: Option<u128>) -> (u128, u128) {
    let mut f = max_fee.saturating_mul(12) / 10 + 1;
    let mut t = tip.saturating_mul(12) / 10 + 1;
    if let Some(c) = cap {
        f = f.min(c.max(max_fee));
        if f == max_fee {
            // a replacement must raise both fees (≥ 10 %, node rule): at the cap there is none to send
            return (max_fee, tip);
        }
        t = t.min(f);
    }
    (f, t)
}

/// A node's nonce complaint anywhere in the error chain (`with_failover` wraps the node's message in a context, so
/// the top-level `to_string()` alone never shows it).
pub fn is_nonce_error(e: &anyhow::Error) -> bool {
    let msg = format!("{e:#}");
    msg.contains("nonce too low") || msg.contains("nonce too high")
}

impl TxManager {
    pub fn new(
        rpc: Arc<Rpc>,
        wallet: EthereumWallet,
        sender: Address,
        chain_id: u64,
        metrics: Metrics,
    ) -> Self {
        Self {
            rpc,
            wallet,
            sender,
            chain_id,
            nonce: Mutex::new(None),
            metrics,
            replace_after_blocks: 3,
            timeout: Duration::from_secs(120),
            gas_x10: 13,
            max_fee_cap_wei: None,
        }
    }

    /// Forget the local nonce (call on becoming leader).
    pub async fn reset_nonce(&self) {
        *self.nonce.lock().await = None;
    }

    async fn next_nonce(&self) -> Result<u64> {
        let mut g = self.nonce.lock().await;
        if g.is_none() {
            let sender = self.sender;
            let n = self
                .rpc
                .with_failover("pending nonce", |p| async move {
                    Ok(p.get_transaction_count(sender).pending().await?)
                })
                .await?;
            *g = Some(n);
        }
        Ok(g.expect("set above"))
    }

    async fn bump_nonce(&self, used: u64) {
        let mut g = self.nonce.lock().await;
        *g = Some(g.map_or(used + 1, |n| n.max(used + 1)));
    }

    /// Estimate, sign, write ahead, broadcast, wait (replacing if stuck). The caller marks its job.
    pub async fn send(
        &self,
        conn: &mut PgConnection,
        job_key: &str,
        to: Address,
        data: Bytes,
    ) -> Result<Mined> {
        let base = TransactionRequest::default()
            .with_from(self.sender)
            .with_to(to)
            .with_input(data);
        let gas = {
            let req = base.clone();
            self.rpc
                .with_failover("estimate_gas", |p| {
                    let req = req.clone();
                    async move { Ok(p.estimate_gas(req).await?) }
                })
                .await
                .context("estimate_gas (the call would revert: not sending)")?
        };
        let fees = self
            .rpc
            .with_failover(
                "fees",
                |p| async move { Ok(p.estimate_eip1559_fees().await?) },
            )
            .await?;
        let nonce = self.next_nonce().await?;
        let mut max_fee = fees.max_fee_per_gas;
        let mut tip = fees.max_priority_fee_per_gas;
        if let Some(c) = self.max_fee_cap_wei {
            max_fee = max_fee.min(c);
            tip = tip.min(max_fee);
        }
        let start_block = self
            .rpc
            .with_failover("block number", |p| async move {
                Ok(p.get_block_number().await?)
            })
            .await?;
        let mut hashes: Vec<B256> = Vec::new();
        let deadline = tokio::time::Instant::now() + self.timeout;
        let mut last_broadcast_block = start_block;

        loop {
            let req = base
                .clone()
                .with_nonce(nonce)
                .with_chain_id(self.chain_id)
                .with_gas_limit(gas.saturating_mul(self.gas_x10) / 10)
                .with_max_fee_per_gas(max_fee)
                .with_max_priority_fee_per_gas(tip);
            let env: TxEnvelope =
                <TransactionRequest as NetworkTransactionBuilder<Ethereum>>::build(
                    req,
                    &self.wallet,
                )
                .await
                .context("signing")?;
            let hash = *env.tx_hash();
            let raw = Bytes::from(env.encoded_2718());
            // write ahead, through the fenced leader connection
            sqlx::query(
                "insert into ops.keeper_tx (hash, job_key, chain_id, sender, nonce, gas_price, status)
                 values ($1, $2, $3, $4, $5, $6::numeric, 'pending') on conflict (hash) do nothing",
            )
            .bind(hash.as_slice())
            .bind(job_key)
            .bind(self.chain_id as i64)
            .bind(self.sender.as_slice())
            .bind(nonce as i64)
            .bind(max_fee.to_string())
            .execute(&mut *conn)
            .await
            .context("write-ahead keeper_tx")?;
            sqlx::query(
                "update ops.keeper_job set status = 'submitted', updated_at = now() where key = $1",
            )
            .bind(job_key)
            .execute(&mut *conn)
            .await?;
            hashes.push(hash);
            let sent = self
                .rpc
                .with_failover("send_raw_transaction", |p| {
                    let raw = raw.clone();
                    async move {
                        match p.send_raw_transaction(&raw).await {
                            Ok(_) => Ok(()),
                            Err(e) if e.to_string().contains("already known") => Ok(()),
                            Err(e) => Err(anyhow!(e)),
                        }
                    }
                })
                .await;
            if let Err(e) = sent {
                if is_nonce_error(&e) {
                    // maybe a previous tx at this nonce already mined: reconcile, then resync
                    if let Reconciled::Mined(m) = self.reconcile_hashes(conn, &hashes).await? {
                        self.bump_nonce(nonce).await;
                        return Ok(m);
                    }
                    self.reset_nonce().await;
                }
                self.metrics.txs.with_label_values(&["send_error"]).inc();
                return Err(e);
            }
            // count the blocks from after the broadcast: a slow broadcast must not make a fresh tx look stuck
            if let Ok(bn) = self
                .rpc
                .with_failover("block number", |p| async move {
                    Ok(p.get_block_number().await?)
                })
                .await
            {
                last_broadcast_block = last_broadcast_block.max(bn);
            }

            // wait for a receipt; replace after N blocks
            loop {
                if let Reconciled::Mined(m) = self.reconcile_hashes(conn, &hashes).await? {
                    self.bump_nonce(nonce).await;
                    self.metrics
                        .txs
                        .with_label_values(&[if m.success { "mined" } else { "reverted" }])
                        .inc();
                    return Ok(m);
                }
                if tokio::time::Instant::now() > deadline {
                    self.metrics.txs.with_label_values(&["timeout"]).inc();
                    bail!(
                        "tx {hash} not mined within {:?}; left for reconciliation",
                        self.timeout
                    );
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
                let bn = self
                    .rpc
                    .with_failover("block number", |p| async move {
                        Ok(p.get_block_number().await?)
                    })
                    .await?;
                if bn >= last_broadcast_block + self.replace_after_blocks {
                    // mined while we slept? never replace a tx that is already in a block
                    if let Reconciled::Mined(m) = self.reconcile_hashes(conn, &hashes).await? {
                        self.bump_nonce(nonce).await;
                        self.metrics
                            .txs
                            .with_label_values(&[if m.success { "mined" } else { "reverted" }])
                            .inc();
                        return Ok(m);
                    }
                    last_broadcast_block = bn;
                    let (f, t) = bump_fees(max_fee, tip, self.max_fee_cap_wei);
                    if (f, t) == (max_fee, tip) {
                        tracing::warn!(%hash, nonce, max_fee, "tx stuck at the fee cap (KEEPER_MAX_FEE_GWEI): waiting, not replacing");
                        continue;
                    }
                    (max_fee, tip) = (f, t);
                    self.metrics
                        .tx_replacements
                        .with_label_values(&[job_key.split(':').next().unwrap_or("?")])
                        .inc();
                    tracing::warn!(%hash, nonce, "tx stuck for {} blocks: replacing with +20% fees", self.replace_after_blocks);
                    break; // re-sign at the same nonce
                }
            }
        }
    }

    async fn receipt(&self, h: B256) -> Result<Option<TransactionReceipt>> {
        self.rpc
            .with_failover("receipt", |p| async move {
                Ok(p.get_transaction_receipt(h).await?)
            })
            .await
    }

    async fn reconcile_hashes(
        &self,
        conn: &mut PgConnection,
        hashes: &[B256],
    ) -> Result<Reconciled> {
        for h in hashes {
            if let Some(r) = self.receipt(*h).await? {
                let success = r.status();
                let block = r.block_number.unwrap_or_default();
                sqlx::query(
                    "update ops.keeper_tx set status = $2, mined_block = $3 where hash = $1",
                )
                .bind(h.as_slice())
                .bind(if success { "mined" } else { "reverted" })
                .bind(block as i64)
                .execute(&mut *conn)
                .await?;
                let others: Vec<Vec<u8>> = hashes
                    .iter()
                    .filter(|x| *x != h)
                    .map(|x| x.to_vec())
                    .collect();
                sqlx::query("update ops.keeper_tx set status = 'replaced' where hash = any($1) and status = 'pending'")
                    .bind(&others)
                    .execute(&mut *conn)
                    .await?;
                return Ok(Reconciled::Mined(Mined {
                    hash: *h,
                    success,
                    block,
                }));
            }
        }
        for h in hashes {
            let h = *h;
            let pending = self
                .rpc
                .with_failover("tx by hash", |p| async move {
                    Ok(p.get_transaction_by_hash(h).await?)
                })
                .await?;
            if pending.is_some() {
                return Ok(Reconciled::Pending);
            }
        }
        Ok(Reconciled::Dropped)
    }

    /// A new leader's view of a job the previous leader left `submitted`.
    pub async fn reconcile_job(
        &self,
        conn: &mut PgConnection,
        job_key: &str,
    ) -> Result<Reconciled> {
        let rows: Vec<(Vec<u8>,)> = sqlx::query_as(
            "select hash from ops.keeper_tx where job_key = $1 order by submitted_at",
        )
        .bind(job_key)
        .fetch_all(&mut *conn)
        .await?;
        let hashes: Vec<B256> = rows
            .into_iter()
            .filter(|(h,)| h.len() == 32)
            .map(|(h,)| B256::from_slice(&h))
            .collect();
        if hashes.is_empty() {
            return Ok(Reconciled::Dropped);
        }
        let r = self.reconcile_hashes(conn, &hashes).await?;
        if r == Reconciled::Dropped {
            sqlx::query("update ops.keeper_tx set status = 'dropped' where job_key = $1 and status = 'pending'")
                .bind(job_key)
                .execute(&mut *conn)
                .await?;
        }
        Ok(r)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn edge_k05_a_wrapped_nonce_error_is_recognised() {
        let node =
            anyhow::anyhow!("server returned an error response: error code -32003: nonce too low");
        let wrapped = node.context("send_raw_transaction: every RPC failed");
        assert!(
            !wrapped.to_string().contains("nonce too low"),
            "the top level hides it"
        );
        assert!(super::is_nonce_error(&wrapped));
        assert!(!super::is_nonce_error(&anyhow::anyhow!(
            "insufficient funds"
        )));
    }

    #[test]
    fn off09_replacement_fees_stop_at_the_cap() {
        assert_eq!(super::bump_fees(100, 10, None), (121, 13));
        assert_eq!(super::bump_fees(100, 10, Some(110)), (110, 13));
        assert_eq!(
            super::bump_fees(110, 13, Some(110)),
            (110, 13),
            "at the cap: unchanged"
        );
        assert_eq!(
            super::bump_fees(100, 100, Some(105)),
            (105, 105),
            "tip never above the max fee"
        );
    }
}
