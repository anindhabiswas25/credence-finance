//! Two (or more) RPC providers with health-checked failover (§10.2, S5 D).
//!
//! Every read goes to the **active** provider (`primary()`); `with_failover` tries the active one first, then the
//! others in order. `health_check` runs at the start of every keeper tick: each provider's head is read under a
//! timeout, and the active provider becomes the first one (in configured order, so the preferred RPC comes back
//! once it is healthy again) that answers and is no more than `max_lag` blocks behind the highest head seen. A
//! provider that answers but lags (two RPCs that disagree on the head) is as bad as one that is down: its reads
//! would be stale. When none answers, the active provider is kept and the tick's own reads fail as before.

use alloy::{
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::{Filter, Log},
};
use anyhow::{anyhow, bail, Context, Result};
use prometheus::{IntCounterVec, IntGaugeVec};
use std::{
    future::Future,
    sync::atomic::{AtomicU64, AtomicUsize, Ordering},
    time::Duration,
};

/// Blocks a provider may lag the best head before it's skipped (Arbitrum ≈ 4 blocks/s: ≈ 8 s).
pub const DEFAULT_MAX_LAG: u64 = 32;
/// Per-provider head read timeout in a health check.
pub const HEALTH_TIMEOUT: Duration = Duration::from_secs(3);

/// `eth_getLogs` paging ([`Rpc::logs_paged`]): a provider is first asked for up to `LOGS_MAX_RANGE` blocks per call
/// and drops to `LOGS_MIN_RANGE` once it refuses a range (Alchemy free: 10 blocks); at most `LOGS_MAX_WINDOWS` calls
/// per scan, the caller's cursor keeps the rest for its next tick.
pub const LOGS_MAX_RANGE: u64 = 10_000;
pub const LOGS_MIN_RANGE: u64 = 10;
pub const LOGS_MAX_WINDOWS: usize = 60;
/// A provider with a small range is tried after the wide ones while the backlog needs more than this many of its
/// windows (a catch-up after a restart); otherwise the read order stands.
pub const LOGS_DEFER_WINDOWS: u64 = 30;
/// A provider whose `eth_getLogs` failed (not a range refusal: Chainstack free refuses non-recent blocks) is tried last
/// for this long.
pub const LOGS_COOLDOWN: Duration = Duration::from_secs(300);

/// Whether an RPC error refuses the block range (or the result size) of an `eth_getLogs`.
pub fn is_range_refusal(msg: &str) -> bool {
    let m = msg.to_ascii_lowercase();
    m.contains("block range")
        || m.contains("range is too")
        || m.contains("exceeds limit")
        || m.contains("too many")
        || m.contains("query returned more than")
}

