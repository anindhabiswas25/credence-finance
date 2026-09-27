// credence-notifier: consumes app.notification_job. Wakes on LISTEN notification_job (insert trigger)
// and polls every NOTIFIER_POLL_MS as a safety net. Serves /healthz, /readyz and /metrics.
import { createServer } from "node:http";
import { loadConfig } from "./config.ts";
import { log } from "./log.ts";
import { createMetrics } from "./metrics.ts";
import { connect } from "./queue.ts";
import { runOnce } from "./worker.ts";

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
