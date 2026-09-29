// Node 24 entry point: `node src/server.ts` (type stripping) or `node dist/server.js`.
import { serve } from "@hono/node-server";
import { createPublicClient, http } from "viem";
import { createApp, toAssetId } from "./app.ts";
import { StreamHub, attachStream } from "./stream.ts";
import { SESSION_COOKIE, verifySession } from "./session.ts";
import { assetVenues, boundariesAfter, loadCalendars } from "./calendar.ts";
import { loadConfig } from "./config.ts";
import { pgRepos } from "./repo.ts";
import { log } from "./log.ts";
import { createMetrics } from "./metrics.ts";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { viemChainReader } from "./chain.ts";
import { loadSetStore } from "./sets.ts";
import { ready as riskReady } from "@credence/sdk/risk";

const config = loadConfig();
const repos = pgRepos(config.databaseUrl, config.indexerSchema);
const calendars = loadCalendars();
const venues = assetVenues(
  (
    process.env.ASSETS ??
    "NVDA:XNAS,AAPL:XNAS,TSLA:XNAS,COIN:XNAS,MSFT:XNAS,SPY:ARCX"
  )
    .split(",")
    .concat("TBILL:USBANK"),
);
await riskReady;
const repoRoot = resolve(
  fileURLToPath(new URL(".", import.meta.url)),
  "../../..",
);
const publicClient = config.rpcUrl
  ? createPublicClient({ transport: http(config.rpcUrl) })
  : undefined;
const app = createApp({
  config,
  clock: repos.clock,
  auth: repos.auth,
  metrics: createMetrics(),
  core: repos.core,
  rt: repos.rt,
  settlement: repos.settlement,
  me: repos.me,
  chain: publicClient ? viemChainReader(publicClient) : undefined,
  sets: loadSetStore(config.scenarioDirs.map((d) => resolve(repoRoot, d))),
  publicClient,
  nextBoundaries: (id, now) => {
    const v = venues.get(id);
    const s = v ? calendars.get(v) : undefined;
    return s ? boundariesAfter(s, now) : undefined;
  },
});

const hub = new StreamHub(repos.stream, toAssetId, {
  pollMs: Number(process.env.STREAM_POLL_MS ?? 1000),
  batch: 500,
  maxAssets: 100,
});
// bell:<owner> needs the SIWE session of that owner: the upgrade request's session cookie
const injectWebSocket = await attachStream(app, hub, async (cookie) => {
  const raw = cookie
    ?.split(";")
    .map((x) => x.trim())
    .find((x) => x.startsWith(`${SESSION_COOKIE}=`))
    ?.slice(SESSION_COOKIE.length + 1);
  const sid = verifySession(
    config.sessionSecret,
    raw ? decodeURIComponent(raw) : undefined,
  );
  return sid
    ? (await repos.auth.getSession(sid, new Date()))?.address
    : undefined;
});
hub.start((err) => log.warn({ err: String(err) }, "stream poll failed"));

const server = serve({ fetch: app.fetch, port: config.port }, (info) => {
  log.info(
    {
      port: info.port,
      indexerSchema: config.indexerSchema,
      corsOrigins: config.corsOrigins,
    },
    "credence-api listening",
  );
});

injectWebSocket(server);

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    hub.stop();
    server.close();
    void repos.close().then(() => process.exit(0));
  });
}
