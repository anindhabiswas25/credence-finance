// Market, position, Senior Vault and σ handlers (Build Guide §10.3, §11.1; ADR-0011).
//
// The rows are the contract's own view (`marketState`, `position`, `debtOf`, the vault's ERC-4626 and
// queue views) read at the block of the event. Not every state change emits an event of its own (the
// Bell's auto-cover adds the premium to debt without a `Borrow`; settlement moves collateral without a
// collateral event), so summing event deltas would drift. A read pinned to the event's block is
// deterministic, reorg-safe and cached by Ponder, and the event itself still drives when a row changes.
import { ponder, type Context } from "ponder:registry";
import {
  auction,
  clockState,
  coverPolicy,
  lotPosition,
  market,
  position,
  positionEvent,
  sigmaPoint,
  vaultRequest,
  vaultState,
} from "ponder:schema";
import {
  bellOutcomeName,
  ICredenceMarketAbi,
  ISeniorVaultAbi,
} from "@credence/sdk";
import { createPublicClient, fallback, http } from "viem";
import { indexerBook, rpcUrls, stackOf } from "./book";
import { withPrunedFallback } from "./pinned";

/** `context.client` whose pinned reads fall back to the latest state when the RPC pruned the event's block. */
function client(context: Context): Pick<Context["client"], "readContract"> {
  return { readContract: withPrunedFallback(context.client, headBlock) };
}

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 412346);
const headClient = createPublicClient({
  transport: fallback(rpcUrls(chainId).map((u) => http(u))),
});
const headBlock = () => headClient.getBlockNumber({ cacheTime: 0 });
const book = indexerBook(
  chainId,
  process.env.DEPLOYMENTS_DIR ?? "../deployments",
);
const marketStack = stackOf(book, "market");
const vaultStack = stackOf(book, "vault");

type Hex = `0x${string}`;
interface Ev {
  block: { number: bigint; timestamp: bigint };
  log: { address: Hex; logIndex: number };
  transaction: { hash: Hex };
}

/** bigint → decimal string, recursively (for json columns). */
export function jsonable(v: unknown): unknown {
  if (typeof v === "bigint") return v.toString();
  if (Array.isArray(v)) return v.map(jsonable);
  if (v && typeof v === "object")
    return Object.fromEntries(
      Object.entries(v).map(([k, x]) => [k, jsonable(x)]),
    );
  return v;
}

