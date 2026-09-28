//! stylus-diff: native `credence-risk-core` vs the deployed Stylus Risk Engine, bit for bit (Build Guide §14.3).
//!
//! ```text
//! credence-risk-engine-diff --rpc http://127.0.0.1:8547 --n 10000 [--book deployments/<chainId>.local.json | --engine 0x…] \
//!     [--seed 42] [--gas]
//! ```
//! For every `IRiskEngine` math function (`safeLtv`, `bellStatus`, `quoteCover`, `coverLossVector`, `poolCapacity`,
//! `liquidationLot`, `precloseLot`, `clear`) it draws `n` random inputs inside the
//! §9.1 bounds (plus a share of out-of-domain inputs, so reverts are compared too), computes the native result,
//! `eth_call`s the engine, and requires identical outputs, including the revert payload
//! (`MathError(uint8)` / `UnknownSet(...)`). Every mismatch is written to
//! `crates/risk-core/tests/regressions/stylus-diff-<fn>.jsonl`. Exit status 1 on any mismatch.
//!
//! The engine is the `RiskEngineRouter` (R-24 split). Its `timelock` and `sigmaOracle` must be the key in
//! `PRIVATE_KEY`: params, sets, joint columns and σ are rewritten on-chain between batches, so run it against a
//! dedicated engine (`make stylus-diff` deploys one and records it in deployments/<chainId>.diff.local.json), never
//! the shared one. `--gas-check` fails if a call exceeds its §8.9.3 CI ceiling.

use alloy::{
    network::EthereumWallet,
    primitives::{Address, Bytes, FixedBytes, B256, U256},
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
    sol_types::{SolCall, SolError},
};
use anyhow::{anyhow, bail, Context, Result};
use credence_risk_core as rc;
use serde_json::json;
use std::{collections::BTreeMap, io::Write, sync::Arc};

mod bindings {
    #![allow(clippy::too_many_arguments)]
    alloy::sol! {
        #[sol(rpc)]
        interface IRiskEngine {
            struct RiskParams {
                uint64 alpha; uint64 kappa; uint64 theta; uint64 costOfCap; uint64 eta; uint64 beta; uint64 uMax;
                uint64 minPremium; uint32 kStress;
            }
            error Unauthorized();
            error NotSorted();
            error UnknownSet(bytes32 assetId, uint8 closureType);
            error MathError(uint8 code);
            function safeLtv(bytes32 assetId, uint8 closureType, uint256 maxLtv, uint256 dividend) external view returns (uint256);
            function liquidationLot(uint256 debt, uint256 qty, uint256 sizingPrice, uint256 hfPrice, uint256 lt,
                uint256 hStar, uint256 lambda, uint8 collDec, uint8 loanDec) external pure returns (uint256 x);
            function clear(uint256[] qtys, uint256[] prices, bytes32[] tieKeys, uint256 lot, uint256 reserve)
                external view returns (uint256 pStar, uint256[] fills, uint256 qPool);
            function precloseLot(uint256 debt, uint256 qty, uint256 valuation, uint256 reserve, uint256 targetLtv,
                uint256 lambdaPre, uint8 collDec, uint8 loanDec) external view returns (uint256 x);
            function bellStatus(bytes32 assetId, uint8 closureType, uint256 collateralValue, uint256 debtProjected,
                uint256 maxLtv, uint256 dividend, bool covered)
                external view returns (uint8 status, uint256 cureRepay, uint256 cureCollateralValue);
            function quoteCover(bytes32 assetId, uint8 closureType, uint16 closureDays, uint256 collateralValue,
                uint256 debtProjected, uint256 utilAfter)
                external view returns (uint256 premium, uint256 expectedLoss, uint256 expectedShortfall);
            function coverLossVector(bytes32 assetId, uint8 closureType, uint256 collateralValue, uint256 debtProjected)
                external view returns (uint256[] packed);
            function poolCapacity(uint256[] packedCurrent, uint256[] packedAdd, bytes32[] uncAssets,
                uint8[] uncClosureTypes, uint256[] uncCollateralValue, uint256[] uncSafeLtv, uint256 equity)
                external view returns (bool ok, uint256 utilAfter, uint256 worstLoss);
            function setJointColumn(bytes32 assetId, uint256[] packedZ) external;
            function setScenarioSet(bytes32 assetId, uint8 closureType, uint256[] packedSortedZ, uint32 n) external;
            function setParams(RiskParams p) external;
            function updateSigma(bytes32 assetId, uint8 closureType, uint256 sigma) external;
            function sigma(bytes32 assetId, uint8 closureType) external view returns (uint256);
        }
    }
}
use bindings::IRiskEngine;

