//! Publication cadence (§10.1; gas, PM 01:20 with the user's agreement):
//!
//! | Kind              | Heartbeat                                   | Deviation trigger |
//! | ----------------- | ------------------------------------------- | ----------------- |
//! | LIVE, REGULAR     | 45 s, or the published price ≥ 50 s old     | ≥ 0.10%           |
//! | LIVE, EXTENDED    | 60 s, or the published price ≥ 240 s old    | ≥ 0.25%           |
//! | STATUS            | 60 s                                        | on change         |
//! | OPEN / CLOSE      | once per session                                                |
//!
//! "Old" is the age of the published price's `observedAt` by the next tick: OracleAdapter's staleness (60 s REGULAR,
//! 300 s EXTENDED) counts from it, and a RedStone package is already 10–25 s old when it is observed, so a wall-clock
//! heartbeat alone would let the on-chain price go stale. **Coalescing:** once a batch is due anyway, every LIVE and
//! STATUS report that would be due within `coalesce_s` rides along, so the assets' heartbeats share one transaction.

use crate::{price::deviation_ppm, report::MarketStatus};
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rule {
    pub heartbeat_s: u64,
    pub move_ppm: u128,
    /// Publish before the published price's observedAt is this old at the next tick.
    pub max_age_s: u64,
}

pub const REGULAR: Rule = Rule {
    heartbeat_s: 45,
    move_ppm: 1_000,
    max_age_s: 50,
};
pub const EXTENDED: Rule = Rule {
    heartbeat_s: 60,
    move_ppm: 2_500,
    max_age_s: 240,
};
pub const STATUS_HEARTBEAT_S: u64 = 60;
pub const COALESCE_S: u64 = 20;

/// The aggregator's cadence (`RELAYER_HEARTBEAT_REGULAR_S`, `RELAYER_MAX_AGE_REGULAR_S`, `RELAYER_HEARTBEAT_EXTENDED_S`,
/// `RELAYER_MAX_AGE_EXTENDED_S`, `RELAYER_COALESCE_S`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CadenceConfig {
    pub regular: Rule,
    pub extended: Rule,
    pub status_heartbeat_s: u64,
    pub coalesce_s: u64,
    /// The aggregator's tick: the age rule looks one tick ahead.
    pub tick_s: u64,
}

impl Default for CadenceConfig {
    fn default() -> Self {
        Self {
            regular: REGULAR,
            extended: EXTENDED,
            status_heartbeat_s: STATUS_HEARTBEAT_S,
            coalesce_s: COALESCE_S,
            tick_s: 10,
        }
    }
}

impl CadenceConfig {
    pub fn live_rule(&self, status: MarketStatus) -> Option<Rule> {
        match status {
            MarketStatus::Regular => Some(self.regular),
            s if s.is_extended() => Some(self.extended),
            _ => None,
        }
    }
}

pub fn live_rule(status: MarketStatus) -> Option<Rule> {
    CadenceConfig::default().live_rule(status)
}

/// The last LIVE report accepted on-chain for one asset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Published {
    pub price: u128,
    /// Wall time it was accepted (unix s).
    pub at: u64,
    pub status: MarketStatus,
    /// Its observedAt (unix s): the on-chain staleness counts from it.
    pub observed_at: u64,
}

/// What was last published (accepted on-chain) for one asset.
#[derive(Debug, Clone, Default)]
pub struct AssetCadence {
    pub live: Option<Published>,
    pub status: Option<(MarketStatus, u64)>,
    pub opens: HashSet<u64>,  // sessionDate
    pub closes: HashSet<u64>, // sessionDate
}

impl AssetCadence {
    /// Should a LIVE report at `price` be published at `now` (default cadence, no coalescing)?
    pub fn live_due(&self, status: MarketStatus, price: u128, now: u64) -> bool {
        self.live_due_with(&CadenceConfig::default(), status, price, now, 0)
    }

