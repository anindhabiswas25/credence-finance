import { describe, expect, it } from "vitest";
import { decimalUp, etTime, pct, tokens, usd } from "../src/format.ts";
import {
  BadPayload,
  GAP_COVER_MEANS,
  render,
  type BellHeadsUp,
} from "../src/templates.ts";
import { MAYA, PRIYA } from "./fixtures.ts";

// Fri 2026-10-02 15:45 ET = 19:45Z
const BELL = Date.UTC(2026, 9, 2, 19, 45) / 1000;

const headsUp = (over: Partial<BellHeadsUp>): BellHeadsUp => ({
  marketId: "0xabc",
  asset: "NVDA",
  token: "tNVDA",
  closureId: "7",
  closureType: 2,
  stage: "T-2h",
  bellAt: BELL,
  ...PRIYA,
  premium: "35950000",
  default: { kind: "autoCover" },
  loanDecimals: 6,
  collateralDecimals: 18,
  ...over,
});

describe("format", () => {
  it("rounds amounts the user pays or adds up, never down", () => {
    expect(usd(PRIYA.cureRepay)).toBe("$2,896.78");
    expect(usd(MAYA.cureRepay)).toBe("$8,527.09");
    expect(usd("35950000")).toBe("$35.95");
    expect(usd("35950001")).toBe("$35.96");
    expect(tokens(MAYA.cureCollateral)).toBe("54.419");
    // 22.58443… rounded up at 3 dp is 22.585; Appendix A prints 22.584 (nearest), which would leave the
    // loan 0.0004 tNVDA short of the safe LTV (spec issue in the sprint report)
    expect(tokens(PRIYA.cureCollateral)).toBe("22.585");
    expect(decimalUp("1", 18, 3)).toBe("0.001");
    expect(decimalUp("0", 6, 2)).toBe("0.00");
    expect(decimalUp("123456789", 0, 0)).toBe("123,456,789");
  });

  it("formats ratios and ET times", () => {
    expect(pct(PRIYA.ltv)).toBe("74.48%");
    expect(pct(PRIYA.safeLtv)).toBe("71.26%");
    expect(pct(MAYA.ltv)).toBe("74.05%");
    expect(pct(MAYA.safeLtv)).toBe("62.68%");
    expect(etTime(BELL)).toBe("Fri 15:45 ET");
    // winter time: Fri 2026-12-04 15:45 EST = 20:45Z
    expect(etTime(Date.UTC(2026, 11, 4, 20, 45) / 1000)).toBe("Fri 15:45 ET");
  });
});

