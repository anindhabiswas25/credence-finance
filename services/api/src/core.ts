// Markets, positions, the Bell quote and the Senior Vault (Build Guide §10.4). Indexed rows come from
// Ponder's views; anything that moves with time (debt with interest, safe LTV, the premium, the share
// price) is read live from the chain at one block and priced with risk-wasm (@credence/sdk/risk), so
// `/bell` equals the market's own `bellStatus` (acceptance 4).
import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import { formatUnits, isAddress, getAddress, type Hex } from "viem";
import { clockStateName } from "@credence/sdk";
import {
  BellStatus,
  bellFromSafeLtv,
  coverQuote,
  safeLtvFor,
  seniorRate,
  utilization,
} from "@credence/sdk/risk";
import type { ChainReader, RiskContext } from "./chain.ts";
import type { ClockRepo, CoreRepo, MarketRow } from "./repo.ts";
import type { SetStore } from "./sets.ts";
import { log } from "./log.ts";

export interface CoreDeps {
  core: CoreRepo;
  clock: ClockRepo;
  chain?: ChainReader;
  sets?: SetStore;
  /** (pool NAV + protocol reserve) ÷ borrows for a stack, read at `block` through one of its markets (S3). */
  cushion?: (
    market: Hex,
    borrows: bigint,
    block: bigint,
  ) => Promise<bigint | null>;
}

/** Safe LTV for the next closure per market (lower-case id), exactly as /v1/markets reports it. */
export async function safeLtvsOf(
  deps: CoreDeps,
): Promise<Map<string, bigint | null>> {
  const out = new Map<string, bigint | null>();
  if (!deps.chain) return out;
  for (const m of await deps.core.markets()) {
    const ctx = await deps.chain
      .risk(m.marketAddress, m.marketId)
      .catch(() => undefined);
    out.set(
      m.marketId.toLowerCase(),
      ctx ? await safeLtvNext(ctx, deps.sets) : null,
    );
  }
  return out;
}

const WAD = 10n ** 18n;
const ErrorBody = z.object({ error: z.string(), message: z.string() });
const Amount = z
  .object({ raw: z.string(), formatted: z.string() })
  .openapi("Amount");
const Ratio = z
  .object({ raw: z.string(), percent: z.string() })
  .openapi("Ratio");
const amt = (v: bigint, decimals: number) => ({
  raw: v.toString(),
  formatted: formatUnits(v, decimals),
});
const ratio = (v: bigint) => ({
  raw: v.toString(),
  percent: (Number((v * 1_000_000n) / WAD) / 10_000).toFixed(4),
});
const closureName = (t: number) =>
  ["NONE", "OVERNIGHT", "WEEKEND", "HOLIDAY_WEEKEND"][t] ?? `UNKNOWN_${t}`;
const statusName = (s: number) =>
  (["SAFE", "NEEDS_ACTION", "COVERED"] as const)[s] ?? `UNKNOWN_${s}`;
const LOAN_DECIMALS_FALLBACK = 6; // USDC, when no chain reader is configured

const NextClosure = z.object({
  closureType: z.object({ code: z.number(), name: z.string() }),
  closeAt: z.number(),
  reopenAt: z.number(),
  days: z.number(),
  safeLtv: Ratio.nullable().openapi({
    description:
      "Safe LTV for this closure (engine σ and the on-chain scenario set); null if the set file is not loaded",
  }),
  sigma: Ratio,
});
const Live = z
  .object({
    block: z.string(),
    borrowRate: Ratio.openapi({
      description: "Annual borrow rate (kinked model)",
    }),
    utilisation: Ratio,
    liquidity: Amount,
    maxLtvEffective: Ratio,
    coverPaused: z.boolean(),
    nextClosure: NextClosure,
  })
  .openapi("MarketLive");
const Market = z
  .object({
    marketId: z.string(),
    stack: z.string(),
    market: z.string(),
    assetId: z.string(),
    kind: z.number(),
    loanToken: z.string(),
    collateralToken: z.string(),
    maxLtv: Ratio,
    lt: Ratio,
    supplyCap: Amount,
    borrowCap: Amount,
    totalSupply: Amount,
    totalBorrow: Amount,
    totalCollateral: z.string(),
    clock: z
      .object({
        state: z.object({ code: z.number(), name: z.string() }),
        closureId: z.string(),
      })
      .nullable(),
    updatedBlock: z.string(),
    live: Live.nullable(),
  })
  .openapi("Market");

