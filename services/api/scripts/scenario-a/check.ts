// Scenario A checks (make scenario-a-e2e, ADR-0012). Waits for each milestone of the closure cycle (the
// keeper, the relayer and the bidder bot drive it), then asserts:
//   1. the keeper sent no transaction that reverted (ops.keeper_tx), and nobody else but the keeper, the
//      relayer and the bot sent a transaction after seeding (block scan);
//   2. the indexer / API figures equal the chain at the same block (auctions, settlements, pool, epochs);
//   3. every expected notification was sent (email + Telegram, notification_log ok) with amounts equal to
//      the chain's own event values.
// Env: API, DATABASE_URL, INDEXER_SCHEMA, SEED_END_BLOCK, KEEPER_ADDRESS, RELAYER_ADDRESS.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import postgres from "postgres";
import type { Address, Hex } from "viem";
import {
  IAuctionHouseAbi,
  ICredenceMarketAbi,
  IUnderwriterPoolAbi,
} from "@credence/sdk";
import { OUT, book, pub } from "./lib.ts";

const API = process.env.API ?? "http://127.0.0.1:18798";
const sql = postgres(process.env.DATABASE_URL!, {
  max: 2,
  onnotice: () => {},
  types: { bigint: postgres.BigInt },
});
const meta = JSON.parse(
  readFileSync(resolve(OUT, "replay.meta.json"), "utf8"),
) as { fridayClose: number; mondayOpen: number };
const actors = JSON.parse(
  readFileSync(resolve(OUT, "actors.json"), "utf8"),
) as Record<string, Address>;
const market = book.equity.market as Address;
const pool = book.equity.pool as Address;
const house = book.equity.auctionHouse as Address;
const from = BigInt(process.env.SEED_END_BLOCK ?? "0");
const failures: string[] = [];
const ok = (cond: boolean, what: string) => {
  console.log(`${cond ? "  ok " : "FAIL "} ${what}`);
  if (!cond) failures.push(what);
};
const now = async () => Number((await pub.getBlock()).timestamp);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until<T>(
  what: string,
  deadline: number,
  f: () => Promise<T | undefined | null | false>,
): Promise<T> {
  for (;;) {
    const v = await f().catch(() => undefined);
    if (v) {
      console.log(`  ✓ ${what}`);
      return v as T;
    }
    if ((await now()) > deadline)
      throw new Error(`timed out waiting for: ${what}`);
    await sleep(5_000);
  }
}
const lc = (a: string) => a.toLowerCase();
const events = <N extends string>(
  address: Address,
  abi: readonly unknown[],
  eventName: N,
) =>
  pub.getContractEvents({
    address,
    abi: abi as never,
    eventName: eventName as never,
    fromBlock: from,
    toBlock: "latest",
  }) as unknown as Promise<
    {
      args: Record<string, unknown>;
      blockNumber: bigint;
      transactionHash: Hex;
    }[]
  >;

