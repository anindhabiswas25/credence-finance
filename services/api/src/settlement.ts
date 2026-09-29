// NAV settlements (S4 D, Build Guide §8.8, §10.4): the SettlementAdapter's settlements, their solver bids and
// the NAV pool's fund redemption claims, from Ponder's `settlement`, `solver_bid` and `redemption_claim`
// tables (pure projections of the draft v3 events, ADR-0111).
import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import { formatUnits, type Address, type Hex } from "viem";
import type postgres from "postgres";

// ── rows ─────────────────────────────────────────────────────────────────────────────────────────
export interface SettlementRow {
  settlementId: bigint;
  adapter: Address;
  marketId: Hex;
  venue: Address;
  qty: bigint;
  floorPrice: bigint;
  endsAt: bigint;
  status: string; // open | filled | advanced
  bids: number;
  bestPrice: bigint | null;
  bestSolver: Address | null;
  solver: Address | null;
  price: bigint | null;
  proceeds: bigint | null;
  requestId: bigint | null;
  positionsSettled: number | null;
  openedAt: bigint;
  finalizedAt: bigint | null;
}

export interface SolverBidRow {
  solver: Address;
  price: bigint;
  block: bigint;
  ts: bigint;
}

export interface RedemptionClaimRow {
  requestId: bigint;
  pool: Address;
  epochId: bigint;
  marketId: Hex;
  fund: Address;
  qty: bigint;
  cost: bigint;
  status: string; // outstanding | claimed
  assets: bigint | null;
  pnl: bigint | null;
  requestedAt: bigint;
  claimedAt: bigint | null;
}

export interface SettlementFilter {
  market?: Hex;
  status?: string;
  cursor?: bigint;
  limit: number;
}

export interface SettlementRepo {
  /** Newest first, strictly below `cursor`. */
  settlements(f: SettlementFilter): Promise<SettlementRow[]>;
  settlement(id: bigint): Promise<SettlementRow | undefined>;
  solverBids(id: bigint): Promise<SolverBidRow[]>;
  /** A pool's redemption claims, newest first. */
  redemptionClaims(pool: Address): Promise<RedemptionClaimRow[]>;
}

const b = (v: unknown): bigint | null =>
  v === null || v === undefined ? null : BigInt(v as string);
const hx = (v: unknown) => String(v) as Hex;

export function pgSettlementRepo(
  sql: postgres.Sql,
  ix: (t: string) => postgres.Helper<string>,
): SettlementRepo {
  const toRow = (r: postgres.Row): SettlementRow => ({
    settlementId: BigInt(r.settlement_id),
    adapter: hx(r.adapter) as Address,
    marketId: hx(r.market_id),
    venue: hx(r.venue) as Address,
    qty: BigInt(r.qty),
    floorPrice: BigInt(r.floor_price),
    endsAt: BigInt(r.ends_at),
    status: String(r.status),
    bids: Number(r.bids),
    bestPrice: b(r.best_price),
    bestSolver: r.best_solver ? (hx(r.best_solver) as Address) : null,
    solver: r.solver ? (hx(r.solver) as Address) : null,
    price: b(r.price),
    proceeds: b(r.proceeds),
    requestId: b(r.request_id),
    positionsSettled:
      r.positions_settled === null ? null : Number(r.positions_settled),
    openedAt: BigInt(r.opened_at),
    finalizedAt: b(r.finalized_at),
  });
  return {
    async settlements(f) {
      const rows = await sql`select * from ${ix("settlement")}
         where true
         ${f.market ? sql`and market_id = ${f.market.toLowerCase()}` : sql``}
         ${f.status ? sql`and status = ${f.status}` : sql``}
         ${f.cursor !== undefined ? sql`and settlement_id < ${f.cursor.toString()}` : sql``}
         order by settlement_id desc limit ${f.limit}`;
      return rows.map(toRow);
    },
    async settlement(id) {
      const [r] =
        await sql`select * from ${ix("settlement")} where settlement_id = ${id.toString()}`;
      return r ? toRow(r) : undefined;
    },
    async solverBids(id) {
      const rows =
        await sql`select solver, price, block, ts from ${ix("solver_bid")}
                   where settlement_id = ${id.toString()} order by block, id`;
      return rows.map((r) => ({
        solver: hx(r.solver) as Address,
        price: BigInt(r.price),
        block: BigInt(r.block),
        ts: BigInt(r.ts),
      }));
    },
    async redemptionClaims(pool) {
      const rows = await sql`select * from ${ix("redemption_claim")}
         where pool = ${pool.toLowerCase()} order by request_id desc`;
      return rows.map((r) => ({
        requestId: BigInt(r.request_id),
        pool: hx(r.pool) as Address,
        epochId: BigInt(r.epoch_id),
        marketId: hx(r.market_id),
        fund: hx(r.fund) as Address,
        qty: BigInt(r.qty),
        cost: BigInt(r.cost),
        status: String(r.status),
        assets: b(r.assets),
        pnl: b(r.pnl),
        requestedAt: BigInt(r.requested_at),
        claimedAt: b(r.claimed_at),
      }));
    },
  };
}