const WAD: u128 = 1_000_000_000_000_000_000;

/// splitmix64: deterministic, dependency-free PRNG (reproducible from `--seed`).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u128) -> u128 {
        if n == 0 {
            return 0;
        }
        (((self.next() as u128) << 64) | self.next() as u128) % n
    }
    fn range(&mut self, lo: u128, hi: u128) -> u128 {
        lo + self.below(hi - lo + 1)
    }
    /// Log-uniform in [1, 10^max_exp]: exercises every magnitude.
    fn magnitude(&mut self, max_exp: u32) -> U256 {
        let e = self.below(max_exp as u128 + 1) as u32;
        let hi = U256::from(10u8).pow(U256::from(e));
        let x = U256::from(self.next()) * U256::from(self.next()) % hi;
        x.max(U256::from(1u8))
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.next() % 100 < pct
    }
    fn b256(&mut self) -> B256 {
        let mut b = [0u8; 32];
        for c in b.chunks_mut(8) {
            c.copy_from_slice(&self.next().to_be_bytes());
        }
        B256::from(b)
    }
}

/// On-chain outcome, normalised so it can be compared with the native one.
#[derive(Debug, PartialEq, Eq, Clone)]
enum Outcome {
    Ok(Vec<U256>),
    Revert(Bytes),
}

fn native_err(e: rc::MathError) -> Outcome {
    Outcome::Revert(
        IRiskEngine::MathError { code: e.code() }
            .abi_encode()
            .into(),
    )
}

/// The raw call result is decoded by the caller for its own return type.
enum Called {
    Ok(Bytes),
    Revert(Bytes),
}

async fn call_raw<P: Provider>(p: &P, to: Address, data: Vec<u8>) -> Result<Called> {
    let tx = alloy::rpc::types::TransactionRequest::default()
        .to(to)
        .input(data.into());
    match p.call(tx).await {
        Ok(out) => Ok(Called::Ok(out)),
        Err(e) => match e.as_error_resp().and_then(|r| r.as_revert_data()) {
            Some(rev) => Ok(Called::Revert(rev)),
            None => Err(anyhow!("rpc error: {e}")),
        },
    }
}

#[derive(Default)]
struct Tally {
    n: u64,
    mismatches: u64,
    reverts: u64,
}

struct Diff {
    tallies: BTreeMap<&'static str, Tally>,
    regressions: std::path::PathBuf,
}

impl Diff {
    fn record(
        &mut self,
        f: &'static str,
        input: serde_json::Value,
        native: &Outcome,
        chain: &Outcome,
    ) -> Result<()> {
        let t = self.tallies.entry(f).or_default();
        t.n += 1;
        if matches!(native, Outcome::Revert(_)) {
            t.reverts += 1;
        }
        if native != chain {
            t.mismatches += 1;
            std::fs::create_dir_all(&self.regressions)?;
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.regressions.join(format!("stylus-diff-{f}.jsonl")))?;
            writeln!(
                file,
                "{}",
                json!({"fn": f, "input": input, "native": format!("{native:?}"), "onchain": format!("{chain:?}")})
            )?;
        }
        Ok(())
    }
}

fn to_outcome_single(c: Called) -> Result<Outcome> {
    Ok(match c {
        Called::Ok(raw) => Outcome::Ok(vec![U256::from_be_slice(
            raw.get(..32).ok_or_else(|| anyhow!("short return"))?,
        )]),
        Called::Revert(r) => Outcome::Revert(r),
    })
}

// ───────────────────────────── liquidationLot ─────────────────────────────

struct LotIn {
    debt: U256,
    qty: U256,
    r: U256,
    p: U256,
    lt: U256,
    h: U256,
    lambda: U256,
    cd: u8,
    ld: u8,
}

