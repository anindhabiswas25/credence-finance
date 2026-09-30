// Notifier configuration from env (Build Guide §12.1 "indexer / api / notifier").
// A channel whose credentials are missing is disabled (logged at start).
import { hostname } from "node:os";
import { z } from "zod";
import type { WorkerConfig } from "./worker.ts";

const Env = z.object({
  DATABASE_URL: z.string().min(1),
  NOTIFIER_PORT: z.coerce.number().int().default(9103),
  NOTIFIER_WORKER_ID: z
    .string()
    .default(`notifier-${hostname()}-${process.pid}`),
  NOTIFIER_BATCH: z.coerce.number().int().positive().default(20),
  NOTIFIER_POLL_MS: z.coerce.number().int().positive().default(1000),
  NOTIFIER_MAX_ATTEMPTS: z.coerce.number().int().positive().default(6),
  NOTIFIER_BACKOFF_BASE_S: z.coerce.number().positive().default(30),
  NOTIFIER_BACKOFF_MAX_S: z.coerce.number().positive().default(3600),
  NOTIFIER_LOCK_TIMEOUT_S: z.coerce.number().int().positive().default(120),
  NOTIFIER_PUSH_TTL_S: z.coerce
    .number()
    .int()
    .positive()
    .default(6 * 3600),
  API_PUBLIC_ORIGIN: z.string().default("http://localhost:3000"),
  /** Indexer-triggered events (producer.ts): Ponder's views schema; empty disables the scan. */
  INDEXER_SCHEMA: z
    .string()
    .regex(/^[a-z0-9_]*$/)
    .default("indexer"),
  NOTIFIER_SCAN_MS: z.coerce.number().int().positive().default(5000),
  NOTIFIER_SCAN_LOOKBACK_S: z.coerce.number().int().nonnegative().default(3600),
  CHAIN_ID: z.coerce.number().int().default(412346),
  /** ADR-0014: the chains this notifier scans, comma-separated (default: CHAIN_ID alone). Per chain:
   * INDEXER_SCHEMA_<id> (default `ix_<id>`; INDEXER_SCHEMA with one chain), DEPLOYMENTS_FILE_<id> (default
   * `deployments/<id>.json`; DEPLOYMENTS_FILE with one chain), LOAN_SYMBOL_<id> / LOAN_DECIMALS_<id>, and
   * RPC_URL_<id> to read them from the loan token instead. */
  NOTIFIER_CHAINS: z.string().optional(),
  DEPLOYMENTS_FILE: z.string().optional(),
  RESEND_API_KEY: z.string().optional(),
  RESEND_API_URL: z.string().default("https://api.resend.com"),
  NOTIFIER_EMAIL_FROM: z.string().default("Credence <alerts@credence.finance>"),
  VAPID_PUBLIC_KEY: z.string().optional(),
  VAPID_PRIVATE_KEY: z.string().optional(),
  VAPID_SUBJECT: z.string().default("mailto:ops@credence.finance"),
  TELEGRAM_BOT_TOKEN: z.string().optional(),
  TELEGRAM_API_URL: z.string().default("https://api.telegram.org"),
});

export interface Config {
  databaseUrl: string;
  port: number;
  workerId: string;
  batch: number;
  pollMs: number;
  lockTimeoutS: number;
  /** Indexer-triggered events (producer.ts), one scan per chain. */
  scan: {
    everyMs: number;
    lookbackS: number;
    chains: ChainScanConfig[];
  };
  worker: WorkerConfig;
}

export interface ChainScanConfig {
  chainId: number;
  /** Ponder's views schema for this chain; empty disables its scan. */
  schema: string;
  bookFile: string;
  /** Overrides; otherwise read from the loan token through `rpcUrl`, or known from a local book. */
  loanSymbol?: string;
  loanDecimals?: number;
  rpcUrl?: string;
}

