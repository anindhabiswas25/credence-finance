// Node 24 entry point: `node src/server.ts` (type stripping) or `node dist/server.js`.
import { serve } from "@hono/node-server";
import { createPublicClient, http } from "viem";
import { createApp } from "./app.ts";
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
  (process.env.ASSETS ?? "NVDA:XNAS,AAPL:XNAS,TSLA:XNAS,COIN:XNAS,MSFT:XNAS,SPY:ARCX").split(",").concat("TBILL:USBANK"),
);
await riskReady;
const repoRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../..");
const publicClient = config.rpcUrl ? createPublicClient({ transport: http(config.rpcUrl) }) : undefined;
const app = createApp({
  config,
  clock: repos.clock,
  auth: repos.auth,
  metrics: createMetrics(),
  core: repos.core,
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

const server = serve({ fetch: app.fetch, port: config.port }, (info) => {
  log.info({ port: info.port, indexerSchema: config.indexerSchema, corsOrigins: config.corsOrigins }, "credence-api listening");
});

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    server.close();
    void repos.close().then(() => process.exit(0));
  });
}