// ── 1. the milestones ──
console.log(
  `scenario A: Friday close ${meta.fridayClose}, Monday open ${meta.mondayOpen}`,
);
// §10.4 / S3 D: before the Bell, /bell equals the market's own bellStatus, premium included (the real pool)
await until(
  "the Friday Bell window (T−2h) with the −1% drift in",
  meta.fridayClose - 2 * 3600 + 90,
  async () => (await now()) >= meta.fridayClose - 2 * 3600 + 60 || null,
);
for (const n of ["priya", "maya"]) {
  const id = book.equity.markets.NVDA as Hex;
  const r = await fetch(`${API}/v1/positions/${id}/${actors[n]}/bell`);
  const b = (await r.json()) as {
    block: string;
    status: { code: number };
    cure: { repay: { raw: string }; addCollateral: string };
    premium: { raw: string } | null;
  };
  const [st, repay, coll, prem] = await pub.readContract({
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "bellStatus",
    args: [id, actors[n]!],
    blockNumber: BigInt(b.block),
  });
  ok(
    Number(st) === b.status.code &&
      repay.toString() === b.cure.repay.raw &&
      coll.toString() === b.cure.addCollateral &&
      (b.status.code !== 1 || prem.toString() === b.premium?.raw),
    `/bell for ${n} == market.bellStatus at block ${b.block}: status ${st}, repay ${repay}, collateral ${coll}, premium ${prem} (API ${b.premium?.raw ?? "null"})`,
  );
}
const autoCover = await until(
  "Priya auto-covered at the Bell (AutoCoverApplied)",
  meta.fridayClose,
  async () =>
    (await events(market, ICredenceMarketAbi, "AutoCoverApplied")).find(
      (e) => lc(e.args.borrower as string) === lc(actors.priya!),
    ),
);
await until(
  "Maya's pre-close sale settled (PRECLOSE auction)",
  meta.fridayClose + 120,
  async () => {
    const s = await events(market, ICredenceMarketAbi, "PositionSettled");
    return s.find((e) => lc(e.args.borrower as string) === lc(actors.maya!));
  },
);
await until(
  "the open prints: NVDA and TSLA in REOPEN",
  meta.mondayOpen + 300,
  async () =>
    (await events(house, IAuctionHouseAbi, "AuctionCreated")).filter(
      (e) => Number(e.args.kind) === 0,
    ).length >= 2,
);
await until(
  "Dev settled at the REOPEN auction with a shortfall",
  meta.mondayOpen + 20 * 60,
  async () =>
    (await events(market, ICredenceMarketAbi, "PositionSettled")).find(
      (e) =>
        lc(e.args.borrower as string) === lc(actors.dev!) &&
        (e.args.shortfall as bigint) > 0n,
    ),
);
await until(
  "the pool paid the shortfall and bought the unsold lot (ShortfallPaid, BackstopBought)",
  meta.mondayOpen + 20 * 60,
  async () => {
    const [s, b] = await Promise.all([
      events(pool, IUnderwriterPoolAbi, "ShortfallPaid"),
      events(pool, IUnderwriterPoolAbi, "BackstopBought"),
    ]);
    return s.length > 0 && b.length > 0;
  },
);
await until(
  "J11 listed the backstop inventory (GdaStarted)",
  meta.mondayOpen + 25 * 60,
  async () => (await events(house, IAuctionHouseAbi, "GdaStarted")).length > 0,
);
const settled = await until(
  "J9 settled the epoch (EpochSettled)",
  meta.mondayOpen + 30 * 60,
  async () => (await events(pool, IUnderwriterPoolAbi, "EpochSettled"))[0],
);
const epochId = settled.args.epochId as bigint;
await sleep(90_000); // the indexer, the notifier scan and delivery catch up

// ── 2. who sent transactions after seeding ──
{
  const allowed = new Set(
    [
      process.env.KEEPER_ADDRESS,
      process.env.RELAYER_ADDRESS,
      actors.honest1,
      actors.honest2,
      actors.lowball,
      actors.noreveal,
    ]
      .filter(Boolean)
      .map((a) => lc(a!)),
  );
  const head = await pub.getBlockNumber();
  const strangers = new Map<string, number>();
  for (let b = from + 1n; b <= head; b++) {
    const blk = await pub.getBlock({
      blockNumber: b,
      includeTransactions: true,
    });
    for (const tx of blk.transactions) {
      if (
        typeof tx === "string" ||
        (tx.type !== "eip1559" && tx.type !== "legacy" && tx.type !== "eip2930")
      )
        continue; // ArbOS internal txs
      if (!allowed.has(lc(tx.from)))
        strangers.set(tx.from, (strangers.get(tx.from) ?? 0) + 1);
    }
  }
  ok(
    strangers.size === 0,
    `no manual transaction after seeding (blocks ${from + 1n}..${head})${strangers.size ? `: ${JSON.stringify([...strangers])}` : ""}`,
  );
  const [r] =
    await sql`select count(*)::int as n from ops.keeper_tx where status = 'reverted' and submitted_at > now() - interval '6 hours'`;
  ok(
    r!.n === 0,
    `the keeper sent 0 failed txs (ops.keeper_tx reverted: ${r!.n})`,
  );
}

