//! Credence price relayer (Build Guide §10.1).
//!
//! Licensed real-time US equity data → filtered LIVE / OPEN / CLOSE / STATUS observations on three
//! signer nodes → median proposal by the aggregator → 2-of-3 EIP-712 signatures → one
//! `CredencePriceFeed.submit` per tick → `ops.relayer_report`.

pub mod aggregator;
pub mod asset;
pub mod cadence;
pub mod chain;
pub mod conditions;
pub mod config;
pub mod filter;
pub mod metrics;
pub mod node;
pub mod ocr;
pub mod price;
pub mod report;
pub mod store;
pub mod vendor;
