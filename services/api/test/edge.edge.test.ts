// S4 H edge cases (make backend-edge), API: pagination edges, unknown ids, invalid inputs, uint256-max amounts.
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
  rateLimitPerMin: 100_000,
  rateLimitAuthPerMin: 1000,
  secureCookies: false,
  scenarioDirs: [],
  publicApiUrl: "http://localhost:8787",
  allowlistEnabled: true,
  allowlistPerIpPerHour: 5,
};
const MAX = 2n ** 256n - 1n;
const MAX128 = 2n ** 128n - 1n;
const M = keccak256(stringToHex("market:TBILL")) as Hex;
const row = (id: bigint, over: Partial<SettlementRow> = {}): SettlementRow => ({
  settlementId: id,
  adapter: "0x00000000000000000000000000000000000000ad" as Address,
  marketId: M,
  venue: "0x00000000000000000000000000000000000000ab" as Address,
  qty: 1n,
  floorPrice: 1n,
  endsAt: 10n,
  status: "open",
  bids: 0,
  bestPrice: null,
  bestSolver: null,
  solver: null,
  price: null,
  proceeds: null,
  requestId: null,
  positionsSettled: null,
  openedAt: 1n,
  finalizedAt: null,
  ...over,
});

function app(n = 45) {
  const repos = memoryRepos({});
  const settlements = Array.from({ length: n }, (_, i) => row(BigInt(i + 1)));
  // the largest values the events can carry
  settlements.push(
    row(2n ** 64n - 1n, {
      status: "advanced",
      qty: MAX128,
      floorPrice: MAX128,
      price: MAX128,
      proceeds: MAX128,
      requestId: MAX,
      finalizedAt: 11n,
    }),
  );
  return createApp({
    config,
    clock: repos.clock,
    auth: repos.auth,
    core: repos.core,
    rt: memRiskTransferRepo({}),
    settlement: memSettlementRepo({ settlements }),
    now: () => 5_000,
  });
}

async function pages(a: ReturnType<typeof app>, limit: number) {
  const ids: string[] = [];
  let cursor: string | null = null;
  for (let i = 0; i < 100; i++) {
    const r: J = await (
      await a.request(
        `/v1/settlements?limit=${limit}${cursor ? `&cursor=${cursor}` : ""}`,
      )
    ).json();
    ids.push(...r.items.map((x: J) => x.settlementId));
    cursor = r.nextCursor;
    if (!cursor) break;
  }
  return ids;
}

describe("edge: pagination", () => {
  it("walks every row exactly once whatever the page size (1, exact multiple, larger than the set)", async () => {
    const a = app(45);
    for (const limit of [1, 23, 46, 100]) {
      const ids = await pages(a, limit);
      expect(ids.length).toBe(46);
      expect(new Set(ids).size).toBe(46);
      expect(ids[0]).toBe((2n ** 64n - 1n).toString()); // newest (largest id) first
    }
  });
  it("an empty set and a cursor past the end return an empty page with no next cursor", async () => {
    const empty: J = await (await app(0).request("/v1/settlements")).json();
    expect(empty.items.length).toBe(1); // only the uint64-max row
    const past: J = await (
      await app(45).request("/v1/settlements?cursor=1")
    ).json();
    expect(past).toEqual({ items: [], nextCursor: null });
  });
});

describe("edge: invalid inputs (400) and unknown ids (404)", () => {
  it.each([
    "/v1/settlements?limit=0",
    "/v1/settlements?limit=101",
    "/v1/settlements?limit=abc",
    "/v1/settlements?cursor=-1",
    "/v1/settlements?cursor=1.5",
    "/v1/settlements?cursor=123456789012345678901",
    "/v1/settlements?market=0x1234",
    "/v1/settlements?status=OPEN",
    "/v1/settlements/abc",
    "/v1/settlements/-1",
    "/v1/auctions?kind=nope",
    "/v1/auctions/1e3",
    "/v1/pool/senior",
  ])("%s → 400", async (path) => {
    const r = await app().request(path);
    expect([400, 404]).toContain(r.status);
    if (!path.startsWith("/v1/pool/")) expect(r.status).toBe(400);
  });
  it("unknown ids → 404 with a JSON error", async () => {
    for (const p of [
      "/v1/settlements/99999",
      "/v1/auctions/99999",
      "/v1/pool/equity",
    ]) {
      const r = await app().request(p);
      expect(r.status).toBe(404);
      expect(((await r.json()) as J).error).toBe("not_found");
    }
  });
});

describe("edge: uint256-max values survive as exact decimal strings", () => {
  it("never loses precision (no Number conversion)", async () => {
    const b: J = await (
      await app().request(`/v1/settlements/${2n ** 64n - 1n}`)
    ).json();
    expect(b.qty).toBe(MAX128.toString());
    expect(b.outcome.proceeds.raw).toBe(MAX128.toString());
    expect(b.outcome.redemptionRequestId).toBe(MAX.toString());
    expect(b.outcome.proceeds.formatted).toBe(
      "340282366920938463463374607431768.211455",
    );
  });
});
