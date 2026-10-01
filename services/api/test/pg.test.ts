// The Postgres repositories against the migrated `app` schema (runs when TEST_DATABASE_URL is set:
// `make api-db-test`, needs make infra-up db-migrate). Each run uses fresh random addresses.
import { randomBytes } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";
import { pgRepos } from "../src/repo.ts";
import { sha256 } from "../src/me.ts";
import { pgAppStream, pgInboxRepo, pgOpsRepo } from "../src/inbox.ts";

const url = process.env.TEST_DATABASE_URL;
const repos = url ? pgRepos(url, "indexer") : undefined;
afterAll(async () => repos?.close());
const addr = () =>
  getAddress(`0x${randomBytes(20).toString("hex")}`) as Address;

describe.skipIf(!url)("OFF-07 read limits", () => {
  it("every API connection has a statement timeout; a slow read is cancelled", async () => {
    const [{ t }] = (await repos!
      .sql`select current_setting('statement_timeout') as t`) as unknown as [
      { t: string },
    ];
    expect(t).toBe("5s");
    await expect(repos!.sql`select pg_sleep(6)`).rejects.toThrow(
      /statement timeout/,
    );
  }, 15_000);
});

describe.skipIf(!url)("pg MeRepo", () => {
  it("email: set unverified, verify once with the right token, re-set invalidates", async () => {
    const me = repos!.me;
    const a = addr();
    const t1 = randomBytes(32).toString("base64url");
    const now = new Date();
    expect(
      await me.setEmail(
        a,
        "x@example.com",
        sha256(t1),
        new Date(now.getTime() + 3600_000),
      ),
    ).toBe(true);
    expect(
      await me.setEmail(
        a,
        "x@example.com",
        sha256("other"),
        new Date(now.getTime() + 3600_000),
      ),
    ).toBe(false);
    expect((await me.account(a)).emailVerified).toBe(false);
    expect(await me.verifyEmail(sha256("wrong"), now)).toBeNull();
    expect(await me.verifyEmail(sha256(t1), now)).toBe(a);
    expect(await me.verifyEmail(sha256(t1), now)).toBeNull();
    expect((await me.account(a)).emailVerified).toBe(true);
    const t2 = randomBytes(32).toString("base64url");
    await me.setEmail(
      a,
      "y@example.com",
      sha256(t2),
      new Date(now.getTime() - 1),
    ); // already expired
    expect(await me.verifyEmail(sha256(t2), now)).toBeNull();
    expect(await me.account(a)).toMatchObject({
      email: "y@example.com",
      emailVerified: false,
    });
  });

  it("telegram, push, prefs, notification job dedupe and the allowlist queue", async () => {
    const me = repos!.me;
    const a = addr();
    await me.setTelegram(a, "42");
    const endpoint = `https://push.example/${randomBytes(8).toString("hex")}`;
    await me.addPush(a, { endpoint, p256dh: "k", auth: "s" });
    await me.setPrefs(a, [
      { event: "bell_headsup", channel: "email", enabled: false },
    ]);
    await me.setPrefs(a, [
      { event: "bell_headsup", channel: "email", enabled: true },
      { event: "bell_outcome", channel: "push", enabled: false },
    ]);
    const v = await me.account(a);
    expect(v.telegramChatId).toBe("42");
    expect(v.push).toEqual([{ endpoint }]);
    expect(v.prefs.sort((x, y) => x.event.localeCompare(y.event))).toEqual([
      { event: "bell_headsup", channel: "email", enabled: true },
      { event: "bell_outcome", channel: "push", enabled: false },
    ]);
    const key = `test:${randomBytes(6).toString("hex")}`;
    await me.enqueue({
      chainId: 0,
      dedupeKey: key,
      address: a,
      event: "email_verify",
      payload: { email: "z@example.com", link: "https://x/y" },
    });
    await me.enqueue({
      chainId: 0,
      dedupeKey: key,
      address: a,
      event: "email_verify",
      payload: { email: "z@example.com", link: "https://x/y" },
    });
    const [{ n }] = (await repos!
      .sql`select count(*)::int as n from app.notification_job where dedupe_key = ${key}`) as unknown as [
      { n: number },
    ];
    expect(n).toBe(1);
    // ADR-0014: the same dedupe key on another chain is another job
    await me.enqueue({
      chainId: 46630,
      dedupeKey: key,
      address: a,
      event: "email_verify",
      payload: { email: "z@example.com", link: "https://x/y" },
    });
    const [{ m }] = (await repos!
      .sql`select count(*)::int as m from app.notification_job where dedupe_key = ${key}`) as unknown as [
      { m: number },
    ];
    expect(m).toBe(2);
    // one attestation allowlists on each served chain, idempotent per chain
    expect(await me.requestAllowlist(a, new Date(), [412346])).toEqual({
      status: "pending",
      created: true,
      chains: [{ chainId: 412346, status: "pending", created: true }],
    });
    expect(await me.requestAllowlist(a, new Date(), [412346, 421614])).toEqual({
      status: "pending",
      created: true,
      chains: [
        { chainId: 412346, status: "pending", created: false },
        { chainId: 421614, status: "pending", created: true },
      ],
    });
    expect((await me.account(a)).allowlistChains).toEqual([
      { chainId: 412346, status: "pending", txHash: null },
      { chainId: 421614, status: "pending", txHash: null },
    ]);
    await repos!
      .sql`delete from app.allowlist_request where chain_id = 421614 and address = ${Buffer.from(a.slice(2), "hex")}`;
    expect((await me.account(a)).allowlist).toEqual({
      status: "pending",
      txHash: null,
    });
    await repos!
      .sql`delete from app.notification_job where dedupe_key = ${key}`;
  });
});

