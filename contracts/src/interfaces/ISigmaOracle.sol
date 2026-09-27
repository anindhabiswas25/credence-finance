// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SigmaUpdate} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISigmaOracleEvents} from "../libraries/Events.sol";

/// @title σ committee gate for the Risk Engine (Build Guide §8.10, R-15). Implemented in S2.
/// @notice EIP-712 domain: name "CredenceSigmaOracle", version "1".
///         SIGMA_TYPEHASH = keccak256("SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)")
///         Signatures sorted by ascending signer, no duplicates, ≥ threshold.
interface ISigmaOracle is ISigmaOracleEvents, ICredenceErrors {
    function submit(SigmaUpdate calldata u, bytes[] calldata signatures) external;
    function setCommittee(address[] calldata signers, uint8 threshold) external; // onlyTimelock
    function lastAsOfDay(bytes32 assetId, uint8 closureType) external view returns (uint32);
    function committee() external view returns (address[] memory signers, uint8 threshold);
    function engine() external view returns (address);
    function SIGMA_TYPEHASH() external view returns (bytes32);
    function domainSeparator() external view returns (bytes32);
}
