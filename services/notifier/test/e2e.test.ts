// Notifier e2e on Postgres (skipped unless TEST_DATABASE_URL is set; run with `make notifier-e2e`).
//
// Scenario A's Friday Bell heads-up for Priya (G-10, NVDA) and Maya (G-11, TSLA): the payloads are
// computed by risk-cli (the engine's own math), enqueued with dedupe keys, and delivered by the real
// worker through email (Resend API), VAPID Web Push and Telegram, all served by a local HTTP server
// that stands in for the providers. The push payload is decrypted with the subscriber's key.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { pino } from "pino";
import postgres from "postgres";
import webpush from "web-push";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { connect, enqueue, type Sql } from "../src/queue.ts";
import { runOnce, type WorkerConfig } from "../src/worker.ts";
import { MAYA, PRIYA, pushSubscriber } from "./fixtures.ts";

const DB = process.env.TEST_DATABASE_URL;
const ROOT = join(import.meta.dirname, "../../..");
const log = pino({ level: "silent" });

const riskCli = (cmd: string, input: object): Record<string, string> => {
  const bin = process.env.RISK_CLI ?? join(ROOT, "target/be/debug/risk-cli");
  return JSON.parse(
    execFileSync(bin, [cmd], { input: JSON.stringify(input) }).toString(),
  );
};

/** Unit-variance t₃ mid-point quantiles in thousandths of σ (the G-22 stand-in set), ascending. */
function t3Set(n: number): number[] {
  const s3 = Math.sqrt(3);
  const cdf = (t: number) =>
    0.5 + (t / (s3 * (1 + (t * t) / 3)) + Math.atan(t / s3)) / Math.PI;
  const out: number[] = [];
  for (let k = 0; k < n; k++) {
    const p = (k + 0.5) / n;
    let [lo, hi] = [-1e6, 1e6];
    for (let i = 0; i < 200; i++) {
      const mid = (lo + hi) / 2;
      if (cdf(mid) < p) lo = mid;
      else hi = mid;
    }
    out.push(
      Math.max(
        -32768,
        Math.min(32767, Math.round(((lo + hi) / 2 / s3) * 1000)),
      ),
    );
  }
  return out;
}

interface Hit {
  path: string;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}

async function providers() {
  const hits: Hit[] = [];
  const failures = new Map<string, number>(); // path substring → remaining 503s
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      const path = req.url ?? "";
      hits.push({ path, headers: req.headers, body });
      for (const [k, n] of failures) {
        const text = body.toString();
        if ((path.includes(k) || text.includes(k)) && n > 0) {
          failures.set(k, n - 1);
          return void res.writeHead(503).end("try later");
        }
      }
      if (path.startsWith("/resend/emails"))
        return void res
          .writeHead(200)
          .end(JSON.stringify({ id: `re_${hits.length}` }));
      if (path.startsWith("/push/gone"))
        return void res.writeHead(410).end("gone");
      if (path.startsWith("/push/"))
        return void res.writeHead(201, { location: `/m/${hits.length}` }).end();
      if (path.includes("/sendMessage"))
        return void res
          .writeHead(200)
          .end(
            JSON.stringify({ ok: true, result: { message_id: hits.length } }),
          );
      res.writeHead(404).end();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { server, base, hits, failures };
}

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const buf = (a: string) => Buffer.from(a.slice(2), "hex");

