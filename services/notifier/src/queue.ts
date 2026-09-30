// The Postgres queue: app.notification_job (§11.2 + migration 20260928000001).
import postgres from "postgres";
import type { Channel } from "./templates.ts";

export type Sql = postgres.Sql;

export interface Job {
  id: bigint;
  dedupeKey: string;
  address: Buffer;
  event: string;
  payload: unknown;
  attempts: number;
  deliveredChannels: Channel[];
  failedChannels: Channel[];
}

export interface Recipient {
  email: string | null;
  emailVerified: boolean;
  telegramChatId: string | null;
  push: { id: bigint; endpoint: string; p256dh: string; auth: string }[];
  /** event channel → enabled, from app.notification_pref (absent = default on). */
  prefs: Map<string, boolean>;
}

export function connect(url: string, max = 5): Sql {
  return postgres(url, {
    max,
    idle_timeout: 30,
    types: { bigint: postgres.BigInt },
    onnotice: () => {},
  });
}

/**
 * Claim up to `n` due jobs. `FOR UPDATE SKIP LOCKED` lets several workers share the queue; a job left
 * in `sending` by a dead worker is reclaimed after `lockTimeoutS`.
 */
export async function claim(
  sql: Sql,
  n: number,
  worker: string,
  lockTimeoutS: number,
): Promise<Job[]> {
  const rows = await sql`
    with due as (
      select id from app.notification_job
      where (status in ('pending', 'retry') and run_at <= now())
         or (status = 'sending' and locked_at < now() - make_interval(secs => ${lockTimeoutS}))
      order by run_at, id
      for update skip locked
      limit ${n}
    )
    update app.notification_job j
       set status = 'sending', attempts = j.attempts + 1, locked_at = now(), locked_by = ${worker}, updated_at = now()
      from due where j.id = due.id
    returning j.id, j.dedupe_key, j.address, j.event, j.payload, j.attempts, j.delivered_channels, j.failed_channels`;
  return rows.map((r) => ({
    id: BigInt(r.id),
    dedupeKey: r.dedupe_key,
    address: r.address,
    event: r.event,
    payload: r.payload,
    attempts: r.attempts,
    deliveredChannels: r.delivered_channels,
    failedChannels: r.failed_channels,
  }));
}

export async function recipient(sql: Sql, address: Buffer): Promise<Recipient> {
  const [acct] =
    await sql`select email, email_verified_at, telegram_chat_id from app.account where address = ${address}`;
  const push =
    await sql`select id, endpoint, p256dh, auth from app.push_subscription where address = ${address} order by id`;
  const prefs =
    await sql`select event, channel, enabled from app.notification_pref where address = ${address}`;
  return {
    email: acct?.email ?? null,
    emailVerified: !!acct?.email_verified_at,
    telegramChatId: acct?.telegram_chat_id ?? null,
    push: push.map((p) => ({
      id: BigInt(p.id),
      endpoint: p.endpoint,
      p256dh: p.p256dh,
      auth: p.auth,
    })),
    prefs: new Map(
      prefs.map((p) => [`${p.event}:${p.channel}`, p.enabled as boolean]),
    ),
  };
}

export async function log(
  sql: Sql,
  jobId: bigint,
  channel: Channel,
  attempt: number,
  ok: boolean,
  providerId: string | null,
  error: string | null,
): Promise<void> {
  await sql`insert into app.notification_log (job_id, channel, sent_at, provider_id, ok, error, attempt)
            values (${jobId.toString()}, ${channel}, ${ok ? sql`now()` : null}, ${providerId}, ${ok}, ${error}, ${attempt})`;
}

export async function deletePushSubscription(
  sql: Sql,
  id: bigint,
): Promise<void> {
  await sql`delete from app.push_subscription where id = ${id.toString()}`;
}

export type Final = "sent" | "dead" | "expired" | "skipped";

/** Record the outcome of one attempt. `retryAt` set ⇒ status `retry`. */
export async function finish(
  sql: Sql,
  job: Job,
  delivered: Channel[],
  failed: Channel[],
  outcome: { status: Final } | { status: "retry"; runAt: Date },
  lastError: string | null,
): Promise<void> {
  const runAt = outcome.status === "retry" ? outcome.runAt : null;
  await sql`
    update app.notification_job
       set status = ${outcome.status},
           delivered_channels = ${sql.array(delivered)}::text[],
           failed_channels = ${sql.array(failed)}::text[],
           run_at = coalesce(${runAt}::timestamptz, run_at),
           last_error = ${lastError},
           locked_at = null, locked_by = null, updated_at = now()
     where id = ${job.id.toString()}`;
}

export interface EnqueueArgs {
  /** ADR-0014: the chain the event happened on (0: account-level, e.g. email verification). A dedupe key is
   * unique per chain. */
  chainId: number;
  dedupeKey: string;
  /** 0x-prefixed 20-byte address */
  address: string;
  event: string;
  payload: object;
  runAt?: Date;
}

/** Producers' side: insert once per (chain, dedupe key). Returns the job id, or null if it already existed. */
export async function enqueue(
  sql: Sql,
  a: EnqueueArgs,
): Promise<bigint | null> {
  const addr = Buffer.from(a.address.replace(/^0x/, ""), "hex");
  if (addr.length !== 20) throw new Error(`bad address ${a.address}`);
  const rows = await sql`
    insert into app.notification_job (chain_id, dedupe_key, address, event, payload, run_at)
    values (${a.chainId}, ${a.dedupeKey}, ${addr}, ${a.event}, ${sql.json(a.payload as postgres.JSONValue)}, ${a.runAt ?? sql`now()`})
    on conflict (chain_id, dedupe_key) do nothing
    returning id`;
  return rows[0] ? BigInt(rows[0].id) : null;
}
