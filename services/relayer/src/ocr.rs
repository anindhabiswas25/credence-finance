//! OCR-lite consensus (§10.1): 3 signer nodes + 1 aggregator per feed.
//!
//! 1. Each node polls the feed's vendor and keeps its own observation of every asset.
//! 2. The aggregator collects the nodes' observations and proposes, per asset, the **median**.
//! 3. A node signs a proposed batch only if every report in it is within **0.10%** of its own
//!    observation (same kind, session and market status). The aggregator keeps the largest batch that
//!    at least `threshold` nodes accept, collects their signatures and submits once per tick.
//!
//! This module is pure: no I/O, so every rule is unit-tested.

use crate::{
    filter::LiveObservation,
    price::deviation_ppm,
    report::{Kind, MarketStatus},
    vendor::PrintSource,
};
use alloy::primitives::{Address, B256};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A node signs only if the proposal is within this distance of its own observation (0.10%).
pub const SIGN_TOLERANCE_PPM: u128 = 1_000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusObservation {
    pub status: MarketStatus,
    pub at: u64,
    pub session_date: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPrint {
    pub session_date: u64,
    pub price_wad: u128,
    pub at: u64,
    pub source: PrintSource,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetObservation {
    pub asset_id: B256,
    pub status: Option<StatusObservation>,
    pub live: Option<LiveObservation>,
    /// Session date of the LIVE observation's session.
    pub live_session_date: Option<u64>,
    pub open: Option<SessionPrint>,
    pub close: Option<SessionPrint>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeSnapshot {
    pub node: String,
    pub signer: Address,
    pub taken_at: u64,
    pub assets: Vec<AssetObservation>,
}

/// A report before the aggregator assigns its `seq`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    pub asset_id: B256,
    pub kind: Kind,
    pub price_wad: u128,
    pub observed_at: u64,
    pub session_date: u64,
    pub status: MarketStatus,
}

/// Lower median by price of a non-empty set, returned with the chosen element's index.
pub fn median_by<T>(items: &[T], key: impl Fn(&T) -> u128) -> Option<&T> {
    if items.is_empty() {
        return None;
    }
    let mut idx: Vec<usize> = (0..items.len()).collect();
    idx.sort_by_key(|&i| key(&items[i]));
    Some(&items[idx[(items.len() - 1) / 2]])
}

/// The status at least `threshold` nodes agree on (with its session date), if any.
fn majority_status(obs: &[&AssetObservation], threshold: usize) -> Option<(MarketStatus, u64, u64)> {
    let mut counts: HashMap<(MarketStatus, u64), Vec<u64>> = HashMap::new();
    for o in obs {
        if let Some(s) = &o.status {
            counts.entry((s.status, s.session_date)).or_default().push(s.at);
        }
    }
    counts
        .into_iter()
        .filter(|(_, ats)| ats.len() >= threshold)
        .max_by_key(|(_, ats)| ats.len())
        .map(|((st, sd), mut ats)| {
            ats.sort_unstable();
            (st, sd, ats[(ats.len() - 1) / 2])
        })
}

/// Candidate reports for one asset from all node snapshots. Cadence is applied by the caller.
pub fn propose_asset(asset_id: B256, snaps: &[NodeSnapshot], threshold: usize) -> Vec<Draft> {
    let obs: Vec<&AssetObservation> =
        snaps.iter().filter_map(|s| s.assets.iter().find(|a| a.asset_id == asset_id)).collect();
    let mut out = Vec::new();
    let Some((status, status_session, status_at)) = majority_status(&obs, threshold) else {
        return out; // no quorum on the market status: publish nothing for this asset
    };
    out.push(Draft {
        asset_id,
        kind: Kind::Status,
        price_wad: 0,
        observed_at: status_at,
        session_date: status_session,
        status,
    });

    // LIVE: only observations taken under the agreed status
    let lives: Vec<(&LiveObservation, u64)> = obs
        .iter()
        .filter_map(|o| Some((o.live.as_ref()?, o.live_session_date?)))
        .filter(|(l, _)| l.status == status)
        .collect();
    if lives.len() >= threshold {
        if let Some((m, sd)) = median_by(&lives, |(l, _)| l.price_wad) {
            out.push(Draft {
                asset_id,
                kind: Kind::Live,
                price_wad: m.price_wad,
                observed_at: m.observed_at,
                session_date: *sd,
                status,
            });
        }
    }

    for (kind, pick) in [
        (Kind::Open, (|o: &AssetObservation| o.open.clone()) as fn(&AssetObservation) -> Option<SessionPrint>),
        (Kind::Close, |o: &AssetObservation| o.close.clone()),
    ] {
        let mut by_session: HashMap<u64, Vec<SessionPrint>> = HashMap::new();
        for p in obs.iter().filter_map(|o| pick(o)) {
            by_session.entry(p.session_date).or_default().push(p);
        }
        // the most recent session with a quorum of prints
        if let Some((sd, prints)) =
            by_session.into_iter().filter(|(_, v)| v.len() >= threshold).max_by_key(|(sd, _)| *sd)
        {
            if let Some(m) = median_by(&prints, |p| p.price_wad) {
                out.push(Draft {
                    asset_id,
                    kind,
                    price_wad: m.price_wad,
                    observed_at: m.at,
                    session_date: sd,
                    status: MarketStatus::Regular,
                });
            }
        }
    }
    out
}

/// Why a node refuses to sign one draft.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
pub enum Refusal {
    #[error("no own observation")]
    NoObservation,
    #[error("market status differs (own {own:?})")]
    StatusMismatch { own: MarketStatus },
    #[error("session differs (own {own})")]
    SessionMismatch { own: u64 },
    #[error("price {deviation_ppm} ppm from own observation (max {SIGN_TOLERANCE_PPM})")]
    OutOfTolerance { deviation_ppm: u128 },
    #[error("observedAt is in the future")]
    FromFuture,
    #[error("unsupported kind")]
    UnsupportedKind,
}

/// A node's check of one draft against its own observation of that asset.
pub fn verify(draft: &Draft, own: Option<&AssetObservation>, now: u64) -> Result<(), Refusal> {
    if draft.observed_at > now + 5 {
        return Err(Refusal::FromFuture);
    }
    let own = own.ok_or(Refusal::NoObservation)?;
    let status = own.status.as_ref().ok_or(Refusal::NoObservation)?;
    let within = |mine: u128| {
        let d = deviation_ppm(draft.price_wad, mine);
        if d <= SIGN_TOLERANCE_PPM {
            Ok(())
        } else {
            Err(Refusal::OutOfTolerance { deviation_ppm: d })
        }
    };
    match draft.kind {
        Kind::Status => {
            if status.status != draft.status {
                return Err(Refusal::StatusMismatch { own: status.status });
            }
            if status.session_date != draft.session_date {
                return Err(Refusal::SessionMismatch { own: status.session_date });
            }
            Ok(())
        }
        Kind::Live => {
            let live = own.live.as_ref().ok_or(Refusal::NoObservation)?;
            if live.status != draft.status {
                return Err(Refusal::StatusMismatch { own: live.status });
            }
            let sd = own.live_session_date.ok_or(Refusal::NoObservation)?;
            if sd != draft.session_date {
                return Err(Refusal::SessionMismatch { own: sd });
            }
            within(live.price_wad)
        }
        Kind::Open | Kind::Close => {
            let p = if draft.kind == Kind::Open { own.open.as_ref() } else { own.close.as_ref() };
            let p = p.ok_or(Refusal::NoObservation)?;
            if p.session_date != draft.session_date {
                return Err(Refusal::SessionMismatch { own: p.session_date });
            }
            within(p.price_wad)
        }
        Kind::Nav => Err(Refusal::UnsupportedKind),
    }
}

/// Given each node's accept flags over the same drafts, pick the node set (≥ threshold nodes) whose
/// common accepted drafts are the most, preferring more signers on a tie. Returns (node indexes,
/// draft indexes).
pub fn choose_quorum(accepts: &[Vec<bool>], threshold: usize) -> Option<(Vec<usize>, Vec<usize>)> {
    let n = accepts.len();
    if n < threshold || n > 16 {
        return None;
    }
    let drafts = accepts.first().map(|a| a.len()).unwrap_or(0);
    let mut best: Option<(Vec<usize>, Vec<usize>)> = None;
    for mask in 1u32..(1 << n) {
        let nodes: Vec<usize> = (0..n).filter(|i| mask & (1 << i) != 0).collect();
        if nodes.len() < threshold {
            continue;
        }
        let common: Vec<usize> = (0..drafts).filter(|&d| nodes.iter().all(|&i| accepts[i][d])).collect();
        if common.is_empty() {
            continue;
        }
        let better = match &best {
            None => true,
            Some((bn, bd)) => (common.len(), nodes.len()) > (bd.len(), bn.len()),
        };
        if better {
            best = Some((nodes, common));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{filter::ObsSource, price::WAD};

    const SD: u64 = 20_717;

    fn obs(price: u128, status: MarketStatus) -> AssetObservation {
        AssetObservation {
            asset_id: B256::repeat_byte(1),
            status: Some(StatusObservation { status, at: 100, session_date: SD }),
            live: Some(LiveObservation { price_wad: price, observed_at: 99, source: ObsSource::Trade, status }),
            live_session_date: Some(SD),
            open: None,
            close: None,
        }
    }

    fn snap(node: &str, a: AssetObservation) -> NodeSnapshot {
        NodeSnapshot { node: node.into(), signer: Address::ZERO, taken_at: 100, assets: vec![a] }
    }

    #[test]
    fn median_of_three_and_lower_median_of_two() {
        let v = [3u128, 1, 2];
        assert_eq!(*median_by(&v, |x| *x).unwrap(), 2);
        let v = [5u128, 1];
        assert_eq!(*median_by(&v, |x| *x).unwrap(), 1);
        assert!(median_by::<u128>(&[], |x| *x).is_none());
    }

    #[test]
    fn proposes_median_live_and_status() {
        let snaps = vec![
            snap("n1", obs(100 * WAD, MarketStatus::Regular)),
            snap("n2", obs(102 * WAD, MarketStatus::Regular)),
            snap("n3", obs(101 * WAD, MarketStatus::Regular)),
        ];
        let d = propose_asset(B256::repeat_byte(1), &snaps, 2);
        let live = d.iter().find(|d| d.kind == Kind::Live).unwrap();
        assert_eq!(live.price_wad, 101 * WAD);
        assert_eq!(live.session_date, SD);
        let st = d.iter().find(|d| d.kind == Kind::Status).unwrap();
        assert_eq!(st.status, MarketStatus::Regular);
        assert_eq!(st.price_wad, 0);
    }

    #[test]
    fn no_quorum_no_report() {
        let snaps = vec![
            snap("n1", obs(100 * WAD, MarketStatus::Regular)),
            snap("n2", obs(100 * WAD, MarketStatus::Halted)),
            snap("n3", obs(100 * WAD, MarketStatus::Post)),
        ];
        assert!(propose_asset(B256::repeat_byte(1), &snaps, 2).is_empty());
        // status quorum but only one LIVE under that status → STATUS only
        let mut a = obs(100 * WAD, MarketStatus::Halted);
        a.live = None;
        let snaps = vec![snap("n1", obs(100 * WAD, MarketStatus::Halted)), snap("n2", a)];
        let d = propose_asset(B256::repeat_byte(1), &snaps, 2);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].status, MarketStatus::Halted);
    }

    #[test]
    fn official_prints_need_a_quorum_on_the_same_session() {
        let print = |sd, p| SessionPrint { session_date: sd, price_wad: p, at: 1000, source: PrintSource::AuctionTrade };
        let mut a = obs(100 * WAD, MarketStatus::Regular);
        let mut b = a.clone();
        let mut c = a.clone();
        a.open = Some(print(SD, 100 * WAD));
        b.open = Some(print(SD, 100 * WAD));
        c.open = Some(print(SD - 1, 90 * WAD));
        let d = propose_asset(B256::repeat_byte(1), &[snap("a", a), snap("b", b), snap("c", c)], 2);
        let open = d.iter().find(|d| d.kind == Kind::Open).unwrap();
        assert_eq!((open.session_date, open.price_wad, open.observed_at), (SD, 100 * WAD, 1000));
        assert!(!d.iter().any(|d| d.kind == Kind::Close));
    }

    #[test]
    fn node_signs_only_within_0_10_percent() {
        let own = obs(100 * WAD, MarketStatus::Regular);
        let draft = |p| Draft {
            asset_id: own.asset_id,
            kind: Kind::Live,
            price_wad: p,
            observed_at: 99,
            session_date: SD,
            status: MarketStatus::Regular,
        };
        assert_eq!(verify(&draft(100_100 * WAD / 1000), Some(&own), 100), Ok(()));
        assert_eq!(verify(&draft(99_900 * WAD / 1000), Some(&own), 100), Ok(()));
        assert_eq!(
            verify(&draft(100_101 * WAD / 1000), Some(&own), 100),
            Err(Refusal::OutOfTolerance { deviation_ppm: 1_010 })
        );
        let mut d = draft(100 * WAD);
        d.status = MarketStatus::Post;
        assert!(matches!(verify(&d, Some(&own), 100), Err(Refusal::StatusMismatch { .. })));
        let mut d = draft(100 * WAD);
        d.session_date = SD + 1;
        assert!(matches!(verify(&d, Some(&own), 100), Err(Refusal::SessionMismatch { .. })));
        let mut d = draft(100 * WAD);
        d.observed_at = 106;
        assert_eq!(verify(&d, Some(&own), 100), Err(Refusal::FromFuture));
        assert_eq!(verify(&draft(100 * WAD), None, 100), Err(Refusal::NoObservation));
    }

    #[test]
    fn quorum_picks_largest_common_batch() {
        // drafts: 0 accepted by all; 1 only by nodes 0,1; 2 only by nodes 0,2
        let accepts = vec![vec![true, true, true], vec![true, true, false], vec![true, false, true]];
        let (nodes, drafts) = choose_quorum(&accepts, 2).unwrap();
        assert_eq!(drafts.len(), 2);
        assert_eq!(nodes.len(), 2);
        // all agree → all three nodes sign everything
        let (nodes, drafts) = choose_quorum(&[vec![true; 2], vec![true; 2], vec![true; 2]], 2).unwrap();
        assert_eq!((nodes.len(), drafts.len()), (3, 2));
        // only one node accepts anything → no quorum
        assert!(choose_quorum(&[vec![true], vec![false], vec![false]], 2).is_none());
    }
}
