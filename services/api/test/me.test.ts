// GET/PUT /v1/me/notifications, the email verification link and POST /v1/testnet/allowlist.
import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { createSiweMessage } from "viem/siwe";
import { createApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { memoryRepos } from "../src/repo.ts";

const T0 = 1_791_380_000;
const config: Config = {
  port: 0,
  databaseUrl: "unused",
  indexerSchema: "indexer",
  corsOrigins: [],
  siweDomain: "testnet.credence.finance",
  chainId: 412346,
  sessionSecret: "x".repeat(40),
  sessionTtlS: 3600,
  rateLimitPerMin: 1000,
  rateLimitAuthPerMin: 1000,
  secureCookies: false,
  scenarioDirs: [],
  publicApiUrl: "https://api.testnet.credence.finance",
  allowlistEnabled: true,
  allowlistPerIpPerHour: 2,
};
const account = privateKeyToAccount(
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
);

function mk(overrides: Partial<Config> = {}) {
  const repos = memoryRepos();
  const app = createApp({
    config: { ...config, ...overrides },
    clock: repos.clock,
    auth: repos.auth,
    me: repos.me,
    now: () => T0 * 1000,
  });
  return { app, jobs: repos.jobs };
}

async function signIn(app: ReturnType<typeof mk>["app"]): Promise<string> {
  const { nonce } = (await (
    await app.request("/v1/auth/siwe/nonce", { method: "POST" })
  ).json()) as { nonce: string };
  const message = createSiweMessage({
    address: account.address,
    chainId: 412346,
    domain: "testnet.credence.finance",
    nonce,
    uri: "https://testnet.credence.finance",
    version: "1",
    issuedAt: new Date(T0 * 1000),
  });
  const r = await app.request("/v1/auth/siwe/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      message,
      signature: await account.signMessage({ message }),
    }),
  });
  return r.headers.get("set-cookie")!.split(";")[0]!;
}

