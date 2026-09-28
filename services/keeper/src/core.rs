//! The lending core as the keeper sees it (S2): market, vault, engine, clock, oracle and pool views,
//! read at one block, and the Bell computed natively with risk-core exactly like
//! `CredenceMarket.bellStatus` (CoverLogic.bellStatusView).
//!
//! Bindings come from the frozen interface ABIs in `deployments/abis/v1` (the same JSON
//! `credence-bindings` is generated from), so switching to that crate changes imports, not logic.

use std::{collections::HashMap, path::Path};

use alloy::{
    eips::BlockId,
    primitives::{Address, B256, U256},
    providers::DynProvider,
};
use anyhow::{Context, Result};
use credence_risk_core::{
    self as rc,
    fixed::{collateral_value, health_factor_down, ltv_up, mul_div_up},
    PackedZ, PremiumParams, WAD,
};

pub mod abi {
    #![allow(missing_docs, clippy::too_many_arguments)]
    use alloy::sol;
    sol!(
        #[sol(rpc)]
        ICredenceMarket,
        "../../deployments/abis/v1/ICredenceMarket.json"
    );
    sol!(
        #[sol(rpc)]
        ISeniorVault,
        "../../deployments/abis/v1/ISeniorVault.json"
    );
    sol!(
        #[sol(rpc)]
        IRiskEngine,
        "../../deployments/abis/v1/IRiskEngine.json"
    );
    sol!(
        #[sol(rpc)]
        IAssetClockV1,
        "../../deployments/abis/v1/IAssetClock.json"
    );
    sol!(
        #[sol(rpc)]
        IOracleAdapter,
        "../../deployments/abis/v1/IOracleAdapter.json"
    );
    sol!(
        #[sol(rpc)]
        IUnderwriterPool,
        "../../deployments/abis/v1/IUnderwriterPool.json"
    );
    sol!(
        #[sol(rpc)]
        ISigmaOracle,
        "../../deployments/abis/v1/ISigmaOracle.json"
    );
    sol!(
        #[sol(rpc)]
        ComplianceRegistry,
        "../../deployments/abis/v1/ComplianceRegistry.json"
    );
    sol! {
        #[sol(rpc)]
        interface IERC20Decimals {
            function decimals() external view returns (uint8);
        }
    }
}

use abi::{
    IAssetClockV1, ICredenceMarket, IERC20Decimals, IOracleAdapter, IRiskEngine, IUnderwriterPool,
};

/// MarketLib constants (R-03, R-07).
pub const DELTA_COVER: u128 = 5_000_000_000_000_000; // 0.005e18
pub const COVER_LT_GAP: u128 = 20_000_000_000_000_000; // 0.02e18
pub const FALLBACK_CLOSURE_DAYS: u64 = 4;
/// ClockState codes (Types.sol).
pub const REGULAR: u8 = 0;
pub const EXTENDED: u8 = 1;
/// BellStatus codes.
pub const SAFE: u8 = 0;
pub const NEEDS_ACTION: u8 = 1;
pub const COVERED: u8 = 2;
/// BellOutcome codes (Types.sol) for the J3 dry-run.
pub const AUTO_COVERED: u8 = 2;
pub const PRECLOSE_THEN_COVER: u8 = 3;
pub const PRECLOSE_SALE: u8 = 4;

#[derive(Clone, Debug)]
pub struct RiskParams {
    pub alpha: U256,
    pub kappa: U256,
    pub theta: U256,
    pub cost_of_cap: U256,
    pub eta: U256,
    pub beta: U256,
    pub u_max: U256,
    pub min_premium: U256,
}