pub struct Rpc {
    providers: Vec<(String, DynProvider)>,
    /// Per provider: the `eth_getLogs` range it accepts (learned).
    log_caps: Vec<AtomicU64>,
    /// Per provider: until when (ms since `epoch`) its `eth_getLogs` is tried last.
    log_cooldown: Vec<AtomicU64>,
    epoch: std::time::Instant,
    pub logs_min_range: u64,
    pub logs_max_windows: usize,
    failovers: Option<IntCounterVec>,
    /// `rpc_up{rpc}` / `rpc_active{rpc}` (S5 alerts: one chain's RPC down), set by each health check.
    health: Option<(IntGaugeVec, IntGaugeVec)>,
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
            log_caps: providers
                .iter()
                .map(|_| AtomicU64::new(LOGS_MAX_RANGE))
                .collect(),
            log_cooldown: providers.iter().map(|_| AtomicU64::new(0)).collect(),
            epoch: std::time::Instant::now(),
            logs_min_range: LOGS_MIN_RANGE,
            logs_max_windows: LOGS_MAX_WINDOWS,
            providers,
            failovers,
            health: None,
            active: AtomicUsize::new(0),
            max_lag: DEFAULT_MAX_LAG,
        })
    }

    /// Publish each health check as `rpc_up{rpc}` (1 = answers within the lag) and `rpc_active{rpc}`.
    pub fn with_health_gauges(mut self, up: IntGaugeVec, active: IntGaugeVec) -> Self {
        self.health = Some((up, active));
        self
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
        if let Some((up, active)) = &self.health {
            let best = heads.iter().flatten().max().copied();
            for (i, ((name, _), h)) in self.providers.iter().zip(&heads).enumerate() {
                let ok = matches!((h, best), (Some(h), Some(b)) if h + self.max_lag >= b);
                up.with_label_values(&[name.as_str()]).set(ok as i64);
                active
                    .with_label_values(&[name.as_str()])
                    .set((i == next) as i64);
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

    /// `eth_getLogs` paging knobs: the first range each provider is asked for, its range after a refusal, and the
    /// calls per scan (`KEEPER_LOGS_MAX_RANGE` / `KEEPER_LOGS_MIN_RANGE` / `KEEPER_LOGS_MAX_WINDOWS`).
    pub fn with_logs_paging(mut self, max_range: u64, min_range: u64, max_windows: usize) -> Self {
        let min_range = min_range.max(1);
        self.log_caps = self
            .providers
            .iter()
            .map(|_| AtomicU64::new(max_range.max(min_range)))
            .collect();
        self.log_cooldown = self.providers.iter().map(|_| AtomicU64::new(0)).collect();
        self.logs_min_range = min_range;
        self.logs_max_windows = max_windows.max(1);
        self
    }

    /// `filter`'s logs over `from..=to` in windows each provider accepts, in the read failover order (a provider
    /// that refuses the range drops to `logs_min_range` and is asked again; any other error moves to the next one).
    /// Returns the logs and the last block covered: less than `to` once `logs_max_windows` calls are spent or every
    /// provider failed after some progress; `Err` only when nothing was covered.
    pub async fn logs_paged(&self, filter: &Filter, from: u64, to: u64) -> Result<(Vec<Log>, u64)> {
        let mut out = Vec::new();
        let mut cur = from;
        let mut windows = 0;
        while cur <= to && windows < self.logs_max_windows {
            let remaining = to - cur + 1;
            let first = self.active();
            let mut order: Vec<usize> = std::iter::once(first)
                .chain((0..self.providers.len()).filter(|&i| i != first))
                .collect();
            let now_ms = self.epoch.elapsed().as_millis() as u64;
            order.sort_by_key(|&i| {
                (
                    self.log_cooldown[i].load(Ordering::Relaxed) > now_ms,
                    self.log_caps[i].load(Ordering::Relaxed) * LOGS_DEFER_WINDOWS < remaining,
                )
            });
            let mut got = None;
            let mut last = None;
            'providers: for i in order {
                let (name, p) = &self.providers[i];
                loop {
                    let cap = self.log_caps[i].load(Ordering::Relaxed);
                    let end = to.min(cur.saturating_add(cap - 1));
                    match p
                        .get_logs(&filter.clone().from_block(cur).to_block(end))
                        .await
                    {
                        Ok(l) => {
                            if i != first {
                                if let Some(c) = &self.failovers {
                                    c.with_label_values(&[name.as_str()]).inc();
                                }
                            }
                            got = Some((l, end));
                            break 'providers;
                        }
                        Err(e) if cap > self.logs_min_range && is_range_refusal(&e.to_string()) => {
                            tracing::info!(rpc = %name, from_range = cap, to_range = self.logs_min_range, "eth_getLogs range refused: paging smaller");
                            self.log_caps[i].store(self.logs_min_range, Ordering::Relaxed);
                        }
                        Err(e) => {
                            let until = self.epoch.elapsed().as_millis() as u64
                                + LOGS_COOLDOWN.as_millis() as u64;
                            // one warning per cooldown, not one per window
                            if self.log_cooldown[i].swap(until, Ordering::Relaxed)
                                <= self.epoch.elapsed().as_millis() as u64
                            {
                                tracing::warn!(rpc = %name, what = "eth_getLogs", error = %e, cooldown_s = LOGS_COOLDOWN.as_secs(), "rpc call failed; tried last for the cooldown");
                            }
                            last = Some(anyhow!(e));
                            continue 'providers;
                        }
                    }
                }
            }
            match got {
                Some((l, end)) => {
                    out.extend(l);
                    cur = end + 1;
                    windows += 1;
                }
                None if cur == from => {
                    return Err(last
                        .unwrap_or_else(|| anyhow!("no provider"))
                        .context("eth_getLogs: every RPC failed"))
                }
                None => break,
            }
        }
        Ok((out, cur - 1))
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
