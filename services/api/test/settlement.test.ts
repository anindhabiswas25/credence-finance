// NAV settlements (S4 D) over in-memory settlement tables: /v1/settlements, /v1/settlements/:id and the NAV
// pool's redemption claims at cost in /v1/pool/nav.
import { describe, expect, it } from "vitest";
import { keccak256, stringToHex, type Address, type Hex } from "viem";
import { createApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { memoryRepos } from "../src/repo.ts";
import { memRiskTransferRepo } from "../src/rt.ts";
import { memSettlementRepo, type SettlementRow } from "../src/settlement.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type J = any;
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
const NAV_POOL = "0x00000000000000000000000000000000000000ee" as Address;
const TBILL = keccak256(stringToHex("market:TBILL")) as Hex;
const OTHER = keccak256(stringToHex("market:OTHER")) as Hex;
const SOLVER = "0x00000000000000000000000000000000000000a1" as Address;
const FUND = "0x00000000000000000000000000000000000000f1" as Address;
const WAD = 10n ** 18n;

const row = (id: bigint, over: Partial<SettlementRow> = {}): SettlementRow => ({
  settlementId: id,
  adapter: "0x00000000000000000000000000000000000000ad",
  marketId: TBILL,
  venue: "0x00000000000000000000000000000000000000ab",
  qty: 10_000n * WAD,
  floorPrice: (995n * WAD) / 1000n,
  endsAt: 2_000n,
  status: "open",
  bids: 0,
  bestPrice: null,
  bestSolver: null,
  solver: null,
  price: null,
  proceeds: null,
  requestId: null,
  positionsSettled: null,
  openedAt: 1_100n,
  finalizedAt: null,
  ...over,
});

function app() {
  const repos = memoryRepos({});
  const rt = memRiskTransferRepo({
    pools: [
      {
        stack: "nav",
        pool: NAV_POOL,
        venue: null,
        activeEpoch: null,
        lastSettledEpoch: null,
        navAfterLastSettlement: null,
        sharePrice: null,
        premiumsWritten: 0n,
        lossesPaid: 0n,
        riskFees: 0n,
        penalties: 0n,
        bonds: 0n,
        updatedBlock: 1n,
      },
    ],
  });
  const settlement = memSettlementRepo({
    settlements: [
      row(1n, {
        status: "filled",
        bids: 2,
        bestPrice: 996_000_000_000_000_000n,
        bestSolver: SOLVER,
        solver: SOLVER,
        price: 996_000_000_000_000_000n,
        proceeds: 9_960_000_000n,
        positionsSettled: 3,
        finalizedAt: 2_001n,
      }),
      row(2n, {
        status: "advanced",
        price: (995n * WAD) / 1000n,
        proceeds: 9_950_000_000n,
        requestId: 7n,
        positionsSettled: 1,
        finalizedAt: 2_002n,
      }),
      row(3n),
      row(4n, { marketId: OTHER }),
    ],
    bids: {
      "1": [
        {
          solver: "0x00000000000000000000000000000000000000a2",
          price: 995_000_000_000_000_000n,
          block: 10n,
          ts: 1_200n,
        },
        {
          solver: SOLVER,
          price: 996_000_000_000_000_000n,
          block: 11n,
          ts: 1_300n,
        },
      ],
    },
    claims: [
      {
        requestId: 7n,
        pool: NAV_POOL,
        epochId: 5n,
        marketId: TBILL,
        fund: FUND,
        qty: 10_000n * WAD,
        cost: 9_950_000_000n,
        status: "outstanding",
        assets: null,
        pnl: null,
        requestedAt: 2_002n,
        claimedAt: null,
      },
      {
        requestId: 6n,
        pool: NAV_POOL,
        epochId: 4n,
        marketId: TBILL,
        fund: FUND,
        qty: 1_000n * WAD,
        cost: 995_000_000n,
        status: "claimed",
        assets: 1_000_000_000n,
        pnl: 5_000_000n,
        requestedAt: 900n,
        claimedAt: 1_000n,
      },
    ],
  });
  return createApp({
    config,
    clock: repos.clock,
    auth: repos.auth,
    core: repos.core,
    rt,
    settlement,
    now: () => 1_500_000,
  });
}

describe("S4 settlement routes", () => {
  it("GET /v1/settlements lists newest first and filters by market and status", async () => {
    const a = app();
    const all: J = await (await a.request("/v1/settlements")).json();
    expect(all.items.map((x: J) => x.settlementId)).toEqual([
      "4",
      "3",
      "2",
      "1",
    ]);
    const tb: J = await (
      await a.request(`/v1/settlements?market=${TBILL}&status=open`)
    ).json();
    expect(tb.items.map((x: J) => x.settlementId)).toEqual(["3"]);
    expect(tb.items[0].secondsLeft).toBe(500); // endsAt 2,000 − now 1,500
    const page: J = await (await a.request("/v1/settlements?limit=2")).json();
    expect(page.nextCursor).toBe("3");
    const next: J = await (
      await a.request(`/v1/settlements?limit=2&cursor=${page.nextCursor}`)
    ).json();
    expect(next.items.map((x: J) => x.settlementId)).toEqual(["2", "1"]);
    expect((await a.request("/v1/settlements?status=done")).status).toBe(400);
  });

  it("GET /v1/settlements/:id: a solver fill with its bids, a pool advance with its redemption", async () => {
    const a = app();
    const f: J = await (await a.request("/v1/settlements/1")).json();
    expect(f.outcome).toEqual({
      kind: "solver_fill",
      solver: SOLVER,
      price: "996000000000000000",
      proceeds: { raw: "9960000000", formatted: "9960" },
      redemptionRequestId: null,
      positionsSettled: 3,
    });
    expect(f.bidList.map((x: J) => x.price)).toEqual([
      "995000000000000000",
      "996000000000000000",
    ]);
    const adv: J = await (await a.request("/v1/settlements/2")).json();
    expect(adv.outcome.kind).toBe("pool_advance");
    expect(adv.outcome.redemptionRequestId).toBe("7");
    expect((await a.request("/v1/settlements/99")).status).toBe(404);
  });

  it("GET /v1/pool/nav includes outstanding redemption claims at cost (§8.6.1)", async () => {
    const b: J = await (await app().request("/v1/pool/nav")).json();
    expect(b.redemptionClaims.outstandingAtCost).toEqual({
      raw: "9950000000",
      formatted: "9950",
    });
    expect(b.redemptionClaims.outstanding).toBe(1);
    expect(b.redemptionClaims.items.map((x: J) => x.status)).toEqual([
      "outstanding",
      "claimed",
    ]);
  });

  it("the OpenAPI document lists the settlement routes", async () => {
    const doc: J = await (await app().request("/v1/openapi.json")).json();
    expect(Object.keys(doc.paths)).toEqual(
      expect.arrayContaining(["/v1/settlements", "/v1/settlements/{id}"]),
    );
  });
});
