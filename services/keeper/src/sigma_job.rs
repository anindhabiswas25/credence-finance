//! J7 σ update (§10.2): gaps from the on-chain OPEN/CLOSE prints → the σ methodology (`sigma`) →
//! the §5 publish rule against the engine's current σ → an EIP-712 `SigmaUpdate` signed by the
//! committee (≥ threshold, ascending signers) → `SigmaOracle.submit`.
//!
//! Everything here is pure except the signers, so it is testable without a chain; the runner that
//! reads the chain and submits lives with the other jobs once `credence-bindings` is READY.

use std::collections::BTreeMap;

use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::signers::Signer;
use alloy::sol;
use alloy::sol_types::{eip712_domain, Eip712Domain, SolStruct};
use anyhow::{bail, ensure, Result};
use chrono::NaiveDate;

use crate::sigma::{classify, gap_return, AssetSigma, Gap, TYPES};

sol! {
    /// `contracts/src/libraries/Types.sol` · SIGMA_TYPEHASH =
    /// keccak256("SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)")
    #[derive(Debug, PartialEq, Eq)]
    struct SigmaUpdate {
        bytes32 assetId;
        uint8 closureType;
        uint256 sigma;
        uint32 asOfDay;
        uint64 nonce;
    }
}

/// EIP-712 domain of `SigmaOracle`: ("CredenceSigmaOracle", "1", chainId, oracle).
pub fn domain(chain_id: u64, oracle: Address) -> Eip712Domain {
    eip712_domain! {
        name: "CredenceSigmaOracle",
        version: "1",
        chain_id: chain_id,
        verifying_contract: oracle,
    }
}

/// The digest the committee signs; equals `SigmaOracle.hashUpdate(u)`.
pub fn digest(u: &SigmaUpdate, domain: &Eip712Domain) -> B256 {
    u.eip712_signing_hash(domain)
}

/// Collect signatures from the committee and return them sorted by ascending signer address (the
/// oracle's `_verify` order). Fails if fewer than `threshold` signers answered.
pub async fn sign_committee<S: Signer + Sync>(
    u: &SigmaUpdate,
    domain: &Eip712Domain,
    signers: &[S],
    threshold: usize,
) -> Result<Vec<Bytes>> {
    let h = digest(u, domain);
    let mut sigs: Vec<(Address, Bytes)> = Vec::new();
    for s in signers {
        match s.sign_hash(&h).await {
            Ok(sig) => {
                let who = sig.recover_address_from_prehash(&h)?;
                ensure!(
                    who == s.address(),
                    "signer {} recovered as {who}",
                    s.address()
                );
                sigs.push((who, Bytes::from(sig.as_bytes().to_vec())));
            }
            Err(e) => {
                tracing::warn!(signer = %s.address(), error = %e, "σ committee signer failed")
            }
        }
    }
    sigs.sort_by_key(|(a, _)| *a);
    sigs.dedup_by_key(|(a, _)| *a);
    if sigs.len() < threshold {
        bail!(
            "σ committee: {} signatures < threshold {threshold}",
            sigs.len()
        );
    }
    Ok(sigs.into_iter().map(|(_, b)| b).collect())
}

/// Official open/close of one XNYS session for one asset, as published on-chain (OPEN / CLOSE reports).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SessionPrints {
    pub open: Option<f64>,
    pub close: Option<f64>,
    /// New shares per old share effective at this session's open (1.0 if none).
    pub split: Option<f64>,
    /// Cash dividend per share with ex-date this session (0.0 if none).
    pub dividend: Option<f64>,
}

