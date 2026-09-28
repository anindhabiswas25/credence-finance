import { describe, expect, it } from "vitest";
import { keccak256, stringToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createSiweMessage } from "viem/siwe";
import { createApp, toAssetId } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { memoryRepos } from "../src/repo.ts";
import { boundariesAfter } from "../src/calendar.ts";

const NVDA = keccak256(stringToHex("NVDA:XNAS"));
const T0 = 1_791_380_000; // 2026-10-07 13:33:20Z

const config: Config = {
  port: 0,
  databaseUrl: "unused",
  indexerSchema: "indexer",
  corsOrigins: ["https://testnet.credence.finance"],
  siweDomain: "testnet.credence.finance",
  chainId: 412346,
  sessionSecret: "x".repeat(40),
  sessionTtlS: 3600,
  rateLimitPerMin: 1000,
  rateLimitAuthPerMin: 1000,
  secureCookies: true,
};

function app(overrides: Partial<Config> = {}, nowMs = T0 * 1000) {
  const repos = memoryRepos({
    clocks: [
      {
        assetId: NVDA,
        state: 0,
        closureId: 7n,
        closureType: 2,
        venueEpoch: 41n,
        refPrice: 180_000_000_000_000_000_000n,
        closeAt: 1_791_144_000n,
        reopenAt: 1_791_379_800n,
        openPrint: 181_500_000_000_000_000_000n,
        openPrintAt: 1_791_379_805n,
        openPrintFallback: false,
        updatedBlock: 1234n,
        updatedAt: 1_791_379_805n,
      },
    ],
    transitions: { [NVDA]: [{ from: 3, to: 0, closureId: 7n, ts: 1_791_380_100n, block: 1300n }] },
    prices: {
      [NVDA]: [
        { feed: "A", seq: 99n, kind: 0, price: 181_750_000_000_000_000_000n, observedAt: BigInt(T0 - 5), block: 1400n },
        { feed: "B", seq: 51n, kind: 0, price: 181_760_000_000_000_000_000n, observedAt: BigInt(T0 - 90), block: 1390n },
      ],
    },
  });
  return createApp({ config: { ...config, ...overrides }, clock: repos.clock, auth: repos.auth, now: () => nowMs, nextBoundaries: () => [{ at: T0 + 60, kind: "bell" }] });
}

describe("health and OpenAPI", () => {
  it("serves /healthz and /readyz", async () => {
    const a = app();
    expect((await a.request("/healthz")).status).toBe(200);
    expect((await a.request("/readyz")).status).toBe(200);
  });
  it("publishes an OpenAPI 3.1 document with every route", async () => {
    const r = await app().request("/v1/openapi.json");
    expect(r.status).toBe(200);
    const doc = (await r.json()) as { openapi: string; paths: Record<string, unknown> };
    expect(doc.openapi).toBe("3.1.0");
    expect(Object.keys(doc.paths)).toEqual(
      expect.arrayContaining(["/v1/clock/{assetId}", "/v1/auth/siwe/nonce", "/v1/auth/siwe/verify", "/v1/auth/session", "/v1/auth/logout"]),
    );
  });
});

describe("GET /metrics", () => {
  it("counts requests by route pattern and status, with one label for unmatched paths", async () => {
    const a = app();
    await a.request("/healthz");
    await a.request(`/v1/clock/${NVDA}`);
    await a.request("/v1/clock/nope!");
    await a.request("/wp-admin/xyz");
    const body = await (await a.request("/metrics")).text();
    expect(body).toMatch(/credence_api_http_requests_total\{method="GET",route="\/healthz",status="200"\} 1/);
    expect(body).toMatch(/credence_api_http_request_duration_seconds_count\{method="GET",route="\/v1\/clock\/:assetId",status="200"\} 1/);
    expect(body).toMatch(/route="\/v1\/clock\/:assetId",status="400"/);
    expect(body).toMatch(/route="unmatched",status="404"/);
    expect(body).not.toMatch(/wp-admin/);
  });
});

describe("GET /v1/clock/:assetId", () => {
  it("accepts TICKER:MIC and bytes32 ids", () => {
    expect(toAssetId("nvda:xnas")).toBe(NVDA);
    expect(toAssetId(NVDA.toUpperCase().replace("0X", "0x"))).toBe(NVDA);
    expect(toAssetId("DROP TABLE")).toBeUndefined();
  });

  it("returns state, closure, transitions, feeds and next boundaries", async () => {
    const r = await app().request("/v1/clock/NVDA:XNAS");
    expect(r.status).toBe(200);
    type Named = { name: string };
    const b = (await r.json()) as {
      assetId: string;
      state: unknown;
      closureType: unknown;
      refPrice: unknown;
      openPrint: { formatted: string };
      transitions: { from: Named; to: Named }[];
      feeds: unknown[];
      next: unknown;
    };
    expect(b.assetId).toBe(NVDA);
    expect(b.state).toEqual({ code: 0, name: "REGULAR" });
    expect(b.closureType).toEqual({ code: 2, name: "WEEKEND" });
    expect(b.refPrice).toEqual({ raw: "180000000000000000000", formatted: "180" });
    expect(b.openPrint.formatted).toBe("181.5");
    expect(b.transitions[0]).toMatchObject({ from: { name: "REOPEN" }, to: { name: "REGULAR" } });
    expect(b.feeds).toEqual([
      expect.objectContaining({ feed: "A", seq: "99", ageSeconds: 5, stale: false }),
      expect.objectContaining({ feed: "B", ageSeconds: 90, stale: true }),
    ]);
    expect(b.next).toEqual([{ at: T0 + 60, kind: "bell" }]);
  });

  it("404 when not indexed, 400 on a bad id", async () => {
    expect((await app().request("/v1/clock/AAPL:XNAS")).status).toBe(404);
    const bad = await app().request("/v1/clock/not-an-asset");
    expect(bad.status).toBe(400);
  });
});

