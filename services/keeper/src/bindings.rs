//! The contract surface the Sprint 1 jobs use (deployments/abis/v0).

use alloy::sol;

sol! {
    #[sol(rpc)]
    interface IAssetClock {
        event StateChanged(bytes32 indexed asset, uint8 from, uint8 to, uint64 closureId);
        function poke(bytes32 assetId) external returns (uint8);
        function pokeMany(bytes32[] calldata assetIds) external;
        function state(bytes32 assetId) external view returns (uint8);
        function previewState(bytes32 assetId) external view returns (uint8);
        function calendar() external view returns (address);
    }

    #[sol(rpc)]
    interface ICalendarStore {
        function coverageEnd(bytes32 venue) external view returns (uint40);
        function sessionCount(bytes32 venue) external view returns (uint256);
    }
}

/// `bytes32("XNYS")`: ASCII, right-padded (ADR-0101).
pub fn venue_id(venue: &str) -> alloy::primitives::B256 {
    let mut b = [0u8; 32];
    let v = venue.as_bytes();
    b[..v.len().min(32)].copy_from_slice(&v[..v.len().min(32)]);
    alloy::primitives::B256::from(b)
}

#[cfg(test)]
mod tests {
    #[test]
    fn venue_ids_are_right_padded_ascii() {
        let v = super::venue_id("XNYS");
        assert_eq!(&v[..4], b"XNYS");
        assert!(v[4..].iter().all(|b| *b == 0));
    }
}
