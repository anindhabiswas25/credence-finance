// Fixed-window rate limits per client IP and, when signed in, per address (§10.4 "rate limits per IP
// and per address"). In-process: each API replica limits independently; a shared store comes with the
// production deploy (S5).
import type { MiddlewareHandler } from "hono";

export class FixedWindow {
  private hits = new Map<string, { windowStart: number; count: number }>();
  private readonly limit: number;
  private readonly windowMs: number;
  private readonly now: () => number;

  constructor(limit: number, windowMs = 60_000, now: () => number = Date.now) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
  }

  /** Returns remaining requests, or -1 when the key is over its limit. */
  take(key: string): { remaining: number; resetMs: number } {
    const t = this.now();
    let e = this.hits.get(key);
    if (!e || t - e.windowStart >= this.windowMs) {
      e = { windowStart: t, count: 0 };
      this.hits.set(key, e);
    }
    e.count++;
    if (this.hits.size > 100_000) this.gc(t);
    return {
      remaining: e.count <= this.limit ? this.limit - e.count : -1,
      resetMs: e.windowStart + this.windowMs - t,
    };
  }

  private gc(t: number) {
    for (const [k, v] of this.hits)
      if (t - v.windowStart >= this.windowMs) this.hits.delete(k);
  }
}

/**
 * The client address for per-IP limits (OFF-03). X-Forwarded-For is client-controlled, so it is read only
 * when the socket peer is one of our proxies; then the right-most hop that is not a trusted proxy is the
 * client (every proxy appends the address it saw). Without trusted proxies the socket address is the client.
 */
export function clientIp(
  headers: Headers,
  remote?: string,
  trustedProxies: readonly string[] = [],
): string {
  const norm = (a: string) =>
    a
      .trim()
      .toLowerCase()
      .replace(/^::ffff:/, "");
  const peer = remote ? norm(remote) : undefined;
  const trusted = new Set(trustedProxies.map(norm));
  if (!peer || !trusted.has(peer)) return peer || "unknown";
  const hops = (headers.get("x-forwarded-for") ?? "")
    .split(",")
    .map(norm)
    .filter(Boolean);
  for (let i = hops.length - 1; i >= 0; i--)
    if (!trusted.has(hops[i]!)) return hops[i]!;
  return peer;
}

export function rateLimit(
  limiter: FixedWindow,
  keyOf: (c: Parameters<MiddlewareHandler>[0]) => string[],
): MiddlewareHandler {
  return async (c, next) => {
    for (const key of keyOf(c)) {
      const r = limiter.take(key);
      if (r.remaining < 0) {
        c.header("retry-after", String(Math.ceil(r.resetMs / 1000)));
        return c.json(
          { error: "rate_limited", message: "Too many requests; slow down." },
          429,
        );
      }
      c.header("x-ratelimit-remaining", String(r.remaining));
    }
    await next();
  };
}