fn gen_lot(g: &mut Rng) -> LotIn {
    let p = g.magnitude(24);
    let kappa = U256::from(g.range(0, WAD / 10));
    let mut i = LotIn {
        debt: g.magnitude(18),
        qty: g.magnitude(27),
        r: p * (U256::from(WAD) - kappa) / U256::from(WAD),
        p,
        lt: U256::from(g.range(WAD / 2, WAD * 95 / 100)),
        h: U256::from(g.range(WAD, WAD * 3 / 2)),
        lambda: U256::from(g.range(0, WAD / 10)),
        cd: g.range(0, 18) as u8,
        ld: g.range(0, 18) as u8,
    };
    if g.chance(3) {
        i.lambda = U256::from(WAD) + U256::from(g.range(1, WAD)); // out of domain → MathError(3)
    }
    if g.chance(2) {
        i.ld = 19 + g.range(0, 10) as u8; // loanDec > 18 → MathError(3)
    }
    i
}

async fn diff_lot<P: Provider>(
    p: &P,
    engine: Address,
    g: &mut Rng,
    n: u64,
    d: &mut Diff,
) -> Result<()> {
    for _ in 0..n {
        let i = gen_lot(g);
        let native =
            match rc::liquidation_lot(i.debt, i.qty, i.r, i.p, i.lt, i.h, i.lambda, i.cd, i.ld) {
                Ok(x) => Outcome::Ok(vec![x]),
                Err(e) => native_err(e),
            };
        let data = IRiskEngine::liquidationLotCall {
            debt: i.debt,
            qty: i.qty,
            sizingPrice: i.r,
            hfPrice: i.p,
            lt: i.lt,
            hStar: i.h,
            lambda: i.lambda,
            collDec: i.cd,
            loanDec: i.ld,
        }
        .abi_encode();
        let chain = to_outcome_single(call_raw(p, engine, data).await?)?;
        let input = json!({"debt": i.debt.to_string(), "qty": i.qty.to_string(), "sizingPrice": i.r.to_string(),
            "hfPrice": i.p.to_string(), "lt": i.lt.to_string(), "hStar": i.h.to_string(),
            "lambda": i.lambda.to_string(), "collDec": i.cd, "loanDec": i.ld});
        d.record("liquidationLot", input, &native, &chain)?;
    }
    Ok(())
}

// ───────────────────────────── precloseLot ─────────────────────────────

async fn diff_preclose<P: Provider>(
    p: &P,
    engine: Address,
    g: &mut Rng,
    n: u64,
    d: &mut Diff,
) -> Result<()> {
    for _ in 0..n {
        let v = g.magnitude(24);
        let kappa = U256::from(g.range(0, WAD / 10));
        let reserve = v * (U256::from(WAD) - kappa) / U256::from(WAD);
        let mut target = U256::from(g.range(0, WAD * 9 / 10));
        let mut lambda = U256::from(g.range(0, WAD / 10));
        let (debt, qty) = (g.magnitude(18), g.magnitude(27));
        let (cd, mut ld) = (g.range(0, 18) as u8, g.range(0, 18) as u8);
        if g.chance(3) {
            lambda = U256::from(WAD) + U256::from(g.range(1, WAD));
        }
        if g.chance(2) {
            target = U256::from(WAD) + U256::from(1u8);
        }
        if g.chance(2) {
            ld = 19 + g.range(0, 10) as u8;
        }
        let native = match rc::preclose_lot(debt, qty, v, reserve, target, lambda, cd, ld) {
            Ok(x) => Outcome::Ok(vec![x]),
            Err(e) => native_err(e),
        };
        let data = IRiskEngine::precloseLotCall {
            debt,
            qty,
            valuation: v,
            reserve,
            targetLtv: target,
            lambdaPre: lambda,
            collDec: cd,
            loanDec: ld,
        }
        .abi_encode();
        let chain = to_outcome_single(call_raw(p, engine, data).await?)?;
        let input = json!({"debt": debt.to_string(), "qty": qty.to_string(), "valuation": v.to_string(),
            "reserve": reserve.to_string(), "targetLtv": target.to_string(), "lambdaPre": lambda.to_string(),
            "collDec": cd, "loanDec": ld});
        d.record("precloseLot", input, &native, &chain)?;
    }
    Ok(())
}

// ───────────────────────────── clear ─────────────────────────────