export function memSettlementRepo(seed: {
  settlements?: SettlementRow[];
  bids?: Record<string, SolverBidRow[]>;
  claims?: RedemptionClaimRow[];
}): SettlementRepo {
  return {
    async settlements(f) {
      return (seed.settlements ?? [])
        .filter(
          (s) =>
            (!f.market ||
              s.marketId.toLowerCase() === f.market.toLowerCase()) &&
            (!f.status || s.status === f.status) &&
            (f.cursor === undefined || s.settlementId < f.cursor),
        )
        .sort((x, y) => (x.settlementId > y.settlementId ? -1 : 1))
        .slice(0, f.limit);
    },
    async settlement(id) {
      return seed.settlements?.find((s) => s.settlementId === id);
    },
    async solverBids(id) {
      return seed.bids?.[id.toString()] ?? [];
    },
    async redemptionClaims(pool) {
      return (seed.claims ?? []).filter(
        (c) => c.pool.toLowerCase() === pool.toLowerCase(),
      );
    },
  };
}

// ── bodies ───────────────────────────────────────────────────────────────────────────────────────
const amt = (v: bigint, d: number) => ({
  raw: v.toString(),
  formatted: formatUnits(v, d),
});
const amtN = (v: bigint | null, d: number) => (v === null ? null : amt(v, d));
const str = (v: bigint | null) => (v === null ? null : v.toString());

function settlementBody(s: SettlementRow, d: number, now: number) {
  return {
    settlementId: s.settlementId.toString(),
    marketId: s.marketId,
    venue: s.venue,
    status: s.status as "open" | "filled" | "advanced",
    qty: s.qty.toString(),
    floorPrice: s.floorPrice.toString(),
    endsAt: Number(s.endsAt),
    secondsLeft:
      s.status === "open" ? Math.max(0, Number(s.endsAt) - now) : null,
    bids: s.bids,
    best:
      s.bestPrice === null
        ? null
        : { solver: s.bestSolver, price: s.bestPrice.toString() },
    outcome:
      s.status === "open"
        ? null
        : {
            kind: (s.status === "filled" ? "solver_fill" : "pool_advance") as
              "solver_fill" | "pool_advance",
            solver: s.solver,
            price: str(s.price),
            proceeds: amtN(s.proceeds, d),
            redemptionRequestId: str(s.requestId),
            positionsSettled: s.positionsSettled,
          },
    openedAt: Number(s.openedAt),
    finalizedAt: s.finalizedAt === null ? null : Number(s.finalizedAt),
  };
}

/** The pool's redemption claims for /v1/pool/{stack}: outstanding ones count in NAV at cost (§8.6.1). */
export function redemptionClaimsBody(rows: RedemptionClaimRow[], d: number) {
  const outstanding = rows.filter((r) => r.status === "outstanding");
  return {
    outstandingAtCost: amt(
      outstanding.reduce((a, r) => a + r.cost, 0n),
      d,
    ),
    outstanding: outstanding.length,
    items: rows.map((r) => ({
      requestId: r.requestId.toString(),
      epochId: r.epochId.toString(),
      marketId: r.marketId,
      fund: r.fund,
      qty: r.qty.toString(),
      cost: amt(r.cost, d),
      status: r.status,
      assets: amtN(r.assets, d),
      pnl: str(r.pnl),
      requestedAt: Number(r.requestedAt),
      claimedAt: r.claimedAt === null ? null : Number(r.claimedAt),
    })),
  };
}

