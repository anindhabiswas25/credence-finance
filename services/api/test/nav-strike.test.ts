// The issuer NAV-strike tool's arithmetic (S4 G tooling): exact WAD parsing and the per-strike drop.
import { describe, expect, it } from "vitest";
import { dropped, wad } from "../scripts/nav/strike.ts";

describe("NAV strike", () => {
  it("parses decimal NAVs exactly", () => {
    expect(wad("1")).toBe(10n ** 18n);
    expect(wad("0.9955")).toBe(995_500_000_000_000_000n);
  });
  it("drops by bps, rounded down, within the oracle's 0.5 % per-strike limit", () => {
    const n = dropped(10n ** 18n, 45);
    expect(n).toBe(995_500_000_000_000_000n);
    expect(10n ** 18n - n <= (10n ** 18n * 5n) / 1000n).toBe(true);
  });
});
