// Amendment 2 (S5): the in-app inbox, the ops-alert webhook, and their live topics on /v1/stream.
import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { createSiweMessage } from "viem/siwe";
import type { Hex } from "viem";
import { createApp, toAssetId } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { memoryRepos } from "../src/repo.ts";
import {
  MAX_ALERTS,
  memoryInbox,
  memoryOps,
  opsAdmins,
  webhookSecret,
} from "../src/inbox.ts";
import {
  StreamHub,
  type InboxEvent,
  type OpsAlertEvent,
  type Socket,
  type StreamSource,
} from "../src/stream.ts";

const T0 = 1_791_380_000;
const SECRET = "s".repeat(40);
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
  publicApiUrl: "https://api.test",
  allowlistEnabled: true,
  allowlistPerIpPerHour: 5,
};
const me = privateKeyToAccount(
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
);
const OTHER = "0x00000000000000000000000000000000000000b2";

function mk(admin = false) {
  const repos = memoryRepos();
  const row = (owner: string, chainId: number, n: number) => ({
    owner,
    chainId,
    event: "withdrawal_claimable",
    subject: `s${n}`,
    body: `b${n}`,
    url: null,
    payload: {},
    createdAt: new Date(T0 * 1000),
    readAt: null,
  });
  const inbox = memoryInbox([
    row(me.address, 46630, 1),
    row(me.address, 421614, 2),
    row(OTHER, 46630, 3),
    row(me.address, 46630, 4),
    row(me.address, 0, 5),
  ]);
  const ops = memoryOps();
  const app = createApp({
    config,
    clock: repos.clock,
    auth: repos.auth,
    inbox: inbox.repo,
    ops,
    webhookSecret: SECRET,
    opsAdmins: opsAdmins(admin ? me.address : OTHER),
    now: () => T0 * 1000,
  });
  return { app, inbox, ops };
}

async function signIn(app: ReturnType<typeof mk>["app"]): Promise<string> {
  const { nonce } = (await (
    await app.request("/v1/auth/siwe/nonce", { method: "POST" })
  ).json()) as { nonce: string };
  const message = createSiweMessage({
    address: me.address,
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
      signature: await me.signMessage({ message }),
    }),
  });
  return r.headers.get("set-cookie")!.split(";")[0]!;
}

type Page = {
  items: { id: string; chainId: number; subject: string; read: boolean }[];
  unread: number;
  nextCursor: string | null;
};

