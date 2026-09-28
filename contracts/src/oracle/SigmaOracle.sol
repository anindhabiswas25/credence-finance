// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SigmaUpdate} from "../libraries/Types.sol";
import {ISigmaOracle} from "../interfaces/ISigmaOracle.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";

/// @title SigmaOracle: the only writer of σ into the Risk Engine (Build Guide §8.10, R-15).
/// @notice Verifies an m-of-n EIP-712 committee signature over one `SigmaUpdate` and forwards it to
///         `engine.updateSigma`. `asOfDay` must be strictly newer than the last accepted one per (asset, closure
///         type), which also makes every signed update single-use. The engine enforces the rate limit and floor.
/// @dev Digest: EIP-712 domain ("CredenceSigmaOracle", "1", chainId, this), struct
///      `SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)`.
///      Signatures are 65-byte r‖s‖v, sorted by ascending recovered signer (as for the price feeds).
contract SigmaOracle is ISigmaOracle, EIP712 {
    /// @inheritdoc ISigmaOracle
    bytes32 public constant SIGMA_TYPEHASH =
        keccak256("SigmaUpdate(bytes32 assetId,uint8 closureType,uint256 sigma,uint32 asOfDay,uint64 nonce)");

    address public immutable timelock;
    address internal immutable deployer;
    address public engine;

    address[] internal _signers;
    mapping(address => bool) public isSigner;
    uint8 public threshold;
    mapping(bytes32 key => uint32) internal _lastAsOfDay; // key = keccak256(assetId, closureType)

    /// @dev The engine is wired once afterwards (`initializeWiring`): the Stylus engine's constructor needs this
    ///      contract's address as its only σ writer, so the oracle is deployed first.
    constructor(address timelock_, address[] memory signers, uint8 threshold_) EIP712("CredenceSigmaOracle", "1") {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        deployer = msg.sender;
        _setCommittee(signers, threshold_);
    }

    /// @inheritdoc ISigmaOracle
    function initializeWiring(address engine_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (engine != address(0)) revert AlreadyWired();
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
    }

    /// @inheritdoc ISigmaOracle
    function setCommittee(address[] calldata signers, uint8 threshold_) external {
        if (msg.sender != timelock) revert Unauthorized();
        _setCommittee(signers, threshold_);
    }

    /// @inheritdoc ISigmaOracle
    function submit(SigmaUpdate calldata u, bytes[] calldata signatures) external {
        if (engine == address(0)) revert NotWired();
        _verify(hashUpdate(u), signatures);
        bytes32 key = keccak256(abi.encodePacked(u.assetId, u.closureType));
        uint32 last = _lastAsOfDay[key];
        if (u.asOfDay <= last) revert SigmaNotNewer(u.asOfDay, last);
        _lastAsOfDay[key] = u.asOfDay;
        IRiskEngine(engine).updateSigma(u.assetId, u.closureType, u.sigma);
        emit SigmaSubmitted(u.assetId, u.closureType, u.sigma, u.asOfDay, u.nonce);
    }

    /// @inheritdoc ISigmaOracle
    function hashUpdate(SigmaUpdate calldata u) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(SIGMA_TYPEHASH, u.assetId, u.closureType, u.sigma, u.asOfDay, u.nonce))
        );
    }

    /// @inheritdoc ISigmaOracle
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ISigmaOracle
    function lastAsOfDay(bytes32 assetId, uint8 closureType) external view returns (uint32) {
        return _lastAsOfDay[keccak256(abi.encodePacked(assetId, closureType))];
    }

    /// @inheritdoc ISigmaOracle
    function committee() external view returns (address[] memory, uint8) {
        return (_signers, threshold);
    }

    function _setCommittee(address[] memory signers, uint8 threshold_) internal {
        uint256 n = signers.length;
        if (n == 0 || threshold_ == 0 || threshold_ > n) revert InvalidCommittee();
        for (uint256 i; i < _signers.length; ++i) {
            isSigner[_signers[i]] = false;
        }
        delete _signers;
        address prev;
        for (uint256 i; i < n; ++i) {
            address s = signers[i];
            if (s <= prev) revert InvalidCommittee(); // non-zero, strictly ascending, no duplicates
            isSigner[s] = true;
            _signers.push(s);
            prev = s;
        }
        threshold = threshold_;
        emit CommitteeChanged(signers, threshold_);
    }

    function _verify(bytes32 digest, bytes[] calldata signatures) internal view {
        address prev;
        for (uint256 i; i < signatures.length; ++i) {
            (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError) revert InvalidSignature();
            if (rec <= prev) revert SignersNotSorted();
            if (!isSigner[rec]) revert UnknownSigner(rec);
            prev = rec;
        }
        if (signatures.length < threshold) revert NotEnoughSigners(signatures.length, threshold);
    }
}
