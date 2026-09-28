// Indexed chain data (Build Guide §11.1): clock, prices (S1) + market, position, vault and σ (S2).
// Handlers project events; market/position/vault rows are re-read at the event's block (ADR-0011).
import { index, onchainTable, primaryKey } from "ponder";

/** Latest clock view per asset (StateChanged, ClosureStarted, OpenPrint). */
export const clockState = onchainTable("clock_state", (t) => ({
  assetId: t.hex().primaryKey(),
  state: t.integer().notNull(),
  closureId: t.bigint().notNull(),
  closureType: t.integer(),
  venueEpoch: t.bigint(),
  refPrice: t.bigint(),
  closeAt: t.bigint(),
  reopenAt: t.bigint(),
  openPrint: t.bigint(),
  openPrintAt: t.bigint(),
  openPrintFallback: t.boolean(),
  updatedBlock: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
}));

/** Every clock state transition (StateChanged). */
export const clockTransition = onchainTable(
  "clock_transition",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    assetId: t.hex().notNull(),
    from: t.integer().notNull(),
    to: t.integer().notNull(),
    closureId: t.bigint().notNull(),
    ts: t.bigint().notNull(),
    block: t.bigint().notNull(),
  }),
  (table) => ({ byAsset: index().on(table.assetId, table.ts) }),
);

/** Every accepted report (ReportAccepted), per feed. */
export const pricePoint = onchainTable(
  "price_point",
  (t) => ({
    assetId: t.hex().notNull(),
    feed: t.text().notNull(), // "A" | "B"
    seq: t.bigint().notNull(),
    kind: t.integer().notNull(),
    price: t.bigint().notNull(),
    observedAt: t.bigint().notNull(),
    status: t.integer(), // FeedMarketStatus from the v1 event (R-25); null for v0 logs
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.assetId, table.feed, table.seq] }), byTime: index().on(table.assetId, table.observedAt) }),
);

/** One row per market (`MarketCreated`), totals as of the last market event (`marketState` at that block). */
export const market = onchainTable("market", (t) => ({
  marketId: t.hex().primaryKey(),
  stack: t.text().notNull(), // "equity" | "nav"
  marketAddress: t.hex().notNull(),
  assetId: t.hex().notNull(),
  kind: t.integer().notNull(),
  loanToken: t.hex().notNull(),
  collateralToken: t.hex().notNull(),
  params: t.json().notNull(), // MarketParams, integers as decimal strings
  maxLtv: t.bigint().notNull(),
  lt: t.bigint().notNull(),
  supplyCap: t.bigint().notNull(),
  borrowCap: t.bigint().notNull(),
  totalSupplyAssets: t.bigint().notNull(),
  totalBorrowAssets: t.bigint().notNull(),
  totalBorrowShares: t.bigint().notNull(),
  poolFeeAccrued: t.bigint().notNull(),
  treasuryFeeAccrued: t.bigint().notNull(),
  totalCollateral: t.bigint().notNull(),
  lastAccrual: t.bigint().notNull(),
  createdBlock: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
}));

/** One row per (market, borrower): `position(id, owner)` at the block of its last event. */
export const position = onchainTable(
  "position",
  (t) => ({
    marketId: t.hex().notNull(),
    owner: t.hex().notNull(),
    collateral: t.bigint().notNull(),
    borrowShares: t.bigint().notNull(),
    debtSnapshot: t.bigint().notNull(), // debtOf at that block
    coverClosureId: t.bigint().notNull(),
    lastBellClosureId: t.bigint().notNull(),
    auctionId: t.bigint().notNull(),
    autoCoverOptOut: t.boolean().notNull(),
    updatedBlock: t.bigint().notNull(),
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.marketId, table.owner] }), byOwner: index().on(table.owner) }),
);

/** Every position event, for the UI history. */
export const positionEvent = onchainTable(
  "position_event",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    marketId: t.hex(),
    owner: t.hex().notNull(),
    kind: t.text().notNull(),
    amounts: t.json().notNull(),
    clockState: t.integer(),
    block: t.bigint().notNull(),
    ts: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ byOwner: index().on(table.owner, table.ts), byMarket: index().on(table.marketId, table.ts) }),
);

/** Senior Vault per stack, as of its last event. */
export const vaultState = onchainTable("vault_state", (t) => ({
  stack: t.text().primaryKey(),
  vault: t.hex().notNull(),
  totalAssets: t.bigint().notNull(),
  totalSupply: t.bigint().notNull(),
  idle: t.bigint().notNull(),
  queueLength: t.bigint().notNull(),
  pendingRedeemShares: t.bigint().notNull(),
  claimableAssets: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
}));

/** The ERC-7540-style FIFO redeem queue (R-17). */
export const vaultRequest = onchainTable(
  "vault_request",
  (t) => ({
    id: t.text().primaryKey(), // "<stack>:<requestId>"
    stack: t.text().notNull(),
    requestId: t.bigint().notNull(),
    owner: t.hex().notNull(),
    receiver: t.hex(),
    shares: t.bigint().notNull(),
    assets: t.bigint(),
    status: t.text().notNull(), // requested | processed | claimed
    requestedAt: t.bigint().notNull(),
    processedAt: t.bigint(),
    claimedAt: t.bigint(),
  }),
  (table) => ({ byOwner: index().on(table.owner) }),
);

/** σ accepted by the engine (`SigmaUpdated`), one row per UTC day (the day's last update wins). */
export const sigmaPoint = onchainTable(
  "sigma_point",
  (t) => ({
    assetId: t.hex().notNull(),
    closureType: t.integer().notNull(),
    day: t.bigint().notNull(), // floor(block.timestamp / 86400)
    sigma: t.bigint().notNull(),
    block: t.bigint().notNull(),
    ts: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.assetId, table.closureType, table.day] }) }),
);
