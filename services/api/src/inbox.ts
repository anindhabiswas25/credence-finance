// Amendment 2 (S5): in-app notifications and ops alerts.
// * GET /v1/me/inbox (paged, ?unread=1, ?chain=) and POST /v1/me/inbox/read: the SIWE session's own inbox, written
//   by the notifier's `inapp` channel (app.inbox, one row per chain, address and dedupe key).
// * POST /v1/ops/alerts: Alertmanager's webhook receiver (payload version 4, `Authorization: Bearer <secret>`), one
//   row per (fingerprint, startsAt) in ops.alert: a re-send is idempotent and `resolved` closes the row.
// * GET /v1/ops/alerts (?status=, ?chain=, paged): for SIWE sessions of an OPS_ADMIN_ADDRESSES address.
// New rows are also pushed on /v1/stream (`inbox:<owner>`, `ops`; stream.ts).
import { timingSafeEqual } from "node:crypto";
import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import { getCookie } from "hono/cookie";
import type { Context } from "hono";
import { getAddress, type Address } from "viem";
import type postgres from "postgres";
import type { AuthRepo } from "./repo.ts";
import { SESSION_COOKIE, verifySession } from "./session.ts";

export interface InboxItem {
  id: bigint;
  chainId: number;
  event: string;
  subject: string;
  body: string;
  url: string | null;
  payload: unknown;
  createdAt: Date;
  readAt: Date | null;
}
export interface InboxRepo {
  /** Newest first, ids below `before` (a cursor), at most `limit`. */
  list(
    owner: Address,
    q: { unread: boolean; chainId?: number; before?: bigint; limit: number },
  ): Promise<InboxItem[]>;
  unreadCount(owner: Address): Promise<number>;
  /** Mark the owner's rows read: the given ids, or every unread row. Returns how many changed. */
  markRead(owner: Address, ids: bigint[] | "all", now: Date): Promise<number>;
}

export interface OpsAlert {
  id: bigint;
  fingerprint: string;
  status: "firing" | "resolved";
  alertname: string;
  chainId: number | null;
  severity: string | null;
  summary: string | null;
  runbook: string | null;
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: Date;
  endsAt: Date | null;
  updatedAt: Date;
}
export interface OpsAlertInput {
  fingerprint: string;
  status: "firing" | "resolved";
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: Date;
  endsAt: Date | null;
}
export interface OpsRepo {
  /** Upsert by (fingerprint, startsAt). Returns [stored, resolved]. */
  store(alerts: OpsAlertInput[]): Promise<{ stored: number; resolved: number }>;
  list(q: {
    status?: "firing" | "resolved";
    chainId?: number;
    before?: bigint;
    limit: number;
  }): Promise<OpsAlert[]>;
}

// ── Alertmanager's webhook payload (version 4) ──────────────────────────────────────────────────
export const MAX_ALERTS = 500;
export const MAX_WEBHOOK_BYTES = 256 * 1024;
const Labels = z.record(z.string(), z.string());
const AmAlert = z.object({
  status: z.enum(["firing", "resolved"]),
  labels: Labels,
  annotations: Labels.default({}),
  startsAt: z.string(),
  endsAt: z.string().optional(),
  fingerprint: z.string().min(1).max(128),
});
export const AlertmanagerPayload = z.object({
  version: z.literal("4"),
  status: z.enum(["firing", "resolved"]),
  alerts: z.array(AmAlert).max(MAX_ALERTS),
});

/** Alertmanager's `endsAt` is the zero time while an alert fires. */
const time = (s: string | undefined): Date | null => {
  if (!s || s.startsWith("0001-01-01")) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
};

export function toAlertInputs(
  p: z.infer<typeof AlertmanagerPayload>,
): OpsAlertInput[] {
  return p.alerts.map((a) => ({
    fingerprint: a.fingerprint,
    status: a.status,
    labels: a.labels,
    annotations: a.annotations,
    startsAt: time(a.startsAt) ?? new Date(0),
    endsAt: a.status === "resolved" ? time(a.endsAt) : null,
  }));
}