describe.skipIf(!DB)("notifier e2e (Postgres)", () => {
  let admin: Sql;
  let sql: Sql;
  let dbName: string;
  let p: Awaited<ReturnType<typeof providers>>;
  let cfg: WorkerConfig;
  const subs = new Map<string, ReturnType<typeof pushSubscriber>>();
  const BELL = Math.floor(Date.now() / 1000) + 2 * 3600; // T−2h
  const PRIYA_ADDR = addr(0xa1);
  const MAYA_ADDR = addr(0xa2);

  beforeAll(async () => {
    admin = postgres(DB!, { max: 1, onnotice: () => {} });
    dbName = `credence_notifier_e2e_${Date.now()}`;
    await admin.unsafe(`create database ${dbName}`);
    const url = new URL(DB!);
    url.pathname = `/${dbName}`;
    sql = connect(url.toString(), 10);
    const dir = join(ROOT, "infra/db/migrations");
    for (const f of readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .sort()) {
      const up = readFileSync(join(dir, f), "utf8").split(
        "-- migrate:down",
      )[0]!;
      await sql.unsafe(up);
    }
    p = await providers();
    const vapid = webpush.generateVAPIDKeys();
    cfg = {
      email: {
        apiKey: "re_test",
        apiUrl: `${p.base}/resend`,
        from: "Credence <alerts@credence.finance>",
      },
      push: {
        publicKey: vapid.publicKey,
        privateKey: vapid.privateKey,
        subject: "mailto:ops@credence.finance",
      },
      telegram: { botToken: "123:test", apiUrl: `${p.base}/tg` },
      webOrigin: "https://testnet.credence.finance",
      maxAttempts: 3,
      backoffBaseS: 0.01,
      backoffMaxS: 0.05,
      pushTtlS: 3600,
    };
    const account = async (
      a: string,
      email: string,
      tg: string | null,
      pushNames: string[],
    ) => {
      await sql`insert into app.account (address, email, email_verified_at, telegram_chat_id)
                values (${buf(a)}, ${email}, now(), ${tg})`;
      for (const n of pushNames) {
        const s = pushSubscriber(`${p.base}/push/${n}`);
        subs.set(n, s);
        await sql`insert into app.push_subscription (address, endpoint, p256dh, auth)
                  values (${buf(a)}, ${s.sub.endpoint}, ${s.sub.p256dh}, ${s.sub.auth})`;
      }
    };
    await account(PRIYA_ADDR, "priya@example.com", "1001", ["priya"]);
    await account(MAYA_ADDR, "maya@example.com", null, ["maya", "gone"]);
  }, 60_000);

  afterAll(async () => {
    await sql?.end();
    if (admin && dbName)
      await admin.unsafe(`drop database if exists ${dbName} with (force)`);
    await admin?.end();
    p?.server.close();
  });

  const drain = async (worker = "w1") => {
    for (let i = 0; i < 50; i++) {
      const n = await runOnce({ sql, cfg, log }, worker, 20, 120);
      const { due } = (
        await sql<
          { due: number }[]
        >`select count(*)::int as due from app.notification_job where status in ('pending', 'retry')`
      )[0]!;
      if (n === 0 && due === 0) return;
      if (n === 0) await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("queue did not drain");
  };

  const status = async (key: string) =>
    (
      await sql`select status, attempts, delivered_channels, failed_channels, last_error from app.notification_job where dedupe_key = ${key}`
    )[0]!;

  it("delivers the scenario A Bell heads-up with exact amounts by email, push and Telegram", async () => {
    // ── payloads from the engine (risk-cli) ──
    const priyaCures = riskCli("cures", {
      debtProjected: "67028990000",
      qty: "500000000000000000000",
      price: "180000000000000000000",
      safeLtv: PRIYA.safeLtv,
    });
    const mayaCures = riskCli("cures", {
      debtProjected: "55535100000",
      qty: "300000000000000000000",
      price: "250000000000000000000",
      safeLtv: MAYA.safeLtv,
    });
    expect([priyaCures.repay, priyaCures.addCollateral]).toEqual([
      PRIYA.cureRepay,
      PRIYA.cureCollateral,
    ]);
    expect([mayaCures.repay, mayaCures.addCollateral]).toEqual([
      MAYA.cureRepay,
      MAYA.cureCollateral,
    ]);
    // Maya: auto-cover off → pre-close lot at R_pre = 99% of V, λ_pre 1% (R-06, F-4.5b)
    const mayaLot = riskCli("preclose-lot", {
      debt: "55535100000",
      qty: "300000000000000000000",
      valuation: "250000000000000000000",
      reserve: "247500000000000000000",
      targetLtv: MAYA.safeLtv,
      lambdaPre: "10000000000000000",
    }).x!;
    // Maya's live premium quote (t₃ stand-in set, σ 6%, weekend τ = 3/365, u = 0); Priya's is the doc's
    // $35.95, injected as R-22 prescribes for scenario tests
    const mayaQuote = riskCli("quote-cover", {
      set: t3Set(10_000),
      sigma: "60000000000000000",
      kappa: "30000000000000000",
      collateralValue: "75000000000",
      debtProjected: "55535100000",
      closureDays: 3,
      theta: "1000000000000000000",
      costOfCap: "150000000000000000",
      eta: "4000000000000000000",
      beta: "975000000000000000",
    }).premium!;
    const common = {
      closureId: "12",
      closureType: 2,
      stage: "T-2h",
      bellAt: BELL,
      expiresAt: BELL,
      loanDecimals: 6,
      collateralDecimals: 18,
    };
    const priya = {
      ...common,
      marketId: "0x01",
      asset: "NVDA",
      token: "tNVDA",
      cureRepay: priyaCures.repay,
      cureCollateral: priyaCures.addCollateral,
      ltv: PRIYA.ltv,
      safeLtv: PRIYA.safeLtv,
      premium: "35950000",
      default: { kind: "autoCover" },
    };
    const maya = {
      ...common,
      marketId: "0x02",
      asset: "TSLA",
      token: "tTSLA",
      cureRepay: mayaCures.repay,
      cureCollateral: mayaCures.addCollateral,
      ltv: MAYA.ltv,
      safeLtv: MAYA.safeLtv,
      premium: mayaQuote,
      default: { kind: "precloseSale", saleQty: mayaLot },
    };
    const kP = `J2:12:${PRIYA_ADDR}:T-2h`;
    const kM = `J2:12:${MAYA_ADDR}:T-2h`;
    expect(
      await enqueue(sql, {
        dedupeKey: kP,
        address: PRIYA_ADDR,
        event: "bell_headsup",
        payload: priya,
      }),
    ).not.toBeNull();
    expect(
      await enqueue(sql, {
        dedupeKey: kM,
        address: MAYA_ADDR,
        event: "bell_headsup",
        payload: maya,
      }),
    ).not.toBeNull();
    // the keeper re-running J2 is deduplicated
    expect(
      await enqueue(sql, {
        dedupeKey: kP,
        address: PRIYA_ADDR,
        event: "bell_headsup",
        payload: priya,
      }),
    ).toBeNull();

    // Priya's first email attempt hits a Resend 503: retried, without re-sending push or Telegram
    p.failures.set("priya@example.com", 1);
    await drain();

    const sP = await status(kP);
    expect(sP.status).toBe("sent");
    expect(sP.attempts).toBe(2);
    expect([...sP.delivered_channels].sort()).toEqual([
      "email",
      "push",
      "telegram",
    ]);
    const sM = await status(kM);
    expect(sM.status).toBe("sent");
    expect([...sM.delivered_channels].sort()).toEqual(["email", "push"]); // Maya has no Telegram

    // ── email (Resend) ──
    const emails = p.hits
      .filter((h) => h.path === "/resend/emails")
      .map((h) => ({ h, b: JSON.parse(h.body.toString()) }));
    const pe = emails.filter((e) => e.b.to[0] === "priya@example.com");
    expect(pe).toHaveLength(2); // the 503, then the delivery
    expect(pe[0]!.h.headers["idempotency-key"]).toBe(`${kP}:email`);
    expect(pe[1]!.b.text).toContain(
      "Your NVDA loan is above this weekend's safe LTV (74.48% vs 71.26%). Before ",
    );
    expect(pe[1]!.b.text).toContain(
      "repay $2,896.78, or add 22.585 tNVDA, or buy Gap Cover for $35.95.",
    );
    expect(pe[1]!.b.text).toContain(
      "If you do nothing, auto-cover will add $35.95 to your debt.",
    );
    const me = emails.filter((e) => e.b.to[0] === "maya@example.com");
    expect(me).toHaveLength(1);
    expect(me[0]!.b.text).toContain("(74.05% vs 62.68%)");
    expect(me[0]!.b.text).toContain(
      "repay $8,527.09, or add 54.419 tTSLA, or buy Gap Cover for $",
    );
    expect(me[0]!.b.text).toMatch(
      /If you do nothing, \d+\.\d{4} tTSLA will be sold in the pre-close sale at the Bell, because auto-cover is off\./,
    );

    // ── push: exactly one per subscriber, decryptable, with the same amounts ──
    const pushes = (n: string) => p.hits.filter((h) => h.path === `/push/${n}`);
    expect(pushes("priya")).toHaveLength(1);
    const pp = subs.get("priya")!.decrypt(pushes("priya")[0]!.body) as {
      title: string;
      body: string;
    };
    expect(pp.title).toMatch(/^NVDA: act before \w{3} \d\d:\d\d ET$/);
    expect(pp.body).toContain(
      "repay $2,896.78, or add 22.585 tNVDA, or buy Gap Cover for $35.95",
    );
    const mp = subs.get("maya")!.decrypt(pushes("maya")[0]!.body) as {
      body: string;
    };
    expect(mp.body).toContain("repay $8,527.09, or add 54.419 tTSLA");
    // the 410 subscription was removed
    expect(pushes("gone")).toHaveLength(1);
    const { n } = (
      await sql<
        { n: number }[]
      >`select count(*)::int as n from app.push_subscription where endpoint like '%/push/gone'`
    )[0]!;
    expect(n).toBe(0);

    // ── Telegram ──
    const tg = p.hits.filter((h) => h.path === "/tg/bot123:test/sendMessage");
    expect(tg).toHaveLength(1);
    expect(JSON.parse(tg[0]!.body.toString())).toMatchObject({
      chat_id: "1001",
    });

    // ── notification_log ──
    const logs =
      await sql`select channel, ok, attempt from app.notification_log l join app.notification_job j on j.id = l.job_id
                           where j.dedupe_key = ${kP} order by l.id`;
    expect(logs.map((l) => `${l.channel}:${l.ok}:${l.attempt}`)).toEqual([
      "email:false:1",
      "push:true:1",
      "telegram:true:1",
      "email:true:2",
    ]);
  });

  it("dead-letters after max attempts, expires late heads-ups, rejects bad payloads", async () => {
    const a = addr(0xb1);
    await sql`insert into app.account (address, email, email_verified_at) values (${buf(a)}, 'down@example.com', now())`;
    p.failures.set("down@example.com", 99);
    await enqueue(sql, {
      dedupeKey: "dead-1",
      address: a,
      event: "bell_outcome",
      payload: {
        marketId: "0x1",
        asset: "NVDA",
        token: "tNVDA",
        closureId: "1",
        outcome: "autoCover",
        premium: "35950000",
        newLtv: "745000000000000000",
      },
    });
    await enqueue(sql, {
      dedupeKey: "late-1",
      address: PRIYA_ADDR,
      event: "bell_headsup",
      payload: {
        marketId: "0x1",
        asset: "NVDA",
        token: "tNVDA",
        closureId: "1",
        closureType: 2,
        stage: "T-26h",
        bellAt: 1_700_000_000,
        expiresAt: 1_700_000_000,
        ...PRIYA,
        premium: "1",
        default: { kind: "autoCover" },
      },
    });
    await enqueue(sql, {
      dedupeKey: "bad-1",
      address: PRIYA_ADDR,
      event: "bell_headsup",
      payload: { asset: "NVDA" },
    });
    await enqueue(sql, {
      dedupeKey: "none-1",
      address: addr(0xb2),
      event: "bell_headsup",
      payload: {
        marketId: "0x1",
        asset: "NVDA",
        token: "tNVDA",
        closureId: "1",
        closureType: 2,
        stage: "T-2h",
        bellAt: BELL,
        ...PRIYA,
        premium: "1",
        default: { kind: "autoCover" },
      },
    });
    const before = p.hits.length;
    await drain();
    const dead = await status("dead-1");
    expect([dead.status, dead.attempts]).toEqual(["dead", 3]);
    expect(dead.last_error).toContain("resend 503");
    expect((await status("late-1")).status).toBe("expired");
    expect((await status("bad-1")).status).toBe("dead");
    expect((await status("bad-1")).last_error).toContain("bad payload");
    expect((await status("none-1")).status).toBe("skipped");
    // only the three failing Resend calls reached a provider
    expect(p.hits.slice(before).map((h) => h.path)).toEqual(
      Array(3).fill("/resend/emails"),
    );
  });

  it("two workers share the queue without double delivery; a crashed worker's job is reclaimed", async () => {
    const a = addr(0xc1);
    await sql`insert into app.account (address, telegram_chat_id) values (${buf(a)}, '555')`;
    const before = p.hits.length;
    for (let i = 0; i < 30; i++) {
      await enqueue(sql, {
        dedupeKey: `many-${i}`,
        address: a,
        event: "bell_outcome",
        payload: {
          marketId: "0x1",
          asset: "NVDA",
          token: "tNVDA",
          closureId: String(i),
          outcome: "autoCover",
          premium: "1000000",
          newLtv: "700000000000000000",
        },
      });
    }
    // a job stuck in `sending` by a worker that died 10 minutes ago
    await enqueue(sql, {
      dedupeKey: "stuck-1",
      address: a,
      event: "bell_outcome",
      payload: {
        marketId: "0x1",
        asset: "NVDA",
        token: "tNVDA",
        closureId: "99",
        outcome: "autoCover",
        premium: "1000000",
        newLtv: "700000000000000000",
      },
    });
    await sql`update app.notification_job set status = 'sending', attempts = 1, locked_at = now() - interval '10 minutes', locked_by = 'dead-worker'
              where dedupe_key = 'stuck-1'`;
    await Promise.all([drain("w1"), drain("w2")]);
    const sent = p.hits
      .slice(before)
      .filter((h) => h.path.includes("/sendMessage"));
    expect(sent).toHaveLength(31);
    const { n } = (
      await sql<
        { n: number }[]
      >`select count(*)::int as n from app.notification_job where dedupe_key like 'many-%' and status = 'sent'`
    )[0]!;
    expect(n).toBe(30);
    expect((await status("stuck-1")).status).toBe("sent");
  });
});
