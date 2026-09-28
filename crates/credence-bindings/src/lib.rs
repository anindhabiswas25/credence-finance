//! # credence-bindings
//!
//! alloy `sol!` bindings generated from the frozen v1 ABIs in `deployments/abis/v2/` (ADR-0104), for the keeper,
//! relayer and other Rust services. Each contract is a module with `#[sol(rpc)]` instances, calls, events and the full
//! Credence error set (`ICredenceErrors` is part of every ABI).
//!
//! ```ignore
//! use credence_bindings::CredenceMarket;
//! let m = CredenceMarket::new(addr, &provider);
//! let ids = m.marketIds().call().await?;
//! ```
//! Regenerate the ABIs with `make abis-export`; this crate picks them up at compile time. Implementation ABIs are
//! used where an implementation exists (they add admin functions and constructors to the interface); the pool and
//! the auction house are bound to their v2 interfaces, the settlement adapter (S4) to its interface.
#![allow(missing_docs, clippy::too_many_arguments, clippy::large_enum_variant)]

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceMarket,
    "../../deployments/abis/v2/CredenceMarket.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SeniorVault,
    "../../deployments/abis/v2/SeniorVault.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SigmaOracle,
    "../../deployments/abis/v2/SigmaOracle.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    KeeperTips,
    "../../deployments/abis/v2/KeeperTips.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Treasury,
    "../../deployments/abis/v2/Treasury.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ProtocolReserve,
    "../../deployments/abis/v2/ProtocolReserve.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceGuardian,
    "../../deployments/abis/v2/CredenceGuardian.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    AssetClock,
    "../../deployments/abis/v2/AssetClock.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CalendarStore,
    "../../deployments/abis/v2/CalendarStore.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredencePriceFeed,
    "../../deployments/abis/v2/CredencePriceFeed.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    OracleAdapter,
    "../../deployments/abis/v2/OracleAdapter.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SequencerHealth,
    "../../deployments/abis/v2/SequencerHealth.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IRiskEngine,
    "../../deployments/abis/v2/IRiskEngine.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IAuctionHouse,
    "../../deployments/abis/v2/IAuctionHouse.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IUnderwriterPool,
    "../../deployments/abis/v2/IUnderwriterPool.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ISettlementAdapter,
    "../../deployments/abis/v2/ISettlementAdapter.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceStockToken,
    "../../deployments/abis/v2/CredenceStockToken.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceTreasuryFund,
    "../../deployments/abis/v2/CredenceTreasuryFund.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Faucet,
    "../../deployments/abis/v2/Faucet.json"
);

// BE-backend REQUEST 2026-09-28 22:20: the testnet allowlist (keeper sender) and the bidder bot's canHold pre-check.
alloy::sol!(
    #[sol(rpc, all_derives)]
    ComplianceRegistry,
    "../../deployments/abis/v2/ComplianceRegistry.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ICompliance,
    "../../deployments/abis/v2/ICompliance.json"
);

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::sol_types::{SolCall, SolEvent};

    #[test]
    fn selectors_are_the_solidity_ones() {
        assert_eq!(
            CredenceMarket::marketIdsCall::SELECTOR,
            alloy::primitives::keccak256("marketIds()")[..4]
        );
        assert_eq!(
            CredencePriceFeed::ReportAccepted::SIGNATURE,
            "ReportAccepted(bytes32,uint8,uint256,uint40,uint64,uint8)"
        );
        assert_eq!(
            CredenceMarket::enforceBellCall::SIGNATURE,
            "enforceBell(bytes32,address[])"
        );
        assert_eq!(IRiskEngine::jointHashCall::SIGNATURE, "jointHash(bytes32)");
    }

    #[test]
    fn v2_events_and_calls() {
        assert_eq!(
            CredenceMarket::PositionSettled::SIGNATURE,
            "PositionSettled(bytes32,address,uint64,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        assert_eq!(
            CredenceMarket::AutoCoverApplied::SIGNATURE,
            "AutoCoverApplied(bytes32,address,uint64,uint256,uint256)"
        );
        assert_eq!(
            IUnderwriterPool::EpochSettled::SIGNATURE,
            "EpochSettled(uint64,uint256,uint256,uint256,uint256,int256,uint256,uint256,uint256,uint256)"
        );
        assert_eq!(
            IAuctionHouse::GdaBought::SIGNATURE,
            "GdaBought(uint64,address,uint256,uint256)"
        );
        assert_eq!(
            IAuctionHouse::completeReopenCall::SIGNATURE,
            "completeReopen(bytes32)"
        );
        assert_eq!(ICompliance::canHoldCall::SIGNATURE, "canHold(address)");
        assert_eq!(
            ComplianceRegistry::setAllowedCall::SIGNATURE,
            "setAllowed(address,bool)"
        );
    }
}