describe("SIWE sessions", () => {
  const account = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

  async function signIn(a: ReturnType<typeof app>, opts: { domain?: string; chainId?: number; reuse?: string } = {}) {
    const { nonce } = (await (await a.request("/v1/auth/siwe/nonce", { method: "POST" })).json()) as { nonce: string };
    const message = createSiweMessage({
      address: account.address,
      chainId: opts.chainId ?? 412346,
      domain: opts.domain ?? "testnet.credence.finance",
      nonce: opts.reuse ?? nonce,
      uri: "https://testnet.credence.finance",
      version: "1",
      issuedAt: new Date(T0 * 1000),
    });
    const signature = await account.signMessage({ message });
    const r = await a.request("/v1/auth/siwe/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message, signature }),
    });
    return { r, nonce, message, signature };
  }

  it("signs in with an httpOnly, Secure, SameSite=Lax cookie and reads the session back", async () => {
    const a = app();
    const { r } = await signIn(a);
    expect(r.status).toBe(200);
    const cookie = r.headers.get("set-cookie")!;
    expect(cookie).toMatch(/credence_session=/);
    expect(cookie).toMatch(/HttpOnly/);
    expect(cookie).toMatch(/Secure/);
    expect(cookie).toMatch(/SameSite=Lax/);
    const s = await a.request("/v1/auth/session", { headers: { cookie: cookie.split(";")[0]! } });
    expect(s.status).toBe(200);
    expect(((await s.json()) as { address: string }).address).toBe(account.address);
    // logout ends it
    const out = await a.request("/v1/auth/logout", { method: "POST", headers: { cookie: cookie.split(";")[0]! } });
    expect(out.status).toBe(204);
    expect((await a.request("/v1/auth/session", { headers: { cookie: cookie.split(";")[0]! } })).status).toBe(401);
  });

  it("rejects a reused nonce, a wrong domain, a wrong chain and a forged cookie", async () => {
    const a = app();
    const first = await signIn(a);
    expect(first.r.status).toBe(200);
    const replay = await a.request("/v1/auth/siwe/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message: first.message, signature: first.signature }),
    });
    expect(replay.status).toBe(401);
    expect((await signIn(a, { domain: "evil.example" })).r.status).toBe(401);
    expect((await signIn(a, { chainId: 1 })).r.status).toBe(401);
    const forged = await a.request("/v1/auth/session", { headers: { cookie: "credence_session=00000000-0000-0000-0000-000000000000.AAAA" } });
    expect(forged.status).toBe(401);
  });

  it("rejects a signature from another key", async () => {
    const a = app();
    const { nonce } = (await (await a.request("/v1/auth/siwe/nonce", { method: "POST" })).json()) as { nonce: string };
    const message = createSiweMessage({
      address: account.address,
      chainId: 412346,
      domain: "testnet.credence.finance",
      nonce,
      uri: "https://testnet.credence.finance",
      version: "1",
    });
    const other = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
    const r = await a.request("/v1/auth/siwe/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message, signature: await other.signMessage({ message }) }),
    });
    expect(r.status).toBe(401);
  });

  it("validates the body with zod", async () => {
    const r = await app().request("/v1/auth/siwe/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message: "hi", signature: "not-hex" }),
    });
    expect(r.status).toBe(400);
  });
});

describe("CORS and rate limits", () => {
  it("allows only the configured origin, with credentials", async () => {
    const ok = await app().request("/v1/clock/NVDA:XNAS", { headers: { origin: "https://testnet.credence.finance" } });
    expect(ok.headers.get("access-control-allow-origin")).toBe("https://testnet.credence.finance");
    expect(ok.headers.get("access-control-allow-credentials")).toBe("true");
    const bad = await app().request("/v1/clock/NVDA:XNAS", { headers: { origin: "https://evil.example" } });
    expect(bad.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("returns 429 past the per-IP limit", async () => {
    const a = app({ rateLimitPerMin: 3 });
    const hit = () => a.request("/v1/clock/NVDA:XNAS", { headers: { "x-forwarded-for": "203.0.113.9" } });
    for (let i = 0; i < 3; i++) expect((await hit()).status).toBe(200);
    const r = await hit();
    expect(r.status).toBe(429);
    expect(r.headers.get("retry-after")).toBeTruthy();
    // another client is unaffected
    expect((await a.request("/v1/clock/NVDA:XNAS", { headers: { "x-forwarded-for": "198.51.100.1" } })).status).toBe(200);
  });
});

describe("calendar boundaries", () => {
  it("lists the next boundaries in order, deduplicated", () => {
    const open = 1_791_379_800;
    const s = [{ extOpen: open - 48_600, open, close: open + 23_400, extClose: open + 37_800, closureTypeAfter: 1 as const }];
    const b = boundariesAfter(s, open + 1);
    expect(b.map((x) => x.kind)).toEqual(["bellWindow", "bell", "close", "extClose"]);
  });
});
