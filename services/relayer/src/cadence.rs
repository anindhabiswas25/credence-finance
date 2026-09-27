//! Publication cadence (§10.1):
//!
//! | Kind              | Heartbeat | Deviation trigger |
//! | ----------------- | --------- | ----------------- |
//! | LIVE, REGULAR     | 10 s      | ≥ 0.10%           |
//! | LIVE, EXTENDED    | 60 s      | ≥ 0.25%           |
//! | STATUS            | 60 s      | on change         |
//! | OPEN / CLOSE      | once per session                |

use crate::{price::deviation_ppm, report::MarketStatus};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rule {
    pub heartbeat_s: u64,
    pub move_ppm: u128,
}

pub const REGULAR: Rule = Rule { heartbeat_s: 10, move_ppm: 1_000 };
pub const EXTENDED: Rule = Rule { heartbeat_s: 60, move_ppm: 2_500 };
pub const STATUS_HEARTBEAT_S: u64 = 60;

pub fn live_rule(status: MarketStatus) -> Option<Rule> {
    match status {
        MarketStatus::Regular => Some(REGULAR),
        s if s.is_extended() => Some(EXTENDED),
        _ => None,
    }
}

/// What was last published (accepted on-chain) for one asset.
#[derive(Debug, Clone, Default)]
pub struct AssetCadence {
    pub live: Option<(u128, u64, MarketStatus)>, // price, published at (wall s), status
    pub status: Option<(MarketStatus, u64)>,
    pub opens: HashSet<u64>,  // sessionDate
    pub closes: HashSet<u64>, // sessionDate
}

impl AssetCadence {
    /// Should a LIVE report at `price` be published at `now`?
    pub fn live_due(&self, status: MarketStatus, price: u128, now: u64) -> bool {
        let Some(rule) = live_rule(status) else { return false };
        match self.live {
            None => true,
            // entering a new session phase always publishes
            Some((_, _, last_status)) if last_status != status => true,
            Some((last_price, at, _)) => {
                now.saturating_sub(at) >= rule.heartbeat_s || deviation_ppm(price, last_price) >= rule.move_ppm
            }
        }
    }

    pub fn status_due(&self, status: MarketStatus, now: u64) -> bool {
        match self.status {
            None => true,
            Some((s, at)) => s != status || now.saturating_sub(at) >= STATUS_HEARTBEAT_S,
        }
    }

    pub fn open_due(&self, session_date: u64) -> bool {
        !self.opens.contains(&session_date)
    }

    pub fn close_due(&self, session_date: u64) -> bool {
        !self.closes.contains(&session_date)
    }

    pub fn mark_live(&mut self, price: u128, now: u64, status: MarketStatus) {
        self.live = Some((price, now, status));
    }

    pub fn mark_status(&mut self, status: MarketStatus, now: u64) {
        self.status = Some((status, now));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::price::WAD;

    #[test]
    fn regular_heartbeat_and_move() {
        let mut c = AssetCadence::default();
        assert!(c.live_due(MarketStatus::Regular, 100 * WAD, 0), "first print publishes");
        c.mark_live(100 * WAD, 0, MarketStatus::Regular);
        assert!(!c.live_due(MarketStatus::Regular, 100 * WAD, 9));
        assert!(c.live_due(MarketStatus::Regular, 100 * WAD, 10), "10 s heartbeat");
        // 0.0999% move: not yet
        assert!(!c.live_due(MarketStatus::Regular, 100_099 * WAD / 1000, 1));
        // 0.10% move: immediately
        assert!(c.live_due(MarketStatus::Regular, 100_100 * WAD / 1000, 1));
        assert!(c.live_due(MarketStatus::Regular, 99_900 * WAD / 1000, 1), "down moves count too");
    }

    #[test]
    fn extended_heartbeat_and_move() {
        let mut c = AssetCadence::default();
        c.mark_live(100 * WAD, 0, MarketStatus::Post);
        assert!(!c.live_due(MarketStatus::Post, 100 * WAD, 59));
        assert!(c.live_due(MarketStatus::Post, 100 * WAD, 60));
        assert!(!c.live_due(MarketStatus::Post, 100_240 * WAD / 1000, 5));
        assert!(c.live_due(MarketStatus::Post, 100_250 * WAD / 1000, 5), "0.25%");
    }

    #[test]
    fn phase_change_publishes_and_closed_never_does() {
        let mut c = AssetCadence::default();
        c.mark_live(100 * WAD, 0, MarketStatus::Pre);
        assert!(c.live_due(MarketStatus::Regular, 100 * WAD, 1));
        assert!(!c.live_due(MarketStatus::Closed, 100 * WAD, 1000));
        assert!(!c.live_due(MarketStatus::Halted, 100 * WAD, 1000));
    }

    #[test]
    fn status_on_change_and_heartbeat() {
        let mut c = AssetCadence::default();
        assert!(c.status_due(MarketStatus::Regular, 0));
        c.mark_status(MarketStatus::Regular, 0);
        assert!(!c.status_due(MarketStatus::Regular, 59));
        assert!(c.status_due(MarketStatus::Regular, 60));
        assert!(c.status_due(MarketStatus::Halted, 1));
    }

    #[test]
    fn open_and_close_once_per_session() {
        let mut c = AssetCadence::default();
        assert!(c.open_due(20_717));
        c.opens.insert(20_717);
        assert!(!c.open_due(20_717));
        assert!(c.open_due(20_718));
        assert!(c.close_due(20_717));
    }
}
