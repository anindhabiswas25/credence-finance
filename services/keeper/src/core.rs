//! The lending core as the keeper sees it (S2): market, vault, engine, clock, oracle and pool views,
//! read at one block, and the Bell computed natively with risk-core exactly like
//! `CredenceMarket.bellStatus` (CoverLogic.bellStatusView).
//!
//! Bindings come from `credence-bindings` (the frozen v1 ABIs).

use alloy::{
    eips::BlockId,
    primitives::{Address, B256, U256},
    providers::DynProvider,
};
use anyhow::{Context, Result};
use credence_risk_core::{
    self as rc,
    fixed::{collateral_value, health_factor_down, ltv_up, mul_div_up},
    WAD,
};

/// Contract bindings: `credence-bindings` (generated from `deployments/abis/v1`), under the names the
/// keeper's jobs use. Declared here only: the ERC-20 `decimals` view, and `ComplianceRegistry` until
/// `credence-bindings` exports it (BE-chain REQUEST, board 2026-09-28).
pub mod abi {
    #![allow(missing_docs)]
    pub use credence_bindings::{
        AssetClock as IAssetClockV1, CredenceMarket as ICredenceMarket, IAuctionHouse, IRiskEngine,
        IUnderwriterPool, OracleAdapter as IOracleAdapter, SeniorVault as ISeniorVault,
        SigmaOracle as ISigmaOracle,
    };
    alloy::sol!(
        #[sol(rpc)]
        ComplianceRegistry,
        "../../deployments/abis/v1/ComplianceRegistry.json"
    );
    alloy::sol! {
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
    /// The current / most recent closure (ClockData.closureId).
    pub closure_id: u64,
    /// ClockData.bellWindowAt / nextCloseAt (J9: the venue's Bell window for the next close).
    pub bell_window_at: u64,
    pub next_close_at: u64,
    /// REOPEN: when the open print was written (0 = not yet), and the sequencer-gap extension (R-20).
    pub open_print_at: u64,
    pub phase_extension: u64,
    /// ClockData.venueEpoch (R-10): the pool epoch of the current / most recent closure.
    pub venue_epoch: u64,
    pub epoch_id: u64,
    pub max_ltv_eff: U256,
    pub lt: U256,
    pub preclose_kappa: U256,
    pub preclose_lambda: U256,
    pub cover_paused: bool,
    pub sigma: U256,
    pub params: RiskParams,
    pub scenario_hash: B256,
    /// The market's safe LTV for this closure; `None` if the engine has no set for it.
    pub safe_ltv: Option<U256>,
    pub valuation_price: U256,
    pub coll_dec: u8,
    pub loan_dec: u8,
    pub pool: Address,
    pub engine: Address,
    /// Annual borrow rate (WAD), for projecting debt over a later closure.
    pub borrow_rate: U256,
    pub pending_fees: bool,
}

/// One scheduled close ahead, from the venue calendar (R-07 days, bellAt = close − 15 min).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub close_at: u64,
    pub reopen_at: u64,
    pub bell_at: u64,
    pub closure_type: u8,
    pub days: u64,
    /// 0 = the next close (closureId + 1), 1 = the one after (closureId + 2).
    pub offset: u64,
}

pub const BELL_BEFORE_CLOSE_S: u64 = 15 * 60;

/// The next two scheduled closes after `now`.
pub fn targets(cal: &credence_common::calendar::Calendar, now: u64) -> Vec<Target> {
    let i = cal.sessions.partition_point(|s| s.close <= now);
    (0..2usize)
        .filter_map(|k| {
            let s = cal.sessions.get(i + k)?;
            let next = cal.sessions.get(i + k + 1)?;
            Some(Target {
                close_at: s.close,
                reopen_at: next.open,
                bell_at: s.close - BELL_BEFORE_CLOSE_S,
                closure_type: s.closure_type_after as u8,
                days: (next.open - s.close).div_ceil(86_400),
                offset: k as u64,
            })
        })
        .collect()
}

/// `min(maxLtvEff, engine.safeLtv(asset, type, maxLtvEff, 0))` for a given closure type (MarketLib.safeLtv).
pub async fn safe_ltv_for(p: &DynProvider, ctx: &RiskCtx, closure_type: u8) -> Option<U256> {
    IRiskEngine::new(ctx.engine, p)
        .safeLtv(ctx.asset_id, closure_type, ctx.max_ltv_eff, U256::ZERO)
        .block(BlockId::number(ctx.block))
        .call()
        .await
        .ok()
        .map(|v| v.min(ctx.max_ltv_eff))
}