describe("GET /v1/me/inbox, POST /v1/me/inbox/read", () => {
  it("needs a session, shows only the caller's rows, newest first, paged", async () => {
    const { app } = mk();
    expect((await app.request("/v1/me/inbox")).status).toBe(401);
    const cookie = await signIn(app);
    const get = async (q: string) =>
      (await (
        await app.request(`/v1/me/inbox${q}`, { headers: { cookie } })
      ).json()) as Page;
    const p1 = await get("?limit=2");
    expect(p1.items.map((i) => i.subject)).toEqual(["s5", "s4"]);
    expect(p1.unread).toBe(4);
    const p2 = await get(`?limit=2&cursor=${p1.nextCursor}`);
    expect(p2.items.map((i) => i.subject)).toEqual(["s2", "s1"]);
    expect(p2.nextCursor).toBeNull();
    expect((await get("?chain=421614")).items.map((i) => i.subject)).toEqual([
      "s2",
    ]);
  });

  it("marks only the caller's own rows read; unread=1 then hides them", async () => {
    const { app, inbox } = mk();
    const cookie = await signIn(app);
    const read = (body: unknown) =>
      app.request("/v1/me/inbox/read", {
        method: "POST",
        headers: { cookie, "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    // id 3 is another address's row: untouched
    const r = (await (await read({ ids: ["1", "3"] })).json()) as {
      updated: number;
      unread: number;
    };
    expect(r).toEqual({ updated: 1, unread: 3 });
    expect(inbox.all.find((x) => x.id === 3n)!.readAt).toBeNull();
    const unread = (await (
      await app.request("/v1/me/inbox?unread=1", { headers: { cookie } })
    ).json()) as Page;
    expect(unread.items.map((i) => i.subject)).toEqual(["s5", "s4", "s2"]);
    expect(
      ((await (await read({ all: true })).json()) as { unread: number }).unread,
    ).toBe(0);
    expect((await read({ ids: [] })).status).toBe(400);
    expect((await read({ all: false })).status).toBe(400);
  });
});

const am = (alerts: object[], status = "firing") => ({
  version: "4",
  groupKey: '{}:{alertname="FeedStale"}',
  status,
  receiver: "credence-api",
  groupLabels: {},
  commonLabels: {},
  commonAnnotations: {},
  externalURL: "http://alertmanager:9093",
  alerts,
});
const alert = (status: string, extra: object = {}) => ({
  status,
  labels: {
    alertname: "FeedStale",
    chain: "46630",
    severity: "page",
    asset: "NVDA",
  },
  annotations: {
    summary: "feed A stale for NVDA",
    runbook: "docs/runbooks/feed-stale.md",
  },
  startsAt: "2026-09-30T12:00:00Z",
  endsAt:
    status === "resolved" ? "2026-09-30T12:05:00Z" : "0001-01-01T00:00:00Z",
  generatorURL: "http://prometheus:9090/graph",
  fingerprint: "a1b2c3",
  ...extra,
});

describe("POST /v1/ops/alerts (Alertmanager webhook), GET /v1/ops/alerts", () => {
  const post = (
    app: ReturnType<typeof mk>["app"],
    body: unknown,
    auth: string | null = `Bearer ${SECRET}`,
  ) =>
    app.request("/v1/ops/alerts", {
      method: "POST",
      headers: {
        ...(auth ? { authorization: auth } : {}),
        "content-type": "application/json",
      },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });

  it("refuses a missing or wrong secret, a bad body, and too many alerts", async () => {
    const { app, ops } = mk();
    expect((await post(app, am([alert("firing")]), null)).status).toBe(
      401,
    );
    expect((await post(app, am([alert("firing")]), "Bearer nope")).status).toBe(
      401,
    );
    expect((await post(app, "{nope")).status).toBe(400);
    expect((await post(app, { version: "3", alerts: [] })).status).toBe(400);
    const many = Array.from({ length: MAX_ALERTS + 1 }, (_, i) =>
      alert("firing", { fingerprint: `f${i}` }),
    );
    expect((await post(app, am(many))).status).toBe(413);
    expect(ops.rows).toHaveLength(0);
  });

  it("stores firing alerts once (a re-send is idempotent) and resolves them", async () => {
    const { app, ops } = mk();
    const r1 = await post(app, am([alert("firing")]));
    expect(await r1.json()).toEqual({ stored: 1, resolved: 0 });
    await post(app, am([alert("firing")])); // Alertmanager re-sends every repeat_interval
    expect(ops.rows).toHaveLength(1);
    expect(ops.rows[0]).toMatchObject({
      status: "firing",
      alertname: "FeedStale",
      chainId: 46630,
      severity: "page",
      runbook: "docs/runbooks/feed-stale.md",
      endsAt: null,
    });
    await post(app, am([alert("resolved")], "resolved"));
    expect(ops.rows).toHaveLength(1);
    expect(ops.rows[0]!.status).toBe("resolved");
    expect(ops.rows[0]!.endsAt?.toISOString()).toBe("2026-09-30T12:05:00.000Z");
    // the same fingerprint firing again later is a new row
    await post(
      app,
      am([alert("firing", { startsAt: "2026-09-30T13:00:00Z" })]),
    );
    expect(ops.rows).toHaveLength(2);
  });

  it("GET is for ops admins only, filtered by status and chain", async () => {
    const outsider = mk(false);
    const c1 = await signIn(outsider.app);
    expect((await outsider.app.request("/v1/ops/alerts")).status).toBe(401);
    expect(
      (
        await outsider.app.request("/v1/ops/alerts", {
          headers: { cookie: c1 },
        })
      ).status,
    ).toBe(403);
    const { app } = mk(true);
    const cookie = await signIn(app);
    await post(
      app,
      am([
        alert("firing"),
        alert("firing", {
          fingerprint: "b",
          labels: { alertname: "KeeperLeaderMissing", chain: "421614" },
        }),
      ]),
    );
    const list = async (q: string) =>
      (
        (await (
          await app.request(`/v1/ops/alerts${q}`, { headers: { cookie } })
        ).json()) as { items: { alertname: string; chainId: number | null }[] }
      ).items;
    expect((await list("")).map((a) => a.alertname)).toEqual([
      "KeeperLeaderMissing",
      "FeedStale",
    ]);
    expect((await list("?chain=421614")).map((a) => a.chainId)).toEqual([
      421614,
    ]);
    expect(await list("?status=resolved")).toEqual([]);
  });

  it("the secret must be at least 32 bytes; admins are checksummed or not", () => {
    expect(() =>
      webhookSecret({ OPS_ALERT_WEBHOOK_SECRET: "short" }, () => ""),
    ).toThrow(/32 bytes/);
    expect(webhookSecret({}, () => "")).toBeUndefined();
    expect(
      webhookSecret(
        { OPS_ALERT_WEBHOOK_SECRET_FILE: "/run/secrets/x" },
        () => `${SECRET}\n`,
      ),
    ).toBe(SECRET);
    expect([...opsAdmins(`${me.address.toLowerCase()}, ${OTHER}`)]).toEqual([
      me.address.toLowerCase(),
      OTHER,
    ]);
  });
});

class Sock implements Socket {
  sent: Record<string, unknown>[] = [];
  send(d: string) {
    this.sent.push(JSON.parse(d));
  }
  close() {}
}
class Source implements StreamSource {
  inbox: InboxEvent[] = [];
  ops: OpsAlertEvent[] = [];
  async head() {
    return 1n;
  }
  async clockSince() {
    return [];
  }
  async pricesSince() {
    return [];
  }
  async auctionsSince() {
    return [];
  }
  async ownerEventsSince() {
    return [];
  }
  async inboxHead() {
    return 0n;
  }
  async inboxSince(id: bigint) {
    return this.inbox.filter((e) => e.id > id);
  }
  async opsAlertsSince(ms: number) {
    return this.ops.filter((e) => e.updatedAt > ms);
  }
}

describe("stream: inbox:<owner> and ops (N-06: reconnect)", () => {
  const ME = me.address.toLowerCase();
  const ev = (id: bigint, owner: string): InboxEvent => ({
    id,
    chainId: 46630,
    owner: owner as Hex,
    event: "withdrawal_claimable",
    subject: `s${id}`,
    body: "b",
    url: null,
    createdAt: T0,
  });
  it("inbox:<owner> needs that owner's session; ops needs an admin; both end with the session", async () => {
    const src = new Source();
    const hub = new StreamHub(src, toAssetId);
    hub.opsAdmins = new Set([ME]);
    const ws = new Sock();
    const anon = new Sock();
    hub.add(ws, { owner: ME, session: "sid" });
    hub.add(anon);
    hub.message(
      ws,
      JSON.stringify({ op: "subscribe", channels: [`inbox:${ME}`, "ops"] }),
    );
    expect(ws.sent.at(-1)).toMatchObject({ type: "subscribed" });
    hub.message(
      anon,
      JSON.stringify({ op: "subscribe", channels: [`inbox:${ME}`] }),
    );
    expect(anon.sent.at(-1)).toMatchObject({ type: "error" });
    hub.message(anon, JSON.stringify({ op: "subscribe", channels: ["ops"] }));
    expect(anon.sent.at(-1)).toMatchObject({ type: "error" });
    await hub.poll(); // positions the cursors
    src.inbox.push(ev(1n, ME), ev(2n, OTHER));
    src.ops.push({
      id: 1n,
      alertname: "FeedStale",
      status: "firing",
      chainId: 46630,
      severity: "page",
      summary: null,
      runbook: null,
      startsAt: T0,
      endsAt: null,
      updatedAt: Date.now() + 1_000,
    });
    await hub.poll();
    const got = ws.sent.filter((f) => f.channel);
    expect(got.map((f) => f.channel)).toEqual([`inbox:${ME}`, "ops"]);
    expect(got[0]).toMatchObject({
      data: { id: "1", chainId: 46630, subject: "s1" },
    });
    // nothing twice on the next poll
    await hub.poll();
    expect(ws.sent.filter((f) => f.channel)).toHaveLength(2);
    // logout (OFF-04c): no more inbox or ops frames
    hub.dropSession("sid");
    src.inbox.push(ev(3n, ME));
    await hub.poll();
    expect(ws.sent.filter((f) => f.channel)).toHaveLength(2);
  });

  it("N-06 reconnect: a new socket gets new rows live; the missed ones are in GET /v1/me/inbox", async () => {
    const src = new Source();
    const hub = new StreamHub(src, toAssetId);
    const a = new Sock();
    hub.add(a, { owner: ME, session: "s1" });
    hub.message(
      a,
      JSON.stringify({ op: "subscribe", channels: [`inbox:${ME}`] }),
    );
    await hub.poll();
    hub.remove(a); // disconnected
    src.inbox.push(ev(1n, ME)); // lands while offline: never pushed, it is in the inbox (GET /v1/me/inbox)
    await hub.poll();
    const b = new Sock();
    hub.add(b, { owner: ME, session: "s1" });
    hub.message(
      b,
      JSON.stringify({ op: "subscribe", channels: [`inbox:${ME}`] }),
    );
    src.inbox.push(ev(2n, ME));
    await hub.poll();
    expect(
      b.sent.filter((f) => f.channel).map((f) => (f.data as { id: string }).id),
    ).toEqual(["2"]);
    expect(a.sent.filter((f) => f.channel)).toHaveLength(0);
  });
});
