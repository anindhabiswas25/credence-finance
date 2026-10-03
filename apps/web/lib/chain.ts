"use client";
/**
 * Live contract reads through wagmi, for what the API doesn't serve per wallet (vault and pool
 * shares, wallet balances) or hasn't indexed yet (a pool before its first epoch).
 */
import { ISeniorVaultAbi, IUnderwriterPoolAbi } from "@credence/sdk";
import { erc20Abi, formatUnits, parseAbi, type Address } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { STACKS, type Stack } from "./protocol";

const f = (v: bigint | undefined, d: number) => (v === undefined ? 0 : Number(formatUnits(v, d)));
const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const ReserveAbi = parseAbi(["function balance() view returns (uint256)"]);

/** The wallet's balance of one token on one chain. */
export function useTokenBalance(chainId: number, token: Address | null | undefined, owner: Address | undefined, decimals = 18) {
  const r = useReadContract({
    chainId,
    address: token ?? ZERO,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [owner ?? ZERO],
    query: { enabled: !!owner && !!token, refetchInterval: 15_000 },
  });
  return { raw: r.data ?? 0n, value: f(r.data, decimals), refetch: r.refetch };
}

export function useVaultChain(stack: Stack, owner: Address | undefined) {
  const s = STACKS[stack];
  const vault = { chainId: s.chainId, address: s.vault, abi: ISeniorVaultAbi } as const;
  const who = owner ?? ZERO;
  const r = useReadContracts({
    contracts: [
      { ...vault, functionName: "balanceOf", args: [who] },
      { ...vault, functionName: "maxWithdraw", args: [who] },
      { ...vault, functionName: "decimals" },
      { chainId: s.chainId, address: s.loanToken, abi: erc20Abi, functionName: "balanceOf", args: [who] },
    ],
    query: { enabled: !!owner, refetchInterval: 15_000 },
  });
  const [bal, maxW, dec, wallet] = r.data ?? [];
  const shares = (bal?.result as bigint | undefined) ?? 0n;
  const sharesDecimals = Number(dec?.result ?? 18);
  const assets = useReadContract({
    ...vault,
    functionName: "convertToAssets",
    args: [shares],
    query: { enabled: shares > 0n, refetchInterval: 15_000 },
  });
  return {
    shares,
    sharesValue: f(shares, sharesDecimals),
    position: f(assets.data as bigint | undefined, s.loanDecimals),
    maxWithdraw: f(maxW?.result as bigint | undefined, s.loanDecimals),
    maxWithdrawRaw: (maxW?.result as bigint | undefined) ?? 0n,
    wallet: f(wallet?.result as bigint | undefined, s.loanDecimals),
    isLoading: r.isLoading,
  };
}

export type RedeemRequest = { owner: Address; receiver: Address; shares: bigint; assets: bigint; processed: boolean; claimed: boolean };

export function useRedeemRequests(stack: Stack, ids: string[]) {
  const s = STACKS[stack];
  const r = useReadContracts({
    contracts: ids.map((id) => ({ chainId: s.chainId, address: s.vault, abi: ISeniorVaultAbi, functionName: "redeemRequest", args: [BigInt(id)] }) as const),
    query: { enabled: ids.length > 0, refetchInterval: 20_000 },
  });
  return ids.map((id, i) => ({ id, req: r.data?.[i]?.result as RedeemRequest | undefined }));
}

export type PoolEpoch = {
  epochId: bigint;
  bellWindowAt: number;
  bellAt: number;
  closeAt: number;
  reopenAt: number;
  phase: number;
  policies: number;
  premiums: bigint;
  equityAtRisk: bigint;
};