async function refreshMarket(context: Context, event: Ev, id: Hex) {
  const addr = event.log.address;
  const s = await client(context).readContract({
    abi: ICredenceMarketAbi,
    address: addr,
    functionName: "marketState",
    args: [id],
    blockNumber: event.block.number,
  });
  const fields = {
    totalSupplyAssets: BigInt(s.totalSupplyAssets),
    totalBorrowAssets: BigInt(s.totalBorrowAssets),
    totalBorrowShares: BigInt(s.totalBorrowShares),
    poolFeeAccrued: BigInt(s.poolFeeAccrued),
    treasuryFeeAccrued: BigInt(s.treasuryFeeAccrued),
    totalCollateral: BigInt(s.totalCollateral),
    lastAccrual: BigInt(s.lastAccrual),
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  const row = await context.db.find(market, { marketId: id });
  if (row) {
    await context.db.update(market, { marketId: id }).set(fields);
    return row;
  }
  // First sight without MarketCreated (e.g. startBlock after creation): read the params too.
  const p = await client(context).readContract({
    abi: ICredenceMarketAbi,
    address: addr,
    functionName: "marketParams",
    args: [id],
    blockNumber: event.block.number,
  });
  return insertMarket(context, event, id, p, fields);
}

type Params = {
  loanToken: Hex;
  collateralToken: Hex;
  assetId: Hex;
  kind: number;
  maxLtv: bigint;
  lt: bigint;
  supplyCap: bigint;
  borrowCap: bigint;
};

async function insertMarket(
  context: Context,
  event: Ev,
  id: Hex,
  p: Params,
  state?: Record<string, bigint>,
) {
  const values = {
    marketId: id,
    stack: marketStack(event.log.address),
    marketAddress: event.log.address,
    assetId: p.assetId,
    kind: Number(p.kind),
    loanToken: p.loanToken,
    collateralToken: p.collateralToken,
    params: jsonable(p),
    maxLtv: BigInt(p.maxLtv),
    lt: BigInt(p.lt),
    supplyCap: BigInt(p.supplyCap),
    borrowCap: BigInt(p.borrowCap),
    totalSupplyAssets: 0n,
    totalBorrowAssets: 0n,
    totalBorrowShares: 0n,
    poolFeeAccrued: 0n,
    treasuryFeeAccrued: 0n,
    totalCollateral: 0n,
    lastAccrual: 0n,
    createdBlock: event.block.number,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
    ...state,
  };
  await context.db.insert(market).values(values).onConflictDoNothing();
  return values;
}

async function refreshPosition(
  context: Context,
  event: Ev,
  id: Hex,
  owner: Hex,
) {
  const at = {
    address: event.log.address,
    blockNumber: event.block.number,
  } as const;
  const [p, debt] = await Promise.all([
    client(context).readContract({
      abi: ICredenceMarketAbi,
      functionName: "position",
      args: [id, owner],
      ...at,
    }),
    client(context).readContract({
      abi: ICredenceMarketAbi,
      functionName: "debtOf",
      args: [id, owner],
      ...at,
    }),
  ]);
  const fields = {
    collateral: BigInt(p.collateral),
    borrowShares: BigInt(p.borrowShares),
    debtSnapshot: debt,
    coverClosureId: BigInt(p.coverClosureId),
    lastBellClosureId: BigInt(p.lastBellClosureId),
    auctionId: BigInt(p.auctionId),
    autoCoverOptOut: p.autoCoverOptOut,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(position)
    .values({ marketId: id, owner, ...fields })
    .onConflictDoUpdate(fields);
}

async function logEvent(
  context: Context,
  event: Ev,
  id: Hex | null,
  owner: Hex,
  kind: string,
  amounts: Record<string, unknown>,
) {
  let cs: number | null = null;
  if (id) {
    const m = await context.db.find(market, { marketId: id });
    if (m)
      cs =
        (await context.db.find(clockState, { assetId: m.assetId }))?.state ??
        null;
  }
  await context.db
    .insert(positionEvent)
    .values({
      id: `${event.transaction.hash}:${event.log.logIndex}`,
      marketId: id,
      owner,
      kind,
      amounts: jsonable(amounts),
      clockState: cs,
      block: event.block.number,
      ts: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
}

/** A position event: refresh the market and the position, append the history row. */
async function onPosition(
  context: Context,
  event: Ev,
  id: Hex,
  owner: Hex,
  kind: string,
  args: Record<string, unknown>,
) {
  await refreshMarket(context, event, id);
  await refreshPosition(context, event, id, owner);
  const { id: _id, owner: _owner, ...amounts } = args;
  await logEvent(context, event, id, owner, kind, amounts);
}

// ── markets ──
ponder.on("Market:MarketCreated", async ({ event, context }) => {
  await insertMarket(
    context,
    event,
    event.args.id,
    event.args.p as unknown as Params,
  );
});
ponder.on("Market:Accrued", async ({ event, context }) => {
  await refreshMarket(context, event, event.args.id);
});
ponder.on("Market:FeesClaimed", async ({ event, context }) => {
  await refreshMarket(context, event, event.args.id);
});
ponder.on("Market:CapsSet", async ({ event, context }) => {
  await refreshMarket(context, event, event.args.id);
  await context.db.update(market, { marketId: event.args.id }).set({
    supplyCap: BigInt(event.args.supplyCap),
    borrowCap: BigInt(event.args.borrowCap),
  });
});
ponder.on("Market:RiskParamsSet", async ({ event, context }) => {
  await refreshMarket(context, event, event.args.id);
  await context.db
    .update(market, { marketId: event.args.id })
    .set({ maxLtv: BigInt(event.args.maxLtv), lt: BigInt(event.args.lt) });
});

// ── positions ──
ponder.on("Market:CollateralAdded", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "collateral_added",
    event.args,
  ),
);
ponder.on("Market:CollateralWithdrawn", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "collateral_withdrawn",
    event.args,
  ),
);
ponder.on("Market:Borrow", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "borrow",
    event.args,
  ),
);
ponder.on("Market:Repay", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "repay",
    event.args,
  ),
);
ponder.on("Market:BellEnforced", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "bell_enforced",
    // outcome 5 SALE_TOO_LATE (ADR-0115): no sale, no tip, lastBellClosureId not set; the notifier alerts on it
    { ...event.args, outcomeName: bellOutcomeName(Number(event.args.outcome)) },
  ),
);
ponder.on("Market:AutoCoverSet", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "auto_cover_set",
    event.args,
  ),
);
ponder.on("Market:Flagged", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "flagged",
    event.args,
  ),
);
ponder.on("Market:Dequeued", async ({ event, context }) =>
  onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "dequeued",
    event.args,
  ),
);

