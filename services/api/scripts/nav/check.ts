// make nav-settlement-e2e (S4 G): drives the issuer and the solver bot, waits for the keeper, then asserts.
//   Phase 1: 8 NAV strikes of −0.45 % take Nia under HF 1 → J10 opens settlement S1 → the solver bot bids →
//            J10 finalizes it at the end of the 5-min window: FILLED.
//   Phase 2: the solver bot restarts in its no-bid profile; 5 more strikes take Omar under HF 1 → J10 opens S2 →
//            no bid → J10 finalizes: ADVANCED (the pool pays qty × floor and requests the redemption) → the
//            issuer fulfils it ("T+1": the next USBANK session on testnet, right away here) → J10 claims it.
// Then: no keeper tx reverted; every J10 step done once; /v1/settlements/{id} and /v1/pool/nav == the chain;
// nav_sold delivered to both borrowers with PositionSettled's amounts.
// Env: API, DATABASE_URL, SOLVER_BIN, SOLVER_KEY, RPC_URL, SCENARIO_DIR.
import { spawn, type ChildProcess } from "node:child_process";
import { openSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import postgres from "postgres";
import { parseAbi, type Address, type Hex } from "viem";
import {
  ICredenceMarketAbi,
  ISettlementAdapterAbi,
  IUnderwriterPoolAbi,
} from "@credence/sdk";
import { OUT, RPC, book, dev, pub, send, Erc20 } from "../scenario-a/lib.ts";
import { strike } from "./strike.ts";

const API = process.env.API ?? "http://127.0.0.1:18898";
const sql = postgres(process.env.DATABASE_URL!, { max: 2, onnotice: () => {} });
const actors = JSON.parse(
  readFileSync(resolve(OUT, "actors.json"), "utf8"),
) as Record<string, Address>;
const market = book.nav.market as Address;
const adapter = book.nav.settlement as Address;
const pool = book.nav.pool as Address;
const fund = book.tokens.tTBILL as Address;
const usdc = book.tokens.usdc as Address;
const nid = book.nav.markets.TBILL as Hex;
const tbill = book.assetIds.TBILL as Hex;
const t0 = Date.now();
const since = new Date(t0 - 120_000); // this run's rows only (the DB is shared with other runs)
const failures: string[] = [];
const ok = (cond: boolean, what: string) => {
  console.log(`${cond ? "  ok " : "FAIL "} ${what}`);
  if (!cond) failures.push(what);
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const lc = (a: string) => a.toLowerCase();
const mins = () => ((Date.now() - t0) / 60_000).toFixed(1);
async function until<T>(
  what: string,
  maxS: number,
  f: () => Promise<T | undefined | null | false>,
): Promise<T> {
  const end = Date.now() + maxS * 1000;
  for (;;) {
    const v = await f().catch(() => undefined);
    if (v) {
      console.log(`  ✓ ${what} (+${mins()} min)`);
      return v as T;
    }
    if (Date.now() > end)
      throw new Error(`timed out after ${maxS} s waiting for: ${what}`);
    await sleep(3_000);
  }
}
const j = async (path: string) => {
  const r = await fetch(`${API}${path}`);
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
  return (await r.json()) as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
};
const Clock = parseAbi(["function state(bytes32) view returns (uint8)"]);
const Fund = parseAbi([
  "function fulfillRedeem(uint256 requestId) returns (uint256)",
]);
const settlement = (id: bigint) =>
  pub.readContract({
    abi: ISettlementAdapterAbi,
    address: adapter,
    functionName: "settlement",
    args: [id],
  });
const lotOf = async (b: Address) =>
  (
    (await pub.readContract({
      abi: ICredenceMarketAbi,
      address: market,
      functionName: "position",
      args: [nid, b],
    })) as {
      auctionId: bigint;
    }
  ).auctionId;

// ── the solver bot, restarted per phase ──
let solver: ChildProcess | undefined;
function startSolver(bid: boolean) {
  const cfg = resolve(OUT, `solver-${bid ? "bid" : "nobid"}.json`);
  writeFileSync(
    cfg,
    JSON.stringify({
      solvers: [
        {
          name: bid ? "solver" : "solver-nobid",
          key: process.env.SOLVER_KEY,
          bid,
          premiumBps: 10,
        },
      ],
    }),
  );
  const log = openSync(
    resolve(OUT, `solver-${bid ? "bid" : "nobid"}.log`),
    "a",
  );
  solver = spawn(process.env.SOLVER_BIN!, [], {
    env: {
      ...process.env,
      RPC_URL: RPC,
      SOLVER_CONFIG: cfg,
      SOLVER_AUCTION: book.nav.solverAuction,
    },
    stdio: ["ignore", log, log],
  });
  console.log(
    `solver bot started (${bid ? "bids 0.1 % over the floor" : "no-bid profile"}), pid ${solver.pid}`,
  );
}
async function stopSolver() {
  if (!solver) return;
  solver.kill("SIGTERM");
  await new Promise((r) => solver!.once("exit", r));
  solver = undefined;
}
process.on("exit", () => solver?.kill("SIGKILL"));

try {
  await until(
    "TBILL clock REGULAR (keeper J1 poke + J10 completeReopen)",
    300,
    async () =>
      (await pub.readContract({
        abi: Clock,
        address: book.shared.clock,
        functionName: "state",
        args: [tbill],
      })) === 0,
  );

  // ── phase 1: solver fill ──
  console.log("── phase 1: 8 strikes of −0.45 %, solver bot bidding");
  startSolver(true);
  for (let i = 0; i < 8; i++) await strike({ "drop-bps": "45" });
  const s1 = await until(
    "J10 opened a settlement for Nia",
    240,
    async () => (await lotOf(actors.nia!)) || false,
  );
  await until(
    `the solver bot bid on settlement ${s1}`,
    240,
    async () =>
      (await settlement(s1)).status === 1 &&
      (
        await pub.getContractEvents({
          address: book.nav.solverAuction,
          abi: parseAbi([
            "event SolverBid(uint64 indexed id, address indexed solver, uint256 price)",
          ]),
          eventName: "SolverBid",
          args: { id: s1 },
          fromBlock: 0n,
        })
      ).length > 0,
  );
  await until(
    `J10 finalized settlement ${s1}: FILLED`,
    480,
    async () => (await settlement(s1)).status === 2,
  );

  // ── phase 2: no bid → pool advance → T+1 → claim ──
  console.log("── phase 2: solver bot in its no-bid profile, 5 more strikes");
  await stopSolver();
  startSolver(false);
  for (let i = 0; i < 5; i++) await strike({ "drop-bps": "45" });
  const s2 = await until("J10 opened a settlement for Omar", 240, async () => {
    const id = await lotOf(actors.omar!);
    return id && id !== s1 ? id : false;
  });
  const adv = await until(
    `J10 finalized settlement ${s2}: ADVANCED (pool fallback)`,
    480,
    async () => {
      const s = await settlement(s2);
      return s.status === 3 ? s : false;
    },
  );
  console.log(`issuer: fulfillRedeem(${adv.requestId}) (T+1)`);
  await send(dev, {
    abi: Erc20,
    address: usdc,
    functionName: "mint",
    args: [dev.account.address, 10n ** 12n],
  });
  await send(dev, {
    abi: Erc20,
    address: usdc,
    functionName: "approve",
    args: [fund, 10n ** 12n],
  });
  await send(dev, {
    abi: Fund,
    address: fund,
    functionName: "fulfillRedeem",
    args: [adv.requestId],
  });
  await until(
    "J10 claimed the redemption (pool claims outstanding = 0)",
    240,
    async () =>
      (await pub.readContract({
        abi: IUnderwriterPoolAbi,
        address: pool,
        functionName: "redemptionClaimsOutstanding",
      })) === 0n,
  );
  await stopSolver();

  // ── checks ──
  console.log("── checks");
  const [rev] =
    await sql`select count(*)::int as n from ops.keeper_tx where status = 'reverted' and submitted_at >= ${since}`;
  ok(rev!.n === 0, `no keeper tx reverted (${rev!.n})`);
  const dups =
    await sql`select job_key, count(*)::int as n from ops.keeper_tx where status = 'mined' and job_key like 'J10:%' and submitted_at >= ${since}
                          group by job_key having count(*) > 1`;
  ok(dups.length === 0, `no J10 step mined twice ${JSON.stringify(dups)}`);
  for (const [step, n] of [
    ["open", 2],
    ["finalize", 2],
    ["claim", 1],
  ] as const) {
    const [r] =
      await sql`select count(*)::int as n from ops.keeper_job where key like ${`J10:%:${step}`} and status = 'done' and created_at >= ${since}`;
    ok(r!.n === n, `J10 ${step}: ${r!.n} done (want ${n})`);
  }

  await sleep(20_000); // the indexer and the notifier's scan catch up
  for (const id of [s1, s2]) {
    const c = await settlement(id);
    const a = await until(
      `/v1/settlements/${id} indexed as ${c.status === 2 ? "filled" : "advanced"}`,
      120,
      async () => {
        const b = await j(`/v1/settlements/${id}`);
        return b.status !== "open" && b.outcome?.positionsSettled != null
          ? b
          : false;
      },
    );
    ok(
      a.qty === c.qty.toString() &&
        a.floorPrice === c.floorPrice.toString() &&
        a.endsAt === Number(c.endsAt) &&
        a.outcome.price === c.price.toString() &&
        a.outcome.proceeds.raw === c.proceeds.toString() &&
        (a.outcome.redemptionRequestId ?? "0") === c.requestId.toString() &&
        lc(a.outcome.solver ?? "0x0000000000000000000000000000000000000000") ===
          lc(c.solver),
      `/v1/settlements/${id} == adapter.settlement(${id}): ${a.status}, qty ${c.qty}, floor ${c.floorPrice}, price ${c.price}, proceeds ${c.proceeds}, request ${c.requestId}`,
    );
  }
  {
    const p = await j("/v1/pool/nav");
    const claims = p.redemptionClaims ?? p.claims;
    const item = claims?.items?.find(
      (x: { requestId: string }) => x.requestId === adv.requestId.toString(),
    );
    const [claimed] = await pub.getContractEvents({
      address: pool,
      abi: IUnderwriterPoolAbi,
      eventName: "RedemptionClaimed",
      args: { requestId: adv.requestId },
      fromBlock: 0n,
    });
    ok(
      !!item &&
        item.status === "claimed" &&
        !!claimed &&
        item.assets.raw === String(claimed.args.assets) &&
        claims.outstanding === 0,
      `/v1/pool/nav redemption claim ${adv.requestId}: ${item?.status}, assets ${item?.assets?.raw} == RedemptionClaimed ${claimed?.args.assets}`,
    );
  }
  const settled = await pub.getContractEvents({
    address: market,
    abi: ICredenceMarketAbi,
    eventName: "PositionSettled",
    fromBlock: 0n,
  });
  for (const [n, id] of [
    ["nia", s1],
    ["omar", s2],
  ] as const) {
    const e = settled.find(
      (x) =>
        lc(x.args.borrower as string) === lc(actors[n]!) &&
        x.args.auctionId === id,
    );
    const key = `NAVSOLD:${id}:${lc(actors[n]!)}`;
    const r = await until(`nav_sold for ${n} sent`, 120, async () => {
      const [row] =
        await sql`select j.status, j.payload, (select count(*)::int from app.notification_log l where l.job_id = j.id and l.ok) as sent
                                from app.notification_job j where j.dedupe_key = ${key}`;
      return row && row.status === "sent" ? row : false;
    }).catch(() => undefined);
    const p = (r?.payload ?? {}) as Record<string, string>;
    ok(
      !!e &&
        !!r &&
        r.sent >= 1 &&
        p.collateralSold === String(e.args.collateralSold) &&
        p.proceeds === String(e.args.proceeds) &&
        p.penalty === String(e.args.penalty) &&
        p.shortfall === String(e.args.shortfall) &&
        p.refund === String(e.args.refund) &&
        p.debtAfter === String(e.args.debtAfter),
      `nav_sold [${key}] ${r ? `${r.status}, ${r.sent} deliveries` : "missing"}: amounts == PositionSettled`,
    );
  }
  const [dead] =
    await sql`select count(*)::int as n from app.notification_job where status = 'dead'
                             and address in (${Buffer.from(actors.nia!.slice(2).toLowerCase(), "hex")}, ${Buffer.from(actors.omar!.slice(2).toLowerCase(), "hex")})`;
  ok(dead!.n === 0, `no dead notification jobs (${dead!.n})`);
} finally {
  await stopSolver();
  await sql.end();
}
console.log(`\nG took ${mins()} min after seeding`);
if (failures.length) {
  console.error(`nav-settlement-e2e: ${failures.length} check(s) failed`);
  process.exit(1);
}
console.log(
  "OK: NAV settlement keeper-only after seeding: a solver fill, a pool advance with its T+1 claim; indexer/API == chain; nav_sold sent with the chain's amounts",
);