/// Everything closure-related the market reads for one market at one block.
#[derive(Clone, Debug)]
pub struct RiskCtx {
    pub block: u64,
    pub timestamp: u64,
    pub market: Address,
    pub market_id: B256,
    pub asset_id: B256,
    pub clock_state: u8,
    pub closure_type: u8,
    pub close_at: u64,
    pub reopen_at: u64,
    pub closure_days: u64,
    pub bell_at: u64,
    pub upcoming_closure_id: u64,
    pub epoch_id: u64,
    pub max_ltv_eff: U256,
    pub lt: U256,
    pub preclose_kappa: U256,
    pub preclose_lambda: U256,
    pub cover_paused: bool,
    pub sigma: U256,
    pub params: RiskParams,
    pub scenario_hash: B256,
    pub valuation_price: U256,
    pub coll_dec: u8,
    pub loan_dec: u8,
    pub pool: Address,
    pub pending_fees: bool,
}

#[derive(Clone, Debug)]
pub struct PositionSnap {
    pub owner: Address,
    pub collateral: U256,
    pub debt_projected: U256,
    pub collateral_value: U256,
    pub covered: bool,
    pub auction_id: u64,
    pub auto_cover_opt_out: bool,
    pub last_bell_closure_id: u64,
}

/// The Bell for one position, as the market's view reports it (cure collateral in token units).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bell {
    pub status: u8,
    pub safe_ltv: U256,
    pub ltv: U256,
    pub cure_repay: U256,
    pub cure_collateral_value: U256,
    pub cure_collateral: U256,
}

/// MarketLib.maxLtvEff.
pub fn max_ltv_eff(max_ltv: U256, now: u64, own: (U256, u64), global: (U256, u64)) -> U256 {
    let mut cut = U256::ZERO;
    if own.1 > now {
        cut = own.0;
    }
    if global.1 > now && global.0 > cut {
        cut = global.0;
    }
    max_ltv.saturating_sub(cut)
}

/// CoverLogic.bellStatusView for one position given the engine's set.
pub fn bell(ctx: &RiskCtx, p: &PositionSnap, set: &PackedZ<'_>) -> Result<Bell> {
    let safe = rc::safe_ltv_from_set(
        set,
        ctx.params.alpha,
        ctx.sigma,
        U256::ZERO,
        ctx.params.kappa,
        ctx.max_ltv_eff,
    )
    .map_err(|e| anyhow::anyhow!("safe_ltv: {e:?}"))?;
    let ltv = ltv_up(p.debt_projected, p.collateral_value).unwrap_or(U256::MAX);
    if p.covered {
        return Ok(Bell {
            status: COVERED,
            safe_ltv: safe,
            ltv,
            cure_repay: U256::ZERO,
            cure_collateral_value: U256::ZERO,
            cure_collateral: U256::ZERO,
        });
    }
    if p.debt_projected.is_zero() {
        return Ok(Bell {
            status: SAFE,
            safe_ltv: safe,
            ltv,
            cure_repay: U256::ZERO,
            cure_collateral_value: U256::ZERO,
            cure_collateral: U256::ZERO,
        });
    }
    let r = rc::bell_status(p.collateral_value, p.debt_projected, safe, false)
        .map_err(|e| anyhow::anyhow!("bell_status: {e:?}"))?;
    if r.status != NEEDS_ACTION {
        return Ok(Bell {
            status: r.status,
            safe_ltv: safe,
            ltv,
            cure_repay: U256::ZERO,
            cure_collateral_value: U256::ZERO,
            cure_collateral: U256::ZERO,
        });
    }
    let cure_collateral = if r.cure_collateral_value == U256::MAX {
        U256::MAX
    } else {
        let num = U256::from(10u64).pow(U256::from(ctx.coll_dec)) * U256::from(WAD);
        let den = ctx.valuation_price * U256::from(10u64).pow(U256::from(ctx.loan_dec));
        mul_div_up(r.cure_collateral_value, num, den).map_err(|e| anyhow::anyhow!("{e:?}"))?
    };
    Ok(Bell {
        status: NEEDS_ACTION,
        safe_ltv: safe,
        ltv,
        cure_repay: r.cure_repay,
        cure_collateral_value: r.cure_collateral_value,
        cure_collateral,
    })
}