/// KinkedRateModel.projected: D × (1 + r × days / 365), rounded up.
pub fn project(debt: U256, rate: U256, days: u64) -> Result<U256> {
    rc::projected_debt(debt, rate, days.min(u16::MAX as u64) as u16)
        .map_err(|e| anyhow::anyhow!("{e:?}"))
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

/// CoverLogic.bellStatusView for one position, at the market's safe LTV for the closure
/// (`min(maxLtvEff, engine.safeLtv(asset, type, maxLtvEff, 0))`, read into the context).
pub fn bell(ctx: &RiskCtx, p: &PositionSnap) -> Result<Bell> {
    let safe = ctx
        .safe_ltv
        .context("the engine has no scenario set for this closure (safeLtv reverted)")?;
    bell_at(ctx, p, safe)
}

/// The Bell at a given safe LTV (risk-core `bell_status`, cures converted like the market).
pub fn bell_at(ctx: &RiskCtx, p: &PositionSnap, safe: U256) -> Result<Bell> {
    let ltv = ltv_up(p.debt_projected, p.collateral_value).unwrap_or(U256::MAX);
    let zero = |status| Bell {
        status,
        safe_ltv: safe,
        ltv,
        cure_repay: U256::ZERO,
        cure_collateral_value: U256::ZERO,
        cure_collateral: U256::ZERO,
    };
    if p.covered {
        return Ok(zero(COVERED));
    }
    if p.debt_projected.is_zero() {
        return Ok(zero(SAFE));
    }
    let r = rc::bell_status(p.collateral_value, p.debt_projected, safe, false)
        .map_err(|e| anyhow::anyhow!("bell_status: {e:?}"))?;
    if r.status != NEEDS_ACTION {
        return Ok(zero(r.status));
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
    let max_eff = max_ltv_eff(
        U256::from(params.maxLtv),
        now,
        (U256::from(own.haircut), own.haircutUntil.to::<u64>()),
        (U256::from(glob.haircut), glob.haircutUntil.to::<u64>()),
    );
    let safe_ltv = engine
        .safeLtv(asset, t, max_eff, U256::ZERO)
        .block(at)
        .call()
        .await
        .ok()
        .map(|v| v.min(max_eff));
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
        closure_id: info.closureId,
        bell_window_at: info.bellWindowAt.to::<u64>(),
        next_close_at: info.nextCloseAt.to::<u64>(),
        open_print_at: info.openPrintAt.to::<u64>(),
        phase_extension: info.phaseExtension.to::<u64>(),
        venue_epoch: info.venueEpoch,
        epoch_id: info.sessionCursor as u64,
        max_ltv_eff: max_eff,
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
        safe_ltv,
        valuation_price: v,
        coll_dec,
        loan_dec,
        pool: w.pool,
        engine: w.engine,
        borrow_rate: m.borrowRate(id).block(at).call().await?,
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

/// The pool's quote for this position's cover: `(premium, uAfter)` from `previewCover`, exactly what
/// the borrower would be charged (and what `CredenceMarket.bellStatus` reports).
pub async fn preview_cover(
    p: &DynProvider,
    ctx: &RiskCtx,
    s: &PositionSnap,
    t: Option<&Target>,
) -> Result<(U256, U256)> {
    let req = abi::IUnderwriterPool::CoverRequest {
        marketId: ctx.market_id,
        assetId: ctx.asset_id,
        borrower: s.owner,
        closureType: t.map_or(ctx.closure_type, |t| t.closure_type),
        closureDays: t.map_or(ctx.closure_days, |t| t.days) as u16,
        closureId: ctx.upcoming_closure_id + t.map_or(0, |t| t.offset),
        epochId: ctx.epoch_id + t.map_or(0, |t| t.offset),
        collateralValue: s.collateral_value,
        debtProjected: s.debt_projected,
    };
    let r = IUnderwriterPool::new(ctx.pool, p)
        .previewCover(req)
        .block(BlockId::number(ctx.block))
        .call()
        .await?;
    Ok((r.premium, r.uAfter))
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
            closure_id: 7,
            bell_window_at: 0,
            next_close_at: 0,
            open_print_at: 0,
            phase_extension: 0,
            venue_epoch: 0,
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
            safe_ltv: None,
            valuation_price: wad("180"),
            coll_dec: 18,
            loan_dec: 6,
            pool: Address::ZERO,
            engine: Address::ZERO,
            borrow_rate: wad("0.0733"),
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
        let z = rc::PackedZ::new(&set.packed, set.z.len() as u32).unwrap();
        let mut c = ctx();
        // what the Stylus engine's safeLtv view returns for this set
        let safe = rc::safe_ltv_from_set(
            &z,
            c.params.alpha,
            c.sigma,
            U256::ZERO,
            c.params.kappa,
            c.max_ltv_eff,
        )
        .unwrap();
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
        assert!(
            bell(&c, &mk(74_000_000_000, false)).is_err(),
            "no safe LTV without an engine set"
        );
        c.safe_ltv = Some(safe);
        let high = bell(&c, &mk(74_000_000_000, false)).unwrap();
        assert_eq!(high.status, NEEDS_ACTION);
        assert_eq!(high.safe_ltv, safe);
        assert!(high.cure_repay > U256::ZERO && high.cure_collateral > U256::ZERO);
        assert_eq!(bell(&c, &mk(74_000_000_000, true)).unwrap().status, COVERED);
        assert_eq!(bell(&c, &mk(10_000_000_000, false)).unwrap().status, SAFE);
        assert_eq!(bell(&c, &mk(0, false)).unwrap().status, SAFE);
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
    fn targets_are_the_next_two_scheduled_closes() {
        let cal = credence_common::calendar::Calendar::load(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../calibration/out/calendars/XNYS-20261001-20271031.json"
        ))
        .unwrap();
        // Thu 2026-10-08 14:05 ET (18:05Z): T-26h before Friday's close
        let t = targets(&cal, 1_791_482_700);
        assert_eq!(t.len(), 2);
        assert_eq!((t[0].closure_type, t[0].days, t[0].offset), (1, 1, 0)); // Thursday night
        assert_eq!((t[1].closure_type, t[1].days, t[1].offset), (2, 3, 1)); // the weekend (R-07: 3 days)
        assert_eq!(t[1].close_at, 1_791_576_000); // Fri 16:00 ET
        assert_eq!(t[1].bell_at, t[1].close_at - 900);
        // Wed 2026-11-25 14:00Z (Thanksgiving next day): the next close opens a holiday closure
        let w = targets(&cal, 1_795_615_200);
        assert_eq!(w[0].closure_type, 3);
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
