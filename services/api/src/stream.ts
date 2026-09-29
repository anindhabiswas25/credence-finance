// WS /v1/stream (Build Guide §10.4): the `clock`, `prices`, `auctions` and `bell:<owner>` channels. One
// hub per process polls the indexer views for rows newer than its cursor and fans them out to the sockets
// subscribed to that channel (optionally filtered by asset). `bell:<owner>` (the owner's Bell, cover,
// queue and settlement events) needs a SIWE session for that address: the socket's session cookie is
// checked at the upgrade, and the channel is refused for any other address.
//
// Protocol (JSON text frames):
//   → {"op":"subscribe","channels":["clock","prices","auctions","bell:0x…"],"assets":["NVDA:XNAS" | "0x…"]?}
//   → {"op":"unsubscribe","channels":["prices"]}
//   ← {"type":"subscribed","channels":[…],"assets":[…]|null}
//   ← {"channel":"clock","data":{assetId,from,to,closureId,block,ts}}
//   ← {"channel":"prices","data":{assetId,feed,seq,kind,price:{raw,formatted},observedAt,status,block}}
//   ← {"channel":"auctions","data":{auctionId,kind,assetId,closureId,status,deadlines,lot,reserve,pStar,…,block}}
//   ← {"channel":"bell:0x…","data":{marketId,kind,amounts,clockState,block,ts,txHash}}
//   ← {"type":"error","message":…}
import type { Hono } from "hono";
import { formatUnits, type Hex } from "viem";
import { clockStateName } from "@credence/sdk";

export const CHANNELS = ["clock", "prices", "auctions"] as const;
export type Channel = (typeof CHANNELS)[number] | `bell:${string}`;
const BELL = /^bell:(0x[0-9a-fA-F]{40})$/;

export interface AuctionEvent {
  auctionId: bigint;
  kind: number;
  assetId: Hex;
  marketId: Hex;
  closureId: bigint;
  tranche: number;
  status: string;
  deadlines: number[];
  lot: bigint | null;
  reserve: bigint | null;
  bids: number;
  pStar: bigint | null;
  qPool: bigint | null;
  proceeds: bigint | null;
  block: bigint;
}
/** One row of the owner's position history (`position_event`). */
export interface OwnerEvent {
  owner: Hex;
  marketId: Hex | null;
  kind: string;
  amounts: unknown;
  clockState: number | null;
  block: bigint;
  ts: bigint;
  txHash: Hex;
}

export interface ClockEvent {
  assetId: Hex;
  from: number;
  to: number;
  closureId: bigint;
  block: bigint;
  ts: bigint;
}
export interface PriceEvent {
  assetId: Hex;
  feed: string;
  seq: bigint;
  kind: number;
  price: bigint;
  observedAt: bigint;
  status: number | null;
  block: bigint;
}

/** Rows strictly after the cursor block, oldest first (at most `limit`). */
export interface StreamSource {
  head(): Promise<bigint>;
  clockSince(block: bigint, limit: number): Promise<ClockEvent[]>;
  pricesSince(block: bigint, limit: number): Promise<PriceEvent[]>;
  auctionsSince(block: bigint, limit: number): Promise<AuctionEvent[]>;
  ownerEventsSince(block: bigint, limit: number): Promise<OwnerEvent[]>;
}

export interface Socket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

interface Sub {
  channels: Set<Channel>;
  assets: Set<string> | null;
  /** The SIWE-authenticated address of this socket (lower-case), if any. */
  owner: string | null;
}

/** A full batch may end mid-block: drop the trailing block (the next poll re-reads it whole). */
export function wholeBlocks<T extends { block: bigint }>(
  rows: T[],
  batch: number,
): T[] {
  if (rows.length < batch || rows.length === 0) return rows;
  const last = rows[rows.length - 1]!.block;
  const cut = rows.filter((r) => r.block < last);
  return cut.length > 0 ? cut : rows;
}

export class StreamHub {
  private subs = new Map<Socket, Sub>();
  private cursorClock = -1n;
  private cursorPrices = -1n;
  private cursorAuctions = -1n;
  private cursorOwners = -1n;
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  private readonly source: StreamSource;
  private readonly toAssetId: (s: string) => Hex | undefined;
  private readonly opts: { pollMs: number; batch: number; maxAssets: number };

  constructor(
    source: StreamSource,
    toAssetId: (s: string) => Hex | undefined,
    opts: { pollMs: number; batch: number; maxAssets: number } = {
      pollMs: 1000,
      batch: 500,
      maxAssets: 100,
    },
  ) {
    this.source = source;
    this.toAssetId = toAssetId;
    this.opts = opts;
  }

  size(): number {
    return this.subs.size;
  }