async function safeLtvNext(
  ctx: RiskContext,
  sets?: SetStore,
): Promise<bigint | null> {
  const set = sets?.byHash(ctx.scenarioHash);
  if (!set) return null;
  return safeLtvFor({
    set,
    params: ctx.params,
    sigma: ctx.sigma,
    maxLtv: ctx.maxLtvEff,
  });
}

async function marketBody(m: MarketRow, deps: CoreDeps) {
  let ctx: RiskContext | undefined;
  if (deps.chain) {
    try {
      ctx = await deps.chain.risk(m.marketAddress, m.marketId);
    } catch (err) {
      log.warn(
        { err: String(err), marketId: m.marketId },
        "live market read failed",
      );
    }
  }
  const d = ctx?.loanDecimals ?? LOAN_DECIMALS_FALLBACK;
  const clock = await deps.clock.clock(m.assetId);
  const live = ctx
    ? {
        block: ctx.block.toString(),
        borrowRate: ratio(ctx.borrowRate),
        utilisation: ratio(
          utilization(ctx.state.totalBorrowAssets, ctx.state.totalSupplyAssets),
        ),
        liquidity: amt(ctx.liquidity, d),
        maxLtvEffective: ratio(ctx.maxLtvEff),
        coverPaused: ctx.coverPaused,
        nextClosure: {
          closureType: {
            code: ctx.closureType,
            name: closureName(ctx.closureType),
          },
          closeAt: ctx.closeAt,
          reopenAt: ctx.reopenAt,
          days: Number(ctx.closureDays),
          safeLtv: await safeLtvNext(ctx, deps.sets).then((v) =>
            v === null ? null : ratio(v),
          ),
          sigma: ratio(ctx.sigma),
        },
      }
    : null;
  return {
    marketId: m.marketId,
    stack: m.stack,
    market: m.marketAddress,
    assetId: m.assetId,
    kind: m.kind,
    loanToken: m.loanToken,
    collateralToken: m.collateralToken,
    maxLtv: ratio(m.maxLtv),
    lt: ratio(m.lt),
    supplyCap: amt(m.supplyCap, d),
    borrowCap: amt(m.borrowCap, d),
    totalSupply: amt(ctx?.state.totalSupplyAssets ?? m.totalSupplyAssets, d),
    totalBorrow: amt(ctx?.state.totalBorrowAssets ?? m.totalBorrowAssets, d),
    totalCollateral: (
      ctx?.state.totalCollateral ?? m.totalCollateral
    ).toString(),
    clock: clock
      ? {
          state: { code: clock.state, name: clockStateName(clock.state) },
          closureId: clock.closureId.toString(),
        }
      : null,
    updatedBlock: m.updatedBlock.toString(),
    live,
    _ctx: ctx,
  };
}

const strip = <T extends { _ctx?: unknown }>({ _ctx, ...rest }: T) => rest;

const MarketIdParam = z.object({
  marketId: z
    .string()
    .regex(/^0x[0-9a-fA-F]{64}$/)
    .openapi({ param: { name: "marketId", in: "path" } }),
});
const OwnerParam = z.object({
  owner: z
    .string()
    .refine((s) => isAddress(s), "not an address")
    .openapi({ param: { name: "owner", in: "path" } }),
});

const PositionBody = z
  .object({
    marketId: z.string(),
    owner: z.string(),
    collateral: z.string(),
    borrowShares: z.string(),
    cover: z.object({
      coveredClosureId: z.string(),
      coveredForNext: z.boolean().nullable(),
    }),
    auctionId: z.string().nullable(),
    autoCover: z.boolean(),
    indexedBlock: z.string(),
    live: z
      .object({
        block: z.string(),
        debt: Amount,
        debtProjected: Amount,
        collateralValue: Amount,
        ltv: Ratio,
        healthFactor: Ratio,
        borrowLimitLtv: Ratio,
      })
      .nullable(),
  })
  .openapi("Position");

