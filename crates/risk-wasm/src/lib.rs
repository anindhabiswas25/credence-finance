//! # @credence/risk-wasm
//!
//! risk-core compiled to WebAssembly for the TypeScript SDK, the API (Bell quotes) and the web app (previews).
//! The same integer code runs in the Stylus Risk Engine, so every result is bit-identical to the chain.
//!
//! Conventions (TypeScript):
//! - Every amount is a `bigint` (WAD ratios / prices, loan units, collateral base units). Negative → error.
//! - z values (thousandths of σ) are `Int16Array`; loss vectors are `BigUint64Array`.
//! - Scenario sets are `ScenarioSet` objects (sorted once, reused), built from z or from an ADR-0106 file.
//! - Errors throw `Error("MathError(<Name>, <code>)")` (code = on-chain `MathError(uint8)`) or
//!   `Error("FileError(<json path>: <message>)")`.

use alloy_primitives::{B256, U256};
use credence_risk_core as core;
use credence_risk_core::fixed::{
    collateral_value, health_factor_down, ltv_up, pack_i16, pack_u64, unpack_i16,
};
use credence_risk_core::setfile;
use js_sys::{BigInt, Object, Reflect};
use wasm_bindgen::prelude::*;

type R<T> = Result<T, JsError>;

// ───────────────────────────── conversions ─────────────────────────────

fn math(e: core::MathError) -> JsError {
    JsError::new(&format!("MathError({e:?}, {})", e.code()))
}

fn file(e: setfile::FileError) -> JsError {
    JsError::new(&format!("FileError({e})"))
}

fn u(b: &BigInt) -> R<U256> {
    let s: String = b
        .to_string(10)
        .map_err(|_| JsError::new("expected a bigint"))?
        .into();
    U256::from_str_radix(&s, 10)
        .map_err(|_| JsError::new(&format!("expected a bigint in [0, 2^256), got {s}")))
}

fn us(v: &[BigInt]) -> R<Vec<U256>> {
    v.iter().map(u).collect()
}

fn small<T: TryFrom<u64>>(b: &BigInt, what: &str) -> R<T> {
    let x: u64 = u(b)?
        .try_into()
        .map_err(|_| JsError::new(&format!("{what} too large")))?;
    T::try_from(x).map_err(|_| JsError::new(&format!("{what} out of range")))
}

fn big(x: U256) -> BigInt {
    BigInt::new(&JsValue::from_str(&x.to_string())).expect("decimal string is a valid bigint")
}

fn bigs(xs: &[U256]) -> Vec<BigInt> {
    xs.iter().map(|x| big(*x)).collect()
}

fn hex(b: B256) -> String {
    format!("{b:#x}")
}

fn obj(fields: &[(&str, JsValue)]) -> JsValue {
    let o = Object::new();
    for (k, v) in fields {
        Reflect::set(&o, &JsValue::from_str(k), v).expect("set on a fresh object");
    }
    o.into()
}

fn sorted(z: &[i16]) -> R<()> {
    if z.is_empty() {
        return Err(math(core::MathError::EmptySet));
    }
    if !core::is_sorted(&core::SliceZ(z)) {
        return Err(math(core::MathError::NotSorted));
    }
    Ok(())
}

// ───────────────────────────── scenario sets ─────────────────────────────

/// A sorted scenario set held in WASM memory. Build it once, pass it to every quote.
#[wasm_bindgen]
pub struct ScenarioSet {
    z: Vec<i16>,
    asset: Option<String>,
    asset_id: Option<String>,
    closure_type: Option<u8>,
    scenario_hash: Option<String>,
    content_hash: Option<String>,
}

#[wasm_bindgen]
impl ScenarioSet {
    /// A set from ascending z values (thousandths of σ).
    #[wasm_bindgen(constructor)]
    pub fn new(z: Vec<i16>) -> R<ScenarioSet> {
        sorted(&z)?;
        Ok(ScenarioSet {
            z,
            asset: None,
            asset_id: None,
            closure_type: None,
            scenario_hash: None,
            content_hash: None,
        })
    }

