// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RedeemRequest, MarketParams} from "../libraries/Types.sol";
import {ISeniorVault} from "../interfaces/ISeniorVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ICredenceMarket} from "../interfaces/ICredenceMarket.sol";

/// @title SeniorVault: ERC-4626 vault of senior lenders (Build Guide §8.5, R-17).
/// @notice Supplies USDC to the markets of one CredenceMarket singleton, up to per-market caps. Senior lenders are
///         never locked by the clock; their protection is the Underwriter Pool and the ProtocolReserve. What cannot
///         be withdrawn now (idle cash + market liquidity) is queued FIFO with `requestRedeem`, and paid at the share
///         price at processing time (`processQueue`), then claimed.
/// @dev totalAssets = idle + Σ enabled markets' totalSupplyAssets (the market figure already carries the senior
///      interest and any waterfall loss). Inflation attack: OZ virtual shares with a decimals offset of 6, plus 1e3
///      dead shares minted to 0xdead on the first deposit.
contract SeniorVault is ERC4626, ISeniorVault, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant DEAD = address(0xdead);
    uint256 internal constant DEAD_SHARES = 1e3;
    uint256 public constant MAX_QUEUE = 32;

    address public immutable timelock;
    address public immutable market;
    address public allocator;

    mapping(bytes32 id => uint256) public cap;
    /// @dev Every market that ever had a cap (totalAssets iterates over it).
    bytes32[] internal _enabled;
    mapping(bytes32 id => bool) internal _isEnabled;
    bytes32[] internal _supplyQueue;
    bytes32[] internal _withdrawQueue;

    mapping(uint256 requestId => RedeemRequest) internal _requests;
    uint256 public queueHead = 1;
    uint256 public nextRequestId = 1;
    uint256 public pendingRedeemShares;
    uint256 public claimableAssets;

    modifier onlyAllocator() {
        if (msg.sender != allocator && msg.sender != timelock) revert Unauthorized();
        _;
    }

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address timelock_,
        address market_,
        address allocator_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (timelock_ == address(0) || market_ == address(0) || allocator_ == address(0)) {
            revert ZeroAddress();
        }
        timelock = timelock_;
        market = market_;
        allocator = allocator_;
        emit AllocatorSet(allocator_);
    }

    // ───────────── governance / allocation ─────────────

    /// @inheritdoc ISeniorVault
    function setAllocator(address allocator_) external {
        if (msg.sender != timelock) revert Unauthorized();
        if (allocator_ == address(0)) revert ZeroAddress();
        allocator = allocator_;
        emit AllocatorSet(allocator_);
    }

    /// @inheritdoc ISeniorVault
    function setCap(bytes32 id, uint256 cap_) external {
        if (msg.sender != timelock) revert Unauthorized();
        MarketParams memory p = ICredenceMarket(market).marketParams(id); // reverts for an unknown market
        if (p.loanToken != asset()) revert InvalidParam();
        if (!_isEnabled[id]) {
            if (_enabled.length >= MAX_QUEUE) revert QueueTooLong(_enabled.length + 1, MAX_QUEUE);
            _isEnabled[id] = true;
            _enabled.push(id);
        }
        cap[id] = cap_;
        emit CapSet(id, cap_);
    }

    /// @inheritdoc ISeniorVault
    function setSupplyQueue(bytes32[] calldata ids) external onlyAllocator {
        _checkQueue(ids);
        _supplyQueue = ids;
        emit SupplyQueueSet(ids);
    }

    /// @inheritdoc ISeniorVault
    /// @dev Must list every enabled market that holds vault money, so all of it stays reachable.
    function setWithdrawQueue(bytes32[] calldata ids) external onlyAllocator {
        _checkQueue(ids);
        for (uint256 i; i < _enabled.length; ++i) {
            bytes32 id = _enabled[i];
            if (_supplied(id) == 0) continue;
            bool found;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == id) found = true;
            }
            if (!found) revert UnknownMarket(id);
        }
        _withdrawQueue = ids;
        emit WithdrawQueueSet(ids);
    }

    /// @inheritdoc ISeniorVault
    function allocate(bytes32 id, uint256 assets) external onlyAllocator nonReentrant {
        if (!_isEnabled[id]) revert UnknownMarket(id);
        uint256 after_ = _supplied(id) + assets;
        if (after_ > cap[id]) revert CapExceeded(after_, cap[id]);
        uint256 free = idle();
        if (assets > free) revert InsufficientLiquidity(assets, free);
        IERC20(asset()).forceApprove(market, assets);
        ICredenceMarket(market).supply(id, assets);
        emit Allocated(id, int256(assets));
    }

    /// @inheritdoc ISeniorVault
    function deallocate(bytes32 id, uint256 assets) external onlyAllocator nonReentrant {
        ICredenceMarket(market).withdrawSupply(id, assets, address(this));
        emit Allocated(id, -int256(assets));
    }

    // ───────────── ERC-4626 ─────────────

    /// @inheritdoc ERC4626
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256 total) {
        total = idle();
        for (uint256 i; i < _enabled.length; ++i) {
            total += _supplied(_enabled[i]);
        }
    }

    /// @inheritdoc ISeniorVault
    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - claimableAssets;
    }

    /// @inheritdoc ERC4626
    /// @dev min(the owner's assets, idle + market liquidity in withdrawQueue order).
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), _available());
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(balanceOf(owner), _convertToShares(_available(), Math.Rounding.Floor));
    }

    /// @inheritdoc ERC4626
    /// @dev QA-05: on the first deposit 1e3 of the minted shares go to 0xdead; the return value is what the receiver got.
    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        bool first = totalSupply() == 0;
        uint256 shares = super.deposit(assets, receiver);
        return first ? shares - DEAD_SHARES : shares;
    }

    /// @inheritdoc ERC4626
    /// @dev QA-05: on the first mint the receiver still gets exactly `shares`; the caller also pays for the 1e3 dead
    ///      shares.
    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        return super.mint(totalSupply() == 0 ? shares + DEAD_SHARES : shares, receiver);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev First deposit: 1e3 shares go to 0xdead. Then the assets are supplied down the supply queue.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (totalSupply() == 0) {
            if (shares <= DEAD_SHARES) revert ZeroAmount();
            _mint(DEAD, DEAD_SHARES);
            shares -= DEAD_SHARES;
        }
        super._deposit(caller, receiver, assets, shares);
        _supplyDown(assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        _pull(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ───────────── redeem queue (R-17) ─────────────

    /// @inheritdoc ISeniorVault
    function requestRedeem(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _transfer(msg.sender, address(this), shares); // escrowed: still counted in totalSupply until processed
        requestId = nextRequestId++;
        _requests[requestId] = RedeemRequest({
            owner: msg.sender,
            receiver: receiver,
            shares: uint128(shares),
            assets: 0,
            processed: false,
            claimed: false
        });
        pendingRedeemShares += shares;
        emit RedeemRequested(requestId, msg.sender, shares);
    }

    /// @inheritdoc ISeniorVault
    /// @dev In order, at the share price at processing time, while liquidity exists. Permissionless.
    function processQueue(uint256 maxRequests) external nonReentrant {
        uint256 head = queueHead;
        uint256 end = nextRequestId;
        for (uint256 n; n < maxRequests && head < end; ++n) {
            RedeemRequest storage r = _requests[head];
            uint256 assets = _convertToAssets(r.shares, Math.Rounding.Floor);
            if (assets > _available()) break;
            _pull(assets);
            _burn(address(this), r.shares);
            pendingRedeemShares -= r.shares;
            claimableAssets += assets;
            r.assets = uint128(assets);
            r.processed = true;
            emit RedeemProcessed(head, assets);
            ++head;
        }
        queueHead = head;
    }

    /// @inheritdoc ISeniorVault
    function claimRedeem(uint256 requestId) external nonReentrant returns (uint256 assets) {
        RedeemRequest storage r = _requests[requestId];
        if (r.owner == address(0)) revert RequestNotFound(requestId);
        if (msg.sender != r.owner && msg.sender != r.receiver) revert NotRequestOwner(requestId);
        if (!r.processed) revert RequestNotProcessed(requestId);
        if (r.claimed) revert RequestAlreadyClaimed(requestId);
        r.claimed = true;
        assets = r.assets;
        claimableAssets -= assets;
        IERC20(asset()).safeTransfer(r.receiver, assets);
        emit RedeemClaimed(requestId, r.receiver, assets);
    }

    // ───────────── views ─────────────

    /// @inheritdoc ISeniorVault
    function queueLength() external view returns (uint256) {
        return nextRequestId - queueHead;
    }

    /// @inheritdoc ISeniorVault
    function supplyQueue() external view returns (bytes32[] memory) {
        return _supplyQueue;
    }

    /// @inheritdoc ISeniorVault
    function withdrawQueue() external view returns (bytes32[] memory) {
        return _withdrawQueue;
    }

    /// @inheritdoc ISeniorVault
    function redeemRequest(uint256 requestId) external view returns (RedeemRequest memory) {
        return _requests[requestId];
    }

    // ───────────── internals ─────────────

    function _supplied(bytes32 id) internal view returns (uint256) {
        return ICredenceMarket(market).marketState(id).totalSupplyAssets;
    }

    /// @dev idle + Σ min(market liquidity, our supply) over the withdraw queue.
    function _available() internal view returns (uint256 a) {
        a = idle();
        for (uint256 i; i < _withdrawQueue.length; ++i) {
            bytes32 id = _withdrawQueue[i];
            a += Math.min(ICredenceMarket(market).liquidity(id), _supplied(id));
        }
    }

    /// @dev Supply `assets` down the supply queue, up to the vault cap and the market cap; keep the rest idle.
    function _supplyDown(uint256 assets) internal {
        ICredenceMarket m = ICredenceMarket(market);
        for (uint256 i; i < _supplyQueue.length && assets != 0; ++i) {
            bytes32 id = _supplyQueue[i];
            uint256 supplied = _supplied(id);
            uint256 room = cap[id] > supplied ? cap[id] - supplied : 0;
            uint256 marketCap = m.marketParams(id).supplyCap;
            room = Math.min(room, marketCap > supplied ? marketCap - supplied : 0);
            uint256 amt = Math.min(room, assets);
            if (amt == 0) continue;
            IERC20(asset()).forceApprove(market, amt);
            m.supply(id, amt);
            assets -= amt;
            emit Allocated(id, int256(amt));
        }
    }

    /// @dev Make `assets` idle (excluding claimable), pulling from markets in withdraw-queue order.
    function _pull(uint256 assets) internal {
        uint256 have = idle();
        if (have >= assets) return;
        uint256 need = assets - have;
        ICredenceMarket m = ICredenceMarket(market);
        for (uint256 i; i < _withdrawQueue.length && need != 0; ++i) {
            bytes32 id = _withdrawQueue[i];
            uint256 amt = Math.min(Math.min(m.liquidity(id), _supplied(id)), need);
            if (amt == 0) continue;
            m.withdrawSupply(id, amt, address(this));
            need -= amt;
            emit Allocated(id, -int256(amt));
        }
        if (need != 0) revert InsufficientLiquidity(assets, assets - need);
    }

    function _checkQueue(bytes32[] calldata ids) internal view {
        if (ids.length > MAX_QUEUE) revert QueueTooLong(ids.length, MAX_QUEUE);
        for (uint256 i; i < ids.length; ++i) {
            if (!_isEnabled[ids[i]]) revert UnknownMarket(ids[i]);
            for (uint256 j; j < i; ++j) {
                if (ids[j] == ids[i]) revert InvalidParam();
            }
        }
    }
}
