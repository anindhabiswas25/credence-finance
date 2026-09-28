//! # credence_risk (Python)
//!
//! risk-core for the calibration pipeline (Build Guide §10.6), built with maturin (`make risk-py-develop`).
//! Every function runs the same integer code as the Stylus Risk Engine, so results are bit-identical to the chain
//! and to `risk-cli`.
//!
//! Conventions:
//! - Every amount is a Python `int` (WAD ratios / prices, loan units, collateral base units). Inputs may also be
//!   decimal or `0x` strings. Negative values raise `ValueError`.
//! - Scenario sets are `ScenarioSet` objects (sorted once, reused across calls) or plain `list[int]` of z in
//!   thousandths of σ. Joint columns are `list[int]` in weekend order.
//! - risk-core math errors raise `credence_risk.MathError(name, code)` (a `ValueError`); `code` is the on-chain
//!   `MathError(uint8)` code. File errors raise `credence_risk.FileError("<json path>: <message>")`.
//! - Scenario-set files follow ADR-0106 (`load_set_file`, `load_joint_file`, `load_bundle`, `validate_file`,
//!   `build_set`, `build_joint`).

use alloy_primitives::{B256, U256};
use credence_risk_core as core;
use credence_risk_core::fixed::{pack_i16, pack_u64, unpack_i16};
use credence_risk_core::setfile;
use pyo3::create_exception;
use pyo3::exceptions::{PyTypeError, PyValueError};
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};
use std::path::Path;

create_exception!(
    credence_risk,
    MathError,
    PyValueError,
    "A risk-core math error: args = (name, code)."
);
create_exception!(
    credence_risk,
    FileError,
    PyValueError,
    "An invalid scenario-set / joint-set / bundle file."
);

type Obj = Py<PyAny>;

// ───────────────────────────── conversions ─────────────────────────────

fn math(e: core::MathError) -> PyErr {
    MathError::new_err((format!("{e:?}"), e.code()))
}

fn file(e: setfile::FileError) -> PyErr {
    FileError::new_err(e.to_string())
}

/// A non-negative Python int (or decimal / 0x string) → U256.
fn u(ob: &Bound<'_, PyAny>) -> PyResult<U256> {
    if let Ok(x) = ob.extract::<u64>() {
        return Ok(U256::from(x));
    }
    let s = ob.str()?.to_string();
    let s = s.trim().replace('_', "");
    let r = if let Some(h) = s.strip_prefix("0x") {
        U256::from_str_radix(h, 16)
    } else {
        U256::from_str_radix(&s, 10)
    };
    r.map_err(|_| {
        PyValueError::new_err(format!("expected a non-negative integer < 2^256, got {s}"))
    })
}

fn small<T: TryFrom<u64>>(ob: &Bound<'_, PyAny>, what: &str) -> PyResult<T> {
    let x: u64 = u(ob)?
        .try_into()
        .map_err(|_| PyValueError::new_err(format!("{what} too large")))?;
    T::try_from(x).map_err(|_| PyValueError::new_err(format!("{what} out of range")))
}

fn us(ob: &Bound<'_, PyAny>) -> PyResult<Vec<U256>> {
    ob.try_iter()?.map(|x| u(&x?)).collect()
}

/// U256 → Python int.
fn int(py: Python<'_>, x: U256) -> PyResult<Obj> {
    if let Ok(v) = u64::try_from(x) {
        return Ok(v.into_pyobject(py)?.into_any().unbind());
    }
    Ok(py
        .import("builtins")?
        .getattr("int")?
        .call1((x.to_string(),))?
        .unbind())
}

fn ints(py: Python<'_>, xs: &[U256]) -> PyResult<Obj> {
    let items = xs
        .iter()
        .map(|x| int(py, *x))
        .collect::<PyResult<Vec<_>>>()?;
    Ok(PyList::new(py, items)?.into_any().unbind())
}

fn hex(b: B256) -> String {
    format!("{b:#x}")
}

fn b256(ob: &Bound<'_, PyAny>) -> PyResult<B256> {
    if let Ok(b) = ob.extract::<Vec<u8>>() {
        if b.len() == 32 && !ob.is_instance_of::<pyo3::types::PyString>() {
            return Ok(B256::from_slice(&b));
        }
    }
    let s: String = ob.extract()?;
    s.parse::<B256>()
        .map_err(|e| PyValueError::new_err(format!("expected 32 bytes or 0x + 64 hex: {e}")))
}