// Lot events: `LotReleased` names the auction, whose row (AuctionCreated, earlier) names the market.
// `PositionSettled` (v2) and `Shortfall` carry the settlement; both land on `lot_position` (projections).
// Shortfall (same tx as the PositionSettled it belongs to) is matched through the tx hash.
const settledIn = new Map<string, bigint>(); // `${tx}:${owner}` → auctionId, for a Shortfall after its PositionSettled
const shortfallIn = new Map<
  string,
  { s: bigint; pool: bigint; reserve: bigint; senior: bigint }
>();

async function marketOfAuction(
  context: Context,
  auctionId: bigint,
): Promise<Hex | null> {
  return (await context.db.find(auction, { auctionId }))?.marketId ?? null;
}
ponder.on("Market:LotReleased", async ({ event, context }) => {
  const { auctionId, owner, qty } = event.args;
  const market = event.log.address.toLowerCase() as Hex;
  // an equity lot is an AuctionHouse auction; a NAV lot is a settlement, whose market id PositionSettled fills in
  const id =
    marketStack(event.log.address) === "equity"
      ? await marketOfAuction(context, auctionId)
      : null;
  await context.db
    .insert(lotPosition)
    .values({
      market,
      auctionId,
      owner: owner.toLowerCase() as Hex,
      marketId: id,
      qty,
    })
    .onConflictDoUpdate({ qty });
  if (id) {
    await refreshMarket(context, event, id);
    await refreshPosition(context, event, id, owner);
  }
  await logEvent(context, event, id, owner, "lot_released", { auctionId, qty });
});
ponder.on("Market:PositionSettled", async ({ event, context }) => {
  const {
    marketId,
    borrower,
    auctionId,
    collateralSold,
    proceeds,
    penalty,
    shortfall,
    refund,
    debtAfter,
  } = event.args;
  const owner = borrower.toLowerCase() as Hex;
  const k = `${event.transaction.hash}:${owner}`;
  const loss = shortfallIn.get(k);
  shortfallIn.delete(k);
  settledIn.set(k, auctionId);
  const fields = {
    marketId,
    collateralSold,
    proceeds,
    penalty,
    shortfall,
    refund,
    debtAfter,
    settledAt: event.block.timestamp,
    ...(loss
      ? {
          paidByPool: loss.pool,
          paidByReserve: loss.reserve,
          seniorLoss: loss.senior,
        }
      : {}),
  };
  await context.db
    .insert(lotPosition)
    .values({
      market: event.log.address.toLowerCase() as Hex,
      auctionId,
      owner,
      qty: collateralSold,
      ...fields,
    })
    .onConflictDoUpdate(fields);
  await refreshMarket(context, event, marketId);
  await refreshPosition(context, event, marketId, borrower);
  await logEvent(context, event, marketId, borrower, "position_settled", {
    auctionId,
    collateralSold,
    proceeds,
    penalty,
    shortfall,
    refund,
    debtAfter,
  });
});
ponder.on("Market:Shortfall", async ({ event, context }) => {
  const { id, owner, s, paidPool, paidReserve, seniorLoss } = event.args;
  const k = `${event.transaction.hash}:${owner.toLowerCase()}`;
  const auctionId = settledIn.get(k);
  if (auctionId === undefined)
    shortfallIn.set(k, {
      s,
      pool: paidPool,
      reserve: paidReserve,
      senior: seniorLoss,
    });
  else
    await context.db
      .update(lotPosition, {
        market: event.log.address.toLowerCase() as Hex,
        auctionId,
        owner: owner.toLowerCase() as Hex,
      })
      .set({ paidByPool: paidPool, paidByReserve: paidReserve, seniorLoss });
  await onPosition(context, event, id, owner, "shortfall", event.args);
});

