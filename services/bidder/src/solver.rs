//! Test solver bot for the NAV stack's `SolverAuction` (§8.8, S4 C; dev chains only). Each configured solver
//! watches the solver windows (`SolverWindowOpened`) and, per its profile, bids so a NAV settlement clears
//! without a human:
//!
//! * the first bid is `floor × (1 + premiumBps)` (never below the venue's `minBid`);
//! * when outbid, it re-bids the venue's `minBid` (= max(floor, best × 1.0001) rounded up) while that stays
//!   within `floor × (1 + maxBps)`;
//! * a **no-bid** profile (`bid: false`) never bids, so the window ends empty and `finalize` takes the
//!   pool's `fallbackAdvance` path.
//!
//! The contract enforces the rules (allowlisted solver, price ≥ floor and ≥ 1.0001 × best, escrow); the bot
//! only pre-checks them so it never sends a bid that would revert.

use alloy::primitives::{Address, U256};
use serde::{Deserialize, Serialize};

use crate::BPS;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SolverProfile {
    pub name: String,
    /// Hex private key: dev chains only. Empty (or absent): the keystore `$KEYSTORE_DIR/<chainId>/solver-<name>.json`
    /// or `SOLVER_<NAME>_KEYSTORE` / `_KMS_KEY_ID` (ADR-0014), which also work on a testnet.
    #[serde(default)]
    pub key: String,
    /// false = never bids (forces the pool-advance fallback).
    #[serde(default = "yes")]
    pub bid: bool,
    /// First bid above the floor, in bps.
    #[serde(default)]
    pub premium_bps: u32,
    /// Highest price it will pay above the floor, in bps.
    #[serde(default = "ten_bps")]
    pub max_bps: u32,
}

fn yes() -> bool {
    true
}
fn ten_bps() -> u32 {
    10
}

#[derive(Debug, Clone, Deserialize)]
pub struct SolverConfig {
    pub solvers: Vec<SolverProfile>,
}

/// What the venue shows for one window (`lot(id)` and `minBid(id)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Window {
    pub floor: U256,
    pub best: Address,
    pub best_price: U256,
    pub ends_at: u64,
    pub finalized: bool,
    pub min_bid: U256,
}

fn bps_of(x: U256, bps: u32) -> U256 {
    x * U256::from(BPS + bps as u128) / U256::from(BPS)
}

/// The price `me` should bid now, or `None`.
pub fn solver_bid(p: &SolverProfile, me: Address, w: &Window, now: u64) -> Option<U256> {
    if !p.bid || w.finalized || now >= w.ends_at || w.best == me || w.floor.is_zero() {
        return None;
    }
    let cap = bps_of(w.floor, p.max_bps);
    let price = if w.best_price.is_zero() {
        bps_of(w.floor, p.premium_bps).max(w.min_bid)
    } else {
        w.min_bid
    };
    (price >= w.floor && price >= w.min_bid && price <= cap).then_some(price)
}

/// `best × 1.0001` rounded up (the venue's increment rule), for tests and logs.
pub fn min_increment(best: U256) -> U256 {
    (best * U256::from(10_001u64)).div_ceil(U256::from(10_000u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    const WAD: u128 = 1_000_000_000_000_000_000;

    fn prof(bid: bool, premium: u32, max: u32) -> SolverProfile {
        SolverProfile {
            name: "s".into(),
            key: String::new(),
            bid,
            premium_bps: premium,
            max_bps: max,
        }
    }
    fn win(best: Address, best_price: U256) -> Window {
        let floor = U256::from(995 * WAD / 1000); // NAV 1.00 × 99.5 %
        let min_bid = if best_price.is_zero() {
            floor
        } else {
            min_increment(best_price).max(floor)
        };
        Window {
            floor,
            best,
            best_price,
            ends_at: 1_000,
            finalized: false,
            min_bid,
        }
    }

    #[test]
    fn first_bid_is_floor_plus_premium() {
        let me = Address::repeat_byte(1);
        let w = win(Address::ZERO, U256::ZERO);
        let p = solver_bid(&prof(true, 2, 10), me, &w, 10).unwrap();
        assert_eq!(p, w.floor * U256::from(10_002u64) / U256::from(10_000u64));
        assert!(p >= w.floor);
    }

    #[test]
    fn outbid_rebids_the_minimum_increment_within_the_cap() {
        let (me, other) = (Address::repeat_byte(1), Address::repeat_byte(2));
        let floor = U256::from(995 * WAD / 1000);
        let w = win(other, floor);
        let p = solver_bid(&prof(true, 0, 10), me, &w, 10).unwrap();
        assert_eq!(p, min_increment(floor));
        assert!(p * U256::from(10_000u64) >= floor * U256::from(10_001u64));
        // leading already: no self-outbid
        assert_eq!(solver_bid(&prof(true, 0, 10), other, &w, 10), None);
        // above the cap (1 bps over the floor allowed, the increment needs ~1 bps + rounding): stays out
        let high = win(other, bps_of(floor, 10));
        assert_eq!(solver_bid(&prof(true, 0, 10), me, &high, 10), None);
    }

    #[test]
    fn no_bid_profile_and_closed_windows_never_bid() {
        let me = Address::repeat_byte(1);
        let w = win(Address::ZERO, U256::ZERO);
        assert_eq!(solver_bid(&prof(false, 0, 10), me, &w, 10), None);
        assert_eq!(
            solver_bid(&prof(true, 0, 10), me, &w, 1_000),
            None,
            "window over"
        );
        let fin = Window {
            finalized: true,
            ..w
        };
        assert_eq!(solver_bid(&prof(true, 0, 10), me, &fin, 10), None);
    }

    #[test]
    fn config_parses_with_defaults() {
        let c: SolverConfig = serde_json::from_str(
            r#"{"solvers":[{"name":"a","key":"0x01","premiumBps":3},{"name":"lazy","key":"0x02","bid":false}]}"#,
        )
        .unwrap();
        assert!(c.solvers[0].bid && c.solvers[0].max_bps == 10);
        assert!(!c.solvers[1].bid);
    }
}