  /** `owner`: the address of the socket's SIWE session (checked at the upgrade), if any. */
  add(ws: Socket, owner?: string | null): void {
    this.subs.set(ws, {
      channels: new Set(),
      assets: null,
      owner: owner ? owner.toLowerCase() : null,
    });
  }

  remove(ws: Socket): void {
    this.subs.delete(ws);
  }

  /** Handle one client frame. */
  message(ws: Socket, raw: string): void {
    const sub = this.subs.get(ws);
    if (!sub) return;
    let m: { op?: unknown; channels?: unknown; assets?: unknown };
    try {
      m = JSON.parse(raw);
    } catch {
      return this.err(ws, "frames must be JSON");
    }
    const channels = Array.isArray(m.channels) ? m.channels : [];
    const bad = channels.find(
      (c) =>
        !CHANNELS.includes(c as (typeof CHANNELS)[number]) &&
        !(typeof c === "string" && BELL.test(c)),
    );
    if (bad !== undefined)
      return this.err(
        ws,
        `unknown channel ${JSON.stringify(bad)} (available: ${CHANNELS.join(", ")}, bell:<owner>)`,
      );
    if (m.op === "subscribe") {
      const denied = channels.find((c) => {
        const x = typeof c === "string" ? BELL.exec(c) : null;
        return x !== null && x[1]!.toLowerCase() !== sub.owner;
      });
      if (denied !== undefined)
        return this.err(
          ws,
          `${String(denied)} needs a SIWE session for that address (POST /v1/auth/siwe/verify, then reconnect)`,
        );
    }
    if (m.op === "subscribe") {
      for (const c of channels)
        sub.channels.add(
          (BELL.test(c as string) ? (c as string).toLowerCase() : c) as Channel,
        );
      if (m.assets !== undefined) {
        if (!Array.isArray(m.assets) || m.assets.length > this.opts.maxAssets)
          return this.err(
            ws,
            `assets must be an array of at most ${this.opts.maxAssets}`,
          );
        const ids = m.assets.map((a) =>
          typeof a === "string" ? this.toAssetId(a) : undefined,
        );
        if (ids.some((x) => !x))
          return this.err(ws, "assets must be bytes32 ids or TICKER:MIC");
        sub.assets = new Set(ids as string[]);
      }
    } else if (m.op === "unsubscribe") {
      for (const c of channels)
        sub.channels.delete(
          (typeof c === "string" ? c.toLowerCase() : c) as Channel,
        );
    } else {
      return this.err(ws, 'op must be "subscribe" or "unsubscribe"');
    }
    ws.send(
      JSON.stringify({
        type: "subscribed",
        channels: [...sub.channels],
        assets: sub.assets ? [...sub.assets] : null,
      }),
    );
  }

  private err(ws: Socket, message: string) {
    ws.send(JSON.stringify({ type: "error", message }));
  }

  private broadcast(channel: Channel, assetId: string | null, data: unknown) {
    const frame = JSON.stringify({ channel, data });
    for (const [ws, s] of this.subs) {
      if (!s.channels.has(channel)) continue;
      if (assetId !== null && s.assets && !s.assets.has(assetId.toLowerCase()))
        continue;
      try {
        ws.send(frame);
      } catch {
        this.subs.delete(ws);
      }
    }
  }

  /** One poll: new rows since the cursors are broadcast; the first poll only positions the cursors. */
  async poll(): Promise<void> {
    if (this.cursorClock < 0n || this.cursorPrices < 0n) {
      const h = await this.source.head();
      this.cursorClock =
        this.cursorPrices =
        this.cursorAuctions =
        this.cursorOwners =
          h;
      return;
    }
    const [auctions, owners] = await Promise.all([
      this.source
        .auctionsSince(this.cursorAuctions, this.opts.batch)
        .then((r) => wholeBlocks(r, this.opts.batch)),
      this.source
        .ownerEventsSince(this.cursorOwners, this.opts.batch)
        .then((r) => wholeBlocks(r, this.opts.batch)),
    ]);
    const s = (v: bigint | null) => (v === null ? null : v.toString());
    for (const a of auctions) {
      this.broadcast("auctions", a.assetId, {
        auctionId: a.auctionId.toString(),
        kind: a.kind,
        assetId: a.assetId,
        marketId: a.marketId,
        closureId: a.closureId.toString(),
        tranche: a.tranche,
        status: a.status,
        deadlines: a.deadlines,
        lot: s(a.lot),
        reserve: s(a.reserve),
        bids: a.bids,
        pStar: s(a.pStar),
        qPool: s(a.qPool),
        proceeds: s(a.proceeds),
        block: a.block.toString(),
      });
      if (a.block > this.cursorAuctions) this.cursorAuctions = a.block;
    }
    for (const e of owners) {
      this.broadcast(`bell:${e.owner.toLowerCase()}`, null, {
        marketId: e.marketId,
        kind: e.kind,
        amounts: e.amounts,
        clockState: e.clockState,
        block: e.block.toString(),
        ts: Number(e.ts),
        txHash: e.txHash,
      });
      if (e.block > this.cursorOwners) this.cursorOwners = e.block;
    }
    const [clock, prices] = await Promise.all([
      this.source
        .clockSince(this.cursorClock, this.opts.batch)
        .then((r) => wholeBlocks(r, this.opts.batch)),
      this.source
        .pricesSince(this.cursorPrices, this.opts.batch)
        .then((r) => wholeBlocks(r, this.opts.batch)),
    ]);
    for (const e of clock) {
      this.broadcast("clock", e.assetId, {
        assetId: e.assetId,
        from: { code: e.from, name: clockStateName(e.from) },
        to: { code: e.to, name: clockStateName(e.to) },
        closureId: e.closureId.toString(),
        block: e.block.toString(),
        ts: Number(e.ts),
      });
      if (e.block > this.cursorClock) this.cursorClock = e.block;
    }
    for (const p of prices) {
      this.broadcast("prices", p.assetId, {
        assetId: p.assetId,
        feed: p.feed,
        seq: p.seq.toString(),
        kind: p.kind,
        price: { raw: p.price.toString(), formatted: formatUnits(p.price, 18) },
        observedAt: Number(p.observedAt),
        status: p.status,
        block: p.block.toString(),
      });
      if (p.block > this.cursorPrices) this.cursorPrices = p.block;
    }
  }

