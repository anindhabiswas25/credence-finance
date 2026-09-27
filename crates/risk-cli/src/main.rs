//! risk-cli: every credence-risk-core function as JSON in → JSON out (Build Guide §5, §14.1).
//!
//! ```text
//! risk-cli <command> [json | -] [--abi]
//! ```
//! The input is a JSON object (argument, or stdin when omitted or `-`). Integers may be JSON numbers, decimal
//! strings or 0x-hex strings. Output is a JSON object whose integers are decimal strings, or with `--abi` the
//! 0x-hex ABI encoding of the outputs in declaration order (for `vm.ffi` in Foundry, profile `ffi`).
//! Errors print `{"error": "...", "code": n}` and exit with status 1 (JSON) or 2 (usage).

use alloy_primitives::{B256, U256};
use credence_risk_core as core;
use credence_risk_core::fixed::{collateral_value, health_factor_down, ltv_up, pack_i16, pack_u64};
use serde_json::{json, Map, Value};
use std::io::Read;
use std::process::ExitCode;

const COMMANDS: &[&str] = &[
    "safe-ltv",
    "safe-ltv-from-set",
    "quantile-index",
    "cures",
    "bell-status",
    "quote-cover",
    "loss-vector",
    "pool-capacity",
    "liquidation-lot",
    "preclose-lot",
    "settle",
    "clear",
    "blended-price",
    "kinked-rate",
    "senior-rate",
    "utilization",
    "accrue-interest",
    "projected-debt",
    "sigma-min-allowed",
    "value",
    "pack-z",
];

#[derive(Debug)]
struct CliError(String, u8);

impl From<core::MathError> for CliError {
    fn from(e: core::MathError) -> Self {
        CliError(format!("{e:?}"), e.code())
    }
}

type R<T> = Result<T, CliError>;

fn bad(msg: impl Into<String>) -> CliError {
    CliError(msg.into(), 0)
}

// ───────────── input parsing ─────────────

struct Input(Map<String, Value>);

impl Input {
    fn get(&self, k: &str) -> R<&Value> {
        self.0.get(k).ok_or_else(|| bad(format!("missing field `{k}`")))
    }
    fn u(&self, k: &str) -> R<U256> {
        parse_u256(self.get(k)?).map_err(|e| bad(format!("`{k}`: {}", e.0)))
    }
    fn u_or(&self, k: &str, d: U256) -> R<U256> {
        if self.0.contains_key(k) {
            self.u(k)
        } else {
            Ok(d)
        }
    }
    fn small<T: TryFrom<u64>>(&self, k: &str) -> R<T> {
        let v = self.u(k)?;
        let x: u64 = v.try_into().map_err(|_| bad(format!("`{k}` too large")))?;
        T::try_from(x).map_err(|_| bad(format!("`{k}` out of range")))
    }
    fn small_or<T: TryFrom<u64>>(&self, k: &str, d: T) -> R<T> {
        if self.0.contains_key(k) {
            self.small(k)
        } else {
            Ok(d)
        }
    }
    fn i16(&self, k: &str) -> R<i16> {
        parse_i16(self.get(k)?)
    }
    fn bool(&self, k: &str) -> R<bool> {
        self.get(k)?.as_bool().ok_or_else(|| bad(format!("`{k}` must be a boolean")))
    }
    fn u_vec(&self, k: &str) -> R<Vec<U256>> {
        self.arr(k)?.iter().map(parse_u256).collect()
    }
    fn z_vec(&self, k: &str) -> R<Vec<i16>> {
        self.arr(k)?.iter().map(parse_i16).collect()
    }
    fn b256_vec(&self, k: &str) -> R<Vec<B256>> {
        self.arr(k)?
            .iter()
            .map(|v| {
                let s = v.as_str().ok_or_else(|| bad("tie key must be a 0x string"))?;
                s.parse::<B256>().map_err(|e| bad(format!("tie key: {e}")))
            })
            .collect()
    }
    fn arr(&self, k: &str) -> R<&Vec<Value>> {
        self.get(k)?.as_array().ok_or_else(|| bad(format!("`{k}` must be an array")))
    }
}