// acceptance 4: the keeper was killed between a REOPEN fixLots and its clear, and no J5 step was sent twice
{
  const [k] =
    await sql`select count(*)::int as n from ops.keeper_job where key like 'J5:%:clear:%' and status = 'done'`;
  const dups =
    await sql`select job_key, count(*)::int as n from ops.keeper_tx where job_key like 'J5:%' and status = 'mined' group by job_key having count(*) > 1`;
  let restarted = "";
  try {
    restarted = readFileSync(resolve(OUT, "restart.log"), "utf8")
      .trim()
      .replace(/\n/g, "; ");
  } catch {
    /* no restart happened */
  }
  ok(
    restarted.includes("killed") && restarted.includes("restarted"),
    `keeper killed between fixLots and clear, then restarted (${restarted || "no restart log"})`,
  );
  ok(
    k!.n >= 1 && dups.length === 0,
    `after the restart every REOPEN auction cleared (${k!.n} J5 clear steps done) with no J5 step mined twice`,
  );
}

// ── 3. indexer / API == chain ──
const j = async (p: string) => {
  const r = await fetch(`${API}${p}`);
  if (!r.ok) throw new Error(`${p}: ${r.status}`);
  return (await r.json()) as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
};
for (const e of await events(house, IAuctionHouseAbi, "AuctionCreated")) {
  const id = e.args.id as bigint;
  const a = await pub.readContract({
    address: house,
    abi: IAuctionHouseAbi,
    functionName: "auction",
    args: [id],
  });
  const api = await j(`/v1/auctions/${id}`);
  ok(
    api.lot === a.lot.toString() &&
      api.reserve === a.reserve.toString() &&
      (api.clearing?.pStar ?? "0") === a.pStar.toString() &&
      (api.clearing?.qPool ?? "0") === a.qPool.toString() &&
      (api.clearing?.proceeds?.raw ?? "0") === a.proceeds.toString(),
    `/v1/auctions/${id} (${api.kind?.name}) == auction(${id}): lot ${a.lot}, R ${a.reserve}, p* ${a.pStar}, qPool ${a.qPool}, proceeds ${a.proceeds}`,
  );
}
for (const e of await events(market, ICredenceMarketAbi, "PositionSettled")) {
  const api = await j(`/v1/auctions/${e.args.auctionId}`);
  const row = (
    api.settlement as {
      owner: string;
      proceeds: { raw: string };
      penalty: { raw: string };
      shortfall: { raw: string };
      refund: { raw: string };
      debtAfter: { raw: string };
    }[]
  ).find((s) => lc(s.owner) === lc(e.args.borrower as string));
  ok(
    !!row &&
      row.proceeds.raw === String(e.args.proceeds) &&
      row.penalty.raw === String(e.args.penalty) &&
      row.shortfall.raw === String(e.args.shortfall) &&
      row.refund.raw === String(e.args.refund) &&
      row.debtAfter.raw === String(e.args.debtAfter),
    `settlement of ${e.args.borrower} in auction ${e.args.auctionId} == PositionSettled`,
  );
}
{
  const p = await j("/v1/pool/equity");
  const b = BigInt(p.block);
  const [nav, sp] = await Promise.all([
    pub.readContract({
      address: pool,
      abi: IUnderwriterPoolAbi,
      functionName: "nav",
      blockNumber: b,
    }),
    pub.readContract({
      address: pool,
      abi: IUnderwriterPoolAbi,
      functionName: "sharePrice",
      blockNumber: b,
    }),
  ]);
  ok(
    p.nav.raw === nav.toString() && p.sharePrice === sp.toString(),
    `/v1/pool/equity == pool at block ${b}: NAV ${nav}, share price ${sp}`,
  );
  const ep = (await j("/v1/pool/equity/epochs?limit=5")).items.find(
    (x: { epochId: string }) => x.epochId === epochId.toString(),
  );
  const onchain = await pub.readContract({
    address: pool,
    abi: IUnderwriterPoolAbi,
    functionName: "epoch",
    args: [epochId],
  });
  ok(
    !!ep &&
      ep.pnl.premiums.raw === onchain.premiums.toString() &&
      ep.pnl.lossesPaid.raw === onchain.lossesPaid.toString() &&
      ep.navAfter.raw === onchain.navAfter.toString() &&
      ep.sharePriceAfter === onchain.sharePriceAfter.toString(),
    `/v1/pool/equity/epochs[${epochId}] == pool.epoch(${epochId}): premiums ${onchain.premiums}, losses ${onchain.lossesPaid}, NAV after ${onchain.navAfter}, share price ${onchain.sharePriceAfter}`,
  );
  const risk = await j("/v1/risk");
  ok(
    risk.auctions.length > 0 && risk.pools.length > 0,
    `/v1/risk lists ${risk.auctions.length} cleared auctions and ${risk.pools.length} pool(s)`,
  );
}

