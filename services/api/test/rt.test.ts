// Pool, epochs, auctions and the risk page over the in-memory S3 tables (no chain reader: indexed figures
// only). The devnode e2e (make scenario-a-e2e) compares the live figures with the chain.
import { describe, expect, it } from "vitest";
import {
  getAddress,
  keccak256,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import { createApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { memoryRepos } from "../src/repo.ts";
import {
  memRiskTransferRepo,
  type AuctionRow,
  type EpochRow,
} from "../src/rt.ts";

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
const POOL = "0x00000000000000000000000000000000000000cc" as Address;
const NVDA = keccak256(stringToHex("NVDA:XNAS"));
const MID = keccak256(stringToHex("market:NVDA")) as Hex;
const PRIYA = getAddress("0x00000000000000000000000000000000000000b1");

const epoch = (id: bigint, over: Partial<EpochRow> = {}): EpochRow => ({
  epochId: id,
  status: "settled",
  bellWindowAt: 1n,
  bellAt: 2n,
  closeAt: 3n,
  reopenAt: 4n,
  navBefore: 1_000_000_000_000n,
  equityAtRisk: 900_000_000_000n,
  worstLoss: 40_000_000_000n,
  premiums: 297_420_000n,
  policies: 3,
  riskFees: 1_000_000n,
  penalties: 270_570_000n,
  bonds: 86_000_000n,
  backstopPnl: -5_000_000n,
  lossesPaid: 672_590_000n,
  pendingLossReserve: 0n,
  navAfter: 999_882_300_000n,
  sharePriceAfter: 999_882_300_000_000_000n,
  sharesBurned: 0n,
  sharesMinted: 0n,
  settledAt: 5n,
  ...over,
});
const auctionRow = (
  id: bigint,
  over: Partial<AuctionRow> = {},
): AuctionRow => ({
  auctionId: id,
  house: "0x00000000000000000000000000000000000000dd",
  kind: 0,
  marketId: MID,
  assetId: NVDA,
  closureId: 7n,
  venueEpoch: 41n,
  tranche: 0,
  deadlines: [120, 120, 300, 420],
  status: "settled",
  lot: 59_080_000_000_000_000_000n,
  reserve: 151_339_400_000_000_000_000n,
  positions: 1,
  bids: 3,
  pStar: 156_020_000_000_000_000_000n,
  filled: 59_080_000_000_000_000_000n,
  qPool: 0n,
  proceeds: 9_217_661_600n,
  blendedPrice: 156_020_000_000_000_000_000n,
  bondsForfeited: 86_000_000n,
  createdAt: 100n,
  clearedAt: 520n,
  openPrint: 160_000_000_000_000_000_000n,
  ...over,
});

function app() {
  const repos = memoryRepos({});
  const rt = memRiskTransferRepo({
    pools: [
      {
        stack: "equity",
        pool: POOL,
        venue: null,
        activeEpoch: null,
        lastSettledEpoch: 42n,
        navAfterLastSettlement: 999_882_300_000n,
        sharePrice: 999_882_300_000_000_000n,
        premiumsWritten: 297_420_000n,
        lossesPaid: 672_590_000n,
        riskFees: 1_000_000n,
        penalties: 270_570_000n,
        bonds: 86_000_000n,
        updatedBlock: 9n,
      },
    ],
    epochs: { [POOL]: [epoch(40n), epoch(41n), epoch(42n)] },
    auctions: [
      auctionRow(1n),
      auctionRow(2n, {
        kind: 1,
        status: "queue",
        pStar: null,
        openPrint: null,
      }),
    ],
    lots: {
      "1": [
        {
          owner: PRIYA,
          qty: 59_080_000_000_000_000_000n,
          collateralSold: 59_080_000_000_000_000_000n,
          proceeds: 9_217_661_600n,
          penalty: 460_883_080n,
          shortfall: 0n,
          refund: 0n,
          debtAfter: 4_578_380_000n,
          paidByPool: null,
          paidByReserve: null,
          seniorLoss: null,
        },
      ],
    },
    marketRisk: [
      {
        marketId: MID,
        premiums: 297_420_000n,
        policies: 3,
        lossPool: 672_590_000n,
        lossReserve: 0n,
        lossSenior: 0n,
      },
    ],
  });
  return createApp({
    config,
    clock: repos.clock,
    auth: repos.auth,
    core: repos.core,
    rt,
  });
}

describe("S3 routes", () => {
  it("GET /v1/pool/:stack serves the indexed pool (live figures null without a chain reader)", async () => {
    const r = await app().request("/v1/pool/equity");
    expect(r.status).toBe(200);
    const b: J = await r.json();
    expect(b.lastSettled).toEqual({
      epochId: "42",
      navAfter: { raw: "999882300000", formatted: "999882.3" },
      sharePrice: "999882300000000000",
    });
    expect(b.allTime.lossesPaid.formatted).toBe("672.59");
    expect(b.nav).toBeNull();
    expect((await app().request("/v1/pool/nav")).status).toBe(404);
    expect((await app().request("/v1/pool/other")).status).toBe(400);
  });
  it("GET /v1/pool/:stack/epochs pages newest first with the P&L breakdown", async () => {
    const b: J = await (
      await app().request("/v1/pool/equity/epochs?limit=2")
    ).json();
    expect(b.items.map((e: J) => e.epochId)).toEqual(["42", "41"]);
    expect(b.nextCursor).toBe("41");
    expect(b.items[0].pnl.backstopPnl.formatted).toBe("-5");
    const next: J = await (
      await app().request(
        `/v1/pool/equity/epochs?limit=2&cursor=${b.nextCursor}`,
      )
    ).json();
    expect(next.items.map((e: J) => e.epochId)).toEqual(["40"]);
    expect(next.nextCursor).toBeNull();
    expect(
      (await app().request("/v1/pool/equity/epochs?cursor=abc")).status,
    ).toBe(400);
  });
  it("GET /v1/auctions filters by status, kind and asset", async () => {
    const all: J = await (await app().request("/v1/auctions")).json();
    expect(all.items.map((a: J) => a.auctionId)).toEqual(["2", "1"]);
    const reopen: J = await (
      await app().request("/v1/auctions?kind=REOPEN")
    ).json();
    expect(reopen.items.map((a: J) => a.auctionId)).toEqual(["1"]);
    const q: J = await (
      await app().request("/v1/auctions?status=queue")
    ).json();
    expect(q.items.map((a: J) => a.auctionId)).toEqual(["2"]);
    expect((await app().request(`/v1/auctions?asset=${NVDA}`)).status).toBe(
      200,
    );
    expect((await app().request("/v1/auctions?kind=SOMETHING")).status).toBe(
      400,
    );
  });
  it("GET /v1/auctions/:id: deadlines, clearing vs open print, per-position settlement", async () => {
    const b: J = await (await app().request("/v1/auctions/1")).json();
    expect(b.deadlines).toEqual({
      lotFixAt: 120,
      biddingStartAt: 120,
      biddingEndAt: 300,
      clearAt: 420,
    });
    expect(b.clearing.pStarVsOpenPrint.percent).toBe("-2.4875");
    expect(b.settlement[0]).toMatchObject({
      owner: PRIYA,
      penalty: { formatted: "460.88308" },
      debtAfter: { formatted: "4578.38" },
      settled: true,
      losses: null,
    });
    expect((await app().request("/v1/auctions/99")).status).toBe(404);
  });
  it("GET /v1/risk: premiums and losses by layer per market, pools, auctions with p* vs open print", async () => {
    const b: J = await (await app().request("/v1/risk")).json();
    expect(b.markets[0]).toMatchObject({
      marketId: MID,
      premiumsCollected: { formatted: "297.42" },
      lossesByLayer: { pool: { formatted: "672.59" } },
    });
    expect(b.pools[0].size.formatted).toBe("999882.3");
    expect(b.auctions).toHaveLength(1);
    expect(b.auctions[0].openPrint).toBe("160000000000000000000");
  });
  it("is in the OpenAPI document", async () => {
    const doc: J = await (await app().request("/v1/openapi.json")).json();
    for (const p of [
      "/v1/pool/{stack}",
      "/v1/pool/{stack}/epochs",
      "/v1/auctions",
      "/v1/auctions/{auctionId}",
      "/v1/risk",
    ])
      expect(doc.paths[p]).toBeDefined();
  });
});