/** Constant-time comparison of the webhook's bearer token with the configured secret. */
export function bearerOk(header: string | undefined, secret: string): boolean {
  const m = /^Bearer (.+)$/.exec(header ?? "");
  if (!m) return false;
  const a = Buffer.from(m[1]!);
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** OPS_ALERT_WEBHOOK_SECRET or the file named by OPS_ALERT_WEBHOOK_SECRET_FILE; ≥ 32 bytes, else refused. */
export function webhookSecret(
  env: NodeJS.ProcessEnv,
  read: (p: string) => string,
): string | undefined {
  const s =
    env.OPS_ALERT_WEBHOOK_SECRET ??
    (env.OPS_ALERT_WEBHOOK_SECRET_FILE
      ? read(env.OPS_ALERT_WEBHOOK_SECRET_FILE).trim()
      : undefined);
  if (s === undefined || s === "") return undefined;
  if (s.length < 32)
    throw new Error("OPS_ALERT_WEBHOOK_SECRET must be at least 32 bytes");
  return s;
}

export function opsAdmins(raw: string | undefined): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => getAddress(s).toLowerCase()),
  );
}

// ── routes ───────────────────────────────────────────────────────────────────────────────────────
const ErrorBody = z.object({ error: z.string(), message: z.string() });
const PAGE_MAX = 100;
const page = z.coerce.number().int().min(1).max(PAGE_MAX).default(20);
const cursor = z
  .string()
  .regex(/^\d+$/)
  .optional()
  .openapi({ description: "`nextCursor` of the previous page" });
const chainQ = z
  .string()
  .regex(/^\d+$/)
  .optional()
  .openapi({ description: "Only this chain's rows (0: account-level)" });

const InboxBody = z
  .object({
    id: z.string(),
    chainId: z.number(),
    event: z.string(),
    subject: z.string(),
    body: z.string(),
    url: z.string().nullable(),
    payload: z.unknown(),
    createdAt: z.number(),
    read: z.boolean(),
  })
  .openapi("InboxItem");
const OpsAlertBody = z
  .object({
    id: z.string(),
    alertname: z.string(),
    status: z.enum(["firing", "resolved"]),
    chainId: z.number().nullable(),
    severity: z.string().nullable(),
    summary: z.string().nullable(),
    runbook: z.string().nullable(),
    labels: z.record(z.string(), z.string()),
    annotations: z.record(z.string(), z.string()),
    startsAt: z.number(),
    endsAt: z.number().nullable(),
  })
  .openapi("OpsAlert");

const s = (d: Date) => Math.floor(d.getTime() / 1000);

export interface InboxDeps {
  auth: AuthRepo;
  inbox: InboxRepo;
  ops?: OpsRepo;
  sessionSecret: string;
  now: () => number;
  /** POST /v1/ops/alerts is mounted only with a secret. */
  webhookSecret?: string;
  opsAdmins: ReadonlySet<string>;
}

