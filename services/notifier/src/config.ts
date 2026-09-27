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
  worker: WorkerConfig;
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
