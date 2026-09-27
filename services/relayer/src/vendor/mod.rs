//! Market-data vendors (§10.1). Feed A and Feed B use two different licensed vendors (ADR-0002):
//! Polygon.io (Massive) and Alpaca. The replay vendor streams recorded sessions for dev and tests
//! and refuses to start on Arbitrum Sepolia.

pub mod alpaca;
pub mod alpaca_ws;
pub mod halts;
pub mod polygon;
pub mod polygon_ws;
pub mod replay;
pub mod stream;

use crate::asset::{Asset, Plan};
use async_trait::async_trait;
use credence_common::calendar::Session;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// One consolidated trade, normalised across vendors.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trade {
    pub price_wad: u128,
    pub size: u64,
    /// Exchange (participant) timestamp, ns since the epoch. SIP timestamp when the vendor has no other.
    pub ts_ns: u64,
    /// MIC of the reporting market (XNAS, XNYS, ARCX, FINRA TRF → "FINR", …).
    pub exchange: String,
    /// SIP sale-condition codes (CTA or UTP letters).
    pub conditions: Vec<String>,
    pub plan: Plan,
}

/// National best bid and offer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Quote {
    pub bid_wad: u128,
    pub ask_wad: u128,
    pub ts_ns: u64,
}

impl Quote {
    /// Mid of a valid (non-crossed, two-sided) quote.
    pub fn mid(&self) -> Option<u128> {
        (self.bid_wad > 0 && self.ask_wad >= self.bid_wad)
            .then(|| self.bid_wad / 2 + self.ask_wad / 2)
    }
}

/// Everything needed for one LIVE observation: recent trades (newest first) and the NBBO.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveInput {
    pub trades: Vec<Trade>,
    pub nbbo: Option<Quote>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PrintSource {
    /// A condition-coded auction print from the listing exchange, with its exchange timestamp.
    AuctionTrade,
    /// The vendor's daily bar open/close (official), timestamped at the scheduled session open/close.
    DailyBar,
}

/// An official opening or closing auction print.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OfficialPrint {
    pub price_wad: u128,
    /// Unix seconds.
    pub at: u64,
    pub source: PrintSource,
}

/// The vendor's view of the market session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VendorMarket {
    Open,
    Extended,
    Closed,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HaltInfo {
    pub halted: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusInput {
    pub market: VendorMarket,
    /// `None` when the vendor has no halt information for the symbol right now.
    pub halt: Option<HaltInfo>,
}

#[derive(Debug, thiserror::Error)]
pub enum VendorError {
    /// The key is valid but the plan does not include this endpoint (free tiers).
    #[error("{vendor}: not authorised for {endpoint} (plan does not include it)")]
    NotEntitled {
        vendor: &'static str,
        endpoint: String,
    },
    #[error("{vendor}: bad or missing API key")]
    Unauthorized { vendor: &'static str },
    #[error("{vendor}: rate limited")]
    RateLimited { vendor: &'static str },
    #[error("{vendor}: http error on {endpoint}: {message}")]
    Http {
        vendor: &'static str,
        endpoint: String,
        message: String,
    },
    #[error("{vendor}: cannot parse {endpoint}: {message}")]
    Parse {
        vendor: &'static str,
        endpoint: String,
        message: String,
    },
    #[error("{0}")]
    Other(String),
}

pub type VendorResult<T> = Result<T, VendorError>;

/// A licensed real-time US equity source. Every method is a point-in-time query: the node polls it and
/// keeps its own observation state.
#[async_trait]
pub trait MarketDataVendor: Send + Sync {
    fn name(&self) -> &'static str;

    /// LIVE: trades since `since_ns` (newest first, capped by the vendor) and the current NBBO.
    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput>;

    /// OPEN: the listing exchange's official opening auction print for `session`, if published yet.
    async fn official_open(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>>;

    /// CLOSE: the official closing auction print for `session`, if published yet.
    async fn official_close(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>>;

    /// STATUS: the vendor's market session plus the single-stock halt state (LULD / regulatory).
    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput>;

    /// Push notifications (symbol) when the vendor streams: the node re-observes that asset at once.
    /// `None` for polled vendors.
    fn updates(&self) -> Option<tokio::sync::broadcast::Receiver<String>> {
        None
    }
}

pub type DynVendor = Arc<dyn MarketDataVendor>;

/// Map a vendor HTTP status to an error.
pub(crate) fn http_error(
    vendor: &'static str,
    endpoint: &str,
    status: reqwest::StatusCode,
    body: &str,
) -> VendorError {
    match status.as_u16() {
        401 => VendorError::Unauthorized { vendor },
        403 => VendorError::NotEntitled {
            vendor,
            endpoint: endpoint.to_owned(),
        },
        429 => VendorError::RateLimited { vendor },
        _ => VendorError::Http {
            vendor,
            endpoint: endpoint.to_owned(),
            message: format!("{status}: {}", body.chars().take(300).collect::<String>()),
        },
    }
}

/// A shared HTTP client with sane timeouts.
pub(crate) fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .connect_timeout(std::time::Duration::from_secs(5))
        .user_agent(concat!("credence-relayer/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("reqwest client")
}

/// Simple token bucket: at most `per_minute` requests per rolling minute (free tiers are tight).
pub(crate) struct RateLimit {
    per_minute: u32,
    sent: tokio::sync::Mutex<std::collections::VecDeque<std::time::Instant>>,
}

impl RateLimit {
    pub fn new(per_minute: u32) -> Self {
        Self {
            per_minute: per_minute.max(1),
            sent: Default::default(),
        }
    }

    pub async fn acquire(&self) {
        loop {
            let wait = {
                let mut q = self.sent.lock().await;
                let now = std::time::Instant::now();
                while q
                    .front()
                    .is_some_and(|t| now.duration_since(*t) >= std::time::Duration::from_secs(60))
                {
                    q.pop_front();
                }
                if (q.len() as u32) < self.per_minute {
                    q.push_back(now);
                    return;
                }
                std::time::Duration::from_secs(60)
                    - now.duration_since(*q.front().expect("non-empty"))
            };
            tokio::time::sleep(wait).await;
        }
    }
}