    /// Parse and fully validate an ADR-0106 scenario-set file (its JSON text).
    #[wasm_bindgen(js_name = fromFile)]
    pub fn from_file(json: &str) -> R<ScenarioSet> {
        let v: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| JsError::new(&format!("FileError(.: invalid JSON: {e})")))?;
        let s = setfile::parse_set(&v).map_err(file)?;
        Ok(ScenarioSet {
            asset: s.asset,
            asset_id: Some(hex(s.asset_id)),
            closure_type: Some(s.closure_type),
            scenario_hash: Some(hex(s.scenario_hash)),
            content_hash: Some(hex(s.content_hash)),
            z: s.z,
        })
    }

    /// N.
    #[wasm_bindgen(getter)]
    pub fn n(&self) -> usize {
        self.z.len()
    }

    /// A copy of the z values.
    #[wasm_bindgen(getter)]
    pub fn z(&self) -> Vec<i16> {
        self.z.clone()
    }

    /// "NVDA:XNAS" when loaded from a file that names it.
    #[wasm_bindgen(getter)]
    pub fn asset(&self) -> Option<String> {
        self.asset.clone()
    }

    /// 0x assetId when loaded from a file.
    #[wasm_bindgen(getter, js_name = assetId)]
    pub fn asset_id(&self) -> Option<String> {
        self.asset_id.clone()
    }

    /// 1, 2 or 3 when loaded from a file.
    #[wasm_bindgen(getter, js_name = closureType)]
    pub fn closure_type(&self) -> Option<u8> {
        self.closure_type
    }

    /// keccak256 of the packed words (== `engine.scenarioHash`) when loaded from a file.
    #[wasm_bindgen(getter, js_name = scenarioHash)]
    pub fn scenario_hash(&self) -> Option<String> {
        self.scenario_hash.clone()
    }

    /// ADR-0106 content hash when loaded from a file.
    #[wasm_bindgen(getter, js_name = contentHash)]
    pub fn content_hash(&self) -> Option<String> {
        self.content_hash.clone()
    }

    /// The on-chain payload: 16 × int16 per word.
    pub fn packed(&self) -> Vec<BigInt> {
        bigs(&pack_i16(&self.z))
    }
}

/// Validate an ADR-0106 scenario-set or joint-set file (JSON text); returns the `risk-cli validate-set` summary.
/// A bundle needs its referenced files, so validate bundles with `risk-cli` / `risk-py`.
#[wasm_bindgen(js_name = validateSetFile)]
pub fn validate_set_file(json: &str) -> R<JsValue> {
    let v: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| JsError::new(&format!("FileError(.: invalid JSON: {e})")))?;
    let out = setfile::validate(&v, |_| Err("bundles are not supported in risk-wasm".into()))
        .map_err(file)?;
    js_sys::JSON::parse(&out.to_string()).map_err(|_| JsError::new("summary is not JSON"))
}

/// Joint column of `assetId` from an ADR-0106 joint-set file (JSON text), weekend order.
#[wasm_bindgen(js_name = jointColumnFromFile)]
pub fn joint_column_from_file(json: &str, asset_id: &str) -> R<Vec<i16>> {
    let v: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| JsError::new(&format!("FileError(.: invalid JSON: {e})")))?;
    let j = setfile::parse_joint(&v).map_err(file)?;
    let id: B256 = asset_id
        .parse()
        .map_err(|e| JsError::new(&format!("assetId: {e}")))?;
    j.columns
        .into_iter()
        .find(|c| c.asset_id == id)
        .map(|c| c.z)
        .ok_or_else(|| JsError::new(&format!("no joint column for {asset_id}")))
}

/// keccak256("TICKER:MIC") as 0x hex.
#[wasm_bindgen(js_name = assetId)]
pub fn asset_id(asset: &str) -> String {
    hex(setfile::asset_id_of(asset))
}

/// Pack int16 values 16 per word.
#[wasm_bindgen(js_name = packZ)]
pub fn pack_z(z: Vec<i16>) -> Vec<BigInt> {
    bigs(&pack_i16(&z))
}

/// Unpack `n` int16 values from packed words.
#[wasm_bindgen(js_name = unpackZ)]
pub fn unpack_z(words: Vec<BigInt>, n: usize) -> R<Vec<i16>> {
    let w = us(&words)?;
    if n.div_ceil(16) > w.len() {
        return Err(math(core::MathError::InvalidInput));
    }
    Ok((0..n).map(|i| unpack_i16(w[i / 16], i % 16)).collect())
}

// ───────────────────────────── F-4.1 / F-4.2 ─────────────────────────────

