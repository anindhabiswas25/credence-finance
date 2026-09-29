// NAV-stack events (S4 D), from BE-chain's draft interfaces v3 (ADR-0111: ISettlementAdapter, ISolverAuction,
// IUnderwriterPool v3). Hand-bound here until the frozen v3 ABIs reach @credence/sdk; then these move there.
import { parseAbi } from "viem";

export const SettlementAdapterEventsAbi = parseAbi([
  "event SettlementOpened(uint64 indexed id, bytes32 indexed marketId, address venue, uint256 qty, uint256 floorPrice, uint40 endsAt)",
  "event SettlementFinalized(uint64 indexed id, bool filled, address solver, uint256 price, uint256 proceeds, uint256 requestId)",
  "event SettlementPositionsSettled(uint64 indexed id, uint256 positions)",
]);

export const SolverAuctionEventsAbi = parseAbi([
  "event SolverWindowOpened(uint64 indexed id, address token, uint256 qty, uint256 floorPrice, uint40 endsAt)",
  "event SolverBid(uint64 indexed id, address indexed solver, uint256 price)",
  "event SolverRefunded(uint64 indexed id, address indexed solver, uint256 amount, bool pushed)",
]);

export const PoolV3EventsAbi = parseAbi([
  "event RedemptionRequested(uint64 indexed epochId, uint256 indexed requestId, bytes32 indexed marketId, address fund, uint256 qty, uint256 cost)",
  "event RedemptionClaimed(uint64 indexed epochId, uint256 indexed requestId, uint256 assets, int256 pnl)",
]);
