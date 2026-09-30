//! `credence-relayer nav-strike` (S5, the NAV stack on Arbitrum Sepolia): the issuer's NAV strike for the test fund.
//! The relayer's nodes serve feeds A and B only (they refuse the NAV kind); the NAV print is the issuer's. Once per
//! USBANK session ops runs this tool, which:
//!
//! 1. computes the new NAV per share: `--price`, or the fund's last NAV accrued at `--apr-bps` for the time since it
//!    was published (simple interest per strike; the test fund accrues ≈ 4 %/yr);
//! 2. signs one NAV report (kind NAV, status CLOSED, the next seq) with the NAV committee's keys (≥ threshold;
//!    keystores `$KEYSTORE_DIR/<chainId>/nav-<n>.json`, ADR-0014) and submits it to `feedNav`;
//! 3. with `--publish`, calls the fund's `publishNav` as the issuer (keystore role `issuer`), only when the issuer is
//!    an EOA: an issuer Safe publishes through the Safe.
//!
//! The report is stamped max(wall clock − 1, head time, feed's last + 1): the feed ignores a NAV print at or before
//! its last one, and an idle chain's head lags the wall clock.

use crate::report::{self, Kind, MarketStatus, Report};
use alloy::primitives::{Address, B256};

pub const WAD: u128 = 1_000_000_000_000_000_000;
pub const YEAR_S: u128 = 365 * 86_400;

/// `nav` accrued at `apr_bps` (simple interest) over `elapsed_s`, rounded down.
pub fn accrue(nav_wad: u128, apr_bps: u32, elapsed_s: u64) -> u128 {
    nav_wad + nav_wad * apr_bps as u128 * elapsed_s as u128 / (10_000 * YEAR_S)
}

/// The NAV report for `asset` at `observed_at` with sequence `seq`.
pub fn nav_report(asset: B256, price_wad: u128, observed_at: u64, seq: u64) -> Report {
    report::report(
        asset,
        Kind::Nav,
        price_wad,
        observed_at,
        observed_at / 86_400,
        MarketStatus::Closed,
        seq,
    )
}

/// The report's timestamp: never before the head or the feed's last NAV print, never in the future.
pub fn stamp(now: u64, head: u64, last_observed: u64) -> u64 {
    now.saturating_sub(1).max(head).max(last_observed + 1)
}

/// The NAV committee in the feed's order: the signers with their addresses, ascending, duplicates refused.
pub fn committee_order(addrs: &[Address]) -> anyhow::Result<Vec<usize>> {
    let mut idx: Vec<usize> = (0..addrs.len()).collect();
    idx.sort_by_key(|i| addrs[*i]);
    anyhow::ensure!(
        idx.windows(2).all(|w| addrs[w[0]] != addrs[w[1]]),
        "the NAV committee lists a key twice"
    );
    Ok(idx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_percent_a_year_is_about_one_basis_point_a_day() {
        let a = accrue(WAD, 400, 86_400);
        assert_eq!(a - WAD, WAD * 400 / 10_000 / 365); // 1.0958904… bp
        assert_eq!(accrue(WAD, 400, 0), WAD);
        assert_eq!(accrue(WAD, 0, 86_400 * 365), WAD);
    }

    #[test]
    fn a_report_is_nav_closed_and_stamped_after_the_last_print() {
        let r = nav_report(B256::repeat_byte(7), WAD, 1_790_800_000, 12);
        assert_eq!(r.kind, Kind::Nav as u8);
        assert_eq!(r.marketStatus, MarketStatus::Closed as u8);
        assert_eq!(r.seq, 12);
        assert_eq!(r.sessionDate.to::<u64>(), 1_790_800_000 / 86_400);
        // an idle chain: the head lags; a fast second strike: after the last print
        assert_eq!(stamp(1_000, 900, 950), 999);
        assert_eq!(stamp(1_000, 1_005, 950), 1_005);
        assert_eq!(stamp(1_000, 900, 1_200), 1_201);
    }

    #[test]
    fn committee_is_sorted_and_unique() {
        let a = Address::repeat_byte(3);
        let b = Address::repeat_byte(1);
        assert_eq!(committee_order(&[a, b]).unwrap(), vec![1, 0]);
        assert!(committee_order(&[a, a]).is_err());
    }
}
