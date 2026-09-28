// Bell and quote helpers over @credence/risk-wasm. Appendix A figures (G-10, G-11): the repay amounts
// equal the notifier's fixtures (cross-checked against risk-cli in services/notifier/test/e2e.test.ts).
// The token amounts follow the MARKET's view, which converts the cure *value* (loan units, rounded up)
// into tokens with mulDivUp; that is ≤ 1e-6 USD of collateral above risk-core's full-precision
// cure_amounts (22.584434549… → 22.58443455), and it is what CredenceMarket.bellStatus returns.
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import { BellStatus, bellFromSafeLtv, bellQuote, coverQuote, cureCollateralTokens, loadScenarioSet, ready, safeLtvFor, type RiskParams } from "../src/risk.js";

const usdc = (s: string) => BigInt(Math.round(Number(s) * 100)) * 10_000n; // 6 decimals, exact to the cent
const wad = (s: string) => {
  const [i, f = ""] = s.split(".");
  return BigInt(i!) * 10n ** 18n + BigInt((f + "0".repeat(18)).slice(0, 18));
};

// Launch parameters (§12.2 / QE proposal): α 0.1%, κ 3%, θ 100%, c 15%, η 4, β 97.5%, u_max 50%, min premium 0.50
const PARAMS: RiskParams = {
  alpha: wad("0.001"),
  kappa: wad("0.03"),
  theta: wad("1"),
  costOfCap: wad("0.15"),
  eta: wad("4"),
  beta: wad("0.975"),
  uMax: wad("0.5"),
  minPremium: 500_000n,
};

beforeAll(async () => {
  await ready;
});

describe("Bell for a known safe LTV (Appendix A)", () => {
  it("G-10 Priya NVDA: repay 2,896.779425, add 22.58443455 tNVDA", () => {
    const b = bellFromSafeLtv(
      { collateralValue: usdc("90000"), debtProjected: usdc("67028.99"), valuationPrice: wad("180"), collDecimals: 18, loanDecimals: 6 },
      wad("0.712580117506"),
    );
    expect(b.status).toBe(BellStatus.NEEDS_ACTION);
    expect(b.cureRepay).toBe(2_896_779_425n);
    expect(b.cureCollateral).toBe(22_584_434_550_000_000_000n);
  });

  it("G-11 Maya TSLA: repay 8,527.088250, add 54.418946464 tTSLA", () => {
    const b = bellFromSafeLtv(
      { collateralValue: usdc("75000"), debtProjected: usdc("55535.10"), valuationPrice: wad("250"), collDecimals: 18, loanDecimals: 6 },
      wad("0.626773490008"),
    );
    expect(b.cureRepay).toBe(8_527_088_250n);
    expect(b.cureCollateral).toBe(54_418_946_464_000_000_000n);
  });

  it("below the safe LTV is SAFE; covered is COVERED; both with zero cures", () => {
    const i = { collateralValue: usdc("90000"), debtProjected: usdc("60000"), valuationPrice: wad("180"), collDecimals: 18, loanDecimals: 6 };
    expect(bellFromSafeLtv(i, wad("0.7")).status).toBe(BellStatus.SAFE);
    const c = bellFromSafeLtv({ ...i, debtProjected: usdc("80000"), covered: true }, wad("0.7"));
    expect(c).toMatchObject({ status: BellStatus.COVERED, cureRepay: 0n, cureCollateral: 0n });
  });

  it("the token conversion rounds up like CoverLogic.mulDivUp", () => {
    expect(cureCollateralTokens(1n, wad("3"), 18, 6)).toBe(333_333_333_334n);
    expect(cureCollateralTokens((1n << 256n) - 1n, wad("3"), 18, 6)).toBe((1n << 256n) - 1n);
  });
});

describe("safe LTV and premium from a real ADR-0106 set", () => {
  const file = new URL("../../../contracts/test/fixtures/risk/NVDA-XNAS-2-63c7ce73.json", import.meta.url);

  it("quotes only when NEEDS_ACTION, and the premium grows with debt", () => {
    const set = loadScenarioSet(readFileSync(file, "utf8"));
    const base = {
      set,
      params: PARAMS,
      sigma: wad("0.045"),
      collateralValue: usdc("90000"),
      valuationPrice: wad("180"),
      maxLtv: wad("0.75"),
      collDecimals: 18,
      loanDecimals: 6,
      closureDays: 3n,
    };
    const safe = safeLtvFor(base);
    expect(safe > 0n && safe <= wad("0.75")).toBe(true);
    const below = bellQuote({ ...base, debtProjected: (usdc("90000") * safe) / 10n ** 18n - 1_000_000n });
    expect(below.status).toBe(BellStatus.SAFE);
    expect(below.premium).toBe(0n);
    const above = bellQuote({ ...base, debtProjected: usdc("74000") });
    expect(above.status).toBe(BellStatus.NEEDS_ACTION);
    expect(above.premium).toBe(coverQuote({ ...base, debtProjected: usdc("74000") }).premium);
    expect(above.premium >= PARAMS.minPremium).toBe(true);
    const more = coverQuote({ ...base, debtProjected: usdc("80000") });
    expect(more.premium >= above.premium).toBe(true);
  });
});
