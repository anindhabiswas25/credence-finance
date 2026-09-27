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
    std::env::var(name).ok().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())
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
    raw.parse::<T>().map_err(|e| anyhow!("env {name}={raw:?}: {e}"))
}

/// Parse an optional variable, falling back to `default`.
pub fn parse_or<T: FromStr>(name: &str, default: T) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    match optional(name) {
        None => Ok(default),
        Some(raw) => raw.parse::<T>().map_err(|e| anyhow!("env {name}={raw:?}: {e}")),
    }
}

/// A comma-separated list (empty items dropped).
pub fn list(name: &str) -> Vec<String> {
    optional(name)
        .map(|v| v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default()
}

/// `CHAIN_ID`, required by every service.
pub fn chain_id() -> Result<u64> {
    parse::<u64>("CHAIN_ID").context("CHAIN_ID")
}
