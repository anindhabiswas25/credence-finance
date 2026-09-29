// NAV settlement handlers (S4 D, Build Guide §8.8, §10.3): pure projections of the draft v3 events of the
// SettlementAdapter, the SolverAuction and the pool (ADR-0111). No RPC reads.
import { ponder } from "ponder:registry";
import { redemptionClaim, settlement, solverBid } from "ponder:schema";
import { onBid, onFinalized } from "./settlement-model";

type Hex = `0x${string}`;
const lc = (a: Hex) => a.toLowerCase() as Hex;

ponder.on("Settlement:SettlementOpened", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .insert(settlement)
    .values({
      settlementId: a.id,
      adapter: lc(event.log.address),
      marketId: a.marketId,
      venue: lc(a.venue),
      qty: a.qty,
      floorPrice: a.floorPrice,
      endsAt: BigInt(a.endsAt),
      status: "open",
      bids: 0,
      openedAt: event.block.timestamp,
      updatedBlock: event.block.number,
    })
    .onConflictDoNothing();
});

ponder.on("SolverAuction:SolverBid", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .insert(solverBid)
    .values({
      id: `${event.transaction.hash}:${event.log.logIndex}`,
      settlementId: a.id,
      solver: lc(a.solver),
      price: a.price,
      block: event.block.number,
      ts: event.block.timestamp,
    })
    .onConflictDoNothing();
  const s = await context.db.find(settlement, { settlementId: a.id });
  if (!s) return;
  await context.db
    .update(settlement, { settlementId: a.id })
    .set({
      ...onBid(s as never, a.solver, a.price),
      updatedBlock: event.block.number,
    });
});

ponder.on("Settlement:SettlementFinalized", async ({ event, context }) => {
  const a = event.args;
  await context.db.update(settlement, { settlementId: a.id }).set({
    ...onFinalized(a),
    finalizedAt: event.block.timestamp,
    updatedBlock: event.block.number,
  });
});

ponder.on(
  "Settlement:SettlementPositionsSettled",
  async ({ event, context }) => {
    await context.db
      .update(settlement, { settlementId: event.args.id })
      .set({
        positionsSettled: Number(event.args.positions),
        updatedBlock: event.block.number,
      });
  },
);

ponder.on("NavPool:RedemptionRequested", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .insert(redemptionClaim)
    .values({
      requestId: a.requestId,
      pool: lc(event.log.address),
      epochId: a.epochId,
      marketId: a.marketId,
      fund: lc(a.fund),
      qty: a.qty,
      cost: a.cost,
      status: "outstanding",
      requestedAt: event.block.timestamp,
    })
    .onConflictDoNothing();
});

ponder.on("NavPool:RedemptionClaimed", async ({ event, context }) => {
  const a = event.args;
  await context.db
    .update(redemptionClaim, { requestId: a.requestId })
    .set({
      status: "claimed",
      assets: a.assets,
      pnl: a.pnl,
      claimedAt: event.block.timestamp,
    });
});
