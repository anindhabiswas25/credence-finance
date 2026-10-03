"use client";
/**
 * Reads from the Credence API (services/api). The browser calls `/v1/*` on its own origin and
 * next.config.ts proxies it to the API, so the SIWE session cookie stays first-party.
 * Every hook maps the API's raw shapes into the plain numbers the pages render.
 */
import { useQueries, useQuery } from "@tanstack/react-query";
import { formatUnits, type Address, type Hex } from "viem";
import { MARKET_INDEX, MARKET_NAMES, STACKS, type ChainId, type Stack } from "./protocol";

type Amt = { raw: string; formatted: string };
type Ratio = { raw: string; percent: string };

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    credentials: "include",
    ...init,
    headers: { ...(init?.body ? { "content-type": "application/json" } : {}), ...init?.headers },
  });
  const body = (await res.json().catch(() => null)) as (T & { message?: string }) | null;
  if (!res.ok) throw new ApiError(res.status, body?.message ?? `${res.status} ${res.statusText}`);
  return body as T;
}

const ratio = (r: Ratio | null | undefined) => (r ? Number(r.percent) / 100 : null);
const amt = (a: Amt | null | undefined) => (a ? Number(a.formatted) : 0);
const wad = (s: string | null | undefined) => (s ? Number(formatUnits(BigInt(s), 18)) : 0);

// ── markets ──────────────────────────────────────────────────────────────────────────────────────

export type MarketState = "Open" | "Extended" | "Closed" | "Reopen" | "Halted" | "Corp. action";
const STATE: Record<string, MarketState> = {
  REGULAR: "Open",
  EXTENDED: "Extended",
  CLOSED: "Closed",
  REOPEN: "Reopen",
  HALTED: "Halted",
  CORP_ACTION: "Corp. action",
};

type ApiMarket = {
  marketId: Hex;
  stack: Stack;
  assetId: Hex;
  loanToken: Address;
  collateralToken: Address;
  maxLtv: Ratio;
  lt: Ratio;
  supplyCap: Amt;
  borrowCap: Amt;
  totalSupply: Amt;
  totalBorrow: Amt;
  totalCollateral: string;
  clock: { state: { code: number; name: string }; closureId: string; pause: { reason: string; message: string } | null } | null;
  live: {
    borrowRate: Ratio;
    utilisation: Ratio;
    liquidity: Amt;
    maxLtvEffective: Ratio;
    coverPaused: boolean;
    nextClosure: { closureType: { code: number; name: string }; closeAt: number; reopenAt: number; days: number; safeLtv: Ratio | null; sigma: Ratio };
    loanSymbol: string;
    multiplier: { tokenPrice: string; corporateAction: boolean } | null;
  } | null;
};

export type Market = {
  marketId: Hex;
  chainId: ChainId;
  stack: Stack;
  symbol: string;
  name: string;
  kind: "Stock" | "Treasury fund";
  assetId: Hex;
  collateralToken: Address;
  loanToken: Address;
  loanSymbol: string;
  price: number;
  state: MarketState;
  stateName: string;
  pause: { reason: string; message: string } | null;
  maxLtv: number;
  maxLtvEffective: number;
  safeLtv: number | null;
  liqThreshold: number;
  borrowApr: number;
  utilisation: number;
  supplied: number;
  borrowed: number;
  liquidity: number;
  coverPaused: boolean;
  sigma: number;
  nextClosure: { type: string; closeAt: number; reopenAt: number; days: number } | null;
};

