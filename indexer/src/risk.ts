// Underwriter pool and auction house handlers (S3, Build Guide §10.3, §11.1): pure projections of the
// interfaces-v2 events (ADR-0110). No RPC reads: every event carries the amounts and the resulting state.
import { ponder, type Context } from "ponder:registry";
import {
  auction,
  backstopInventory,
  bid,
  coverPolicy,
  epoch,
  gda,
  pool,
  poolFlow,
  poolRequest,
} from "ponder:schema";
import { indexerBook, stackOf } from "./book";

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 412346);
const book = indexerBook(
  chainId,
  process.env.DEPLOYMENTS_DIR ?? "../deployments",
);
const poolStack = stackOf(book, "pool");

type Hex = `0x${string}`;
interface Ev {
  block: { number: bigint; timestamp: bigint };
  log: { address: Hex; logIndex: number };
  transaction: { hash: Hex };
}
const lc = (a: Hex) => a.toLowerCase() as Hex;

// ── pool ──

async function ensurePool(context: Context, event: Ev) {
  const stack = poolStack(event.log.address);
  const row = await context.db.find(pool, { stack });
  if (row) return row;
  const values = {
    stack,
    pool: lc(event.log.address),
    premiumsWritten: 0n,
    lossesPaid: 0n,
    riskFees: 0n,
    penalties: 0n,
    bonds: 0n,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db.insert(pool).values(values);
  return (await context.db.find(pool, { stack }))!;
}

type PoolRow = Awaited<ReturnType<typeof ensurePool>>;
async function bumpPool(
  context: Context,
  event: Ev,
  f: (p: PoolRow) => Partial<PoolRow>,
) {
  const p = await ensurePool(context, event);
  await context.db.update(pool, { stack: p.stack }).set({
    ...f(p),
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  });
}

async function ensureEpoch(context: Context, event: Ev, epochId: bigint) {
  const key = { pool: lc(event.log.address), epochId };
  const row = await context.db.find(epoch, key);
  if (row) return row;
  await context.db.insert(epoch).values({
    ...key,
    stack: poolStack(event.log.address),
    status: "open",
    premiums: 0n,
    policies: 0,
  });
  return (await context.db.find(epoch, key))!;
}

async function flow(
  context: Context,
  event: Ev,
  kind: string,
  amount: bigint,
  epochId: bigint | null,
  assetId: Hex | null = null,
) {
  await context.db
    .insert(poolFlow)
    .values({
      id: `${event.transaction.hash}:${event.log.logIndex}`,
      pool: lc(event.log.address),
      kind,
      amount,
      epochId,
      assetId,
      ts: event.block.timestamp,
    })
    .onConflictDoNothing();
}

ponder.on("Pool:EpochOpened", async ({ event, context }) => {
  const a = event.args;
  await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: lc(event.log.address), epochId: a.epochId })
    .set({
      venue: a.venue,
      status: "open",
      bellWindowAt: BigInt(a.bellWindowAt),
      bellAt: BigInt(a.bellAt),
      closeAt: BigInt(a.closeAt),
      reopenAt: BigInt(a.reopenAt),
      navBefore: a.navBefore,
      withdrawSharesQueued: a.withdrawSharesQueued,
      openedAt: event.block.timestamp,
    });
  await bumpPool(context, event, () => ({
    venue: a.venue,
    activeEpoch: a.epochId,
  }));
});

ponder.on("Pool:EpochSnapshotted", async ({ event, context }) => {
  const a = event.args;
  await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: lc(event.log.address), epochId: a.epochId })
    .set({
      status: "snapshotted",
      equityAtRisk: a.equityAtRisk,
      worstLoss: a.worstLoss,
      snapshottedAt: event.block.timestamp,
    });
});

ponder.on("Pool:EpochSettled", async ({ event, context }) => {
  const a = event.args;
  await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: lc(event.log.address), epochId: a.epochId })
    .set({
      status: "settled",
      riskFees: a.riskFees,
      penalties: a.penalties,
      bonds: a.bonds,
      backstopPnl: a.backstopPnl,
      lossesPaid: a.lossesPaid,
      pendingLossReserve: a.pendingLossReserve,
      navAfter: a.navAfter,
      sharePriceAfter: a.sharePriceAfter,
      settledAt: event.block.timestamp,
    });
  await bumpPool(context, event, (p) => ({
    activeEpoch: p.activeEpoch === a.epochId ? null : p.activeEpoch,
    lastSettledEpoch: a.epochId,
    navAfterLastSettlement: a.navAfter,
    sharePrice: a.sharePriceAfter,
  }));
});