describe.skipIf(!url)("pg inbox and ops alerts (Amendment 2)", () => {
  it("inbox: own rows, paging, mark read; the stream source filters by chain", async () => {
    const sql = repos!.sql;
    const inbox = pgInboxRepo(sql);
    const a = addr();
    const b = addr();
    const buf = (x: Address) => Buffer.from(x.slice(2).toLowerCase(), "hex");
    const src46 = pgAppStream(sql, 46630, true);
    const src421 = pgAppStream(sql, 421614, false);
    const head = await src46.inboxHead();
    for (const [who, chain, key] of [
      [a, 46630, "k1"],
      [a, 421614, "k2"],
      [b, 46630, "k3"],
      [a, 0, "k4"],
    ] as const)
      await sql`insert into app.inbox (chain_id, address, event, dedupe_key, subject, body, payload)
                values (${chain}, ${buf(who)}, 'withdrawal_claimable', ${key}, ${key}, 'b', '{}')`;
    const rows = await inbox.list(a, { unread: false, limit: 10 });
    expect(rows.map((r) => r.subject)).toEqual(["k4", "k2", "k1"]);
    expect(await inbox.unreadCount(a)).toBe(3);
    const other = (await inbox.list(b, { unread: false, limit: 10 }))[0]!;
    expect(await inbox.markRead(a, [rows[2]!.id, other.id], new Date())).toBe(
      1,
    );
    expect(await inbox.unreadCount(b)).toBe(1);
    expect(await inbox.markRead(a, "all", new Date())).toBe(2);
    // the default chain's hub gets its chain and account-level rows; the other hub only its chain
    expect(
      (await src46.inboxSince(head, 50)).map((e) => e.chainId).sort(),
    ).toEqual([0, 46630, 46630]);
    expect((await src421.inboxSince(head, 50)).map((e) => e.chainId)).toEqual([
      421614,
    ]);
    expect(src421.opsAlertsSince).toBeUndefined();
  });

  it("ops: stored once per (fingerprint, startsAt), resolved in place, pushed as changed", async () => {
    const sql = repos!.sql;
    const ops = pgOpsRepo(sql);
    const fp = `fp-${randomBytes(4).toString("hex")}`;
    const since = Date.now() - 1000;
    const alert = (status: "firing" | "resolved") => ({
      fingerprint: fp,
      status,
      labels: { alertname: "FeedStale", chain: "46630", severity: "page" },
      annotations: { summary: "stale" },
      startsAt: new Date("2026-09-30T12:00:00Z"),
      endsAt: status === "resolved" ? new Date("2026-09-30T12:05:00Z") : null,
    });
    await ops.store([alert("firing")]);
    await ops.store([alert("firing")]);
    expect(await ops.store([alert("resolved")])).toEqual({
      stored: 1,
      resolved: 1,
    });
    const [row] =
      await sql`select status, chain_id, severity, ends_at from ops.alert where fingerprint = ${fp}`;
    expect(row).toMatchObject({ status: "resolved", severity: "page" });
    expect(Number(row!.chain_id)).toBe(46630);
    const n =
      await sql`select count(*)::int as n from ops.alert where fingerprint = ${fp}`;
    expect(n[0]!.n).toBe(1);
    const pushed = await pgAppStream(sql, 46630, true).opsAlertsSince!(
      since,
      50,
    );
    expect(
      pushed.filter((p) => p.alertname === "FeedStale").at(-1)!.status,
    ).toBe("resolved");
  });
});
