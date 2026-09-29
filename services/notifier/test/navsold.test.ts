// S4 E: a NAV position sold at T+0 (§8.8), by a solver fill or the pool's advance at the floor, with exact amounts.
import { describe, expect, it } from "vitest";
import { labelsFromBook, navSoldPayload } from "../src/producer.ts";
import { render } from "../src/templates.ts";

const W = 10n ** 18n;
const TB = "0x" + "22".repeat(32);
const labels = labelsFromBook({
  equity: { pool: "0xpool", markets: {} },
  nav: { pool: "0xnavpool", markets: { TBILL: TB } },
});
// 10,000 tTBILL at NAV $1.00: floor $0.995 (κ_nav 0.5 %); debt $9,800, penalty 2 %
const base = {
  marketId: TB,
  settlementId: 3n,
  collateralSold: 10_000n * W,
  floorPrice: (995n * W) / 1000n,
  penalty: 196_000_000n,
  shortfall: 0n,
  debtAfter: 0n,
  collateralAfter: 0n,
  lt: (95n * W) / 100n,
};

describe("nav_sold", () => {
  it("a solver fill: price above the floor, the loan repaid, the rest refunded", () => {
    // 10,000 × $0.996 = $9,960; repaid 9,960 − 196 − 0 … refund = proceeds − debt − penalty
    const p = navSoldPayload(
      {
        ...base,
        status: "filled",
        price: (996n * W) / 1000n,
        proceeds: 9_960_000_000n,
        refund: 0n,
      },
      labels,
    );
    expect(p).toMatchObject({
      asset: "TBILL",
      token: "tTBILL",
      settlementId: "3",
      path: "solver_fill",
      proceeds: "9960000000",
      repaid: "9764000000",
      healthFactorAfter: null,
    });
    const r = render("nav_sold", p, "https://app.test").rendered;
    expect(r.text).toContain("10,000.0000 tTBILL sold to a solver at $0.9960");
    expect(r.text).toContain("floor $0.9950");
    expect(r.text).toContain("for $9,960.00");
    expect(r.text).toContain(
      "Liquidation penalty $196.00; $9,764.00 repaid your loan; $0.00 refunded to you.",
    );
    expect(r.text).toContain("Your loan is fully repaid.");
    expect(r.push.url).toBe("https://app.test/settlements/3");
  });

  it("a pool advance at the floor, with debt left", () => {
    const p = navSoldPayload(
      {
        ...base,
        status: "advanced",
        price: base.floorPrice,
        proceeds: 9_950_000_000n,
        refund: 0n,
        debtAfter: 1_000_000_000n,
        collateralAfter: 2_000n * W,
      },
      labels,
    );
    expect(p.path).toBe("pool_advance");
    // HF = 2,000 × 0.995 × 0.95 / 1,000 = 1.8905
    expect(p.healthFactorAfter).toBe("1890500000000000000");
    const r = render("nav_sold", p, "https://app.test").rendered;
    expect(r.text).toContain(
      "bought by the NAV underwriter pool at the floor, $0.9950 (no solver bid in the window)",
    );
    expect(r.text).toContain(
      "Your remaining debt is $1,000.00 and your health factor is now 1.89",
    );
  });

  it("rejects a malformed payload", () => {
    expect(() => render("nav_sold", { asset: "TBILL" }, "https://x")).toThrow();
  });
});