fn to_py(py: Python<'_>, v: &serde_json::Value) -> PyResult<Obj> {
    Ok(py
        .import("json")?
        .call_method1("loads", (v.to_string(),))?
        .unbind())
}

fn from_py(py: Python<'_>, ob: &Bound<'_, PyAny>) -> PyResult<serde_json::Value> {
    let s: String = py.import("json")?.call_method1("dumps", (ob,))?.extract()?;
    serde_json::from_str(&s).map_err(|e| PyValueError::new_err(format!("meta is not JSON: {e}")))
}

// ───────────────────────────── scenario sets ─────────────────────────────

/// A sorted scenario set held in Rust memory. Build it once (`load_set`, `load_set_file`), pass it to every call.
#[pyclass(frozen, module = "credence_risk")]
struct ScenarioSet {
    z: Vec<i16>,
    /// "NVDA:XNAS" when known.
    #[pyo3(get)]
    asset: Option<String>,
    /// 0x assetId when loaded from a file.
    #[pyo3(get)]
    asset_id: Option<String>,
    /// 1, 2 or 3 when loaded from a file.
    #[pyo3(get)]
    closure_type: Option<u8>,
    /// keccak256 of the packed words (== engine.scenarioHash) when loaded from a file.
    #[pyo3(get)]
    scenario_hash: Option<String>,
    /// ADR-0106 content hash when loaded from a file.
    #[pyo3(get)]
    content_hash: Option<String>,
}

impl ScenarioSet {
    fn from_file(s: setfile::ScenarioSet) -> Self {
        ScenarioSet {
            asset: s.asset,
            asset_id: Some(hex(s.asset_id)),
            closure_type: Some(s.closure_type),
            scenario_hash: Some(hex(s.scenario_hash)),
            content_hash: Some(hex(s.content_hash)),
            z: s.z,
        }
    }
}

#[pymethods]
impl ScenarioSet {
    /// A set from ascending z values (thousandths of σ). Raises MathError(NotSorted) otherwise.
    #[new]
    fn new(z: Vec<i16>) -> PyResult<Self> {
        if z.is_empty() {
            return Err(math(core::MathError::EmptySet));
        }
        if !core::is_sorted(&core::SliceZ(&z)) {
            return Err(math(core::MathError::NotSorted));
        }
        Ok(ScenarioSet {
            z,
            asset: None,
            asset_id: None,
            closure_type: None,
            scenario_hash: None,
            content_hash: None,
        })
    }

    /// The z values (a copy).
    #[getter]
    fn z(&self) -> Vec<i16> {
        self.z.clone()
    }

    /// N.
    #[getter]
    fn n(&self) -> usize {
        self.z.len()
    }

    /// The on-chain payload: 16 × int16 per word.
    fn packed(&self, py: Python<'_>) -> PyResult<Obj> {
        ints(py, &pack_i16(&self.z))
    }

    fn __len__(&self) -> usize {
        self.z.len()
    }

    fn __repr__(&self) -> String {
        format!(
            "ScenarioSet(asset={:?}, closure_type={:?}, n={})",
            self.asset,
            self.closure_type,
            self.z.len()
        )
    }
}

/// Borrow the z values of a `ScenarioSet`, or sort-check a `list[int]`.
fn with_set<R>(ob: &Bound<'_, PyAny>, f: impl FnOnce(&[i16]) -> PyResult<R>) -> PyResult<R> {
    if let Ok(s) = ob.extract::<PyRef<'_, ScenarioSet>>() {
        return f(&s.z);
    }
    let z: Vec<i16> = ob
        .extract()
        .map_err(|_| PyTypeError::new_err("expected a ScenarioSet or a list of int16"))?;
    if !core::is_sorted(&core::SliceZ(&z)) {
        return Err(math(core::MathError::NotSorted));
    }
    f(&z)
}

fn column(ob: &Bound<'_, PyAny>) -> PyResult<Vec<i16>> {
    if let Ok(s) = ob.extract::<PyRef<'_, ScenarioSet>>() {
        return Ok(s.z.clone());
    }
    ob.extract()
        .map_err(|_| PyTypeError::new_err("a joint column must be a list of int16"))
}