/// Collateral value, LTV (rounded up) and health factor (rounded down) of a position.
#[wasm_bindgen(
    unchecked_return_type = "{ collateralValue: bigint; ltv: bigint; healthFactor: bigint }"
)]
pub fn value(
    qty: &BigInt,
    price: &BigInt,
    debt: &BigInt,
    lt: &BigInt,
    coll_dec: u8,
    loan_dec: u8,
) -> R<JsValue> {
    let c = collateral_value(u(qty)?, u(price)?, coll_dec, loan_dec).map_err(math)?;
    let d = u(debt)?;
    Ok(obj(&[
        ("collateralValue", big(c).into()),
        ("ltv", big(ltv_up(d, c).map_err(math)?).into()),
        (
            "healthFactor",
            big(health_factor_down(c, u(lt)?, d).map_err(math)?).into(),
        ),
    ]))
}

/// Safe LTV for one z (F-4.2), WAD.
#[wasm_bindgen(js_name = safeLtv)]
pub fn safe_ltv(
    z: i16,
    sigma: &BigInt,
    dividend: &BigInt,
    kappa: &BigInt,
    max_ltv: &BigInt,
) -> R<BigInt> {
    Ok(big(core::safe_ltv(
        z,
        u(sigma)?,
        u(dividend)?,
        u(kappa)?,
        u(max_ltv)?,
    )
    .map_err(math)?))
}

/// Safe LTV at the α-quantile of a set (what `engine.safeLtv` computes).
#[wasm_bindgen(js_name = safeLtvFromSet)]
pub fn safe_ltv_from_set(
    set: &ScenarioSet,
    alpha: &BigInt,
    sigma: &BigInt,
    dividend: &BigInt,
    kappa: &BigInt,
    max_ltv: &BigInt,
) -> R<BigInt> {
    Ok(big(core::safe_ltv_from_set(
        &core::SliceZ(&set.z),
        u(alpha)?,
        u(sigma)?,
        u(dividend)?,
        u(kappa)?,
        u(max_ltv)?,
    )
    .map_err(math)?))
}

/// Gap factor, WAD.
#[wasm_bindgen(js_name = gapFactor)]
pub fn gap_factor(z: i16, sigma: &BigInt, dividend: &BigInt, kappa: &BigInt) -> R<BigInt> {
    Ok(big(
        core::gap_factor(z, u(sigma)?, u(dividend)?, u(kappa)?).map_err(math)?
    ))
}

/// ceil(α·N) − 1.
#[wasm_bindgen(js_name = quantileIndex)]
pub fn quantile_index(n: u32, alpha: &BigInt) -> R<u32> {
    core::quantile_index(n, u(alpha)?).map_err(math)
}

/// Cure amounts for an at-risk position.
#[wasm_bindgen(
    js_name = cureAmounts,
    unchecked_return_type = "{ repay: bigint; addCollateral: bigint; addCollateralValue: bigint }"
)]
pub fn cure_amounts(
    debt_projected: &BigInt,
    qty: &BigInt,
    price: &BigInt,
    safe_ltv: &BigInt,
    coll_dec: u8,
    loan_dec: u8,
) -> R<JsValue> {
    let c = core::cure_amounts(
        u(debt_projected)?,
        u(qty)?,
        u(price)?,
        u(safe_ltv)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?;
    Ok(obj(&[
        ("repay", big(c.repay).into()),
        ("addCollateral", big(c.add_collateral).into()),
        ("addCollateralValue", big(c.add_collateral_value).into()),
    ]))
}

/// Bell status: 0 SAFE, 1 AT_RISK, 2 COVERED (Types.sol `BellStatus`).
#[wasm_bindgen(
    js_name = bellStatus,
    unchecked_return_type = "{ status: number; cureRepay: bigint; cureCollateralValue: bigint }"
)]
pub fn bell_status(
    collateral_value: &BigInt,
    debt_projected: &BigInt,
    safe_ltv: &BigInt,
    covered: bool,
) -> R<JsValue> {
    let b = core::bell_status(
        u(collateral_value)?,
        u(debt_projected)?,
        u(safe_ltv)?,
        covered,
    )
    .map_err(math)?;
    Ok(obj(&[
        ("status", JsValue::from(b.status)),
        ("cureRepay", big(b.cure_repay).into()),
        ("cureCollateralValue", big(b.cure_collateral_value).into()),
    ]))
}

/// Whole days between two unix timestamps.
#[wasm_bindgen(js_name = elapsedDays)]
pub fn elapsed_days(from: u64, now: u64) -> u64 {
    core::elapsed_days(from, now)
}

/// Lowest σ the engine accepts after `days` days (R-15).
#[wasm_bindgen(js_name = sigmaMinAllowed)]
pub fn sigma_min_allowed(current: &BigInt, days: u64) -> R<BigInt> {
    Ok(big(
        core::sigma_min_allowed(u(current)?, days).map_err(math)?
    ))
}