/// The Gap Cover premium the pool would charge (engine.quoteCover with the pool's uAfter).
pub fn premium(
    ctx: &RiskCtx,
    p: &PositionSnap,
    set: &PackedZ<'_>,
    util_after: U256,
) -> Result<U256> {
    let q = rc::quote_cover(
        set,
        &PremiumParams {
            sigma: ctx.sigma,
            dividend: U256::ZERO,
            kappa: ctx.params.kappa,
            collateral_value: p.collateral_value,
            debt_projected: p.debt_projected,
            closure_days: ctx.closure_days as u16,
            util_after,
            theta: ctx.params.theta,
            cost_of_cap: ctx.params.cost_of_cap,
            eta: ctx.params.eta,
            beta: ctx.params.beta,
            min_premium: ctx.params.min_premium,
        },
    )
    .map_err(|e| anyhow::anyhow!("quote_cover: {e:?}"))?;
    Ok(q.premium)
}

/// CoverLogic._cure's branch for a NEEDS_ACTION borrower (the J3 dry-run's expected outcome).
/// `ltv_now` is debt / value at the current price (not projected), as the market computes it.
pub fn expected_outcome(ctx: &RiskCtx, p: &PositionSnap, ltv_now: U256) -> u8 {
    let cover_on = !p.auto_cover_opt_out && !ctx.cover_paused;
    let coverable = (ctx.max_ltv_eff + U256::from(DELTA_COVER))
        .min(ctx.lt.saturating_sub(U256::from(COVER_LT_GAP)));
    if cover_on && ltv_now <= coverable {
        AUTO_COVERED
    } else if cover_on {
        PRECLOSE_THEN_COVER
    } else {
        PRECLOSE_SALE
    }
}

/// The pre-close sale the Bell would queue down to `target` (LiquidationLogic: sized at the reserve
/// V × (1 − κ_preclose), capped at the collateral), at today's valuation price.
pub fn preclose_qty(ctx: &RiskCtx, p: &PositionSnap, target: U256) -> Result<U256> {
    if ltv_up(p.debt_projected, p.collateral_value).unwrap_or(U256::MAX) <= target {
        return Ok(U256::ZERO);
    }
    let reserve =
        rc::fixed::mul_wad_down(ctx.valuation_price, U256::from(WAD) - ctx.preclose_kappa)
            .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let x = rc::preclose_lot(
        p.debt_projected,
        p.collateral,
        ctx.valuation_price,
        reserve,
        target,
        ctx.preclose_lambda,
        ctx.coll_dec,
        ctx.loan_dec,
    )
    .map_err(|e| anyhow::anyhow!("preclose_lot: {e:?}"))?;
    Ok(x.min(p.collateral))
}

/// Health factor at the valuation price with the (unprojected) debt, WAD.
pub fn health(ctx: &RiskCtx, collateral: U256, debt: U256) -> U256 {
    match collateral_value(collateral, ctx.valuation_price, ctx.coll_dec, ctx.loan_dec) {
        Ok(c) => health_factor_down(c, ctx.lt, debt).unwrap_or(U256::MAX),
        Err(_) => U256::MAX,
    }
}

/// Scenario sets from ADR-0106 files, by on-chain `scenarioHash`.
#[derive(Default)]
pub struct SetStore {
    sets: HashMap<B256, (u32, Vec<U256>)>,
}