const BellBody = z
  .object({
    marketId: z.string(),
    owner: z.string(),
    block: z.string(),
    status: z.object({ code: z.number(), name: z.string() }),
    closure: z.object({
      closureId: z.string(),
      closureType: z.object({ code: z.number(), name: z.string() }),
      closeAt: z.number(),
      reopenAt: z.number(),
      days: z.number(),
    }),
    safeLtv: Ratio,
    ltvProjected: Ratio,
    collateralValue: Amount,
    debtProjected: Amount,
    cure: z.object({
      repay: Amount,
      addCollateral: z
        .string()
        .openapi({ description: "collateral token units, rounded up" }),
      addCollateralValue: Amount,
    }),
    premium: Amount.nullable().openapi({
      description:
        "Gap Cover premium for this closure (NEEDS_ACTION only, like the market's view)",
    }),
    expectedLoss: Amount.nullable(),
    expectedShortfall: Amount.nullable(),
    scenarioHash: z.string(),
  })
  .openapi("Bell");

export function registerCoreRoutes(app: OpenAPIHono, deps: CoreDeps) {
  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/markets",
      summary:
        "All markets: params, utilisation, rates, caps, clock state, safe LTV for the next closure",
      responses: {
        200: {
          description: "Markets",
          content: {
            "application/json": {
              schema: z.object({ markets: z.array(Market) }),
            },
          },
        },
      },
    }),
    async (c) => {
      const rows = await deps.core.markets();
      const markets = await Promise.all(
        rows.map((m) => marketBody(m, deps).then(strip)),
      );
      return c.json({ markets }, 200);
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/markets/{marketId}",
      summary: "One market",
      request: { params: MarketIdParam },
      responses: {
        200: {
          description: "Market",
          content: { "application/json": { schema: Market } },
        },
        404: {
          description: "Not indexed",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const id = c.req.valid("param").marketId.toLowerCase() as Hex;
      const m = await deps.core.market(id);
      if (!m)
        return c.json({ error: "not_found", message: `no market ${id}` }, 404);
      return c.json(strip(await marketBody(m, deps)), 200);
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/positions/{owner}",
      summary:
        "All positions of an owner with HF, LTV, limit, cover and auction status",
      request: { params: OwnerParam },
      responses: {
        200: {
          description: "Positions",
          content: {
            "application/json": {
              schema: z.object({
                owner: z.string(),
                positions: z.array(PositionBody),
              }),
            },
          },
        },
      },
    }),
    async (c) => {
      const owner = getAddress(c.req.valid("param").owner);
      const rows = await deps.core.positionsOf(owner);
      const positions = await Promise.all(
        rows.map(async (p) => {
          const m = await deps.core.market(p.marketId);
          let live = null;
          let coveredForNext: boolean | null = null;
          if (m && deps.chain) {
            try {
              const ctx = await deps.chain.risk(m.marketAddress, m.marketId);
              const s = await deps.chain.position(m.marketAddress, ctx, owner);
              const d = ctx.loanDecimals;
              coveredForNext = s.covered;
              live = {
                block: ctx.block.toString(),
                debt: amt(s.debt, d),
                debtProjected: amt(s.debtProjected, d),
                collateralValue: amt(s.collateralValue, d),
                ltv: ratio(s.ltv),
                healthFactor: ratio(s.healthFactor),
                borrowLimitLtv: ratio(s.borrowLimitLtv),
              };
            } catch (err) {
              log.warn(
                { err: String(err), marketId: p.marketId, owner },
                "live position read failed",
              );
            }
          }
          return {
            marketId: p.marketId,
            owner,
            collateral: p.collateral.toString(),
            borrowShares: p.borrowShares.toString(),
            cover: {
              coveredClosureId: p.coverClosureId.toString(),
              coveredForNext,
            },
            auctionId: p.auctionId === 0n ? null : p.auctionId.toString(),
            autoCover: !p.autoCoverOptOut,
            indexedBlock: p.updatedBlock.toString(),
            live,
          };
        }),
      );
      return c.json({ owner, positions }, 200);
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/positions/{marketId}/{owner}/bell",
      summary:
        "Bell status for the upcoming closure: exact cures and a live Gap Cover quote (risk-wasm on current chain state)",
      request: { params: MarketIdParam.merge(OwnerParam) },
      responses: {
        200: {
          description: "Bell",
          content: { "application/json": { schema: BellBody } },
        },
        404: {
          description: "Unknown market",
          content: { "application/json": { schema: ErrorBody } },
        },
        503: {
          description:
            "No chain reader, or the engine's scenario set is not loaded",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const { marketId, owner: o } = c.req.valid("param");
      const owner = getAddress(o);
      const m = await deps.core.market(marketId.toLowerCase() as Hex);
      if (!m)
        return c.json(
          { error: "not_found", message: `no market ${marketId}` },
          404,
        );
      if (!deps.chain)
        return c.json(
          { error: "unavailable", message: "no RPC configured" },
          503,
        );
      const ctx = await deps.chain.risk(m.marketAddress, m.marketId);
      const set = deps.sets?.byHash(ctx.scenarioHash);
      if (!set)
        return c.json(
          {
            error: "unavailable",
            message: `scenario set ${ctx.scenarioHash} (asset ${ctx.assetId}, type ${ctx.closureType}) is not loaded`,
          },
          503,
        );
      const pos = await deps.chain.position(m.marketAddress, ctx, owner);
      const safe = safeLtvFor({
        set,
        params: ctx.params,
        sigma: ctx.sigma,
        maxLtv: ctx.maxLtvEff,
      });
      const bell = bellFromSafeLtv(
        {
          collateralValue: pos.collateralValue,
          debtProjected: pos.debtProjected,
          valuationPrice: ctx.valuationPrice,
          collDecimals: ctx.collDecimals,
          loanDecimals: ctx.loanDecimals,
          covered: pos.covered,
        },
        safe,
      );
      // The market's view: debt 0 is SAFE (no engine call); only NEEDS_ACTION is quoted.
      const status =
        pos.debtProjected === 0n && !pos.covered
          ? BellStatus.SAFE
          : bell.status;
      let quote: {
        premium: bigint;
        expectedLoss: bigint;
        expectedShortfall: bigint;
      } | null = null;
      if (status === BellStatus.NEEDS_ACTION) {
        const utilAfter = await deps.chain
          .uAfter(ctx, owner, pos)
          .catch(() => 0n);
        quote = coverQuote({
          set,
          params: ctx.params,
          sigma: ctx.sigma,
          collateralValue: pos.collateralValue,
          debtProjected: pos.debtProjected,
          maxLtv: ctx.maxLtvEff,
          valuationPrice: ctx.valuationPrice,
          collDecimals: ctx.collDecimals,
          loanDecimals: ctx.loanDecimals,
          closureDays: ctx.closureDays,
          utilAfter,
        });
      }
      const d = ctx.loanDecimals;
      const needs = status === BellStatus.NEEDS_ACTION;
      const ltvUp =
        pos.collateralValue === 0n
          ? pos.debtProjected === 0n
            ? 0n
            : (1n << 256n) - 1n
          : (pos.debtProjected * WAD + pos.collateralValue - 1n) /
            pos.collateralValue;
      return c.json(
        {
          marketId: m.marketId,
          owner,
          block: ctx.block.toString(),
          status: { code: status, name: statusName(status) },
          closure: {
            closureId: ctx.upcomingClosureId.toString(),
            closureType: {
              code: ctx.closureType,
              name: closureName(ctx.closureType),
            },
            closeAt: ctx.closeAt,
            reopenAt: ctx.reopenAt,
            days: Number(ctx.closureDays),
          },
          safeLtv: ratio(safe),
          ltvProjected: ratio(ltvUp),
          collateralValue: amt(pos.collateralValue, d),
          debtProjected: amt(pos.debtProjected, d),
          cure: {
            repay: amt(needs ? bell.cureRepay : 0n, d),
            addCollateral: (needs ? bell.cureCollateral : 0n).toString(),
            addCollateralValue: amt(needs ? bell.cureCollateralValue : 0n, d),
          },
          premium: quote ? amt(quote.premium, d) : null,
          expectedLoss: quote ? amt(quote.expectedLoss, d) : null,
          expectedShortfall: quote ? amt(quote.expectedShortfall, d) : null,
          scenarioHash: ctx.scenarioHash,
        },
        200,
      );
    },
  );

  const VaultBody = z
    .object({
      stack: z.string(),
      vault: z.string(),
      totalAssets: Amount,
      totalSupply: z.string(),
      sharePrice: z.string().openapi({ description: "assets per whole share" }),
      apy: Ratio.nullable().openapi({
        description:
          "Supply-weighted senior rate of the stack's markets over total assets (idle earns 0)",
      }),
      idle: Amount,
      queue: z.object({
        length: z.string(),
        pendingShares: z.string(),
        claimable: Amount,
        head: z.array(
          z.object({
            requestId: z.string(),
            owner: z.string(),
            shares: z.string(),
          }),
        ),
      }),
      cushion: Ratio.nullable().openapi({
        description:
          "(pool NAV + protocol reserve) ÷ the stack's borrows, at `block`; null without a chain reader or with no borrows",
      }),
      block: z.string(),
    })
    .openapi("Vault");

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/vault/{stack}",
      summary: "Senior Vault: TVL, share price, APY, idle, queue",
      request: {
        params: z.object({
          stack: z
            .enum(["equity", "nav"])
            .openapi({ param: { name: "stack", in: "path" } }),
        }),
      },
      responses: {
        200: {
          description: "Vault",
          content: { "application/json": { schema: VaultBody } },
        },
        404: {
          description: "Not indexed",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const { stack } = c.req.valid("param");
      const row = await deps.core.vault(stack);
      if (!row)
        return c.json(
          { error: "not_found", message: `no ${stack} vault indexed` },
          404,
        );
      const head = await deps.core.openRequests(stack, 10);
      let live = null;
      let apy: bigint | null = null;
      let cushionV: bigint | null = null;
      let d = LOAN_DECIMALS_FALLBACK;
      if (deps.chain) {
        live = await deps.chain.vault(row.vault).catch(() => null);
        const markets = (await deps.core.markets()).filter(
          (m) => m.stack === stack,
        );
        let weighted = 0n;
        let borrows = 0n;
        for (const m of markets) {
          const ctx = await deps.chain
            .risk(m.marketAddress, m.marketId)
            .catch(() => undefined);
          if (!ctx) continue;
          d = ctx.loanDecimals;
          const u = utilization(
            ctx.state.totalBorrowAssets,
            ctx.state.totalSupplyAssets,
          );
          const r = seniorRate(
            ctx.borrowRate,
            u,
            (BigInt(ctx.state.feePoolBps) * WAD) / 10_000n,
            (BigInt(ctx.state.feeTreasuryBps) * WAD) / 10_000n,
          );
          weighted += r * ctx.state.totalSupplyAssets;
          borrows += ctx.state.totalBorrowAssets;
        }
        const ta = live?.totalAssets ?? row.totalAssets;
        apy = ta > 0n ? weighted / ta : 0n;
        if (deps.cushion && markets[0] && live)
          cushionV = await deps
            .cushion(markets[0].marketAddress, borrows, live.block)
            .catch(() => null);
      }
      const decimals = live?.decimals ?? d;
      return c.json(
        {
          stack,
          vault: row.vault,
          totalAssets: amt(live?.totalAssets ?? row.totalAssets, d),
          totalSupply: (live?.totalSupply ?? row.totalSupply).toString(),
          sharePrice: live
            ? formatUnits(live.assetsPerShare, d)
            : row.totalSupply > 0n
              ? formatUnits(
                  (row.totalAssets * 10n ** BigInt(decimals)) / row.totalSupply,
                  d,
                )
              : "1",
          apy: apy === null ? null : ratio(apy),
          idle: amt(live?.idle ?? row.idle, d),
          queue: {
            length: (live?.queueLength ?? row.queueLength).toString(),
            pendingShares: (
              live?.pendingRedeemShares ?? row.pendingRedeemShares
            ).toString(),
            claimable: amt(live?.claimableAssets ?? row.claimableAssets, d),
            head: head.map((r) => ({
              requestId: r.requestId.toString(),
              owner: r.owner,
              shares: r.shares.toString(),
            })),
          },
          cushion: cushionV === null ? null : ratio(cushionV),
          block: (live?.block ?? row.updatedBlock).toString(),
        },
        200,
      );
    },
  );
}