// ───────────────────────────── F-4.3 / F-4.4 ─────────────────────────────

/// Inputs of a Gap Cover quote (every field a bigint; `dividend`, `utilAfter`, `minPremium` default to 0).
#[wasm_bindgen(typescript_custom_section)]
const QUOTE_TS: &str = r#"
export interface QuoteInput {
  sigma: bigint; dividend?: bigint; kappa: bigint; collateralValue: bigint; debtProjected: bigint;
  closureDays: bigint; utilAfter?: bigint; theta: bigint; costOfCap: bigint; eta: bigint; beta: bigint;
  minPremium?: bigint;
}
"#;

fn field(o: &JsValue, k: &str, optional: bool) -> R<U256> {
    let v = Reflect::get(o, &JsValue::from_str(k))
        .map_err(|_| JsError::new("input must be an object"))?;
    if v.is_undefined() || v.is_null() {
        return if optional {
            Ok(U256::ZERO)
        } else {
            Err(JsError::new(&format!("missing field `{k}`")))
        };
    }
    let b: BigInt = v
        .dyn_into()
        .map_err(|_| JsError::new(&format!("`{k}` must be a bigint")))?;
    u(&b)
}

/// Gap Cover quote over a scenario set (loan units).
#[wasm_bindgen(
    js_name = quoteCover,
    unchecked_return_type = "{ premium: bigint; expectedLoss: bigint; expectedShortfall: bigint }"
)]
pub fn quote_cover(
    set: &ScenarioSet,
    #[wasm_bindgen(unchecked_param_type = "QuoteInput")] input: JsValue,
) -> R<JsValue> {
    let days = field(&input, "closureDays", false)?;
    let p = core::PremiumParams {
        sigma: field(&input, "sigma", false)?,
        dividend: field(&input, "dividend", true)?,
        kappa: field(&input, "kappa", false)?,
        collateral_value: field(&input, "collateralValue", false)?,
        debt_projected: field(&input, "debtProjected", false)?,
        closure_days: u16::try_from(days).map_err(|_| JsError::new("closureDays out of range"))?,
        util_after: field(&input, "utilAfter", true)?,
        theta: field(&input, "theta", false)?,
        cost_of_cap: field(&input, "costOfCap", false)?,
        eta: field(&input, "eta", false)?,
        beta: field(&input, "beta", false)?,
        min_premium: field(&input, "minPremium", true)?,
    };
    let q = core::quote_cover(&core::SliceZ(&set.z), &p).map_err(math)?;
    Ok(obj(&[
        ("premium", big(q.premium).into()),
        ("expectedLoss", big(q.expected_loss).into()),
        ("expectedShortfall", big(q.expected_shortfall).into()),
    ]))
}

/// Per-weekend loss of a covered position over a joint column (unpacked), loan units.
#[wasm_bindgen(js_name = coverLossVector)]
pub fn cover_loss_vector(
    joint: Vec<i16>,
    collateral_value: &BigInt,
    debt_projected: &BigInt,
    sigma: &BigInt,
    dividend: &BigInt,
    kappa: &BigInt,
) -> R<Vec<u64>> {
    core::loss_vector(
        &core::SliceZ(&joint),
        u(collateral_value)?,
        u(debt_projected)?,
        u(sigma)?,
        u(dividend)?,
        u(kappa)?,
    )
    .map_err(math)
}

/// Pack loss values 4 × uint64 per word (on-chain layout).
#[wasm_bindgen(js_name = packLosses)]
pub fn pack_losses(losses: Vec<u64>) -> Vec<BigInt> {
    bigs(&pack_u64(&losses))
}

/// Pool capacity (R-13) with no uncovered markets: `current` + `add` loss vectors (unpacked, K long) against
/// `equity`. For uncovered exposure use `poolCapacityWithUncovered`.
#[wasm_bindgen(
    js_name = poolCapacity,
    unchecked_return_type = "{ ok: boolean; utilAfter: bigint; worstLoss: bigint }"
)]
pub fn pool_capacity(
    current: Vec<u64>,
    add: Vec<u64>,
    kappa: &BigInt,
    equity: &BigInt,
    u_max: &BigInt,
) -> R<JsValue> {
    capacity(current, add, &[], kappa, equity, u_max)
}

/// One market's uncovered exposure for the capacity check.
#[wasm_bindgen]
pub struct Uncovered {
    joint: Vec<i16>,
    sigma: U256,
    dividend: U256,
    collateral_value: U256,
    safe_ltv: U256,
}

