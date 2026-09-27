//! Turn raw vendor data into one LIVE observation per asset (§10.1):
//!
//! * REGULAR: the newest regular-eligible consolidated trade, cross-checked against the NBBO mid; the
//!   observation is rejected if the trade is more than 0.5% from the mid, or if there is no valid NBBO
//!   (fail closed: no report, and the on-chain staleness rule takes over).
//! * EXTENDED (pre, post, overnight): the newest extended-eligible trade; the NBBO mid when there is no
//!   recent trade.

use crate::{
    conditions::classify,
    price::deviation_ppm,
    report::MarketStatus,
    vendor::{LiveInput, Quote, Trade},
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy)]
pub struct FilterConfig {
    /// Max trade–mid distance in REGULAR (5000 ppm = 0.5%).
    pub nbbo_max_dev_ppm: u128,
    /// Oldest trade usable in REGULAR.
    pub regular_max_age_s: u64,
    /// Oldest trade usable in EXTENDED before falling back to the NBBO mid.
    pub extended_max_age_s: u64,
    /// Oldest NBBO usable.
    pub quote_max_age_s: u64,
    /// Widest spread, (ask − bid) / mid, for a mid-based EXTENDED observation (2% default).
    pub mid_max_spread_ppm: u128,
}

impl Default for FilterConfig {
    fn default() -> Self {
        Self {
            nbbo_max_dev_ppm: 5_000,
            regular_max_age_s: 60,
            extended_max_age_s: 300,
            quote_max_age_s: 60,
            mid_max_spread_ppm: 20_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ObsSource {
    Trade,
    NbboMid,
}

/// A node's LIVE observation of one asset.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveObservation {
    pub price_wad: u128,
    /// Unix seconds of the print (exchange time).
    pub observed_at: u64,
    pub source: ObsSource,
    pub status: MarketStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Rejection {
    #[error("no eligible trade in the window")]
    NoEligibleTrade,
    #[error("no valid NBBO")]
    NoQuote,
    #[error("trade {deviation_ppm} ppm from NBBO mid (max {max_ppm})")]
    NbboDeviation { deviation_ppm: u128, max_ppm: u128 },
    #[error("spread too wide for a mid price ({spread_ppm} ppm)")]
    WideSpread { spread_ppm: u128 },
    #[error("market status {0:?} has no LIVE price")]
    NotTrading(MarketStatus),
}

fn fresh(ts_ns: u64, now_s: u64, max_age_s: u64) -> bool {
    let t = ts_ns / 1_000_000_000;
    t <= now_s + 5 && now_s.saturating_sub(t) <= max_age_s
}

fn valid_quote(q: &Option<Quote>, now_s: u64, cfg: &FilterConfig) -> Option<(u128, u64)> {
    let q = q.as_ref()?;
    if !fresh(q.ts_ns, now_s, cfg.quote_max_age_s) {
        return None;
    }
    q.mid().map(|m| (m, q.ts_ns / 1_000_000_000))
}

/// Pick the LIVE observation for `status` at `now_s`, or say why there is none.
pub fn live_observation(
    status: MarketStatus,
    input: &LiveInput,
    now_s: u64,
    cfg: &FilterConfig,
) -> Result<LiveObservation, Rejection> {
    match status {
        MarketStatus::Regular => regular(input, now_s, cfg),
        s if s.is_extended() => extended(s, input, now_s, cfg),
        s => Err(Rejection::NotTrading(s)),
    }
}

fn newest<'a>(trades: &'a [Trade], ok: impl Fn(&Trade) -> bool) -> Option<&'a Trade> {
    trades.iter().filter(|t| ok(t)).max_by_key(|t| t.ts_ns)
}

fn regular(input: &LiveInput, now_s: u64, cfg: &FilterConfig) -> Result<LiveObservation, Rejection> {
    let t = newest(&input.trades, |t| {
        t.price_wad > 0 && fresh(t.ts_ns, now_s, cfg.regular_max_age_s) && classify(t.plan, &t.conditions).regular
    })
    .ok_or(Rejection::NoEligibleTrade)?;
    let (mid, _) = valid_quote(&input.nbbo, now_s, cfg).ok_or(Rejection::NoQuote)?;
    let dev = deviation_ppm(t.price_wad, mid);
    if dev > cfg.nbbo_max_dev_ppm {
        return Err(Rejection::NbboDeviation { deviation_ppm: dev, max_ppm: cfg.nbbo_max_dev_ppm });
    }
    Ok(LiveObservation {
        price_wad: t.price_wad,
        observed_at: t.ts_ns / 1_000_000_000,
        source: ObsSource::Trade,
        status: MarketStatus::Regular,
    })
}

fn extended(
    status: MarketStatus,
    input: &LiveInput,
    now_s: u64,
    cfg: &FilterConfig,
) -> Result<LiveObservation, Rejection> {
    if let Some(t) = newest(&input.trades, |t| {
        t.price_wad > 0 && fresh(t.ts_ns, now_s, cfg.extended_max_age_s) && classify(t.plan, &t.conditions).extended
    }) {
        return Ok(LiveObservation {
            price_wad: t.price_wad,
            observed_at: t.ts_ns / 1_000_000_000,
            source: ObsSource::Trade,
            status,
        });
    }
    let q = input.nbbo.as_ref().ok_or(Rejection::NoEligibleTrade)?;
    let (mid, at) = valid_quote(&input.nbbo, now_s, cfg).ok_or(Rejection::NoQuote)?;
    let spread = q.ask_wad.saturating_sub(q.bid_wad).saturating_mul(crate::price::PPM) / mid.max(1);
    if spread > cfg.mid_max_spread_ppm {
        return Err(Rejection::WideSpread { spread_ppm: spread });
    }
    Ok(LiveObservation { price_wad: mid, observed_at: at, source: ObsSource::NbboMid, status })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{asset::Plan, price::WAD};

    const NOW: u64 = 1_790_000_000;

    fn trade(p: u128, age_s: u64, cond: &[&str]) -> Trade {
        Trade {
            price_wad: p,
            size: 100,
            ts_ns: (NOW - age_s) * 1_000_000_000,
            exchange: "XNAS".into(),
            conditions: cond.iter().map(|s| s.to_string()).collect(),
            plan: Plan::Utp,
        }
    }

    fn quote(bid: u128, ask: u128, age_s: u64) -> Option<Quote> {
        Some(Quote { bid_wad: bid, ask_wad: ask, ts_ns: (NOW - age_s) * 1_000_000_000 })
    }

    #[test]
    fn regular_takes_newest_eligible_trade() {
        let input = LiveInput {
            trades: vec![
                trade(101 * WAD, 1, &["@", "I"]), // odd lot, newest: skipped
                trade(100 * WAD, 2, &["@"]),
                trade(99 * WAD, 3, &["@"]),
            ],
            nbbo: quote(99_95 * WAD / 100, 100_05 * WAD / 100, 1),
        };
        let o = live_observation(MarketStatus::Regular, &input, NOW, &FilterConfig::default()).unwrap();
        assert_eq!(o.price_wad, 100 * WAD);
        assert_eq!(o.observed_at, NOW - 2);
        assert_eq!(o.source, ObsSource::Trade);
    }

    #[test]
    fn regular_rejects_far_from_mid_and_missing_quote() {
        let cfg = FilterConfig::default();
        let far = LiveInput { trades: vec![trade(10_060 * WAD / 100, 1, &["@"])], nbbo: quote(100 * WAD, 100 * WAD, 1) };
        assert!(matches!(
            live_observation(MarketStatus::Regular, &far, NOW, &cfg),
            Err(Rejection::NbboDeviation { deviation_ppm: 6_000, .. })
        ));
        let edge = LiveInput { trades: vec![trade(10_050 * WAD / 100, 1, &["@"])], nbbo: quote(100 * WAD, 100 * WAD, 1) };
        assert!(live_observation(MarketStatus::Regular, &edge, NOW, &cfg).is_ok(), "exactly 0.5% passes");
        let noq = LiveInput { trades: vec![trade(100 * WAD, 1, &["@"])], nbbo: None };
        assert_eq!(live_observation(MarketStatus::Regular, &noq, NOW, &cfg), Err(Rejection::NoQuote));
        let crossed = LiveInput { trades: vec![trade(100 * WAD, 1, &["@"])], nbbo: quote(101 * WAD, 100 * WAD, 1) };
        assert_eq!(live_observation(MarketStatus::Regular, &crossed, NOW, &cfg), Err(Rejection::NoQuote));
        let stale_q = LiveInput { trades: vec![trade(100 * WAD, 1, &["@"])], nbbo: quote(100 * WAD, 100 * WAD, 61) };
        assert_eq!(live_observation(MarketStatus::Regular, &stale_q, NOW, &cfg), Err(Rejection::NoQuote));
    }

    #[test]
    fn regular_rejects_form_t_and_stale_trades() {
        let cfg = FilterConfig::default();
        let input = LiveInput {
            trades: vec![trade(100 * WAD, 1, &["@", "T"]), trade(100 * WAD, 61, &["@"])],
            nbbo: quote(100 * WAD, 100 * WAD, 1),
        };
        assert_eq!(live_observation(MarketStatus::Regular, &input, NOW, &cfg), Err(Rejection::NoEligibleTrade));
    }

    #[test]
    fn extended_uses_form_t_then_mid() {
        let cfg = FilterConfig::default();
        let with_trade = LiveInput { trades: vec![trade(100 * WAD, 30, &["@", "T"])], nbbo: None };
        let o = live_observation(MarketStatus::Post, &with_trade, NOW, &cfg).unwrap();
        assert_eq!((o.price_wad, o.source, o.status), (100 * WAD, ObsSource::Trade, MarketStatus::Post));

        let mid_only = LiveInput { trades: vec![trade(100 * WAD, 301, &["@", "T"])], nbbo: quote(99 * WAD, 101 * WAD, 5) };
        let o = live_observation(MarketStatus::Overnight, &mid_only, NOW, &cfg).unwrap();
        assert_eq!((o.price_wad, o.source, o.observed_at), (100 * WAD, ObsSource::NbboMid, NOW - 5));

        let wide = LiveInput { trades: vec![], nbbo: quote(95 * WAD, 105 * WAD, 5) };
        assert!(matches!(live_observation(MarketStatus::Pre, &wide, NOW, &cfg), Err(Rejection::WideSpread { .. })));
    }

    #[test]
    fn closed_and_halted_have_no_live_price() {
        let input = LiveInput { trades: vec![trade(100 * WAD, 1, &["@"])], nbbo: quote(100 * WAD, 100 * WAD, 1) };
        for s in [MarketStatus::Closed, MarketStatus::Halted] {
            assert_eq!(
                live_observation(s, &input, NOW, &FilterConfig::default()),
                Err(Rejection::NotTrading(s))
            );
        }
    }

    #[test]
    fn future_prints_are_ignored() {
        let mut t = trade(100 * WAD, 0, &["@"]);
        t.ts_ns = (NOW + 10) * 1_000_000_000;
        let input = LiveInput { trades: vec![t], nbbo: quote(100 * WAD, 100 * WAD, 1) };
        assert_eq!(
            live_observation(MarketStatus::Regular, &input, NOW, &FilterConfig::default()),
            Err(Rejection::NoEligibleTrade)
        );
    }
}
