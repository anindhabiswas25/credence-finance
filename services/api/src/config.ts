// API configuration from env (Build Guide §12.1 "indexer / api / notifier").
import { z } from "zod";

const Env = z.object({
  API_PORT: z.coerce.number().int().default(8787),
  DATABASE_URL: z.string().min(1),
  /** Ponder's views schema (`ponder start --views-schema`). */
  INDEXER_SCHEMA: z
    .string()
    .regex(/^[a-z_][a-z0-9_]*$/)
    .default("indexer"),
  /** Comma-separated CORS allowlist; the first entry is the public web origin. */
  API_PUBLIC_ORIGIN: z.string().default("http://localhost:3000"),
  CORS_ORIGINS: z.string().optional(),
  SIWE_DOMAIN: z.string().default("localhost:3000"),
  SIWE_CHAIN_ID: z.coerce.number().int().optional(),
  CHAIN_ID: z.coerce.number().int().default(412346),
  /** ADR-0014: the chains this API serves, `chainId:viewsSchema` comma-separated, e.g.
   * `46630:ix_46630,421614:ix_421614`. Default: CHAIN_ID with INDEXER_SCHEMA. */
  API_CHAINS: z.string().optional(),
  SESSION_SECRET: z
    .string()
    .min(32, "SESSION_SECRET must be at least 32 characters"),
  SESSION_TTL_S: z.coerce
    .number()
    .int()
    .default(7 * 24 * 3600),
  /** Optional RPC for ERC-1271 / ERC-6492 smart-wallet SIWE signatures. */
  RPC_URL: z.string().optional(),
  /** Comma-separated directories of ADR-0106 scenario-set files (relative to the repo root). */
  SCENARIO_DIRS: z
    .string()
    .default("calibration/out/scenarios,contracts/test/fixtures/risk"),
  /** Public URL of this API (email verification links). */
  API_PUBLIC_URL: z.string().url().default("http://localhost:8787"),
  /** Testnet self-service allowlist; refused on Arbitrum One whatever this says. */
  ALLOWLIST_ENABLED: z.enum(["0", "1"]).default("1"),
  ALLOWLIST_PER_IP_PER_HOUR: z.coerce.number().int().default(5),
  RATE_LIMIT_PER_MIN: z.coerce.number().int().default(120),
  RATE_LIMIT_AUTH_PER_MIN: z.coerce.number().int().default(20),
  /** OFF-03: comma-separated addresses of our reverse proxies; X-Forwarded-For is trusted only from them. */
  TRUSTED_PROXIES: z.string().default(""),
  NODE_ENV: z.string().default("development"),
});

export type ServedChain = { chainId: number; indexerSchema: string };

export type Config = {
  port: number;
  databaseUrl: string;
  /** This app's chain view (with one chain, the only one; `forChain` sets it per chain). */
  indexerSchema: string;
  /** ADR-0014: every served chain; the first is the default for chain-agnostic routes. */
  chains?: ServedChain[];
  /** SIWE accepts a message for any served chain. */
  siweChainIds?: number[];
  /** The served testnet chains a self-attestation allowlists on (never Arbitrum One). */
  allowlistChains?: number[];
  corsOrigins: string[];
  siweDomain: string;
  chainId: number;
  sessionSecret: string;
  sessionTtlS: number;
  rpcUrl?: string;
  scenarioDirs: string[];
  publicApiUrl: string;
  allowlistEnabled: boolean;
  allowlistPerIpPerHour: number;
  rateLimitPerMin: number;
  rateLimitAuthPerMin: number;
  /** OFF-03: peers whose X-Forwarded-For is trusted (empty: the socket address is the client). */
  trustedProxies?: string[];
  secureCookies: boolean;
};

/** `46630:ix_46630,421614:ix_421614` → served chains. */
export function parseChains(raw: string): ServedChain[] {
  const chains = raw
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean)
    .map((x) => {
      const [id, schema] = x.split(":");
      const chainId = Number(id);
      if (!Number.isInteger(chainId) || chainId <= 0)
        throw new Error(`API_CHAINS: bad chain id in ${x}`);
      const indexerSchema = schema ?? `ix_${chainId}`;
      if (!/^[a-z_][a-z0-9_]*$/.test(indexerSchema))
        throw new Error(`API_CHAINS: bad schema in ${x}`);
      return { chainId, indexerSchema };
    });
  if (chains.length === 0) throw new Error("API_CHAINS is empty");
  if (new Set(chains.map((c) => c.chainId)).size !== chains.length)
    throw new Error("API_CHAINS: duplicate chain id");
  return chains;
}

/** The config of one served chain's app (ADR-0014). */
export function forChain(c: Config, chainId: number): Config {
  const ch = (
    c.chains ?? [{ chainId: c.chainId, indexerSchema: c.indexerSchema }]
  ).find((x) => x.chainId === chainId);
  if (!ch) throw new Error(`chain ${chainId} is not served`);
  return { ...c, chainId, indexerSchema: ch.indexerSchema };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = Env.parse(env);
  const chains = e.API_CHAINS
    ? parseChains(e.API_CHAINS)
    : [
        {
          chainId: e.SIWE_CHAIN_ID ?? e.CHAIN_ID,
          indexerSchema: e.INDEXER_SCHEMA,
        },
      ];
  const origins = (e.CORS_ORIGINS ?? e.API_PUBLIC_ORIGIN)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    port: e.API_PORT,
    databaseUrl: e.DATABASE_URL,
    indexerSchema: chains[0]!.indexerSchema,
    chains,
    siweChainIds: chains.map((c) => c.chainId),
    allowlistChains:
      e.ALLOWLIST_ENABLED === "1"
        ? chains.map((c) => c.chainId).filter((id) => id !== 42161)
        : [],
    corsOrigins: origins,
    siweDomain: e.SIWE_DOMAIN,
    chainId: chains[0]!.chainId,
    sessionSecret: e.SESSION_SECRET,
    sessionTtlS: e.SESSION_TTL_S,
    rpcUrl: e.RPC_URL,
    publicApiUrl: e.API_PUBLIC_URL,
    allowlistEnabled:
      e.ALLOWLIST_ENABLED === "1" && chains.some((c) => c.chainId !== 42161),
    allowlistPerIpPerHour: e.ALLOWLIST_PER_IP_PER_HOUR,
    scenarioDirs: e.SCENARIO_DIRS.split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    rateLimitPerMin: e.RATE_LIMIT_PER_MIN,
    rateLimitAuthPerMin: e.RATE_LIMIT_AUTH_PER_MIN,
    trustedProxies: e.TRUSTED_PROXIES.split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
    secureCookies: e.NODE_ENV === "production",
  };
}
