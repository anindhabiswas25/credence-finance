// Event handlers (Build Guide §10.3). Pure projections of events: no RPC reads.
import { ponder } from "ponder:registry";
import { clockState, clockTransition, pricePoint } from "ponder:schema";
import { feedLabeler, indexerBook } from "./book";

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 412346);
const feedLabel = feedLabeler(indexerBook(chainId, process.env.DEPLOYMENTS_DIR ?? "../deployments"));

ponder.on("AssetClock:StateChanged", async ({ event, context }) => {
  const { asset, from, to, closureId } = event.args;
  await context.db
    .insert(clockState)
    .values({
      assetId: asset,
      state: Number(to),
      closureId: BigInt(closureId),
      updatedBlock: event.block.number,
      updatedAt: event.block.timestamp,
    })
    .onConflictDoUpdate({ state: Number(to), closureId: BigInt(closureId), updatedBlock: event.block.number, updatedAt: event.block.timestamp });
  await context.db.insert(clockTransition).values({
    id: `${event.transaction.hash}:${event.log.logIndex}`,
    assetId: asset,
    from: Number(from),
    to: Number(to),
    closureId: BigInt(closureId),
    ts: event.block.timestamp,
    block: event.block.number,
  });
});

ponder.on("AssetClock:ClosureStarted", async ({ event, context }) => {
  const { asset, closureId, venueEpoch, t, refPrice, reopenAt } = event.args;
  const fields = {
    closureId: BigInt(closureId),
    closureType: Number(t),
    venueEpoch: BigInt(venueEpoch),
    refPrice,
    closeAt: event.block.timestamp,
    reopenAt: BigInt(reopenAt),
    openPrint: null,
    openPrintAt: null,
    openPrintFallback: null,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(clockState)
    .values({ assetId: asset, state: 2 /* CLOSED until the next StateChanged says otherwise */, ...fields })
    .onConflictDoUpdate(fields);
});

ponder.on("AssetClock:OpenPrint", async ({ event, context }) => {
  const { asset, closureId, price, fallbackUsed } = event.args;
  const fields = {
    openPrint: price,
    openPrintAt: event.block.timestamp,
    openPrintFallback: fallbackUsed,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(clockState)
    .values({ assetId: asset, state: 3, closureId: BigInt(closureId), ...fields })
    .onConflictDoUpdate(fields);
});

ponder.on("PriceFeed:ReportAccepted", async ({ event, context }) => {
  const { asset, kind, price, observedAt, seq } = event.args;
  await context.db
    .insert(pricePoint)
    .values({
      assetId: asset,
      feed: feedLabel(event.log.address),
      seq: BigInt(seq),
      kind: Number(kind),
      price,
      observedAt: BigInt(observedAt),
      block: event.block.number,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});
