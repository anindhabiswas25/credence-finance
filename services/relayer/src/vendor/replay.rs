//! Replay vendor (§13.1): streams a recorded session as if it were live, for local runs and tests.
//! A stored Friday-to-Monday session can then run in minutes (`speed` > 1) against a time-warped
//! calendar carried in the recording's header.
//!
//! **Dev only.** It refuses to start on any chain that is not a local dev chain (anvil 31337,
//! nitro-devnode 412346), so it can never run on Arbitrum Sepolia (421614) or mainnet.
//!
//! Recording format: JSON lines, `ev` tagged, timestamps in ns (recording time):
//! ```text
//! {"ev":"header","venue":"XNYS","sessions":[{"extOpen":…,"open":…,"close":…,"extClose":…,"closureTypeAfter":1}]}
//! {"ev":"market","t":…,"m":"open"|"extended"|"closed"}
//! {"ev":"trade","t":…,"sym":"NVDA","p":181.25,"s":100,"x":"XNAS","c":["@"],"z":"C"}
//! {"ev":"quote","t":…,"sym":"NVDA","bp":181.24,"ap":181.26}
//! {"ev":"halt","t":…,"sym":"NVDA","halted":true,"reason":"LUDP"}
//! ```
//! On replay every timestamp is re-stamped to wall time: `wall = wallStart + (t − recStart) / speed`.

use super::{
    polygon::find_official, HaltInfo, LiveInput, MarketDataVendor, OfficialPrint, Quote,
    StatusInput, Trade, VendorError, VendorMarket, VendorResult,
};
use crate::{
    asset::{Asset, Plan},
    price::wad_from_f64,
};
use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use credence_common::{
    calendar::{Calendar, ClosureType, Session},
    is_dev_chain,
};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "ev", rename_all = "lowercase")]
pub enum Event {
    Header {
        venue: String,
        sessions: Vec<RawSession>,
    },
    Market {
        t: u64,
        m: String,
    },
    Trade {
        t: u64,
        sym: String,
        p: f64,
        s: u64,
        x: String,
        c: Vec<String>,
        z: Option<String>,
    },
    Quote {
        t: u64,
        sym: String,
        bp: f64,
        ap: f64,
    },
    Halt {
        t: u64,
        sym: String,
        halted: bool,
        reason: Option<String>,
    },
}