/// A `ScenarioSet` from ascending z values (the "load set" of QE's Engine protocol).
#[pyfunction]
fn load_set(z: Vec<i16>) -> PyResult<ScenarioSet> {
    ScenarioSet::new(z)
}

/// Load and fully validate an ADR-0106 scenario-set file.
#[pyfunction]
fn load_set_file(path: &str) -> PyResult<ScenarioSet> {
    Ok(ScenarioSet::from_file(
        setfile::load_set_path(Path::new(path)).map_err(file)?,
    ))
}

fn joint_dict<'py>(py: Python<'py>, j: &setfile::JointSet) -> PyResult<Bound<'py, PyDict>> {
    let d = PyDict::new(py);
    d.set_item("k", j.k)?;
    d.set_item("contentHash", hex(j.content_hash))?;
    let cols = PyDict::new(py);
    for c in &j.columns {
        let cd = PyDict::new(py);
        cd.set_item("asset", c.asset.clone())?;
        cd.set_item("z", c.z.clone())?;
        cd.set_item("columnHash", hex(c.column_hash))?;
        cols.set_item(hex(c.asset_id), cd)?;
    }
    d.set_item("columns", cols)?;
    Ok(d)
}

/// Load and validate an ADR-0106 joint-set file:
/// `{"k", "contentHash", "columns": {assetId: {"asset", "z", "columnHash"}}}` (columns in file order).
#[pyfunction]
fn load_joint_file<'py>(py: Python<'py>, path: &str) -> PyResult<Bound<'py, PyDict>> {
    joint_dict(
        py,
        &setfile::load_joint_path(Path::new(path)).map_err(file)?,
    )
}

/// Load and validate a risk bundle and every file it references:
/// `{"params": {name: int}, "sets": [ScenarioSet], "joint": dict | None,
///   "sigmaFloors": [(assetId, closureType, floor)], "sigmas": [(assetId, closureType, sigma)]}`.
#[pyfunction]
fn load_bundle<'py>(py: Python<'py>, path: &str) -> PyResult<Bound<'py, PyDict>> {
    let b = setfile::load_bundle_path(Path::new(path)).map_err(file)?;
    let d = PyDict::new(py);
    let params = PyDict::new(py);
    for (k, v) in setfile::PARAM_KEYS.iter().zip(b.params.iter()) {
        params.set_item(*k, *v)?;
    }
    d.set_item("params", params)?;
    let sets = b
        .sets
        .into_iter()
        .map(|s| Py::new(py, ScenarioSet::from_file(s)))
        .collect::<PyResult<Vec<_>>>()?;
    d.set_item("sets", sets)?;
    match &b.joint {
        Some(j) => d.set_item("joint", joint_dict(py, j)?)?,
        None => d.set_item("joint", py.None())?,
    }
    for (key, list) in [("sigmaFloors", &b.sigma_floors), ("sigmas", &b.sigmas)] {
        let items = list
            .iter()
            .map(|(id, ty, v)| Ok((hex(*id), *ty, int(py, *v)?)))
            .collect::<PyResult<Vec<_>>>()?;
        d.set_item(key, items)?;
    }
    Ok(d)
}

/// Validate a set / joint / bundle file (same as `risk-cli validate-set`); returns the summary dict or raises
/// FileError.
#[pyfunction]
fn validate_file(py: Python<'_>, path: &str) -> PyResult<Obj> {
    to_py(py, &setfile::validate_path(Path::new(path)).map_err(file)?)
}

/// The canonical ADR-0106 scenario-set document and its file name: `(doc, file_name)`; `json.dump(doc)` it.
/// `meta` is any JSON-able object (not hashed).
#[pyfunction]
#[pyo3(signature = (asset, closure_type, z, meta=None))]
fn build_set(
    py: Python<'_>,
    asset: &str,
    closure_type: u8,
    z: Vec<i16>,
    meta: Option<&Bound<'_, PyAny>>,
) -> PyResult<(Obj, String)> {
    let s = setfile::build_set(asset, closure_type, &z).map_err(file)?;
    let meta = meta.map(|m| from_py(py, m)).transpose()?;
    Ok((
        to_py(py, &setfile::set_to_json(&s, meta))?,
        setfile::set_file_name(&s),
    ))
}