describe("Bell heads-up", () => {
  it("matches the §10.5 copy with exact amounts (Priya, G-10)", () => {
    const r = render(
      "bell_headsup",
      headsUp({}),
      "https://testnet.credence.finance",
    ).rendered;
    expect(r.text).toContain(
      "Your NVDA loan is above this weekend's safe LTV (74.48% vs 71.26%). Before Fri 15:45 ET: repay $2,896.78, or add 22.585 tNVDA, or buy Gap Cover for $35.95.",
    );
    expect(r.text).toContain(
      "If you do nothing, auto-cover will add $35.95 to your debt.",
    );
    expect(r.push.body).toContain("repay $2,896.78");
    expect(r.subject).toBe("NVDA: action needed before Fri 15:45 ET");
  });

  it("auto-cover off: the default is the pre-close sale (Maya, G-11)", () => {
    const r = render(
      "bell_headsup",
      headsUp({
        asset: "TSLA",
        token: "tTSLA",
        ...MAYA,
        premium: "61230000",
        default: { kind: "precloseSale", saleQty: "96545400000000000000" },
      }),
      "https://x",
    ).rendered;
    expect(r.text).toContain(
      "(74.05% vs 62.68%). Before Fri 15:45 ET: repay $8,527.09, or add 54.419 tTSLA, or buy Gap Cover for $61.23.",
    );
    expect(r.text).toContain(
      "If you do nothing, 96.5454 tTSLA will be sold in the pre-close sale at the Bell, because auto-cover is off.",
    );
  });

  it("closure wording and cover unavailable", () => {
    const night = render(
      "bell_headsup",
      headsUp({ closureType: 1 }),
      "https://x",
    ).rendered;
    expect(night.text).toContain("above tonight's safe LTV");
    const r = render(
      "bell_headsup",
      headsUp({
        premium: null,
        coverUnavailable: "the underwriter pool is full",
        default: { kind: "precloseSale", saleQty: "1000000000000000000" },
      }),
      "https://x",
    ).rendered;
    expect(r.text).not.toContain("Gap Cover for");
    expect(r.text).toContain(
      "Gap Cover is not available for this closure: the underwriter pool is full.",
    );
    expect(r.text).toContain(
      "If you do nothing, 1.0000 tNVDA will be sold in the pre-close sale at the Bell.",
    );
  });

  it("R-18 copy rule: every mention of Gap Cover says what it buys; never 'insured'", () => {
    const variants: Partial<BellHeadsUp>[] = [
      {},
      {
        default: { kind: "autoCoverAfterSale", saleQty: "5000000000000000000" },
      },
      { default: { kind: "precloseSale", saleQty: "5000000000000000000" } },
    ];
    for (const v of variants) {
      const r = render("bell_headsup", headsUp(v), "https://x").rendered;
      expect(r.text).toContain(GAP_COVER_MEANS);
      expect(r.html).toContain(
        "exempts you from overnight emergency liquidation",
      );
      expect(`${r.text} ${r.html} ${r.push.body}`.toLowerCase()).not.toMatch(
        /insur/,
      );
    }
    for (const outcome of ["autoCover", "autoCoverAfterSale"] as const) {
      const r = render(
        "bell_outcome",
        {
          marketId: "0x1",
          asset: "NVDA",
          token: "tNVDA",
          closureId: "7",
          outcome,
          premium: "35950000",
          saleQty: "1000000000000000000",
          newLtv: "745200000000000000",
        },
        "https://x",
      ).rendered;
      expect(r.text).toContain(GAP_COVER_MEANS);
      expect(r.text.toLowerCase()).not.toMatch(/insur/);
    }
  });
});

describe("Bell outcome", () => {
  it("auto-cover and pre-close sale report amounts and the new LTV", () => {
    const a = render(
      "bell_outcome",
      {
        marketId: "0x1",
        asset: "NVDA",
        token: "tNVDA",
        closureId: "7",
        outcome: "autoCover",
        premium: "35950000",
        newLtv: "745166000000000000",
      },
      "https://x",
    ).rendered;
    expect(a.text).toContain(
      "auto-cover bought Gap Cover for $35.95 and added it to your debt. Your LTV is now 74.52%.",
    );
    const s = render(
      "bell_outcome",
      {
        marketId: "0x2",
        asset: "TSLA",
        token: "tTSLA",
        closureId: "7",
        outcome: "precloseSale",
        saleQty: "96545400000000000000",
        newLtv: "626773490008000000",
      },
      "https://x",
    ).rendered;
    expect(s.text).toContain(
      "96.5454 tTSLA went into the pre-close sale. At the sale's reserve price your LTV is 62.68%.",
    );
    expect(s.subject).toBe("TSLA: pre-close sale of 96.5454 tTSLA");
  });

  it("rejects unknown events and malformed payloads", () => {
    expect(() => render("nope", {}, "https://x")).toThrow(BadPayload);
    expect(() =>
      render("bell_headsup", { asset: "NVDA" }, "https://x"),
    ).toThrow(BadPayload);
    expect(() =>
      render("bell_headsup", headsUp({ cureRepay: "-1" }), "https://x"),
    ).toThrow(BadPayload);
  });
});