#[wasm_bindgen]
impl Uncovered {
    /// (joint column, σ, dividend, uncovered collateral value, safe LTV).
    #[wasm_bindgen(constructor)]
    pub fn new(
        joint: Vec<i16>,
        sigma: &BigInt,
        dividend: &BigInt,
        collateral_value: &BigInt,
        safe_ltv: &BigInt,
    ) -> R<Uncovered> {
        Ok(Uncovered {
            joint,
            sigma: u(sigma)?,
            dividend: u(dividend)?,
            collateral_value: u(collateral_value)?,
            safe_ltv: u(safe_ltv)?,
        })
    }
}

/// Pool capacity (R-13) including uncovered markets.
#[wasm_bindgen(
    js_name = poolCapacityWithUncovered,
    unchecked_return_type = "{ ok: boolean; utilAfter: bigint; worstLoss: bigint }"
)]
pub fn pool_capacity_with_uncovered(
    current: Vec<u64>,
    add: Vec<u64>,
    uncovered: Vec<Uncovered>,
    kappa: &BigInt,
    equity: &BigInt,
    u_max: &BigInt,
) -> R<JsValue> {
    capacity(current, add, &uncovered, kappa, equity, u_max)
}

fn capacity(
    current: Vec<u64>,
    add: Vec<u64>,
    uncovered: &[Uncovered],
    kappa: &BigInt,
    equity: &BigInt,
    u_max: &BigInt,
) -> R<JsValue> {
    if current.len() != add.len() {
        return Err(JsError::new("current and add must both be K long"));
    }
    let k = u32::try_from(current.len()).map_err(|_| JsError::new("K too large"))?;
    let slices: Vec<core::SliceZ<'_>> = uncovered.iter().map(|m| core::SliceZ(&m.joint)).collect();
    let unc: Vec<core::UncoveredMarket<'_, core::SliceZ<'_>>> = slices
        .iter()
        .zip(uncovered)
        .map(|(j, m)| core::UncoveredMarket {
            joint: j,
            sigma: m.sigma,
            dividend: m.dividend,
            collateral_value: m.collateral_value,
            safe_ltv: m.safe_ltv,
        })
        .collect();
    let r = core::pool_capacity(
        &pack_u64(&current),
        &pack_u64(&add),
        k,
        &unc,
        u(kappa)?,
        u(equity)?,
        u(u_max)?,
    )
    .map_err(math)?;
    Ok(obj(&[
        ("ok", JsValue::from(r.ok)),
        ("utilAfter", big(r.util_after).into()),
        ("worstLoss", big(r.worst_loss).into()),
    ]))
}

// ───────────────────────────── F-4.5 ─────────────────────────────