impl Event {
    fn t(&self) -> Option<u64> {
        match self {
            Self::Header { .. } => None,
            Self::Market { t, .. }
            | Self::Trade { t, .. }
            | Self::Quote { t, .. }
            | Self::Halt { t, .. } => Some(*t),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawSession {
    pub ext_open: u64,
    pub open: u64,
    pub close: u64,
    pub ext_close: u64,
    pub closure_type_after: u8,
}

/// Maps between recording time and wall time.
#[derive(Debug, Clone, Copy)]
pub struct Warp {
    pub rec_start_ns: u64,
    pub wall_start_ns: u64,
    pub speed: f64,
}

impl Warp {
    pub fn to_wall(&self, rec_ns: u64) -> u64 {
        let d = rec_ns.saturating_sub(self.rec_start_ns) as f64 / self.speed;
        self.wall_start_ns + d as u64
    }
    pub fn to_rec(&self, wall_ns: u64) -> u64 {
        let d = wall_ns.saturating_sub(self.wall_start_ns) as f64 * self.speed;
        self.rec_start_ns + d as u64
    }
}

pub struct Replay {
    events: Vec<Event>, // sorted by t, header removed
    calendar: Calendar,
    warp: Warp,
    clock: fn() -> u64,
}

fn wall_now_ns() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

impl Replay {
    /// Load a recording, starting the replay `start_offset_s` seconds into it (recording time).
    /// Fails on any non-dev chain.
    pub fn load(path: &Path, speed: f64, chain_id: u64, start_offset_s: u64) -> Result<Self> {
        let raw =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let events = raw
            .lines()
            .filter(|l| !l.trim().is_empty())
            .enumerate()
            .map(|(i, l)| {
                serde_json::from_str::<Event>(l).with_context(|| format!("line {}", i + 1))
            })
            .collect::<Result<Vec<_>>>()?;
        // recording start maps to "now − offset" (wall), so the replay is `offset` seconds in right away
        let offset_wall_ns = (start_offset_s as f64 * 1e9 / speed) as u64;
        Self::from_events(
            events,
            speed,
            chain_id,
            wall_now_ns().saturating_sub(offset_wall_ns),
        )
    }

    /// Build from events, starting the replay at `wall_start_ns`.
    pub fn from_events(
        mut events: Vec<Event>,
        speed: f64,
        chain_id: u64,
        wall_start_ns: u64,
    ) -> Result<Self> {
        if !is_dev_chain(chain_id) {
            bail!("the replay vendor is a dev tool and refuses to run on chain {chain_id} (only 31337 / 412346)");
        }
        if !(speed.is_finite() && speed > 0.0) {
            bail!("replay speed must be > 0");
        }
        let header = events
            .iter()
            .position(|e| matches!(e, Event::Header { .. }));
        let Some(Event::Header { venue, sessions }) = header.map(|i| events.remove(i)) else {
            bail!("recording has no header line");
        };
        events.sort_by_key(|e| e.t().unwrap_or(0));
        let rec_start_ns = events
            .first()
            .and_then(|e| e.t())
            .context("recording has no events")?;
        let warp = Warp {
            rec_start_ns,
            wall_start_ns,
            speed,
        };
        let s = |t: u64| warp.to_wall(t * 1_000_000_000) / 1_000_000_000;
        let sessions = sessions
            .iter()
            .map(|r| {
                Ok(Session {
                    ext_open: s(r.ext_open),
                    open: s(r.open),
                    close: s(r.close),
                    ext_close: s(r.ext_close),
                    closure_type_after: ClosureType::try_from(r.closure_type_after)?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let calendar = Calendar::from_sessions(&venue, sessions)?;
        Ok(Self {
            events,
            calendar,
            warp,
            clock: wall_now_ns,
        })
    }

    /// Replace the wall clock (tests).
    pub fn with_clock(mut self, clock: fn() -> u64) -> Self {
        self.clock = clock;
        self
    }

    /// The recording's sessions re-stamped to wall time.
    pub fn calendar(&self) -> &Calendar {
        &self.calendar
    }

    pub fn warp(&self) -> Warp {
        self.warp
    }

    fn visible(&self) -> &[Event] {
        let now_rec = self.warp.to_rec((self.clock)());
        let n = self
            .events
            .partition_point(|e| e.t().unwrap_or(0) <= now_rec);
        &self.events[..n]
    }

    fn trade(&self, e: &Event, listing_plan: Plan) -> Option<Trade> {
        let Event::Trade {
            t, p, s, x, c, z, ..
        } = e
        else {
            return None;
        };
        Some(Trade {
            price_wad: wad_from_f64(*p).ok()?,
            size: *s,
            ts_ns: self.warp.to_wall(*t),
            exchange: x.clone(),
            conditions: c.clone(),
            plan: z
                .as_deref()
                .and_then(Plan::from_tape)
                .unwrap_or(listing_plan),
        })
    }

    fn trades_for(&self, asset: &Asset) -> Vec<Trade> {
        let mut v: Vec<Trade> = self
            .visible()
            .iter()
            .filter(|e| matches!(e, Event::Trade { sym, .. } if *sym == asset.symbol))
            .filter_map(|e| self.trade(e, asset.plan()))
            .collect();
        v.reverse(); // newest first
        v
    }
}

#[async_trait]
impl MarketDataVendor for Replay {
    fn name(&self) -> &'static str {
        "replay"
    }

    async fn live(&self, asset: &Asset, since_ns: u64) -> VendorResult<LiveInput> {
        let trades: Vec<Trade> = self
            .trades_for(asset)
            .into_iter()
            .filter(|t| t.ts_ns >= since_ns)
            .take(1000)
            .collect();
        let nbbo = self.visible().iter().rev().find_map(|e| match e {
            Event::Quote { t, sym, bp, ap } if *sym == asset.symbol => Some(Quote {
                bid_wad: wad_from_f64(*bp).ok()?,
                ask_wad: wad_from_f64(*ap).ok()?,
                ts_ns: self.warp.to_wall(*t),
            }),
            _ => None,
        });
        Ok(LiveInput { trades, nbbo })
    }

    async fn official_open(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        let lo = session.open * 1_000_000_000;
        let hi = (session.open + 15 * 60) * 1_000_000_000;
        let t: Vec<Trade> = self
            .trades_for(asset)
            .into_iter()
            .filter(|t| t.ts_ns >= lo && t.ts_ns < hi)
            .collect();
        Ok(find_official(&t, &asset.listing, true))
    }

    async fn official_close(
        &self,
        asset: &Asset,
        session: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        let lo = session.close * 1_000_000_000;
        let hi = (session.close + 30 * 60) * 1_000_000_000;
        let t: Vec<Trade> = self
            .trades_for(asset)
            .into_iter()
            .filter(|t| t.ts_ns >= lo && t.ts_ns < hi)
            .collect();
        Ok(find_official(&t, &asset.listing, false))
    }

    async fn status(&self, asset: &Asset) -> VendorResult<StatusInput> {
        let vis = self.visible();
        let market = vis
            .iter()
            .rev()
            .find_map(|e| match e {
                Event::Market { m, .. } => Some(match m.as_str() {
                    "open" => VendorMarket::Open,
                    "extended" => VendorMarket::Extended,
                    "closed" => VendorMarket::Closed,
                    _ => VendorMarket::Unknown,
                }),
                _ => None,
            })
            .ok_or_else(|| {
                VendorError::Other("replay has not reached a market event yet".into())
            })?;
        let halt = vis
            .iter()
            .rev()
            .find_map(|e| match e {
                Event::Halt {
                    sym,
                    halted,
                    reason,
                    ..
                } if *sym == asset.symbol => Some(HaltInfo {
                    halted: *halted,
                    reason: reason.clone(),
                }),
                _ => None,
            })
            .or(Some(HaltInfo {
                halted: false,
                reason: None,
            }));
        Ok(StatusInput { market, halt })
    }
}

/// A synthetic but realistically shaped one-session recording (tests and quick local runs when no
/// real recording is at hand): pre-market, the opening auction print (`Q` from the listing market),
/// regular trades with NBBO, a LULD halt and resumption, the closing print (`M`), post-market Form T.
pub fn synthetic_session(symbols: &[(&str, &str, f64)], open_s: u64) -> Vec<Event> {
    let ns = |s: u64| s * 1_000_000_000;
    let close_s = open_s + 6 * 3600 + 30 * 60;
    let mut ev = vec![Event::Header {
        venue: "XNYS".into(),
        sessions: vec![RawSession {
            ext_open: open_s - 13 * 3600 - 30 * 60,
            open: open_s,
            close: close_s,
            ext_close: close_s + 4 * 3600,
            closure_type_after: 1,
        }],
    }];
    ev.push(Event::Market {
        t: ns(open_s - 3600),
        m: "extended".into(),
    });
    ev.push(Event::Market {
        t: ns(open_s),
        m: "open".into(),
    });
    ev.push(Event::Market {
        t: ns(close_s),
        m: "extended".into(),
    });
    for (sym, listing, base) in symbols {
        let x = listing.to_string();
        let tape = if *listing == "XNAS" { "C" } else { "A" };
        let trade = |t: u64, p: f64, c: &[&str], x: &str| Event::Trade {
            t,
            sym: sym.to_string(),
            p,
            s: 100,
            x: x.into(),
            c: c.iter().map(|s| s.to_string()).collect(),
            z: Some(tape.into()),
        };
        let quote = |t: u64, mid: f64| Event::Quote {
            t,
            sym: sym.to_string(),
            bp: mid - 0.01,
            ap: mid + 0.01,
        };
        // pre-market Form T prints every 30 s for the last 10 minutes
        for i in 0..20u64 {
            let t = ns(open_s - 600 + i * 30);
            ev.push(quote(t, *base));
            ev.push(trade(t + 1, *base, &["@", "T"], "ARCX"));
        }
        // opening auction print from the listing market, then regular trading every 2 s for the session
        ev.push(trade(ns(open_s) + 50_000_000, *base, &["Q"], &x));
        ev.push(trade(ns(open_s) + 50_000_001, *base, &["@", "O"], &x));
        let mut p = *base;
        let mut t = open_s + 2;
        while t < close_s {
            p *= 1.0 + 0.0004 * (((t / 2) % 7) as f64 - 3.0) / 3.0; // gentle deterministic walk
            p = (p * 100.0).round() / 100.0;
            ev.push(quote(ns(t), p));
            ev.push(trade(ns(t) + 1_000, p, &["@"], "XNAS"));
            if t.is_multiple_of(60) {
                ev.push(trade(ns(t) + 2_000, p * 1.02, &["@", "I"], "FINR")); // odd lot outlier: filtered
            }
            t += 2;
        }
        // a LULD pause mid-session (5 minutes)
        ev.push(Event::Halt {
            t: ns(open_s + 3 * 3600),
            sym: sym.to_string(),
            halted: true,
            reason: Some("LUDP".into()),
        });
        ev.push(Event::Halt {
            t: ns(open_s + 3 * 3600 + 300),
            sym: sym.to_string(),
            halted: false,
            reason: None,
        });
        ev.push(trade(ns(close_s) + 10_000_000, p, &["M"], &x));
        for i in 1..10u64 {
            ev.push(quote(ns(close_s + i * 60), p));
            ev.push(trade(ns(close_s + i * 60) + 1, p, &["@", "T"], "ARCX"));
        }
    }
    ev
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::price::WAD;

    const OPEN: u64 = 1_790_000_000;

    fn clock_at_open_plus_60() -> u64 {
        // replay started (wall) at OPEN − 3600 − 1 s … see `replay()`
        (OPEN + 60) * 1_000_000_000
    }

    fn replay() -> Replay {
        let ev = synthetic_session(&[("NVDA", "XNAS", 180.0)], OPEN);
        // wall == recording time (start the replay at the recording's first event)
        let first = ev.iter().filter_map(|e| e.t()).min().unwrap();
        Replay::from_events(ev, 1.0, 31_337, first)
            .unwrap()
            .with_clock(clock_at_open_plus_60)
    }

    #[test]
    fn refuses_arbitrum_sepolia_and_mainnet() {
        let ev = synthetic_session(&[("NVDA", "XNAS", 180.0)], OPEN);
        for chain in [421_614u64, 42_161, 1] {
            let err = Replay::from_events(ev.clone(), 1.0, chain, 0)
                .err()
                .unwrap();
            assert!(err.to_string().contains("refuses"), "{chain}");
        }
        assert!(Replay::from_events(ev, 1.0, 412_346, 0).is_ok());
    }

    #[tokio::test]
    async fn serves_live_open_and_status_at_replay_time() {
        let r = replay();
        let a = Asset::parse("NVDA:XNAS").unwrap();
        let live = r.live(&a, (OPEN - 10) * 1_000_000_000).await.unwrap();
        assert!(!live.trades.is_empty());
        assert!(
            live.trades
                .iter()
                .all(|t| t.ts_ns <= clock_at_open_plus_60()),
            "no future events"
        );
        assert!(
            live.trades.windows(2).all(|w| w[0].ts_ns >= w[1].ts_ns),
            "newest first"
        );
        assert!(live.nbbo.is_some());
        let s = r.calendar().sessions[0];
        assert_eq!(s.open, OPEN);
        let o = r.official_open(&a, &s).await.unwrap().unwrap();
        assert_eq!((o.price_wad, o.at), (180 * WAD, OPEN));
        assert!(
            r.official_close(&a, &s).await.unwrap().is_none(),
            "close not reached yet"
        );
        let st = r.status(&a).await.unwrap();
        assert_eq!(st.market, VendorMarket::Open);
        assert!(!st.halt.unwrap().halted);
    }

    #[test]
    fn warp_speeds_up_time() {
        let w = Warp {
            rec_start_ns: 1_000,
            wall_start_ns: 10_000,
            speed: 60.0,
        };
        assert_eq!(w.to_wall(1_000 + 60_000), 11_000);
        assert_eq!(w.to_rec(11_000), 61_000);
    }

    #[test]
    fn warped_calendar_is_compressed() {
        let ev = synthetic_session(&[("NVDA", "XNAS", 180.0)], OPEN);
        let r = Replay::from_events(ev, 60.0, 31_337, 5_000_000_000_000_000_000).unwrap();
        let s = r.calendar().sessions[0];
        assert!(
            (389..=391).contains(&(s.close - s.open)),
            "6.5 h at 60× is 6.5 min"
        );
    }
}
