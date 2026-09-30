// ERC-8056 multiplier and corporate actions (ABIs v4, ADR-0119; S5 Amendment 1 point 5). Pure projections of
// events, no RPC reads:
// - a collateral token's `UIMultiplierUpdated` (often days ahead: the early warning) and its cancellation;
// - the clock's `CorporateActionBegun` / `CorporateActionConfirmed` (the `multiplierAction(asset)` window);
// - the oracle's `SharesPerTokenChanged`: the cached multiplier the market values collateral with.
import { ponder, type Context } from "ponder:registry";
import { corporateAction, multiplier, multiplierSchedule } from "ponder:schema";

type Ev = {
  block: { number: bigint; timestamp: bigint };
  transaction: { hash: `0x${string}` };
  log: { logIndex: number; address: `0x${string}` };
};

const at = (event: Ev) => ({
  id: `${event.transaction.hash}:${event.log.logIndex}`,
  ts: event.block.timestamp,
  block: event.block.number,
});

async function upsertMultiplier(
  context: Context,
  event: Ev,
  assetId: `0x${string}`,
  set: Partial<{
    sharesPerToken: bigint;
    corporateAction: boolean;
    closureId: bigint | null;
  }>,
) {
  const stamp = {
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(multiplier)
    .values({
      assetId,
      corporateAction: false,
      ...set,
      ...stamp,
    })
    .onConflictDoUpdate({ ...set, ...stamp });
}

ponder.on("CollateralToken:UIMultiplierUpdated", async ({ event, context }) => {
  const { oldMultiplier, newMultiplier, effectiveAtTimestamp } = event.args;
  const token = event.log.address.toLowerCase() as `0x${string}`;
  const row = {
    current: oldMultiplier,
    next: newMultiplier,
    effectiveAt: effectiveAtTimestamp,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(multiplierSchedule)
    .values({ token, ...row })
    .onConflictDoUpdate(row);
  await context.db.insert(corporateAction).values({
    ...at(event),
    kind: "scheduled",
    token,
    oldValue: oldMultiplier,
    newValue: newMultiplier,
    effectiveAt: effectiveAtTimestamp,
  });
});

ponder.on(
  "CollateralToken:UIMultiplierUpdateCancelled",
  async ({ event, context }) => {
    const { cancelledMultiplier, cancelledEffectiveAt } = event.args;
    const token = event.log.address.toLowerCase() as `0x${string}`;
    const row = {
      next: null,
      effectiveAt: null,
      updatedBlock: event.block.number,
      updatedAt: event.block.timestamp,
    };
    // `current` is unknown if the schedule was never seen (startBlock after it): 0 marks "not observed"
    await context.db
      .insert(multiplierSchedule)
      .values({ token, current: 0n, ...row })
      .onConflictDoUpdate(row);
    await context.db.insert(corporateAction).values({
      ...at(event),
      kind: "cancelled",
      token,
      newValue: cancelledMultiplier,
      effectiveAt: cancelledEffectiveAt,
    });
  },
);

ponder.on("AssetClock:CorporateActionBegun", async ({ event, context }) => {
  const { asset, closureId } = event.args;
  await upsertMultiplier(context, event, asset, {
    corporateAction: true,
    closureId: BigInt(closureId),
  });
  await context.db.insert(corporateAction).values({
    ...at(event),
    kind: "begun",
    assetId: asset,
    closureId: BigInt(closureId),
  });
});

ponder.on("AssetClock:CorporateActionConfirmed", async ({ event, context }) => {
  const { asset, sharesPerToken } = event.args;
  await upsertMultiplier(context, event, asset, {
    corporateAction: false,
    closureId: null,
    sharesPerToken,
  });
  await context.db.insert(corporateAction).values({
    ...at(event),
    kind: "confirmed",
    assetId: asset,
    newValue: sharesPerToken,
  });
});

ponder.on("Oracle:SharesPerTokenChanged", async ({ event, context }) => {
  const { asset, oldValue, newValue } = event.args;
  await upsertMultiplier(context, event, asset, { sharesPerToken: newValue });
  await context.db.insert(corporateAction).values({
    ...at(event),
    kind: "synced",
    assetId: asset,
    oldValue,
    newValue,
  });
});
