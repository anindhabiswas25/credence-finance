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
        /// AssetClock's public constants (§8.2.2): bellWindowAt = close − BELL_WINDOW, bellAt = close − BELL_DEADLINE.
        function BELL_WINDOW() external view returns (uint40);
        function BELL_DEADLINE() external view returns (uint40);
    }

    /// RiskEngineRouter (R-24, ADR-0108): the Solidity `shared.riskEngine` in front of the two Stylus programs.
    #[sol(rpc)]
    interface IRiskEngineRouter {
        function pricing() external view returns (address);
        function auction() external view returns (address);
    }

    /// Arbitrum's ArbWasm precompile (0x…71): Stylus program lifecycle.
    #[sol(rpc)]
    interface IArbWasm {
        function programTimeLeft(address program) external view returns (uint64);
        function programVersion(address program) external view returns (uint16);
    }

    #[sol(rpc)]
    interface ICalendarStore {
        function coverageEnd(bytes32 venue) external view returns (uint40);
        function sessionCount(bytes32 venue) external view returns (uint256);
    }
}

/// ArbWasm precompile address.
pub const ARB_WASM: alloy::primitives::Address =
    alloy::primitives::address!("0000000000000000000000000000000000000071");

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