/// The canonical ADR-0106 joint-set document; `columns` = [(asset, z in weekend order), …].
/// Returns `(doc, file_name)`.
#[pyfunction]
#[pyo3(signature = (columns, meta=None))]
fn build_joint(
    py: Python<'_>,
    columns: Vec<(String, Vec<i16>)>,
    meta: Option<&Bound<'_, PyAny>>,
) -> PyResult<(Obj, String)> {
    let refs: Vec<(&str, Vec<i16>)> = columns
        .iter()
        .map(|(a, z)| (a.as_str(), z.clone()))
        .collect();
    let j = setfile::build_joint(&refs).map_err(file)?;
    let meta = meta.map(|m| from_py(py, m)).transpose()?;
    let name = format!("joint-{}.json", &format!("{:x}", j.content_hash)[..8]);
    Ok((to_py(py, &setfile::joint_to_json(&j, meta))?, name))
}

/// keccak256("TICKER:MIC") as 0x hex.
#[pyfunction]
fn asset_id(asset: &str) -> String {
    hex(setfile::asset_id_of(asset))
}

/// Pack int16 values 16 per word (lane 0 = least-significant bits).
#[pyfunction]
fn pack_z(py: Python<'_>, z: Vec<i16>) -> PyResult<Obj> {
    ints(py, &pack_i16(&z))
}

/// Unpack `n` int16 values from packed words.
#[pyfunction]
fn unpack_z(words: &Bound<'_, PyAny>, n: usize) -> PyResult<Vec<i16>> {
    let w = us(words)?;
    if n.div_ceil(16) > w.len() {
        return Err(math(core::MathError::InvalidInput));
    }
    Ok((0..n).map(|i| unpack_i16(w[i / 16], i % 16)).collect())
}

// ───────────────────────────── F-4.2 safe LTV, Bell ─────────────────────────────

/// Safe LTV for one z (F-4.2), WAD, rounded down.
#[pyfunction]
#[pyo3(signature = (z, sigma, dividend, kappa, max_ltv))]
fn safe_ltv(
    py: Python<'_>,
    z: i16,
    sigma: &Bound<'_, PyAny>,
    dividend: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
    max_ltv: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::safe_ltv(z, u(sigma)?, u(dividend)?, u(kappa)?, u(max_ltv)?).map_err(math)?,
    )
}

/// Safe LTV at the α-quantile of a set (what `engine.safeLtv` computes).
#[pyfunction]
#[pyo3(signature = (set, alpha, sigma, dividend, kappa, max_ltv))]
fn safe_ltv_from_set(
    py: Python<'_>,
    set: &Bound<'_, PyAny>,
    alpha: &Bound<'_, PyAny>,
    sigma: &Bound<'_, PyAny>,
    dividend: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
    max_ltv: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    let (a, s, d, k, m) = (u(alpha)?, u(sigma)?, u(dividend)?, u(kappa)?, u(max_ltv)?);
    let v = with_set(set, |z| {
        core::safe_ltv_from_set(&core::SliceZ(z), a, s, d, k, m).map_err(math)
    })?;
    int(py, v)
}

/// Gap factor 1 + z·σ − d − κ (floored at 0), WAD.
#[pyfunction]
fn gap_factor(
    py: Python<'_>,
    z: i16,
    sigma: &Bound<'_, PyAny>,
    dividend: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::gap_factor(z, u(sigma)?, u(dividend)?, u(kappa)?).map_err(math)?,
    )
}

/// ceil(α·N) − 1 (0-based quantile index).
#[pyfunction]
fn quantile_index(n: u32, alpha: &Bound<'_, PyAny>) -> PyResult<u32> {
    core::quantile_index(n, u(alpha)?).map_err(math)
}

