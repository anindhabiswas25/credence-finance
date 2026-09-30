// credence-notifier: consumes app.notification_job. Wakes on LISTEN notification_job (insert trigger)
// and polls every NOTIFIER_POLL_MS as a safety net. Serves /healthz, /readyz and /metrics.
import { createServer } from "node:http";
import { chainName, loadConfig, type ChainScanConfig } from "./config.ts";
import { resolveLoanToken } from "./loan.ts";
import { log } from "./log.ts";
import { createMetrics } from "./metrics.ts";
import { connect } from "./queue.ts";
import { runOnce } from "./worker.ts";
import { labelsFromBook, scan, type Labels, type Units } from "./producer.ts";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cfg = loadConfig();
const sql = connect(cfg.databaseUrl, cfg.batch + 2);
const metrics = createMetrics();
const deps = { sql, cfg: cfg.worker, log, metrics };
let ready = false;
let stopping = false;

log.info(
  {
    worker: cfg.workerId,
    email: !!cfg.worker.email,
    push: !!cfg.worker.push,
    telegram: !!cfg.worker.telegram,
  },
  "notifier starting (a channel without credentials is disabled)",
);

async function sampleQueue() {
  const rows =
    await sql`select status, count(*)::int as n from app.notification_job
                         where status in ('pending', 'retry', 'sending', 'dead') group by status`;
  for (const s of ["pending", "retry", "sending", "dead"]) {
    metrics.queueDepth.set(
      { status: s },
      rows.find((r) => r.status === s)?.n ?? 0,
    );
  }
  const [o] =
    await sql`select extract(epoch from now() - min(run_at))::float8 as age from app.notification_job
                        where status in ('pending', 'retry') and run_at <= now()`;
  metrics.oldestDueSeconds.set(o?.age ?? 0);
}

let wake: () => void = () => {};
async function loop() {
  while (!stopping) {
    try {
      const n = await runOnce(deps, cfg.workerId, cfg.batch, cfg.lockTimeoutS);
      ready = true;
      if (n === cfg.batch) continue; // more waiting
      await sampleQueue();
    } catch (e) {
      ready = false;
      log.error({ err: String(e) }, "queue loop error");
    }
    await new Promise<void>((resolve) => {
      const t = setTimeout(resolve, cfg.pollMs);
      wake = () => {
        clearTimeout(t);
        resolve();
      };
    });
  }
}

await sql.listen("notification_job", () => wake());

// indexer-triggered events (auto-cover, reopen queue, auction settled, epoch settled, withdrawal claimable,
// corporate actions), one scan per chain (ADR-0014), each with its own window
async function scanLoop(c: ChainScanConfig) {
  if (!c.schema) return;
  const root = resolve(
    fileURLToPath(new URL(".", import.meta.url)),
    "../../..",
  );
  const tag = { chainId: c.chainId, chainName: chainName(c.chainId) };
  let labels: Labels | null = null;
  let units: Units | null = null;
  let since = BigInt(Math.floor(Date.now() / 1000) - cfg.scan.lookbackS);
  while (!stopping) {
    try {
      if (!labels || !units) {
        const book = JSON.parse(
          readFileSync(resolve(root, c.bookFile), "utf8"),
        );
        const loan = await resolveLoanToken(c, book);
        labels = labelsFromBook(book);
        units = {
          loanDecimals: loan.decimals,
          collateralDecimals: 18,
          loanSymbol: loan.symbol,
        };
        log.info({ ...tag, schema: c.schema, loan }, "scanning chain");
      }
      const r = await scan(sql, c.schema, since, labels, units, tag);
      since = r.maxTs; // inclusive: rows of the same second are re-read, their dedupe keys hold
      if (r.enqueued > 0)
        log.info(
          { ...tag, enqueued: r.enqueued },
          "indexer-triggered notifications enqueued",
        );
    } catch (e) {
      log.warn({ ...tag, err: String(e) }, "indexer scan failed");
    }
    await new Promise((r) => setTimeout(r, cfg.scan.everyMs));
  }
}
for (const c of cfg.scan.chains) void scanLoop(c);

createServer(async (req, res) => {
  if (req.url === "/healthz") return void res.writeHead(200).end("ok");
  if (req.url === "/readyz")
    return void res
      .writeHead(ready ? 200 : 503)
      .end(ready ? "ready" : "not ready");
  if (req.url === "/metrics") {
    res.writeHead(200, { "content-type": metrics.registry.contentType });
    return void res.end(await metrics.registry.metrics());
  }
  res.writeHead(404).end();
}).listen(cfg.port, () => log.info({ port: cfg.port }, "ops server listening"));

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, async () => {
    stopping = true;
    wake();
    await sql.end({ timeout: 5 });
    process.exit(0);
  });
}

await loop();
