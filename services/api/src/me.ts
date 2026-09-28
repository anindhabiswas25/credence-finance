// Signed-in account routes (Build Guide §10.4): notification preferences and the testnet allowlist.
// Everything here needs a SIWE session; the address always comes from the session, never the body.
import { createHash, randomBytes } from "node:crypto";
import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import { getCookie } from "hono/cookie";
import type { Context } from "hono";
import type { Address } from "viem";
import type { AuthRepo } from "./repo.ts";
import { SESSION_COOKIE, verifySession } from "./session.ts";
import { FixedWindow } from "./ratelimit.ts";

/** Events and channels the notifier knows (services/notifier/src/templates.ts EVENTS / DEFAULT_CHANNELS). */
export const EVENTS = ["bell_headsup", "bell_outcome"] as const;
export const CHANNELS = ["email", "push", "telegram"] as const;
export type Pref = { event: (typeof EVENTS)[number]; channel: (typeof CHANNELS)[number]; enabled: boolean };

export interface PushSub {
  endpoint: string;
  p256dh: string;
  auth: string;
}
export interface AccountView {
  email: string | null;
  emailVerified: boolean;
  telegramChatId: string | null;
  push: { endpoint: string }[];
  /** Explicit rows only; everything else is on (the notifier's defaults). */
  prefs: Pref[];
  testnetAttestedAt: Date | null;
  allowlist: { status: string; txHash: string | null } | null;
}

export interface MeRepo {
  account(address: Address): Promise<AccountView>;
  /** Sets the email unverified and stores sha256(token); returns false if unchanged. */
  setEmail(address: Address, email: string | null, tokenHash: Buffer | null, expiresAt: Date): Promise<boolean>;
  /** Marks the email verified if the token is valid and still names the account's current email. */
  verifyEmail(tokenHash: Buffer, now: Date): Promise<Address | null>;
  setTelegram(address: Address, chatId: string | null): Promise<void>;
  addPush(address: Address, sub: PushSub): Promise<void>;
  removePush(address: Address, endpoint: string): Promise<void>;
  setPrefs(address: Address, prefs: Pref[]): Promise<void>;
  enqueue(job: { dedupeKey: string; address: Address; event: string; payload: object }): Promise<void>;
  requestAllowlist(address: Address, now: Date): Promise<{ status: string; created: boolean }>;
}

export interface MeDeps {
  auth: AuthRepo;
  me: MeRepo;
  sessionSecret: string;
  /** Public origin of the API, for the email verification link. */
  publicApiOrigin: string;
  now: () => number;
  allowlistEnabled: boolean;
  allowlistPerIpPerHour: number;
  ipOf: (c: Context) => string;
}

const ErrorBody = z.object({ error: z.string(), message: z.string() });
const Prefs = z.array(z.object({ event: z.enum(EVENTS), channel: z.enum(CHANNELS), enabled: z.boolean() })).max(EVENTS.length * CHANNELS.length);
const AccountBody = z
  .object({
    address: z.string(),
    email: z.object({ address: z.string(), verified: z.boolean() }).nullable(),
    telegramChatId: z.string().nullable(),
    push: z.array(z.object({ endpoint: z.string() })),
    prefs: z.array(z.object({ event: z.string(), channel: z.string(), enabled: z.boolean() })).openapi({ description: "Effective matrix: every event × channel" }),
    testnet: z.object({ attestedAt: z.number().nullable(), allowlist: z.object({ status: z.string(), txHash: z.string().nullable() }).nullable() }),
  })
  .openapi("NotificationSettings");

export const sha256 = (s: string) => createHash("sha256").update(s).digest();

function effective(prefs: Pref[]) {
  return EVENTS.flatMap((event) => CHANNELS.map((channel) => ({ event, channel, enabled: prefs.find((p) => p.event === event && p.channel === channel)?.enabled ?? true })));
}

function view(address: Address, a: AccountView) {
  return {
    address,
    email: a.email ? { address: a.email, verified: a.emailVerified } : null,
    telegramChatId: a.telegramChatId,
    push: a.push,
    prefs: effective(a.prefs),
    testnet: { attestedAt: a.testnetAttestedAt ? Math.floor(a.testnetAttestedAt.getTime() / 1000) : null, allowlist: a.allowlist },
  };
}

