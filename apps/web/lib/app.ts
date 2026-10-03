"use client";
/** What most pages need at once: the connected wallet, every market, the next closure and the loans. */
import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { nextClosureOf, useMarkets, usePositions, type Market, type Position } from "./api";

export type Loan = { p: Position; m: Market };

export function useApp() {
  const { address, isConnected } = useAccount();
  const mk = useMarkets();
  const pos = usePositions(address);
  const loans: Loan[] = pos.positions
    .map((p) => ({ p, m: mk.byId[p.marketId.toLowerCase()]! }))
    .filter((l) => l.m);
  return {
    address,
    isConnected,
    ...mk,
    closure: nextClosureOf(mk.markets),
    loans,
    loansLoading: pos.isLoading,
  };
}

/** Unix seconds, ticking every `ms` (countdowns). */
export function useNow(ms = 1000) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}
