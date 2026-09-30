//! # credence-bindings
//!
//! alloy `sol!` bindings generated from the frozen ABIs in `deployments/abis/v5/` (ADR-0104), for the keeper,
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
//! the auction house are bound to their interfaces, and so are the NAV settlement adapter and the solver auction (v3, S4).
#![allow(missing_docs, clippy::too_many_arguments, clippy::large_enum_variant)]

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceMarket,
    "../../deployments/abis/v5/CredenceMarket.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SeniorVault,
    "../../deployments/abis/v5/SeniorVault.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SigmaOracle,
    "../../deployments/abis/v5/SigmaOracle.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    KeeperTips,
    "../../deployments/abis/v5/KeeperTips.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Treasury,
    "../../deployments/abis/v5/Treasury.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ProtocolReserve,
    "../../deployments/abis/v5/ProtocolReserve.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceGuardian,
    "../../deployments/abis/v5/CredenceGuardian.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    AssetClock,
    "../../deployments/abis/v5/AssetClock.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CalendarStore,
    "../../deployments/abis/v5/CalendarStore.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredencePriceFeed,
    "../../deployments/abis/v5/CredencePriceFeed.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    OracleAdapter,
    "../../deployments/abis/v5/OracleAdapter.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SequencerHealth,
    "../../deployments/abis/v5/SequencerHealth.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IRiskEngine,
    "../../deployments/abis/v5/IRiskEngine.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IAuctionHouse,
    "../../deployments/abis/v5/IAuctionHouse.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IUnderwriterPool,
    "../../deployments/abis/v5/IUnderwriterPool.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ISettlementAdapter,
    "../../deployments/abis/v5/ISettlementAdapter.json"
);

// v3 (S4, ADR-0111): the native solver venue of the NAV stack (J10, the solver bot)
alloy::sol!(
    #[sol(rpc, all_derives)]
    ISolverAuction,
    "../../deployments/abis/v5/ISolverAuction.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceStockToken,
    "../../deployments/abis/v5/CredenceStockToken.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceTreasuryFund,
    "../../deployments/abis/v5/CredenceTreasuryFund.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Faucet,
    "../../deployments/abis/v5/Faucet.json"
);

// S3: the clean-room RedStone price source (local / testnet only until ADR-0009 D3)
alloy::sol!(
    #[sol(rpc, all_derives)]
    RedStonePriceSource,
    "../../deployments/abis/v5/RedStonePriceSource.json"
);

// BE-backend REQUEST 2026-09-28 22:20: the testnet allowlist (keeper sender) and the bidder bot's canHold pre-check.
alloy::sol!(
    #[sol(rpc, all_derives)]
    ComplianceRegistry,
    "../../deployments/abis/v5/ComplianceRegistry.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ICompliance,
    "../../deployments/abis/v5/ICompliance.json"
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
            RedStonePriceSource::submitCall::SIGNATURE,
            "submit(bytes,bytes32[])"
        );
        assert_eq!(
            CredenceMarket::cancelLotCall::SIGNATURE,
            "cancelLot(uint64)"
        );
        assert_eq!(
            ComplianceRegistry::setAllowedCall::SIGNATURE,
            "setAllowed(address,bool)"
        );
    }

    #[test]
    fn v3_nav_settlement() {
        assert_eq!(
            ISettlementAdapter::openSettlementCall::SIGNATURE,
            "openSettlement(bytes32,address[])"
        );
        assert_eq!(ISettlementAdapter::finalizeCall::SIGNATURE, "finalize(uint64)");
        assert_eq!(
            ISettlementAdapter::completeReopenCall::SIGNATURE,
            "completeReopen(bytes32)"
        );
        assert_eq!(
            ISettlementAdapter::SettlementOpened::SIGNATURE,
            "SettlementOpened(uint64,bytes32,address,uint256,uint256,uint40)"
        );
        assert_eq!(
            ISettlementAdapter::SettlementFinalized::SIGNATURE,
            "SettlementFinalized(uint64,bool,address,uint256,uint256,uint256)"
        );
        assert_eq!(
            ISettlementAdapter::FallbackAdvanced::SIGNATURE,
            "FallbackAdvanced(uint64,uint256,uint256,uint256)"
        );
        assert_eq!(
            ISolverAuction::SolverBid::SIGNATURE,
            "SolverBid(uint64,address,uint256)"
        );
        assert_eq!(ISolverAuction::bidCall::SIGNATURE, "bid(uint64,uint256)");
        assert_eq!(
            IUnderwriterPool::RedemptionRequested::SIGNATURE,
            "RedemptionRequested(uint64,uint256,bytes32,address,uint256,uint256)"
        );
        assert_eq!(
            IUnderwriterPool::RedemptionClaimed::SIGNATURE,
            "RedemptionClaimed(uint64,uint256,uint256,int256)"
        );
        assert_eq!(
            IUnderwriterPool::claimRedemptionCall::SIGNATURE,
            "claimRedemption(uint256)"
        );
    }
}