describe("S3 events (§10.5) carry exact amounts", () => {
  const O = "https://app.test";
  it("queued at reopen: countdown with the cure amounts", () => {
    const { rendered } = render(
      "reopen_queued",
      {
        marketId: "0xabc",
        asset: "NVDA",
        token: "tNVDA",
        auctionId: "12",
        closureId: "7",
        healthFactor: "870000000000000000",
        openPrint: "171230000000000000000",
        cureRepay: "4012345678",
        cureCollateral: "23456700000000000001",
        deadline: Date.UTC(2026, 9, 5, 13, 32) / 1000,
        loanDecimals: 6,
        collateralDecimals: 18,
      },
      O,
    );
    expect(rendered.push.body).toBe(
      "You can leave the queue by repaying $4,012.35 or adding 23.457 tNVDA until 09:32:00 ET.",
    );
    expect(rendered.text).toContain(
      "NVDA reopened at $171.23 and your loan's health factor is 0.87",
    );
  });
  it("auction settled: tokens sold, p* vs open print, penalty, refund, new HF", () => {
    const { rendered } = render(
      "auction_settled",
      {
        marketId: "0xabc",
        asset: "NVDA",
        token: "tNVDA",
        auctionId: "12",
        kind: "REOPEN",
        collateralSold: "96920000000000000000",
        pStar: "167500000000000000000",
        openPrint: "171230000000000000000",
        proceeds: "16234100000",
        penalty: "811705000",
        repaid: "15422395000",
        refund: "0",
        shortfall: "0",
        debtAfter: "51606605000",
        healthFactorAfter: "1052300000000000000",
      },
      O,
    );
    expect(rendered.text).toContain(
      "96.9200 tNVDA sold at $167.50 (open print $171.23, −2.18%), for $16,234.10.",
    );
    expect(rendered.text).toContain(
      "Liquidation penalty $811.71; $15,422.40 repaid your loan; $0.00 refunded to you.",
    );
    expect(rendered.text).toContain(
      "Your remaining debt is $51,606.61 and your health factor is now 1.05.",
    );
    expect(rendered.text).not.toContain("shortfall");
  });
  it("auction settled with a shortfall and no debt left", () => {
    const { rendered } = render(
      "auction_settled",
      {
        marketId: "0xabc",
        asset: "TSLA",
        token: "tTSLA",
        auctionId: "3",
        kind: "EMERGENCY",
        collateralSold: "10000000000000000000",
        pStar: "300000000000000000000",
        openPrint: null,
        proceeds: "3000000000",
        penalty: "0",
        repaid: "3000000000",
        refund: "0",
        shortfall: "125000000",
        debtAfter: "0",
        healthFactorAfter: null,
      },
      O,
    );
    expect(rendered.text).toContain("a shortfall of $125.00 was absorbed");
    expect(rendered.text).toContain("Your loan is fully repaid.");
  });
  it("epoch settled: P&L breakdown and share price", () => {
    const { rendered } = render(
      "epoch_settled",
      {
        stack: "equity",
        epochId: "42",
        premiums: "35950000",
        fees: "1234567",
        penalties: "270568333",
        bonds: "0",
        losses: "0",
        sharePriceBefore: "1000000",
        sharePriceAfter: "1003076",
        shares: "1000000000000000000000",
        value: "1003076000",
      },
      O,
    );
    expect(rendered.text).toContain(
      "Premiums $35.95, risk fees $1.23, penalties $270.57, forfeited bonds $0.00; losses paid $0.00.",
    );
    expect(rendered.text).toContain(
      "The new share price is $1.003076 (was $1.000000). Your 1,000.0000 shares are worth $1,003.08.",
    );
  });
  it("withdrawal claimable: amount and claim link; channels per §10.5", () => {
    const { rendered } = render(
      "withdrawal_claimable",
      {
        stack: "equity",
        epochId: "42",
        shares: "500000000000000000000",
        assets: "501538000",
      },
      O,
    );
    expect(rendered.subject).toBe("Withdrawal ready: claim $501.54");
    expect(rendered.text).toContain(
      "https://app.test/underwrite?claim=equity:42",
    );
  });
  it("rejects a malformed payload", () => {
    expect(() => render("auction_settled", { asset: "NVDA" }, O)).toThrow(
      BadPayload,
    );
  });
});