async fn diff_clear<P: Provider>(
    p: &P,
    engine: Address,
    g: &mut Rng,
    n: u64,
    d: &mut Diff,
) -> Result<()> {
    for _ in 0..n {
        let bids = g.below(65) as usize;
        // a small price ladder makes ties at the marginal price common (R-05)
        let ladder: Vec<U256> = (0..g.range(1, 8)).map(|_| g.magnitude(24)).collect();
        let mut qtys = Vec::with_capacity(bids);
        let mut prices = Vec::with_capacity(bids);
        let mut keys = Vec::with_capacity(bids);
        for _ in 0..bids {
            qtys.push(if g.chance(5) {
                U256::ZERO
            } else {
                g.magnitude(24)
            });
            prices.push(ladder[g.below(ladder.len() as u128) as usize]);
            keys.push(if g.chance(10) && !keys.is_empty() {
                keys[0]
            } else {
                g.b256()
            });
        }
        if g.chance(2) && !qtys.is_empty() {
            prices.pop(); // length mismatch → MathError(3)
        }
        let lot = g.magnitude(25);
        let reserve = ladder[g.below(ladder.len() as u128) as usize] * U256::from(g.range(50, 100))
            / U256::from(100u8);
        let native = match rc::clear(&qtys, &prices, &keys, lot, reserve) {
            Ok(r) => {
                let mut v = vec![r.p_star, r.q_pool];
                v.extend(r.fills);
                Outcome::Ok(v)
            }
            Err(e) => native_err(e),
        };
        let data = IRiskEngine::clearCall {
            qtys: qtys.clone(),
            prices: prices.clone(),
            tieKeys: keys.clone(),
            lot,
            reserve,
        }
        .abi_encode();
        let chain = match call_raw(p, engine, data).await? {
            Called::Ok(raw) => {
                let r = IRiskEngine::clearCall::abi_decode_returns(&raw).context("decode clear")?;
                let mut v = vec![r.pStar, r.qPool];
                v.extend(r.fills);
                Outcome::Ok(v)
            }
            Called::Revert(r) => Outcome::Revert(r),
        };
        let input = json!({"qtys": qtys.iter().map(|x| x.to_string()).collect::<Vec<_>>(),
            "prices": prices.iter().map(|x| x.to_string()).collect::<Vec<_>>(),
            "tieKeys": keys.iter().map(|k| k.to_string()).collect::<Vec<_>>(),
            "lot": lot.to_string(), "reserve": reserve.to_string()});
        d.record("clear", input, &native, &chain)?;
    }
    Ok(())
}

// ───────────────────────────── safeLtv ─────────────────────────────

async fn send<P: Provider>(p: &P, engine: Address, data: Vec<u8>) -> Result<()> {
    let tx = alloy::rpc::types::TransactionRequest::default()
        .to(engine)
        .input(data.into());
    let receipt = p.send_transaction(tx).await?.get_receipt().await?;
    if !receipt.status() {
        bail!("setup tx reverted: {:?}", receipt.transaction_hash);
    }
    Ok(())
}