function toMarket(m: ApiMarket, chainId: ChainId): Market {
  const meta = MARKET_INDEX[m.marketId.toLowerCase()];
  const symbol = meta?.symbol ?? m.marketId.slice(0, 8);
  const live = m.live;
  return {
    marketId: m.marketId,
    chainId,
    stack: m.stack,
    symbol,
    name: MARKET_NAMES[symbol] ?? symbol,
    kind: m.stack === "nav" ? "Treasury fund" : "Stock",
    assetId: m.assetId,
    collateralToken: m.collateralToken,
    loanToken: m.loanToken,
    loanSymbol: live?.loanSymbol ?? STACKS[m.stack].loanSymbol,
    price: wad(live?.multiplier?.tokenPrice),
    state: STATE[m.clock?.state.name ?? ""] ?? "Closed",
    stateName: m.clock?.state.name ?? "UNKNOWN",
    pause: m.clock?.pause ?? null,
    maxLtv: ratio(m.maxLtv) ?? 0,
    maxLtvEffective: ratio(live?.maxLtvEffective) ?? ratio(m.maxLtv) ?? 0,
    safeLtv: ratio(live?.nextClosure.safeLtv),
    liqThreshold: ratio(m.lt) ?? 0,
    borrowApr: ratio(live?.borrowRate) ?? 0,
    utilisation: ratio(live?.utilisation) ?? 0,
    supplied: amt(m.totalSupply),
    borrowed: amt(m.totalBorrow),
    liquidity: amt(live?.liquidity),
    coverPaused: live?.coverPaused ?? false,
    sigma: ratio(live?.nextClosure.sigma) ?? 0,
    nextClosure: live
      ? {
          type: live.nextClosure.closureType.name,
          closeAt: live.nextClosure.closeAt,
          reopenAt: live.nextClosure.reopenAt,
          days: live.nextClosure.days,
        }
      : null,
  };
}

const CHAIN_IDS = [STACKS.equity.chainId, STACKS.nav.chainId] as const;
const ORDER = ["NVDA", "AAPL", "TSLA", "RHTSLA", "MSFT", "AMZN", "GOOGL", "TBILL"];

export function useMarkets() {
  const qs = useQueries({
    queries: CHAIN_IDS.map((chainId) => ({
      queryKey: ["markets", chainId],
      queryFn: () => api<{ markets: ApiMarket[] }>(`/v1/markets?chain=${chainId}`),
      refetchInterval: 20_000,
    })),
  });
  const markets = qs
    .flatMap((q, i) => (q.data?.markets ?? []).map((m) => toMarket(m, CHAIN_IDS[i]!)))
    .sort((a, b) => ORDER.indexOf(a.symbol) - ORDER.indexOf(b.symbol));
  return {
    markets,
    bySymbol: Object.fromEntries(markets.map((m) => [m.symbol, m])) as Record<string, Market>,
    byId: Object.fromEntries(markets.map((m) => [m.marketId.toLowerCase(), m])) as Record<string, Market>,
    isLoading: qs.some((q) => q.isLoading),
    error: qs.find((q) => q.error)?.error ?? null,
  };
}

/** The next equity closure (every stock shares the XNYS venue), with its Bell times. */
export function nextClosureOf(markets: Market[]) {
  const eq = markets
    .filter((m) => m.stack === "equity" && m.nextClosure)
    .sort((a, b) => a.nextClosure!.closeAt - b.nextClosure!.closeAt)[0];
  if (!eq?.nextClosure) return null;
  const c = eq.nextClosure;
  return {
    type: c.type,
    label: c.type === "OVERNIGHT" ? "Overnight" : c.type === "HOLIDAY_WEEKEND" ? "Holiday weekend" : "Weekend",
    closeAt: c.closeAt,
    reopenAt: c.reopenAt,
    bellWindowAt: c.closeAt - 2 * 3600,
    bellDeadlineAt: c.closeAt - 15 * 60,
    /** The market is already shut for this closure (the API keeps it as "next" until the reopen). */
    inProgress: c.closeAt <= Date.now() / 1000,
  };
}
export type NextClosure = NonNullable<ReturnType<typeof nextClosureOf>>;

// ── positions and the Bell ───────────────────────────────────────────────────────────────────────

type ApiPosition = {
  marketId: Hex;
  owner: Address;
  collateral: string;
  borrowShares: string;
  cover: { coveredClosureId: string; coveredForNext: boolean | null };
  auctionId: string | null;
  autoCover: boolean;
  live: {
    debt: Amt;
    debtProjected: Amt;
    collateralValue: Amt | null;
    ltv: Ratio;
    healthFactor: Ratio;
    borrowLimitLtv: Ratio;
  } | null;
};

export type Position = {
  marketId: Hex;
  chainId: ChainId;
  symbol: string;
  collateralRaw: bigint;
  tokens: number;
  borrowShares: bigint;
  debt: number;
  debtRaw: bigint;
  value: number;
  ltv: number;
  hf: number | null;
  borrowLimitLtv: number;
  covered: boolean;
  autoCover: boolean;
  inAuction: string | null;
};