impl SetStore {
    pub fn load(dirs: &[impl AsRef<Path>]) -> Result<Self> {
        let mut s = Self::default();
        for d in dirs {
            let Ok(rd) = std::fs::read_dir(d.as_ref()) else {
                tracing::warn!(dir = %d.as_ref().display(), "scenario-set directory not found");
                continue;
            };
            for e in rd.flatten() {
                let path = e.path();
                if path.extension().is_none_or(|x| x != "json") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&path) else {
                    continue;
                };
                if !text.contains("\"credence.scenario-set/v1\"") {
                    continue;
                }
                let v: serde_json::Value =
                    serde_json::from_str(&text).with_context(|| path.display().to_string())?;
                match rc::setfile::parse_set(&v) {
                    Ok(set) => {
                        s.sets
                            .insert(set.scenario_hash, (set.z.len() as u32, set.packed));
                    }
                    Err(e) => {
                        tracing::warn!(path = %path.display(), error = ?e, "invalid scenario set skipped")
                    }
                }
            }
        }
        tracing::info!(sets = s.sets.len(), "scenario sets loaded");
        Ok(s)
    }

    pub fn get(&self, scenario_hash: &B256) -> Option<PackedZ<'_>> {
        self.sets
            .get(scenario_hash)
            .and_then(|(n, w)| PackedZ::new(w, *n).ok())
    }

    pub fn len(&self) -> usize {
        self.sets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.sets.is_empty()
    }
}

/// Read one market's risk context at `block` (latest if None).
pub async fn read_ctx(
    p: &DynProvider,
    market: Address,
    id: B256,
    block: Option<u64>,
) -> Result<RiskCtx> {
    use alloy::providers::Provider;
    let blk = match block {
        Some(b) => p.get_block_by_number(b.into()).await?,
        None => {
            p.get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
                .await?
        }
    }
    .context("block")?;
    let at = BlockId::number(blk.header.number);
    let now = blk.header.timestamp;
    let m = ICredenceMarket::new(market, p);
    let params = m.marketParams(id).block(at).call().await?;
    let w = m.wiring().block(at).call().await?;
    let st = m.marketState(id).block(at).call().await?;
    let own = m.overlay(id).block(at).call().await?;
    let glob = m.overlay(B256::ZERO).block(at).call().await?;
    let asset = params.assetId;
    let clock = IAssetClockV1::new(w.clock, p);
    let window = clock.closureWindow(asset).block(at).call().await?;
    let info = clock.closureInfo(asset).block(at).call().await?;
    let days = clock
        .closureDays(asset)
        .block(at)
        .call()
        .await
        .map(|d| d.to::<u64>())
        .unwrap_or(FALLBACK_CLOSURE_DAYS);
    let engine = IRiskEngine::new(w.engine, p);
    let t = window.t;
    let rp = engine.params().block(at).call().await?;
    let sigma = engine.sigma(asset, t).block(at).call().await?;
    let scenario_hash = engine.scenarioHash(asset, t).block(at).call().await?;
    let v = IOracleAdapter::new(w.oracle, p)
        .valuationPrice(asset)
        .block(at)
        .call()
        .await?;
    let coll_dec = IERC20Decimals::new(params.collateralToken, p)
        .decimals()
        .call()
        .await?;
    let loan_dec = IERC20Decimals::new(params.loanToken, p)
        .decimals()
        .call()
        .await?;
    Ok(RiskCtx {
        block: blk.header.number,
        timestamp: now,
        market,
        market_id: id,
        asset_id: asset,
        clock_state: info.state,
        closure_type: t,
        close_at: window.closeAt.to::<u64>(),
        reopen_at: window.reopenAt.to::<u64>(),
        closure_days: days,
        bell_at: info.bellAt.to::<u64>(),
        upcoming_closure_id: info.closureId + 1,
        epoch_id: info.sessionCursor as u64,
        max_ltv_eff: max_ltv_eff(
            U256::from(params.maxLtv),
            now,
            (U256::from(own.haircut), own.haircutUntil.to::<u64>()),
            (U256::from(glob.haircut), glob.haircutUntil.to::<u64>()),
        ),
        lt: U256::from(params.lt),
        preclose_kappa: U256::from(params.precloseKappa),
        preclose_lambda: U256::from(params.precloseLambda),
        cover_paused: own.coverPaused || glob.coverPaused,
        sigma,
        params: RiskParams {
            alpha: U256::from(rp.alpha),
            kappa: U256::from(rp.kappa),
            theta: U256::from(rp.theta),
            cost_of_cap: U256::from(rp.costOfCap),
            eta: U256::from(rp.eta),
            beta: U256::from(rp.beta),
            u_max: U256::from(rp.uMax),
            min_premium: U256::from(rp.minPremium),
        },
        scenario_hash,
        valuation_price: v,
        coll_dec,
        loan_dec,
        pool: w.pool,
        pending_fees: st.poolFeeAccrued > 0 || st.treasuryFeeAccrued > 0,
    })
}

