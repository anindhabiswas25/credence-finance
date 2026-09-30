// ADR-0014 (S5 Amendment 1): one API for both chains. `?chain=` picks the chain's app; a chain-bound body carries
// `chainId`; the same wallet (even the same market id) on two chains stays two positions; one rate-limit quota.
import { describe, expect, it } from "vitest";
import { getAddress, type Address, type Hex } from "viem";
import { createApp, newLimiters } from "../src/app.ts";
import { forChain, parseChains, type Config } from "../src/config.ts";
import { createMultiChainApp, isChainAgnostic } from "../src/multichain.ts";
import { memoryRepos, type MarketRow, type PositionRow } from "../src/repo.ts";
import type { ChainReader, RiskContext } from "../src/chain.ts";

const base: Config = {
  port: 0,
  databaseUrl: "unused",
  indexerSchema: "ix_46630",
  corsOrigins: [],
  siweDomain: "testnet.credence.finance",
  chainId: 46630,
  sessionSecret: "x".repeat(40),
  sessionTtlS: 3600,
  rateLimitPerMin: 5,
  rateLimitAuthPerMin: 100,
  secureCookies: false,
  scenarioDirs: [],
  publicApiUrl: "https://api.test",
  allowlistEnabled: true,
  allowlistPerIpPerHour: 5,
  chains: parseChains("46630:ix_46630,421614:ix_421614"),
  siweChainIds: [46630, 421614],
  allowlistChains: [46630, 421614],
};
const OWNER = getAddress("0x00000000000000000000000000000000000000b1");
const MID = `0x${"ab".repeat(32)}` as Hex;
const pos = (collateral: bigint): PositionRow => ({
  marketId: MID,
  owner: OWNER as Address,
  collateral,
  borrowShares: 1n,
  debtSnapshot: 1n,
  coverClosureId: 0n,
  lastBellClosureId: 0n,
  auctionId: 0n,
  autoCoverOptOut: false,
  updatedBlock: 7n,
  updatedAt: 1n,
});

function twoChains(config: Config = base) {
  const limiters = newLimiters(config);
  const shared = memoryRepos();
  const apps = [
    [46630, 100n],
    [421614, 200n],
  ].map(([id, q]) => {
    const r = memoryRepos({ positions: [pos(q as bigint)] });
    return {
      chainId: Number(id),
      app: createApp({
        config: forChain(config, Number(id)),
        clock: r.clock,
        auth: shared.auth,
        me: shared.me,
        core: r.core,
        limiters,
      }),
    };
  });
  return createMultiChainApp(apps);
}

// every request comes through our proxy with its own client address (the rate limiter keys on it)
const get = (app: ReturnType<typeof twoChains>, path: string, ip = "1.1.1.1") =>
  app.request(
    path,
    { headers: { "x-forwarded-for": ip } },
    { incoming: { socket: { remoteAddress: "10.0.0.1" } } },
  );

describe("API_CHAINS", () => {
  it("parses chainId:schema pairs and refuses duplicates and bad schemas", () => {
    expect(parseChains("46630:ix_46630, 421614")).toEqual([
      { chainId: 46630, indexerSchema: "ix_46630" },
      { chainId: 421614, indexerSchema: "ix_421614" },
    ]);
    expect(() => parseChains("46630,46630")).toThrow(/duplicate/);
    expect(() => parseChains("46630:ix-1")).toThrow(/bad schema/);
    expect(forChain(base, 421614).indexerSchema).toBe("ix_421614");
    expect(() => forChain(base, 1)).toThrow(/not served/);
  });
  it("classifies routes", () => {
    for (const p of [
      "/healthz",
      "/v1/auth/siwe/nonce",
      "/v1/me/notifications",
      "/v1/testnet/allowlist",
    ])
      expect(isChainAgnostic(p)).toBe(true);
    for (const p of [
      "/v1/markets",
      "/v1/positions/0x1",
      "/v1/clock/0x1",
      "/v1/stream",
    ])
      expect(isChainAgnostic(p)).toBe(false);
  });
});