export function usePositions(owner: Address | undefined) {
  const qs = useQueries({
    queries: CHAIN_IDS.map((chainId) => ({
      queryKey: ["positions", chainId, owner],
      queryFn: () => api<{ positions: ApiPosition[] }>(`/v1/positions/${owner}?chain=${chainId}`),
      enabled: !!owner,
      refetchInterval: 15_000,
    })),
  });
  const positions: Position[] = qs
    .flatMap((q, i) =>
      (q.data?.positions ?? []).map((p) => {
        const live = p.live;
        const hfRatio = live ? Number(live.healthFactor.percent) / 100 : null;
        const collateralRaw = BigInt(p.collateral);
        return {
          marketId: p.marketId,
          chainId: CHAIN_IDS[i]!,
          symbol: MARKET_INDEX[p.marketId.toLowerCase()]?.symbol ?? "?",
          collateralRaw,
          tokens: Number(formatUnits(collateralRaw, 18)),
          borrowShares: BigInt(p.borrowShares),
          debt: amt(live?.debt),
          debtRaw: BigInt(live?.debt.raw ?? "0"),
          value: amt(live?.collateralValue),
          ltv: ratio(live?.ltv) ?? 0,
          // The API returns HF as a WAD ratio; an empty debt has an unbounded one.
          hf: hfRatio !== null && hfRatio < 1e6 ? hfRatio : null,
          borrowLimitLtv: ratio(live?.borrowLimitLtv) ?? 0,
          covered: !!p.cover.coveredForNext,
          autoCover: p.autoCover,
          inAuction: p.auctionId,
        };
      }),
    )
    .filter((p) => p.collateralRaw > 0n || p.borrowShares > 0n);
  return { positions, isLoading: qs.some((q) => q.isLoading && q.fetchStatus !== "idle") };
}

type ApiBell = {
  status: { code: number; name: "SAFE" | "NEEDS_ACTION" | "COVERED" | string };
  closure: { closureId: string; epochId: string; closureType: { name: string }; closeAt: number; reopenAt: number };
  safeLtv: Ratio;
  ltvProjected: Ratio;
  debtProjected: Amt;
  cure: { repay: Amt; addCollateral: string; addCollateralValue: Amt };
  premium: Amt | null;
};

export type Bell = {
  status: string;
  closureId: string;
  closureType: string;
  closeAt: number;
  reopenAt: number;
  safeLtv: number;
  ltvProjected: number;
  repayRaw: bigint;
  repay: number;
  addRaw: bigint;
  add: number;
  premiumRaw: bigint | null;
  premium: number | null;
};

export function useBell(p: Pick<Position, "marketId" | "chainId"> | undefined, owner: Address | undefined) {
  return useQuery({
    queryKey: ["bell", p?.chainId, p?.marketId, owner],
    enabled: !!p && !!owner,
    refetchInterval: 15_000,
    queryFn: async (): Promise<Bell> => {
      const b = await api<ApiBell>(`/v1/positions/${p!.marketId}/${owner}/bell?chain=${p!.chainId}`);
      return {
        status: b.status.name,
        closureId: b.closure.closureId,
        closureType: b.closure.closureType.name,
        closeAt: b.closure.closeAt,
        reopenAt: b.closure.reopenAt,
        safeLtv: Number(b.safeLtv.percent) / 100,
        ltvProjected: Number(b.ltvProjected.percent) / 100,
        repayRaw: BigInt(b.cure.repay.raw),
        repay: amt(b.cure.repay),
        addRaw: BigInt(b.cure.addCollateral),
        add: Number(formatUnits(BigInt(b.cure.addCollateral), 18)),
        premiumRaw: b.premium ? BigInt(b.premium.raw) : null,
        premium: b.premium ? amt(b.premium) : null,
      };
    },
  });
}

// ── Senior Vault and Underwriter Pool ────────────────────────────────────────────────────────────

type ApiVault = {
  vault: Address;
  totalAssets: Amt;
  totalSupply: string;
  sharePrice: string;
  apy: Ratio;
  idle: Amt;
  queue: { length: string; pendingShares: string; claimable: Amt; head: { requestId: string; owner: string; shares: string }[] };
  cushion: Ratio | null;
};