export function usePoolChain(stack: Stack, owner: Address | undefined) {
  const s = STACKS[stack];
  const pool = { chainId: s.chainId, address: s.pool, abi: IUnderwriterPoolAbi } as const;
  const who = owner ?? ZERO;
  const r = useReadContracts({
    contracts: [
      { ...pool, functionName: "nav" },
      { ...pool, functionName: "totalSupply" },
      { ...pool, functionName: "activeEpoch" },
      { ...pool, functionName: "balanceOf", args: [who] },
      { chainId: s.chainId, address: s.loanToken, abi: erc20Abi, functionName: "balanceOf", args: [who] },
      { ...pool, functionName: "freeCash" },
      { chainId: s.chainId, address: s.reserve ?? ZERO, abi: ReserveAbi, functionName: "balance" },
    ],
    query: { refetchInterval: 20_000 },
  });
  const [nav, supply, active, bal, wallet, free, reserve] = r.data ?? [];
  const navRaw = (nav?.result as bigint | undefined) ?? 0n;
  const supplyRaw = (supply?.result as bigint | undefined) ?? 0n;
  const shares = (bal?.result as bigint | undefined) ?? 0n;
  const [epochId, exists] = (active?.result as readonly [bigint, boolean] | undefined) ?? [0n, false];
  const ep = useReadContracts({
    contracts: [
      { ...pool, functionName: "epoch", args: [epochId] },
      { ...pool, functionName: "utilisation", args: [epochId] },
      { ...pool, functionName: "capacityHeadroom", args: [epochId] },
    ],
    query: { enabled: exists, refetchInterval: 20_000 },
  });
  const [e, u, head] = ep.data ?? [];
  const d = s.loanDecimals;
  const navNum = f(navRaw, d);
  const supplyNum = f(supplyRaw, 18);
  return {
    nav: navNum,
    sharePrice: supplyNum > 0 ? navNum / supplyNum : 1,
    shares,
    sharesNum: f(shares, 18),
    position: supplyRaw > 0n ? f((shares * navRaw) / supplyRaw, d) : 0,
    wallet: f(wallet?.result as bigint | undefined, d),
    freeCash: f(free?.result as bigint | undefined, d),
    reserve: s.reserve ? f(reserve?.result as bigint | undefined, d) : null,
    activeEpoch: exists ? epochId : null,
    epoch: exists ? (e?.result as PoolEpoch | undefined) ?? null : null,
    utilisation: exists && u?.result !== undefined ? f(u.result as bigint, 18) : null,
    headroom: exists && head?.result !== undefined ? f(head.result as bigint, d) : null,
    isLoading: r.isLoading,
  };
}

/** Claimable deposit tickets and withdrawal requests for the epochs this wallet used. */
export function usePoolTickets(stack: Stack, owner: Address | undefined, epochIds: string[]) {
  const s = STACKS[stack];
  const pool = { chainId: s.chainId, address: s.pool, abi: IUnderwriterPoolAbi } as const;
  const who = owner ?? ZERO;
  const r = useReadContracts({
    contracts: epochIds.flatMap((id) => [
      { ...pool, functionName: "pendingDeposit", args: [BigInt(id), who] } as const,
      { ...pool, functionName: "pendingWithdraw", args: [BigInt(id), who] } as const,
      { ...pool, functionName: "epoch", args: [BigInt(id)] } as const,
    ]),
    query: { enabled: !!owner && epochIds.length > 0, refetchInterval: 20_000 },
  });
  return epochIds.map((id, i) => {
    const dep = r.data?.[i * 3]?.result as bigint | undefined;
    const wd = r.data?.[i * 3 + 1]?.result as readonly [bigint, bigint] | undefined;
    const ep = r.data?.[i * 3 + 2]?.result as PoolEpoch | undefined;
    return {
      epochId: id,
      deposit: f(dep, s.loanDecimals),
      withdrawShares: wd ? f(wd[0], 18) : 0,
      withdrawPending: !!wd && wd[0] > 0n,
      depositPending: !!dep && dep > 0n,
      settled: ep?.phase === EPOCH_SETTLED,
      reopenAt: ep?.reopenAt ?? 0,
    };
  });
}

/** EpochPhase in Types.sol: NONE, OPEN, SNAPSHOT, SETTLED. */
const EPOCH_SETTLED = 3;