describe("one API, two chains", () => {
  it("a chain-bound route needs ?chain= and names the served chains", async () => {
    const app = twoChains();
    const r = await get(app, `/v1/positions/${OWNER}`);
    expect(r.status).toBe(400);
    expect(((await r.json()) as { message: string }).message).toContain(
      "46630, 421614",
    );
    const u = await get(app, `/v1/positions/${OWNER}?chain=1`);
    expect(u.status).toBe(400);
  });

  it("the same wallet and market id on both chains are two separate positions", async () => {
    const app = twoChains();
    const a = (await (
      await get(app, `/v1/positions/${OWNER}?chain=46630`)
    ).json()) as { chainId: number; positions: { collateral: string }[] };
    const b = (await (
      await get(app, `/v1/positions/${OWNER}?chain=421614`)
    ).json()) as { chainId: number; positions: { collateral: string }[] };
    expect(a.chainId).toBe(46630);
    expect(a.positions.map((p) => p.collateral)).toEqual(["100"]);
    expect(b.chainId).toBe(421614);
    expect(b.positions.map((p) => p.collateral)).toEqual(["200"]);
  });

  it("chain-agnostic routes need no chain", async () => {
    const app = twoChains();
    expect((await get(app, "/healthz")).status).toBe(200);
    const n = await app.request("/v1/auth/siwe/nonce", { method: "POST" });
    expect(n.status).toBe(200);
    expect(await n.json()).toHaveProperty("nonce"); // its own SIWE chainId: the default chain's
  });

  it("one rate-limit quota across chains (alternating chains doesn't double it)", async () => {
    const app = twoChains({ ...base, trustedProxies: ["10.0.0.1"] });
    const codes: number[] = [];
    for (let i = 0; i < 8; i++)
      codes.push(
        (
          await get(
            app,
            `/v1/positions/${OWNER}?chain=${i % 2 ? 421614 : 46630}`,
            "7.7.7.7",
          )
        ).status,
      );
    expect(codes.filter((c) => c === 200)).toHaveLength(5); // RATE_LIMIT_PER_MIN = 5
    expect(codes.slice(5)).toEqual([429, 429, 429]);
  });

  it("with one chain, chain is optional and the body still carries chainId", async () => {
    const one: Config = { ...base, chains: parseChains("412346:indexer") };
    const r = memoryRepos({ positions: [pos(5n)] });
    const app = createMultiChainApp([
      {
        chainId: 412346,
        app: createApp({
          config: forChain(one, 412346),
          clock: r.clock,
          auth: r.auth,
          core: r.core,
        }),
      },
    ]);
    const body = (await (
      await app.request(`/v1/positions/${OWNER}`)
    ).json()) as { chainId: number };
    expect(body.chainId).toBe(412346);
  });

  it("one chain's RPC down: its positions still answer from the indexer, the other chain's live reads go on", async () => {
    const market = {
      marketId: MID,
      marketAddress: OWNER,
    } as unknown as MarketRow;
    const down: ChainReader = {
      risk: async () => {
        throw new Error("HTTP request failed: ECONNREFUSED (RPC down)");
      },
      position: async () => {
        throw new Error("unreachable");
      },
      uAfter: async () => 0n,
      vault: async () => {
        throw new Error("RPC down");
      },
    };
    const up: ChainReader = {
      risk: async () =>
        ({
          block: 99n,
          loanDecimals: 6,
          loanSymbol: "USDC",
          multiplier: null,
          valuationPrice: 10n ** 18n,
          upcomingClosureId: 1n,
        }) as unknown as RiskContext,
      position: async () => ({
        collateral: 200n,
        borrowShares: 1n,
        coverClosureId: 0n,
        auctionId: 0n,
        autoCoverOptOut: false,
        debt: 5_000_000n,
        debtProjected: 5_000_000n,
        collateralValue: 9_000_000n,
        covered: false,
        ltv: 10n ** 17n,
        healthFactor: 10n ** 19n,
        borrowLimitLtv: 10n ** 17n,
      }),
      uAfter: async () => 0n,
      vault: async () => {
        throw new Error("unused");
      },
    };
    const limiters = newLimiters(base);
    const shared = memoryRepos();
    const apps = (
      [
        [46630, 100n, down],
        [421614, 200n, up],
      ] as const
    ).map(([id, q, chain]) => {
      const r = memoryRepos({ markets: [market], positions: [pos(q)] });
      return {
        chainId: id,
        app: createApp({
          config: forChain(base, id),
          clock: r.clock,
          auth: shared.auth,
          core: r.core,
          chain,
          limiters,
        }),
      };
    });
    const app = createMultiChainApp(apps);
    type Body = {
      positions: {
        collateral: string;
        live: { block: string; loanSymbol: string } | null;
      }[];
    };
    const a = (await (
      await get(app, `/v1/positions/${OWNER}?chain=46630`)
    ).json()) as Body;
    expect(a.positions[0]!.collateral).toBe("100");
    expect(a.positions[0]!.live).toBeNull(); // no live read, but the indexed row is served
    const b = (await (
      await get(app, `/v1/positions/${OWNER}?chain=421614`)
    ).json()) as Body;
    expect(b.positions[0]!.live).toMatchObject({
      block: "99",
      loanSymbol: "USDC",
    });
  });
});