ponder.on("Pool:EpochQueuesProcessed", async ({ event, context }) => {
  const a = event.args;
  await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: lc(event.log.address), epochId: a.epochId })
    .set({
      sharesBurned: a.sharesBurned,
      assetsReserved: a.assetsReserved,
      depositAssets: a.depositAssets,
      sharesMinted: a.sharesMinted,
    });
});

ponder.on("Pool:CoverWritten", async ({ event, context }) => {
  const a = event.args;
  const p = lc(event.log.address);
  await context.db
    .insert(coverPolicy)
    .values({
      id: `${p}:${a.policyId}`,
      pool: p,
      policyId: a.policyId,
      marketId: a.marketId,
      owner: lc(a.borrower),
      epochId: a.epochId,
      assetId: a.assetId,
      premium: a.premium,
      uAfter: a.uAfter,
      worstLoss: a.worstLoss,
      auto: false, // CoverBought / AutoCoverApplied (market, same tx) complete the row
      block: event.block.number,
      ts: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
  const e = await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: p, epochId: a.epochId })
    .set({ premiums: e.premiums + a.premium, policies: e.policies + 1 });
  await bumpPool(context, event, (x) => ({
    premiumsWritten: x.premiumsWritten + a.premium,
  }));
  await flow(context, event, "premium", a.premium, a.epochId, a.assetId);
});

ponder.on("Pool:Deposited", async ({ event, context }) => {
  await ensurePool(context, event);
  await flow(context, event, "deposit", event.args.assets, null);
});

async function request(
  context: Context,
  event: Ev,
  owner: Hex,
  epochId: bigint,
  kind: "deposit" | "withdraw",
) {
  const key = { pool: lc(event.log.address), owner: lc(owner), epochId, kind };
  const row = await context.db.find(poolRequest, key);
  if (row) return row;
  await context.db.insert(poolRequest).values({
    ...key,
    assets: 0n,
    shares: 0n,
    claimed: false,
    requestedAt: event.block.timestamp,
  });
  return (await context.db.find(poolRequest, key))!;
}

ponder.on("Pool:DepositQueued", async ({ event, context }) => {
  const a = event.args;
  const r = await request(context, event, a.owner, a.epochId, "deposit");
  await context.db
    .update(poolRequest, {
      pool: r.pool,
      owner: r.owner,
      epochId: r.epochId,
      kind: r.kind,
    })
    .set({ assets: r.assets + a.assets });
  await flow(context, event, "deposit", a.assets, a.epochId);
});
ponder.on("Pool:DepositClaimed", async ({ event, context }) => {
  const a = event.args;
  const r = await request(context, event, a.owner, a.epochId, "deposit");
  await context.db
    .update(poolRequest, {
      pool: r.pool,
      owner: r.owner,
      epochId: r.epochId,
      kind: r.kind,
    })
    .set({
      shares: r.shares + a.shares,
      claimed: true,
      claimedAt: event.block.timestamp,
    });
});
ponder.on("Pool:WithdrawRequested", async ({ event, context }) => {
  const a = event.args;
  const r = await request(context, event, a.owner, a.epochId, "withdraw");
  await context.db
    .update(poolRequest, {
      pool: r.pool,
      owner: r.owner,
      epochId: r.epochId,
      kind: r.kind,
    })
    .set({ shares: r.shares + a.shares });
});
ponder.on("Pool:WithdrawClaimed", async ({ event, context }) => {
  const a = event.args;
  const r = await request(context, event, a.owner, a.epochId, "withdraw");
  await context.db
    .update(poolRequest, {
      pool: r.pool,
      owner: r.owner,
      epochId: r.epochId,
      kind: r.kind,
    })
    .set({
      assets: r.assets + a.assets,
      stillOwed: a.stillOwed,
      claimed: a.stillOwed === 0n,
      claimedAt: event.block.timestamp,
    });
  await flow(context, event, "withdraw", a.assets, a.epochId);
});

