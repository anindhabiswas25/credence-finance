"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import type { ReactNode } from "react";
import { ConnectFirst } from "../actions";
import { GradientCard, Note, Pill, num, pct } from "../ui";
import type { Bell, Market, MarketState, Position } from "@/lib/api";
import { useActivity } from "@/lib/activity";
import { STACKS, explorerTx, ticker, tokenLogo, type Stack } from "@/lib/protocol";
import { local } from "@/lib/time";

export const STATE_TONE: Record<MarketState, "good" | "warn" | "bad" | "soft"> = {
  Open: "good",
  Extended: "warn",
  Closed: "soft",
  Reopen: "warn",
  Halted: "bad",
  "Corp. action": "bad",
};

/** Shown in place of wallet data before a wallet is connected. */
export function ConnectNote({ children }: { children: ReactNode }) {
  return (
    <div style={{ display: "grid", gap: 14, justifyItems: "start" }}>
      <Note icon="lock">{children}</Note>
      <ConnectFirst label="Connect wallet" />
    </div>
  );
}

export function Loading({ what = "Loading" }: { what?: string }) {
  return <p className="cx-page-sub" style={{ margin: 0 }}>{what}…</p>;
}

export function ErrorNote({ error }: { error: unknown }) {
  return (
    <Note icon="alert">
      Couldn&apos;t reach the Credence API ({error instanceof Error ? error.message : String(error)}). Is it running? The app
      retries on its own.
    </Note>
  );
}

/** The Bell pill for one loan. */
export function bellPill(p: Position, bell: Bell | null | undefined) {
  if (p.inAuction) return <Pill tone="bad">In auction</Pill>;
  if (p.covered || bell?.status === "COVERED") return <Pill tone="good">Covered</Pill>;
  if (bell?.status === "NEEDS_ACTION") return <Pill>Bell due</Pill>;
  return <Pill tone="good">Safe</Pill>;
}

/** The loan card from the mockup: debt, health factor and LTV, with the Bell pill. */
export function LoanCard({ p, m, bell }: { p: Position; m: Market; bell?: Bell | null }) {
  return (
    <GradientCard
      logo={tokenLogo(m.symbol)}
      tag={ticker(m.symbol)}
      big={`${num(p.debt)} ${m.loanSymbol}`}
      label="Health factor"
      value={`${p.hf === null ? "No debt" : num(p.hf)} · LTV ${pct(p.ltv, 1)}`}
      pill={bellPill(p, bell)}
    />
  );
}

/** This wallet's actions sent from this device, as activity rows with a link to each transaction. */
export function useActivityRows(address: string | undefined, kind?: string) {
  return useActivity(address, kind).map((a) => ({
    icon: a.icon,
    title: a.title,
    when: local(a.when),
    amount: a.amount,
    href: explorerTx(a.chainId, a.hash),
  }));
}

export function NoActivity() {
  return <Note icon="clock">Nothing yet. Every action you take from this device shows up here, with a link to the transaction.</Note>;
}

export function NoLoans() {
  return (
    <Note icon="card">
      You have no loans yet. <Link href="/app/borrow" style={{ textDecoration: "underline" }}>Open one on Borrow</Link> with test
      tokens from the <Link href="/app/faucet" style={{ textDecoration: "underline" }}>Faucet</Link>.
    </Note>
  );
}

/** Equity (Robinhood Chain, tUSDG) or NAV (Arbitrum Sepolia, USDC): each stack has its own vault and pool. */
export function StackSwitch({ stack, base }: { stack: Stack; base: string }) {
  const router = useRouter();
  return (
    <div className="cx-seg" role="group" aria-label="Stack">
      {(["equity", "nav"] as const).map((s) => (
        <button key={s} type="button" aria-pressed={s === stack} onClick={() => router.replace(s === "equity" ? base : `${base}?stack=nav`)}>
          {STACKS[s].chainName} · {STACKS[s].loanSymbol}
        </button>
      ))}
    </div>
  );
}
