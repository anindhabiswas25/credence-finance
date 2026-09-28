// Bell status and the Gap Cover quote off-chain, bit-identical to the chain (@credence/risk-wasm is
// risk-core compiled to WASM, the same crate the Stylus engine runs). Mirrors
// CredenceMarket.bellStatus (CoverLogic.bellStatusView) and IRiskEngine.bellStatus / quoteCover.
//
//   import { ready, bellQuote, loadScenarioSet } from "@credence/sdk/risk";
//   await ready;
import { ScenarioSet, bellStatus as wasmBellStatus, quoteCover, ready, safeLtvFromSet } from "@credence/risk-wasm";

export { ready, ScenarioSet };

export const WAD = 10n ** 18n;

/** `BellStatus` (Types.sol). */
export const BellStatus = { SAFE: 0, NEEDS_ACTION: 1, COVERED: 2 } as const;
export type BellStatusCode = (typeof BellStatus)[keyof typeof BellStatus];

/** `RiskParams` (Types.sol); every field WAD except `minPremium` (loan units) and `kStress`. */
export interface RiskParams {
  alpha: bigint;
  kappa: bigint;
  theta: bigint;
  costOfCap: bigint;
  eta: bigint;
  beta: bigint;
  uMax: bigint;
  minPremium: bigint;
  kStress?: number;
}

/** Everything the chain reads for one position at one block. */
export interface BellInputs {
  /** The (asset, closure type) scenario set the engine holds (check `scenarioHash` before use). */
  set: ScenarioSet;
  params: RiskParams;
  /** `engine.sigma(asset, type)`, WAD. */
  sigma: bigint;
  dividend?: bigint;
  /** `value(qty, valuationPrice)`, loan units. */
  collateralValue: bigint;
  /** `market.projectedDebt(id, b)`, loan units. */
  debtProjected: bigint;
  /** `maxLtvEff` = maxLtv minus any active guardian haircut, WAD. */
  maxLtv: bigint;
  /** `oracle.valuationPrice(asset)`, WAD per token. */
  valuationPrice: bigint;
  collDecimals: number;
  loanDecimals: number;
  closureDays: bigint;
  /** Pool utilisation after this cover (the pool's `previewCover` input); 0 before S3. */
  utilAfter?: bigint;
  /** Already covered for the upcoming closure. */
  covered?: boolean;
}

export interface BellQuote {
  status: BellStatusCode;
  safeLtv: bigint;
  cureRepay: bigint;
  cureCollateralValue: bigint;
  /** Collateral tokens to add (token units), rounded up like the market. `2^256−1` = cannot cure by adding. */
  cureCollateral: bigint;
  premium: bigint;
  expectedLoss: bigint;
  expectedShortfall: bigint;
}

const MAX_UINT256 = (1n << 256n) - 1n;

const mulDivUp = (a: bigint, b: bigint, d: bigint): bigint => (a * b + d - 1n) / d;

/** CoverLogic.bellStatusView's collateral conversion: mulDivUp(value, 10^coll · WAD, V · 10^loan). */
export function cureCollateralTokens(cureValue: bigint, valuationPrice: bigint, collDecimals: number, loanDecimals: number): bigint {
  if (cureValue === MAX_UINT256) return MAX_UINT256;
  return mulDivUp(cureValue, 10n ** BigInt(collDecimals) * WAD, valuationPrice * 10n ** BigInt(loanDecimals));
}

/** The Bell for a known safe LTV (engine `bellStatus` given its quantile), with the cure in tokens. */
export function bellFromSafeLtv(
  i: Pick<BellInputs, "collateralValue" | "debtProjected" | "valuationPrice" | "collDecimals" | "loanDecimals" | "covered">,
  safeLtv: bigint,
): Pick<BellQuote, "status" | "safeLtv" | "cureRepay" | "cureCollateralValue" | "cureCollateral"> {
  if (i.covered) return { status: BellStatus.COVERED, safeLtv, cureRepay: 0n, cureCollateralValue: 0n, cureCollateral: 0n };
  const r = wasmBellStatus(i.collateralValue, i.debtProjected, safeLtv, false);
  const status = r.status as BellStatusCode;
  if (status !== BellStatus.NEEDS_ACTION) return { status, safeLtv, cureRepay: 0n, cureCollateralValue: 0n, cureCollateral: 0n };
  return {
    status,
    safeLtv,
    cureRepay: r.cureRepay,
    cureCollateralValue: r.cureCollateralValue,
    cureCollateral: cureCollateralTokens(r.cureCollateralValue, i.valuationPrice, i.collDecimals, i.loanDecimals),
  };
}

/** Safe LTV for the upcoming closure: `engine.safeLtv(asset, type, maxLtvEff, dividend)`. */
export function safeLtvFor(i: Pick<BellInputs, "set" | "params" | "sigma" | "dividend" | "maxLtv">): bigint {
  return safeLtvFromSet(i.set, i.params.alpha, i.sigma, i.dividend ?? 0n, i.params.kappa, i.maxLtv);
}

/** The Gap Cover premium quote (`engine.quoteCover`). */
export function coverQuote(i: BellInputs): { premium: bigint; expectedLoss: bigint; expectedShortfall: bigint } {
  return quoteCover(i.set, {
    sigma: i.sigma,
    dividend: i.dividend ?? 0n,
    kappa: i.params.kappa,
    collateralValue: i.collateralValue,
    debtProjected: i.debtProjected,
    closureDays: i.closureDays,
    utilAfter: i.utilAfter ?? 0n,
    theta: i.params.theta,
    costOfCap: i.params.costOfCap,
    eta: i.params.eta,
    beta: i.params.beta,
    minPremium: i.params.minPremium,
  });
}

/**
 * Full `/bell` answer. Like the market's view, the premium is quoted only for NEEDS_ACTION
 * (SAFE and COVERED return 0); `withPremium` forces a quote for any status (the UI's "buy anyway").
 */
export function bellQuote(i: BellInputs, withPremium = false): BellQuote {
  const safe = safeLtvFor(i);
  const bell = bellFromSafeLtv(i, safe);
  const quote = bell.status === BellStatus.NEEDS_ACTION || withPremium ? coverQuote(i) : { premium: 0n, expectedLoss: 0n, expectedShortfall: 0n };
  return { ...bell, ...quote };
}

/** ADR-0106 scenario-set file (JSON text) → a validated set. */
export function loadScenarioSet(json: string): ScenarioSet {
  return ScenarioSet.fromFile(json);
}