ponder.on("Pool:ShortfallPaid", async ({ event, context }) => {
  const a = event.args;
  await bumpPool(context, event, (p) => ({
    lossesPaid: p.lossesPaid + a.paid,
  }));
  await flow(context, event, "shortfall", a.paid, a.epochId);
});
ponder.on("Pool:RiskFeeCredited", async ({ event, context }) => {
  await bumpPool(context, event, (p) => ({
    riskFees: p.riskFees + event.args.assets,
  }));
  await flow(context, event, "fee", event.args.assets, event.args.epochId);
});
ponder.on("Pool:PenaltyCredited", async ({ event, context }) => {
  await bumpPool(context, event, (p) => ({
    penalties: p.penalties + event.args.assets,
  }));
  await flow(context, event, "penalty", event.args.assets, event.args.epochId);
});
ponder.on("Pool:BondCredited", async ({ event, context }) => {
  await bumpPool(context, event, (p) => ({
    bonds: p.bonds + event.args.assets,
  }));
  await flow(context, event, "bond", event.args.assets, event.args.epochId);
});

async function inventoryRow(context: Context, event: Ev, assetId: Hex) {
  const key = { pool: lc(event.log.address), assetId };
  const row = await context.db.find(backstopInventory, key);
  if (row) return row;
  await context.db.insert(backstopInventory).values({
    ...key,
    qty: 0n,
    cost: 0n,
    listed: 0n,
    realisedPnl: 0n,
    updatedAt: event.block.timestamp,
  });
  return (await context.db.find(backstopInventory, key))!;
}

ponder.on("Pool:BackstopBought", async ({ event, context }) => {
  const a = event.args;
  const i = await inventoryRow(context, event, a.assetId);
  await context.db
    .update(backstopInventory, { pool: i.pool, assetId: i.assetId })
    .set({
      qty: i.qty + a.qty,
      cost: i.cost + a.paid,
      updatedAt: event.block.timestamp,
    });
  await flow(context, event, "backstop", a.paid, a.epochId, a.assetId);
});
ponder.on("Pool:InventoryListed", async ({ event, context }) => {
  const a = event.args;
  const i = await inventoryRow(context, event, a.assetId);
  await context.db
    .update(backstopInventory, { pool: i.pool, assetId: i.assetId })
    .set({ listed: i.listed + a.qty, updatedAt: event.block.timestamp });
});
ponder.on("Pool:InventorySold", async ({ event, context }) => {
  const a = event.args;
  const i = await inventoryRow(context, event, a.assetId);
  // cost basis of what was sold = proceeds − realised P&L
  const basis = a.proceeds - a.realisedPnl;
  await context.db
    .update(backstopInventory, { pool: i.pool, assetId: i.assetId })
    .set({
      qty: i.qty - a.qty,
      cost: i.cost - basis,
      listed: i.listed > a.qty ? i.listed - a.qty : 0n,
      realisedPnl: i.realisedPnl + a.realisedPnl,
      updatedAt: event.block.timestamp,
    });
  await flow(context, event, "gda", a.proceeds, null, a.assetId);
});
ponder.on("Pool:LossReserveReleased", async ({ event, context }) => {
  const a = event.args;
  const e = await ensureEpoch(context, event, a.epochId);
  await context.db
    .update(epoch, { pool: lc(event.log.address), epochId: a.epochId })
    .set({
      pendingLossReserve:
        (e.pendingLossReserve ?? 0n) > a.amount
          ? e.pendingLossReserve! - a.amount
          : 0n,
    });
});

// ── auction house ──

const touch = (event: Ev) => ({ updatedBlock: event.block.number });

ponder.on("AuctionHouse:AuctionCreated", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .insert(auction)
    .values({
      auctionId: a.id,
      house: lc(event.log.address),
      kind: Number(a.kind),
      marketId: a.marketId,
      assetId: a.assetId,
      closureId: a.closureId,
      venueEpoch: a.venueEpoch,
      tranche: Number(a.tranche),
      deadlines: a.deadlines.map(Number),
      status: "queue",
      bids: 0,
      bondsForfeited: 0n,
      createdAt: event.block.timestamp,
      ...touch(event),
    })
    .onConflictDoNothing();
});
ponder.on("AuctionHouse:LotsFixed", async ({ event, context }) => {
  const a = event.args;
  await context.db.update(auction, { auctionId: a.id }).set({
    lot: a.lot,
    reserve: a.reserve,
    positions: Number(a.positions),
    status: "fixed",
    fixedAt: event.block.timestamp,
    ...touch(event),
  });
});

