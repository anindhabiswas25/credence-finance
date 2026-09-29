// OFF-04 (QA-sec): the /v1/stream upgrade refuses cross-site origins; subscribe messages are small.
import { describe, expect, it } from "vitest";
import { MAX_MESSAGE_BYTES, originAllowed } from "../src/stream.ts";

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
