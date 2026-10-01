// Credence API (Build Guide §10.4). S1: health, OpenAPI, GET /v1/clock/:assetId, SIWE sessions.
// S2: markets, positions, /bell (core.ts), vault, notifications, testnet allowlist, /v1/stream.
// Every input is validated with zod; the OpenAPI document is generated from the same schemas.
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { routePath } from "hono/route";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { getConnInfo } from "@hono/node-server/conninfo";
import {
  formatUnits,
  isHex,
  keccak256,
  stringToHex,
  verifyMessage,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { parseSiweMessage, validateSiweMessage } from "viem/siwe";
import { ClockState, ClosureType, clockStateName } from "@credence/sdk";
import type { Config } from "./config.ts";
import type { AuthRepo, ClockRepo, CoreRepo } from "./repo.ts";
import type { ChainReader } from "./chain.ts";
import type { SetStore } from "./sets.ts";
import { registerCoreRoutes, safeLtvsOf, type CoreDeps } from "./core.ts";
import {
  registerRiskTransferRoutes,
  stackCushion,
  type RiskTransferRepo,
} from "./rt.ts";
import { registerSettlementRoutes, type SettlementRepo } from "./settlement.ts";
import { registerMeRoutes, type MeRepo } from "./me.ts";
import { registerInboxRoutes, type InboxRepo, type OpsRepo } from "./inbox.ts";
import { FixedWindow, clientIp, rateLimit } from "./ratelimit.ts";
import {
  SESSION_COOKIE,
  newNonce,
  newSessionId,
  signSession,
  verifySession,
} from "./session.ts";
import { log } from "./log.ts";
import { createMetrics, type ApiMetrics } from "./metrics.ts";

export interface Deps {
  config: Config;
  clock: ClockRepo;
  auth: AuthRepo;
  /** For ERC-1271 / ERC-6492 SIWE signatures; EOA signatures are verified locally without it. */
  publicClient?: PublicClient;
  /** Next calendar boundaries per asset id (lower-case hex), if calendars are loaded. */
  nextBoundaries?: (
    assetId: Hex,
    now: number,
  ) => { at: number; kind: string }[] | undefined;
  now?: () => number; // ms
  metrics?: ApiMetrics;
  /** Markets, positions, vaults (indexer views); the core routes are mounted only when present. */
  core?: CoreRepo;
  chain?: ChainReader;
  sets?: SetStore;
  /** Account settings and the testnet allowlist; mounted only when present. */
  me?: MeRepo;
  /** Pool, epochs, auctions and the risk page (S3); mounted only when present. */
  rt?: RiskTransferRepo;
  /** NAV settlements and redemption claims (S4); mounted only when present. */
  settlement?: SettlementRepo;
  /** ADR-0014: one API serves several chains through one app per chain; they share these windows, so a client
   * gets one quota whatever chain it asks for. */
  limiters?: Limiters;
  /** Amendment 2: the in-app inbox (GET /v1/me/inbox, POST /v1/me/inbox/read); mounted only when present. */
  inbox?: InboxRepo;
  /** Amendment 2: ops alerts (GET /v1/ops/alerts; POST /v1/ops/alerts with `webhookSecret`). */
  ops?: OpsRepo;
  webhookSecret?: string;
  opsAdmins?: ReadonlySet<string>;
  /** OFF-04c: called with the session id at logout (the server ends that session's `bell:<owner>` streams). */
  onLogout?: (session: string) => void;
}

export interface Limiters {
  general: FixedWindow;
  auth: FixedWindow;
  allowlist: FixedWindow;
}

export function newLimiters(
  config: Config,
  now: () => number = Date.now,
): Limiters {
  return {
    general: new FixedWindow(config.rateLimitPerMin, 60_000, now),
    auth: new FixedWindow(config.rateLimitAuthPerMin, 60_000, now),
    allowlist: new FixedWindow(config.allowlistPerIpPerHour, 3600_000, now),
  };
}

// ── schemas ──────────────────────────────────────────────────────────────────────────────────────
const ErrorBody = z
  .object({ error: z.string(), message: z.string() })
  .openapi("Error");
const Amount = z
  .object({
    raw: z.string().openapi({ example: "180250000000000000000" }),
    formatted: z.string().openapi({ example: "180.25" }),
  })
  .openapi("WadAmount");
const Enum = z.object({ code: z.number().int(), name: z.string() });
const AssetParam = z.object({
  assetId: z
    .string()
    .min(3)
    .max(66)
    .openapi({
      param: { name: "assetId", in: "path" },
      example: "NVDA:XNAS",
      description: "bytes32 asset id or TICKER:MIC",
    }),
});
const ClockBody = z
  .object({
    assetId: z.string(),
    state: Enum,
    closureId: z.string(),
    closureType: Enum.nullable(),
    venueEpoch: z.string().nullable(),
    refPrice: Amount.nullable(),
    closeAt: z.number().nullable(),
    reopenAt: z.number().nullable(),
    openPrint: Amount.nullable(),
    openPrintAt: z.number().nullable(),
    openPrintFallback: z.boolean().nullable(),
    updatedBlock: z.string(),
    updatedAt: z.number(),
    transitions: z.array(
      z.object({
        from: Enum,
        to: Enum,
        closureId: z.string(),
        ts: z.number(),
        block: z.string(),
      }),
    ),
    feeds: z.array(
      z.object({
        feed: z.string(),
        seq: z.string(),
        price: Amount,
        observedAt: z.number(),
        ageSeconds: z.number(),
        stale: z.boolean().openapi({
          description:
            "Older than 60 s (the REGULAR staleness limit). Indexed view; the authoritative check is OracleAdapter.feedHealth.",
        }),
      }),
    ),
    next: z.array(z.object({ at: z.number(), kind: z.string() })).nullable(),
  })
  .openapi("Clock");

const closureTypeName = (c: number) =>
  Object.entries(ClosureType).find(([, v]) => v === c)?.[0] ?? `UNKNOWN_${c}`;
const wad = (v: bigint) => ({
  raw: v.toString(),
  formatted: formatUnits(v, 18),
});

export function toAssetId(p: string): Hex | undefined {
  if (isHex(p) && p.length === 66) return p.toLowerCase() as Hex;
  const m = /^([A-Za-z0-9.]{1,12}):([A-Za-z]{4,6})$/.exec(p);
  return m
    ? keccak256(stringToHex(`${m[1]!.toUpperCase()}:${m[2]!.toUpperCase()}`))
    : undefined;
}

// ── app ──────────────────────────────────────────────────────────────────────────────────────────
export function createApp(deps: Deps) {
  const { config } = deps;
  const now = deps.now ?? Date.now;
  const app = new OpenAPIHono({
    defaultHook: (result, c) => {
      if (!result.success) {
        return c.json(
          {
            error: "bad_request",
            message: result.error.issues
              .map((i) => `${i.path.join(".")}: ${i.message}`)
              .join("; "),
          },
          400,
        );
      }
    },
  });

  const metrics = deps.metrics ?? createMetrics(false);
  app.use("*", async (c, next) => {
    const t0 = performance.now();
    await next();
    // the last matched route is the handler; if only wildcard middleware matched (a 404), use one
    // shared label so a scanner cannot blow up the series count
    const last = routePath(c, -1);
    const route = last && !last.endsWith("*") ? last : "unmatched";
    const labels = {
      method: c.req.method,
      route,
      status: String(c.res.status),
    };
    metrics.duration.observe(labels, (performance.now() - t0) / 1000);
    metrics.requests.inc(labels);
  });
  app.use("*", secureHeaders());
  app.use(
    "*",
    cors({
      origin: (origin) => (config.corsOrigins.includes(origin) ? origin : null),
      credentials: true,
      allowMethods: ["GET", "POST", "PUT", "OPTIONS"],
      allowHeaders: ["content-type"],
      maxAge: 600,
    }),
  );

  const ipOf = (c: Parameters<Parameters<typeof app.use>[1]>[0]) => {
    let remote: string | undefined;
    try {
      remote = getConnInfo(c).remote.address;
    } catch {
      remote = undefined;
    }
    return clientIp(c.req.raw.headers, remote, config.trustedProxies);
  };
  const limiters = deps.limiters ?? newLimiters(config, now);
  const general = limiters.general;
  const authLimiter = limiters.auth;
  app.use(
    "/v1/*",
    rateLimit(general, (c) => {
      const keys = [`ip:${ipOf(c)}`];
      const sid = verifySession(
        config.sessionSecret,
        getCookie(c, SESSION_COOKIE),
      );
      if (sid) keys.push(`session:${sid}`);
      return keys;
    }),
  );
  app.use(
    "/v1/auth/*",
    rateLimit(authLimiter, (c) => [`auth-ip:${ipOf(c)}`]),
  );

  app.onError((err, c) => {
    log.error({ err, path: c.req.path }, "unhandled error");
    return c.json({ error: "internal", message: "Internal error" }, 500);
  });

  // health
  app.get("/healthz", (c) => c.text("credence-api ok\n"));
  app.get("/metrics", async (c) =>
    c.text(await metrics.registry.metrics(), 200, {
      "content-type": metrics.registry.contentType,
    }),
  );
  app.get("/readyz", async (c) => {
    try {
      await deps.clock.ping();
      return c.text("ready\n");
    } catch {
      return c.text("not ready\n", 503);
    }
  });

  // GET /v1/clock/:assetId
  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/clock/{assetId}",
      summary:
        "Clock state, closure info, recent transitions, feed freshness and next calendar boundaries",
      request: { params: AssetParam },
      responses: {
        200: {
          description: "The asset's clock",
          content: { "application/json": { schema: ClockBody } },
        },
        400: {
          description: "Bad asset id",
          content: { "application/json": { schema: ErrorBody } },
        },
        404: {
          description: "Not indexed yet",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const id = toAssetId(c.req.valid("param").assetId);
      if (!id)
        return c.json(
          {
            error: "bad_request",
            message: "assetId must be a bytes32 hex id or TICKER:MIC",
          },
          400,
        );
      const row = await deps.clock.clock(id);
      if (!row)
        return c.json(
          { error: "not_found", message: `no clock indexed for ${id}` },
          404,
        );
      const [transitions, feeds] = await Promise.all([
        deps.clock.transitions(id, 20),
        deps.clock.latestLive(id),
      ]);
      const t = Math.floor(now() / 1000);
      const e = (code: number) => ({ code, name: clockStateName(code) });
      return c.json(
        {
          assetId: id,
          state: e(row.state),
          closureId: row.closureId.toString(),
          closureType:
            row.closureType === null
              ? null
              : {
                  code: row.closureType,
                  name: closureTypeName(row.closureType),
                },
          venueEpoch: row.venueEpoch?.toString() ?? null,
          refPrice: row.refPrice === null ? null : wad(row.refPrice),
          closeAt: row.closeAt === null ? null : Number(row.closeAt),
          reopenAt: row.reopenAt === null ? null : Number(row.reopenAt),
          openPrint: row.openPrint === null ? null : wad(row.openPrint),
          openPrintAt:
            row.openPrintAt === null ? null : Number(row.openPrintAt),
          openPrintFallback: row.openPrintFallback,
          updatedBlock: row.updatedBlock.toString(),
          updatedAt: Number(row.updatedAt),
          transitions: transitions.map((x) => ({
            from: e(x.from),
            to: e(x.to),
            closureId: x.closureId.toString(),
            ts: Number(x.ts),
            block: x.block.toString(),
          })),
          feeds: feeds.map((f) => {
            const age = Math.max(0, t - Number(f.observedAt));
            return {
              feed: f.feed,
              seq: f.seq.toString(),
              price: wad(f.price),
              observedAt: Number(f.observedAt),
              ageSeconds: age,
              stale: age > 60,
            };
          }),
          next: deps.nextBoundaries?.(id, t) ?? null,
        },
        200,
      );
    },
  );

  const pc = deps.publicClient;
  const coreDeps: CoreDeps | undefined = deps.core
    ? {
        core: deps.core,
        clock: deps.clock,
        chain: deps.chain,
        sets: deps.sets,
        cushion:
          pc && deps.rt
            ? (m, borrows, block) =>
                stackCushion(pc, m as Address, borrows, block)
            : undefined,
      }
    : undefined;
  if (coreDeps) registerCoreRoutes(app, coreDeps);
  if (deps.rt)
    registerRiskTransferRoutes(app, {
      rt: deps.rt,
      core: deps.core,
      client: pc,
      settlement: deps.settlement,
      safeLtvs: coreDeps ? () => safeLtvsOf(coreDeps) : undefined,
    });
  if (deps.settlement)
    registerSettlementRoutes(app, { settlement: deps.settlement, now });
  if (deps.inbox)
    registerInboxRoutes(app, {
      auth: deps.auth,
      inbox: deps.inbox,
      ops: deps.ops,
      sessionSecret: config.sessionSecret,
      now,
      webhookSecret: deps.webhookSecret,
      opsAdmins: deps.opsAdmins ?? new Set(),
    });
  if (deps.me) {
    registerMeRoutes(app, {
      auth: deps.auth,
      me: deps.me,
      sessionSecret: config.sessionSecret,
      publicApiOrigin: config.publicApiUrl,
      now,
      allowlistEnabled: config.allowlistEnabled,
      allowlistChains: config.allowlistChains ?? [config.chainId],
      allowlistPerIpPerHour: config.allowlistPerIpPerHour,
      allowlistLimiter: limiters.allowlist,
      ipOf,
    });
  }

  // SIWE
  app.openapi(
    createRoute({
      method: "post",
      path: "/v1/auth/siwe/nonce",
      summary: "Issue a single-use SIWE nonce (10 min)",
      responses: {
        200: {
          description: "Nonce",
          content: {
            "application/json": {
              schema: z.object({
                nonce: z.string(),
                domain: z.string(),
                chainId: z.number(),
              }),
            },
          },
        },
      },
    }),
    async (c) => {
      const nonce = newNonce();
      await deps.auth.putNonce(nonce, new Date(now() + 10 * 60_000));
      return c.json(
        { nonce, domain: config.siweDomain, chainId: config.chainId },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "post",
      path: "/v1/auth/siwe/verify",
      summary: "Verify an EIP-4361 message and start an httpOnly session",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                message: z.string().min(1).max(4096),
                signature: z
                  .string()
                  .regex(/^0x[0-9a-fA-F]+$/)
                  .max(4096),
              }),
            },
          },
        },
      },
      responses: {
        200: {
          description: "Signed in",
          content: {
            "application/json": {
              schema: z.object({ address: z.string(), expiresAt: z.number() }),
            },
          },
        },
        401: {
          description: "Rejected",
          content: { "application/json": { schema: ErrorBody } },
        },
      },
    }),
    async (c) => {
      const { message, signature } = c.req.valid("json");
      const deny = (why: string) =>
        c.json({ error: "unauthorized", message: why }, 401);
      let parsed: ReturnType<typeof parseSiweMessage>;
      try {
        parsed = parseSiweMessage(message);
      } catch {
        return deny("malformed SIWE message");
      }
      if (!parsed.address || !parsed.nonce)
        return deny("malformed SIWE message");
      if (
        !validateSiweMessage({
          message: parsed,
          domain: config.siweDomain,
          time: new Date(now()),
        })
      ) {
        return deny("wrong domain, expired or not yet valid");
      }
      const siweChains = config.siweChainIds ?? [config.chainId];
      if (parsed.chainId === undefined || !siweChains.includes(parsed.chainId))
        return deny(`wrong chain (expected ${siweChains.join(" or ")})`);
      if (!(await deps.auth.takeNonce(parsed.nonce, new Date(now()))))
        return deny("unknown, used or expired nonce");
      const ok = deps.publicClient
        ? await deps.publicClient.verifySiweMessage({
            message,
            signature: signature as Hex,
          })
        : await verifyMessage({
            address: parsed.address,
            message,
            signature: signature as Hex,
          });
      if (!ok) return deny("bad signature");
      const id = newSessionId();
      const expiresAt = now() + config.sessionTtlS * 1000;
      await deps.auth.createSession(
        id,
        parsed.address as Address,
        parsed.nonce,
        new Date(expiresAt),
      );
      setCookie(c, SESSION_COOKIE, signSession(config.sessionSecret, id), {
        httpOnly: true,
        secure: config.secureCookies,
        sameSite: "Lax",
        path: "/",
        maxAge: config.sessionTtlS,
      });
      return c.json(
        { address: parsed.address, expiresAt: Math.floor(expiresAt / 1000) },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "get",
      path: "/v1/auth/session",
      summary: "The signed-in address, if any",
      responses: {
        200: {
          description: "Session",
          content: {
            "application/json": {
              schema: z.object({ address: z.string(), expiresAt: z.number() }),
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
      const id = verifySession(
        config.sessionSecret,
        getCookie(c, SESSION_COOKIE),
      );
      const s = id
        ? await deps.auth.getSession(id, new Date(now()))
        : undefined;
      if (!s)
        return c.json({ error: "unauthorized", message: "not signed in" }, 401);
      return c.json(
        {
          address: s.address,
          expiresAt: Math.floor(s.expiresAt.getTime() / 1000),
        },
        200,
      );
    },
  );

  app.openapi(
    createRoute({
      method: "post",
      path: "/v1/auth/logout",
      summary: "End the session",
      responses: { 204: { description: "Signed out" } },
    }),
    async (c) => {
      const id = verifySession(
        config.sessionSecret,
        getCookie(c, SESSION_COOKIE),
      );
      if (id) {
        await deps.auth.deleteSession(id);
        deps.onLogout?.(id);
      }
      deleteCookie(c, SESSION_COOKIE, { path: "/" });
      return c.body(null, 204);
    },
  );

  app.doc31("/v1/openapi.json", {
    openapi: "3.1.0",
    info: {
      title: "Credence Finance API",
      version: "0.1.0",
      description:
        "Build Guide §10.4. Amounts are decimal strings in base units plus a formatted field.",
    },
  });

  return app;
}

export { ClockState };
