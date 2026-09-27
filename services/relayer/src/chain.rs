//! On-chain side of the aggregator: `CredencePriceFeed.submit`, `latestSeq`, and the other feed's
//! latest price for the vendor-disagreement metric. Two RPC endpoints with failover.

use crate::report::{ICredencePriceFeed, Report};
use alloy::{
    network::EthereumWallet,
    primitives::{Address, Bytes, B256},
    providers::{DynProvider, Provider, ProviderBuilder},
    sol,
    sol_types::SolInterface,
};
use anyhow::{anyhow, bail, Context, Result};
use async_trait::async_trait;
use std::time::Duration;

sol!(
    #[allow(missing_docs)]
    #[derive(Debug)]
    ICredenceErrors,
    "../../deployments/abis/v0/ICredenceErrors.json"
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitOutcome {
    /// Mined and succeeded.
    Accepted { tx_hash: B256, block: u64 },
    /// Mined but reverted.
    Reverted { tx_hash: B256, block: u64 },
    /// Rejected at gas estimation (never broadcast); `reason` is the decoded custom error.
    Rejected { reason: String },
}

/// What the aggregator needs from the chain (mocked in unit tests).
#[async_trait]
pub trait FeedChain: Send + Sync {
    async fn latest_seq(&self, asset: B256) -> Result<u64>;
    async fn submit(&self, reports: &[Report], signatures: Vec<Bytes>) -> Result<SubmitOutcome>;
    /// The other feed's latest price for `asset` (vendor-disagreement metric), if configured.
    async fn other_feed_latest(&self, _asset: B256) -> Result<Option<u128>> {
        Ok(None)
    }
}

/// Decode a revert payload into the Credence error name and arguments.
pub fn decode_revert(data: &[u8]) -> String {
    match ICredenceErrors::ICredenceErrorsErrors::abi_decode(data) {
        Ok(e) => format!("{e:?}"),
        Err(_) => format!("0x{}", alloy::primitives::hex::encode(data)),
    }
}

pub struct ChainClient {
    providers: Vec<DynProvider>,
    pub feed: Address,
    other_feed: Option<Address>,
    receipt_timeout: Duration,
}

impl ChainClient {
    /// `rpc_urls`: primary first, then fallbacks.
    pub fn connect(
        rpc_urls: &[String],
        wallet: EthereumWallet,
        feed: Address,
        other_feed: Option<Address>,
    ) -> Result<Self> {
        if rpc_urls.is_empty() {
            bail!("no RPC url");
        }
        let providers = rpc_urls
            .iter()
            .map(|u| {
                Ok(ProviderBuilder::new()
                    .wallet(wallet.clone())
                    .connect_http(u.parse().with_context(|| format!("rpc url {u}"))?)
                    .erased())
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            providers,
            feed,
            other_feed,
            receipt_timeout: Duration::from_secs(30),
        })
    }

    pub fn provider(&self) -> &DynProvider {
        &self.providers[0]
    }

    pub async fn chain_id(&self) -> Result<u64> {
        for p in &self.providers {
            if let Ok(id) = p.get_chain_id().await {
                return Ok(id);
            }
        }
        bail!("no RPC endpoint answered eth_chainId")
    }

    /// The on-chain EIP-712 digest for `reports` (cross-check against the Rust digest).
    pub async fn hash_reports(&self, reports: &[Report]) -> Result<B256> {
        Ok(ICredencePriceFeed::new(self.feed, self.provider())
            .hashReports(reports.to_vec())
            .call()
            .await?)
    }

    async fn submit_via(
        &self,
        p: &DynProvider,
        reports: &[Report],
        sigs: Vec<Bytes>,
    ) -> Result<SubmitOutcome> {
        let feed = ICredencePriceFeed::new(self.feed, p);
        let call = feed.submit(reports.to_vec(), sigs);
        let gas = match call.estimate_gas().await {
            Ok(g) => g,
            Err(e) => {
                if let Some(data) = e.as_revert_data() {
                    return Ok(SubmitOutcome::Rejected {
                        reason: decode_revert(&data),
                    });
                }
                return Err(anyhow!(e).context("estimate_gas"));
            }
        };
        let pending = call
            .gas(gas.saturating_mul(13) / 10)
            .send()
            .await
            .context("send submit")?;
        let tx_hash = *pending.tx_hash();
        let receipt = pending
            .with_timeout(Some(self.receipt_timeout))
            .get_receipt()
            .await
            .with_context(|| format!("receipt for {tx_hash}"))?;
        let block = receipt.block_number.unwrap_or_default();
        Ok(if receipt.status() {
            SubmitOutcome::Accepted { tx_hash, block }
        } else {
            SubmitOutcome::Reverted { tx_hash, block }
        })
    }
}

#[async_trait]
impl FeedChain for ChainClient {
    async fn latest_seq(&self, asset: B256) -> Result<u64> {
        let mut last = None;
        for p in &self.providers {
            match ICredencePriceFeed::new(self.feed, p)
                .latestSeq(asset)
                .call()
                .await
            {
                Ok(s) => return Ok(s),
                Err(e) => last = Some(e),
            }
        }
        Err(anyhow!("latestSeq failed on every RPC: {last:?}"))
    }

    async fn submit(&self, reports: &[Report], signatures: Vec<Bytes>) -> Result<SubmitOutcome> {
        let mut last = None;
        for p in &self.providers {
            match self.submit_via(p, reports, signatures.clone()).await {
                Ok(o) => return Ok(o),
                Err(e) => {
                    tracing::warn!(error = %e, "submit failed on one RPC, trying the next");
                    last = Some(e)
                }
            }
        }
        Err(last.unwrap_or_else(|| anyhow!("no RPC")))
    }

    async fn other_feed_latest(&self, asset: B256) -> Result<Option<u128>> {
        let Some(other) = self.other_feed else {
            return Ok(None);
        };
        let r = ICredencePriceFeed::new(other, self.provider())
            .latest(asset)
            .call()
            .await?;
        Ok(Some(r.price.to::<u128>()))
    }
}