export function registerInboxRoutes(app: OpenAPIHono, deps: InboxDeps) {
  const session = async (c: Context): Promise<Address | undefined> => {
    const id = verifySession(deps.sessionSecret, getCookie(c, SESSION_COOKIE));
    return id
      ? (await deps.auth.getSession(id, new Date(deps.now())))?.address
      : undefined;
  };
  const unauthorized = {
    error: "unauthorized",
    message: "sign in with SIWE first",
  };

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/me/inbox",
      summary: "The signed-in address's in-app notifications, newest first",
      request: {
        query: z.object({
          unread: z.enum(["0", "1"]).optional(),
          chain: chainQ,
          cursor,
          limit: page,
        }),
      },
      responses: {
        200: {
          description: "A page",
          content: {
            "application/json": {
              schema: z.object({
                items: z.array(InboxBody),
                unread: z.number(),
                nextCursor: z.string().nullable(),
              }),
            },
          },
        },
        401: {
          description: "No session",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const owner = await session(c);
      if (!owner) return c.json(unauthorized, 401);
      const q = c.req.valid("query");
      const rows = await deps.inbox.list(owner, {
        unread: q.unread === "1",
        chainId: q.chain === undefined ? undefined : Number(q.chain),
        before: q.cursor === undefined ? undefined : BigInt(q.cursor),
        limit: q.limit + 1,
      });
      const items = rows.slice(0, q.limit);
      return c.json(
        {
          items: items.map((r) => ({
            id: r.id.toString(),
            chainId: r.chainId,
            event: r.event,
            subject: r.subject,
            body: r.body,
            url: r.url,
            payload: r.payload,
            createdAt: s(r.createdAt),
            read: r.readAt !== null,
          })),
          unread: await deps.inbox.unreadCount(owner),
          nextCursor:
            rows.length > q.limit ? items.at(-1)!.id.toString() : null,
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "post",
      path: "/v1/me/inbox/read",
      summary: "Mark in-app notifications read (the given ids, or all)",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z
                .union([
                  z
                    .object({
                      ids: z.array(z.string().regex(/^\d+$/)).min(1).max(500),
                    })
                    .strict(),
                  z.object({ all: z.literal(true) }).strict(),
                ])
                .openapi("InboxRead"),
            },
          },
        },
      },
      responses: {
        200: {
          description: "How many changed (only the caller's own rows)",
          content: {
            "application/json": {
              schema: z.object({ updated: z.number(), unread: z.number() }),
            },
          },
        },
        401: {
          description: "No session",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const owner = await session(c);
      if (!owner) return c.json(unauthorized, 401);
      const b = c.req.valid("json");
      const updated = await deps.inbox.markRead(
        owner,
        "all" in b ? "all" : b.ids.map((x) => BigInt(x)),
        new Date(deps.now()),
      );
      return c.json(
        { updated, unread: await deps.inbox.unreadCount(owner) },
        200,
      );
    },
  );

  const ops = deps.ops;
  if (!ops) return;

  if (deps.webhookSecret) {
    const secret = deps.webhookSecret;
    app.post("/v1/ops/alerts", async (c) => {
      if (!bearerOk(c.req.header("authorization"), secret))
        return c.json(
          { error: "unauthorized", message: "bad webhook secret" },
          401,
        );
      const raw = await c.req.text();
      if (Buffer.byteLength(raw) > MAX_WEBHOOK_BYTES)
        return c.json(
          { error: "too_large", message: "webhook body over 256 KiB" },
          413,
        );
      let json: unknown;
      try {
        json = JSON.parse(raw);
      } catch {
        return c.json({ error: "bad_request", message: "not JSON" }, 400);
      }
      const p = AlertmanagerPayload.safeParse(json);
      if (!p.success) {
        const tooMany = p.error.issues.some(
          (i) => i.path[0] === "alerts" && i.code === "too_big",
        );
        return c.json(
          {
            error: tooMany ? "too_large" : "bad_request",
            message: p.error.issues
              .map((i) => `${i.path.join(".")}: ${i.message}`)
              .join("; "),
          },
          tooMany ? 413 : 400,
        );
      }
      return c.json(await ops.store(toAlertInputs(p.data)), 200);
    });
  }

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/ops/alerts",
      summary: "Ops alerts from Alertmanager, newest first (ops admins only)",
      request: {
        query: z.object({
          status: z.enum(["firing", "resolved"]).optional(),
          chain: chainQ,
          cursor,
          limit: page,
        }),
      },
      responses: {
        200: {
          description: "A page",
          content: {
            "application/json": {
              schema: z.object({
                items: z.array(OpsAlertBody),
                nextCursor: z.string().nullable(),
              }),
            },
          },
        },
        401: {
          description: "No session",
          content: { "application/json": { schema: ErrorBody } },
        },
        403: {
          description: "Not an ops admin",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const who = await session(c);
      if (!who) return c.json(unauthorized, 401);
      if (!deps.opsAdmins.has(who.toLowerCase()))
        return c.json({ error: "forbidden", message: "not an ops admin" }, 403);
      const q = c.req.valid("query");
      const rows = await ops.list({
        status: q.status,
        chainId: q.chain === undefined ? undefined : Number(q.chain),
        before: q.cursor === undefined ? undefined : BigInt(q.cursor),
        limit: q.limit + 1,
      });
      const items = rows.slice(0, q.limit);
      return c.json(
        {
          items: items.map((a) => ({
            id: a.id.toString(),
            alertname: a.alertname,
            status: a.status,
            chainId: a.chainId,
            severity: a.severity,
            summary: a.summary,
            runbook: a.runbook,
            labels: a.labels,
            annotations: a.annotations,
            startsAt: s(a.startsAt),
            endsAt: a.endsAt ? s(a.endsAt) : null,
          })),
          nextCursor:
            rows.length > q.limit ? items.at(-1)!.id.toString() : null,
        },
        200,
      );
    },
  );
}

// ── Postgres ──────────────────────────────────────────────────────────────────────────────────────
type Sql = postgres.Sql<{ bigint: bigint }>;
const addr = (a: Address) => Buffer.from(a.slice(2).toLowerCase(), "hex");
const chainOf = (labels: Record<string, string>) => {
  const n = Number(labels.chain);
  return Number.isInteger(n) && n > 0 ? n : null;
};