export function useVault(stack: Stack) {
  const chainId = STACKS[stack].chainId;
  return useQuery({
    queryKey: ["vault", stack],
    refetchInterval: 30_000,
    queryFn: async () => {
      const v = await api<ApiVault>(`/v1/vault/${stack}?chain=${chainId}`);
      return {
        tvl: amt(v.totalAssets),
        idle: amt(v.idle),
        borrowed: Math.max(0, amt(v.totalAssets) - amt(v.idle)),
        apy: ratio(v.apy) ?? 0,
        sharePrice: Number(v.sharePrice),
        queueLength: Number(v.queue.length),
        claimable: amt(v.queue.claimable),
        head: v.queue.head,
        cushion: ratio(v.cushion),
      };
    },
  });
}

type ApiEpoch = {
  epochId: string;
  status: string;
  closeAt: number | null;
  reopenAt: number | null;
  exposure: { equityAtRisk: Amt | null; worstLoss: Amt | null; policies: number };
  pnl: { premiums: Amt; riskFees: Amt | null; penalties: Amt | null; lossesPaid: Amt | null };
  navBefore: Amt | null;
  navAfter: Amt | null;
  sharePriceAfter: string | null;
  settledAt: number | null;
};

export type Epoch = {
  id: string;
  status: string;
  closeAt: number | null;
  reopenAt: number | null;
  policies: number;
  worstLoss: number;
  premiums: number;
  fees: number;
  losses: number;
  result: number | null;
  sharePriceAfter: number | null;
};

export function usePoolEpochs(stack: Stack) {
  const chainId = STACKS[stack].chainId;
  return useQuery({
    queryKey: ["epochs", stack],
    refetchInterval: 60_000,
    retry: false,
    queryFn: async (): Promise<Epoch[]> => {
      try {
        const r = await api<{ items: ApiEpoch[] }>(`/v1/pool/${stack}/epochs?chain=${chainId}&limit=12`);
        return r.items.map((e) => ({
          id: e.epochId,
          status: e.status,
          closeAt: e.closeAt,
          reopenAt: e.reopenAt,
          policies: e.exposure.policies,
          worstLoss: amt(e.exposure.worstLoss),
          premiums: amt(e.pnl.premiums),
          fees: amt(e.pnl.riskFees) + amt(e.pnl.penalties),
          losses: amt(e.pnl.lossesPaid),
          result: e.navBefore && e.navAfter && amt(e.navBefore) > 0 ? amt(e.navAfter) / amt(e.navBefore) - 1 : null,
          sharePriceAfter: e.sharePriceAfter ? wad(e.sharePriceAfter) : null,
        }));
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) return []; // no epoch indexed yet
        throw e;
      }
    },
  });
}

type ApiPool = {
  allTime: { premiums: Amt; riskFees: Amt; penalties: Amt; bonds: Amt; lossesPaid: Amt };
  currentEpoch: { policies?: number; worstLoss?: Amt | null; premiums?: Amt } | null;
};

export function usePoolApi(stack: Stack) {
  const chainId = STACKS[stack].chainId;
  return useQuery({
    queryKey: ["pool", stack],
    refetchInterval: 60_000,
    retry: false,
    queryFn: async () => {
      try {
        const p = await api<ApiPool>(`/v1/pool/${stack}?chain=${chainId}`);
        return {
          premiums: amt(p.allTime.premiums),
          riskFees: amt(p.allTime.riskFees),
          penalties: amt(p.allTime.penalties),
          lossesPaid: amt(p.allTime.lossesPaid),
          currentEpoch: p.currentEpoch,
        };
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) return null; // the pool has no indexed epoch yet
        throw e;
      }
    },
  });
}

// ── auctions, settlements, risk ──────────────────────────────────────────────────────────────────

export type Auction = {
  auctionId: string;
  kind: { code: number; name: "REOPEN" | "INTRADAY" | "EMERGENCY" | "PRECLOSE" | string };
  marketId: Hex;
  assetId: Hex;
  closureId: string;
  status: "queue" | "fixed" | "cleared" | "settled" | string;
  deadlines: { lotFixAt: number | null; biddingStartAt: number | null; biddingEndAt: number | null; clearAt: number | null };
  lot: string | null;
  reserve: string | null;
  positions: number;
  bids: number;
  clearing: { pStar: string; openPrint: string | null; filled: string | null; qPool: string | null } | null;
  createdAt: number;
  clearedAt: number | null;
};