const put = (
  app: ReturnType<typeof mk>["app"],
  cookie: string,
  body: unknown,
) =>
  app.request("/v1/me/notifications", {
    method: "PUT",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

type Settings = {
  address: string;
  email: { address: string; verified: boolean } | null;
  telegramChatId: string | null;
  push: { endpoint: string }[];
  prefs: { event: string; channel: string; enabled: boolean }[];
  testnet: { attestedAt: number | null; allowlist: { status: string } | null };
};

describe("/v1/me/notifications", () => {
  it("needs a session", async () => {
    const { app } = mk();
    expect((await app.request("/v1/me/notifications")).status).toBe(401);
    expect(
      (await put(app, "credence_session=forged", { telegramChatId: "1" }))
        .status,
    ).toBe(401);
  });

  it("defaults every event × channel to on; PUT switches single cells, sets Telegram and push", async () => {
    const { app } = mk();
    const cookie = await signIn(app);
    const s0 = (await (
      await app.request("/v1/me/notifications", { headers: { cookie } })
    ).json()) as Settings;
    expect(s0.address).toBe(account.address);
    expect(s0.prefs).toHaveLength(6);
    expect(s0.prefs.every((p) => p.enabled)).toBe(true);
    const r = await put(app, cookie, {
      telegramChatId: "123456789",
      pushSubscribe: {
        endpoint: "https://fcm.googleapis.com/fcm/send/sub-1",
        p256dh: "BPk",
        auth: "a1",
      },
      prefs: [{ event: "bell_outcome", channel: "telegram", enabled: false }],
    });
    expect(r.status).toBe(200);
    const s1 = (await r.json()) as Settings;
    expect(s1.telegramChatId).toBe("123456789");
    expect(s1.push).toEqual([
      { endpoint: "https://fcm.googleapis.com/fcm/send/sub-1" },
    ]);
    expect(
      s1.prefs.find(
        (p) => p.event === "bell_outcome" && p.channel === "telegram",
      )!.enabled,
    ).toBe(false);
    expect(s1.prefs.filter((p) => !p.enabled)).toHaveLength(1);
    const s2 = (await (
      await put(app, cookie, {
        pushUnsubscribe: "https://fcm.googleapis.com/fcm/send/sub-1",
        telegramChatId: null,
      })
    ).json()) as Settings;
    expect(s2.push).toEqual([]);
    expect(s2.telegramChatId).toBeNull();
  });

  it("a new email is unverified, queues exactly one verification mail, and the link verifies it once", async () => {
    const { app, jobs } = mk();
    const cookie = await signIn(app);
    const s = (await (
      await put(app, cookie, { email: "Priya@Example.com" })
    ).json()) as Settings;
    expect(s.email).toEqual({ address: "priya@example.com", verified: false });
    await put(app, cookie, { email: "priya@example.com" }); // unchanged: no second mail
    expect(jobs).toHaveLength(1);
    const job = jobs[0]!;
    expect(job.event).toBe("email_verify");
    const { email, link } = job.payload as { email: string; link: string };
    expect(email).toBe("priya@example.com");
    expect(
      link.startsWith(
        "https://api.testnet.credence.finance/v1/me/email/verify?token=",
      ),
    ).toBe(true);
    const path = link.replace("https://api.testnet.credence.finance", "");
    expect((await app.request(path)).status).toBe(200);
    expect((await app.request(path)).status).toBe(400); // single use
    const after = (await (
      await app.request("/v1/me/notifications", { headers: { cookie } })
    ).json()) as Settings;
    expect(after.email).toEqual({
      address: "priya@example.com",
      verified: true,
    });
  });

  it("changing the email again unverifies it and invalidates the old link", async () => {
    const { app, jobs } = mk();
    const cookie = await signIn(app);
    await put(app, cookie, { email: "a@example.com" });
    const oldPath = (jobs[0]!.payload as { link: string }).link.replace(
      "https://api.testnet.credence.finance",
      "",
    );
    await put(app, cookie, { email: "b@example.com" });
    expect((await app.request(oldPath)).status).toBe(400);
    expect(jobs).toHaveLength(2);
  });

  it("rejects unknown fields, bad events and non-https push endpoints", async () => {
    const { app } = mk();
    const cookie = await signIn(app);
    expect(
      (
        await put(app, cookie, {
          address: "0x0000000000000000000000000000000000000001",
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await put(app, cookie, {
          prefs: [{ event: "email_verify", channel: "email", enabled: false }],
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await put(app, cookie, {
          pushSubscribe: {
            endpoint: "http://push.example/x",
            p256dh: "a",
            auth: "b",
          },
        })
      ).status,
    ).toBe(400);
    // OFF-05: an https endpoint on any other host (a blind SSRF from the notifier) is refused
    for (const endpoint of [
      "https://internal.corp.example/admin",
      "https://fcm.googleapis.com.evil.example/x",
      "https://fcm.googleapis.com:8443/x",
    ])
      expect(
        (
          await put(app, cookie, {
            pushSubscribe: { endpoint, p256dh: "a", auth: "b" },
          })
        ).status,
      ).toBe(400);
  });
});

describe("POST /v1/testnet/allowlist", () => {
  const post = (
    app: ReturnType<typeof mk>["app"],
    cookie: string | undefined,
    ip = "1.2.3.4",
  ) =>
    app.request(
      "/v1/testnet/allowlist",
      {
        method: "POST",
        headers: {
          ...(cookie ? { cookie } : {}),
          "content-type": "application/json",
          "x-forwarded-for": ip,
        },
        body: JSON.stringify({ attest: true }),
      },
      // the request arrives through our proxy (OFF-03: X-Forwarded-For is trusted only from it)
      { incoming: { socket: { remoteAddress: "10.0.0.1" } } },
    );

  it("queues once per address (idempotent), records the attestation, rate-limits per IP", async () => {
    const { app } = mk({ trustedProxies: ["10.0.0.1"] });
    expect((await post(app, undefined)).status).toBe(401);
    const cookie = await signIn(app);
    const a = await post(app, cookie);
    expect(a.status).toBe(202);
    expect(await a.json()).toEqual({
      address: account.address,
      status: "pending",
      created: true,
      chains: [{ chainId: 412346, status: "pending", created: true }],
    });
    const b = await post(app, cookie);
    expect(await b.json()).toEqual({
      address: account.address,
      status: "pending",
      created: false,
      chains: [{ chainId: 412346, status: "pending", created: false }],
    });
    expect((await post(app, cookie)).status).toBe(429); // 3rd request from this IP within the hour
    expect((await post(app, cookie, "5.6.7.8")).status).toBe(202);
    const s = (await (
      await app.request("/v1/me/notifications", { headers: { cookie } })
    ).json()) as Settings;
    expect(s.testnet.attestedAt).toBe(T0);
    expect(s.testnet.allowlist).toEqual({ status: "pending", txHash: null });
  });

  it("ADR-0014: one attestation queues every served testnet chain; ?chain= picks one", async () => {
    const { app } = mk({
      trustedProxies: ["10.0.0.1"],
      allowlistPerIpPerHour: 10,
      chains: [
        { chainId: 46630, indexerSchema: "ix_46630" },
        { chainId: 421614, indexerSchema: "ix_421614" },
      ],
      siweChainIds: [412346, 46630, 421614],
      allowlistChains: [46630, 421614],
    });
    const cookie = await signIn(app);
    const one = await app.request(
      "/v1/testnet/allowlist?chain=46630",
      {
        method: "POST",
        headers: {
          cookie,
          "content-type": "application/json",
          "x-forwarded-for": "9.9.9.9",
        },
        body: JSON.stringify({ attest: true }),
      },
      { incoming: { socket: { remoteAddress: "10.0.0.1" } } },
    );
    expect(((await one.json()) as { chains: unknown }).chains).toEqual([
      { chainId: 46630, status: "pending", created: true },
    ]);
    const all = (await (await post(app, cookie)).json()) as {
      created: boolean;
      chains: unknown;
    };
    expect(all.created).toBe(true);
    expect(all.chains).toEqual([
      { chainId: 46630, status: "pending", created: false },
      { chainId: 421614, status: "pending", created: true },
    ]);
    const bad = await app.request(
      "/v1/testnet/allowlist?chain=42161",
      {
        method: "POST",
        headers: {
          cookie,
          "content-type": "application/json",
          "x-forwarded-for": "9.9.9.9",
        },
        body: JSON.stringify({ attest: true }),
      },
      { incoming: { socket: { remoteAddress: "10.0.0.1" } } },
    );
    expect(bad.status).toBe(400);
  });

  it("requires the attestation and is off on mainnet", async () => {
    const { app } = mk();
    const cookie = await signIn(app);
    const r = await app.request("/v1/testnet/allowlist", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ attest: false }),
    });
    expect(r.status).toBe(400);
    const off = mk({ allowlistEnabled: false });
    const c2 = await signIn(off.app);
    expect((await post(off.app, c2)).status).toBe(404);
  });
});
