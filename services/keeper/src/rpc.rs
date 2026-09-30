//! Two (or more) RPC providers with health-checked failover (§10.2, S5 D).
//!
//! Every read goes to the **active** provider (`primary()`); `with_failover` tries the active one first, then the
//! others in order. `health_check` runs at the start of every keeper tick: each provider's head is read under a
//! timeout, and the active provider becomes the first one (in configured order, so the preferred RPC comes back
//! once it is healthy again) that answers and is no more than `max_lag` blocks behind the highest head seen. A
//! provider that answers but lags (two RPCs that disagree on the head) is as bad as one that is down: its reads
//! would be stale. When none answers, the active provider is kept and the tick's own reads fail as before.

use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use anyhow::{anyhow, bail, Context, Result};
use prometheus::IntCounterVec;
use std::{
    future::Future,
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};

/// Blocks a provider may lag the best head before it's skipped (Arbitrum ≈ 4 blocks/s: ≈ 8 s).
pub const DEFAULT_MAX_LAG: u64 = 32;
/// Per-provider head read timeout in a health check.
pub const HEALTH_TIMEOUT: Duration = Duration::from_secs(3);

pub struct Rpc {
    providers: Vec<(String, DynProvider)>,
    failovers: Option<IntCounterVec>,
    active: AtomicUsize,
    pub max_lag: u64,
}

/// A health check's result: each provider's head (`None` = no answer in time) and the provider now active.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Health {
    pub active: usize,
    pub heads: Vec<Option<u64>>,
    pub switched: bool,
}

/// The provider to use given each one's head (`None` = down): the first, in order, that answers and is within
/// `max_lag` of the best head; `current` if none answers.
pub fn choose(heads: &[Option<u64>], max_lag: u64, current: usize) -> usize {
    let Some(best) = heads.iter().flatten().max().copied() else {
        return current;
    };
    heads
        .iter()
        .position(|h| matches!(h, Some(h) if h + max_lag >= best))
        .unwrap_or(current)
}

impl Rpc {
    pub fn connect(urls: &[String], failovers: Option<IntCounterVec>) -> Result<Self> {
        if urls.is_empty() {
            bail!("no RPC url configured");
        }
        let providers = urls
            .iter()
            .map(|u| {
                Ok((
                    host(u),
                    ProviderBuilder::new()
                        .connect_http(u.parse().with_context(|| format!("rpc {u}"))?)
                        .erased(),
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            providers,
            failovers,
            active: AtomicUsize::new(0),
            max_lag: DEFAULT_MAX_LAG,
        })
    }

    /// The active provider (the configured primary unless a health check switched away from it).
    pub fn primary(&self) -> &DynProvider {
        &self.providers[self.active()].1
    }

    pub fn active(&self) -> usize {
        self.active.load(Ordering::Relaxed)
    }

    pub fn active_name(&self) -> &str {
        &self.providers[self.active()].0
    }

    /// Read every provider's head and pick the active one (see the module docs).
    pub async fn health_check(&self) -> Health {
        let heads = futures::future::join_all(self.providers.iter().map(|(_, p)| async move {
            match tokio::time::timeout(HEALTH_TIMEOUT, p.get_block_number()).await {
                Ok(Ok(h)) => Some(h),
                _ => None,
            }
        }))
        .await;
        let current = self.active();
        let next = choose(&heads, self.max_lag, current);
        let switched = next != current;
        if switched {
            self.active.store(next, Ordering::Relaxed);
            tracing::warn!(from = %self.providers[current].0, to = %self.providers[next].0, ?heads, "RPC failover");
            if let Some(c) = &self.failovers {
                c.with_label_values(&[self.providers[next].0.as_str()])
                    .inc();
            }
        }
        Health {
            active: next,
            heads,
            switched,
        }
    }

    /// Run `f` on the active provider, then on each other one in order, until one succeeds.
    pub async fn with_failover<T, F, Fut>(&self, what: &str, f: F) -> Result<T>
    where
        F: Fn(DynProvider) -> Fut,
        Fut: Future<Output = Result<T>>,
    {
        let first = self.active();
        let order = std::iter::once(first).chain((0..self.providers.len()).filter(|&i| i != first));
        let mut last = None;
        for i in order {
            let (name, p) = &self.providers[i];
            match f(p.clone()).await {
                Ok(v) => {
                    if i != first {
                        if let Some(c) = &self.failovers {
                            c.with_label_values(&[name.as_str()]).inc();
                        }
                    }
                    return Ok(v);
                }
                Err(e) => {
                    tracing::warn!(rpc = %name, what, error = %e, "rpc call failed");
                    last = Some(e);
                }
            }
        }
        Err(last
            .unwrap_or_else(|| anyhow!("no provider"))
            .context(format!("{what}: every RPC failed")))
    }

    pub async fn chain_id(&self) -> Result<u64> {
        self.with_failover(
            "eth_chainId",
            |p| async move { Ok(p.get_chain_id().await?) },
        )
        .await
    }
}

fn host(url: &str) -> String {
    url.split("://")
        .nth(1)
        .unwrap_or(url)
        .split(['/', '?'])
        .next()
        .unwrap_or(url)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edge_rpc_choose_prefers_the_first_healthy_provider_within_the_lag() {
        // both fine: the configured primary
        assert_eq!(choose(&[Some(100), Some(100)], 32, 1), 0);
        // primary down → fallback; back up → primary again
        assert_eq!(choose(&[None, Some(100)], 32, 0), 1);
        assert_eq!(choose(&[Some(101), Some(101)], 32, 1), 0);
        // disagreement on the head: the primary is stale by more than max_lag → fallback
        assert_eq!(choose(&[Some(60), Some(100)], 32, 0), 1);
        // lagging by exactly max_lag is still fine
        assert_eq!(choose(&[Some(68), Some(100)], 32, 1), 0);
        // the fallback is the stale one: stay on the primary
        assert_eq!(choose(&[Some(100), Some(10)], 32, 0), 0);
        // nothing answers: keep what we have
        assert_eq!(choose(&[None, None], 32, 1), 1);
    }
}
