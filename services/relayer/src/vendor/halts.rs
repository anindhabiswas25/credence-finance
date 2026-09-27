//! Single-stock halts (§10.1 STATUS: "the single-stock halt feed (LULD / regulatory halts)").
//!
//! Source: Nasdaq Trader's public trade-halt feed (`rss.aspx?feed=tradehalts`), which lists every
//! current-day halt and LULD pause in US-listed securities, across all listing markets, with reason
//! codes and resumption times. It is polled every few seconds; a symbol is halted while it has an item
//! without a resumption trade time, or with a resumption time still in the future.

use chrono::{NaiveDate, NaiveTime, TimeZone};
use chrono_tz::America::New_York;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::RwLock;

use super::HaltInfo;

pub const NASDAQ_HALTS_URL: &str = "https://www.nasdaqtrader.com/rss.aspx?feed=tradehalts";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HaltItem {
    pub symbol: String,
    pub market: String,
    pub reason: String,
    /// Unix seconds.
    pub halted_at: u64,
    /// Unix seconds of the resumption trade, if announced.
    pub resumes_at: Option<u64>,
}

/// Parse the RSS body. Items that cannot be parsed are skipped.
pub fn parse_rss(xml: &str) -> Vec<HaltItem> {
    use quick_xml::{events::Event, Reader};
    let mut reader = Reader::from_str(xml);
    let mut out = Vec::new();
    let mut cur: HashMap<String, String> = HashMap::new();
    let mut in_item = false;
    let mut field: Option<String> = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if name == "item" {
                    in_item = true;
                    cur.clear();
                } else if in_item {
                    field = Some(name);
                }
            }
            Ok(Event::Text(t)) => {
                if let (true, Some(f)) = (in_item, &field) {
                    let v = t.decode().map(|c| c.into_owned()).unwrap_or_default();
                    cur.entry(f.clone()).or_default().push_str(&v);
                }
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if name == "item" {
                    in_item = false;
                    if let Some(item) = to_item(&cur) {
                        out.push(item);
                    }
                }
                field = None;
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

fn et_to_unix(date: &str, time: &str) -> Option<u64> {
    let d = NaiveDate::parse_from_str(date.trim(), "%m/%d/%Y").ok()?;
    let t = NaiveTime::parse_from_str(time.trim(), "%H:%M:%S%.f")
        .or_else(|_| NaiveTime::parse_from_str(time.trim(), "%H:%M:%S"))
        .ok()?;
    New_York
        .from_local_datetime(&d.and_time(t))
        .earliest()
        .map(|x| x.timestamp() as u64)
}

fn to_item(m: &HashMap<String, String>) -> Option<HaltItem> {
    let g = |k: &str| m.get(k).map(|s| s.trim().to_owned()).unwrap_or_default();
    let symbol = g("ndaq:IssueSymbol");
    if symbol.is_empty() {
        return None;
    }
    let halted_at = et_to_unix(&g("ndaq:HaltDate"), &g("ndaq:HaltTime"))?;

    let resume_date = g("ndaq:ResumptionDate");
    let resume_time = g("ndaq:ResumptionTradeTime");
    let halt_date = g("ndaq:HaltDate");
    let resumes_at = if resume_time.is_empty() {
        None
    } else {
        et_to_unix(
            if resume_date.is_empty() {
                &halt_date
            } else {
                &resume_date
            },
            &resume_time,
        )
    };
    Some(HaltItem {
        symbol,
        market: g("ndaq:Market"),
        reason: g("ndaq:ReasonCode"),
        halted_at,
        resumes_at,
    })
}

/// Halt state per symbol at `now` from a list of items (latest halt per symbol wins).
pub fn halts_at(items: &[HaltItem], now: u64) -> HashMap<String, HaltInfo> {
    let mut latest: HashMap<&str, &HaltItem> = HashMap::new();
    for i in items {
        if i.halted_at > now {
            continue;
        }
        let e = latest.entry(i.symbol.as_str()).or_insert(i);
        if i.halted_at > e.halted_at {
            *e = i;
        }
    }
    latest
        .into_iter()
        .map(|(s, i)| {
            let halted = i.resumes_at.is_none_or(|r| r > now);
            (
                s.to_owned(),
                HaltInfo {
                    halted,
                    reason: Some(i.reason.clone()),
                },
            )
        })
        .collect()
}

/// Shared, periodically refreshed halt state.
pub struct HaltFeed {
    url: String,
    items: RwLock<Option<(Vec<HaltItem>, u64)>>, // items, fetched at
    http: reqwest::Client,
    /// If the feed has not refreshed for this long, halt information is reported as unknown.
    max_age_s: u64,
}

impl HaltFeed {
    pub fn new(url: impl Into<String>) -> Arc<Self> {
        Arc::new(Self {
            url: url.into(),
            items: RwLock::new(None),
            http: super::http_client(),
            max_age_s: 120,
        })
    }

    /// A feed with fixed items (tests, replay).
    pub fn fixed(items: Vec<HaltItem>) -> Arc<Self> {
        Arc::new(Self {
            url: String::new(),
            items: RwLock::new(Some((items, u64::MAX / 2))),
            http: super::http_client(),
            max_age_s: u64::MAX,
        })
    }

    pub async fn refresh(&self) -> anyhow::Result<usize> {
        let body = self
            .http
            .get(&self.url)
            .header("user-agent", "Mozilla/5.0 credence-relayer")
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        let items = parse_rss(&body);
        let n = items.len();
        *self.items.write().await = Some((items, now()));
        Ok(n)
    }

    /// Poll forever (spawned by the node).
    pub async fn run(self: Arc<Self>, every: Duration) {
        loop {
            if let Err(e) = self.refresh().await {
                tracing::warn!(error = %e, "halt feed refresh failed");
            }
            tokio::time::sleep(every).await;
        }
    }

    /// `None` when the feed is not fresh (unknown), otherwise the symbol's state (not halted if absent).
    pub async fn halt(&self, symbol: &str) -> Option<HaltInfo> {
        let g = self.items.read().await;
        let (items, fetched) = g.as_ref()?;
        let t = now();
        if self.max_age_s != u64::MAX && t.saturating_sub(*fetched) > self.max_age_s {
            return None;
        }
        Some(halts_at(items, t).remove(symbol).unwrap_or(HaltInfo {
            halted: false,
            reason: None,
        }))
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> String {
        std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/nasdaq/tradehalts.xml"
        ))
        .unwrap()
    }

    #[test]
    fn parses_recorded_feed() {
        let items = parse_rss(&fixture());
        assert_eq!(items.len(), 19);
        let f = items.iter().find(|i| i.symbol == "FBGL").unwrap();
        assert_eq!(f.market, "NASDAQ");
        assert_eq!(f.reason, "T1");
        // 09/25/2026 19:50:00 ET (EDT) = 23:50:00Z
        assert_eq!(f.halted_at, 1_790_380_200);
        assert_eq!(f.resumes_at, None);
    }

    #[test]
    fn halted_until_resumption() {
        let item = |sym: &str, at, res| HaltItem {
            symbol: sym.into(),
            market: "NASDAQ".into(),
            reason: "LUDP".into(),
            halted_at: at,
            resumes_at: res,
        };
        let items = vec![
            item("NVDA", 100, Some(400)),
            item("AAPL", 100, None),
            item("TSLA", 500, None),
        ];
        let h = halts_at(&items, 200);
        assert!(h["NVDA"].halted);
        assert!(h["AAPL"].halted);
        assert!(!h.contains_key("TSLA"), "future halt ignored");
        let h = halts_at(&items, 400);
        assert!(!h["NVDA"].halted, "resumed");
        // a second, later halt of the same symbol wins
        let items = vec![item("NVDA", 100, Some(150)), item("NVDA", 300, None)];
        assert!(halts_at(&items, 350)["NVDA"].halted);
    }

    #[tokio::test]
    async fn fixed_feed_reports_absent_symbols_as_trading() {
        let feed = HaltFeed::fixed(vec![HaltItem {
            symbol: "COIN".into(),
            market: "NASDAQ".into(),
            reason: "T12".into(),
            halted_at: 1,
            resumes_at: None,
        }]);
        assert!(feed.halt("COIN").await.unwrap().halted);
        assert!(!feed.halt("NVDA").await.unwrap().halted);
    }
}
