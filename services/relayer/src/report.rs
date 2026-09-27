//! The signed `Report` (§8.3.1) and its EIP-712 digest, exactly as `CredencePriceFeed` verifies it
//! (ICredencePriceFeed.sol, ADR-0101):
//!
//! ```text
//! domain         = EIP712Domain("CredencePriceFeed", "1", chainId, verifyingContract)
//! reportsHash    = keccak256(abi.encode(Report[]))        // offset word, length, 7 words per report
//! structHash     = keccak256(abi.encode(keccak256("Reports(bytes32 reportsHash)"), reportsHash))
//! digest         = keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)
//! ```
//!
//! Signatures are 65-byte r‖s‖v, low-s, ordered by strictly ascending signer address.

use alloy::{
    primitives::{aliases::U40, keccak256, Address, Bytes, Signature, B256},
    sol,
    sol_types::{eip712_domain, Eip712Domain, SolStruct, SolValue},
};
use serde::{Deserialize, Serialize};

sol! {
    /// Mirror of `struct Report` in contracts/src/libraries/Types.sol.
    #[derive(Debug, PartialEq, Eq, Hash)]
    struct Report {
        bytes32 assetId;
        uint8   kind;
        uint128 price;
        uint40  observedAt;
        uint40  sessionDate;
        uint8   marketStatus;
        uint64  seq;
    }

    /// The EIP-712 primary type the committee signs.
    #[derive(Debug)]
    struct Reports {
        bytes32 reportsHash;
    }

    /// The subset of `ICredencePriceFeed` the relayer calls (deployments/abis/v0/ICredencePriceFeed.json).
    #[sol(rpc)]
    interface ICredencePriceFeed {
        function submit(Report[] calldata reports, bytes[] calldata signatures) external;
        function latestSeq(bytes32 assetId) external view returns (uint64);
        function latest(bytes32 assetId) external view returns (uint256 price, uint40 observedAt, uint8 marketStatus);
        function hashReports(Report[] calldata reports) external view returns (bytes32);
        function domainSeparator() external view returns (bytes32);
        function committee() external view returns (address[] memory signers, uint8 threshold);
    }
}

/// `Report.kind` (Types.sol `ReportKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
#[repr(u8)]
pub enum Kind {
    Live = 0,
    Open = 1,
    Close = 2,
    Nav = 3,
    Status = 4,
}

impl Kind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Live,
            1 => Self::Open,
            2 => Self::Close,
            3 => Self::Nav,
            4 => Self::Status,
            _ => return None,
        })
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Open => "open",
            Self::Close => "close",
            Self::Nav => "nav",
            Self::Status => "status",
        }
    }
}

/// `Report.marketStatus` (Types.sol `FeedMarketStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum MarketStatus {
    Closed = 0,
    Pre = 1,
    Regular = 2,
    Post = 3,
    Overnight = 4,
    Halted = 5,
}

impl MarketStatus {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Closed,
            1 => Self::Pre,
            2 => Self::Regular,
            3 => Self::Post,
            4 => Self::Overnight,
            5 => Self::Halted,
            _ => return None,
        })
    }
    pub fn is_extended(self) -> bool {
        matches!(self, Self::Pre | Self::Post | Self::Overnight)
    }
}

/// The feed's EIP-712 domain.
pub fn domain(chain_id: u64, feed: Address) -> Eip712Domain {
    eip712_domain! {
        name: "CredencePriceFeed",
        version: "1",
        chain_id: chain_id,
        verifying_contract: feed,
    }
}

/// `keccak256(abi.encode(reports))` for a single `Report[]` value.
pub fn reports_hash(reports: &[Report]) -> B256 {
    keccak256(reports.to_vec().abi_encode())
}

/// The digest each committee member signs for `reports`.
pub fn digest(domain: &Eip712Domain, reports: &[Report]) -> B256 {
    Reports { reportsHash: reports_hash(reports) }.eip712_signing_hash(domain)
}

/// Order `(signer, signature)` pairs by strictly ascending signer and drop duplicate signers.
pub fn sorted_signatures(mut sigs: Vec<(Address, Signature)>) -> Vec<(Address, Bytes)> {
    sigs.sort_by_key(|(a, _)| *a);
    sigs.dedup_by_key(|(a, _)| *a);
    sigs.into_iter().map(|(a, s)| (a, Bytes::from(s.as_bytes().to_vec()))).collect()
}

/// JSON transport form of a report (node ↔ aggregator, persistence, cross-language vectors).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportDto {
    pub asset_id: B256,
    pub kind: u8,
    /// WAD per share, decimal string.
    pub price: String,
    pub observed_at: u64,
    pub session_date: u64,
    pub market_status: u8,
    pub seq: u64,
}

impl From<&Report> for ReportDto {
    fn from(r: &Report) -> Self {
        Self {
            asset_id: r.assetId,
            kind: r.kind,
            price: r.price.to_string(),
            observed_at: r.observedAt.to::<u64>(),
            session_date: r.sessionDate.to::<u64>(),
            market_status: r.marketStatus,
            seq: r.seq,
        }
    }
}

