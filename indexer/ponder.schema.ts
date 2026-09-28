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
  (table) => ({
    pk: primaryKey({ columns: [table.assetId, table.feed, table.seq] }),
    byTime: index().on(table.assetId, table.observedAt),
  }),
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
  (table) => ({
    pk: primaryKey({ columns: [table.marketId, table.owner] }),
    byOwner: index().on(table.owner),
  }),
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
  (table) => ({
    byOwner: index().on(table.owner, table.ts),
    byMarket: index().on(table.marketId, table.ts),
  }),
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
  (table) => ({
    pk: primaryKey({ columns: [table.assetId, table.closureType, table.day] }),
  }),
);

// ─────────────── S3: underwriter pool and auction house (§11.1; pure projections of the v2 events, ADR-0110) ───────────────

/** One row per stack's pool, from its events: the last settled NAV plus the flows since. */
export const pool = onchainTable("pool", (t) => ({
  stack: t.text().primaryKey(),
  pool: t.hex().notNull(),
  venue: t.hex(),
  activeEpoch: t.bigint(), // null: none unsettled
  lastSettledEpoch: t.bigint(),
  navAfterLastSettlement: t.bigint(),
  sharePrice: t.bigint(), // WAD, at the last settlement
  premiumsWritten: t.bigint().notNull(), // all time
  lossesPaid: t.bigint().notNull(), // all time
  riskFees: t.bigint().notNull(),
  penalties: t.bigint().notNull(),
  bonds: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
  updatedAt: t.bigint().notNull(),
}));

export const epoch = onchainTable(
  "epoch",
  (t) => ({
    pool: t.hex().notNull(),
    epochId: t.bigint().notNull(),
    stack: t.text().notNull(),
    venue: t.hex(),
    status: t.text().notNull(), // open | snapshotted | settled
    bellWindowAt: t.bigint(),
    bellAt: t.bigint(),
    closeAt: t.bigint(),
    reopenAt: t.bigint(),
    navBefore: t.bigint(),
    withdrawSharesQueued: t.bigint(),
    equityAtRisk: t.bigint(),
    worstLoss: t.bigint(),
    premiums: t.bigint().notNull(), // written into this epoch (CoverWritten)
    policies: t.integer().notNull(),
    riskFees: t.bigint(),
    penalties: t.bigint(),
    bonds: t.bigint(),
    backstopPnl: t.bigint(), // signed
    lossesPaid: t.bigint(),
    pendingLossReserve: t.bigint(),
    navAfter: t.bigint(),
    sharePriceAfter: t.bigint(),
    sharesBurned: t.bigint(),
    assetsReserved: t.bigint(),
    depositAssets: t.bigint(),
    sharesMinted: t.bigint(),
    openedAt: t.bigint(),
    snapshottedAt: t.bigint(),
    settledAt: t.bigint(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.pool, table.epochId] }),
    byStack: index().on(table.stack, table.epochId),
  }),
);

/** A Gap Cover policy (`CoverWritten`); `auto` when the Bell's auto-cover wrote it (`AutoCoverApplied`). */
export const coverPolicy = onchainTable(
  "cover_policy",
  (t) => ({
    id: t.text().primaryKey(), // "<pool>:<policyId>"
    pool: t.hex().notNull(),
    policyId: t.bigint().notNull(),
    marketId: t.hex().notNull(),
    owner: t.hex().notNull(),
    epochId: t.bigint().notNull(),
    assetId: t.hex().notNull(),
    closureId: t.bigint(),
    premium: t.bigint().notNull(),
    uAfter: t.bigint().notNull(),
    worstLoss: t.bigint().notNull(),
    auto: t.boolean().notNull(),
    debtAfter: t.bigint(),
    block: t.bigint().notNull(),
    ts: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    byOwner: index().on(table.owner),
    byEpoch: index().on(table.pool, table.epochId),
  }),
);

/** Every pool money flow, for the P&L breakdown. */
export const poolFlow = onchainTable(
  "pool_flow",
  (t) => ({
    id: t.text().primaryKey(), // txHash:logIndex
    pool: t.hex().notNull(),
    kind: t.text().notNull(), // premium | fee | penalty | bond | shortfall | backstop | gda | deposit | withdraw
    amount: t.bigint().notNull(),
    epochId: t.bigint(),
    assetId: t.hex(),
    ts: t.bigint().notNull(),
  }),
  (table) => ({ byPool: index().on(table.pool, table.ts) }),
);

