// WS /v1/stream: the hub (subscriptions, filters, cursors, batching) and a real WebSocket round trip.
import { describe, expect, it } from "vitest";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { keccak256, stringToHex, type Hex } from "viem";
import { toAssetId } from "../src/app.ts";
import { StreamHub, attachStream, wholeBlocks, type ClockEvent, type PriceEvent, type Socket, type StreamSource } from "../src/stream.ts";

const NVDA = keccak256(stringToHex("NVDA:XNAS")) as Hex;
const AAPL = keccak256(stringToHex("AAPL:XNAS")) as Hex;

class FakeSource implements StreamSource {
  clock: ClockEvent[] = [];
  prices: PriceEvent[] = [];
  headBlock = 10n;
  async head() {
    return this.headBlock;
  }
  async clockSince(b: bigint, limit: number) {
    return this.clock.filter((e) => e.block > b).slice(0, limit);
  }
  async pricesSince(b: bigint, limit: number) {
    return this.prices.filter((e) => e.block > b).slice(0, limit);
  }
}
const price = (assetId: Hex, block: bigint, seq: bigint): PriceEvent => ({ assetId, feed: "A", seq, kind: 0, price: 181_330_000_000_000_000_000n, observedAt: 1_791_380_000n, status: 2, block });
class FakeSocket implements Socket {
  sent: Record<string, unknown>[] = [];
  closed = false;
  send(d: string) {
    this.sent.push(JSON.parse(d));
  }
  close() {
    this.closed = true;
  }
}

describe("StreamHub", () => {
  it("first poll positions the cursor at the head; later rows go only to matching subscribers", async () => {
    const src = new FakeSource();
    src.prices.push(price(NVDA, 5n, 1n)); // history before the head: never replayed
    const hub = new StreamHub(src, toAssetId);
    const all = new FakeSocket();
    const onlyAapl = new FakeSocket();
    const clockOnly = new FakeSocket();
    for (const s of [all, onlyAapl, clockOnly]) hub.add(s);
    hub.message(all, JSON.stringify({ op: "subscribe", channels: ["clock", "prices"] }));
    hub.message(onlyAapl, JSON.stringify({ op: "subscribe", channels: ["prices"], assets: ["AAPL:XNAS"] }));
    hub.message(clockOnly, JSON.stringify({ op: "subscribe", channels: ["clock"] }));
    expect(onlyAapl.sent[0]).toEqual({ type: "subscribed", channels: ["prices"], assets: [AAPL] });
    await hub.poll();
    src.prices.push(price(NVDA, 11n, 2n), price(AAPL, 12n, 7n));
    src.clock.push({ assetId: NVDA, from: 2, to: 3, closureId: 4n, block: 12n, ts: 1_791_379_801n });
    await hub.poll();
    const frames = (s: FakeSocket) => s.sent.filter((f) => "channel" in f);
    expect(frames(all).map((f) => f.channel)).toEqual(["clock", "prices", "prices"]);
    expect(frames(onlyAapl)).toEqual([
      { channel: "prices", data: { assetId: AAPL, feed: "A", seq: "7", kind: 0, price: { raw: "181330000000000000000", formatted: "181.33" }, observedAt: 1_791_380_000, status: 2, block: "12" } },
    ]);
    expect(frames(clockOnly)).toEqual([{ channel: "clock", data: { assetId: NVDA, from: { code: 2, name: "CLOSED" }, to: { code: 3, name: "REOPEN" }, closureId: "4", block: "12", ts: 1_791_379_801 } }]);
    await hub.poll(); // nothing new: nothing sent
    expect(frames(all)).toHaveLength(3);
  });

  it("unsubscribe, bad frames and unknown channels", async () => {
    const hub = new StreamHub(new FakeSource(), toAssetId);
    const s = new FakeSocket();
    hub.add(s);
    hub.message(s, "not json");
    hub.message(s, JSON.stringify({ op: "subscribe", channels: ["auctions"] }));
    hub.message(s, JSON.stringify({ op: "subscribe", channels: ["clock"], assets: ["nope"] }));
    hub.message(s, JSON.stringify({ op: "dance" }));
    expect(s.sent.map((f) => f.type)).toEqual(["error", "error", "error", "error"]);
    hub.message(s, JSON.stringify({ op: "subscribe", channels: ["clock", "prices"] }));
    hub.message(s, JSON.stringify({ op: "unsubscribe", channels: ["prices"] }));
    expect(s.sent.at(-1)).toEqual({ type: "subscribed", channels: ["clock"], assets: null });
    hub.remove(s);
    expect(hub.size()).toBe(0);
  });

  it("a full batch never ends mid-block", () => {
    const rows = [1n, 2n, 2n, 3n, 3n].map((block) => ({ block }));
    expect(wholeBlocks(rows, 5).map((r) => r.block)).toEqual([1n, 2n, 2n]);
    expect(wholeBlocks(rows, 6)).toHaveLength(5);
    expect(wholeBlocks([{ block: 9n }, { block: 9n }], 2)).toHaveLength(2); // one huge block: take it
  });
});

describe("WS /v1/stream end to end (Node 24 global WebSocket client)", () => {
  it("upgrades, subscribes and receives a price pushed after connect", async () => {
    const src = new FakeSource();
    const hub = new StreamHub(src, toAssetId, { pollMs: 20, batch: 500, maxAssets: 100 });
    const app = new Hono();
    const inject = await attachStream(app, hub);
    const server = serve({ fetch: app.fetch, port: 0 });
    inject(server);
    await new Promise((r) => server.once("listening", r));
    const port = (server.address() as { port: number }).port;
    hub.start(() => {});
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/stream`);
      const got: Record<string, unknown>[] = [];
      ws.addEventListener("message", (e) => got.push(JSON.parse(String(e.data))));
      await new Promise((r) => ws.addEventListener("open", r, { once: true }));
      ws.send(JSON.stringify({ op: "subscribe", channels: ["prices"], assets: [NVDA] }));
      await until(() => got.some((f) => f.type === "subscribed"));
      src.prices.push(price(NVDA, 11n, 3n), price(AAPL, 11n, 4n));
      await until(() => got.some((f) => f.channel === "prices"));
      expect(got.filter((f) => f.channel === "prices")).toHaveLength(1);
      expect((got.find((f) => f.channel === "prices")!.data as { seq: string }).seq).toBe("3");
      ws.close();
      await until(() => hub.size() === 0);
    } finally {
      hub.stop();
      server.close();
    }
  });
});

async function until(ok: () => boolean, ms = 3000) {
  const t = Date.now();
  while (!ok()) {
    if (Date.now() - t > ms) throw new Error("timeout");
    await new Promise((r) => setTimeout(r, 10));
  }
}