impl TryFrom<&ReportDto> for Report {
    type Error = anyhow::Error;
    fn try_from(d: &ReportDto) -> anyhow::Result<Self> {
        anyhow::ensure!(Kind::from_u8(d.kind).is_some(), "bad kind {}", d.kind);
        anyhow::ensure!(MarketStatus::from_u8(d.market_status).is_some(), "bad marketStatus {}", d.market_status);
        anyhow::ensure!(d.observed_at < (1 << 40) && d.session_date < (1 << 40), "uint40 overflow");
        Ok(Report {
            assetId: d.asset_id,
            kind: d.kind,
            price: d.price.parse()?,
            observedAt: U40::from(d.observed_at),
            sessionDate: U40::from(d.session_date),
            marketStatus: d.market_status,
            seq: d.seq,
        })
    }
}

/// Build a report (all fields in natural units).
pub fn report(
    asset_id: B256,
    kind: Kind,
    price_wad: u128,
    observed_at: u64,
    session_date: u64,
    status: MarketStatus,
    seq: u64,
) -> Report {
    Report {
        assetId: asset_id,
        kind: kind as u8,
        price: price_wad,
        observedAt: U40::from(observed_at),
        sessionDate: U40::from(session_date),
        marketStatus: status as u8,
        seq,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        primitives::{address, b256, U256},
        signers::{local::PrivateKeySigner, SignerSync},
    };

    fn sample() -> Vec<Report> {
        vec![
            report(keccak256("NVDA:XNAS"), Kind::Live, 181_250_000_000_000_000_000, 1_790_000_000, 20_717, MarketStatus::Regular, 7),
            report(keccak256("AAPL:XNAS"), Kind::Status, 0, 1_790_000_001, 20_717, MarketStatus::Halted, 3),
        ]
    }

    #[test]
    fn abi_encode_of_report_array_is_offset_length_then_7_words_each() {
        let r = sample();
        let enc = r.to_vec().abi_encode();
        assert_eq!(enc.len(), 32 * (2 + 7 * r.len()));
        assert_eq!(U256::from_be_slice(&enc[0..32]), U256::from(0x20));
        assert_eq!(U256::from_be_slice(&enc[32..64]), U256::from(2));
        assert_eq!(B256::from_slice(&enc[64..96]), r[0].assetId);
        assert_eq!(U256::from_be_slice(&enc[96..128]), U256::from(Kind::Live as u8));
        assert_eq!(U256::from_be_slice(&enc[128..160]), U256::from(r[0].price));
        assert_eq!(U256::from_be_slice(&enc[64 + 6 * 32..64 + 7 * 32]), U256::from(7));
        assert_eq!(U256::from_be_slice(&enc[64 + 13 * 32..64 + 14 * 32]), U256::from(3));
    }

    #[test]
    fn digest_matches_manual_eip712() {
        let r = sample();
        let feed = address!("0x5FbDB2315678afecb367f032d93F642f64180aa3");
        let d = domain(31_337, feed);
        let domain_typehash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        let ds = keccak256(
            (domain_typehash, keccak256("CredencePriceFeed"), keccak256("1"), U256::from(31_337u64), feed)
                .abi_encode(),
        );
        assert_eq!(ds, d.separator());
        let typehash = keccak256("Reports(bytes32 reportsHash)");
        let struct_hash = keccak256((typehash, reports_hash(&r)).abi_encode());
        let mut buf = vec![0x19, 0x01];
        buf.extend_from_slice(ds.as_slice());
        buf.extend_from_slice(struct_hash.as_slice());
        assert_eq!(keccak256(buf), digest(&d, &r));
    }

    #[test]
    fn digest_changes_with_domain_and_content() {
        let r = sample();
        let feed = address!("0x5FbDB2315678afecb367f032d93F642f64180aa3");
        let base = digest(&domain(31_337, feed), &r);
        assert_ne!(base, digest(&domain(412_346, feed), &r));
        assert_ne!(base, digest(&domain(31_337, Address::ZERO), &r));
        let mut r2 = r.clone();
        r2[0].seq += 1;
        assert_ne!(base, digest(&domain(31_337, feed), &r2));
    }

    #[test]
    fn signatures_sorted_ascending_and_recoverable() {
        let r = sample();
        let d = domain(31_337, address!("0x5FbDB2315678afecb367f032d93F642f64180aa3"));
        let h = digest(&d, &r);
        let keys: Vec<PrivateKeySigner> = [
            b256!("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"),
            b256!("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"),
            b256!("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"),
        ]
        .iter()
        .map(|k| PrivateKeySigner::from_bytes(k).unwrap())
        .collect();
        let sigs: Vec<_> = keys.iter().rev().map(|k| (k.address(), k.sign_hash_sync(&h).unwrap())).collect();
        let sorted = sorted_signatures(sigs);
        assert!(sorted.windows(2).all(|w| w[0].0 < w[1].0));
        for (a, s) in &sorted {
            assert_eq!(s.len(), 65);
            let sig = Signature::try_from(s.as_ref()).unwrap();
            assert_eq!(sig.recover_address_from_prehash(&h).unwrap(), *a);
            assert!(s[64] == 27 || s[64] == 28);
        }
    }

    #[test]
    fn dto_round_trip() {
        for r in sample() {
            let dto = ReportDto::from(&r);
            assert_eq!(Report::try_from(&dto).unwrap(), r);
        }
    }
}
