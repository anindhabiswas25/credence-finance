// WS /v1/stream (Build Guide §10.4): the `clock` and `prices` channels. One hub per process polls the
// indexer views for rows newer than its cursor and fans them out to the sockets subscribed to that
// channel (optionally filtered by asset). `auctions` and `bell:<owner>` join with the S3 contracts.
//
// Protocol (JSON text frames):
//   → {"op":"subscribe","channels":["clock","prices"],"assets":["NVDA:XNAS" | "0x…"]?}
//   → {"op":"unsubscribe","channels":["prices"]}
//   ← {"type":"subscribed","channels":[…],"assets":[…]|null}
//   ← {"channel":"clock","data":{assetId,from,to,closureId,block,ts}}
//   ← {"channel":"prices","data":{assetId,feed,seq,kind,price:{raw,formatted},observedAt,status,block}}
//   ← {"type":"error","message":…}
import type { Hono } from "hono";
import { formatUnits, type Hex } from "viem";
import { clockStateName } from "@credence/sdk";

export const CHANNELS = ["clock", "prices"] as const;
export type Channel = (typeof CHANNELS)[number];

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
}

export interface Socket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

interface Sub {
  channels: Set<Channel>;
  assets: Set<string> | null;
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

  add(ws: Socket): void {
    this.subs.set(ws, { channels: new Set(), assets: null });
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
    const bad = channels.find((c) => !CHANNELS.includes(c as Channel));
    if (bad !== undefined)
      return this.err(
        ws,
        `unknown channel ${JSON.stringify(bad)} (available: ${CHANNELS.join(", ")})`,
      );
    if (m.op === "subscribe") {
      for (const c of channels) sub.channels.add(c as Channel);
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
      for (const c of channels) sub.channels.delete(c as Channel);
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

  private broadcast(channel: Channel, assetId: string, data: unknown) {
    const frame = JSON.stringify({ channel, data });
    for (const [ws, s] of this.subs) {
      if (!s.channels.has(channel)) continue;
      if (s.assets && !s.assets.has(assetId.toLowerCase())) continue;
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
      this.cursorClock = this.cursorPrices = h;
      return;
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
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function attachStream(app: Hono<any, any, any>, hub: StreamHub) {
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
    upgradeWebSocket(() => ({
      onOpen: (_e, ws) => hub.add(of(ws)),
      onMessage: (e, ws) =>
        hub.message(
          of(ws),
          typeof e.data === "string" ? e.data : String(e.data),
        ),
      onClose: (_e, ws) => hub.remove(of(ws)),
      onError: (_e, ws) => hub.remove(of(ws)),
    })),
  );
  return injectWebSocket;
}