/** Display names for the chains we deploy to (payloads and templates carry them). */
export const CHAIN_NAMES: Record<number, string> = {
  46630: "Robinhood Chain testnet",
  421614: "Arbitrum Sepolia",
  42161: "Arbitrum One",
  412346: "local devnode",
  31337: "anvil",
};
export const chainName = (id: number) => CHAIN_NAMES[id] ?? `chain ${id}`;

/** ADR-0014: one scan per served chain. With a single chain the legacy variables apply unchanged. */
export function chainScans(
  env: NodeJS.ProcessEnv,
  e: z.infer<typeof Env>,
): ChainScanConfig[] {
  const ids = (e.NOTIFIER_CHAINS ?? String(e.CHAIN_ID))
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean)
    .map((x) => {
      const n = Number(x);
      if (!Number.isInteger(n) || n <= 0)
        throw new Error(`NOTIFIER_CHAINS: bad chain id ${x}`);
      return n;
    });
  if (new Set(ids).size !== ids.length)
    throw new Error("NOTIFIER_CHAINS: duplicate chain id");
  const single = ids.length === 1;
  return ids.map((id) => {
    const v = (k: string) => set(env[`${k}_${id}`]);
    const schema =
      v("INDEXER_SCHEMA") ?? (single ? e.INDEXER_SCHEMA : `ix_${id}`);
    if (!/^[a-z0-9_]*$/.test(schema))
      throw new Error(`INDEXER_SCHEMA_${id}: bad schema ${schema}`);
    const dec = v("LOAN_DECIMALS");
    return {
      chainId: id,
      schema,
      bookFile:
        v("DEPLOYMENTS_FILE") ??
        (single
          ? (e.DEPLOYMENTS_FILE ?? `deployments/${id}.local.json`)
          : `deployments/${id}.json`),
      loanSymbol: v("LOAN_SYMBOL"),
      loanDecimals: dec === undefined ? undefined : Number(dec),
      rpcUrl: v("RPC_URL") ?? (single ? set(env.RPC_URL) : undefined),
    };
  });
}

const set = (v?: string) => (v && v.trim() ? v.trim() : undefined);

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = Env.parse(env);
  const resend = set(e.RESEND_API_KEY);
  const vapidPub = set(e.VAPID_PUBLIC_KEY);
  const vapidPriv = set(e.VAPID_PRIVATE_KEY);
  const tg = set(e.TELEGRAM_BOT_TOKEN);
  return {
    databaseUrl: e.DATABASE_URL,
    port: e.NOTIFIER_PORT,
    workerId: e.NOTIFIER_WORKER_ID,
    batch: e.NOTIFIER_BATCH,
    pollMs: e.NOTIFIER_POLL_MS,
    lockTimeoutS: e.NOTIFIER_LOCK_TIMEOUT_S,
    scan: {
      everyMs: e.NOTIFIER_SCAN_MS,
      lookbackS: e.NOTIFIER_SCAN_LOOKBACK_S,
      chains: chainScans(env, e),
    },
    worker: {
      email: resend
        ? {
            apiKey: resend,
            apiUrl: e.RESEND_API_URL,
            from: e.NOTIFIER_EMAIL_FROM,
          }
        : undefined,
      push:
        vapidPub && vapidPriv
          ? {
              publicKey: vapidPub,
              privateKey: vapidPriv,
              subject: e.VAPID_SUBJECT,
            }
          : undefined,
      telegram: tg ? { botToken: tg, apiUrl: e.TELEGRAM_API_URL } : undefined,
      webOrigin: e.API_PUBLIC_ORIGIN.split(",")[0]!.trim(),
      maxAttempts: e.NOTIFIER_MAX_ATTEMPTS,
      backoffBaseS: e.NOTIFIER_BACKOFF_BASE_S,
      backoffMaxS: e.NOTIFIER_BACKOFF_MAX_S,
      pushTtlS: e.NOTIFIER_PUSH_TTL_S,
    },
  };
}
