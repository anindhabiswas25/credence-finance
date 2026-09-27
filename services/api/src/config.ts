// API configuration from env (Build Guide §12.1 "indexer / api / notifier").
import { z } from "zod";

const Env = z.object({
  API_PORT: z.coerce.number().int().default(8787),
  DATABASE_URL: z.string().min(1),
  /** Ponder's views schema (`ponder start --views-schema`). */
  INDEXER_SCHEMA: z.string().regex(/^[a-z_][a-z0-9_]*$/).default("indexer"),
  /** Comma-separated CORS allowlist; the first entry is the public web origin. */
  API_PUBLIC_ORIGIN: z.string().default("http://localhost:3000"),
  CORS_ORIGINS: z.string().optional(),
  SIWE_DOMAIN: z.string().default("localhost:3000"),
  SIWE_CHAIN_ID: z.coerce.number().int().optional(),
  CHAIN_ID: z.coerce.number().int().default(412346),
  SESSION_SECRET: z.string().min(32, "SESSION_SECRET must be at least 32 characters"),
  SESSION_TTL_S: z.coerce.number().int().default(7 * 24 * 3600),
  /** Optional RPC for ERC-1271 / ERC-6492 smart-wallet SIWE signatures. */
  RPC_URL: z.string().optional(),
  RATE_LIMIT_PER_MIN: z.coerce.number().int().default(120),
  RATE_LIMIT_AUTH_PER_MIN: z.coerce.number().int().default(20),
  NODE_ENV: z.string().default("development"),
});

export type Config = {
  port: number;
  databaseUrl: string;
  indexerSchema: string;
  corsOrigins: string[];
  siweDomain: string;
  chainId: number;
  sessionSecret: string;
  sessionTtlS: number;
  rpcUrl?: string;
  rateLimitPerMin: number;
  rateLimitAuthPerMin: number;
  secureCookies: boolean;
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = Env.parse(env);
  const origins = (e.CORS_ORIGINS ?? e.API_PUBLIC_ORIGIN).split(",").map((s) => s.trim()).filter(Boolean);
  return {
    port: e.API_PORT,
    databaseUrl: e.DATABASE_URL,
    indexerSchema: e.INDEXER_SCHEMA,
    corsOrigins: origins,
    siweDomain: e.SIWE_DOMAIN,
    chainId: e.SIWE_CHAIN_ID ?? e.CHAIN_ID,
    sessionSecret: e.SESSION_SECRET,
    sessionTtlS: e.SESSION_TTL_S,
    rpcUrl: e.RPC_URL,
    rateLimitPerMin: e.RATE_LIMIT_PER_MIN,
    rateLimitAuthPerMin: e.RATE_LIMIT_AUTH_PER_MIN,
    secureCookies: e.NODE_ENV === "production",
  };
}