export function useAuctions() {
  return useQuery({
    queryKey: ["auctions"],
    refetchInterval: 10_000,
    queryFn: () => api<{ items: Auction[] }>(`/v1/auctions?chain=${STACKS.equity.chainId}&limit=25`).then((r) => r.items),
  });
}

export type AuctionDetail = Auction & {
  bidList: { bidder: string; status: string; qty: string | null; price: string | null; tokens: string | null; refund: Amt | null; bondForfeited: boolean }[];
};

export function useAuctionDetails(ids: string[]) {
  return useQueries({
    queries: ids.map((id) => ({
      queryKey: ["auction", id],
      refetchInterval: 15_000,
      retry: false,
      queryFn: () => api<AuctionDetail>(`/v1/auctions/${id}?chain=${STACKS.equity.chainId}`),
    })),
  });
}

export type Settlement = {
  settlementId: string;
  marketId: Hex;
  status: "open" | "filled" | "advanced";
  qty: string;
  floorPrice: string;
  endsAt: number;
  bids: number;
  best: { solver: string | null; price: string };
  outcome: { kind: string; price: string | null; proceeds: Amt } | null;
  openedAt: number;
};

export function useSettlements() {
  return useQuery({
    queryKey: ["settlements"],
    refetchInterval: 30_000,
    queryFn: () => api<{ items: Settlement[] }>(`/v1/settlements?chain=${STACKS.nav.chainId}&limit=10`).then((r) => r.items),
  });
}

type ApiRisk = {
  markets: { marketId: Hex; safeLtvNextClosure: Ratio | null; premiumsCollected: Amt; policies: number; lossesByLayer: { pool: Amt; reserve: Amt; senior: Amt } }[];
  pools: { stack: Stack; size: Amt | null; utilisation: Ratio | null; premiumsCollected: Amt; lossesPaid: Amt }[];
  auctions: { auctionId: string; kind: string; assetId: Hex; pStar: string; openPrint: string | null; pStarVsOpenPrint: Ratio | null }[];
};

export function useRisk() {
  const qs = useQueries({
    queries: CHAIN_IDS.map((chainId) => ({
      queryKey: ["risk", chainId],
      refetchInterval: 60_000,
      queryFn: () => api<ApiRisk>(`/v1/risk?chain=${chainId}`),
    })),
  });
  const markets = qs.flatMap((q) => q.data?.markets ?? []);
  return {
    byMarket: Object.fromEntries(
      markets.map((m) => [
        m.marketId.toLowerCase(),
        {
          premiums: amt(m.premiumsCollected),
          policies: m.policies,
          losses: amt(m.lossesByLayer.pool) + amt(m.lossesByLayer.reserve) + amt(m.lossesByLayer.senior),
        },
      ]),
    ) as Record<string, { premiums: number; policies: number; losses: number }>,
    auctions: qs.flatMap((q) => q.data?.auctions ?? []),
    isLoading: qs.some((q) => q.isLoading),
  };
}

// ── session, inbox, testnet access ───────────────────────────────────────────────────────────────

export function useSession() {
  return useQuery({
    queryKey: ["session"],
    retry: false,
    queryFn: async () => {
      try {
        return await api<{ address: Address; expiresAt: number }>("/v1/auth/session");
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) return null;
        throw e;
      }
    },
  });
}

export type InboxItem = { id: string; chainId: number; event: string; subject: string; body: string; url: string | null; createdAt: number; read: boolean };

export function useInbox(signedIn: boolean) {
  return useQuery({
    queryKey: ["inbox"],
    enabled: signedIn,
    refetchInterval: 30_000,
    queryFn: () => api<{ items: InboxItem[]; unread: number }>("/v1/me/inbox?limit=50"),
  });
}

export type Me = {
  address: Address;
  testnet: {
    attestedAt: number | null;
    allowlist: { status: string; txHash: string | null };
    allowlistChains: { chainId: number; status: string; txHash: string | null }[];
  };
};

export function useMe(signedIn: boolean) {
  return useQuery({
    queryKey: ["me"],
    enabled: signedIn,
    refetchInterval: (q) => (q.state.data?.testnet.allowlistChains.some((c) => c.status === "pending" || c.status === "sent") ? 10_000 : false),
    queryFn: () => api<Me>("/v1/me/notifications"),
  });
}
