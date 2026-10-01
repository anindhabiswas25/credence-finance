// Node 24 entry point: `node src/server.ts` (type stripping) or `node dist/server.js`.
import { serve } from "@hono/node-server";
import { createPublicClient, fallback, http } from "viem";
import { Hono } from "hono";
import { createApp, newLimiters, toAssetId } from "./app.ts";
import { createMultiChainApp } from "./multichain.ts";
import { StreamHub, attachStream } from "./stream.ts";
import { SESSION_COOKIE, verifySession } from "./session.ts";
import { assetVenues, boundariesAfter, loadCalendars } from "./calendar.ts";
import { forChain, loadConfig } from "./config.ts";
import { readFileSync } from "node:fs";
import {
  opsAdmins,
  pgAppStream,
  pgInboxRepo,
  pgOpsRepo,
  webhookSecret,
} from "./inbox.ts";
import { pgRepos } from "./repo.ts";
import { log } from "./log.ts";
import { createMetrics } from "./metrics.ts";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { viemChainReader } from "./chain.ts";
import { loadSetStore } from "./sets.ts";
import { ready as riskReady } from "@credence/sdk/risk";

const config = loadConfig();
const chains = config.chains ?? [
  { chainId: config.chainId, indexerSchema: config.indexerSchema },
];
const single = chains.length === 1;
const calendars = loadCalendars();
await riskReady;
const repoRoot = resolve(
  fileURLToPath(new URL(".", import.meta.url)),
  "../../..",
);
const sets = loadSetStore(config.scenarioDirs.map((d) => resolve(repoRoot, d)));
const metrics = createMetrics();
const limiters = newLimiters(config);
// sessions, accounts and preferences are per address in one database: every chain's app shares them
const shared = pgRepos(config.databaseUrl, chains[0]!.indexerSchema);
// Amendment 2: the in-app inbox and ops alerts (one database for every chain)
const inbox = pgInboxRepo(shared.sql);
const ops = pgOpsRepo(shared.sql);
const admins = opsAdmins(process.env.OPS_ADMIN_ADDRESSES);
const secret = webhookSecret(process.env, (p) => readFileSync(p, "utf8"));
if (!secret)
  log.warn(
    "OPS_ALERT_WEBHOOK_SECRET not set: POST /v1/ops/alerts is not mounted",
  );

/** ADR-0014: one app per served chain, with its own indexer views, RPC (RPC_URL_<id>) and assets (ASSETS_<id>). */
const served = chains.map(({ chainId, indexerSchema }) => {
  const env = (k: string) =>
    process.env[`${k}_${chainId}`] ?? (single ? process.env[k] : undefined);
  const repos =
    indexerSchema === chains[0]!.indexerSchema
      ? shared
      : pgRepos(config.databaseUrl, indexerSchema);
  const venues = assetVenues(
    (
      env("ASSETS") ??
      process.env.ASSETS ??
      "NVDA:XNAS,AAPL:XNAS,TSLA:XNAS,COIN:XNAS,MSFT:XNAS,SPY:ARCX"
    )
      .split(",")
      .concat("TBILL:USBANK"),
  );
  // S5: RPC_URL_<id> is an ordered failover list (comma-separated), like the keeper's and the indexer's
  const rpcUrls = (env("RPC_URL") ?? "")
    .split(",")
    .map((u) => u.trim())
    .filter(Boolean);
  const publicClient =
    rpcUrls.length === 0
      ? undefined
      : createPublicClient({
          transport:
            rpcUrls.length === 1
              ? http(rpcUrls[0])
              : fallback(
                  rpcUrls.map((u) => http(u, { timeout: 5_000 })),
                  { rank: false, retryCount: 1 },
                ),
        });
  const app = createApp({
    config: forChain(config, chainId),
    clock: repos.clock,
    auth: shared.auth,
    metrics,
    core: repos.core,
    rt: repos.rt,
    settlement: repos.settlement,
    me: shared.me,
    chain: publicClient ? viemChainReader(publicClient) : undefined,
    sets,
    publicClient,
    limiters,
    inbox,
    ops,
    webhookSecret: secret,
    opsAdmins: admins,
    // OFF-04c: a logout ends that session's bell:<owner> streams on every chain's hub
    onLogout: (sid) => {
      for (const s of served) s.hub.dropSession(sid);
    },
    nextBoundaries: (id, now) => {
      const v = venues.get(id);
      const s = v ? calendars.get(v) : undefined;
      return s ? boundariesAfter(s, now) : undefined;
    },
  });
  // Amendment 2: inbox:<owner> for this chain (the default chain also gets account-level rows and ops)
  const source = {
    ...repos.stream,
    ...pgAppStream(shared.sql, chainId, chainId === chains[0]!.chainId),
  };
  const hub = new StreamHub(source, toAssetId, {
    pollMs: Number(process.env.STREAM_POLL_MS ?? 1000),
    batch: 500,
    maxAssets: 100,
  });
  hub.opsAdmins = admins;
  return { chainId, indexerSchema, repos, app, hub };
});

