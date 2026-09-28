// Live chain reads for the quote endpoints (§10.4 "/bell ... against current chain state"). Every read
// of one request is pinned to one block, so the inputs are mutually consistent. The math itself runs
// in risk-wasm (@credence/sdk/risk); this module only gathers what the market and engine would read.
import {
  ICredenceMarketAbi,
  IAssetClockAbi,
  IOracleAdapterAbi,
  IRiskEngineAbi,
  ISeniorVaultAbi,
  IUnderwriterPoolAbi,
} from "@credence/sdk";
import type { RiskParams } from "@credence/sdk/risk";
import {
  parseAbi,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

const ERC20 = parseAbi(["function decimals() view returns (uint8)"]);
const WAD = 10n ** 18n;
const ZERO32 = `0x${"0".repeat(64)}` as Hex;
/** MarketLib constants (R-03, R-07). */
export const DELTA_COVER = 5n * 10n ** 15n;
export const COVER_LT_GAP = 2n * 10n ** 16n;
export const FALLBACK_CLOSURE_DAYS = 4n;

/** The closure-dependent risk inputs of one market (shared by /markets and /bell). */
export interface RiskContext {
  block: bigint;
  timestamp: bigint;
  marketId: Hex;
  assetId: Hex;
  closureType: number;
  closeAt: number;
  reopenAt: number;
  closureDays: bigint;
  /** closureInfo.closureId + 1: the closure cover bought now protects. */
  upcomingClosureId: bigint;
  epochId: bigint;
  maxLtv: bigint;
  /** maxLtv minus any active guardian haircut (market or global). */
  maxLtvEff: bigint;
  lt: bigint;
  coverPaused: boolean;
  sigma: bigint;
  params: RiskParams;
  scenarioHash: Hex;
  valuationPrice: bigint;
  collDecimals: number;
  loanDecimals: number;
  borrowRate: bigint;
  liquidity: bigint;
  state: {
    totalSupplyAssets: bigint;
    totalBorrowAssets: bigint;
    totalBorrowShares: bigint;
    totalCollateral: bigint;
    feePoolBps: number;
    feeTreasuryBps: number;
  };
  wiring: {
    clock: Address;
    oracle: Address;
    engine: Address;
    pool: Address;
    vault: Address;
  };
}

export interface PositionState {
  collateral: bigint;
  borrowShares: bigint;
  coverClosureId: bigint;
  auctionId: bigint;
  autoCoverOptOut: boolean;
  debt: bigint;
  debtProjected: bigint;
  collateralValue: bigint;
  covered: boolean;
  /** The market's own views at the same block (WAD). */
  ltv: bigint;
  healthFactor: bigint;
  borrowLimitLtv: bigint;
}

export interface VaultLive {
  block: bigint;
  totalAssets: bigint;
  totalSupply: bigint;
  idle: bigint;
  queueLength: bigint;
  pendingRedeemShares: bigint;
  claimableAssets: bigint;
  /** convertToAssets(10^decimals): assets per whole share. */
  assetsPerShare: bigint;
  decimals: number;
}

export interface ChainReader {
  risk(market: Address, id: Hex, block?: bigint): Promise<RiskContext>;
  position(
    market: Address,
    ctx: RiskContext,
    owner: Address,
  ): Promise<PositionState>;
  /** The pool's utilisation after this cover (`previewCover`), the one input risk-wasm cannot know. */
  uAfter(ctx: RiskContext, owner: Address, pos: PositionState): Promise<bigint>;
  vault(vault: Address): Promise<VaultLive>;
}

/** WadMath.collateralValue: floor(q · v · 10^loan / (10^coll · WAD)). */
export function collateralValue(
  q: bigint,
  v: bigint,
  collDec: number,
  loanDec: number,
): bigint {
  return (q * v * 10n ** BigInt(loanDec)) / (10n ** BigInt(collDec) * WAD);
}

/** MarketLib.maxLtvEff. */
export function maxLtvEff(
  maxLtv: bigint,
  now: bigint,
  own: { haircut: bigint; haircutUntil: number },
  global: { haircut: bigint; haircutUntil: number },
): bigint {
  let cut = 0n;
  if (BigInt(own.haircutUntil) > now) cut = own.haircut;
  if (BigInt(global.haircutUntil) > now && global.haircut > cut)
    cut = global.haircut;
  return maxLtv > cut ? maxLtv - cut : 0n;
}

export function viemChainReader(client: PublicClient): ChainReader {
  const decCache = new Map<string, number>();
  const decimals = async (token: Address) => {
    const k = token.toLowerCase();
    let d = decCache.get(k);
    if (d === undefined) {
      d = Number(
        await client.readContract({
          abi: ERC20,
          address: token,
          functionName: "decimals",
        }),
      );
      decCache.set(k, d);
    }
    return d;
  };

  return {
    async risk(market, id, blockNumber) {
      const block = await client.getBlock(
        blockNumber === undefined ? {} : { blockNumber },
      );
      const at = { blockNumber: block.number } as const;
      const m = { abi: ICredenceMarketAbi, address: market, ...at } as const;
      const [p, w, st, rate, liq, own, glob] = await Promise.all([
        client.readContract({ ...m, functionName: "marketParams", args: [id] }),
        client.readContract({ ...m, functionName: "wiring" }),
        client.readContract({ ...m, functionName: "marketState", args: [id] }),
        client.readContract({ ...m, functionName: "borrowRate", args: [id] }),
        client.readContract({ ...m, functionName: "liquidity", args: [id] }),
        client.readContract({ ...m, functionName: "overlay", args: [id] }),
        client.readContract({ ...m, functionName: "overlay", args: [ZERO32] }),
      ]);
      const asset = p.assetId;
      const clock = { abi: IAssetClockAbi, address: w.clock, ...at } as const;
      const engine = { abi: IRiskEngineAbi, address: w.engine, ...at } as const;
      const [window, info, days, v, cd, ld, params] = await Promise.all([
        client.readContract({
          ...clock,
          functionName: "closureWindow",
          args: [asset],
        }),
        client.readContract({
          ...clock,
          functionName: "closureInfo",
          args: [asset],
        }),
        client
          .readContract({
            ...clock,
            functionName: "closureDays",
            args: [asset],
          })
          .catch(() => FALLBACK_CLOSURE_DAYS),
        client.readContract({
          abi: IOracleAdapterAbi,
          address: w.oracle,
          functionName: "valuationPrice",
          args: [asset],
          ...at,
        }),
        decimals(p.collateralToken),
        decimals(p.loanToken),
        client.readContract({ ...engine, functionName: "params" }),
      ]);
      const t = Number(window[2]);
      const [sigma, scenarioHash] = await Promise.all([
        client.readContract({
          ...engine,
          functionName: "sigma",
          args: [asset, t],
        }),
        client.readContract({
          ...engine,
          functionName: "scenarioHash",
          args: [asset, t],
        }),
      ]);
      return {
        block: block.number,
        timestamp: block.timestamp,
        marketId: id,
        assetId: asset,
        closureType: t,
        closeAt: Number(window[0]),
        reopenAt: Number(window[1]),
        closureDays: BigInt(days),
        upcomingClosureId: BigInt(info.closureId) + 1n,
        epochId: BigInt(info.sessionCursor),
        maxLtv: BigInt(p.maxLtv),
        maxLtvEff: maxLtvEff(
          BigInt(p.maxLtv),
          block.timestamp,
          {
            haircut: BigInt(own.haircut),
            haircutUntil: Number(own.haircutUntil),
          },
          {
            haircut: BigInt(glob.haircut),
            haircutUntil: Number(glob.haircutUntil),
          },
        ),
        lt: BigInt(p.lt),
        coverPaused: own.coverPaused || glob.coverPaused,
        sigma,
        params: {
          alpha: BigInt(params.alpha),
          kappa: BigInt(params.kappa),
          theta: BigInt(params.theta),
          costOfCap: BigInt(params.costOfCap),
          eta: BigInt(params.eta),
          beta: BigInt(params.beta),
          uMax: BigInt(params.uMax),
          minPremium: BigInt(params.minPremium),
          kStress: Number(params.kStress),
        },
        scenarioHash,
        valuationPrice: v,
        collDecimals: cd,
        loanDecimals: ld,
        borrowRate: rate,
        liquidity: liq,
        state: {
          totalSupplyAssets: BigInt(st.totalSupplyAssets),
          totalBorrowAssets: BigInt(st.totalBorrowAssets),
          totalBorrowShares: BigInt(st.totalBorrowShares),
          totalCollateral: BigInt(st.totalCollateral),
          feePoolBps: Number(st.feePoolBps),
          feeTreasuryBps: Number(st.feeTreasuryBps),
        },
        wiring: {
          clock: w.clock,
          oracle: w.oracle,
          engine: w.engine,
          pool: w.pool,
          vault: w.vault,
        },
      };
    },

    async position(market, ctx, owner) {
      const m = {
        abi: ICredenceMarketAbi,
        address: market,
        blockNumber: ctx.block,
      } as const;
      const [pos, debt, dproj, ltv, hf, lim] = await Promise.all([
        client.readContract({
          ...m,
          functionName: "position",
          args: [ctx.marketId, owner],
        }),
        client.readContract({
          ...m,
          functionName: "debtOf",
          args: [ctx.marketId, owner],
        }),
        client.readContract({
          ...m,
          functionName: "projectedDebt",
          args: [ctx.marketId, owner],
        }),
        client.readContract({
          ...m,
          functionName: "ltv",
          args: [ctx.marketId, owner],
        }),
        client.readContract({
          ...m,
          functionName: "healthFactor",
          args: [ctx.marketId, owner],
        }),
        client.readContract({
          ...m,
          functionName: "borrowLimitLtv",
          args: [ctx.marketId, owner],
        }),
      ]);
      const q = BigInt(pos.collateral);
      return {
        collateral: q,
        borrowShares: BigInt(pos.borrowShares),
        coverClosureId: BigInt(pos.coverClosureId),
        auctionId: BigInt(pos.auctionId),
        autoCoverOptOut: pos.autoCoverOptOut,
        debt,
        debtProjected: dproj,
        collateralValue: collateralValue(
          q,
          ctx.valuationPrice,
          ctx.collDecimals,
          ctx.loanDecimals,
        ),
        covered: BigInt(pos.coverClosureId) === ctx.upcomingClosureId,
        ltv,
        healthFactor: hf,
        borrowLimitLtv: lim,
      };
    },

    async uAfter(ctx, owner, pos) {
      if (ctx.wiring.pool === zeroAddress) return 0n;
      const [, u] = await client.readContract({
        abi: IUnderwriterPoolAbi,
        address: ctx.wiring.pool,
        functionName: "previewCover",
        blockNumber: ctx.block,
        args: [
          {
            marketId: ctx.marketId,
            assetId: ctx.assetId,
            borrower: owner,
            closureType: ctx.closureType,
            closureDays: Number(ctx.closureDays),
            closureId: ctx.upcomingClosureId,
            epochId: ctx.epochId,
            collateralValue: pos.collateralValue,
            debtProjected: pos.debtProjected,
          },
        ],
      });
      return u;
    },

    async vault(vault) {
      const blockNumber = await client.getBlockNumber();
      const v = { abi: ISeniorVaultAbi, address: vault, blockNumber } as const;
      const [
        totalAssets,
        totalSupply,
        idle,
        queueLength,
        pendingRedeemShares,
        claimableAssets,
        dec,
      ] = await Promise.all([
        client.readContract({ ...v, functionName: "totalAssets" }),
        client.readContract({ ...v, functionName: "totalSupply" }),
        client.readContract({ ...v, functionName: "idle" }),
        client.readContract({ ...v, functionName: "queueLength" }),
        client.readContract({ ...v, functionName: "pendingRedeemShares" }),
        client.readContract({ ...v, functionName: "claimableAssets" }),
        client.readContract({ ...v, functionName: "decimals" }),
      ]);
      const assetsPerShare = await client.readContract({
        ...v,
        functionName: "convertToAssets",
        args: [10n ** BigInt(dec)],
      });
      return {
        block: blockNumber,
        totalAssets,
        totalSupply,
        idle,
        queueLength,
        pendingRedeemShares,
        claimableAssets,
        assetsPerShare,
        decimals: Number(dec),
      };
    },
  };
}
