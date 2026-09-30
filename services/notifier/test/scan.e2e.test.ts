// The producer's scan against Postgres, on a minimal `ix` schema with the indexer's column names: Bell outcome 5
// (SALE_TOO_LATE, ADR-0115) enqueues one "too late for a pre-close sale" alert; other outcomes don't; a second scan
// over the same window enqueues nothing (N-05, dedupe). Needs TEST_DATABASE_URL (skipped without it).
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import postgres from "postgres";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { labelsFromBook, scan } from "../src/producer.ts";
import { connect, type Sql } from "../src/queue.ts";
import { render } from "../src/templates.ts";

const DB = process.env.TEST_DATABASE_URL;
const ROOT = join(import.meta.dirname, "../../..");
const W = 10n ** 18n;
const MID = "0x" + "11".repeat(32);
const ASSET = "0x" + "22".repeat(32);
const LATE = "0x00000000000000000000000000000000000000b1";
const COVERED = "0x00000000000000000000000000000000000000b2";
const labels = labelsFromBook({
  equity: { pool: "0xpool", markets: { NVDA: MID } },
});

const IX = `
create schema ix;
create table ix.market (market_id text, asset_id text, lt numeric);
create table ix.position (market_id text, owner text, collateral numeric, debt_snapshot numeric);
create table ix.position_event (owner text, market_id text, kind text, amounts jsonb, ts numeric);
create table ix.price_point (asset_id text, kind int, observed_at numeric, price numeric);
create table ix.auction (auction_id numeric, market_id text, kind int, asset_id text, closure_id numeric, p_star numeric, deadlines jsonb);
create table ix.open_print (asset_id text, closure_id numeric, price numeric);
create table ix.lot_position (auction_id numeric, market_id text, owner text, settled_at numeric);
create table ix.settlement (settlement_id numeric, market_id text, status text, price numeric, floor_price numeric);
create table ix.epoch (pool text, epoch_id numeric, status text, share_price_after numeric, settled_at numeric);
create table ix.pool_holder (pool text, owner text, shares numeric);
create table ix.pool_request (pool text, owner text, epoch_id numeric, kind text, shares numeric);
`;

describe.skipIf(!DB)("producer scan (Postgres)", () => {
  let admin: Sql;
  let sql: Sql;
  let dbName: string;

  beforeAll(async () => {
    admin = postgres(DB!, { max: 1, onnotice: () => {} });
    dbName = `credence_notifier_scan_${Date.now()}`;
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
    await sql.unsafe(IX);
    await sql`insert into ix.market values (${MID}, ${ASSET}, ${((8n * W) / 10n).toString()})`;
    await sql`insert into ix.price_point values (${ASSET}, 0, 1000, ${(180n * W).toString()})`;
    for (const [owner, outcome] of [
      [LATE, 5],
      [COVERED, 2],
    ] as const) {
      await sql`insert into ix.position values (${MID}, ${owner}, ${(500n * W).toString()}, 67000000000)`;
      await sql`insert into ix.position_event values (${owner}, ${MID}, 'bell_enforced',
                ${sql.json({ closureId: "7", outcome, outcomeName: outcome === 5 ? "SALE_TOO_LATE" : "AUTO_COVERED" })}, 1100)`;
    }
  }, 60_000);

  afterAll(async () => {
    await sql?.end();
    if (admin && dbName)
      await admin.unsafe(`drop database if exists ${dbName} with (force)`);
    await admin?.end();
  });

  it("outcome 5 → one 'too late for a pre-close sale' alert; a rescan enqueues nothing", async () => {
    const first = await scan(sql, "ix", 0n, labels);
    expect(first.enqueued).toBe(1);
    expect(first.maxTs).toBe(1100n);
    const jobs = await sql<
      { dedupe_key: string; event: string; payload: Record<string, string> }[]
    >`select dedupe_key, event, payload from app.notification_job`;
    expect(jobs).toHaveLength(1);
    expect(jobs[0]!.dedupe_key).toBe(`TOOLATE:${MID}:7:${LATE}`);
    expect(jobs[0]!.event).toBe("bell_outcome");
    expect(jobs[0]!.payload.outcome).toBe("saleTooLate");
    // 67,000 / (500 × 180) = 74.44 %, rounded up
    expect(jobs[0]!.payload.newLtv).toBe("744444444444444445");
    const r = render("bell_outcome", jobs[0]!.payload, "https://x").rendered;
    expect(r.subject).toBe("NVDA: too late for a pre-close sale");
    expect(r.text).toContain("nothing was sold and no Gap Cover was bought");

    expect((await scan(sql, "ix", 0n, labels)).enqueued).toBe(0);
    const n = await sql`select count(*)::int as n from app.notification_job`;
    expect(n[0]!.n).toBe(1);
  });
});
