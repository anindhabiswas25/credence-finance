//! Shared plumbing for the Credence off-chain services (Build Guide §5 `crates/credence-common`).
//!
//! Every service is stateless with respect to correctness (§10): config comes from env, state that must
//! survive a restart lives in Postgres (`ops` schema), and each service exposes `/healthz`, `/readyz`
//! and Prometheus `/metrics` through [`ops::OpsServer`].

pub mod calendar;
pub mod db;
pub mod env;
pub mod ops;
pub mod retry;
pub mod signer;
pub mod telemetry;

/// Chain ids on which dev-only tooling (replay vendor, local key files) may run.
pub const DEV_CHAIN_IDS: [u64; 2] = [31_337, 412_346];
/// Arbitrum Sepolia: the public testnet (§3.1). Dev tooling refuses to start here.
pub const ARB_SEPOLIA: u64 = 421_614;

/// True when `chain_id` is a local development chain (anvil or nitro-devnode).
pub fn is_dev_chain(chain_id: u64) -> bool {
    DEV_CHAIN_IDS.contains(&chain_id)
}