/// Cure amounts: `(repay, add_collateral, add_collateral_value)`.
#[pyfunction]
#[pyo3(signature = (debt_projected, qty, price, safe_ltv, coll_dec=18, loan_dec=6))]
fn cure_amounts(
    py: Python<'_>,
    debt_projected: &Bound<'_, PyAny>,
    qty: &Bound<'_, PyAny>,
    price: &Bound<'_, PyAny>,
    safe_ltv: &Bound<'_, PyAny>,
    coll_dec: u8,
    loan_dec: u8,
) -> PyResult<(Obj, Obj, Obj)> {
    let c = core::cure_amounts(
        u(debt_projected)?,
        u(qty)?,
        u(price)?,
        u(safe_ltv)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?;
    Ok((
        int(py, c.repay)?,
        int(py, c.add_collateral)?,
        int(py, c.add_collateral_value)?,
    ))
}

/// Bell status: `(status, cure_repay, cure_collateral_value)`; status 0 SAFE, 1 AT_RISK, 2 COVERED (Types.sol).
#[pyfunction]
fn bell_status(
    py: Python<'_>,
    collateral_value: &Bound<'_, PyAny>,
    debt_projected: &Bound<'_, PyAny>,
    safe_ltv: &Bound<'_, PyAny>,
    covered: bool,
) -> PyResult<(u8, Obj, Obj)> {
    let b = core::bell_status(
        u(collateral_value)?,
        u(debt_projected)?,
        u(safe_ltv)?,
        covered,
    )
    .map_err(math)?;
    Ok((
        b.status,
        int(py, b.cure_repay)?,
        int(py, b.cure_collateral_value)?,
    ))
}

/// Whole days between two timestamps (for σ decay).
#[pyfunction]
fn elapsed_days(from_ts: u64, now: u64) -> u64 {
    core::elapsed_days(from_ts, now)
}

/// Lowest σ the engine accepts after `days` days: current × 0.9^days, rounded up (R-15).
#[pyfunction]
fn sigma_min_allowed(py: Python<'_>, current: &Bound<'_, PyAny>, days: u64) -> PyResult<Obj> {
    int(
        py,
        core::sigma_min_allowed(u(current)?, days).map_err(math)?,
    )
}

// ───────────────────────────── F-4.3 premium, F-4.4 capacity ─────────────────────────────

/// Gap Cover quote: `(premium, expected_loss, expected_shortfall)` in loan units.
#[pyfunction]
#[pyo3(signature = (set, sigma, dividend, kappa, collateral_value, debt_projected, closure_days, util_after,
                    theta, cost_of_cap, eta, beta, min_premium=None))]
#[allow(clippy::too_many_arguments)]
fn quote_cover(
    py: Python<'_>,
    set: &Bound<'_, PyAny>,
    sigma: &Bound<'_, PyAny>,
    dividend: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
    collateral_value: &Bound<'_, PyAny>,
    debt_projected: &Bound<'_, PyAny>,
    closure_days: &Bound<'_, PyAny>,
    util_after: &Bound<'_, PyAny>,
    theta: &Bound<'_, PyAny>,
    cost_of_cap: &Bound<'_, PyAny>,
    eta: &Bound<'_, PyAny>,
    beta: &Bound<'_, PyAny>,
    min_premium: Option<&Bound<'_, PyAny>>,
) -> PyResult<(Obj, Obj, Obj)> {
    let p = core::PremiumParams {
        sigma: u(sigma)?,
        dividend: u(dividend)?,
        kappa: u(kappa)?,
        collateral_value: u(collateral_value)?,
        debt_projected: u(debt_projected)?,
        closure_days: small(closure_days, "closure_days")?,
        util_after: u(util_after)?,
        theta: u(theta)?,
        cost_of_cap: u(cost_of_cap)?,
        eta: u(eta)?,
        beta: u(beta)?,
        min_premium: min_premium.map(u).transpose()?.unwrap_or(U256::ZERO),
    };
    let q = with_set(set, |z| {
        core::quote_cover(&core::SliceZ(z), &p).map_err(math)
    })?;
    Ok((
        int(py, q.premium)?,
        int(py, q.expected_loss)?,
        int(py, q.expected_shortfall)?,
    ))
}

/// Per-weekend loss of a covered position over the joint column (`engine.coverLossVector`, unpacked), loan units.
#[pyfunction]
fn cover_loss_vector(
    joint: &Bound<'_, PyAny>,
    collateral_value: &Bound<'_, PyAny>,
    debt_projected: &Bound<'_, PyAny>,
    sigma: &Bound<'_, PyAny>,
    dividend: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
) -> PyResult<Vec<u64>> {
    let j = column(joint)?;
    core::loss_vector(
        &core::SliceZ(&j),
        u(collateral_value)?,
        u(debt_projected)?,
        u(sigma)?,
        u(dividend)?,
        u(kappa)?,
    )
    .map_err(math)
}

