//! Typed access to environment variables (§12.1). `.env` is loaded once, from the working directory or
//! the nearest parent that has one.

use anyhow::{anyhow, Context, Result};
use std::{str::FromStr, sync::Once};

static DOTENV: Once = Once::new();

/// Load `.env` (if any) into the process environment without overriding variables already set.
pub fn load_dotenv() {
    DOTENV.call_once(|| {
        let _ = dotenvy::dotenv();
    });
}

/// A required variable. Empty counts as missing.
pub fn required(name: &str) -> Result<String> {
    optional(name).ok_or_else(|| anyhow!("missing required env var {name}"))
}

/// An optional variable. Empty counts as missing.
pub fn optional(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
}

/// A variable with a default.
pub fn or(name: &str, default: &str) -> String {
    optional(name).unwrap_or_else(|| default.to_owned())
}

/// Parse a required variable.
pub fn parse<T: FromStr>(name: &str) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    let raw = required(name)?;
    raw.parse::<T>()
        .map_err(|e| anyhow!("env {name}={raw:?}: {e}"))
}

/// Parse an optional variable, falling back to `default`.
pub fn parse_or<T: FromStr>(name: &str, default: T) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    match optional(name) {
        None => Ok(default),
        Some(raw) => raw
            .parse::<T>()
            .map_err(|e| anyhow!("env {name}={raw:?}: {e}")),
    }
}

/// A chain-bound service's RPCs in failover order (ADR-0014: ≥ 2 per chain in prod): `RPC_URL`, then
/// `RPC_URL_FALLBACK`, each a comma-separated list (the legacy `ARB_SEPOLIA_RPC_URL[_FALLBACK]` still work);
/// duplicates dropped. Errors when none is set.
pub fn rpc_urls() -> Result<Vec<String>> {
    rpc_urls_from(optional)
}

/// `rpc_urls` over any variable source (testable).
pub fn rpc_urls_from(get: impl Fn(&str) -> Option<String>) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for raw in [
        get("RPC_URL").or_else(|| get("ARB_SEPOLIA_RPC_URL")),
        get("RPC_URL_FALLBACK").or_else(|| get("ARB_SEPOLIA_RPC_URL_FALLBACK")),
    ]
    .into_iter()
    .flatten()
    {
        for u in raw.split(',').map(str::trim).filter(|u| !u.is_empty()) {
            if !out.iter().any(|x| x == u) {
                out.push(u.to_owned());
            }
        }
    }
    if out.is_empty() {
        return Err(anyhow!("missing required env var RPC_URL"));
    }
    Ok(out)
}

/// A comma-separated list (empty items dropped).
pub fn list(name: &str) -> Vec<String> {
    optional(name)
        .map(|v| {
            v.split(',')
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// `CHAIN_ID`, required by every service.
pub fn chain_id() -> Result<u64> {
    parse::<u64>("CHAIN_ID").context("CHAIN_ID")
}

#[cfg(test)]
mod tests {
    #[test]
    fn rpc_urls_keep_failover_order_and_drop_duplicates() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |n: &str| {
                pairs
                    .iter()
                    .find(|(k, _)| *k == n)
                    .map(|(_, v)| v.to_string())
            }
        };
        assert_eq!(
            super::rpc_urls_from(env(&[
                ("RPC_URL", "https://a, https://b"),
                ("RPC_URL_FALLBACK", "https://b,https://c"),
            ]))
            .unwrap(),
            ["https://a", "https://b", "https://c"]
        );
        assert_eq!(
            super::rpc_urls_from(env(&[("ARB_SEPOLIA_RPC_URL", "https://s")])).unwrap(),
            ["https://s"]
        );
        assert!(super::rpc_urls_from(env(&[])).is_err());
    }
}
