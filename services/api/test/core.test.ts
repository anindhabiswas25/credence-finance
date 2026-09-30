// Markets, positions, /bell and the vault over an in-memory indexer and a fake chain reader. The
// devnode e2e (make api-bell-e2e) proves /bell == CredenceMarket.bellStatus on real contracts; this
// suite pins the plumbing: which inputs feed risk-wasm, rounding, and the failure modes.
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import {
  getAddress,
  keccak256,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import {
  BellStatus,
  bellFromSafeLtv,
  coverQuote,
  loadScenarioSet,
  ready,
  safeLtvFor,
  type RiskParams,
} from "@credence/sdk/risk";
import { createApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import type { ChainReader, PositionState, RiskContext } from "../src/chain.ts";
import { collateralValue, maxLtvEff } from "../src/chain.ts";
import { memoryRepos, type MarketRow, type PositionRow } from "../src/repo.ts";
import { memorySetStore } from "../src/sets.ts";

// Response bodies are checked field by field; a loose JSON type keeps the assertions readable.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type J = any;
const WAD = 10n ** 18n;
const wad = (s: string) => {
  const [i, f = ""] = s.split(".");
  return BigInt(i!) * WAD + BigInt((f + "0".repeat(18)).slice(0, 18));
};
const config: Config = {
  port: 0,
  databaseUrl: "unused",
  indexerSchema: "indexer",
  corsOrigins: [],
  siweDomain: "localhost",
  chainId: 412346,
  sessionSecret: "x".repeat(40),
  sessionTtlS: 3600,
  rateLimitPerMin: 1000,
  rateLimitAuthPerMin: 1000,
  secureCookies: false,
  scenarioDirs: [],
  publicApiUrl: "http://localhost:8787",
  allowlistEnabled: true,
  allowlistPerIpPerHour: 5,
};
const NVDA = keccak256(stringToHex("NVDA:XNAS"));
const MARKET_ID = keccak256(stringToHex("market:NVDA")) as Hex;
const MARKET = "0x00000000000000000000000000000000000000aa" as Address;
const PRIYA = getAddress("0x00000000000000000000000000000000000000b1");
const BEN = getAddress("0x00000000000000000000000000000000000000b2");
const PARAMS: RiskParams = {
  alpha: wad("0.001"),
  kappa: wad("0.03"),
  theta: wad("1"),
  costOfCap: wad("0.15"),
  eta: wad("4"),
  beta: wad("0.975"),
  uMax: wad("0.5"),
  minPremium: 500_000n,
};
const setText = readFileSync(
  new URL(
    "../../../contracts/test/fixtures/risk/NVDA-XNAS-2-63c7ce73.json",
    import.meta.url,
  ),
  "utf8",
);

let set: ReturnType<typeof loadScenarioSet>;
let ctx: RiskContext;
beforeAll(async () => {
  await ready;
  set = loadScenarioSet(setText);
  ctx = {
    block: 1234n,
    timestamp: 1_791_300_000n,
    marketId: MARKET_ID,
    assetId: NVDA,
    closureType: 2,
    closeAt: 1_791_316_800,
    reopenAt: 1_791_552_600,
    closureDays: 3n,
    upcomingClosureId: 8n,
    epochId: 41n,
    maxLtv: wad("0.75"),
    maxLtvEff: wad("0.75"),
    lt: wad("0.85"),
    coverPaused: false,
    sigma: wad("0.045"),
    params: PARAMS,
    scenarioHash: set.scenarioHash as Hex,
    valuationPrice: wad("180"),
    collDecimals: 18,
    loanDecimals: 6,
    loanSymbol: "tUSDG",
    multiplier: {
      sharesPerToken: WAD,
      live: WAD,
      next: 0n,
      effectiveAt: 0,
      corporateAction: false,
    },
    borrowRate: wad("0.0733"),
    liquidity: 1_000_000_000_000n,
    state: {
      totalSupplyAssets: 2_000_000_000_000n,
      totalBorrowAssets: 1_600_000_000_000n,
      totalBorrowShares: 1_600_000_000_000n,
      totalCollateral: 10_000n * WAD,
      feePoolBps: 1500,
      feeTreasuryBps: 500,
    },
    wiring: {
      clock: MARKET,
      oracle: MARKET,
      engine: MARKET,
      pool: MARKET,
      vault: MARKET,
    },
  };
});

const debts: Record<string, bigint> = {
  [PRIYA]: 74_000_000_000n,
  [BEN]: 50_000_000_000n,
};
const fakeChain = (uAfter = wad("0.2")): ChainReader => ({
  async risk() {
    return ctx;
  },
  async position(_m, c, owner): Promise<PositionState> {
    const q = 500n * WAD;
    const d = debts[owner] ?? 0n;
    const cv = collateralValue(
      q,
      c.valuationPrice,
      c.collDecimals,
      c.loanDecimals,
    );
    return {
      collateral: q,
      borrowShares: d,
      coverClosureId: 0n,
      auctionId: 0n,
      autoCoverOptOut: false,
      debt: d,
      debtProjected: d,
      collateralValue: cv,
      covered: false,
      ltv: (d * WAD) / cv,
      healthFactor: (cv * c.lt) / (d || 1n),
      borrowLimitLtv: c.maxLtvEff,
    };
  },
  async uAfter() {
    return uAfter;
  },
  async vault() {
    return {
      block: 1234n,
      totalAssets: 2_100_000_000_000n,
      totalSupply: 2_000_000_000_000n,
      idle: 100_000_000_000n,
      queueLength: 1n,
      pendingRedeemShares: 5_000_000n,
      claimableAssets: 0n,
      assetsPerShare: 1_050_000n,
      decimals: 6,
    };
  },
});

const market: MarketRow = {
  marketId: MARKET_ID,
  stack: "equity",
  marketAddress: MARKET,
  assetId: NVDA,
  kind: 0,
  loanToken: MARKET,
  collateralToken: MARKET,
  params: {},
  maxLtv: wad("0.75"),
  lt: wad("0.85"),
  supplyCap: 10n ** 13n,
  borrowCap: 10n ** 13n,
  totalSupplyAssets: 1n,
  totalBorrowAssets: 1n,
  totalBorrowShares: 1n,
  poolFeeAccrued: 0n,
  treasuryFeeAccrued: 0n,
  totalCollateral: 1n,
  updatedBlock: 1200n,
  updatedAt: 0n,
};
const pos = (owner: Address): PositionRow => ({
  marketId: MARKET_ID,
  owner,
  collateral: 500n * WAD,
  borrowShares: 1n,
  debtSnapshot: 1n,
  coverClosureId: 0n,
  lastBellClosureId: 0n,
  auctionId: 0n,
  autoCoverOptOut: false,
  updatedBlock: 1200n,
  updatedAt: 0n,
});

function mk(opts: { chain?: ChainReader; withSet?: boolean } = {}) {
  const repos = memoryRepos({
    markets: [market],
    positions: [pos(PRIYA), pos(BEN)],
    vaults: [
      {
        stack: "equity",
        vault: MARKET,
        totalAssets: 1n,
        totalSupply: 1n,
        idle: 1n,
        queueLength: 1n,
        pendingRedeemShares: 5_000_000n,
        claimableAssets: 0n,
        updatedBlock: 1200n,
        updatedAt: 0n,
      },
    ],
    requests: {
      equity: [
        {
          requestId: 7n,
          owner: BEN,
          shares: 5_000_000n,
          assets: null,
          status: "requested",
          requestedAt: 0n,
        },
      ],
    },
  });
  return createApp({
    config,
    clock: repos.clock,
    auth: repos.auth,
    core: repos.core,
    chain: "chain" in opts ? opts.chain : fakeChain(),
    sets: opts.withSet === false ? memorySetStore([]) : memorySetStore([set]),
  });
}

describe("GET /v1/positions/:marketId/:owner/bell", () => {
  it("NEEDS_ACTION: cures and premium are exactly risk-wasm's on the chain inputs", async () => {
    const res = await mk().request(`/v1/positions/${MARKET_ID}/${PRIYA}/bell`);
    expect(res.status).toBe(200);
    const b = (await res.json()) as J;
    const cv = 90_000_000_000n;
    const safe = safeLtvFor({
      set,
      params: PARAMS,
      sigma: ctx.sigma,
      maxLtv: ctx.maxLtvEff,
    });
    const want = bellFromSafeLtv(
      {
        collateralValue: cv,
        debtProjected: debts[PRIYA]!,
        valuationPrice: wad("180"),
        collDecimals: 18,
        loanDecimals: 6,
      },
      safe,
    );
    const q = coverQuote({
      set,
      params: PARAMS,
      sigma: ctx.sigma,
      collateralValue: cv,
      debtProjected: debts[PRIYA]!,
      maxLtv: ctx.maxLtvEff,
      valuationPrice: wad("180"),
      collDecimals: 18,
      loanDecimals: 6,
      closureDays: 3n,
      utilAfter: wad("0.2"),
    });
    expect(b.status).toEqual({
      code: BellStatus.NEEDS_ACTION,
      name: "NEEDS_ACTION",
    });
    expect(b.safeLtv.raw).toBe(safe.toString());
    expect(b.cure.repay.raw).toBe(want.cureRepay.toString());
    expect(b.cure.addCollateral).toBe(want.cureCollateral.toString());
    expect(b.premium.raw).toBe(q.premium.toString());
    expect(BigInt(b.premium.raw)).toBeGreaterThanOrEqual(PARAMS.minPremium);
    expect(b.closure).toMatchObject({
      closureId: "8",
      closureType: { code: 2, name: "WEEKEND" },
      days: 3,
    });
    expect(b.scenarioHash).toBe(set.scenarioHash);
  });

  it("SAFE below the safe LTV: zero cures and no premium (like the market's view)", async () => {
    const b = (await (
      await mk().request(`/v1/positions/${MARKET_ID}/${BEN}/bell`)
    ).json()) as J;
    expect(b.status.name).toBe("SAFE");
    expect(b.cure.repay.raw).toBe("0");
    expect(b.premium).toBeNull();
  });

  it("the utilisation-after from the pool changes the premium (it is a live input)", async () => {
    const lo = (await (
      await mk({ chain: fakeChain(0n) }).request(
        `/v1/positions/${MARKET_ID}/${PRIYA}/bell`,
      )
    ).json()) as J;
    const hi = (await (
      await mk({ chain: fakeChain(wad("0.45")) }).request(
        `/v1/positions/${MARKET_ID}/${PRIYA}/bell`,
      )
    ).json()) as J;
    expect(BigInt(hi.premium.raw)).toBeGreaterThanOrEqual(
      BigInt(lo.premium.raw),
    );
  });

  it("503 when the engine's set is not loaded or there is no RPC; 404 for an unknown market; 400 for a bad owner", async () => {
    expect(
      (
        await mk({ withSet: false }).request(
          `/v1/positions/${MARKET_ID}/${PRIYA}/bell`,
        )
      ).status,
    ).toBe(503);
    expect(
      (
        await mk({ chain: undefined }).request(
          `/v1/positions/${MARKET_ID}/${PRIYA}/bell`,
        )
      ).status,
    ).toBe(503);
    expect(
      (await mk().request(`/v1/positions/0x${"11".repeat(32)}/${PRIYA}/bell`))
        .status,
    ).toBe(404);
    expect(
      (await mk().request(`/v1/positions/${MARKET_ID}/0x1234/bell`)).status,
    ).toBe(400);
  });
});

describe("markets, positions, vault", () => {
  it("/v1/markets carries the live rate, utilisation and the safe LTV for the next closure", async () => {
    const body = (await (await mk().request("/v1/markets")).json()) as {
      markets: J[];
    };
    expect(body.markets).toHaveLength(1);
    const m = body.markets[0]!;
    expect(m.live.utilisation.percent).toBe("80.0000");
    expect(m.live.nextClosure.safeLtv.raw).toBe(
      safeLtvFor({
        set,
        params: PARAMS,
        sigma: ctx.sigma,
        maxLtv: ctx.maxLtvEff,
      }).toString(),
    );
    expect(m.totalBorrow.formatted).toBe("1600000");
    expect(m).not.toHaveProperty("_ctx");
    const one = await mk().request(
      `/v1/markets/${MARKET_ID.toUpperCase().replace("0X", "0x")}`,
    );
    expect(one.status).toBe(200);
  });

  it("/v1/markets without an RPC serves the indexed rows with live = null", async () => {
    const m = (
      (await (
        await mk({ chain: undefined }).request("/v1/markets")
      ).json()) as { markets: J[] }
    ).markets[0]!;
    expect(m.live).toBeNull();
    expect(m.maxLtv.percent).toBe("75.0000");
  });

  it("/v1/positions/:owner has live debt, LTV, HF and limit", async () => {
    const body = (await (
      await mk().request(`/v1/positions/${PRIYA.toLowerCase()}`)
    ).json()) as { positions: J[] };
    expect(body.positions).toHaveLength(1);
    expect(body.positions[0]!.live.debt.formatted).toBe("74000");
    expect(body.positions[0]!.live.collateralValue.formatted).toBe("90000");
    expect(body.positions[0]!.autoCover).toBe(true);
  });

  it("/v1/vault/equity: share price, supply-weighted APY and the queue head", async () => {
    const v = (await (await mk().request("/v1/vault/equity")).json()) as J;
    expect(v.sharePrice).toBe("1.05");
    expect(v.queue.head).toEqual([
      { requestId: "7", owner: BEN, shares: "5000000" },
    ]);
    expect(BigInt(v.apy.raw)).toBeGreaterThan(0n);
    expect((await mk().request("/v1/vault/nav")).status).toBe(404);
    expect((await mk().request("/v1/vault/other")).status).toBe(400);
  });
});

describe("chain helpers mirror MarketLib", () => {
  it("collateralValue floors; maxLtvEff takes the larger active haircut", () => {
    expect(collateralValue(500n * WAD, wad("180"), 18, 6)).toBe(
      90_000_000_000n,
    );
    expect(collateralValue(1n, wad("180"), 18, 6)).toBe(0n);
    const now = 1000n;
    expect(
      maxLtvEff(
        wad("0.75"),
        now,
        { haircut: wad("0.05"), haircutUntil: 2000 },
        { haircut: wad("0.1"), haircutUntil: 999 },
      ),
    ).toBe(wad("0.7"));
    expect(
      maxLtvEff(
        wad("0.75"),
        now,
        { haircut: wad("0.05"), haircutUntil: 2000 },
        { haircut: wad("0.1"), haircutUntil: 2000 },
      ),
    ).toBe(wad("0.65"));
  });
});

describe("ERC-8056 multiplier in the API (ADR-0119; S5 Amendment 1 point 5)", () => {
  // the market values collateral per token: share price × the oracle's cached sharesPerToken (= valuationPrice)
  const withMultiplier = (sharePriceWad: bigint, m: bigint): ChainReader => {
    const base = fakeChain();
    return {
      ...base,
      async risk() {
        return {
          ...ctx,
          valuationPrice: (sharePriceWad * m) / WAD,
          multiplier: {
            sharesPerToken: m,
            live: m,
            next: 0n,
            effectiveAt: 0,
            corporateAction: false,
          },
        };
      },
    };
  };
  type Live = {
    collateralValue: { raw: string; formatted: string };
    loanSymbol: string;
    multiplier: {
      sharesPerToken: string;
      sharePrice: string;
      tokenPrice: string;
    };
  };
  const live = async (chain: ChainReader) =>
    (
      (await (
        await mk({ chain }).request(`/v1/positions/${PRIYA}`)
      ).json()) as { positions: { live: Live }[] }
    ).positions[0]!.live;

  it("a 2:1 split: share price halves, 2 shares per token, the position's value is unchanged", async () => {
    const l = await live(withMultiplier(wad("90"), 2n * WAD));
    expect(l.multiplier.sharesPerToken).toBe((2n * WAD).toString());
    expect(l.multiplier.sharePrice).toBe(wad("90").toString());
    expect(l.multiplier.tokenPrice).toBe(wad("180").toString());
    expect(l.collateralValue.formatted).toBe("90000"); // 500 tokens × $180
    expect(l.loanSymbol).toBe("tUSDG");
  });
  it("a 1:3 reverse split: a third of a share per token at 3× the share price", async () => {
    const l = await live(withMultiplier(wad("540"), WAD / 3n));
    expect(l.multiplier.sharePrice).toBe(wad("540").toString());
    // 540 × 0.333… = 179.99…: rounded down, never above the market's own valuation
    expect(BigInt(l.multiplier.tokenPrice)).toBeLessThanOrEqual(wad("180"));
    expect(Number(l.collateralValue.formatted)).toBeCloseTo(90_000, 0);
  });
  it("a 1 % dividend step: the same share price is worth 1 % more per token", async () => {
    const l = await live(withMultiplier(wad("180"), (WAD * 101n) / 100n));
    expect(l.multiplier.tokenPrice).toBe(wad("181.8").toString());
    expect(l.collateralValue.formatted).toBe("90900");
  });
  it("a deployment before ABIs v4 shows no multiplier", async () => {
    const base = fakeChain();
    const l = await live({
      ...base,
      async risk() {
        return { ...ctx, multiplier: null };
      },
    });
    expect(l.multiplier).toBeNull();
  });
});
