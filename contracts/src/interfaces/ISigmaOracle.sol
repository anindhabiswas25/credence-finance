// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SigmaUpdate} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISigmaOracleEvents} from "../libraries/Events.sol";

/// @title σ committee gate for the Risk Engine (Build Guide §8.10, R-15). Interface v1.
/// @notice EIP-712 domain: name "CredenceSigmaOracle", version "1".
///         SIGMA_TYPEHASH = keccak256("SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)")
///         Signatures sorted by ascending signer, no duplicates, ≥ threshold.
interface ISigmaOracle is ISigmaOracleEvents, ICredenceErrors {
    /// @notice Permissionless: an m-of-n EIP-712 committee-signed σ update, forwarded to the engine (R-15).
    function submit(SigmaUpdate calldata u, bytes[] calldata signatures) external;
    /// @notice onlyTimelock: the σ committee and threshold.
    function setCommittee(address[] calldata signers, uint8 threshold) external;
    /// @notice The day of the last accepted σ of (asset, closure type).
    function lastAsOfDay(bytes32 assetId, uint8 closureType) external view returns (uint32);
    /// @notice The committee (ascending) and threshold.
    function committee() external view returns (address[] memory signers, uint8 threshold);
    /// @notice The Risk Engine it writes σ into.
    function engine() external view returns (address);
    /// @notice EIP-712 type hash of a σ update.
    function SIGMA_TYPEHASH() external view returns (bytes32);
    /// @notice The EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32);

    // ── v1 additions ──
    /// @notice The EIP-712 digest the committee signs for `u` (for keeper J7 cross-checks).
    function hashUpdate(SigmaUpdate calldata u) external view returns (bytes32);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
    /// @notice v1 (S2): once, by the deployer. The engine's constructor needs this oracle's address first.
    function initializeWiring(address engine) external;
}
