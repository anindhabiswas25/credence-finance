//! Calendar-driven trigger source for J1 (§10.2): every session boundary — extOpen, open, close,
//! extClose, bellWindowAt (close − 2 h) and bellAt (close − 15 min) — fires at boundary + 1 s, plus a
//! 60 s heartbeat. Missed boundaries within `lookback` are still due after a restart; the idempotency
//! keys in `ops.keeper_job` make sure each is acted on once.

use alloy::primitives::B256;
use credence_common::calendar::Calendar;
use std::sync::Arc;

pub const TRIGGER_DELAY_S: u64 = 1;
pub const HEARTBEAT_S: u64 = 60;
pub const BELL_WINDOW_LEAD_S: u64 = 2 * 3600;
pub const BELL_LEAD_S: u64 = 15 * 60;

/// An asset the keeper pokes, with its venue's calendar.
#[derive(Debug, Clone)]
pub struct Tracked {
    pub id: B256,
    pub label: String,
    pub venue: String,
    pub calendar: Arc<Calendar>,
}

/// Every J1 boundary in `(from, to]`, ascending.
pub fn boundaries(cal: &Calendar, from: u64, to: u64) -> Vec<u64> {
    let mut v = cal.boundaries_between(from, to);
    for s in &cal.sessions {
        for b in [
            s.close.saturating_sub(BELL_WINDOW_LEAD_S),
            s.close.saturating_sub(BELL_LEAD_S),
        ] {
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
pub fn due(cal: &Calendar, now: u64, lookback: u64) -> Vec<u64> {
    let upto = now.saturating_sub(TRIGGER_DELAY_S);
    boundaries(cal, upto.saturating_sub(lookback), upto)
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
        let b = boundaries(&c, open - 1, close + 4 * 3600);
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
        assert!(due(&c, open, 600).is_empty(), "not before boundary + 1 s");
        assert_eq!(due(&c, open + 1, 600), vec![open]);
        assert_eq!(due(&c, open + 500, 600), vec![open]);
        assert!(due(&c, open + 700, 600).is_empty(), "beyond lookback");
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
