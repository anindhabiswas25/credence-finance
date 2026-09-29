//! Test bidder bot (S3 dev tool; **never** for a public network). Each configured bidder watches every
//! auction of an auction house and, per its profile:
//!
//! * REOPEN (sealed, §8.7.1): once the lot is fixed, in the commit window it commits
//!   `keccak256(abi.encode(chainid, house, auctionId, bidder, qty, price, salt))` with a declared
//!   `maxNotional` (bond = 10%, R-04); in the reveal window it reveals (unless it is a non-revealing
//!   profile, whose bond the pool keeps);
//! * INTRADAY / EMERGENCY / PRECLOSE (open, firm): places one bid in the bidding window;
//! * after clearing: claims.
//!
//! Bids are sized from the fixed lot and priced against the reserve R: `qty = lot × qtyBps`,
//! `price = R × priceBps` (a profile below 10,000 bps is a low-ball that must never fill, INV-AH-03).
//! Salts are persisted to a state file, so a restarted bot can still reveal.

use alloy::{
    primitives::{keccak256, Address, B256, U256},
    sol_types::SolValue,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub mod solver;

pub const BPS: u128 = 10_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub name: String,
    /// Hex private key (dev keys only).
    pub key: String,
    /// Auction kinds this bidder joins (default: all).
    #[serde(default = "all_kinds")]
    pub kinds: Vec<String>,
    /// Share of the lot to bid for, in bps.
    pub qty_bps: u32,
    /// Price relative to the reserve R, in bps.
    pub price_bps: u32,
    /// Sealed auctions: reveal (false = forfeits the bond).
    #[serde(default = "yes")]
    pub reveal: bool,
    /// Declared maxNotional as a multiple of the bid's value, in bps (≥ 10,000).
    #[serde(default = "max_notional_bps")]
    pub max_notional_bps: u32,
}

fn all_kinds() -> Vec<String> {
    ["REOPEN", "INTRADAY", "EMERGENCY", "PRECLOSE"]
        .map(String::from)
        .to_vec()
}
fn yes() -> bool {
    true
}
fn max_notional_bps() -> u32 {
    12_000
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub bidders: Vec<Profile>,
}

pub fn kind_name(k: u8) -> &'static str {
    match k {
        0 => "REOPEN",
        1 => "INTRADAY",
        2 => "EMERGENCY",
        3 => "PRECLOSE",
        _ => "?",
    }
}

/// §8.7.2: `keccak256(abi.encode(block.chainid, address(this), auctionId, msg.sender, qty, price, salt))`.
pub fn commitment(
    chain_id: u64,
    house: Address,
    auction_id: u64,
    bidder: Address,
    qty: u128,
    price: u128,
    salt: B256,
) -> B256 {
    keccak256(
        (
            U256::from(chain_id),
            house,
            auction_id,
            bidder,
            qty,
            price,
            salt,
        )
            .abi_encode(),
    )
}

/// qty (collateral base units) × price (WAD per whole token) in loan base units, rounded up.
pub fn notional(qty: u128, price: u128, coll_dec: u8, loan_dec: u8) -> U256 {
    let num = U256::from(qty) * U256::from(price);
    let den = U256::from(10u64).pow(U256::from(coll_dec))
        * U256::from(10u64).pow(U256::from(18 - loan_dec.min(18)));
    num.div_ceil(den)
}

/// The bid a profile makes on a fixed lot at reserve R: `(qty, price)`, or `None` if it rounds to 0.
pub fn size(p: &Profile, lot: u128, reserve: u128) -> Option<(u128, u128)> {
    let qty = lot * p.qty_bps as u128 / BPS;
    let price = reserve * p.price_bps as u128 / BPS;
    (qty > 0 && price > 0).then_some((qty, price))
}

/// Phase windows (§8.7.1): deadlines = [lotFixAt, biddingStartAt, commitEndOrBidEnd, clearAt].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Commit,
    Reveal,
    Place,
    Claim,
}

/// AuctionPhase.CLEARED.
pub const CLEARED: u8 = 5;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BidState {
    pub qty: u128,
    pub price: u128,
    pub salt: B256,
    pub committed: bool,
    pub revealed: bool,
    pub placed: bool,
    pub claimed: bool,
}

/// What this bidder should do now. `fixed` = the lot and reserve are known (after `fixLots`).
pub fn decide(
    p: &Profile,
    kind: u8,
    phase: u8,
    fixed: bool,
    deadlines: [u64; 4],
    now: u64,
    st: &BidState,
) -> Option<Action> {
    if !p.kinds.iter().any(|k| k == kind_name(kind)) {
        return None;
    }
    let in_bidding = now >= deadlines[1] && now < deadlines[2];
    if phase == CLEARED {
        // a commit that was never revealed forfeits its bond at clearing: nothing to claim
        let took_part = st.revealed || st.placed;
        return (took_part && !st.claimed).then_some(Action::Claim);
    }
    if kind == 0 {
        if fixed && in_bidding && !st.committed {
            return Some(Action::Commit);
        }
        let in_reveal = now >= deadlines[2] && now < deadlines[3];
        if in_reveal && st.committed && !st.revealed && p.reveal {
            return Some(Action::Reveal);
        }
        return None;
    }
    (fixed && in_bidding && !st.placed).then_some(Action::Place)
}