/// One position at the context's block.
pub async fn read_position(
    p: &DynProvider,
    ctx: &RiskCtx,
    owner: Address,
) -> Result<(PositionSnap, U256)> {
    let at = BlockId::number(ctx.block);
    let m = ICredenceMarket::new(ctx.market, p);
    let pos = m.position(ctx.market_id, owner).block(at).call().await?;
    let dproj = m
        .projectedDebt(ctx.market_id, owner)
        .block(at)
        .call()
        .await?;
    let debt = m.debtOf(ctx.market_id, owner).block(at).call().await?;
    let q = U256::from(pos.collateral);
    let snap = PositionSnap {
        owner,
        collateral: q,
        debt_projected: dproj,
        collateral_value: collateral_value(q, ctx.valuation_price, ctx.coll_dec, ctx.loan_dec)
            .map_err(|e| anyhow::anyhow!("{e:?}"))?,
        covered: pos.coverClosureId == ctx.upcoming_closure_id,
        auction_id: pos.auctionId,
        auto_cover_opt_out: pos.autoCoverOptOut,
        last_bell_closure_id: pos.lastBellClosureId,
    };
    Ok((snap, debt))
}

/// The pool's utilisation after this cover (its `previewCover`); 0 without a pool.
pub async fn util_after(p: &DynProvider, ctx: &RiskCtx, s: &PositionSnap) -> Result<U256> {
    if ctx.pool == Address::ZERO {
        return Ok(U256::ZERO);
    }
    let req = abi::IUnderwriterPool::CoverRequest {
        marketId: ctx.market_id,
        assetId: ctx.asset_id,
        borrower: s.owner,
        closureType: ctx.closure_type,
        closureDays: ctx.closure_days as u16,
        closureId: ctx.upcoming_closure_id,
        epochId: ctx.epoch_id,
        collateralValue: s.collateral_value,
        debtProjected: s.debt_projected,
    };
    let r = IUnderwriterPool::new(ctx.pool, p)
        .previewCover(req)
        .block(BlockId::number(ctx.block))
        .call()
        .await?;
    Ok(r.uAfter)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wad(s: &str) -> U256 {
        let (i, f) = s.split_once('.').unwrap_or((s, ""));
        U256::from_str_radix(&format!("{i}{:0<18}", f), 10).unwrap()
    }

    fn ctx() -> RiskCtx {
        RiskCtx {
            block: 1,
            timestamp: 0,
            market: Address::ZERO,
            market_id: B256::ZERO,
            asset_id: B256::ZERO,
            clock_state: REGULAR,
            closure_type: 2,
            close_at: 0,
            reopen_at: 0,
            closure_days: 3,
            bell_at: 0,
            upcoming_closure_id: 8,
            epoch_id: 0,
            max_ltv_eff: wad("0.75"),
            lt: wad("0.85"),
            preclose_kappa: wad("0.01"),
            preclose_lambda: wad("0.01"),
            cover_paused: false,
            sigma: wad("0.045"),
            params: RiskParams {
                alpha: wad("0.001"),
                kappa: wad("0.03"),
                theta: wad("1"),
                cost_of_cap: wad("0.15"),
                eta: wad("4"),
                beta: wad("0.975"),
                u_max: wad("0.5"),
                min_premium: U256::from(500_000u64),
            },
            scenario_hash: B256::ZERO,
            valuation_price: wad("180"),
            coll_dec: 18,
            loan_dec: 6,
            pool: Address::ZERO,
            pending_fees: false,
        }
    }

    /// G-10 (Priya) through the market's conversion: the same integers @credence/sdk/risk returns
    /// (packages/sdk/test/risk.test.ts), so the keeper, the API and the chain agree.
    #[test]
    fn g10_cures_match_the_market_view() {
        let c = ctx();
        let r = rc::bell_status(
            U256::from(90_000_000_000u64),
            U256::from(67_028_990_000u64),
            wad("0.712580117506"),
            false,
        )
        .unwrap();
        assert_eq!(r.status, NEEDS_ACTION);
        assert_eq!(r.cure_repay, U256::from(2_896_779_425u64));
        let num = U256::from(10u64).pow(U256::from(18u64)) * U256::from(WAD);
        let den = c.valuation_price * U256::from(1_000_000u64);
        assert_eq!(
            mul_div_up(r.cure_collateral_value, num, den).unwrap(),
            U256::from(22_584_434_550_000_000_000u128)
        );
    }

    #[test]
    fn bell_on_a_real_set_and_outcomes() {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../contracts/test/fixtures/risk/NVDA-XNAS-2-63c7ce73.json"
        ))
        .unwrap();
        let set = rc::setfile::parse_set(&serde_json::from_str(&text).unwrap()).unwrap();
        let z = PackedZ::new(&set.packed, set.z.len() as u32).unwrap();
        let c = ctx();
        let q = U256::from(500u64) * U256::from(WAD);
        let cv = collateral_value(q, c.valuation_price, 18, 6).unwrap();
        let mk = |d: u64, covered: bool| PositionSnap {
            owner: Address::ZERO,
            collateral: q,
            debt_projected: U256::from(d),
            collateral_value: cv,
            covered,
            auction_id: 0,
            auto_cover_opt_out: false,
            last_bell_closure_id: 0,
        };
        let high = bell(&c, &mk(74_000_000_000, false), &z).unwrap();
        assert_eq!(high.status, NEEDS_ACTION);
        assert!(high.cure_repay > U256::ZERO && high.cure_collateral > U256::ZERO);
        assert!(
            premium(&c, &mk(74_000_000_000, false), &z, U256::ZERO).unwrap()
                >= c.params.min_premium
        );
        assert_eq!(
            bell(&c, &mk(74_000_000_000, true), &z).unwrap().status,
            COVERED
        );
        assert_eq!(
            bell(&c, &mk(10_000_000_000, false), &z).unwrap().status,
            SAFE
        );
        assert_eq!(bell(&c, &mk(0, false), &z).unwrap().status, SAFE);
        // coverable = min(0.75 + 0.005, 0.85 − 0.02) = 0.755
        assert_eq!(
            expected_outcome(&c, &mk(0, false), wad("0.755")),
            AUTO_COVERED
        );
        assert_eq!(
            expected_outcome(&c, &mk(0, false), wad("0.7551")),
            PRECLOSE_THEN_COVER
        );
        let mut opt_out = mk(0, false);
        opt_out.auto_cover_opt_out = true;
        assert_eq!(expected_outcome(&c, &opt_out, wad("0.5")), PRECLOSE_SALE);
    }

    #[test]
    fn haircut_takes_the_larger_active_one() {
        assert_eq!(
            max_ltv_eff(wad("0.75"), 10, (wad("0.05"), 20), (wad("0.1"), 5)),
            wad("0.7")
        );
        assert_eq!(
            max_ltv_eff(wad("0.75"), 10, (wad("0.05"), 20), (wad("0.1"), 20)),
            wad("0.65")
        );
        assert_eq!(
            max_ltv_eff(wad("0.75"), 30, (wad("0.05"), 20), (wad("0.1"), 20)),
            wad("0.75")
        );
    }
}