/// Reopen liquidation lot (F-4.5a), collateral base units.
#[wasm_bindgen(js_name = liquidationLot)]
#[allow(clippy::too_many_arguments)]
pub fn liquidation_lot(
    debt: &BigInt,
    qty: &BigInt,
    sizing_price: &BigInt,
    hf_price: &BigInt,
    lt: &BigInt,
    h_star: &BigInt,
    lambda: &BigInt,
    coll_dec: u8,
    loan_dec: u8,
) -> R<BigInt> {
    Ok(big(core::liquidation_lot(
        u(debt)?,
        u(qty)?,
        u(sizing_price)?,
        u(hf_price)?,
        u(lt)?,
        u(h_star)?,
        u(lambda)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?))
}

/// Pre-close lot (F-4.5b, R-06), collateral base units.
#[wasm_bindgen(js_name = precloseLot)]
#[allow(clippy::too_many_arguments)]
pub fn preclose_lot(
    debt: &BigInt,
    qty: &BigInt,
    valuation: &BigInt,
    reserve: &BigInt,
    target_ltv: &BigInt,
    lambda_pre: &BigInt,
    coll_dec: u8,
    loan_dec: u8,
) -> R<BigInt> {
    Ok(big(core::preclose_lot(
        u(debt)?,
        u(qty)?,
        u(valuation)?,
        u(reserve)?,
        u(target_ltv)?,
        u(lambda_pre)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?))
}

/// Settle one position (F-4.5d).
#[wasm_bindgen(
    js_name = settlePosition,
    unchecked_return_type = "{ proceeds: bigint; penalty: bigint; repaid: bigint; refund: bigint; shortfall: bigint; debtAfter: bigint; fullClose: boolean }"
)]
pub fn settle_position(
    x: &BigInt,
    q_before: &BigInt,
    blended_price: &BigInt,
    debt: &BigInt,
    lambda: &BigInt,
    coll_dec: u8,
    loan_dec: u8,
) -> R<JsValue> {
    let s = core::settle_position(
        u(x)?,
        u(q_before)?,
        u(blended_price)?,
        u(debt)?,
        u(lambda)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?;
    Ok(obj(&[
        ("proceeds", big(s.proceeds).into()),
        ("penalty", big(s.penalty).into()),
        ("repaid", big(s.repaid).into()),
        ("refund", big(s.refund).into()),
        ("shortfall", big(s.shortfall).into()),
        ("debtAfter", big(s.debt_after).into()),
        ("fullClose", JsValue::from(s.full_close)),
    ]))
}

/// Uniform-price clearing (F-4.5c). `tieKeys` are 0x-hex bytes32.
#[wasm_bindgen(unchecked_return_type = "{ pStar: bigint; fills: bigint[]; qPool: bigint }")]
pub fn clear(
    qtys: Vec<BigInt>,
    prices: Vec<BigInt>,
    tie_keys: Vec<String>,
    lot: &BigInt,
    reserve: &BigInt,
) -> R<JsValue> {
    let keys = tie_keys
        .iter()
        .map(|k| {
            k.parse::<B256>()
                .map_err(|e| JsError::new(&format!("tie key: {e}")))
        })
        .collect::<R<Vec<_>>>()?;
    let r = core::clear(&us(&qtys)?, &us(&prices)?, &keys, u(lot)?, u(reserve)?).map_err(math)?;
    let fills = js_sys::Array::new();
    for f in r.fills {
        fills.push(&big(f).into());
    }
    Ok(obj(&[
        ("pStar", big(r.p_star).into()),
        ("fills", fills.into()),
        ("qPool", big(r.q_pool).into()),
    ]))
}

/// Blended settlement price, WAD.
#[wasm_bindgen(js_name = blendedPrice)]
pub fn blended_price(
    lot: &BigInt,
    p_star: &BigInt,
    q_pool: &BigInt,
    reserve: &BigInt,
) -> R<BigInt> {
    Ok(big(core::blended_price(
        u(lot)?,
        u(p_star)?,
        u(q_pool)?,
        u(reserve)?,
    )
    .map_err(math)?))
}

// ───────────────────────────── F-4.6 ─────────────────────────────

/// borrowed / supplied, WAD.
#[wasm_bindgen]
pub fn utilization(borrowed: &BigInt, supplied: &BigInt) -> R<BigInt> {
    Ok(big(
        core::utilization(u(borrowed)?, u(supplied)?).map_err(math)?
    ))
}

/// Kinked borrow rate, WAD per year.
#[wasm_bindgen(js_name = kinkedRate)]
pub fn kinked_rate(
    util: &BigInt,
    r0: &BigInt,
    s1: &BigInt,
    s2: &BigInt,
    u_kink: &BigInt,
) -> R<BigInt> {
    Ok(big(core::kinked_rate(
        u(util)?,
        u(r0)?,
        u(s1)?,
        u(s2)?,
        u(u_kink)?,
    )
    .map_err(math)?))
}

/// Senior (vault) rate, WAD per year.
#[wasm_bindgen(js_name = seniorRate)]
pub fn senior_rate(
    borrow_rate: &BigInt,
    util: &BigInt,
    rho_pool: &BigInt,
    rho_treasury: &BigInt,
) -> R<BigInt> {
    Ok(big(core::senior_rate(
        u(borrow_rate)?,
        u(util)?,
        u(rho_pool)?,
        u(rho_treasury)?,
    )
    .map_err(math)?))
}

/// Interest over `dt` seconds, loan units.
#[wasm_bindgen(js_name = accrueInterest)]
pub fn accrue_interest(borrowed: &BigInt, rate: &BigInt, dt: &BigInt) -> R<BigInt> {
    Ok(big(core::accrue_interest(
        u(borrowed)?,
        u(rate)?,
        small(dt, "dt")?,
    )
    .map_err(math)?))
}

/// Debt projected `days` ahead (R-08), loan units.
#[wasm_bindgen(js_name = projectedDebt)]
pub fn projected_debt(debt: &BigInt, rate: &BigInt, days: u16) -> R<BigInt> {
    Ok(big(
        core::projected_debt(u(debt)?, u(rate)?, days).map_err(math)?
    ))
}
