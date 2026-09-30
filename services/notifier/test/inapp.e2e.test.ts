// Amendment 2 (S5): the in-app channel on Postgres. The default config delivers in-app only (email / push /
// Telegram off); a user event lands in app.inbox with its chain; a duplicate event, a replayed job and a retry
// write one row (N-06); the same dedupe key on another chain is that chain's row. Needs TEST_DATABASE_URL.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import pino from "pino";
import postgres from "postgres";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";
import { claim, connect, enqueue, type Sql } from "../src/queue.ts";
import { processJob } from "../src/worker.ts";

const DB = process.env.TEST_DATABASE_URL;
const ROOT = join(import.meta.dirname, "../../..");
const OWNER = "0x00000000000000000000000000000000000000d1";
const payload = {
  stack: "equity",
  epochId: "7",
  shares: "1000000000000000000000",
  assets: "1234560000",
  loanDecimals: 6,
  loanSymbol: "tUSDG",
  chainId: 46630,
  chainName: "Robinhood Chain testnet",
};

describe.skipIf(!DB)("in-app channel (Postgres)", () => {
  let admin: Sql;
  let sql: Sql;
  let dbName: string;
  const log = pino({ level: "silent" });
  // the production default: NOTIFIER_CHANNELS unset → in-app only, even with every provider configured
  const cfg = loadConfig({
    DATABASE_URL: "postgres://unused",
    RESEND_API_KEY: "re_test",
    TELEGRAM_BOT_TOKEN: "123:test",
  }).worker;

  beforeAll(async () => {
    admin = postgres(DB!, { max: 1, onnotice: () => {} });
    dbName = `credence_notifier_inapp_${Date.now()}`;
    await admin.unsafe(`create database ${dbName}`);
    const url = new URL(DB!);
    url.pathname = `/${dbName}`;
    sql = connect(url.toString(), 4);
    const dir = join(ROOT, "infra/db/migrations");
    for (const f of readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .sort())
      await sql.unsafe(
        readFileSync(join(dir, f), "utf8").split("-- migrate:down")[0]!,
      );
    // an account with a verified email and Telegram: still in-app only by default
    await sql`insert into app.account (address, email, email_verified_at, telegram_chat_id)
              values (${Buffer.from(OWNER.slice(2), "hex")}, 'd1@example.com', now(), '42')`;
  }, 60_000);

  afterAll(async () => {
    await sql?.end();
    if (admin && dbName)
      await admin.unsafe(`drop database if exists ${dbName} with (force)`);
    await admin?.end();
  });

  const runAll = async () => {
    for (const j of await claim(sql, 10, "w1", 60))
      await processJob({ sql, cfg, log }, j);
  };
  const inbox = () =>
    sql<
      { chain_id: string; subject: string; body: string; url: string | null }[]
    >`select chain_id, subject, body, url from app.inbox order by id`;

  it("an event lands in the inbox, in-app only, with its chain and loan token", async () => {
    expect([...cfg.enabled!]).toEqual(["inapp"]);
    await enqueue(sql, {
      chainId: 46630,
      dedupeKey: "WITHDRAW:pool:7:d1",
      address: OWNER,
      event: "withdrawal_claimable",
      payload,
    });
    await runAll();
    const rows = await inbox();
    expect(rows).toHaveLength(1);
    expect(Number(rows[0]!.chain_id)).toBe(46630);
    expect(rows[0]!.subject).toBe("Withdrawal ready: claim 1,234.56 tUSDG");
    expect(rows[0]!.url).toContain("chain=46630");
    const [j] = await sql<
      { status: string; delivered_channels: string[] }[]
    >`select status, delivered_channels from app.notification_job`;
    expect(j).toEqual({ status: "sent", delivered_channels: ["inapp"] });
  });

  it("N-06: a duplicate event, a replayed job and a retry write one row; another chain writes its own", async () => {
    // duplicate event: the queue refuses the second job
    expect(
      await enqueue(sql, {
        chainId: 46630,
        dedupeKey: "WITHDRAW:pool:7:d1",
        address: OWNER,
        event: "withdrawal_claimable",
        payload,
      }),
    ).toBeNull();
    // a replayed job (a crash after the inbox write, before the job was marked sent)
    await sql`update app.notification_job set status = 'pending', delivered_channels = '{}', run_at = now()`;
    await runAll();
    expect(await inbox()).toHaveLength(1);
    // the same key on the other chain
    await enqueue(sql, {
      chainId: 421614,
      dedupeKey: "WITHDRAW:pool:7:d1",
      address: OWNER,
      event: "withdrawal_claimable",
      payload: { ...payload, chainId: 421614, loanSymbol: "USDC" },
    });
    await runAll();
    const rows = await inbox();
    expect(rows.map((r) => Number(r.chain_id))).toEqual([46630, 421614]);
    expect(rows[1]!.subject).toContain("USDC");
  });

  it("the inbox write notifies listeners (the API's live push)", async () => {
    const got: string[] = [];
    const l = await sql.listen("inbox", (id) => got.push(id));
    await enqueue(sql, {
      chainId: 46630,
      dedupeKey: "WITHDRAW:pool:8:d1",
      address: OWNER,
      event: "withdrawal_claimable",
      payload: { ...payload, epochId: "8" },
    });
    await runAll();
    await new Promise((r) => setTimeout(r, 200));
    expect(got).toHaveLength(1);
    await l.unlisten();
  });
});