export function pgInboxRepo(sql: Sql): InboxRepo {
  return {
    async list(owner, q) {
      const rows = await sql`
        select id, chain_id, event, subject, body, url, payload, created_at, read_at from app.inbox
         where address = ${addr(owner)}
           ${q.unread ? sql`and read_at is null` : sql``}
           ${q.chainId === undefined ? sql`` : sql`and chain_id = ${q.chainId}`}
           ${q.before === undefined ? sql`` : sql`and id < ${q.before.toString()}`}
         order by id desc limit ${q.limit}`;
      return rows.map((r) => ({
        id: BigInt(r.id as string),
        chainId: Number(r.chain_id),
        event: String(r.event),
        subject: String(r.subject),
        body: String(r.body),
        url: (r.url as string | null) ?? null,
        payload: r.payload,
        createdAt: new Date(r.created_at as string),
        readAt: r.read_at ? new Date(r.read_at as string) : null,
      }));
    },
    async unreadCount(owner) {
      const [r] =
        await sql`select count(*)::int as n from app.inbox where address = ${addr(owner)} and read_at is null`;
      return Number(r!.n);
    },
    async markRead(owner, ids, now) {
      const r =
        ids === "all"
          ? await sql`update app.inbox set read_at = ${now} where address = ${addr(owner)} and read_at is null`
          : await sql`update app.inbox set read_at = ${now}
                       where address = ${addr(owner)} and read_at is null and id = any(${ids.map(String)}::bigint[])`;
      return r.count;
    },
  };
}

export function pgOpsRepo(sql: Sql): OpsRepo {
  return {
    async store(alerts) {
      let resolved = 0;
      for (const a of alerts) {
        await sql`
          insert into ops.alert (fingerprint, starts_at, status, alertname, chain_id, severity, summary, runbook,
                                 labels, annotations, ends_at)
          values (${a.fingerprint}, ${a.startsAt}, ${a.status}, ${a.labels.alertname ?? "unnamed"},
                  ${chainOf(a.labels)}, ${a.labels.severity ?? null},
                  ${a.annotations.summary ?? a.annotations.description ?? null},
                  ${a.annotations.runbook ?? a.annotations.runbook_url ?? null},
                  ${sql.json(a.labels)}, ${sql.json(a.annotations)}, ${a.endsAt})
          on conflict (fingerprint, starts_at) do update
            set status = excluded.status, ends_at = excluded.ends_at, labels = excluded.labels,
                annotations = excluded.annotations, summary = excluded.summary, runbook = excluded.runbook,
                updated_at = now()
            where ops.alert.status <> excluded.status or ops.alert.annotations <> excluded.annotations`;
        if (a.status === "resolved") resolved++;
      }
      return { stored: alerts.length, resolved };
    },
    async list(q) {
      const rows = await sql`
        select * from ops.alert where true
          ${q.status ? sql`and status = ${q.status}` : sql``}
          ${q.chainId === undefined ? sql`` : sql`and chain_id = ${q.chainId}`}
          ${q.before === undefined ? sql`` : sql`and id < ${q.before.toString()}`}
         order by id desc limit ${q.limit}`;
      return rows.map(opsRow);
    },
  };
}

function opsRow(r: Record<string, unknown>): OpsAlert {
  return {
    id: BigInt(r.id as string),
    fingerprint: String(r.fingerprint),
    status: r.status as "firing" | "resolved",
    alertname: String(r.alertname),
    chainId: r.chain_id === null ? null : Number(r.chain_id),
    severity: (r.severity as string | null) ?? null,
    summary: (r.summary as string | null) ?? null,
    runbook: (r.runbook as string | null) ?? null,
    labels: r.labels as Record<string, string>,
    annotations: r.annotations as Record<string, string>,
    startsAt: new Date(r.starts_at as string),
    endsAt: r.ends_at ? new Date(r.ends_at as string) : null,
    updatedAt: new Date(r.updated_at as string),
  };
}

