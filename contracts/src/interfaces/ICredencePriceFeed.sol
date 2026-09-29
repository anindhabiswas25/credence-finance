// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Report} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IPriceFeedEvents} from "../libraries/Events.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {INavSource} from "./INavSource.sol";

/// @title Signed push feed written by a relayer committee (Build Guide §8.3.1, §10.1).
/// @notice EIP-712 domain: name "CredencePriceFeed", version "1", chainId, verifyingContract.
///         structHash = keccak256(abi.encode(REPORTS_TYPEHASH, keccak256(abi.encode(reports))))
///         REPORTS_TYPEHASH = keccak256("Reports(bytes32 reportsHash)")
///         digest = keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)
///         `abi.encode(reports)` is the ABI encoding of a single `Report[]` value (offset word 0x20, length, then
///         each report as 7 static words). Signatures are 65-byte (r, s, v) and must be ordered by strictly
///         ascending recovered signer address (no duplicates); at least `threshold` must be committee members.
interface ICredencePriceFeed is IPriceSource, INavSource, IPriceFeedEvents, ICredenceErrors {
    /// @notice Verify and store a batch. Reverts the whole batch on any invalid report.
    /// @dev Rules: observedAt ≤ block.timestamp + MAX_FUTURE_SKEW; seq > stored seq for the asset;
    ///      price > 0 (STATUS may carry 0); kind ≤ 4; marketStatus ≤ 5.
    /// @custom:state any. Permissionless (the signatures carry the authority).
    function submit(Report[] calldata reports, bytes[] calldata signatures) external;

    /// @notice onlyTimelock. Signers must be non-zero and strictly ascending; 1 ≤ threshold ≤ signers.length.
    function setCommittee(address[] calldata signers, uint8 threshold) external;

    /// @notice EIP-712 type hash of a signed report batch.
    function REPORTS_TYPEHASH() external view returns (bytes32);
    /// @notice How far in the future a report's observedAt may be (seconds).
    function MAX_FUTURE_SKEW() external view returns (uint40);
    /// @notice Live prints kept per asset for the TWAP fallback.
    function RING_SIZE() external view returns (uint256);
    /// @notice The EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32);
    /// @notice The EIP-712 digest the committee signs for `reports`.
    function hashReports(Report[] calldata reports) external view returns (bytes32);
    /// @notice The signer committee (ascending) and its threshold.
    function committee() external view returns (address[] memory signers, uint8 threshold);
    /// @notice Whether `a` is a committee signer.
    function isSigner(address a) external view returns (bool);
    /// @notice The last accepted seq of an asset.
    function latestSeq(bytes32 assetId) external view returns (uint64);
    /// @notice Number of LIVE observations stored in the ring buffer (≤ RING_SIZE).
    function observationCount(bytes32 assetId) external view returns (uint256);
    /// @notice The i-th most recent LIVE observation (0 = newest).
    function observation(bytes32 assetId, uint256 i) external view returns (uint256 price, uint40 observedAt);
    /// @notice The governance timelock.
    function timelock() external view returns (address);
}