fn parse_u256(v: &Value) -> R<U256> {
    match v {
        Value::Number(n) => n.as_u64().map(U256::from).ok_or_else(|| bad("numbers must be non-negative integers")),
        Value::String(s) => {
            let s = s.replace('_', "");
            if let Some(h) = s.strip_prefix("0x") {
                U256::from_str_radix(h, 16).map_err(|e| bad(format!("{e}")))
            } else {
                U256::from_str_radix(&s, 10).map_err(|e| bad(format!("{e}")))
            }
        }
        _ => Err(bad("expected an integer")),
    }
}

fn parse_i16(v: &Value) -> R<i16> {
    let x = match v {
        Value::Number(n) => n.as_i64().ok_or_else(|| bad("z must be an integer"))?,
        Value::String(s) => s.parse::<i64>().map_err(|e| bad(format!("{e}")))?,
        _ => return Err(bad("z must be an integer")),
    };
    i16::try_from(x).map_err(|_| bad("z out of int16 range"))
}

// ───────────── output ─────────────

enum Out {
    U(U256),
    B(bool),
    V(Vec<U256>),
}

fn s(x: U256) -> Value {
    Value::String(x.to_string())
}

/// JSON, or the head/tail ABI encoding of the tuple (uint256 | bool | uint256[])….
fn render(fields: Vec<(&str, Out)>, abi: bool) -> String {
    if abi {
        let head_len = fields.len();
        let mut head: Vec<U256> = Vec::with_capacity(head_len);
        let mut tail: Vec<U256> = Vec::new();
        let mut dyn_slots = Vec::new();
        for (_, o) in &fields {
            match o {
                Out::U(x) => head.push(*x),
                Out::B(b) => head.push(U256::from(*b as u8)),
                Out::V(v) => {
                    dyn_slots.push((head.len(), tail.len()));
                    head.push(U256::ZERO);
                    tail.push(U256::from(v.len()));
                    tail.extend(v.iter().copied());
                }
            }
        }
        for (h, t) in dyn_slots {
            head[h] = U256::from((head_len + t) * 32);
        }
        let mut hex = String::from("0x");
        for w in head.iter().chain(tail.iter()) {
            hex.push_str(&format!("{w:064x}"));
        }
        return hex;
    }
    let mut m = Map::new();
    for (k, o) in fields {
        let v = match o {
            Out::U(x) => s(x),
            Out::B(b) => Value::Bool(b),
            Out::V(v) => Value::Array(v.into_iter().map(s).collect()),
        };
        m.insert(k.to_string(), v);
    }
    Value::Object(m).to_string()
}

// ───────────── commands ─────────────

fn premium_params(i: &Input) -> R<core::PremiumParams> {
    Ok(core::PremiumParams {
        sigma: i.u("sigma")?,
        dividend: i.u_or("dividend", U256::ZERO)?,
        kappa: i.u("kappa")?,
        collateral_value: i.u("collateralValue")?,
        debt_projected: i.u("debtProjected")?,
        closure_days: i.small("closureDays")?,
        util_after: i.u_or("utilAfter", U256::ZERO)?,
        theta: i.u("theta")?,
        cost_of_cap: i.u("costOfCap")?,
        eta: i.u("eta")?,
        beta: i.u("beta")?,
        min_premium: i.u_or("minPremium", U256::ZERO)?,
    })
}

fn sorted_set(i: &Input, k: &str) -> R<Vec<i16>> {
    let set = i.z_vec(k)?;
    if !core::is_sorted(&core::SliceZ(&set)) {
        return Err(core::MathError::NotSorted.into());
    }
    Ok(set)
}

