// Indexed chain data (Build Guide §11.1): the Sprint 1 subset. Handlers are pure projections of events.
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
    status: t.integer(), // not in the event; filled when known
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.assetId, table.feed, table.seq] }), byTime: index().on(table.assetId, table.observedAt) }),
);
