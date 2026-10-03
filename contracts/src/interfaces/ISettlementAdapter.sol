// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AuctionKind, Settlement} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";
import {ISettlementEvents} from "../libraries/Events.sol";

/// @title NAV-stack liquidation: solver venue at T+0, pool-advance fallback (Build Guide §8.8). Interface v3 (S4,
///        ADR-0111); every v2 selector is unchanged.
/// @notice A settlement id is the NAV market's lot id: `market.lotBorrowers(id)` / `lotPosition(id, b)` describe it.
///         Timing contract for the keeper (J10): ADR-0111 §3.
interface ISettlementAdapter is ISettlementEvents, ICredenceErrors {
    // ── keeper (permissionless, tipped) ──
    /// @notice Flags every listed borrower with HF < 1 of NAV market `marketId` into one lot (≤ 128 borrowers per
    ///         call), sizes it with F-4.5a at κ_nav = 0.5 % (floor = NAV × 99.5 %), pulls it from the market
    ///         (`releaseLots`) and opens a `window()`-long solver window on `venues()[0]`. Allowed while the asset's
    ///         clock is REGULAR, or REOPEN within the 120 s queue after the open print (the market's flag rules);
    ///         CLOSED, HALTED and CORP_ACTION revert. Borrowers already in a lot or with HF ≥ 1 are skipped; if none
    ///         is left, it reverts `NothingToSettle`. The caller receives the market's FLAG tips plus one
    ///         OPEN_SETTLEMENT tip.
    /// @return settlementId the new settlement (the market lot id); see the `SettlementOpened` event.
    function openSettlement(bytes32 marketId, address[] calldata borrowers)
        external
        returns (uint64 settlementId);
    /// @notice After the window (`block.timestamp ≥ endsAt`). Filled: the tokens go to the solver and its escrow to
    ///         the market. No bid: the pool pays qty × floor (`fallbackAdvance`), takes the tokens and requests
    ///         their redemption; this reverts `RedemptionsGated` while the fund gates redemptions (retry later).
    ///         Then every position of the lot is settled in the market (F-4.5d). Tips: the market's SETTLE tip plus
    ///         one FINALIZE_SETTLEMENT tip.
    function finalize(uint64 settlementId) external;
    /// @notice v3: ends a NAV asset's REOPEN (clock.markReopenComplete) once the 120 s queue after its open print
    ///         (plus any phase extension) is over and every REOPEN settlement of that closure is finalized. Reverts
    ///         `WrongKind` for an equity asset.
    function completeReopen(bytes32 assetId) external;

    // ── market callbacks (the IAuctionHouse subset the market calls on the NAV stack) ──
    /// @notice onlyMarket, and only inside `openSettlement` (a direct `market.flagForAuction` on a NAV market
    ///         reverts `Unauthorized`): the lot the flagged borrowers join.
    function getOrCreate(AuctionKind k, bytes32 marketId, bytes32 assetId, uint64 closureId)
        external
        returns (uint64 settlementId);
    /// @notice onlyMarket: never needed (a call holds ≤ 128 borrowers, one lot); returns 0.
    function nextTranche(uint64 settlementId) external returns (uint64);
    /// @notice onlyMarket: every position of the lot is settled.
    function lotSettled(uint64 settlementId) external;

    // ── governance (onlyTimelock) ──
    /// @notice onlyTimelock: the solver venues (the first is used).
    function setVenues(address[] calldata venues_) external;
    /// @notice Solver window length, 5 min ≤ w ≤ 1 day (15 min at launch).
    function setWindow(uint40 window_) external;

    // ── views ──
    /// @notice The solver venues (the first is used).
    function venues() external view returns (address[] memory);
    /// @notice Solver window length (15 min at launch).
    function window() external view returns (uint40);
    /// @notice κ_nav (WAD): the NAV lot's reserve discount, floor = NAV × (1 − κ_nav).
    function kappaNav() external view returns (uint256);
    /// @notice One settlement (a NAV market lot sold through a venue).
    function settlement(uint64 settlementId) external view returns (Settlement memory);
    /// @notice The id the next settlement will get.
    function nextSettlementId() external view returns (uint64);
    /// @notice REOPEN settlements of (asset, closure) opened and not yet finalized.
    function openReopenSettlements(bytes32 assetId, uint64 closureId) external view returns (uint256);
    /// @notice The NAV market.
    function market() external view returns (address);
    /// @notice The NAV pool (the fallback advance).
    function pool() external view returns (address);
}