/// Pack loss values 4 × uint64 per word (the on-chain loss-vector layout).
#[pyfunction]
fn pack_losses(py: Python<'_>, losses: Vec<u64>) -> PyResult<Obj> {
    ints(py, &pack_u64(&losses))
}

/// Pool capacity (R-13): `(ok, util_after, worst_loss)`. `current` / `add` are unpacked K-long loss vectors;
/// `uncovered` = [(joint_column, sigma, dividend, collateral_value, safe_ltv), …].
#[pyfunction]
#[pyo3(signature = (current, add, uncovered, kappa, equity, u_max))]
fn pool_capacity(
    py: Python<'_>,
    current: Vec<u64>,
    add: Vec<u64>,
    uncovered: &Bound<'_, PyAny>,
    kappa: &Bound<'_, PyAny>,
    equity: &Bound<'_, PyAny>,
    u_max: &Bound<'_, PyAny>,
) -> PyResult<(bool, Obj, Obj)> {
    if current.len() != add.len() {
        return Err(PyValueError::new_err("current and add must both be K long"));
    }
    let k = u32::try_from(current.len()).map_err(|_| PyValueError::new_err("K too large"))?;
    let mut joints = Vec::new();
    let mut params = Vec::new();
    for m in uncovered.try_iter()? {
        let m = m?;
        let t: Vec<Bound<'_, PyAny>> = m.try_iter()?.collect::<PyResult<_>>()?;
        if t.len() != 5 {
            return Err(PyTypeError::new_err(
                "uncovered entries are (joint, sigma, dividend, collateral_value, safe_ltv)",
            ));
        }
        joints.push(column(&t[0])?);
        params.push((u(&t[1])?, u(&t[2])?, u(&t[3])?, u(&t[4])?));
    }
    let slices: Vec<core::SliceZ<'_>> = joints.iter().map(|j| core::SliceZ(j)).collect();
    let unc: Vec<core::UncoveredMarket<'_, core::SliceZ<'_>>> = slices
        .iter()
        .zip(params.iter())
        .map(|(j, p)| core::UncoveredMarket {
            joint: j,
            sigma: p.0,
            dividend: p.1,
            collateral_value: p.2,
            safe_ltv: p.3,
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
    Ok((r.ok, int(py, r.util_after)?, int(py, r.worst_loss)?))
}

// ───────────────────────────── F-4.5 liquidation ─────────────────────────────

/// Reopen liquidation lot x (F-4.5a), collateral base units.
#[pyfunction]
#[pyo3(signature = (debt, qty, sizing_price, hf_price, lt, h_star, lam, coll_dec=18, loan_dec=6))]
#[allow(clippy::too_many_arguments)]
fn liquidation_lot(
    py: Python<'_>,
    debt: &Bound<'_, PyAny>,
    qty: &Bound<'_, PyAny>,
    sizing_price: &Bound<'_, PyAny>,
    hf_price: &Bound<'_, PyAny>,
    lt: &Bound<'_, PyAny>,
    h_star: &Bound<'_, PyAny>,
    lam: &Bound<'_, PyAny>,
    coll_dec: u8,
    loan_dec: u8,
) -> PyResult<Obj> {
    int(
        py,
        core::liquidation_lot(
            u(debt)?,
            u(qty)?,
            u(sizing_price)?,
            u(hf_price)?,
            u(lt)?,
            u(h_star)?,
            u(lam)?,
            coll_dec,
            loan_dec,
        )
        .map_err(math)?,
    )
}

/// Pre-close lot (F-4.5b, R-06), collateral base units.
#[pyfunction]
#[pyo3(signature = (debt, qty, valuation, reserve, target_ltv, lambda_pre, coll_dec=18, loan_dec=6))]
#[allow(clippy::too_many_arguments)]
fn preclose_lot(
    py: Python<'_>,
    debt: &Bound<'_, PyAny>,
    qty: &Bound<'_, PyAny>,
    valuation: &Bound<'_, PyAny>,
    reserve: &Bound<'_, PyAny>,
    target_ltv: &Bound<'_, PyAny>,
    lambda_pre: &Bound<'_, PyAny>,
    coll_dec: u8,
    loan_dec: u8,
) -> PyResult<Obj> {
    int(
        py,
        core::preclose_lot(
            u(debt)?,
            u(qty)?,
            u(valuation)?,
            u(reserve)?,
            u(target_ltv)?,
            u(lambda_pre)?,
            coll_dec,
            loan_dec,
        )
        .map_err(math)?,
    )
}

/// Settle one position (F-4.5d): dict with proceeds, penalty, repaid, refund, shortfall, debtAfter, fullClose
/// (the same keys as `risk-cli settle`).
#[pyfunction]
#[pyo3(signature = (x, q_before, blended_price, debt, lam, coll_dec=18, loan_dec=6))]
#[allow(clippy::too_many_arguments)]
fn settle_position<'py>(
    py: Python<'py>,
    x: &Bound<'_, PyAny>,
    q_before: &Bound<'_, PyAny>,
    blended_price: &Bound<'_, PyAny>,
    debt: &Bound<'_, PyAny>,
    lam: &Bound<'_, PyAny>,
    coll_dec: u8,
    loan_dec: u8,
) -> PyResult<Bound<'py, PyDict>> {
    let s = core::settle_position(
        u(x)?,
        u(q_before)?,
        u(blended_price)?,
        u(debt)?,
        u(lam)?,
        coll_dec,
        loan_dec,
    )
    .map_err(math)?;
    let d = PyDict::new(py);
    d.set_item("proceeds", int(py, s.proceeds)?)?;
    d.set_item("penalty", int(py, s.penalty)?)?;
    d.set_item("repaid", int(py, s.repaid)?)?;
    d.set_item("refund", int(py, s.refund)?)?;
    d.set_item("shortfall", int(py, s.shortfall)?)?;
    d.set_item("debtAfter", int(py, s.debt_after)?)?;
    d.set_item("fullClose", s.full_close)?;
    Ok(d)
}

