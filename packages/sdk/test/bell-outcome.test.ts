import { describe, expect, it } from "vitest";
import { BellOutcome, bellOutcomeName } from "../src/types.js";

describe("BellEnforced.outcome", () => {
  it("names every v1 value, including 5 SALE_TOO_LATE (ADR-0115)", () => {
    expect(BellOutcome.SALE_TOO_LATE).toBe(5);
    expect([0, 1, 2, 3, 4, 5].map(bellOutcomeName)).toEqual([
      "SAFE",
      "ALREADY_COVERED",
      "AUTO_COVERED",
      "PRECLOSE_THEN_COVER",
      "PRECLOSE_SALE",
      "SALE_TOO_LATE",
    ]);
  });
  it("keeps an unknown value visible instead of dropping it", () => {
    expect(bellOutcomeName(6)).toBe("UNKNOWN_6");
  });
});
