// The Postgres repositories against the migrated `app` schema (runs when TEST_DATABASE_URL is set:
// `make api-db-test`, needs make infra-up db-migrate). Each run uses fresh random addresses.
import { randomBytes } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";
import { getAddress, type Address } from "viem";
import { pgRepos } from "../src/repo.ts";
import { sha256 } from "../src/me.ts";

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