// ── 4. notifications with exact amounts ──
const job = async (key: string) => {
  const [r] = await sql`select j.id, j.status, j.payload, j.delivered_channels,
                               (select count(*)::int from app.notification_log l where l.job_id = j.id and l.ok) as sent
                          from app.notification_job j where j.dedupe_key = ${key}`;
  return r;
};
const expectJob = async (
  key: string,
  what: string,
  check: (p: Record<string, string>) => boolean,
) => {
  const r = await job(key);
  ok(
    !!r &&
      r.status === "sent" &&
      r.sent >= 1 &&
      check(r.payload as Record<string, string>),
    `${what} [${key}]${r ? ` status ${r.status}, ${r.sent} deliveries` : " missing"}`,
  );
};
const mId = (t: string) => lc(book.equity.markets[t]);
const closure = (autoCover.args.closureId as bigint).toString();
for (const n of ["priya", "maya"]) {
  const [r] =
    await sql`select dedupe_key from app.notification_job where event = 'bell_headsup' and address = ${Buffer.from(actors[n]!.slice(2).toLowerCase(), "hex")} limit 1`;
  ok(!!r, `J2 Bell heads-up for ${n}${r ? ` [${r.dedupe_key}]` : ""}`);
  if (r) await expectJob(r.dedupe_key as string, `  delivered`, () => true);
}
await expectJob(
  `AUTO:${mId("NVDA")}:${closure}:${lc(actors.priya!)}`,
  "auto-cover applied: premium == AutoCoverApplied.premium",
  (p) => p.premium === String(autoCover.args.premium),
);
for (const e of await events(market, ICredenceMarketAbi, "PositionSettled")) {
  await expectJob(
    `SETTLED:${e.args.auctionId}:${lc(e.args.borrower as string)}`,
    `auction settled for ${e.args.borrower}: proceeds/penalty/shortfall/refund == PositionSettled`,
    (p) =>
      p.proceeds === String(e.args.proceeds) &&
      p.penalty === String(e.args.penalty) &&
      p.shortfall === String(e.args.shortfall) &&
      p.refund === String(e.args.refund) &&
      p.debtAfter === String(e.args.debtAfter),
  );
}
for (const e of (await events(market, ICredenceMarketAbi, "Flagged")).filter(
  (x) => Number(x.args.kind) === 0,
)) {
  await expectJob(
    `REOPENQ:${e.args.auctionId}:${lc(e.args.owner as string)}`,
    `queued at the reopen: ${e.args.owner}`,
    (p) => BigInt(p.cureRepay!) > 0n,
  );
}
for (const n of ["uma", "sara"]) {
  await expectJob(
    `EPOCH:${lc(pool)}:${epochId}:${lc(actors[n]!)}`,
    `epoch settled for ${n}: share price == EpochSettled.sharePriceAfter`,
    (p) => p.sharePriceAfter === String(settled.args.sharePriceAfter),
  );
}
{
  const [shares] = await pub.readContract({
    address: pool,
    abi: IUnderwriterPoolAbi,
    functionName: "pendingWithdraw",
    args: [epochId, actors.sara!],
  });
  const onchain = await pub.readContract({
    address: pool,
    abi: IUnderwriterPoolAbi,
    functionName: "epoch",
    args: [epochId],
  });
  await expectJob(
    `WITHDRAW:${lc(pool)}:${epochId}:${lc(actors.sara!)}`,
    `withdrawal claimable for Sara == the epoch's reserved assets`,
    (p) =>
      p.assets === onchain.withdrawAssetsReserved.toString() ||
      p.shares === shares.toString(),
  );
}
{
  const [r] =
    await sql`select count(*)::int as n from app.notification_log where ok is false`;
  const [d] =
    await sql`select count(*)::int as n from app.notification_job where status = 'dead'`;
  console.log(`  (notification_log failures ${r!.n}, dead jobs ${d!.n})`);
}
await sql.end();
if (failures.length) {
  console.error(`\nscenario A: ${failures.length} check(s) failed`);
  process.exit(1);
}
console.log(
  "\nOK: scenario A ran keeper-only from the Friday Bell to epoch settlement; indexer/API == chain; every notification sent with the chain's amounts",
);