// ── routes ───────────────────────────────────────────────────────────────────────────────────────
const ErrorBody = z.object({ error: z.string(), message: z.string() });
const Amt = z.object({ raw: z.string(), formatted: z.string() });
const SettlementBody = z
  .object({
    settlementId: z.string(),
    marketId: z.string(),
    venue: z.string(),
    status: z.enum(["open", "filled", "advanced"]),
    qty: z.string(),
    floorPrice: z
      .string()
      .openapi({ description: "WAD per token: NAV × (1 − κ_nav)" }),
    endsAt: z.number(),
    secondsLeft: z.number().nullable(),
    bids: z.number(),
    best: z
      .object({ solver: z.string().nullable(), price: z.string() })
      .nullable(),
    outcome: z
      .object({
        kind: z.enum(["solver_fill", "pool_advance"]),
        solver: z.string().nullable(),
        price: z.string().nullable(),
        proceeds: Amt.nullable(),
        redemptionRequestId: z.string().nullable(),
        positionsSettled: z.number().nullable(),
      })
      .nullable(),
    openedAt: z.number(),
    finalizedAt: z.number().nullable(),
  })
  .openapi("Settlement");

export interface SettlementDeps {
  settlement: SettlementRepo;
  loanDecimals?: number;
  now?: () => number; // ms
}

export function registerSettlementRoutes(
  app: OpenAPIHono,
  deps: SettlementDeps,
) {
  const d = deps.loanDecimals ?? 6;
  const nowS = () => Math.floor((deps.now?.() ?? Date.now()) / 1000);

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/settlements",
      summary:
        "NAV-stack settlements, newest first (solver fill or pool advance)",
      request: {
        query: z.object({
          market: z
            .string()
            .regex(/^0x[0-9a-fA-F]{64}$/)
            .optional()
            .openapi({
              param: { name: "market", in: "query" },
              description: "bytes32 market id",
            }),
          status: z
            .enum(["open", "filled", "advanced"])
            .optional()
            .openapi({ param: { name: "status", in: "query" } }),
          cursor: z
            .string()
            .regex(/^\d{1,20}$/, "a decimal id")
            .optional()
            .openapi({ param: { name: "cursor", in: "query" } }),
          limit: z.coerce
            .number()
            .int()
            .min(1)
            .max(100)
            .default(20)
            .openapi({ param: { name: "limit", in: "query" } }),
        }),
      },
      responses: {
        200: {
          description: "Settlements",
          content: {
            "application/json": {
              schema: z.object({
                items: z.array(SettlementBody),
                nextCursor: z.string().nullable(),
              }),
            },
          },
        },
      },
    }),
    async (c) => {
      const q = c.req.valid("query");
      const rows = await deps.settlement.settlements({
        market: q.market as Hex | undefined,
        status: q.status,
        cursor: q.cursor === undefined ? undefined : BigInt(q.cursor),
        limit: q.limit,
      });
      const now = nowS();
      return c.json(
        {
          items: rows.map((s) => settlementBody(s, d, now)),
          nextCursor:
            rows.length === q.limit
              ? rows[rows.length - 1]!.settlementId.toString()
              : null,
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/settlements/{id}",
      summary: "One NAV settlement with its solver bids",
      request: {
        params: z.object({
          id: z
            .string()
            .regex(/^\d{1,20}$/)
            .openapi({ param: { name: "id", in: "path" } }),
        }),
      },
      responses: {
        200: {
          description: "Settlement",
          content: {
            "application/json": {
              schema: SettlementBody.extend({
                bidList: z.array(
                  z.object({
                    solver: z.string(),
                    price: z.string(),
                    block: z.string(),
                    ts: z.number(),
                  }),
                ),
              }),
            },
          },
        },
        404: {
          description: "Unknown settlement",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const id = BigInt(c.req.valid("param").id);
      const s = await deps.settlement.settlement(id);
      if (!s)
        return c.json(
          { error: "not_found", message: `settlement ${id} not indexed` },
          404,
        );
      const bids = await deps.settlement.solverBids(id);
      return c.json(
        {
          ...settlementBody(s, d, nowS()),
          bidList: bids.map((x) => ({
            solver: x.solver,
            price: x.price.toString(),
            block: x.block.toString(),
            ts: Number(x.ts),
          })),
        },
        200,
      );
    },
  );
}