/// Persisted salts and progress: (bidder, house, auctionId) → state.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Book {
    pub bids: BTreeMap<String, BidState>,
}

impl Book {
    pub fn key(bidder: Address, house: Address, id: u64) -> String {
        format!("{bidder:#x}:{house:#x}:{id}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prof(reveal: bool) -> Profile {
        Profile {
            name: "t".into(),
            key: String::new(),
            kinds: all_kinds(),
            qty_bps: 6_000,
            price_bps: 10_150,
            reveal,
            max_notional_bps: 12_000,
        }
    }

    #[test]
    fn commitment_is_the_abi_encoding_of_the_seven_words() {
        let (h, b) = (Address::repeat_byte(0xaa), Address::repeat_byte(0xbb));
        let salt = B256::repeat_byte(7);
        let c = commitment(412_346, h, 12, b, 5, 6, salt);
        let mut raw = Vec::new();
        raw.extend_from_slice(&U256::from(412_346u64).to_be_bytes::<32>());
        raw.extend_from_slice(&[0u8; 12]);
        raw.extend_from_slice(h.as_slice());
        raw.extend_from_slice(&U256::from(12u64).to_be_bytes::<32>());
        raw.extend_from_slice(&[0u8; 12]);
        raw.extend_from_slice(b.as_slice());
        raw.extend_from_slice(&U256::from(5u64).to_be_bytes::<32>());
        raw.extend_from_slice(&U256::from(6u64).to_be_bytes::<32>());
        raw.extend_from_slice(salt.as_slice());
        assert_eq!(c, keccak256(raw));
    }

    #[test]
    fn notional_in_loan_units_rounds_up() {
        // 96.92 tokens at $167.50 = $16,234.10
        let q = 96_920_000_000_000_000_000u128;
        let p = 167_500_000_000_000_000_000u128;
        assert_eq!(notional(q, p, 18, 6), U256::from(16_234_100_000u64));
        assert_eq!(notional(1, 1, 18, 6), U256::from(1u64));
    }

    #[test]
    fn sizing_against_the_reserve() {
        assert_eq!(size(&prof(true), 100_000, 200_000), Some((60_000, 203_000)));
        assert_eq!(size(&prof(true), 1, 200_000), None);
    }

    #[test]
    fn sealed_flow_commit_reveal_claim() {
        let p = prof(true);
        let d = [120, 120, 300, 420];
        let mut st = BidState::default();
        assert_eq!(
            decide(&p, 0, 2, false, d, 130, &st),
            None,
            "lot not fixed yet"
        );
        assert_eq!(decide(&p, 0, 2, true, d, 130, &st), Some(Action::Commit));
        st.committed = true;
        assert_eq!(decide(&p, 0, 2, true, d, 299, &st), None);
        assert_eq!(decide(&p, 0, 3, true, d, 300, &st), Some(Action::Reveal));
        st.revealed = true;
        assert_eq!(decide(&p, 0, 3, true, d, 419, &st), None);
        assert_eq!(
            decide(&p, 0, CLEARED, true, d, 421, &st),
            Some(Action::Claim)
        );
        st.claimed = true;
        assert_eq!(decide(&p, 0, CLEARED, true, d, 422, &st), None);
    }

    #[test]
    fn non_revealer_never_reveals_and_has_nothing_to_claim() {
        let p = prof(false);
        let d = [120, 120, 300, 420];
        let st = BidState {
            committed: true,
            ..Default::default()
        };
        assert_eq!(decide(&p, 0, 3, true, d, 350, &st), None);
        assert_eq!(decide(&p, 0, CLEARED, true, d, 421, &st), None);
    }

    #[test]
    fn open_auctions_place_once_in_the_window() {
        let p = prof(true);
        let d = [15, 15, 60, 60];
        let mut st = BidState::default();
        assert_eq!(decide(&p, 1, 4, true, d, 14, &st), None);
        assert_eq!(decide(&p, 1, 4, true, d, 15, &st), Some(Action::Place));
        st.placed = true;
        assert_eq!(decide(&p, 1, 4, true, d, 30, &st), None);
        let mut only_reopen = p.clone();
        only_reopen.kinds = vec!["REOPEN".into()];
        assert_eq!(
            decide(&only_reopen, 1, 4, true, d, 30, &BidState::default()),
            None
        );
    }
}