/** The stream's inbox / ops sources for one chain's hub (the default chain also gets account-level rows and ops). */
export function pgAppStream(sql: Sql, chainId: number, isDefault: boolean) {
  const chains = isDefault ? [chainId, 0] : [chainId];
  return {
    async inboxHead() {
      const [r] =
        await sql`select coalesce(max(id), 0)::text as id from app.inbox`;
      return BigInt(r!.id as string);
    },
    async inboxSince(id: bigint, limit: number) {
      const rows = await sql`
        select id, chain_id, address, event, subject, body, url, created_at from app.inbox
         where id > ${id.toString()} and chain_id = any(${chains}::bigint[]) order by id limit ${limit}`;
      return rows.map((r) => ({
        id: BigInt(r.id as string),
        chainId: Number(r.chain_id),
        owner: `0x${(r.address as Buffer).toString("hex")}` as `0x${string}`,
        event: String(r.event),
        subject: String(r.subject),
        body: String(r.body),
        url: (r.url as string | null) ?? null,
        createdAt: Math.floor(
          new Date(r.created_at as string).getTime() / 1000,
        ),
      }));
    },
    ...(isDefault
      ? {
          async opsAlertsSince(ms: number, limit: number) {
            const rows =
              await sql`select * from ops.alert where updated_at > ${new Date(ms)} order by updated_at, id limit ${limit}`;
            return rows.map((r) => {
              const a = opsRow(r);
              return {
                id: a.id,
                alertname: a.alertname,
                status: a.status,
                chainId: a.chainId,
                severity: a.severity,
                summary: a.summary,
                runbook: a.runbook,
                startsAt: s(a.startsAt),
                endsAt: a.endsAt ? s(a.endsAt) : null,
                updatedAt: a.updatedAt.getTime(),
              };
            });
          },
        }
      : {}),
  };
}

// ── in memory (tests) ─────────────────────────────────────────────────────────────────────────────
export function memoryInbox(
  rows: (Omit<InboxItem, "id"> & { owner: string })[] = [],
) {
  let next = 1n;
  const all = rows.map((r) => ({ ...r, id: next++ }));
  const own = (o: Address) =>
    all.filter((r) => r.owner.toLowerCase() === o.toLowerCase());
  const repo: InboxRepo = {
    async list(o, q) {
      return own(o)
        .filter((r) => !q.unread || r.readAt === null)
        .filter((r) => q.chainId === undefined || r.chainId === q.chainId)
        .filter((r) => q.before === undefined || r.id < q.before)
        .sort((a, b) => (a.id < b.id ? 1 : -1))
        .slice(0, q.limit);
    },
    async unreadCount(o) {
      return own(o).filter((r) => r.readAt === null).length;
    },
    async markRead(o, ids, now) {
      let n = 0;
      for (const r of own(o))
        if (r.readAt === null && (ids === "all" || ids.includes(r.id))) {
          r.readAt = now;
          n++;
        }
      return n;
    },
  };
  return {
    repo,
    all,
    add: (r: (typeof rows)[number]) => all.push({ ...r, id: next++ }),
  };
}

export function memoryOps(): OpsRepo & { rows: OpsAlert[] } {
  const rows: OpsAlert[] = [];
  let next = 1n;
  return {
    rows,
    async store(alerts) {
      let resolved = 0;
      for (const a of alerts) {
        const i = rows.findIndex(
          (r) =>
            r.fingerprint === a.fingerprint &&
            r.startsAt.getTime() === a.startsAt.getTime(),
        );
        const row: OpsAlert = {
          id: i >= 0 ? rows[i]!.id : next++,
          fingerprint: a.fingerprint,
          status: a.status,
          alertname: a.labels.alertname ?? "unnamed",
          chainId: chainOf(a.labels),
          severity: a.labels.severity ?? null,
          summary: a.annotations.summary ?? a.annotations.description ?? null,
          runbook: a.annotations.runbook ?? a.annotations.runbook_url ?? null,
          labels: a.labels,
          annotations: a.annotations,
          startsAt: a.startsAt,
          endsAt: a.endsAt,
          updatedAt: new Date(),
        };
        if (i >= 0) rows[i] = row;
        else rows.push(row);
        if (a.status === "resolved") resolved++;
      }
      return { stored: alerts.length, resolved };
    },
    async list(q) {
      return rows
        .filter((r) => !q.status || r.status === q.status)
        .filter((r) => q.chainId === undefined || r.chainId === q.chainId)
        .filter((r) => q.before === undefined || r.id < q.before)
        .sort((a, b) => (a.id < b.id ? 1 : -1))
        .slice(0, q.limit);
    },
  };
}
