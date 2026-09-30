// WS /v1/stream: the hub (subscriptions, filters, cursors, batching) and a real WebSocket round trip.
import { describe, expect, it } from "vitest";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { keccak256, stringToHex, type Hex } from "viem";
import { toAssetId } from "../src/app.ts";
import {
  StreamHub,
  attachStream,
  wholeBlocks,
  type ClockEvent,
  type PriceEvent,
  type Socket,
  type StreamSource,
  type AuctionEvent,
  type OwnerEvent,
} from "../src/stream.ts";

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
  auctions: AuctionEvent[] = [];
  owners: OwnerEvent[] = [];
  async auctionsSince(b: bigint, limit: number) {
    return this.auctions.filter((e) => e.block > b).slice(0, limit);
  }
  async ownerEventsSince(b: bigint, limit: number) {
    return this.owners.filter((e) => e.block > b).slice(0, limit);
  }
}
const price = (assetId: Hex, block: bigint, seq: bigint): PriceEvent => ({
  assetId,
  feed: "A",
  seq,
  kind: 0,
  price: 181_330_000_000_000_000_000n,
  observedAt: 1_791_380_000n,
  status: 2,
  block,
});
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
    hub.message(
      all,
      JSON.stringify({ op: "subscribe", channels: ["clock", "prices"] }),
    );
    hub.message(
      onlyAapl,
      JSON.stringify({
        op: "subscribe",
        channels: ["prices"],
        assets: ["AAPL:XNAS"],
      }),
    );
    hub.message(
      clockOnly,
      JSON.stringify({ op: "subscribe", channels: ["clock"] }),
    );
    expect(onlyAapl.sent[0]).toEqual({
      type: "subscribed",
      channels: ["prices"],
      assets: [AAPL],
    });
    await hub.poll();
    src.prices.push(price(NVDA, 11n, 2n), price(AAPL, 12n, 7n));
    src.clock.push({
      assetId: NVDA,
      from: 2,
      to: 3,
      closureId: 4n,
      block: 12n,
      ts: 1_791_379_801n,
    });
    await hub.poll();
    const frames = (s: FakeSocket) => s.sent.filter((f) => "channel" in f);
    expect(frames(all).map((f) => f.channel)).toEqual([
      "clock",
      "prices",
      "prices",
    ]);
    expect(frames(onlyAapl)).toEqual([
      {
        channel: "prices",
        data: {
          assetId: AAPL,
          feed: "A",
          seq: "7",
          kind: 0,
          price: { raw: "181330000000000000000", formatted: "181.33" },
          observedAt: 1_791_380_000,
          status: 2,
          block: "12",
        },
      },
    ]);
    expect(frames(clockOnly)).toEqual([
      {
        channel: "clock",
        data: {
          assetId: NVDA,
          from: { code: 2, name: "CLOSED" },
          to: { code: 3, name: "REOPEN" },
          closureId: "4",
          block: "12",
          ts: 1_791_379_801,
        },
      },
    ]);
    await hub.poll(); // nothing new: nothing sent
    expect(frames(all)).toHaveLength(3);
  });

  it("unsubscribe, bad frames and unknown channels", async () => {
    const hub = new StreamHub(new FakeSource(), toAssetId);
    const s = new FakeSocket();
    hub.add(s);
    hub.message(s, "not json");
    hub.message(s, JSON.stringify({ op: "subscribe", channels: ["gossip"] }));
    hub.message(
      s,
      JSON.stringify({
        op: "subscribe",
        channels: ["clock"],
        assets: ["nope"],
      }),
    );
    hub.message(s, JSON.stringify({ op: "dance" }));
    expect(s.sent.map((f) => f.type)).toEqual([
      "error",
      "error",
      "error",
      "error",
    ]);
    hub.message(
      s,
      JSON.stringify({ op: "subscribe", channels: ["clock", "prices"] }),
    );
    hub.message(s, JSON.stringify({ op: "unsubscribe", channels: ["prices"] }));
    expect(s.sent.at(-1)).toEqual({
      type: "subscribed",
      channels: ["clock"],
      assets: null,
    });
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
    const hub = new StreamHub(src, toAssetId, {
      pollMs: 20,
      batch: 500,
      maxAssets: 100,
    });
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
      ws.addEventListener("message", (e) =>
        got.push(JSON.parse(String(e.data))),
      );
      await new Promise((r) => ws.addEventListener("open", r, { once: true }));
      ws.send(
        JSON.stringify({
          op: "subscribe",
          channels: ["prices"],
          assets: [NVDA],
        }),
      );
      await until(() => got.some((f) => f.type === "subscribed"));
      src.prices.push(price(NVDA, 11n, 3n), price(AAPL, 11n, 4n));
      await until(() => got.some((f) => f.channel === "prices"));
      expect(got.filter((f) => f.channel === "prices")).toHaveLength(1);
      expect(
        (got.find((f) => f.channel === "prices")!.data as { seq: string }).seq,
      ).toBe("3");
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

describe("S3 channels", () => {
  const ME = "0x00000000000000000000000000000000000000b1";
  const OTHER = "0x00000000000000000000000000000000000000b2";
  it("auctions streams auction rows; bell:<owner> needs the socket's SIWE address and gets only that owner's events", async () => {
    const src = new FakeSource();
    const hub = new StreamHub(src, toAssetId);
    const mine = new FakeSocket();
    const anon = new FakeSocket();
    hub.add(mine, ME.toUpperCase().replace("0X", "0x"));
    hub.add(anon);
    hub.message(
      mine,
      JSON.stringify({ op: "subscribe", channels: ["auctions", `bell:${ME}`] }),
    );
    hub.message(
      anon,
      JSON.stringify({ op: "subscribe", channels: [`bell:${ME}`] }),
    );
    expect(mine.sent.at(-1)).toMatchObject({ type: "subscribed" });
    expect(anon.sent.at(-1)).toMatchObject({ type: "error" });
    hub.message(
      mine,
      JSON.stringify({ op: "subscribe", channels: [`bell:${OTHER}`] }),
    );
    expect(mine.sent.at(-1)).toMatchObject({ type: "error" });
    await hub.poll();
    src.auctions.push({
      auctionId: 1n,
      kind: 0,
      assetId: NVDA,
      marketId: NVDA,
      closureId: 7n,
      tranche: 0,
      status: "cleared",
      deadlines: [1, 1, 2, 3],
      lot: 5n,
      reserve: 6n,
      bids: 2,
      pStar: 7n,
      qPool: 0n,
      proceeds: 35n,
      block: 11n,
    });
    src.owners.push({
      owner: ME as Hex,
      marketId: NVDA,
      kind: "auto_cover_applied",
      amounts: { premium: "35950000" },
      clockState: 0,
      block: 11n,
      ts: 1n,
      txHash: NVDA,
    });
    src.owners.push({
      owner: OTHER as Hex,
      marketId: NVDA,
      kind: "flagged",
      amounts: {},
      clockState: 3,
      block: 11n,
      ts: 1n,
      txHash: NVDA,
    });
    const before = mine.sent.length;
    await hub.poll();
    const got = mine.sent.slice(before);
    expect(got.map((f) => f.channel)).toEqual(["auctions", `bell:${ME}`]);
    expect(got[0]).toMatchObject({ data: { auctionId: "1", pStar: "7" } });
    expect(got[1]).toMatchObject({ data: { kind: "auto_cover_applied" } });
  });
});

describe("OFF-04c: bell:<owner> ends with the SIWE session", () => {
  const ME = "0x00000000000000000000000000000000000000b1";
  const ev = (block: bigint): OwnerEvent => ({
    owner: ME as Hex,
    marketId: NVDA,
    kind: "auto_cover_applied",
    amounts: {},
    clockState: 0,
    block,
    ts: 1n,
    txHash: NVDA,
  });
  const setup = async () => {
    const src = new FakeSource();
    const hub = new StreamHub(src, toAssetId);
    const ws = new FakeSocket();
    const other = new FakeSocket();
    hub.add(ws, { owner: ME, session: "sid-1" });
    hub.add(other, { owner: ME, session: "sid-2" }); // the same wallet on another device
    for (const s of [ws, other])
      hub.message(
        s,
        JSON.stringify({
          op: "subscribe",
          channels: ["auctions", `bell:${ME}`],
        }),
      );
    await hub.poll();
    return { src, hub, ws, other };
  };
  const bells = (s: FakeSocket) =>
    s.sent.filter((f) => f.channel === `bell:${ME}`).length;

  it("logout: that session's socket stops getting bell frames, keeps public channels, and is told why", async () => {
    const { src, hub, ws, other } = await setup();
    expect(hub.dropSession("sid-1")).toBe(1);
    expect(ws.sent.at(-1)).toMatchObject({ type: "session_ended" });
    src.owners.push(ev(12n));
    await hub.poll();
    expect(bells(ws)).toBe(0);
    expect(bells(other)).toBe(1); // another session of the same wallet is untouched
    // it cannot subscribe again without a new session
    hub.message(
      ws,
      JSON.stringify({ op: "subscribe", channels: [`bell:${ME}`] }),
    );
    expect(ws.sent.at(-1)).toMatchObject({ type: "error" });
  });

  it("expiry: the periodic re-check ends expired sessions only", async () => {
    const { src, hub, ws, other } = await setup();
    expect(await hub.revalidate(async (sid) => sid !== "sid-2")).toBe(1);
    src.owners.push(ev(13n));
    await hub.poll();
    expect(bells(ws)).toBe(1);
    expect(bells(other)).toBe(0);
    // a failing session store never ends a live session
    expect(
      await hub.revalidate(async () => {
        throw new Error("db down");
      }),
    ).toBe(0);
  });
});