fn run(cmd: &str, i: &Input) -> R<Vec<(&'static str, Out)>> {
    use Out::*;
    let zero = U256::ZERO;
    Ok(match cmd {
        "safe-ltv" => vec![(
            "safeLtv",
            U(core::safe_ltv(i.i16("z")?, i.u("sigma")?, i.u_or("dividend", zero)?, i.u("kappa")?, i.u("maxLtv")?)?),
        )],
        "safe-ltv-from-set" => {
            let set = sorted_set(i, "set")?;
            let v = core::safe_ltv_from_set(
                &core::SliceZ(&set),
                i.u("alpha")?,
                i.u("sigma")?,
                i.u_or("dividend", zero)?,
                i.u("kappa")?,
                i.u("maxLtv")?,
            )?;
            vec![("safeLtv", U(v))]
        }
        "quantile-index" => vec![("index", U(U256::from(core::quantile_index(i.small("n")?, i.u("alpha")?)?)))],
        "cures" => {
            let c = core::cure_amounts(
                i.u("debtProjected")?,
                i.u("qty")?,
                i.u("price")?,
                i.u("safeLtv")?,
                i.small_or("collDec", 18u8)?,
                i.small_or("loanDec", 6u8)?,
            )?;
            vec![
                ("repay", U(c.repay)),
                ("addCollateral", U(c.add_collateral)),
                ("addCollateralValue", U(c.add_collateral_value)),
            ]
        }
        "bell-status" => {
            let b = core::bell_status(
                i.u("collateralValue")?,
                i.u("debtProjected")?,
                i.u("safeLtv")?,
                i.bool("covered")?,
            )?;
            vec![
                ("status", U(U256::from(b.status))),
                ("cureRepay", U(b.cure_repay)),
                ("cureCollateralValue", U(b.cure_collateral_value)),
            ]
        }
        "quote-cover" => {
            let set = sorted_set(i, "set")?;
            let q = core::quote_cover(&core::SliceZ(&set), &premium_params(i)?)?;
            vec![
                ("premium", U(q.premium)),
                ("expectedLoss", U(q.expected_loss)),
                ("expectedShortfall", U(q.expected_shortfall)),
            ]
        }
        "loss-vector" => {
            let joint = i.z_vec("joint")?;
            let lv = core::loss_vector(
                &core::SliceZ(&joint),
                i.u("collateralValue")?,
                i.u("debtProjected")?,
                i.u("sigma")?,
                i.u_or("dividend", zero)?,
                i.u("kappa")?,
            )?;
            vec![("losses", V(lv.iter().map(|x| U256::from(*x)).collect())), ("packed", V(pack_u64(&lv)))]
        }
        "pool-capacity" => {
            let k: u32 = i.small("k")?;
            let cur = i.u_vec("packedCurrent")?;
            let add = i.u_vec("packedAdd")?;
            let mut joints = Vec::new();
            let mut params = Vec::new();
            for m in i.arr("uncovered")? {
                let mi = Input(m.as_object().ok_or_else(|| bad("uncovered[] entries must be objects"))?.clone());
                joints.push(mi.z_vec("joint")?);
                params.push((mi.u("sigma")?, mi.u_or("dividend", zero)?, mi.u("collateralValue")?, mi.u("safeLtv")?));
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
            let r = core::pool_capacity(&cur, &add, k, &unc, i.u("kappa")?, i.u("equity")?, i.u("uMax")?)?;
            vec![("ok", B(r.ok)), ("utilAfter", U(r.util_after)), ("worstLoss", U(r.worst_loss))]
        }
        "liquidation-lot" => vec![(
            "x",
            U(core::liquidation_lot(
                i.u("debt")?,
                i.u("qty")?,
                i.u("sizingPrice")?,
                i.u("hfPrice")?,
                i.u("lt")?,
                i.u("hStar")?,
                i.u("lambda")?,
                i.small_or("collDec", 18u8)?,
                i.small_or("loanDec", 6u8)?,
            )?),
        )],
        "preclose-lot" => vec![(
            "x",
            U(core::preclose_lot(
                i.u("debt")?,
                i.u("qty")?,
                i.u("valuation")?,
                i.u("reserve")?,
                i.u("targetLtv")?,
                i.u("lambdaPre")?,
                i.small_or("collDec", 18u8)?,
                i.small_or("loanDec", 6u8)?,
            )?),
        )],
        "settle" => {
            let st = core::settle_position(
                i.u("x")?,
                i.u("qtyBefore")?,
                i.u("blendedPrice")?,
                i.u("debt")?,
                i.u("lambda")?,
                i.small_or("collDec", 18u8)?,
                i.small_or("loanDec", 6u8)?,
            )?;
            vec![
                ("proceeds", U(st.proceeds)),
                ("penalty", U(st.penalty)),
                ("repaid", U(st.repaid)),
                ("refund", U(st.refund)),
                ("shortfall", U(st.shortfall)),
                ("debtAfter", U(st.debt_after)),
                ("fullClose", B(st.full_close)),
            ]
        }
        "clear" => {
            let r = core::clear(
                &i.u_vec("qtys")?,
                &i.u_vec("prices")?,
                &i.b256_vec("tieKeys")?,
                i.u("lot")?,
                i.u("reserve")?,
            )?;
            vec![("pStar", U(r.p_star)), ("fills", V(r.fills)), ("qPool", U(r.q_pool))]
        }
        "blended-price" => vec![(
            "blendedPrice",
            U(core::blended_price(i.u("lot")?, i.u("pStar")?, i.u("qPool")?, i.u("reserve")?)?),
        )],
        "kinked-rate" => vec![(
            "rate",
            U(core::kinked_rate(i.u("utilization")?, i.u("r0")?, i.u("s1")?, i.u("s2")?, i.u("uKink")?)?),
        )],
        "senior-rate" => vec![(
            "rate",
            U(core::senior_rate(i.u("borrowRate")?, i.u("utilization")?, i.u("rhoPool")?, i.u("rhoTreasury")?)?),
        )],
        "utilization" => vec![("utilization", U(core::utilization(i.u("borrowed")?, i.u("supplied")?)?))],
        "accrue-interest" => {
            vec![("interest", U(core::accrue_interest(i.u("borrowed")?, i.u("rate")?, i.small("dt")?)?))]
        }
        "projected-debt" => {
            vec![("debtProjected", U(core::projected_debt(i.u("debt")?, i.u("rate")?, i.small("days")?)?))]
        }
        "sigma-min-allowed" => {
            vec![("minAllowed", U(core::sigma_min_allowed(i.u("current")?, i.small("days")?)?))]
        }
        "value" => {
            let (cd, ld) = (i.small_or("collDec", 18u8)?, i.small_or("loanDec", 6u8)?);
            let c = collateral_value(i.u("qty")?, i.u("price")?, cd, ld)?;
            let d = i.u_or("debt", zero)?;
            vec![
                ("collateralValue", U(c)),
                ("ltv", U(ltv_up(d, c)?)),
                ("healthFactor", U(health_factor_down(c, i.u_or("lt", zero)?, d)?)),
            ]
        }
        "pack-z" => {
            let set = i.z_vec("set")?;
            vec![("n", U(U256::from(set.len()))), ("packed", V(pack_i16(&set)))]
        }
        _ => return Err(bad(format!("unknown command `{cmd}`; one of: {}", COMMANDS.join(", ")))),
    })
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let abi = args.iter().any(|a| a == "--abi");
    let pos: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let Some(cmd) = pos.first() else {
        eprintln!("usage: risk-cli <command> [json|-] [--abi]\ncommands: {}", COMMANDS.join(", "));
        return ExitCode::from(2);
    };
    let raw = match pos.get(1) {
        Some(j) if j.as_str() != "-" => (*j).clone(),
        _ => {
            let mut b = String::new();
            if std::io::stdin().read_to_string(&mut b).is_err() {
                eprintln!("cannot read stdin");
                return ExitCode::from(2);
            }
            b
        }
    };
    let parsed: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            println!("{}", json!({"error": format!("invalid JSON: {e}"), "code": 0}));
            return ExitCode::from(1);
        }
    };
    let Some(obj) = parsed.as_object() else {
        println!("{}", json!({"error": "input must be a JSON object", "code": 0}));
        return ExitCode::from(1);
    };
    match run(cmd, &Input(obj.clone())) {
        Ok(fields) => {
            println!("{}", render(fields, abi));
            ExitCode::SUCCESS
        }
        Err(CliError(msg, code)) => {
            println!("{}", json!({"error": msg, "code": code}));
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(cmd: &str, j: Value) -> Value {
        let out = render(run(cmd, &Input(j.as_object().unwrap().clone())).unwrap(), false);
        serde_json::from_str(&out).unwrap()
    }

    #[test]
    fn commands_round_trip() {
        let r = call(
            "liquidation-lot",
            json!({"debt": "13500000000", "qty": "100000000000000000000",
                "sizingPrice": "153648000000000000000", "hfPrice": "158400000000000000000",
                "lt": "800000000000000000", "hStar": "1100000000000000000", "lambda": "30000000000000000"}),
        );
        assert!(r["x"].as_str().unwrap().starts_with("585131"));
        let r = call(
            "clear",
            json!({"qtys": [300, 300], "prices": [12440, 12411],
                "tieKeys": [format!("0x{}", "01".repeat(32)), format!("0x{}", "02".repeat(32))],
                "lot": 500, "reserve": 12222}),
        );
        assert_eq!(r["pStar"], "12411");
        assert_eq!(r["fills"], json!(["300", "200"]));
        let r = call(
            "kinked-rate",
            json!({"utilization": "850000000000000000", "r0": "20000000000000000",
                "s1": "60000000000000000", "s2": "800000000000000000", "uKink": "900000000000000000"}),
        );
        assert_eq!(r["rate"], "76666666666666666");
        let r = call(
            "safe-ltv",
            json!({"z": -5897, "sigma": "40000000000000000", "kappa": "30000000000000000",
                "maxLtv": "750000000000000000"}),
        );
        assert!(r["safeLtv"].as_str().unwrap().starts_with("7411"));
        assert_eq!(call("pack-z", json!({"set": [-1, 0, 1]}))["n"], "3");
        let r = call(
            "bell-status",
            json!({"collateralValue": 18000, "debtProjected": 13500, "safeLtv": "741182000000000000", "covered": false}),
        );
        assert_eq!(r["status"], "1");
        let r = call(
            "quote-cover",
            json!({"set": [-9000, -6000, -100, 0, 500], "sigma": "40000000000000000",
                "kappa": "30000000000000000", "collateralValue": "18000000000", "debtProjected": "13500000000",
                "closureDays": 3, "theta": "1000000000000000000", "costOfCap": "150000000000000000",
                "eta": "4000000000000000000", "beta": "975000000000000000"}),
        );
        assert!(r["premium"].as_str().unwrap().parse::<u128>().unwrap() > 0);
        let r = call(
            "pool-capacity",
            json!({"k": 2, "packedCurrent": ["0"], "packedAdd": ["5"],
                "uncovered": [], "kappa": "30000000000000000", "equity": 100, "uMax": "500000000000000000"}),
        );
        assert_eq!(r["ok"], true);
        assert_eq!(r["worstLoss"], "5");
        let r = call("value", json!({"qty": "100000000000000000000", "price": "180000000000000000000"}));
        assert_eq!(r["collateralValue"], "18000000000");
    }

    #[test]
    fn abi_encoding_layout() {
        let out = render(
            vec![("a", Out::U(U256::from(1u8))), ("v", Out::V(vec![U256::from(7u8)])), ("b", Out::B(true))],
            true,
        );
        let word = |k: usize| U256::from_str_radix(&out[2 + 64 * k..2 + 64 * (k + 1)], 16).unwrap();
        assert_eq!(word(0), U256::from(1u8));
        assert_eq!(word(1), U256::from(96u8)); // offset of v = 3 × 32
        assert_eq!(word(2), U256::from(1u8));
        assert_eq!(word(3), U256::from(1u8)); // length
        assert_eq!(word(4), U256::from(7u8));
    }

    #[test]
    fn errors_are_reported() {
        let inp = |j: Value| Input(j.as_object().unwrap().clone());
        let e = run("kinked-rate", &inp(json!({"utilization": 1, "r0": 0, "s1": 0, "s2": 0, "uKink": 0})));
        assert!(matches!(e, Err(CliError(_, 3))));
        assert!(run("nope", &inp(json!({}))).is_err());
        assert!(run("safe-ltv", &inp(json!({}))).is_err());
        assert!(matches!(run("quote-cover", &inp(json!({"set": [1, 0]}))), Err(CliError(_, 5))));
    }
}