/// One batch = random params, one asset with a sorted set + σ + joint column, a second asset with a joint column
/// + σ; then `per` random cases of each closure function against those.
async fn diff_closure<P: Provider>(
    p: &P,
    engine: Address,
    g: &mut Rng,
    n: u64,
    d: &mut Diff,
) -> Result<()> {
    let batches = 20u64;
    let per = n.div_ceil(batches);
    let mut done = 0u64;
    for b in 0..batches {
        let asset = g.b256();
        let asset_b = g.b256();
        let closure_type = g.range(1, 5) as u8;
        let len = g.range(1, 2000) as usize;
        let mut set: Vec<i16> = (0..len)
            .map(|_| (g.next() as i64 % 12_000 - 9_000) as i16)
            .collect();
        set.sort();
        let alpha = [WAD / 1000, WAD / 400, WAD / 100, WAD / 20, WAD][b as usize % 5];
        let kappa = g.range(0, WAD / 10);
        let u_max = g.range(WAD / 10, WAD);
        let params = IRiskEngine::RiskParams {
            alpha: alpha as u64,
            kappa: kappa as u64,
            theta: g.range(0, 2 * WAD) as u64,
            costOfCap: g.range(0, WAD / 2) as u64,
            eta: g.range(0, 8 * WAD) as u64,
            beta: g.range(WAD * 9 / 10, WAD) as u64,
            uMax: u_max as u64,
            minPremium: g.range(0, 2_000_000) as u64,
            kStress: 256,
        };
        send(
            p,
            engine,
            IRiskEngine::setParamsCall { p: params.clone() }.abi_encode(),
        )
        .await?;
        send(
            p,
            engine,
            IRiskEngine::setScenarioSetCall {
                assetId: asset,
                closureType: closure_type,
                packedSortedZ: rc::fixed::pack_i16(&set),
                n: len as u32,
            }
            .abi_encode(),
        )
        .await?;
        let joint_a: Vec<i16> = (0..256)
            .map(|_| (g.next() as i64 % 14_000 - 10_000) as i16)
            .collect();
        let joint_b: Vec<i16> = (0..256)
            .map(|_| (g.next() as i64 % 14_000 - 10_000) as i16)
            .collect();
        for (a, j) in [(asset, &joint_a), (asset_b, &joint_b)] {
            send(
                p,
                engine,
                IRiskEngine::setJointColumnCall {
                    assetId: a,
                    packedZ: rc::fixed::pack_i16(j),
                }
                .abi_encode(),
            )
            .await?;
        }
        let sigma = U256::from(g.range(WAD / 1000, WAD / 4));
        let sigma_b = U256::from(g.range(WAD / 1000, WAD / 4));
        for (a, s) in [(asset, sigma), (asset_b, sigma_b)] {
            send(
                p,
                engine,
                IRiskEngine::updateSigmaCall {
                    assetId: a,
                    closureType: closure_type,
                    sigma: s,
                }
                .abi_encode(),
            )
            .await?;
        }
        let z = set[rc::quantile_index(len as u32, U256::from(alpha))
            .map_err(|e| anyhow!("{e:?}"))? as usize];
        let (w, kap) = (|x: u64| U256::from(x), U256::from(kappa));
        let unknown_err = |qa: B256, qt: u8| {
            Outcome::Revert(
                IRiskEngine::UnknownSet {
                    assetId: qa,
                    closureType: qt,
                }
                .abi_encode()
                .into(),
            )
        };

        for _ in 0..per.min(n - done) {
            let max_ltv = U256::from(g.range(0, WAD));
            let dividend = if g.chance(30) {
                U256::from(g.range(0, WAD / 20))
            } else {
                U256::ZERO
            };
            let unknown = g.chance(3);
            let qa = if unknown { g.b256() } else { asset };
            let c = g.magnitude(15);
            let debt = c * U256::from(g.range(0, WAD * 12 / 10)) / U256::from(WAD);
            let base = json!({"assetId": qa.to_string(), "closureType": closure_type, "sigma": sigma.to_string(),
                "alpha": alpha.to_string(), "kappa": kappa.to_string(), "setLen": len, "z": z,
                "collateralValue": c.to_string(), "debtProjected": debt.to_string()});

            // safeLtv
            let safe = rc::safe_ltv(z, sigma, dividend, kap, max_ltv);
            let native = if unknown {
                unknown_err(qa, closure_type)
            } else {
                match safe {
                    Ok(x) => Outcome::Ok(vec![x]),
                    Err(e) => native_err(e),
                }
            };
            let chain = to_outcome_single(
                call_raw(
                    p,
                    engine,
                    IRiskEngine::safeLtvCall {
                        assetId: qa,
                        closureType: closure_type,
                        maxLtv: max_ltv,
                        dividend,
                    }
                    .abi_encode(),
                )
                .await?,
            )?;
            let mut input = base.clone();
            input["maxLtv"] = json!(max_ltv.to_string());
            input["dividend"] = json!(dividend.to_string());
            d.record("safeLtv", input.clone(), &native, &chain)?;

            // bellStatus
            let covered = g.chance(10);
            let native = if unknown {
                unknown_err(qa, closure_type)
            } else {
                match safe.and_then(|s| rc::bell_status(c, debt, s, covered)) {
                    Ok(r) => Outcome::Ok(vec![
                        U256::from(r.status),
                        r.cure_repay,
                        r.cure_collateral_value,
                    ]),
                    Err(e) => native_err(e),
                }
            };
            let chain = match call_raw(
                p,
                engine,
                IRiskEngine::bellStatusCall {
                    assetId: qa,
                    closureType: closure_type,
                    collateralValue: c,
                    debtProjected: debt,
                    maxLtv: max_ltv,
                    dividend,
                    covered,
                }
                .abi_encode(),
            )
            .await?
            {
                Called::Ok(raw) => {
                    let r = IRiskEngine::bellStatusCall::abi_decode_returns(&raw)
                        .context("decode bellStatus")?;
                    Outcome::Ok(vec![
                        U256::from(r.status),
                        r.cureRepay,
                        r.cureCollateralValue,
                    ])
                }
                Called::Revert(r) => Outcome::Revert(r),
            };
            input["covered"] = json!(covered);
            d.record("bellStatus", input, &native, &chain)?;

            // quoteCover
            let days = g.range(1, 5) as u16;
            let util = U256::from(g.range(0, WAD));
            let native = if unknown {
                unknown_err(qa, closure_type)
            } else {
                match rc::quote_cover(
                    &rc::SliceZ(&set),
                    &rc::PremiumParams {
                        sigma,
                        dividend: U256::ZERO,
                        kappa: kap,
                        collateral_value: c,
                        debt_projected: debt,
                        closure_days: days,
                        util_after: util,
                        theta: w(params.theta),
                        cost_of_cap: w(params.costOfCap),
                        eta: w(params.eta),
                        beta: w(params.beta),
                        min_premium: w(params.minPremium),
                    },
                ) {
                    Ok(q) => Outcome::Ok(vec![q.premium, q.expected_loss, q.expected_shortfall]),
                    Err(e) => native_err(e),
                }
            };
            let chain = match call_raw(
                p,
                engine,
                IRiskEngine::quoteCoverCall {
                    assetId: qa,
                    closureType: closure_type,
                    closureDays: days,
                    collateralValue: c,
                    debtProjected: debt,
                    utilAfter: util,
                }
                .abi_encode(),
            )
            .await?
            {
                Called::Ok(raw) => {
                    let r = IRiskEngine::quoteCoverCall::abi_decode_returns(&raw)
                        .context("decode quoteCover")?;
                    Outcome::Ok(vec![r.premium, r.expectedLoss, r.expectedShortfall])
                }
                Called::Revert(r) => Outcome::Revert(r),
            };
            let mut qi = base.clone();
            qi["closureDays"] = json!(days);
            qi["utilAfter"] = json!(util.to_string());
            d.record("quoteCover", qi, &native, &chain)?;

            // coverLossVector (asset A's joint column, σ of (A, type))
            let native =
                match rc::loss_vector(&rc::SliceZ(&joint_a), c, debt, sigma, U256::ZERO, kap) {
                    Ok(lv) => Outcome::Ok(rc::fixed::pack_u64(&lv)),
                    Err(e) => native_err(e),
                };
            let chain = match call_raw(
                p,
                engine,
                IRiskEngine::coverLossVectorCall {
                    assetId: asset,
                    closureType: closure_type,
                    collateralValue: c,
                    debtProjected: debt,
                }
                .abi_encode(),
            )
            .await?
            {
                Called::Ok(raw) => Outcome::Ok(
                    IRiskEngine::coverLossVectorCall::abi_decode_returns(&raw)
                        .context("decode lossVector")?,
                ),
                Called::Revert(r) => Outcome::Revert(r),
            };
            let mut li = base.clone();
            li["assetId"] = json!(asset.to_string());
            d.record("coverLossVector", li, &native, &chain)?;

            // poolCapacity (random current / added vectors, 0–2 uncovered markets)
            let cur: Vec<u64> = (0..256).map(|_| g.next() % 1_000_000_000_000).collect();
            let add: Vec<u64> = (0..256).map(|_| g.next() % 100_000_000_000).collect();
            let (pc, pa) = (rc::fixed::pack_u64(&cur), rc::fixed::pack_u64(&add));
            let m = g.below(3) as usize;
            let unc_assets: Vec<B256> = [asset, asset_b][..m].to_vec();
            let unc_c: Vec<U256> = (0..m).map(|_| g.magnitude(15)).collect();
            let unc_s: Vec<U256> = (0..m).map(|_| U256::from(g.range(0, WAD))).collect();
            let equity = if g.chance(3) {
                U256::ZERO
            } else {
                g.magnitude(15)
            };
            let joints = [&joint_a, &joint_b];
            let sigmas = [sigma, sigma_b];
            let slices: Vec<rc::SliceZ<'_>> = (0..m).map(|i| rc::SliceZ(joints[i])).collect();
            let unc: Vec<rc::UncoveredMarket<'_, rc::SliceZ<'_>>> = (0..m)
                .map(|i| rc::UncoveredMarket {
                    joint: &slices[i],
                    sigma: sigmas[i],
                    dividend: U256::ZERO,
                    collateral_value: unc_c[i],
                    safe_ltv: unc_s[i],
                })
                .collect();
            let native =
                match rc::pool_capacity(&pc, &pa, 256, &unc, kap, equity, U256::from(u_max)) {
                    Ok(r) => Outcome::Ok(vec![U256::from(r.ok as u8), r.util_after, r.worst_loss]),
                    Err(e) => native_err(e),
                };
            let chain = match call_raw(
                p,
                engine,
                IRiskEngine::poolCapacityCall {
                    packedCurrent: pc,
                    packedAdd: pa,
                    uncAssets: unc_assets.clone(),
                    uncClosureTypes: vec![closure_type; m],
                    uncCollateralValue: unc_c.clone(),
                    uncSafeLtv: unc_s.clone(),
                    equity,
                }
                .abi_encode(),
            )
            .await?
            {
                Called::Ok(raw) => {
                    let r = IRiskEngine::poolCapacityCall::abi_decode_returns(&raw)
                        .context("decode capacity")?;
                    Outcome::Ok(vec![U256::from(r.ok as u8), r.utilAfter, r.worstLoss])
                }
                Called::Revert(r) => Outcome::Revert(r),
            };
            let ci = json!({"uncAssets": unc_assets.iter().map(|x| x.to_string()).collect::<Vec<_>>(),
                "uncCollateralValue": unc_c.iter().map(|x| x.to_string()).collect::<Vec<_>>(),
                "uncSafeLtv": unc_s.iter().map(|x| x.to_string()).collect::<Vec<_>>(),
                "equity": equity.to_string(), "kappa": kappa.to_string(), "uMax": u_max.to_string(),
                "current0": cur[0], "add0": add[0]});
            d.record("poolCapacity", ci, &native, &chain)?;
            done += 1;
        }
    }
    Ok(())
}

