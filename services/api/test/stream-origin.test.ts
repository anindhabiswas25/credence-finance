// OFF-04 (QA-sec): the /v1/stream upgrade refuses cross-site origins; subscribe messages are small.
import { describe, expect, it } from "vitest";
import { Hono } from "hono";
import {
  MAX_MESSAGE_BYTES,
  attachStream,
  originAllowed,
  type StreamHub,
} from "../src/stream.ts";

describe("stream origin", () => {
  const allowed = ["https://app.credence.finance", "http://localhost:3000"];
  it("allows the web origins and non-browser clients, refuses others", () => {
    expect(originAllowed("https://app.credence.finance", allowed)).toBe(true);
    expect(originAllowed("https://App.Credence.Finance/", allowed)).toBe(true);
    expect(originAllowed(undefined, allowed)).toBe(true);
    expect(originAllowed("https://evil.example", allowed)).toBe(false);
    expect(originAllowed("http://localhost:3001", allowed)).toBe(false);
    expect(originAllowed("https://evil.example", [])).toBe(true); // no list configured
  });
  it("caps client messages at 16 KiB", () => {
    expect(MAX_MESSAGE_BYTES).toBe(16_384);
  });
});

describe("stream chain (ADR-0014)", () => {
  it("a socket opens on a served chain only (?chain=, optional with one chain)", async () => {
    const app = new Hono();
    const hub = {} as StreamHub;
    await attachStream(app, (chain) => (chain === "46630" ? hub : undefined));
    expect((await app.request("/v1/stream?chain=1")).status).toBe(400);
    expect((await app.request("/v1/stream")).status).toBe(400);
    expect((await app.request("/v1/stream?chain=46630")).status).not.toBe(
      400,
    );
  });
});