export function registerMeRoutes(app: OpenAPIHono, deps: MeDeps) {
  const session = async (c: Context): Promise<Address | undefined> => {
    const id = verifySession(deps.sessionSecret, getCookie(c, SESSION_COOKIE));
    return id ? (await deps.auth.getSession(id, new Date(deps.now())))?.address : undefined;
  };
  const unauthorized = { error: "unauthorized", message: "sign in with SIWE first" };

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/me/notifications",
      summary: "Channel preferences of the signed-in address",
      responses: {
        200: { description: "Settings", content: { "application/json": { schema: AccountBody } } },
        401: { description: "No session", content: { "application/json": { schema: ErrorBody } } },
      },
    }),
    async (c) => {
      const address = await session(c);
      if (!address) return c.json(unauthorized, 401);
      return c.json(view(address, await deps.me.account(address)), 200);
    },
  );

  app.openapi(
    createRoute({
      method: "put",
      path: "/v1/me/notifications",
      summary: "Update email (sends a verification link), Telegram chat id, push subscriptions and per-event channel switches",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z
                .object({
                  email: z.string().email().max(254).nullable().optional(),
                  telegramChatId: z.string().regex(/^-?\d{1,20}$/).nullable().optional(),
                  pushSubscribe: z.object({ endpoint: z.string().url().max(2048).startsWith("https://"), p256dh: z.string().max(200), auth: z.string().max(100) }).optional(),
                  pushUnsubscribe: z.string().url().max(2048).optional(),
                  prefs: Prefs.optional(),
                })
                .strict(),
            },
          },
        },
      },
      responses: {
        200: { description: "Updated settings", content: { "application/json": { schema: AccountBody } } },
        401: { description: "No session", content: { "application/json": { schema: ErrorBody } } },
      },
    }),
    async (c) => {
      const address = await session(c);
      if (!address) return c.json(unauthorized, 401);
      const b = c.req.valid("json");
      if (b.email !== undefined) {
        const email = b.email === null ? null : b.email.trim().toLowerCase();
        const token = email ? randomBytes(32).toString("base64url") : null;
        const changed = await deps.me.setEmail(address, email, token ? sha256(token) : null, new Date(deps.now() + 24 * 3600_000));
        if (changed && email && token) {
          const link = `${deps.publicApiOrigin.replace(/\/$/, "")}/v1/me/email/verify?token=${token}`;
          await deps.me.enqueue({ dedupeKey: `email_verify:${address.toLowerCase()}:${sha256(token).toString("hex").slice(0, 16)}`, address, event: "email_verify", payload: { email, link } });
        }
      }
      if (b.telegramChatId !== undefined) await deps.me.setTelegram(address, b.telegramChatId);
      if (b.pushSubscribe) await deps.me.addPush(address, b.pushSubscribe);
      if (b.pushUnsubscribe) await deps.me.removePush(address, b.pushUnsubscribe);
      if (b.prefs) await deps.me.setPrefs(address, b.prefs);
      return c.json(view(address, await deps.me.account(address)), 200);
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/me/email/verify",
      summary: "Confirm an email address (the link from the verification mail)",
      request: { query: z.object({ token: z.string().min(20).max(100) }) },
      responses: {
        200: { description: "Verified", content: { "application/json": { schema: z.object({ address: z.string(), verified: z.literal(true) }) } } },
        400: { description: "Unknown, used or expired token", content: { "application/json": { schema: ErrorBody } } },
      },
    }),
    async (c) => {
      const address = await deps.me.verifyEmail(sha256(c.req.valid("query").token), new Date(deps.now()));
      if (!address) return c.json({ error: "bad_request", message: "unknown, used or expired token" }, 400);
      return c.json({ address, verified: true as const }, 200);
    },
  );

  const perIp = new FixedWindow(deps.allowlistPerIpPerHour, 3600_000, deps.now);
  app.openapi(
    createRoute({
      method: "post",
      path: "/v1/testnet/allowlist",
      summary: "Testnet self-attestation: queue the ops allowlist transaction for the signed-in address (rate-limited)",
      request: {
        body: { content: { "application/json": { schema: z.object({ attest: z.literal(true).openapi({ description: "I accept the testnet terms (test assets, no value)" }) }).strict() } } },
      },
      responses: {
        202: { description: "Queued (or already queued / done)", content: { "application/json": { schema: z.object({ address: z.string(), status: z.string(), created: z.boolean() }) } } },
        401: { description: "No session", content: { "application/json": { schema: ErrorBody } } },
        404: { description: "Not a testnet deployment", content: { "application/json": { schema: ErrorBody } } },
        429: { description: "Too many requests from this IP", content: { "application/json": { schema: ErrorBody } } },
      },
    }),
    async (c) => {
      if (!deps.allowlistEnabled) return c.json({ error: "not_found", message: "allowlist self-service is testnet only" }, 404);
      const address = await session(c);
      if (!address) return c.json(unauthorized, 401);
      const ip = deps.ipOf(c);
      if (perIp.take(`allowlist:${ip}`).remaining < 0) return c.json({ error: "rate_limited", message: "too many allowlist requests from this IP" }, 429);
      const r = await deps.me.requestAllowlist(address, new Date(deps.now()));
      return c.json({ address, ...r }, 202);
    },
  );
}