// ───────────────────────────── gas ─────────────────────────────

async fn gas_report<P: Provider>(p: &P, engine: Address, g: &mut Rng) -> Result<serde_json::Value> {
    let est = |data: Vec<u8>| {
        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(engine)
            .input(data.into());
        async move {
            p.estimate_gas(tx)
                .await
                .map_err(|e| anyhow!("estimate: {e}"))
        }
    };
    // safeLtv on a 3,000-scenario set
    let asset: B256 = FixedBytes::repeat_byte(0x5a);
    let mut set: Vec<i16> = (0..3000)
        .map(|_| (g.next() as i64 % 12_000 - 9_000) as i16)
        .collect();
    set.sort();
    send(
        p,
        engine,
        IRiskEngine::setParamsCall {
            p: IRiskEngine::RiskParams {
                alpha: (WAD / 1000) as u64,
                kappa: (WAD * 3 / 100) as u64,
                theta: WAD as u64,
                costOfCap: (WAD * 15 / 100) as u64,
                eta: (4 * WAD) as u64,
                beta: (WAD * 975 / 1000) as u64,
                uMax: (WAD / 2) as u64,
                minPremium: 500_000,
                kStress: 256,
            },
        }
        .abi_encode(),
    )
    .await?;
    send(
        p,
        engine,
        IRiskEngine::setScenarioSetCall {
            assetId: asset,
            closureType: 2,
            packedSortedZ: rc::fixed::pack_i16(&set),
            n: 3000,
        }
        .abi_encode(),
    )
    .await?;
    send(
        p,
        engine,
        IRiskEngine::updateSigmaCall {
            assetId: asset,
            closureType: 2,
            sigma: U256::from(WAD * 4 / 100),
        }
        .abi_encode(),
    )
    .await?;
    let safe = est(IRiskEngine::safeLtvCall {
        assetId: asset,
        closureType: 2,
        maxLtv: U256::from(WAD * 3 / 4),
        dividend: U256::ZERO,
    }
    .abi_encode())
    .await?;
    let wad = |x: &str| U256::from_str_radix(x, 10).unwrap();
    let lot = est(IRiskEngine::liquidationLotCall {
        debt: U256::from(13_500_000_000u64),
        qty: wad("100000000000000000000"),
        sizingPrice: wad("153648000000000000000"),
        hfPrice: wad("158400000000000000000"),
        lt: wad("800000000000000000"),
        hStar: wad("1100000000000000000"),
        lambda: wad("30000000000000000"),
        collDec: 18,
        loanDec: 6,
    }
    .abi_encode())
    .await?;
    let mut clear64 = Vec::new();
    for _ in 0..64 {
        clear64.push((
            g.magnitude(21),
            U256::from(g.range(100, 130)) * U256::from(WAD),
            g.b256(),
        ));
    }
    let clear = est(IRiskEngine::clearCall {
        qtys: clear64.iter().map(|b| b.0).collect(),
        prices: clear64.iter().map(|b| b.1).collect(),
        tieKeys: clear64.iter().map(|b| b.2).collect(),
        lot: clear64.iter().map(|b| b.0).fold(U256::ZERO, |a, b| a + b) / U256::from(2u8),
        reserve: U256::from(100u8) * U256::from(WAD),
    }
    .abi_encode())
    .await?;
    Ok(json!({
        "note": "eth_estimateGas of one call on the devnode (L1 price 0); includes the 21,000 intrinsic gas and calldata.",
        "safeLtv_N3000": safe, "liquidationLot": lot, "clear_64bids": clear
    }))
}