  start(onError: (e: unknown) => void): void {
    if (this.timer) return;
    const tick = async () => {
      if (this.running) return;
      this.running = true;
      try {
        await this.poll();
      } catch (e) {
        onError(e);
      } finally {
        this.running = false;
      }
    };
    this.timer = setInterval(tick, this.opts.pollMs);
    void tick();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    for (const ws of this.subs.keys()) ws.close(1001, "server shutting down");
    this.subs.clear();
  }
}

/**
 * Mount `GET /v1/stream` (WebSocket upgrade) on a Node server. Returns `injectWebSocket(server)`, to
 * call once `serve()` has returned. The hub keys sockets by the underlying `ws` object.
 */
/** OFF-04: the largest client message accepted on /v1/stream (subscribe / unsubscribe are ~100 bytes). */
export const MAX_MESSAGE_BYTES = 16 * 1024;

/** OFF-04: no Origin (a non-browser client) or an origin on the allowlist; everything when no list is set. */
export function originAllowed(
  origin: string | undefined,
  allowed: readonly string[],
): boolean {
  if (!origin || allowed.length === 0) return true;
  return allowed.includes(origin.replace(/\/$/, "").toLowerCase());
}

export async function attachStream(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  app: Hono<any, any, any>,
  hub: StreamHub,
  /** The SIWE session's address for the upgrade request's cookie header, if valid. */
  sessionOwner: (
    cookieHeader: string | undefined,
  ) => Promise<string | undefined> = async () => undefined,
  /** OFF-04: browser origins allowed to open a socket (the CORS allowlist); empty = no Origin check. */
  allowedOrigins: readonly string[] = [],
) {
  const { createNodeWebSocket } = await import("@hono/node-ws");
  const { injectWebSocket, upgradeWebSocket } = createNodeWebSocket({ app });
  const sockets = new WeakMap<object, Socket>();
  const of = (ws: {
    raw?: unknown;
    send: (d: string) => void;
    close: (c?: number, r?: string) => void;
  }) => {
    const key = (ws.raw ?? ws) as object;
    let s = sockets.get(key);
    if (!s) {
      s = { send: (d) => ws.send(d), close: (c, r) => ws.close(c, r) };
      sockets.set(key, s);
    }
    return s;
  };
  app.get(
    "/v1/stream",
    // OFF-04: a cross-site page must not open a socket with the user's cookie (non-browser clients send no Origin)
    async (c, next) => {
      if (!originAllowed(c.req.header("origin"), allowedOrigins))
        return c.json(
          { error: "forbidden", message: "origin not allowed" },
          403,
        );
      await next();
    },
    upgradeWebSocket(async (c) => {
      const owner = await sessionOwner(c.req.header("cookie")).catch(
        () => undefined,
      );
      return {
        onOpen: (_e, ws) => hub.add(of(ws), owner),
        onMessage: (e, ws) => {
          const text = typeof e.data === "string" ? e.data : String(e.data);
          // OFF-04: subscribe messages are tiny; refuse anything big before parsing it
          if (text.length > MAX_MESSAGE_BYTES) {
            ws.close(1009, "message too big");
            return;
          }
          hub.message(of(ws), text);
        },
        onClose: (_e, ws) => hub.remove(of(ws)),
        onError: (_e, ws) => hub.remove(of(ws)),
      };
    }),
  );
  return injectWebSocket;
}
