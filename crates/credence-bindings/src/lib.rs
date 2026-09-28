//! # credence-bindings
//!
//! alloy `sol!` bindings generated from the frozen v1 ABIs in `deployments/abis/v1/` (ADR-0104), for the keeper,
//! relayer and other Rust services. Each contract is a module with `#[sol(rpc)]` instances, calls, events and the full
//! Credence error set (`ICredenceErrors` is part of every ABI).
//!
//! ```ignore
//! use credence_bindings::CredenceMarket;
//! let m = CredenceMarket::new(addr, &provider);
//! let ids = m.marketIds().call().await?;
//! ```
//! Regenerate the ABIs with `make abis-export`; this crate picks them up at compile time. Implementation ABIs are
//! used where an implementation exists (they add admin functions and constructors to the interface); the S3
//! contracts (auction house, pool, settlement) are bound to their interfaces.
#![allow(missing_docs, clippy::too_many_arguments, clippy::large_enum_variant)]

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceMarket,
    "../../deployments/abis/v1/CredenceMarket.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SeniorVault,
    "../../deployments/abis/v1/SeniorVault.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SigmaOracle,
    "../../deployments/abis/v1/SigmaOracle.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    KeeperTips,
    "../../deployments/abis/v1/KeeperTips.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Treasury,
    "../../deployments/abis/v1/Treasury.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ProtocolReserve,
    "../../deployments/abis/v1/ProtocolReserve.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceGuardian,
    "../../deployments/abis/v1/CredenceGuardian.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    AssetClock,
    "../../deployments/abis/v1/AssetClock.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CalendarStore,
    "../../deployments/abis/v1/CalendarStore.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredencePriceFeed,
    "../../deployments/abis/v1/CredencePriceFeed.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    OracleAdapter,
    "../../deployments/abis/v1/OracleAdapter.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    SequencerHealth,
    "../../deployments/abis/v1/SequencerHealth.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IRiskEngine,
    "../../deployments/abis/v1/IRiskEngine.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IAuctionHouse,
    "../../deployments/abis/v1/IAuctionHouse.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    IUnderwriterPool,
    "../../deployments/abis/v1/IUnderwriterPool.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    ISettlementAdapter,
    "../../deployments/abis/v1/ISettlementAdapter.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceStockToken,
    "../../deployments/abis/v1/CredenceStockToken.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    CredenceTreasuryFund,
    "../../deployments/abis/v1/CredenceTreasuryFund.json"
);

alloy::sol!(
    #[sol(rpc, all_derives)]
    Faucet,
    "../../deployments/abis/v1/Faucet.json"
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
}