/// Gaps between consecutive calendar sessions (§1). `sessions` are the XNYS session dates in order;
/// `closure_after` optionally gives the calendar's `closureTypeAfter` of each session (it must agree
/// with the date rule). A gap with a missing bar is skipped (§1).
pub fn build_gaps(
    sessions: &[NaiveDate],
    prints: &BTreeMap<NaiveDate, SessionPrints>,
    closure_after: Option<&BTreeMap<NaiveDate, u8>>,
) -> Result<Vec<Gap>> {
    let mut out = Vec::new();
    for w in sessions.windows(2) {
        let (p, s) = (w[0], w[1]);
        let t = classify(p, s)?;
        if let Some(cal) = closure_after {
            if let Some(&ct) = cal.get(&p) {
                ensure!(
                    ct == t,
                    "calendar says closure type {ct} after {p}, dates say {t}"
                );
            }
        }
        let (Some(close_p), Some(sp)) = (prints.get(&p).and_then(|x| x.close), prints.get(&s))
        else {
            continue;
        };
        let Some(open_s) = sp.open else { continue };
        let r = gap_return(
            close_p,
            open_s,
            sp.split.unwrap_or(1.0),
            sp.dividend.unwrap_or(0.0),
        );
        out.push(Gap {
            session: s,
            closure_type: t,
            r,
        });
    }
    Ok(out)
}

/// A WAD price → the `f64` nearest to its exact decimal value (the same number `float("225.07")`
/// gives), so on-chain prints feed the methodology exactly like the vendor decimals do.
pub fn wad_to_f64(v: U256) -> f64 {
    let wad = U256::from(10u64).pow(U256::from(18u64));
    let (int, frac) = (v / wad, v % wad);
    let s = format!("{int}.{:0>18}", frac.to_string());
    s.parse().expect("decimal string")
}

/// `asOfDay` = the UTC day index of the ET date of the session just closed (days since 1970-01-01).
pub fn as_of_day(session: NaiveDate) -> u32 {
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).unwrap();
    (session - epoch).num_days() as u32
}

/// On-chain σ state J7 needs per closure type.
#[derive(Debug, Clone, Copy, Default)]
pub struct OnChainSigma {
    pub current: U256,
    /// Timestamp of the last accepted update (the engine's `sigma_at`); `None` if never set.
    pub sigma_at: Option<u64>,
    /// `SigmaOracle.lastAsOfDay`.
    pub last_as_of_day: u32,
}

/// One planned submission and why it has this value.
#[derive(Debug, Clone, PartialEq)]
pub struct Planned {
    pub update: SigmaUpdate,
    pub model: U256,
    pub floor: U256,
    pub days: u64,
}