// bell:<owner> needs the SIWE session of that owner: the upgrade request's session cookie
const sessionOwner = async (cookie: string | undefined) => {
  const raw = cookie
    ?.split(";")
    .map((x) => x.trim())
    .find((x) => x.startsWith(`${SESSION_COOKIE}=`))
    ?.slice(SESSION_COOKIE.length + 1);
  const sid = verifySession(
    config.sessionSecret,
    raw ? decodeURIComponent(raw) : undefined,
  );
  const s = sid ? await shared.auth.getSession(sid, new Date()) : undefined;
  return s && sid ? { owner: s.address, session: sid } : undefined;
};
const hubs = new Map(served.map((s) => [String(s.chainId), s.hub]));
const top = createMultiChainApp(
  served.map((s) => ({ chainId: s.chainId, app: s.app })),
);
// the socket picks its chain with ?chain= (optional with one chain); registered before the dispatcher's catch-all
const stream = new Hono();
const injectWebSocket = await attachStream(
  stream,
  (chain) =>
    chain === undefined
      ? single
        ? served[0]!.hub
        : undefined
      : hubs.get(chain),
  sessionOwner,
  config.corsOrigins.map((o) => o.replace(/\/$/, "").toLowerCase()),
);
const app = new Hono();
// OFF-08: metrics never on the public port; they have their own listener (API_METRICS_ADDR, private by default)
app.all("/metrics", (c) =>
  c.json({ error: "not_found", message: "Not found" }, 404),
);
app.route("/", stream);
app.route("/", top);
// OFF-04c: an expired session's bell:<owner> streams end within STREAM_SESSION_CHECK_MS
const sessionCheck = setInterval(
  () => {
    for (const s of served)
      void s.hub.revalidate(
        async (sid) => !!(await shared.auth.getSession(sid, new Date())),
      );
  },
  Number(process.env.STREAM_SESSION_CHECK_MS ?? 30_000),
);
sessionCheck.unref();
for (const s of served)
  s.hub.start((err) =>
    log.warn({ chainId: s.chainId, err: String(err) }, "stream poll failed"),
  );

const server = serve({ fetch: app.fetch, port: config.port }, (info) => {
  log.info(
    {
      port: info.port,
      chains: chains.map((c) => `${c.chainId}:${c.indexerSchema}`),
      corsOrigins: config.corsOrigins,
    },
    "credence-api listening",
  );
});

injectWebSocket(server);

const metricsAddr = process.env.API_METRICS_ADDR ?? "127.0.0.1:9104";
const cut = metricsAddr.lastIndexOf(":");
const metricsApp = new Hono();
metricsApp.get("/metrics", async (c) =>
  c.text(await metrics.registry.metrics(), 200, {
    "content-type": metrics.registry.contentType,
  }),
);
const metricsServer = serve(
  {
    fetch: metricsApp.fetch,
    hostname: metricsAddr.slice(0, cut),
    port: Number(metricsAddr.slice(cut + 1)),
  },
  (info) =>
    log.info(
      { metrics: `${metricsAddr}`, port: info.port },
      "metrics listener",
    ),
);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    for (const x of served) x.hub.stop();
    server.close();
    metricsServer.close();
    void Promise.all(
      [...new Set(served.map((x) => x.repos))].map((r) => r.close()),
    ).then(() => process.exit(0));
  });
}