// Cover: the pool's CoverWritten (earlier in the tx) created the policy; the market's CoverBought names
// it and says whether auto-cover wrote it, and AutoCoverApplied adds the debt after the premium.
const policyIn = new Map<string, string>(); // `${tx}:${owner}` → cover_policy id
const poolOfMarket = (addr: string) => {
  const st = marketStack(addr);
  return (st === "equity" ? book.equity?.pool : book.nav?.pool)?.toLowerCase();
};
ponder.on("Market:CoverBought", async ({ event, context }) => {
  const a = event.args;
  const p = poolOfMarket(event.log.address);
  if (p) {
    const pid = `${p}:${a.policyId}`;
    if (await context.db.find(coverPolicy, { id: pid })) {
      await context.db
        .update(coverPolicy, { id: pid })
        .set({ closureId: BigInt(a.closureId), auto: a.auto_ });
      policyIn.set(`${event.transaction.hash}:${a.owner.toLowerCase()}`, pid);
    }
  }
  await onPosition(
    context,
    event,
    event.args.id,
    event.args.owner,
    "cover_bought",
    event.args,
  );
});
ponder.on("Market:AutoCoverApplied", async ({ event, context }) => {
  const { marketId, borrower, premium, debtAfter, closureId } = event.args;
  const k = `${event.transaction.hash}:${borrower.toLowerCase()}`;
  const pid = policyIn.get(k);
  policyIn.delete(k);
  if (pid)
    await context.db
      .update(coverPolicy, { id: pid })
      .set({ auto: true, debtAfter });
  await onPosition(context, event, marketId, borrower, "auto_cover_applied", {
    closureId,
    premium,
    debtAfter,
  });
});

// ── Senior Vault ──
async function refreshVault(context: Context, event: Ev) {
  const at = {
    abi: ISeniorVaultAbi,
    address: event.log.address,
    blockNumber: event.block.number,
  } as const;
  const [
    totalAssets,
    totalSupply,
    idle,
    queueLength,
    pendingRedeemShares,
    claimableAssets,
  ] = await Promise.all([
    client(context).readContract({ ...at, functionName: "totalAssets" }),
    client(context).readContract({ ...at, functionName: "totalSupply" }),
    client(context).readContract({ ...at, functionName: "idle" }),
    client(context).readContract({ ...at, functionName: "queueLength" }),
    client(context).readContract({
      ...at,
      functionName: "pendingRedeemShares",
    }),
    client(context).readContract({ ...at, functionName: "claimableAssets" }),
  ]);
  const fields = {
    vault: event.log.address,
    totalAssets,
    totalSupply,
    idle,
    queueLength,
    pendingRedeemShares,
    claimableAssets,
    updatedBlock: event.block.number,
    updatedAt: event.block.timestamp,
  };
  await context.db
    .insert(vaultState)
    .values({ stack: vaultStack(event.log.address), ...fields })
    .onConflictDoUpdate(fields);
}

for (const ev of ["Deposit", "Withdraw", "Allocated", "CapSet"] as const) {
  ponder.on(`SeniorVault:${ev}`, async ({ event, context }) =>
    refreshVault(context, event),
  );
}

ponder.on("SeniorVault:RedeemRequested", async ({ event, context }) => {
  const stack = vaultStack(event.log.address);
  const r = await client(context).readContract({
    abi: ISeniorVaultAbi,
    address: event.log.address,
    functionName: "redeemRequest",
    args: [event.args.id],
    blockNumber: event.block.number,
  });
  await context.db
    .insert(vaultRequest)
    .values({
      id: `${stack}:${event.args.id}`,
      stack,
      requestId: event.args.id,
      owner: event.args.owner,
      receiver: r.receiver,
      shares: event.args.shares,
      status: "requested",
      requestedAt: event.block.timestamp,
    })
    .onConflictDoNothing();
  await refreshVault(context, event);
});
ponder.on("SeniorVault:RedeemProcessed", async ({ event, context }) => {
  const stack = vaultStack(event.log.address);
  await context.db
    .update(vaultRequest, { id: `${stack}:${event.args.id}` })
    .set({
      assets: event.args.assets,
      status: "processed",
      processedAt: event.block.timestamp,
    });
  await refreshVault(context, event);
});
ponder.on("SeniorVault:RedeemClaimed", async ({ event, context }) => {
  const stack = vaultStack(event.log.address);
  await context.db
    .update(vaultRequest, { id: `${stack}:${event.args.id}` })
    .set({
      receiver: event.args.receiver,
      status: "claimed",
      claimedAt: event.block.timestamp,
    });
  await refreshVault(context, event);
});

// ── σ ──
ponder.on("RiskEngine:SigmaUpdated", async ({ event, context }) => {
  const { asset, closureType, sigma } = event.args;
  const fields = {
    sigma,
    block: event.block.number,
    ts: event.block.timestamp,
  };
  await context.db
    .insert(sigmaPoint)
    .values({
      assetId: asset,
      closureType: Number(closureType),
      day: event.block.timestamp / 86_400n,
      ...fields,
    })
    .onConflictDoUpdate(fields);
});
