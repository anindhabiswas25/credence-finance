//! Two RPC providers with automatic failover (§10.2). Reads try the primary, then the fallback.

use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use anyhow::{anyhow, bail, Context, Result};
use prometheus::IntCounterVec;
use std::future::Future;

pub struct Rpc {
    providers: Vec<(String, DynProvider)>,
    failovers: Option<IntCounterVec>,
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
        })
    }

    pub fn primary(&self) -> &DynProvider {
        &self.providers[0].1
    }

    /// Run `f` on each provider in order until one succeeds.
    pub async fn with_failover<T, F, Fut>(&self, what: &str, f: F) -> Result<T>
    where
        F: Fn(DynProvider) -> Fut,
        Fut: Future<Output = Result<T>>,
    {
        let mut last = None;
        for (i, (name, p)) in self.providers.iter().enumerate() {
            match f(p.clone()).await {
                Ok(v) => {
                    if i > 0 {
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