export const poolRequest = onchainTable(
  "pool_request",
  (t) => ({
    pool: t.hex().notNull(),
    owner: t.hex().notNull(),
    epochId: t.bigint().notNull(),
    kind: t.text().notNull(), // deposit | withdraw
    assets: t.bigint().notNull(), // deposit: queued assets; withdraw: assets claimed so far
    shares: t.bigint().notNull(), // deposit: shares claimed; withdraw: shares escrowed
    stillOwed: t.bigint(),
    claimed: t.boolean().notNull(),
    requestedAt: t.bigint().notNull(),
    claimedAt: t.bigint(),
  }),
  (table) => ({
    pk: primaryKey({
      columns: [table.pool, table.owner, table.epochId, table.kind],
    }),
    byOwner: index().on(table.owner),
  }),
);

/** Backstop inventory per (pool, asset): bought at R in auctions, resold by GDA. */
export const backstopInventory = onchainTable(
  "backstop_inventory",
  (t) => ({
    pool: t.hex().notNull(),
    assetId: t.hex().notNull(),
    qty: t.bigint().notNull(),
    cost: t.bigint().notNull(), // loan units paid for what is still held
    listed: t.bigint().notNull(), // in a running GDA
    realisedPnl: t.bigint().notNull(), // signed
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.pool, table.assetId] }) }),
);

export const auction = onchainTable(
  "auction",
  (t) => ({
    auctionId: t.bigint().primaryKey(),
    house: t.hex().notNull(),
    kind: t.integer().notNull(), // 0 REOPEN, 1 INTRADAY, 2 EMERGENCY, 3 PRECLOSE
    marketId: t.hex().notNull(),
    assetId: t.hex().notNull(),
    closureId: t.bigint().notNull(),
    venueEpoch: t.bigint().notNull(),
    tranche: t.integer().notNull(),
    deadlines: t.json().notNull(), // [lotFixAt, biddingStartAt, commitEndOrBidEnd, clearAt]
    status: t.text().notNull(), // queue | fixed | cleared | settled
    lot: t.bigint(),
    reserve: t.bigint(),
    positions: t.integer(),
    bids: t.integer().notNull(),
    pStar: t.bigint(),
    filled: t.bigint(),
    qPool: t.bigint(),
    proceeds: t.bigint(),
    blendedPrice: t.bigint(),
    bondsForfeited: t.bigint().notNull(),
    createdAt: t.bigint().notNull(),
    fixedAt: t.bigint(),
    clearedAt: t.bigint(),
    settledAt: t.bigint(),
  }),
  (table) => ({
    byStatus: index().on(table.status, table.kind),
    byAsset: index().on(table.assetId),
  }),
);

export const bid = onchainTable(
  "bid",
  (t) => ({
    auctionId: t.bigint().notNull(),
    bidder: t.hex().notNull(),
    commitment: t.hex(),
    maxNotional: t.bigint(),
    bond: t.bigint(),
    qty: t.bigint(),
    price: t.bigint(),
    escrow: t.bigint(),
    tokens: t.bigint(), // claimed
    refund: t.bigint(), // claimed
    bondForfeited: t.boolean().notNull(),
    status: t.text().notNull(), // committed | revealed | placed | forfeited | claimed
    updatedAt: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.auctionId, table.bidder] }),
    byBidder: index().on(table.bidder),
  }),
);

/** One position's part in an auction: released qty, then its settlement. */
export const lotPosition = onchainTable(
  "lot_position",
  (t) => ({
    auctionId: t.bigint().notNull(),
    owner: t.hex().notNull(),
    marketId: t.hex(),
    qty: t.bigint().notNull(),
    collateralSold: t.bigint(),
    proceeds: t.bigint(),
    penalty: t.bigint(),
    shortfall: t.bigint(),
    refund: t.bigint(),
    debtAfter: t.bigint(),
    paidByPool: t.bigint(),
    paidByReserve: t.bigint(),
    seniorLoss: t.bigint(),
    settledAt: t.bigint(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.auctionId, table.owner] }),
    byOwner: index().on(table.owner),
  }),
);

export const gda = onchainTable("gda", (t) => ({
  gdaId: t.bigint().primaryKey(),
  house: t.hex().notNull(),
  assetId: t.hex().notNull(),
  token: t.hex().notNull(),
  qty: t.bigint().notNull(),
  k: t.bigint().notNull(),
  decay: t.bigint().notNull(),
  emissionPerSec: t.bigint().notNull(),
  start: t.bigint().notNull(),
  sold: t.bigint().notNull(),
  proceeds: t.bigint().notNull(),
  unsold: t.bigint(),
  status: t.text().notNull(), // running | closed
}));

/** Every closure's open print (`AssetClock.OpenPrint`), the reference for REOPEN auctions' p*. */
export const openPrint = onchainTable(
  "open_print",
  (t) => ({
    assetId: t.hex().notNull(),
    closureId: t.bigint().notNull(),
    price: t.bigint().notNull(),
    fallbackUsed: t.boolean().notNull(),
    ts: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.assetId, table.closureId] }),
  }),
);