/// Uniform-price clearing (F-4.5c): `(p_star, fills, q_pool)`. `tie_keys` are 32-byte values (bytes or 0x hex).
#[pyfunction]
fn clear(
    py: Python<'_>,
    qtys: &Bound<'_, PyAny>,
    prices: &Bound<'_, PyAny>,
    tie_keys: &Bound<'_, PyAny>,
    lot: &Bound<'_, PyAny>,
    reserve: &Bound<'_, PyAny>,
) -> PyResult<(Obj, Obj, Obj)> {
    let keys = tie_keys
        .try_iter()?
        .map(|k| b256(&k?))
        .collect::<PyResult<Vec<_>>>()?;
    let r = core::clear(&us(qtys)?, &us(prices)?, &keys, u(lot)?, u(reserve)?).map_err(math)?;
    Ok((int(py, r.p_star)?, ints(py, &r.fills)?, int(py, r.q_pool)?))
}

/// Blended settlement price of a lot (auction fills + pool at the reserve), WAD.
#[pyfunction]
fn blended_price(
    py: Python<'_>,
    lot: &Bound<'_, PyAny>,
    p_star: &Bound<'_, PyAny>,
    q_pool: &Bound<'_, PyAny>,
    reserve: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::blended_price(u(lot)?, u(p_star)?, u(q_pool)?, u(reserve)?).map_err(math)?,
    )
}

// ───────────────────────────── F-4.6 rates ─────────────────────────────

/// Utilisation borrowed / supplied, WAD.
#[pyfunction]
fn utilization(
    py: Python<'_>,
    borrowed: &Bound<'_, PyAny>,
    supplied: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::utilization(u(borrowed)?, u(supplied)?).map_err(math)?,
    )
}

/// Kinked borrow rate (WAD per year).
#[pyfunction]
fn kinked_rate(
    py: Python<'_>,
    util: &Bound<'_, PyAny>,
    r0: &Bound<'_, PyAny>,
    s1: &Bound<'_, PyAny>,
    s2: &Bound<'_, PyAny>,
    u_kink: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::kinked_rate(u(util)?, u(r0)?, u(s1)?, u(s2)?, u(u_kink)?).map_err(math)?,
    )
}