// ───────────────────────────── main ─────────────────────────────

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let rpc = arg(&args, "--rpc").unwrap_or_else(|| "http://127.0.0.1:8547".into());
    let n: u64 = arg(&args, "--n")
        .unwrap_or_else(|| "10000".into())
        .parse()?;
    let seed: u64 = arg(&args, "--seed")
        .unwrap_or_else(|| "20260927".into())
        .parse()?;
    let key = std::env::var("PRIVATE_KEY")
        .context("PRIVATE_KEY (the engine's timelock / sigma oracle)")?;
    let signer: PrivateKeySigner = key.parse()?;
    let provider = Arc::new(
        ProviderBuilder::new()
            .wallet(EthereumWallet::from(signer))
            .connect_http(rpc.parse()?),
    );
    // The engine comes from THE local address book (charter §2a, ADR-0105): `--engine` overrides,
    // else `.shared.riskEngine` of `--book` (default deployments/<chainId>.local.json).
    let engine: Address = match arg(&args, "--engine") {
        Some(a) => a.parse()?,
        None => {
            let chain_id = provider.get_chain_id().await?;
            let book = arg(&args, "--book")
                .unwrap_or_else(|| format!("deployments/{chain_id}.local.json"));
            let v: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(&book).with_context(|| format!("read {book}"))?,
            )?;
            v.pointer("/shared/riskEngine")
                .and_then(|x| x.as_str())
                .ok_or_else(|| {
                    anyhow!("no .shared.riskEngine in {book}: run make devnode-deploy-engine")
                })?
                .parse()?
        }
    };

    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut d = Diff {
        tallies: BTreeMap::new(),
        regressions: root.join("crates/risk-core/tests/regressions"),
    };
    let mut g = Rng(seed);
    let t0 = std::time::Instant::now();
    diff_lot(&*provider, engine, &mut g, n, &mut d).await?;
    diff_clear(&*provider, engine, &mut g, n, &mut d).await?;
    diff_preclose(&*provider, engine, &mut g, n, &mut d).await?;
    diff_closure(&*provider, engine, &mut g, n, &mut d).await?;
    let gas = if args.iter().any(|a| a == "--gas") {
        Some(gas_report(&*provider, engine, &mut g).await?)
    } else {
        None
    };

    let total_mismatch: u64 = d.tallies.values().map(|t| t.mismatches).sum();
    let summary = json!({
        "engine": engine.to_string(),
        "seed": seed,
        "seconds": t0.elapsed().as_secs_f64(),
        "functions": d.tallies.iter().map(|(k, t)| (k.to_string(), json!({
            "cases": t.n, "revertCases": t.reverts, "mismatches": t.mismatches}))).collect::<serde_json::Map<_, _>>(),
        "mismatches": total_mismatch,
        "gas": gas,
    });
    println!("{}", serde_json::to_string_pretty(&summary)?);
    if total_mismatch > 0 {
        std::process::exit(1);
    }
    Ok(())
}