    /// Should a LIVE report at `price` be published at `now`, counting time-based triggers `lead_s` early
    /// (coalescing)?
    pub fn live_due_with(
        &self,
        cfg: &CadenceConfig,
        status: MarketStatus,
        price: u128,
        now: u64,
        lead_s: u64,
    ) -> bool {
        let Some(rule) = cfg.live_rule(status) else {
            return false;
        };
        let t = now + lead_s;
        match self.live {
            None => true,
            // entering a new session phase always publishes
            Some(p) if p.status != status => true,
            Some(p) => {
                t.saturating_sub(p.at) >= rule.heartbeat_s
                    || (t + cfg.tick_s).saturating_sub(p.observed_at) >= rule.max_age_s
                    || deviation_ppm(price, p.price) >= rule.move_ppm
            }
        }
    }

    pub fn status_due(&self, status: MarketStatus, now: u64) -> bool {
        self.status_due_with(&CadenceConfig::default(), status, now, 0)
    }

    pub fn status_due_with(
        &self,
        cfg: &CadenceConfig,
        status: MarketStatus,
        now: u64,
        lead_s: u64,
    ) -> bool {
        match self.status {
            None => true,
            Some((s, at)) => s != status || (now + lead_s).saturating_sub(at) >= cfg.status_heartbeat_s,
        }
    }

    pub fn open_due(&self, session_date: u64) -> bool {
        !self.opens.contains(&session_date)
    }

    pub fn close_due(&self, session_date: u64) -> bool {
        !self.closes.contains(&session_date)
    }

    /// A LIVE report accepted at `now`, observed at `observed_at`.
    pub fn mark_live(&mut self, price: u128, now: u64, status: MarketStatus, observed_at: u64) {
        self.live = Some(Published {
            price,
            at: now,
            status,
            observed_at,
        });
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
        assert!(
            c.live_due(MarketStatus::Regular, 100 * WAD, 0),
            "first print publishes"
        );
        // a fresh observation (observedAt = now): the 45 s heartbeat
        c.mark_live(100 * WAD, 0, MarketStatus::Regular, 0);
        assert!(!c.live_due(MarketStatus::Regular, 100 * WAD, 39));
        assert!(
            c.live_due(MarketStatus::Regular, 100 * WAD, 40),
            "age 40 + the 10 s tick reaches 50 s"
        );
        // a lagging source (observed 20 s before it was published): the age rule fires first
        c.mark_live(100 * WAD, 100, MarketStatus::Regular, 80);
        assert!(!c.live_due(MarketStatus::Regular, 100 * WAD, 119));
        assert!(c.live_due(MarketStatus::Regular, 100 * WAD, 120));
        // 0.0999% move: not yet
        assert!(!c.live_due(MarketStatus::Regular, 100_099 * WAD / 1000, 1));
        // 0.10% move: immediately
        assert!(c.live_due(MarketStatus::Regular, 100_100 * WAD / 1000, 1));
        assert!(
            c.live_due(MarketStatus::Regular, 99_900 * WAD / 1000, 1),
            "down moves count too"
        );
    }

    #[test]
    fn extended_heartbeat_and_move() {
        let mut c = AssetCadence::default();
        c.mark_live(100 * WAD, 0, MarketStatus::Post, 0);
        assert!(!c.live_due(MarketStatus::Post, 100 * WAD, 59));
        assert!(c.live_due(MarketStatus::Post, 100 * WAD, 60));
        assert!(!c.live_due(MarketStatus::Post, 100_240 * WAD / 1000, 5));
        assert!(
            c.live_due(MarketStatus::Post, 100_250 * WAD / 1000, 5),
            "0.25%"
        );
    }

    #[test]
    fn phase_change_publishes_and_closed_never_does() {
        let mut c = AssetCadence::default();
        c.mark_live(100 * WAD, 0, MarketStatus::Pre, 0);
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
    fn coalescing_counts_the_time_triggers_early() {
        let cfg = CadenceConfig::default();
        let mut c = AssetCadence::default();
        c.mark_live(100 * WAD, 0, MarketStatus::Regular, 0);
        c.mark_status(MarketStatus::Regular, 0);
        assert!(!c.live_due_with(&cfg, MarketStatus::Regular, 100 * WAD, 20, 0));
        assert!(c.live_due_with(&cfg, MarketStatus::Regular, 100 * WAD, 20, cfg.coalesce_s));
        assert!(!c.status_due_with(&cfg, MarketStatus::Regular, 39, cfg.coalesce_s));
        assert!(c.status_due_with(&cfg, MarketStatus::Regular, 40, cfg.coalesce_s));
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