async function bidRow(
  context: Context,
  event: Ev,
  auctionId: bigint,
  bidder: Hex,
) {
  const key = { auctionId, bidder: lc(bidder) };
  const row = await context.db.find(bid, key);
  if (row) return { row, created: false };
  await context.db.insert(bid).values({
    ...key,
    bondForfeited: false,
    status: "new",
    updatedAt: event.block.timestamp,
  });
  const a = await context.db.find(auction, { auctionId });
  if (a)
    await context.db
      .update(auction, { auctionId })
      .set({ bids: a.bids + 1, ...touch(event) });
  return { row: (await context.db.find(bid, key))!, created: true };
}

ponder.on("AuctionHouse:BidCommitted", async ({ event, context }) => {
  const a = event.args;
  await bidRow(context, event, a.id, a.bidder);
  await context.db.update(bid, { auctionId: a.id, bidder: lc(a.bidder) }).set({
    commitment: a.commitment,
    maxNotional: a.maxNotional,
    bond: a.bond,
    status: "committed",
    updatedAt: event.block.timestamp,
  });
});
ponder.on("AuctionHouse:BidRevealed", async ({ event, context }) => {
  const a = event.args;
  await bidRow(context, event, a.id, a.bidder);
  await context.db.update(bid, { auctionId: a.id, bidder: lc(a.bidder) }).set({
    qty: a.qty,
    price: a.price,
    escrow: a.escrow,
    status: "revealed",
    updatedAt: event.block.timestamp,
  });
});
ponder.on("AuctionHouse:BidPlaced", async ({ event, context }) => {
  const a = event.args;
  await bidRow(context, event, a.id, a.bidder);
  await context.db.update(bid, { auctionId: a.id, bidder: lc(a.bidder) }).set({
    qty: a.qty,
    price: a.price,
    escrow: a.escrow,
    status: "placed",
    updatedAt: event.block.timestamp,
  });
});
ponder.on("AuctionHouse:AuctionCleared", async ({ event, context }) => {
  const a = event.args;
  await context.db.update(auction, { auctionId: a.id }).set({
    pStar: a.pStar,
    filled: a.filled,
    qPool: a.qPool,
    proceeds: a.proceeds,
    blendedPrice: a.blendedPrice,
    reserve: a.reserve,
    status: "cleared",
    clearedAt: event.block.timestamp,
    ...touch(event),
  });
});
ponder.on("AuctionHouse:BondForfeited", async ({ event, context }) => {
  const a = event.args;
  await bidRow(context, event, a.id, a.bidder);
  await context.db.update(bid, { auctionId: a.id, bidder: lc(a.bidder) }).set({
    bondForfeited: true,
    status: "forfeited",
    updatedAt: event.block.timestamp,
  });
  const x = await context.db.find(auction, { auctionId: a.id });
  if (x)
    await context.db
      .update(auction, { auctionId: a.id })
      .set({ bondsForfeited: x.bondsForfeited + a.bond, ...touch(event) });
});
ponder.on("AuctionHouse:Claimed", async ({ event, context }) => {
  const a = event.args;
  await bidRow(context, event, a.id, a.bidder);
  await context.db.update(bid, { auctionId: a.id, bidder: lc(a.bidder) }).set({
    tokens: a.tokens,
    refund: a.refund,
    status: "claimed",
    updatedAt: event.block.timestamp,
  });
});
ponder.on("AuctionHouse:LotSettled", async ({ event, context }) => {
  await context.db.update(auction, { auctionId: event.args.id }).set({
    status: "settled",
    settledAt: event.block.timestamp,
    ...touch(event),
  });
});

ponder.on("AuctionHouse:GdaStarted", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .insert(gda)
    .values({
      gdaId: a.gdaId,
      house: lc(event.log.address),
      assetId: a.assetId,
      token: lc(a.token),
      qty: a.qty,
      k: a.k,
      decay: a.decay,
      emissionPerSec: a.emissionPerSec,
      start: BigInt(a.start),
      sold: 0n,
      proceeds: 0n,
      status: "running",
    })
    .onConflictDoNothing();
});
ponder.on("AuctionHouse:GdaBought", async ({ event, context }) => {
  const a = event.args;
  const g = await context.db.find(gda, { gdaId: a.gdaId });
  if (g)
    await context.db
      .update(gda, { gdaId: a.gdaId })
      .set({ sold: g.sold + a.qty, proceeds: g.proceeds + a.cost });
});
ponder.on("AuctionHouse:GdaClosed", async ({ event, context }) => {
  await context.db
    .update(gda, { gdaId: event.args.gdaId })
    .set({ unsold: event.args.unsold, status: "closed" });
});
