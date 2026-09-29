//! Calendar-driven trigger source for J1 (§10.2): every session boundary — extOpen, open, close,
//! extClose, bellWindowAt (close − 2 h) and bellAt (close − 15 min) — fires at boundary + 1 s, plus a
//! 60 s heartbeat. Missed boundaries within `lookback` are still due after a restart; the idempotency
//! keys in `ops.keeper_job` make sure each is acted on once.
//!
//! The Bell offsets come from the chain (S4 A): `AssetClock.BELL_WINDOW` / `BELL_DEADLINE`, the same
//! constants the clock uses for `closureInfo.bellWindowAt` / `bellAt`, so the keeper and the contracts
//! cannot drift. The constants below are only a startup self-check ([`BellLeads::self_check`]).

use alloy::{primitives::Address, primitives::B256, providers::DynProvider};
use anyhow::Result;
use credence_common::calendar::Calendar;
use std::sync::Arc;

pub const TRIGGER_DELAY_S: u64 = 1;
pub const HEARTBEAT_S: u64 = 60;
/// §8.2.2 values the keeper was written against; used only to warn when the chain differs.
pub const BELL_WINDOW_LEAD_S: u64 = 2 * 3600;
pub const BELL_LEAD_S: u64 = 15 * 60;

/// How long before a scheduled close the Bell window opens and the Bell deadline falls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BellLeads {
    /// close − bellWindowAt
    pub window_s: u64,
    /// close − bellAt
    pub deadline_s: u64,
}

impl Default for BellLeads {
    fn default() -> Self {
        Self {
            window_s: BELL_WINDOW_LEAD_S,
            deadline_s: BELL_LEAD_S,
        }
    }
}

impl BellLeads {
    pub fn bell_window_at(&self, close: u64) -> u64 {
        close.saturating_sub(self.window_s)
    }
    pub fn bell_at(&self, close: u64) -> u64 {
        close.saturating_sub(self.deadline_s)
    }

    /// Read `BELL_WINDOW` / `BELL_DEADLINE` from the AssetClock.
    pub async fn read(p: &DynProvider, clock: Address) -> Result<Self> {
        let c = crate::bindings::IAssetClock::new(clock, p);
        let window = c.BELL_WINDOW().call().await?;
        let deadline = c.BELL_DEADLINE().call().await?;
        let b = Self {
            window_s: window.to::<u64>(),
            deadline_s: deadline.to::<u64>(),
        };
        anyhow::ensure!(
            b.deadline_s > 0 && b.deadline_s < b.window_s,
            "AssetClock Bell offsets make no sense: window {} s, deadline {} s",
            b.window_s,
            b.deadline_s
        );
        Ok(b)
    }

    /// The startup self-check: a warning when the chain's offsets differ from the keeper's constants.
    pub fn self_check(&self) -> Option<String> {
        let built = Self::default();
        (*self != built).then(|| {
            format!(
                "AssetClock Bell offsets (window {} s, deadline {} s) differ from the keeper's constants \
                 (window {} s, deadline {} s): using the chain's",
                self.window_s, self.deadline_s, built.window_s, built.deadline_s
            )
        })
    }
}

/// An asset the keeper pokes, with its venue's calendar.
#[derive(Debug, Clone)]
pub struct Tracked {
    pub id: B256,
    pub label: String,
    pub venue: String,
    pub calendar: Arc<Calendar>,
}

/// Every J1 boundary in `(from, to]`, ascending.
pub fn boundaries(cal: &Calendar, from: u64, to: u64, bell: BellLeads) -> Vec<u64> {
    let mut v = cal.boundaries_between(from, to);
    for s in &cal.sessions {
        for b in [bell.bell_window_at(s.close), bell.bell_at(s.close)] {
            if b > from && b <= to {
                v.push(b);
            }
        }
    }
    v.sort_unstable();
    v.dedup();
    v
}

/// Boundaries due at `now` (fired at boundary + 1 s) that are at most `lookback` seconds old.
pub fn due(cal: &Calendar, now: u64, lookback: u64, bell: BellLeads) -> Vec<u64> {
    let upto = now.saturating_sub(TRIGGER_DELAY_S);
    boundaries(cal, upto.saturating_sub(lookback), upto, bell)
}

pub fn j1_key(asset: &B256, boundary: u64) -> String {
    format!("J1:{asset}:{boundary}")
}

pub fn j1_heartbeat_key(asset: &B256, now: u64) -> String {
    format!("J1:{asset}:hb:{}", now / HEARTBEAT_S * HEARTBEAT_S)
}

pub fn j12_key(check: &str, now: u64) -> String {
    let day = chrono::DateTime::from_timestamp(now as i64, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    format!("J12:{check}:{day}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cal() -> Calendar {
        Calendar::load(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../calibration/out/calendars/XNYS-20261001-20271031.json"
        ))
        .unwrap()
    }

    #[test]
    fn a_weekday_has_six_boundaries_plus_the_previous_overnight_open() {
        let c = cal();
        // Wed 2026-10-07: open 13:30Z, close 20:00Z
        let open = 1_791_379_800;
        let close = open + 23_400;
        let b = boundaries(&c, open - 1, close + 4 * 3600, BellLeads::default());
        assert_eq!(
            b,
            vec![open, close - 7200, close - 900, close, close + 4 * 3600]
        );
        // the session's extClose (20:00 ET) is also the next session's extOpen: one boundary, not two
    }

    #[test]
    fn due_fires_one_second_after_and_respects_lookback() {
        let c = cal();
        let open = 1_791_379_800;
        let d = BellLeads::default();
        assert!(
            due(&c, open, 600, d).is_empty(),
            "not before boundary + 1 s"
        );
        assert_eq!(due(&c, open + 1, 600, d), vec![open]);
        assert_eq!(due(&c, open + 500, 600, d), vec![open]);
        assert!(due(&c, open + 700, 600, d).is_empty(), "beyond lookback");
    }

    #[test]
    fn bell_boundaries_follow_the_chain_offsets() {
        let c = cal();
        let open = 1_791_379_800;
        let close = open + 23_400;
        // a clock with a 3 h window and a 20 min deadline: the J1 boundaries move with it
        let chain = BellLeads {
            window_s: 3 * 3600,
            deadline_s: 20 * 60,
        };
        let b = boundaries(&c, open - 1, close + 4 * 3600, chain);
        assert_eq!(
            b,
            vec![open, close - 10_800, close - 1_200, close, close + 4 * 3600]
        );
        assert!(chain.self_check().unwrap().contains("differ"));
        assert_eq!(BellLeads::default().self_check(), None);
        assert_eq!(chain.bell_at(close), close - 1_200);
        assert_eq!(chain.bell_window_at(close), close - 10_800);
    }

    #[test]
    fn keys() {
        let a = B256::repeat_byte(1);
        assert_eq!(j1_heartbeat_key(&a, 119), j1_heartbeat_key(&a, 61));
        assert_ne!(j1_heartbeat_key(&a, 120), j1_heartbeat_key(&a, 119));
        assert_eq!(
            j12_key("coverage", 1_791_379_800),
            "J12:coverage:2026-10-07"
        );
    }
}