/// Senior (vault) rate from the borrow rate and fee split, WAD per year.
#[pyfunction]
fn senior_rate(
    py: Python<'_>,
    borrow_rate: &Bound<'_, PyAny>,
    utilization: &Bound<'_, PyAny>,
    rho_pool: &Bound<'_, PyAny>,
    rho_treasury: &Bound<'_, PyAny>,
) -> PyResult<Obj> {
    int(
        py,
        core::senior_rate(
            u(borrow_rate)?,
            u(utilization)?,
            u(rho_pool)?,
            u(rho_treasury)?,
        )
        .map_err(math)?,
    )
}

/// Simple interest over `dt` seconds, loan units, rounded up.
#[pyfunction]
fn accrue_interest(
    py: Python<'_>,
    borrowed: &Bound<'_, PyAny>,
    rate: &Bound<'_, PyAny>,
    dt: u64,
) -> PyResult<Obj> {
    int(
        py,
        core::accrue_interest(u(borrowed)?, u(rate)?, dt).map_err(math)?,
    )
}

/// Debt projected `days` ahead (R-08), loan units, rounded up.
#[pyfunction]
fn projected_debt(
    py: Python<'_>,
    debt: &Bound<'_, PyAny>,
    rate: &Bound<'_, PyAny>,
    days: u16,
) -> PyResult<Obj> {
    int(
        py,
        core::projected_debt(u(debt)?, u(rate)?, days).map_err(math)?,
    )
}

// ───────────────────────────── module ─────────────────────────────

#[pymodule]
fn credence_risk(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("MathError", m.py().get_type::<MathError>())?;
    m.add("FileError", m.py().get_type::<FileError>())?;
    m.add("WAD", 1_000_000_000_000_000_000u64)?;
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add_class::<ScenarioSet>()?;
    m.add_function(wrap_pyfunction!(load_set, m)?)?;
    m.add_function(wrap_pyfunction!(load_set_file, m)?)?;
    m.add_function(wrap_pyfunction!(load_joint_file, m)?)?;
    m.add_function(wrap_pyfunction!(load_bundle, m)?)?;
    m.add_function(wrap_pyfunction!(validate_file, m)?)?;
    m.add_function(wrap_pyfunction!(build_set, m)?)?;
    m.add_function(wrap_pyfunction!(build_joint, m)?)?;
    m.add_function(wrap_pyfunction!(asset_id, m)?)?;
    m.add_function(wrap_pyfunction!(pack_z, m)?)?;
    m.add_function(wrap_pyfunction!(unpack_z, m)?)?;
    m.add_function(wrap_pyfunction!(safe_ltv, m)?)?;
    m.add_function(wrap_pyfunction!(safe_ltv_from_set, m)?)?;
    m.add_function(wrap_pyfunction!(gap_factor, m)?)?;
    m.add_function(wrap_pyfunction!(quantile_index, m)?)?;
    m.add_function(wrap_pyfunction!(cure_amounts, m)?)?;
    m.add_function(wrap_pyfunction!(bell_status, m)?)?;
    m.add_function(wrap_pyfunction!(elapsed_days, m)?)?;
    m.add_function(wrap_pyfunction!(sigma_min_allowed, m)?)?;
    m.add_function(wrap_pyfunction!(quote_cover, m)?)?;
    m.add_function(wrap_pyfunction!(cover_loss_vector, m)?)?;
    m.add_function(wrap_pyfunction!(pack_losses, m)?)?;
    // the name QE's Engine protocol uses
    m.add("loss_vector", m.getattr("cover_loss_vector")?)?;
    m.add_function(wrap_pyfunction!(pool_capacity, m)?)?;
    m.add_function(wrap_pyfunction!(liquidation_lot, m)?)?;
    m.add_function(wrap_pyfunction!(preclose_lot, m)?)?;
    m.add_function(wrap_pyfunction!(settle_position, m)?)?;
    m.add_function(wrap_pyfunction!(clear, m)?)?;
    m.add_function(wrap_pyfunction!(blended_price, m)?)?;
    m.add_function(wrap_pyfunction!(utilization, m)?)?;
    m.add_function(wrap_pyfunction!(kinked_rate, m)?)?;
    m.add_function(wrap_pyfunction!(senior_rate, m)?)?;
    m.add_function(wrap_pyfunction!(accrue_interest, m)?)?;
    m.add_function(wrap_pyfunction!(projected_debt, m)?)?;
    Ok(())
}
