// One job, end to end: validate → render → deliver per channel → retry / dead-letter / done.
import { type Logger } from "pino";
import { sendEmail, type EmailConfig } from "./channels/email.ts";
import { goneStatus, sendPush, type PushConfig } from "./channels/push.ts";
import { sendTelegram, type TelegramConfig } from "./channels/telegram.ts";
import { ChannelError, type Fetch } from "./channels/types.ts";
import type { Metrics } from "./metrics.ts";
import * as q from "./queue.ts";
import {
  BadPayload,
  DEFAULT_CHANNELS,
  render,
  type Channel,
  type EventName,
} from "./templates.ts";

export interface WorkerConfig {
  email?: EmailConfig;
  push?: PushConfig;
  telegram?: TelegramConfig;
  webOrigin: string;
  maxAttempts: number;
  /** Back-off base: attempt k waits base × 2^(k−1), capped at `backoffMaxS`. */
  backoffBaseS: number;
  backoffMaxS: number;
  pushTtlS: number;
}

export interface Deps {
  sql: q.Sql;
  cfg: WorkerConfig;
  log: Logger;
  fetch?: Fetch;
  metrics?: Metrics;
  now?: () => Date;
}

export function backoffS(cfg: WorkerConfig, attempt: number): number {
  return Math.min(
    cfg.backoffMaxS,
    cfg.backoffBaseS * 2 ** Math.max(0, attempt - 1),
  );
}

/** Channels this job should reach: event defaults ∩ user prefs ∩ what the account has configured. */
export function channelsFor(
  event: EventName,
  r: q.Recipient,
  cfg: WorkerConfig,
): Channel[] {
  return DEFAULT_CHANNELS[event].filter((c) => {
    if (r.prefs.get(`${event}:${c}`) === false) return false;
    switch (c) {
      case "email":
        return (
          !!cfg.email &&
          !!r.email &&
          (r.emailVerified || event === "email_verify")
        );
      case "push":
        return !!cfg.push && r.push.length > 0;
      case "telegram":
        return !!cfg.telegram && !!r.telegramChatId;
    }
  });
}

export async function processJob(
  d: Deps,
  job: q.Job,
): Promise<q.Final | "retry"> {
  const now = d.now?.() ?? new Date();
  const f = d.fetch ?? fetch;
  const done = async (
    status: q.Final | "retry",
    delivered: Channel[],
    failed: Channel[],
    err: string | null,
  ) => {
    const outcome =
      status === "retry"
        ? {
            status: "retry" as const,
            runAt: new Date(
              now.getTime() + backoffS(d.cfg, job.attempts) * 1000,
            ),
          }
        : { status };
    await q.finish(d.sql, job, delivered, failed, outcome, err);
    d.metrics?.jobs.inc({ event: job.event, status });
    return status;
  };

  let rendered, data;
  try {
    ({ rendered, data } = render(job.event, job.payload, d.cfg.webOrigin));
  } catch (e) {
    if (e instanceof BadPayload) {
      d.log.error(
        { job: job.id.toString(), event: job.event, err: e.message },
        "bad payload: dead-lettered",
      );
      return done(
        "dead",
        job.deliveredChannels,
        job.failedChannels,
        `bad payload: ${e.message}`,
      );
    }
    throw e;
  }
  const expiresAt = (data as { expiresAt?: number }).expiresAt;
  if (expiresAt !== undefined && now.getTime() / 1000 > expiresAt) {
    return done(
      "expired",
      job.deliveredChannels,
      job.failedChannels,
      "past its deadline",
    );
  }

  const r = await q.recipient(d.sql, job.address);
  const wanted = channelsFor(job.event as EventName, r, d.cfg);
  const delivered = [...job.deliveredChannels];
  const failed = [...job.failedChannels];
  const todo = wanted.filter(
    (c) => !delivered.includes(c) && !failed.includes(c),
  );
  if (wanted.length === 0)
    return done("skipped", delivered, failed, "no deliverable channel");

  const errors: string[] = [];
  let transient = false;
  for (const c of todo) {
    const t0 = performance.now();
    try {
      const providerIds: string[] = [];
      switch (c) {
        case "email": {
          const to =
            job.event === "email_verify"
              ? (data as { email: string }).email
              : r.email!;
          providerIds.push(
            await sendEmail(
              d.cfg.email!,
              { to, ...rendered },
              `${job.dedupeKey}:email`,
              f,
            ),
          );
          break;
        }
        case "push": {
          // delivered if any subscription takes it; gone subscriptions are removed
          let lastErr: ChannelError | undefined;
          for (const s of r.push) {
            try {
              providerIds.push(
                await sendPush(
                  d.cfg.push!,
                  s,
                  rendered.push,
                  d.cfg.pushTtlS,
                  f,
                ),
              );
            } catch (e) {
              if (!(e instanceof ChannelError)) throw e;
              if (goneStatus(e)) await q.deletePushSubscription(d.sql, s.id);
              lastErr = e;
            }
          }
          if (providerIds.length === 0)
            throw lastErr ?? new ChannelError("push: no subscription", true);
          break;
        }
        case "telegram":
          providerIds.push(
            await sendTelegram(
              d.cfg.telegram!,
              r.telegramChatId!,
              rendered.text,
              f,
            ),
          );
          break;
      }
      delivered.push(c);
      await q.log(
        d.sql,
        job.id,
        c,
        job.attempts,
        true,
        providerIds.join(","),
        null,
      );
      d.metrics?.deliveries.inc({ channel: c, result: "ok" });
    } catch (e) {
      const err =
        e instanceof ChannelError ? e : new ChannelError(String(e), false);
      if (err.permanent) failed.push(c);
      else transient = true;
      errors.push(err.message);
      await q.log(d.sql, job.id, c, job.attempts, false, null, err.message);
      d.metrics?.deliveries.inc({
        channel: c,
        result: err.permanent ? "permanent" : "transient",
      });
      d.log.warn(
        {
          job: job.id.toString(),
          channel: c,
          err: err.message,
          permanent: err.permanent,
        },
        "delivery failed",
      );
    } finally {
      d.metrics?.latency.observe(
        { channel: c },
        (performance.now() - t0) / 1000,
      );
    }
  }

  const err = errors.length ? errors.join("; ") : null;
  if (transient) {
    if (job.attempts >= d.cfg.maxAttempts) {
      d.log.error(
        { job: job.id.toString(), attempts: job.attempts, err },
        "retries exhausted: dead-lettered",
      );
      return done("dead", delivered, failed, err);
    }
    return done("retry", delivered, failed, err);
  }
  return done(delivered.length > 0 ? "sent" : "dead", delivered, failed, err);
}

/** Claim and process one batch. Returns the number of jobs handled. */
export async function runOnce(
  d: Deps,
  worker: string,
  batch: number,
  lockTimeoutS: number,
): Promise<number> {
  const jobs = await q.claim(d.sql, batch, worker, lockTimeoutS);
  await Promise.all(
    jobs.map((j) =>
      processJob(d, j).catch(async (e) => {
        d.log.error(
          { job: j.id.toString(), err: String(e) },
          "job crashed; retried later",
        );
        const outcome =
          j.attempts >= d.cfg.maxAttempts
            ? { status: "dead" as const }
            : {
                status: "retry" as const,
                runAt: new Date(
                  Date.now() + backoffS(d.cfg, j.attempts) * 1000,
                ),
              };
        await q.finish(
          d.sql,
          j,
          j.deliveredChannels,
          j.failedChannels,
          outcome,
          String(e),
        );
      }),
    ),
  );
  return jobs.length;
}
