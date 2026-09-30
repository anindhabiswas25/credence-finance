// Node 24 entry point: `node src/server.ts` (type stripping) or `node dist/server.js`.
import { serve } from "@hono/node-server";
import { createPublicClient, http } from "viem";
import { Hono } from "hono";
import { createApp, newLimiters, toAssetId } from "./app.ts";
import { createMultiChainApp } from "./multichain.ts";
import { StreamHub, attachStream } from "./stream.ts";
import { SESSION_COOKIE, verifySession } from "./session.ts";
import { assetVenues, boundariesAfter, loadCalendars } from "./calendar.ts";
import { forChain, loadConfig } from "./config.ts";
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
  const rpcUrl = env("RPC_URL");
  const publicClient = rpcUrl
    ? createPublicClient({ transport: http(rpcUrl) })
    : undefined;
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
  return sid
    ? (await shared.auth.getSession(sid, new Date()))?.address
    : undefined;
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
app.route("/", stream);
app.route("/", top);
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

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    for (const x of served) x.hub.stop();
    server.close();
    void Promise.all(
      [...new Set(served.map((x) => x.repos))].map((r) => r.close()),
    ).then(() => process.exit(0));
  });
}
