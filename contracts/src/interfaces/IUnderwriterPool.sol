// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverRequest, Epoch, Inventory, RedemptionClaim} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {IUnderwriterPoolEvents} from "../libraries/Events.sol";

/// @title Underwriter Pool: junior first-loss capital, ERC-20 shares (Build Guide §8.6). Interface v2 (S3, ADR-0110).
/// @notice One pool per stack, bound to one venue calendar (XNYS / USBANK). `epochId` is the calendar index of the
///         session whose close starts the closure (the clock's `venueEpoch`, R-10). At most one epoch is unsettled at
///         a time. Money flows (ADR-0107 §3): the payer transfers first, then notifies (`credit*`, `backstopBuy`).
interface IUnderwriterPool is IERC20, IUnderwriterPoolEvents, ICredenceErrors {
    // ── underwriters ──
    /// @notice Mints at the current share price, or queues the assets into the unsettled epoch (or the calendar epoch
    ///         whose Bell window is open), to be minted at its `sharePriceAfter` by `claimDeposit`. Returns the
    ///         shares minted (0 when queued; `DepositQueued` names the epoch).
    function deposit(uint256 assets, address receiver) external returns (uint256 sharesOrTicket);
    /// @notice Escrows `shares` for the first epoch whose Bell window has not opened; burned at its `sharePriceAfter`.
    function requestWithdraw(uint256 shares) external returns (uint64 epochId);
    /// @notice Pays the caller's reserved assets of a settled epoch, as far as free cash allows, oldest epoch first.
    function claimWithdraw(uint64 epochId) external returns (uint256 assets);
    function claimDeposit(uint64 epochId) external returns (uint256 shares);

    // ── cover (onlyMarket) ──
    function previewCover(CoverRequest calldata r) external view returns (uint256 premium, uint256 uAfter);
    /// @notice v2: computes the premium once (quoteCover at u_after from poolCapacity over the epoch's aggregate
    ///         K-vector), requires `premium ≤ maxPremium` and u_after ≤ u_max, adds the policy's loss vector. The market
    ///         transfers `premium` to the pool in the same transaction.
    function writeCover(CoverRequest calldata r, uint256 maxPremium)
        external
        returns (uint64 policyId, uint256 premium);

    // ── income (onlyMarket / onlyAuctionHouse) ──
    function creditRiskFee(uint256 assets) external;
    function creditPenalty(uint256 assets) external;
    function creditBond(uint256 assets) external;

    // ── losses and backstop ──
    /// @notice onlyMarket: pays min(s, freeCash) to the market.
    function payShortfall(uint256 s) external returns (uint256 paid);
    /// @notice onlyAuctionHouse, after it transferred `qty` tokens here: pays min(qty × price, freeCash) to the
    ///         auction house and books the tokens as backstop inventory. Returns what it paid.
    function backstopBuy(uint64 auctionId, bytes32 assetId, address token, uint256 qty, uint256 price)
        external
        returns (uint256 paid);
    /// @notice onlyAuctionHouse, after it transferred `proceeds` here: a GDA sale of inventory.
    function onGdaSale(bytes32 assetId, uint256 qty, uint256 proceeds) external;
    /// @notice onlyAuctionHouse: the GDA ended with `qty` unsold tokens returned to the pool.
    function onGdaClosed(bytes32 assetId, uint256 qty) external;
    /// @notice v3: onlySettlement (NAV stack), after the adapter transferred `qty` fund tokens here: pays
    ///         min(qty × price, freeCash) to the adapter, requests the redemption of the tokens from the fund
    ///         (`requestRedeem(qty, pool, pool)`) and carries the claim in NAV at what it paid (§8.6.1). Emits
    ///         `RedemptionRequested`.
    function fallbackAdvance(bytes32 marketId, uint256 qty, uint256 price)
        external
        returns (uint256 requestId);
    /// @notice v3, permissionless, tipped (EPOCH): claims a fulfilled redemption (`fund.redeem`). Realised P&L =
    ///         assets − cost (the κ_nav discount) goes to the active epoch. Emits `RedemptionClaimed`.
    function claimRedemption(uint256 requestId) external returns (uint256 assets);

    // ── lifecycle (permissionless, tipped) ──
    function openEpoch(bytes32 venue) external;
    function snapshotEpoch(uint64 epochId) external;
    function settleEpoch(uint64 epochId) external;
    /// @notice Lists the inventory of `assetId` not yet in a GDA with the auction house (F-4.5e).
    function resellInventory(bytes32 assetId) external returns (uint64 gdaId);
    /// @notice Releases an epoch's R-11 reserve for `assetId` once its REOPEN completed and its lots settled.
    function releaseLossReserve(uint64 epochId, bytes32 assetId) external;

    // ── views ──
    function nav() external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function utilisation(uint64 epochId) external view returns (uint256);
    function capacityHeadroom(uint64 epochId) external view returns (uint256);
    function epoch(uint64 epochId) external view returns (Epoch memory);
    function currentEpoch(bytes32 venue) external view returns (uint64);
    function venue() external view returns (bytes32);
    /// @notice The loan token (USDC).
    function asset() external view returns (address);
    function activeEpoch() external view returns (uint64 epochId, bool exists);
    function freeCash() external view returns (uint256);
    function unearnedPremiums() external view returns (uint256);
    function pendingLossReserve() external view returns (uint256);
    function inventory(bytes32 assetId) external view returns (Inventory memory);
    function pendingDeposit(uint64 epochId, address owner) external view returns (uint256 assets);
    function pendingWithdraw(uint64 epochId, address owner)
        external
        view
        returns (uint256 shares, uint256 paid);
    function lossReserve(uint64 epochId, bytes32 assetId) external view returns (uint256);

    // ── v3 (S4) ──
    /// @notice Σ cost of the unclaimed redemption claims (in NAV, §8.6.1).
    function redemptionClaimsOutstanding() external view returns (uint256);
    function redemptionClaim(uint256 requestId) external view returns (RedemptionClaim memory);
    /// @notice §15.1 concentration limit (WAD, 0.35 at launch): an asset's worst covered loss in an epoch stays
    ///         ≤ maxAssetShare × u_max × J (ADR-0112). `writeCover` reverts `ConcentrationExceeded` above it.
    function maxAssetShare() external view returns (uint64);
    /// @notice onlyTimelock, 0 < share ≤ 1e18.
    function setMaxAssetShare(uint64 share) external;
}
