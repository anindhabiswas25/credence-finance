// Risk transfer (S3, Build Guide §10.4): the underwriter pool, its epochs, the auction house and the public
// risk page. History comes from Ponder's S3 tables (pure projections of the v2 events, ADR-0110); what moves
// with time (NAV, share price, utilisation, headroom, free cash) is read live from the pool at one block, so
// every figure equals the chain at the block the response names (acceptance 5).
import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import {
  formatUnits,
  parseAbi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import type postgres from "postgres";
import { ICredenceMarketAbi } from "@credence/sdk";
import type { CoreRepo } from "./repo.ts";
import { redemptionClaimsBody, type SettlementRepo } from "./settlement.ts";

// ── rows ─────────────────────────────────────────────────────────────────────────────────────────
export interface PoolRow {
  stack: string;
  pool: Address;
  venue: Hex | null;
  activeEpoch: bigint | null;
  lastSettledEpoch: bigint | null;
  navAfterLastSettlement: bigint | null;
  sharePrice: bigint | null;
  premiumsWritten: bigint;
  lossesPaid: bigint;
  riskFees: bigint;
  penalties: bigint;
  bonds: bigint;
  updatedBlock: bigint;
}

export interface EpochRow {
  epochId: bigint;
  status: string;
  bellWindowAt: bigint | null;
  bellAt: bigint | null;
  closeAt: bigint | null;
  reopenAt: bigint | null;
  navBefore: bigint | null;
  equityAtRisk: bigint | null;
  worstLoss: bigint | null;
  premiums: bigint;
  policies: number;
  riskFees: bigint | null;
  penalties: bigint | null;
  bonds: bigint | null;
  backstopPnl: bigint | null;
  lossesPaid: bigint | null;
  pendingLossReserve: bigint | null;
  navAfter: bigint | null;
  sharePriceAfter: bigint | null;
  sharesBurned: bigint | null;
  sharesMinted: bigint | null;
  settledAt: bigint | null;
}

export interface AuctionRow {
  auctionId: bigint;
  house: Address;
  kind: number;
  marketId: Hex;
  assetId: Hex;
  closureId: bigint;
  venueEpoch: bigint;
  tranche: number;
  deadlines: number[];
  status: string;
  lot: bigint | null;
  reserve: bigint | null;
  positions: number | null;
  bids: number;
  pStar: bigint | null;
  filled: bigint | null;
  qPool: bigint | null;
  proceeds: bigint | null;
  blendedPrice: bigint | null;
  bondsForfeited: bigint;
  createdAt: bigint;
  clearedAt: bigint | null;
  /** REOPEN: the closure's open print P° (clock), else null. */
  openPrint: bigint | null;
}

export interface LotPositionRow {
  owner: Address;
  qty: bigint;
  collateralSold: bigint | null;
  proceeds: bigint | null;
  penalty: bigint | null;
  shortfall: bigint | null;
  refund: bigint | null;
  debtAfter: bigint | null;
  paidByPool: bigint | null;
  paidByReserve: bigint | null;
  seniorLoss: bigint | null;
}

export interface BidRow {
  bidder: Address;
  status: string;
  maxNotional: bigint | null;
  bond: bigint | null;
  qty: bigint | null;
  price: bigint | null;
  tokens: bigint | null;
  refund: bigint | null;
  bondForfeited: boolean;
}

export interface InventoryRow {
  assetId: Hex;
  qty: bigint;
  cost: bigint;
  listed: bigint;
  realisedPnl: bigint;
}

export interface MarketRiskRow {
  marketId: Hex;
  premiums: bigint;
  policies: number;
  lossPool: bigint;
  lossReserve: bigint;
  lossSenior: bigint;
}

export interface AuctionFilter {
  status?: string;
  kind?: number;
  asset?: Hex;
  cursor?: bigint;
  limit: number;
}

export interface RiskTransferRepo {
  pool(stack: string): Promise<PoolRow | undefined>;
  /** Newest first, strictly below `cursor`. */
  epochs(
    pool: Address,
    cursor: bigint | undefined,
    limit: number,
  ): Promise<EpochRow[]>;
  auctions(f: AuctionFilter): Promise<AuctionRow[]>;
  auction(id: bigint): Promise<AuctionRow | undefined>;
  lotPositions(id: bigint): Promise<LotPositionRow[]>;
  bids(id: bigint): Promise<BidRow[]>;
  inventory(pool: Address): Promise<InventoryRow[]>;
  marketRisk(): Promise<MarketRiskRow[]>;
}

const b = (v: unknown): bigint | null =>
  v === null || v === undefined ? null : BigInt(v as string);
const hx = (v: unknown) => String(v) as Hex;

export function pgRiskTransferRepo(
  sql: postgres.Sql,
  ix: (t: string) => postgres.Helper<string>,
): RiskTransferRepo {
  const toAuction = (r: postgres.Row): AuctionRow => ({
    auctionId: BigInt(r.auction_id),
    house: hx(r.house) as Address,
    kind: Number(r.kind),
    marketId: hx(r.market_id),
    assetId: hx(r.asset_id),
    closureId: BigInt(r.closure_id),
    venueEpoch: BigInt(r.venue_epoch),
    tranche: Number(r.tranche),
    deadlines: (r.deadlines as (string | number)[]).map(Number),
    status: String(r.status),
    lot: b(r.lot),
    reserve: b(r.reserve),
    positions: r.positions === null ? null : Number(r.positions),
    bids: Number(r.bids),
    pStar: b(r.p_star),
    filled: b(r.filled),
    qPool: b(r.q_pool),
    proceeds: b(r.proceeds),
    blendedPrice: b(r.blended_price),
    bondsForfeited: BigInt(r.bonds_forfeited),
    createdAt: BigInt(r.created_at),
    clearedAt: b(r.cleared_at),
    openPrint: b(r.open_print),
  });
  const withPrint = (where: postgres.PendingQuery<postgres.Row[]>) =>
    sql`select a.*, o.price as open_print from ${ix("auction")} a
          left join ${ix("open_print")} o on a.kind = 0 and o.asset_id = a.asset_id and o.closure_id = a.closure_id
         where true ${where}`;
  return {
    async pool(stack) {
      const [r] = await sql`select * from ${ix("pool")} where stack = ${stack}`;
      if (!r) return undefined;
      return {
        stack: String(r.stack),
        pool: hx(r.pool) as Address,
        venue: r.venue ? hx(r.venue) : null,
        activeEpoch: b(r.active_epoch),
        lastSettledEpoch: b(r.last_settled_epoch),
        navAfterLastSettlement: b(r.nav_after_last_settlement),
        sharePrice: b(r.share_price),
        premiumsWritten: BigInt(r.premiums_written),
        lossesPaid: BigInt(r.losses_paid),
        riskFees: BigInt(r.risk_fees),
        penalties: BigInt(r.penalties),
        bonds: BigInt(r.bonds),
        updatedBlock: BigInt(r.updated_block),
      };
    },
    async epochs(pool, cursor, limit) {
      const rows =
        await sql`select * from ${ix("epoch")} where pool = ${pool.toLowerCase()}
                             ${cursor === undefined ? sql`` : sql`and epoch_id < ${cursor.toString()}`}
                             order by epoch_id desc limit ${limit}`;
      return rows.map((r) => ({
        epochId: BigInt(r.epoch_id),
        status: String(r.status),
        bellWindowAt: b(r.bell_window_at),
        bellAt: b(r.bell_at),
        closeAt: b(r.close_at),
        reopenAt: b(r.reopen_at),
        navBefore: b(r.nav_before),
        equityAtRisk: b(r.equity_at_risk),
        worstLoss: b(r.worst_loss),
        premiums: BigInt(r.premiums),
        policies: Number(r.policies),
        riskFees: b(r.risk_fees),
        penalties: b(r.penalties),
        bonds: b(r.bonds),
        backstopPnl: b(r.backstop_pnl),
        lossesPaid: b(r.losses_paid),
        pendingLossReserve: b(r.pending_loss_reserve),
        navAfter: b(r.nav_after),
        sharePriceAfter: b(r.share_price_after),
        sharesBurned: b(r.shares_burned),
        sharesMinted: b(r.shares_minted),
        settledAt: b(r.settled_at),
      }));
    },
    async auctions(f) {
      const rows = await withPrint(sql`
        ${f.status ? sql`and a.status = ${f.status}` : sql``}
        ${f.kind === undefined ? sql`` : sql`and a.kind = ${f.kind}`}
        ${f.asset ? sql`and a.asset_id = ${f.asset.toLowerCase()}` : sql``}
        ${f.cursor === undefined ? sql`` : sql`and a.auction_id < ${f.cursor.toString()}`}
        order by a.auction_id desc limit ${f.limit}`);
      return rows.map(toAuction);
    },
    async auction(id) {
      const [r] = await withPrint(sql`and a.auction_id = ${id.toString()}`);
      return r ? toAuction(r) : undefined;
    },
    async lotPositions(id) {
      const rows =
        await sql`select * from ${ix("lot_position")} where auction_id = ${id.toString()} order by owner`;
      return rows.map((r) => ({
        owner: hx(r.owner) as Address,
        qty: BigInt(r.qty),
        collateralSold: b(r.collateral_sold),
        proceeds: b(r.proceeds),
        penalty: b(r.penalty),
        shortfall: b(r.shortfall),
        refund: b(r.refund),
        debtAfter: b(r.debt_after),
        paidByPool: b(r.paid_by_pool),
        paidByReserve: b(r.paid_by_reserve),
        seniorLoss: b(r.senior_loss),
      }));
    },
    async bids(id) {
      const rows =
        await sql`select * from ${ix("bid")} where auction_id = ${id.toString()} order by bidder`;
      return rows.map((r) => ({
        bidder: hx(r.bidder) as Address,
        status: String(r.status),
        maxNotional: b(r.max_notional),
        bond: b(r.bond),
        qty: b(r.qty),
        price: b(r.price),
        tokens: b(r.tokens),
        refund: b(r.refund),
        bondForfeited: Boolean(r.bond_forfeited),
      }));
    },
    async inventory(pool) {
      const rows =
        await sql`select * from ${ix("backstop_inventory")} where pool = ${pool.toLowerCase()} order by asset_id`;
      return rows.map((r) => ({
        assetId: hx(r.asset_id),
        qty: BigInt(r.qty),
        cost: BigInt(r.cost),
        listed: BigInt(r.listed),
        realisedPnl: BigInt(r.realised_pnl),
      }));
    },
    async marketRisk() {
      const rows = await sql`
        select m.market_id,
               coalesce(c.premiums, 0) as premiums, coalesce(c.policies, 0) as policies,
               coalesce(l.pool, 0) as pool, coalesce(l.reserve, 0) as reserve, coalesce(l.senior, 0) as senior
          from ${ix("market")} m
          left join (select market_id, sum(premium) as premiums, count(*) as policies from ${ix("cover_policy")} group by market_id) c
            on c.market_id = m.market_id
          left join (select a.market_id, sum(lp.paid_by_pool) as pool, sum(lp.paid_by_reserve) as reserve, sum(lp.senior_loss) as senior
                       from ${ix("lot_position")} lp join ${ix("auction")} a on a.auction_id = lp.auction_id group by a.market_id) l
            on l.market_id = m.market_id
         order by m.market_id`;
      return rows.map((r) => ({
        marketId: hx(r.market_id),
        premiums: BigInt(r.premiums),
        policies: Number(r.policies),
        lossPool: BigInt(r.pool),
        lossReserve: BigInt(r.reserve),
        lossSenior: BigInt(r.senior),
      }));
    },
  };
}

export function memRiskTransferRepo(seed: {
  pools?: PoolRow[];
  epochs?: Record<string, EpochRow[]>;
  auctions?: AuctionRow[];
  lots?: Record<string, LotPositionRow[]>;
  bids?: Record<string, BidRow[]>;
  inventory?: Record<string, InventoryRow[]>;
  marketRisk?: MarketRiskRow[];
}): RiskTransferRepo {
  return {
    async pool(stack) {
      return seed.pools?.find((p) => p.stack === stack);
    },
    async epochs(pool, cursor, limit) {
      return (seed.epochs?.[pool.toLowerCase()] ?? [])
        .filter((e) => cursor === undefined || e.epochId < cursor)
        .sort((a, c) => (a.epochId > c.epochId ? -1 : 1))
        .slice(0, limit);
    },
    async auctions(f) {
      return (seed.auctions ?? [])
        .filter(
          (a) =>
            (!f.status || a.status === f.status) &&
            (f.kind === undefined || a.kind === f.kind) &&
            (!f.asset || a.assetId.toLowerCase() === f.asset.toLowerCase()) &&
            (f.cursor === undefined || a.auctionId < f.cursor),
        )
        .sort((a, c) => (a.auctionId > c.auctionId ? -1 : 1))
        .slice(0, f.limit);
    },
    async auction(id) {
      return seed.auctions?.find((a) => a.auctionId === id);
    },
    async lotPositions(id) {
      return seed.lots?.[id.toString()] ?? [];
    },
    async bids(id) {
      return seed.bids?.[id.toString()] ?? [];
    },
    async inventory(pool) {
      return seed.inventory?.[pool.toLowerCase()] ?? [];
    },
    async marketRisk() {
      return seed.marketRisk ?? [];
    },
  };
}

// ── live pool reads (interface v2, ADR-0110) ─────────────────────────────────────────────────────
export const PoolAbi = parseAbi([
  "function nav() view returns (uint256)",
  "function sharePrice() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function activeEpoch() view returns (uint64 epochId, bool exists)",
  "function utilisation(uint64 epochId) view returns (uint256)",
  "function capacityHeadroom(uint64 epochId) view returns (uint256)",
  "function freeCash() view returns (uint256)",
  "function unearnedPremiums() view returns (uint256)",
  "function pendingLossReserve() view returns (uint256)",
  "function asset() view returns (address)",
]);
const ReserveAbi = parseAbi(["function balance() view returns (uint256)"]);

export interface PoolLive {
  block: bigint;
  nav: bigint;
  sharePrice: bigint;
  totalSupply: bigint;
  activeEpoch: bigint | null;
  utilisation: bigint | null;
  headroom: bigint | null;
  freeCash: bigint;
  unearnedPremiums: bigint;
  pendingLossReserve: bigint;
}

export async function readPoolLive(
  client: PublicClient,
  pool: Address,
  blockNumber?: bigint,
): Promise<PoolLive> {
  const block = blockNumber ?? (await client.getBlockNumber());
  const at = { address: pool, abi: PoolAbi, blockNumber: block } as const;
  const [
    nav,
    sharePrice,
    totalSupply,
    [e, exists],
    freeCash,
    unearnedPremiums,
    pendingLossReserve,
  ] = await Promise.all([
    client.readContract({ ...at, functionName: "nav" }),
    client.readContract({ ...at, functionName: "sharePrice" }),
    client.readContract({ ...at, functionName: "totalSupply" }),
    client.readContract({ ...at, functionName: "activeEpoch" }),
    client.readContract({ ...at, functionName: "freeCash" }),
    client.readContract({ ...at, functionName: "unearnedPremiums" }),
    client.readContract({ ...at, functionName: "pendingLossReserve" }),
  ]);
  const [utilisation, headroom] = exists
    ? await Promise.all([
        client.readContract({ ...at, functionName: "utilisation", args: [e] }),
        client.readContract({
          ...at,
          functionName: "capacityHeadroom",
          args: [e],
        }),
      ])
    : [null, null];
  return {
    block,
    nav,
    sharePrice,
    totalSupply,
    activeEpoch: exists ? e : null,
    utilisation,
    headroom,
    freeCash,
    unearnedPremiums,
    pendingLossReserve,
  };
}

/** The stack's cushion through one of its markets: the pool and the reserve from `market.wiring()`. */
export async function stackCushion(
  client: PublicClient,
  market: Address,
  borrows: bigint,
  blockNumber: bigint,
): Promise<bigint | null> {
  const w = await client.readContract({
    address: market,
    abi: ICredenceMarketAbi,
    functionName: "wiring",
    blockNumber,
  });
  return (await cushion(client, w.pool, w.reserve, borrows, blockNumber)).value;
}

/** Cushion under the senior vault (§10.4): (pool NAV + protocol reserve) ÷ the stack's borrows, WAD. */
export async function cushion(
  client: PublicClient,
  pool: Address,
  reserve: Address | null,
  borrows: bigint,
  blockNumber: bigint,
): Promise<{ value: bigint | null; pool: bigint; reserve: bigint }> {
  const [nav, res] = await Promise.all([
    client.readContract({
      address: pool,
      abi: PoolAbi,
      functionName: "nav",
      blockNumber,
    }),
    reserve
      ? client.readContract({
          address: reserve,
          abi: ReserveAbi,
          functionName: "balance",
          blockNumber,
        })
      : Promise.resolve(0n),
  ]);
  return {
    value: borrows > 0n ? ((nav + res) * WAD) / borrows : null,
    pool: nav,
    reserve: res,
  };
}

// ── routes ───────────────────────────────────────────────────────────────────────────────────────
export interface RtDeps {
  rt: RiskTransferRepo;
  core?: CoreRepo;
  client?: PublicClient;
  /** Loan-token decimals (USDC). */
  loanDecimals?: number;
  /** Safe LTV for the next closure per market id (lower-case), as /v1/markets computes it. */
  safeLtvs?: () => Promise<Map<string, bigint | null>>;
  /** NAV stack (S4): the pool's fund redemption claims, in NAV at cost (§8.6.1). */
  settlement?: SettlementRepo;
}

const WAD = 10n ** 18n;
const ErrorBody = z.object({ error: z.string(), message: z.string() });
const Amt = z
  .object({ raw: z.string(), formatted: z.string() })
  .openapi("Amount");
const Pct = z.object({ raw: z.string(), percent: z.string() }).openapi("Ratio");
const KINDS = ["REOPEN", "INTRADAY", "EMERGENCY", "PRECLOSE"] as const;

const amt = (v: bigint, d: number) => ({
  raw: v.toString(),
  formatted: formatUnits(v, d),
});
const amtN = (v: bigint | null, d: number) => (v === null ? null : amt(v, d));
const pct = (v: bigint) => ({
  raw: v.toString(),
  percent: (Number((v * 1_000_000n) / WAD) / 10_000).toFixed(4),
});
const str = (v: bigint | null) => (v === null ? null : v.toString());
const StackParam = z.object({
  stack: z
    .enum(["equity", "nav"])
    .openapi({ param: { name: "stack", in: "path" } }),
});
const Cursor = z
  .string()
  .regex(/^\d{1,20}$/, "a decimal id")
  .optional()
  .openapi({
    param: { name: "cursor", in: "query" },
    description:
      "Return items with an id below this one (the previous page's nextCursor)",
  });
const Limit = z.coerce
  .number()
  .int()
  .min(1)
  .max(100)
  .default(20)
  .openapi({ param: { name: "limit", in: "query" } });

const PoolBody = z
  .object({
    stack: z.string(),
    pool: z.string(),
    block: z.string().nullable().openapi({
      description:
        "The block every live figure was read at (null: no chain reader)",
    }),
    nav: Amt.nullable(),
    sharePrice: z.string().nullable().openapi({ description: "WAD" }),
    totalSupply: z.string().nullable(),
    activeEpoch: z.string().nullable(),
    utilisation: Pct.nullable(),
    headroom: Amt.nullable(),
    freeCash: Amt.nullable(),
    unearnedPremiums: Amt.nullable(),
    pendingLossReserve: Amt.nullable(),
    lastSettled: z.object({
      epochId: z.string().nullable(),
      navAfter: Amt.nullable(),
      sharePrice: z.string().nullable(),
    }),
    allTime: z.object({
      premiums: Amt,
      riskFees: Amt,
      penalties: Amt,
      bonds: Amt,
      lossesPaid: Amt,
    }),
    currentEpoch: z.unknown().nullable(),
    backstopInventory: z.array(
      z.object({
        assetId: z.string(),
        qty: z.string(),
        cost: Amt,
        listed: z.string(),
        realisedPnl: z.string(),
      }),
    ),
    redemptionClaims: z
      .object({
        outstandingAtCost: Amt,
        outstanding: z.number(),
        items: z.array(z.unknown()),
      })
      .nullable()
      .openapi({
        description:
          "NAV stack: the pool's fund redemption claims from pool advances; outstanding ones count in NAV at cost (§8.6.1). null without the settlement tables",
      }),
  })
  .openapi("Pool");

function epochBody(e: EpochRow, d: number) {
  return {
    epochId: e.epochId.toString(),
    status: e.status,
    bellWindowAt: e.bellWindowAt === null ? null : Number(e.bellWindowAt),
    bellAt: e.bellAt === null ? null : Number(e.bellAt),
    closeAt: e.closeAt === null ? null : Number(e.closeAt),
    reopenAt: e.reopenAt === null ? null : Number(e.reopenAt),
    exposure: {
      equityAtRisk: amtN(e.equityAtRisk, d),
      worstLoss: amtN(e.worstLoss, d),
      policies: e.policies,
    },
    pnl: {
      premiums: amt(e.premiums, d),
      riskFees: amtN(e.riskFees, d),
      penalties: amtN(e.penalties, d),
      bonds: amtN(e.bonds, d),
      backstopPnl:
        e.backstopPnl === null
          ? null
          : {
              raw: e.backstopPnl.toString(),
              formatted: formatUnits(e.backstopPnl, d),
            },
      lossesPaid: amtN(e.lossesPaid, d),
      pendingLossReserve: amtN(e.pendingLossReserve, d),
    },
    navBefore: amtN(e.navBefore, d),
    navAfter: amtN(e.navAfter, d),
    sharePriceAfter: str(e.sharePriceAfter),
    sharesBurned: str(e.sharesBurned),
    sharesMinted: str(e.sharesMinted),
    settledAt: e.settledAt === null ? null : Number(e.settledAt),
  };
}

function auctionSummary(a: AuctionRow, d: number) {
  return {
    auctionId: a.auctionId.toString(),
    kind: { code: a.kind, name: KINDS[a.kind] ?? `UNKNOWN_${a.kind}` },
    marketId: a.marketId,
    assetId: a.assetId,
    closureId: a.closureId.toString(),
    venueEpoch: a.venueEpoch.toString(),
    tranche: a.tranche,
    status: a.status,
    deadlines: {
      lotFixAt: a.deadlines[0] ?? null,
      biddingStartAt: a.deadlines[1] ?? null,
      biddingEndAt: a.deadlines[2] ?? null,
      clearAt: a.deadlines[3] ?? null,
    },
    lot: str(a.lot),
    reserve: str(a.reserve),
    positions: a.positions,
    bids: a.bids,
    clearing:
      a.pStar === null
        ? null
        : {
            pStar: a.pStar.toString(),
            openPrint: str(a.openPrint),
            pStarVsOpenPrint: a.openPrint
              ? pct(((a.pStar - a.openPrint) * WAD) / a.openPrint)
              : null,
            filled: str(a.filled),
            qPool: str(a.qPool),
            proceeds: amtN(a.proceeds, d),
            blendedPrice: str(a.blendedPrice),
            bondsForfeited: amt(a.bondsForfeited, d),
          },
    createdAt: Number(a.createdAt),
    clearedAt: a.clearedAt === null ? null : Number(a.clearedAt),
  };
}

export function registerRiskTransferRoutes(app: OpenAPIHono, deps: RtDeps) {
  const d = deps.loanDecimals ?? 6;

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/pool/{stack}",
      summary:
        "Underwriter pool: NAV, share price, utilisation, headroom, current epoch exposure, backstop inventory",
      request: { params: StackParam },
      responses: {
        200: {
          description: "Pool",
          content: { "application/json": { schema: PoolBody } },
        },
        404: {
          description: "Not indexed",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const { stack } = c.req.valid("param");
      const row = await deps.rt.pool(stack);
      if (!row)
        return c.json(
          { error: "not_found", message: `no ${stack} pool indexed` },
          404,
        );
      const live = deps.client
        ? await readPoolLive(deps.client, row.pool).catch(() => null)
        : null;
      const current = live?.activeEpoch ?? row.activeEpoch;
      const [cur] =
        current === null
          ? []
          : (await deps.rt.epochs(row.pool, current + 1n, 1)).filter(
              (e) => e.epochId === current,
            );
      const inv = await deps.rt.inventory(row.pool);
      const claims = deps.settlement
        ? redemptionClaimsBody(
            await deps.settlement.redemptionClaims(row.pool),
            d,
          )
        : null;
      return c.json(
        {
          stack,
          pool: row.pool,
          block: live ? live.block.toString() : null,
          nav: live ? amt(live.nav, d) : null,
          sharePrice: live ? live.sharePrice.toString() : null,
          totalSupply: live ? live.totalSupply.toString() : null,
          activeEpoch: current === null ? null : current.toString(),
          utilisation: live?.utilisation != null ? pct(live.utilisation) : null,
          headroom: live?.headroom != null ? amt(live.headroom, d) : null,
          freeCash: live ? amt(live.freeCash, d) : null,
          unearnedPremiums: live ? amt(live.unearnedPremiums, d) : null,
          pendingLossReserve: live ? amt(live.pendingLossReserve, d) : null,
          lastSettled: {
            epochId: str(row.lastSettledEpoch),
            navAfter: amtN(row.navAfterLastSettlement, d),
            sharePrice: str(row.sharePrice),
          },
          allTime: {
            premiums: amt(row.premiumsWritten, d),
            riskFees: amt(row.riskFees, d),
            penalties: amt(row.penalties, d),
            bonds: amt(row.bonds, d),
            lossesPaid: amt(row.lossesPaid, d),
          },
          currentEpoch: cur ? epochBody(cur, d) : null,
          backstopInventory: inv.map((i) => ({
            assetId: i.assetId,
            qty: i.qty.toString(),
            cost: amt(i.cost, d),
            listed: i.listed.toString(),
            realisedPnl: i.realisedPnl.toString(),
          })),
          redemptionClaims: claims,
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/pool/{stack}/epochs",
      summary: "Epoch history with the P&L breakdown (newest first)",
      request: {
        params: StackParam,
        query: z.object({ cursor: Cursor, limit: Limit }),
      },
      responses: {
        200: {
          description: "Epochs",
          content: {
            "application/json": {
              schema: z.object({
                items: z.array(z.unknown()),
                nextCursor: z.string().nullable(),
              }),
            },
          },
        },
        404: {
          description: "Not indexed",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const { stack } = c.req.valid("param");
      const { cursor, limit } = c.req.valid("query");
      const row = await deps.rt.pool(stack);
      if (!row)
        return c.json(
          { error: "not_found", message: `no ${stack} pool indexed` },
          404,
        );
      const rows = await deps.rt.epochs(
        row.pool,
        cursor === undefined ? undefined : BigInt(cursor),
        limit,
      );
      return c.json(
        {
          items: rows.map((e) => epochBody(e, d)),
          nextCursor:
            rows.length === limit
              ? rows[rows.length - 1]!.epochId.toString()
              : null,
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/auctions",
      summary: "Auctions, newest first (the bidder feed)",
      request: {
        query: z.object({
          status: z
            .enum(["queue", "fixed", "cleared", "settled"])
            .optional()
            .openapi({ param: { name: "status", in: "query" } }),
          kind: z
            .enum(KINDS)
            .optional()
            .openapi({ param: { name: "kind", in: "query" } }),
          asset: z
            .string()
            .regex(/^0x[0-9a-fA-F]{64}$/)
            .optional()
            .openapi({
              param: { name: "asset", in: "query" },
              description: "bytes32 asset id",
            }),
          cursor: Cursor,
          limit: Limit,
        }),
      },
      responses: {
        200: {
          description: "Auctions",
          content: {
            "application/json": {
              schema: z.object({
                items: z.array(z.unknown()),
                nextCursor: z.string().nullable(),
              }),
            },
          },
        },
      },
    }),
    async (c) => {
      const q = c.req.valid("query");
      const rows = await deps.rt.auctions({
        status: q.status,
        kind: q.kind === undefined ? undefined : KINDS.indexOf(q.kind),
        asset: q.asset as Hex | undefined,
        cursor: q.cursor === undefined ? undefined : BigInt(q.cursor),
        limit: q.limit,
      });
      return c.json(
        {
          items: rows.map((a) => auctionSummary(a, d)),
          nextCursor:
            rows.length === q.limit
              ? rows[rows.length - 1]!.auctionId.toString()
              : null,
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/auctions/{auctionId}",
      summary:
        "One auction: lot, reserve, phase deadlines, clearing result, bids and per-position settlement",
      request: {
        params: z.object({
          auctionId: z
            .string()
            .regex(/^\d{1,20}$/)
            .openapi({ param: { name: "auctionId", in: "path" } }),
        }),
      },
      responses: {
        200: {
          description: "Auction",
          content: { "application/json": { schema: z.unknown() } },
        },
        404: {
          description: "Unknown auction",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const id = BigInt(c.req.valid("param").auctionId);
      const a = await deps.rt.auction(id);
      if (!a)
        return c.json(
          { error: "not_found", message: `auction ${id} not indexed` },
          404,
        );
      const [lots, bids] = await Promise.all([
        deps.rt.lotPositions(id),
        deps.rt.bids(id),
      ]);
      return c.json(
        {
          ...auctionSummary(a, d),
          bidList: bids.map((x) => ({
            bidder: x.bidder,
            status: x.status,
            maxNotional: amtN(x.maxNotional, d),
            bond: amtN(x.bond, d),
            qty: str(x.qty),
            price: str(x.price),
            tokens: str(x.tokens),
            refund: amtN(x.refund, d),
            bondForfeited: x.bondForfeited,
          })),
          settlement: lots.map((l) => ({
            owner: l.owner,
            qty: l.qty.toString(),
            collateralSold: str(l.collateralSold),
            proceeds: amtN(l.proceeds, d),
            penalty: amtN(l.penalty, d),
            shortfall: amtN(l.shortfall, d),
            refund: amtN(l.refund, d),
            debtAfter: amtN(l.debtAfter, d),
            losses:
              l.shortfall && l.shortfall > 0n
                ? {
                    pool: amtN(l.paidByPool, d),
                    reserve: amtN(l.paidByReserve, d),
                    senior: amtN(l.seniorLoss, d),
                  }
                : null,
            settled: l.proceeds !== null,
          })),
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/risk",
      summary:
        "Public risk page (Architecture §3.9): per market premiums and losses by layer; pools; every auction's p* vs the open print; backstop inventory",
      responses: {
        200: {
          description: "Risk page",
          content: { "application/json": { schema: z.unknown() } },
        },
      },
    }),
    async (c) => {
      const [perMarket, auctions] = await Promise.all([
        deps.rt.marketRisk(),
        deps.rt.auctions({ status: undefined, limit: 100 }),
      ]);
      const pools = [];
      for (const stack of ["equity", "nav"] as const) {
        const row = await deps.rt.pool(stack);
        if (!row) continue;
        const live = deps.client
          ? await readPoolLive(deps.client, row.pool).catch(() => null)
          : null;
        pools.push({
          stack,
          pool: row.pool,
          block: live ? live.block.toString() : null,
          size: live ? amt(live.nav, d) : amtN(row.navAfterLastSettlement, d),
          utilisation: live?.utilisation != null ? pct(live.utilisation) : null,
          premiumsCollected: amt(row.premiumsWritten, d),
          lossesPaid: amt(row.lossesPaid, d),
          backstopInventory: (await deps.rt.inventory(row.pool)).map((i) => ({
            assetId: i.assetId,
            qty: i.qty.toString(),
            cost: amt(i.cost, d),
          })),
        });
      }
      const auctionList = auctions
        .filter((x) => x.pStar !== null)
        .map((a) => ({
          auctionId: a.auctionId.toString(),
          kind: KINDS[a.kind],
          assetId: a.assetId,
          closureId: a.closureId.toString(),
          pStar: a.pStar!.toString(),
          reserve: str(a.reserve),
          openPrint: str(a.openPrint),
          pStarVsOpenPrint: a.openPrint
            ? pct(((a.pStar! - a.openPrint) * WAD) / a.openPrint)
            : null,
          qPool: str(a.qPool),
        }));
      const safe = deps.safeLtvs
        ? await deps.safeLtvs()
        : new Map<string, bigint | null>();
      return c.json(
        {
          markets: perMarket.map((m) => ({
            marketId: m.marketId,
            safeLtvNextClosure: ((v) => (v == null ? null : pct(v)))(
              safe.get(m.marketId.toLowerCase()),
            ),
            premiumsCollected: amt(m.premiums, d),
            policies: m.policies,
            lossesByLayer: {
              pool: amt(m.lossPool, d),
              reserve: amt(m.lossReserve, d),
              senior: amt(m.lossSenior, d),
            },
          })),
          pools,
          auctions: auctionList,
        },
        200,
      );
    },
  );
}