/// Plan J7 for one asset: resume over `gaps`, then one update per closure type whose `asOfDay` is
/// newer than the oracle's. `now` is the expected block timestamp; if the tx lands later the update
/// stays valid (§5). `nonce` is the keeper's per-run nonce (logged by the oracle, not checked).
pub fn plan(
    asset: &mut AssetSigma,
    gaps: &[Gap],
    chain: &[OnChainSigma; 3],
    session: NaiveDate,
    now: u64,
    nonce: u64,
) -> Result<Vec<Planned>> {
    asset.resume(gaps)?;
    let day = as_of_day(session);
    let asset_id: B256 = asset.asset_id.parse()?;
    let mut out = Vec::new();
    for t in TYPES {
        let c = chain[t as usize - 1];
        if day <= c.last_as_of_day {
            continue; // already published for this day (idempotency (asset, type, day))
        }
        let days = match c.sigma_at {
            Some(at) if !c.current.is_zero() => crate::sigma::days_since(at, now),
            _ => 0,
        };
        let sigma = asset.submit(t, c.current, days)?;
        out.push(Planned {
            update: SigmaUpdate {
                assetId: asset_id,
                closureType: t,
                sigma,
                asOfDay: day,
                nonce,
            },
            model: asset.state.model_wad(t),
            floor: asset.floor_wad[t as usize - 1],
            days,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{address, keccak256};
    use alloy::signers::local::PrivateKeySigner;
    use alloy::sol_types::SolValue;

    fn d(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    #[test]
    fn typehash_and_digest_match_the_solidity_encoding() {
        let th = keccak256("SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)");
        let u = SigmaUpdate {
            assetId: B256::repeat_byte(7),
            closureType: 2,
            sigma: U256::from(15_811_388u64) * U256::from(1_000_000_000u64),
            asOfDay: 20_724,
            nonce: 3,
        };
        assert_eq!(u.eip712_type_hash(), th);
        let struct_hash = keccak256(
            (
                th,
                u.assetId,
                U256::from(u.closureType),
                u.sigma,
                U256::from(u.asOfDay),
                U256::from(u.nonce),
            )
                .abi_encode(),
        );
        let dom = domain(412346, address!("00000000000000000000000000000000000000aa"));
        let manual = keccak256(
            [
                &[0x19u8, 0x01][..],
                dom.separator().as_slice(),
                struct_hash.as_slice(),
            ]
            .concat(),
        );
        assert_eq!(digest(&u, &dom), manual);
    }

    #[tokio::test]
    async fn committee_signatures_are_sorted_and_threshold_enforced() {
        let keys: Vec<PrivateKeySigner> = (1..=3u8)
            .map(|i| PrivateKeySigner::from_bytes(&B256::repeat_byte(i)).unwrap())
            .collect();
        let u = SigmaUpdate {
            assetId: B256::ZERO,
            closureType: 1,
            sigma: U256::from(1u64),
            asOfDay: 1,
            nonce: 0,
        };
        let dom = domain(1, Address::ZERO);
        let sigs = sign_committee(&u, &dom, &keys, 2).await.unwrap();
        assert_eq!(sigs.len(), 3);
        let h = digest(&u, &dom);
        let who: Vec<Address> = sigs
            .iter()
            .map(|b| {
                alloy::primitives::Signature::try_from(b.as_ref())
                    .unwrap()
                    .recover_address_from_prehash(&h)
                    .unwrap()
            })
            .collect();
        assert!(who.windows(2).all(|w| w[0] < w[1]));
        assert!(sign_committee(&u, &dom, &keys[..1], 2).await.is_err());
    }

    #[test]
    fn wad_prices_convert_like_decimal_parsing() {
        let wad = |s: &str| -> U256 {
            let (i, f) = s.split_once('.').unwrap_or((s, ""));
            U256::from_str_radix(&format!("{i}{:0<18}", f), 10).unwrap()
        };
        for s in ["225.07", "341.07", "0.01", "771.35", "516.17", "1234.5678"] {
            assert_eq!(
                wad_to_f64(wad(s)).to_bits(),
                s.parse::<f64>().unwrap().to_bits(),
                "{s}"
            );
        }
    }

    #[test]
    fn gaps_skip_missing_bars_and_use_calendar_types() {
        let sessions = [
            d("2026-11-24"),
            d("2026-11-25"),
            d("2026-11-27"),
            d("2026-11-30"),
            d("2026-12-01"),
        ];
        let p = |o: Option<f64>, c: Option<f64>| SessionPrints {
            open: o,
            close: c,
            ..Default::default()
        };
        let prints = BTreeMap::from([
            (d("2026-11-24"), p(Some(100.0), Some(101.0))),
            (d("2026-11-25"), p(Some(102.0), Some(103.0))),
            (d("2026-11-27"), p(Some(104.0), None)), // no close (halted through the close)
            (d("2026-11-30"), p(Some(106.0), Some(107.0))),
            (
                d("2026-12-01"),
                SessionPrints {
                    open: Some(50.0),
                    close: Some(51.0),
                    split: Some(2.0),
                    dividend: Some(0.5),
                },
            ),
        ]);
        let gaps = build_gaps(&sessions, &prints, None).unwrap();
        let types: Vec<(NaiveDate, u8)> =
            gaps.iter().map(|g| (g.session, g.closure_type)).collect();
        assert_eq!(
            types,
            vec![
                (d("2026-11-25"), 1),
                (d("2026-11-27"), 3),
                (d("2026-12-01"), 1)
            ]
        );
        assert_eq!(
            gaps[0].r.to_bits(),
            gap_return(101.0, 102.0, 1.0, 0.0).to_bits()
        );
        assert_eq!(
            gaps[2].r.to_bits(),
            gap_return(107.0, 50.0, 2.0, 0.5).to_bits()
        );
        let bad = BTreeMap::from([(d("2026-11-25"), 1u8)]);
        assert!(build_gaps(&sessions, &prints, Some(&bad)).is_err());
    }

    #[test]
    fn as_of_day_is_the_utc_day_index() {
        assert_eq!(as_of_day(d("1970-01-02")), 1);
        assert_eq!(as_of_day(d("2026-09-25")), 20_721);
    }
}
