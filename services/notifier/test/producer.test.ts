import { describe, expect, it } from "vitest";
import {
  auctionSettledPayload,
  autoCoverPayload,
  collateralValue,
  epochSettledPayload,
  healthFactor,
  labelsFromBook,
  leaveQueueCure,
  reopenQueuedPayload,
  withdrawalPayload,
} from "../src/producer.ts";
import { render } from "../src/templates.ts";

const W = 10n ** 18n;
const MID = "0x" + "11".repeat(32);
const labels = labelsFromBook({
  equity: { pool: "0xpool", markets: { NVDA: MID } },
  nav: { pool: "0xnavpool", markets: {} },
});

describe("producer payloads (exact amounts)", () => {
  it("collateral value and HF in loan units", () => {
    // 500 tNVDA at $160 = $80,000
    expect(collateralValue(500n * W, 160n * W)).toBe(80_000_000_000n);
    // HF = 80,000 × 0.85 / 70,000 = 0.971428…
    expect(
      healthFactor(500n * W, 160n * W, 85n * 10n ** 16n, 70_000_000_000n),
    ).toBe(971_428_571_428_571_428n);
  });
  it("leaving the reopen queue brings HF back to exactly ≥ 1", () => {
    const [q, v, lt, d] = [
      500n * W,
      160n * W,
      85n * 10n ** 16n,
      70_000_000_000n,
    ];
    const c = leaveQueueCure(q, v, lt, d);
    expect(c.repay).toBe(2_000_000_000n); // 70,000 − 68,000
    expect(healthFactor(q, v, lt, d - c.repay)).toBe(W);
    expect(healthFactor(q + c.add, v, lt, d)! >= W).toBe(true);
    expect(healthFactor(q + c.add - 10n ** 12n, v, lt, d)! < W).toBe(true);
    const p = reopenQueuedPayload(
      {
        marketId: MID,
        auctionId: 12n,
        closureId: 7n,
        collateral: q,
        debt: d,
        lt,
        openPrint: v,
        lotFixAt: 1_791_500_000,
      },
      labels,
    );
    expect(p).toMatchObject({
      asset: "NVDA",
      token: "tNVDA",
      cureRepay: "2000000000",
      healthFactor: "971428571428571428",
    });
    expect(() => render("reopen_queued", p, "https://x")).not.toThrow();
  });
  it("auction settled: repaid = proceeds − penalty − refund; HF after at the open print", () => {
    const p = auctionSettledPayload(
      {
        marketId: MID,
        auctionId: 12n,
        kind: 0,
        collateralSold: 59_080_000_000_000_000_000n,
        pStar: 156_020_000_000_000_000_000n,
        reference: 160n * W,
        proceeds: 9_217_661_600n,
        penalty: 460_883_080n,
        shortfall: 0n,
        refund: 0n,
        debtAfter: 4_578_380_000n,
        collateralAfter: 100n * W,
        lt: 85n * 10n ** 16n,
      },
      labels,
    );
    expect(p.repaid).toBe("8756778520");
    expect(p.healthFactorAfter).toBe(
      ((16_000_000_000n * 85n * 10n ** 16n) / 4_578_380_000n).toString(),
    );
    expect(render("auction_settled", p, "https://x").rendered.text).toContain(
      "$8,756.78 repaid your loan",
    );
  });
  it("epoch settled and withdrawals: shares × sharePriceAfter", () => {
    const e = epochSettledPayload({
      stack: "equity",
      epochId: 42n,
      premiums: 297_420_000n,
      riskFees: 0n,
      penalties: 0n,
      bonds: 86_000_000n,
      lossesPaid: 672_590_000n,
      before: 1_000_000n,
      after: 999_882n,
      shares: 10_000n * W,
    });
    expect(e.value).toBe("9998820000"); // $9,998.82
    expect(render("epoch_settled", e, "https://x").rendered.text).toContain(
      "worth $9,998.82",
    );
    expect(
      withdrawalPayload({
        stack: "nav",
        epochId: 3n,
        shares: 3n * W,
        sharePriceAfter: 1_000_001n,
      }).assets,
    ).toBe("3000003");
    expect(labels.stack("0xnavpool")).toBe("nav");
  });
  it("auto-cover: new LTV rounded up", () => {
    const p = autoCoverPayload(
      {
        marketId: MID,
        closureId: 7n,
        premium: 35_950_000n,
        debtAfter: 67_038_161_505n,
        collateral: 500n * W,
        price: 180n * W,
      },
      labels,
    );
    expect(p.newLtv).toBe("744868461166666667");
    expect(render("bell_outcome", p, "https://x").rendered.text).toContain(
      "$35.95",
    );
  });
});
