"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useRef, useState, type ReactNode } from "react";
import { formatUnits, parseUnits } from "viem";
import { useAccount } from "wagmi";
import { ICredenceMarketAbi } from "@credence/sdk";
import { Icon } from "./Icon";
import type { Bell, Market, NextClosure, Position } from "@/lib/api";
import { STACKS, explorerTx, ticker } from "@/lib/protocol";
import { et } from "@/lib/time";
import { humanError, useTx, type TxPlan } from "@/lib/tx";

const usd = (n: number, d = 2) =>
  n.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: d, maximumFractionDigits: d });
const num = (n: number, d = 2) => n.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const pct = (n: number) => `${(n * 100).toFixed(2)}%`;
/** A number for an input box: no grouping, trimmed to `d` decimals, rounded down. */
export const plain = (n: number, d = 2) => (Math.floor(Math.max(0, n) * 10 ** d) / 10 ** d).toString();

export type Field = { key: string; unit: string; label?: string; initial?: string; quick?: { label: string; value: string }[] };

type RunResult = Awaited<ReturnType<ReturnType<typeof useTx>["run"]>>;

export type Spec = {
  icon: string;
  /** A token logo shown instead of the icon. */
  logo?: string | null;
  title: string;
  sub: string;
  amount: string;
  dialog: {
    title: string;
    description: ReactNode;
    /** Amount entry; omit for fixed-price actions like buying cover. */
    fields?: Field[];
    preview: (v: Record<string, number>) => [string, ReactNode][];
    /** Button label, e.g. "Repay". */
    confirm: string;
    /** Why this action can't run right now (shown instead of sending). */
    blocked?: string | null;
    hint?: ReactNode;
    /** Build the transaction from the raw inputs; throw an Error to show a validation message. */
    plan: (v: Record<string, string>) => TxPlan | Promise<TxPlan>;
    onDone?: (r: RunResult, v: Record<string, string>) => void;
  };
};

/** Parse a decimal input into token units, or throw a readable error. */
export function units(v: string | undefined, decimals: number, what = "an amount"): bigint {
  const s = (v ?? "").trim();
  if (!s || !/^\d*\.?\d*$/.test(s) || s === ".") throw new Error(`Enter ${what}.`);
  const u = parseUnits(s, decimals);
  if (u <= 0n) throw new Error(`Enter ${what} above zero.`);
  return u;
}

/** Connect first, then act. Keeps the mockup's "Connect wallet" button. */
export function ConnectFirst({ children, label = "Connect wallet to continue" }: { children?: ReactNode; label?: string }) {
  const { isConnected } = useAccount();
  if (isConnected) return <>{children}</>;
  return (
    <ConnectButton.Custom>
      {({ openConnectModal, mounted }) => (
        <button type="button" className="cx-btn" onClick={openConnectModal} disabled={!mounted}>
          <Icon name="lock" size={18} strokeWidth={1.9} /> {label}
        </button>
      )}
    </ConnectButton.Custom>
  );
}

export function ActionTile({ spec }: { spec: Spec }) {
  const ref = useRef<HTMLDialogElement>(null);
  const d = spec.dialog;
  const init = () => Object.fromEntries((d.fields ?? []).map((f) => [f.key, f.initial ?? ""]));
  const [values, setValues] = useState<Record<string, string>>(init);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ hash: string; chainId: number } | null>(null);
  const { run } = useTx();
  const nums = Object.fromEntries(Object.entries(values).map(([k, v]) => [k, Number(v) || 0]));
  const disabled = !!busy || !!d.blocked;

  const open = () => {
    setValues(init());
    setError(null);
    setDone(null);
    ref.current?.showModal();
  };

  const send = async () => {
    if (disabled) return;
    setError(null);
    setDone(null);
    try {
      const plan = await d.plan(values);
      setBusy("Preparing…");
      const r = await run(plan, setBusy);
      setDone({ hash: r.hash, chainId: plan.write.chainId });
      d.onDone?.(r, values);
    } catch (e) {
      setError(humanError(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <>
      <button type="button" className="cx-tile" onClick={open}>
        {spec.logo ? (
          <img className="cx-tile-logo" src={spec.logo} alt="" />
        ) : (
          <span className="cx-tile-icon">
            <Icon name={spec.icon} size={24} strokeWidth={1.9} />
          </span>
        )}
        <span className="cx-tile-title">{spec.title}</span>
        <span className="cx-tile-sub">{spec.sub}</span>
        <span className="cx-tile-amount">{spec.amount}</span>
      </button>
      <dialog ref={ref} className="cx-dialog" aria-label={d.title} onClick={(e) => e.target === ref.current && !busy && ref.current?.close()}>
        <form method="dialog" className="cx-dialog-body" onSubmit={(e) => e.preventDefault()}>
          <div className="cx-dialog-head">
            <div>
              <h2>{d.title}</h2>
              <p>{d.description}</p>
            </div>
            <button type="button" className="cx-icon-btn" aria-label="Close" onClick={() => ref.current?.close()}>
              <Icon name="close" size={18} strokeWidth={2} />
            </button>
          </div>
          {(d.fields ?? []).map((f) => (
            <div key={f.key} className="cx-field">
              {f.label && <span className="cx-field-label">{f.label}</span>}
              <label className="cx-amount">
                <span className="cx-sr">
                  {f.label ?? "Amount"} in {f.unit}
                </span>
                <input
                  inputMode="decimal"
                  value={values[f.key] ?? ""}
                  placeholder="0"
                  onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value.replace(/[^\d.]/g, "") }))}
                />
                <span>{f.unit}</span>
              </label>
              {f.quick && f.quick.length > 0 && (
                <div className="cx-quick">
                  {f.quick.map((q) => (
                    <button key={q.label} type="button" onClick={() => setValues((v) => ({ ...v, [f.key]: q.value }))}>
                      {q.label}
                    </button>
                  ))}
                </div>
              )}
            </div>
          ))}
          <dl className="cx-kv">
            {d.preview(nums).map(([k, v]) => (
              <div key={k}>
                <dt>{k}</dt>
                <dd>{v}</dd>
              </div>
            ))}
          </dl>
          <ConnectFirst>
            <button type="button" className="cx-btn" aria-disabled={disabled || undefined} onClick={send}>
              {busy ?? d.confirm}
            </button>
          </ConnectFirst>
          {error ? (
            <p className="cx-hint is-bad" role="alert">
              {error}
            </p>
          ) : done ? (
            <p className="cx-hint is-good" role="status">
              Done.{" "}
              <a href={explorerTx(done.chainId, done.hash)} target="_blank" rel="noreferrer">
                View transaction
              </a>
            </p>
          ) : d.blocked ? (
            <p className="cx-hint">{d.blocked}</p>
          ) : (
            d.hint && <p className="cx-hint">{d.hint}</p>
          )}
        </form>
      </dialog>
    </>
  );
}

/** The card with its action tiles beside it, as in the mockup; three or more tiles sit below it. */
export function Row({ children, specs }: { children?: ReactNode; specs: Spec[] }) {
  const tiles = specs.map((s) => <ActionTile key={s.title} spec={s} />);
  if (specs.length < 3) {
    return (
      <div className="cx-row">
        {children}
        {tiles}
      </div>
    );
  }
  return (
    <div className="cx-stack">
      {children && <div className="cx-row">{children}</div>}
      <div className="cx-row cx-row-even">{tiles}</div>
    </div>
  );
}

// ── Borrow ───────────────────────────────────────────────────────────────────────────────────────

/** Why new borrowing is unavailable in this market right now (never blocks repay or add). */
export function borrowBlock(m: Market): string | null {
  if (m.state === "Closed" || m.state === "Halted" || m.state === "Corp. action")
    return `Borrowing is paused while ${ticker(m.symbol)} is ${m.state.toLowerCase()}; you can still repay or add collateral.`;
  if (m.pause) return m.pause.message;
  return null;
}

const marketAddress = (m: Market) => STACKS[m.stack].market;

/**
 * The loan actions for one market: repay, add collateral, Gap Cover (the Bell choices), borrow and
 * withdraw collateral. `only` picks tiles by title, in that order; amounts come from the API's live
 * Bell figures.
 */
export function BorrowActions({
  market: m,
  position: p,
  bell,
  closure,
  only,
  children,
}: {
  market: Market;
  position?: Position;
  bell?: Bell | null;
  closure?: NextClosure | null;
  only?: string[];
  children?: ReactNode;
}) {
  const { address } = useAccount();
  const sym = ticker(m.symbol);
  const loan = m.loanSymbol;
  const debt = p?.debt ?? 0;
  const tokens = p?.tokens ?? 0;
  const id = m.marketId;
  const decimals = STACKS[m.stack].loanDecimals;
  const write = (functionName: string, args: readonly unknown[]) => ({
    chainId: m.chainId,
    address: marketAddress(m),
    abi: ICredenceMarketAbi,
    functionName,
    args,
  });
  const needs = bell?.status === "NEEDS_ACTION";

  const after = (newDebt: number, newTokens: number): [string, ReactNode][] => {
    const value = newTokens * m.price;
    const ltv = value > 0 ? newDebt / value : 0;
    const safe = bell?.safeLtv ?? m.safeLtv;
    return [
      ["New debt", `${num(Math.max(0, newDebt))} ${loan}`],
      ["New LTV", value > 0 ? pct(ltv) : "—"],
      ["Health factor", newDebt > 0 && value > 0 ? num((value * m.liqThreshold) / newDebt) : "No debt"],
      [
        `${closure?.label ?? "Next"} Bell`,
        safe === null || newDebt <= 0 ? "Nothing due" : ltv <= safe ? "Safe, no action needed" : `Still above ${pct(safe)}`,
      ],
    ];
  };

  const limit = Math.min(m.maxLtvEffective, p?.borrowLimitLtv || m.maxLtvEffective);
  const canBorrow = Math.max(0, tokens * m.price * limit - debt);
  const premium = bell?.premium ?? null;

  const specs: Record<string, Spec> = {
    Repay: {
      icon: "repay",
      title: "Repay",
      sub: needs ? "To weekend-safe LTV" : "Lower your debt",
      amount: `${num(needs ? bell!.repay : debt)} ${loan}`,
      dialog: {
        title: `Repay ${sym} loan`,
        description: "Repaying is always allowed, in any market state.",
        fields: [
          {
            key: "a",
            unit: loan,
            initial: plain(needs ? bell!.repay + 0.01 : debt, 2),
            quick: [
              ...(needs ? [{ label: "To safe LTV", value: plain(bell!.repay + 0.01, 2) }] : []),
              { label: "Half", value: plain(debt / 2, 2) },
              { label: "All", value: formatUnits(p?.debtRaw ?? 0n, decimals) },
            ],
          },
        ],
        preview: (v) => after(debt - (v.a ?? 0), tokens),
        confirm: "Repay",
        blocked: !p || p.borrowShares === 0n ? "This loan has no debt to repay." : null,
        plan: (v) => {
          const a = units(v.a, decimals);
          const all = !!p && a >= p.debtRaw;
          // Repaying everything goes by shares, so interest accrued since the last read leaves no dust.
          return {
            approve: { token: m.loanToken, spender: marketAddress(m), amount: all ? (p!.debtRaw * 1002n) / 1000n + 1n : a },
            write: write("repay", all ? [id, address, 0n, p!.borrowShares] : [id, address, a, 0n]),
            activity: { icon: "repay", title: `Repaid ${sym} loan`, amount: `${num(Number(v.a))} ${loan}`, kind: "borrow" },
          };
        },
      },
    },
    "Add collateral": {
      icon: "plus",
      title: "Add collateral",
      sub: needs && bell!.add > 0 ? `${sym} to safe LTV` : `Deposit ${sym}`,
      amount: needs && bell!.add > 0 ? `${num(bell!.add)} ${sym}` : `${num(tokens)} ${sym} in`,
      dialog: {
        title: `Add ${sym}`,
        description: "Adding collateral is always allowed, in any market state.",
        fields: [
          {
            key: "a",
            unit: sym,
            initial: needs && bell!.add > 0 ? plain(bell!.add * 1.001, 4) : "",
            quick: needs && bell!.add > 0 ? [{ label: "To safe LTV", value: plain(bell!.add * 1.001, 4) }] : [],
          },
        ],
        preview: (v) => after(debt, tokens + (v.a ?? 0)),
        confirm: "Add collateral",
        hint: <>Test {sym} tokens come from the Faucet page.</>,
        plan: (v) => {
          const a = units(v.a, 18);
          return {
            approve: { token: m.collateralToken, spender: marketAddress(m), amount: a },
            write: write("addCollateral", [id, address, a]),
            activity: { icon: "deposit", title: `Deposited ${sym}`, amount: `${num(Number(v.a))} ${sym}`, kind: "borrow" },
          };
        },
      },
    },
    "Gap Cover": {
      icon: "shield",
      title: "Gap Cover",
      sub: "Keep your leverage",
      amount: premium !== null ? `${num(premium)} ${loan}` : p?.covered ? "Covered" : "Not needed",
      dialog: {
        title: `Gap Cover for ${sym}`,
        description:
          "Gap Cover lets you keep your LTV through this closure, and exempts you from overnight emergency liquidation. A covered loan can still be partly liquidated at the reopen.",
        preview: () => [
          ["Premium", premium !== null ? `${num(premium)} ${loan}` : "—"],
          ["Covers", bell ? `Closure #${bell.closureId}, ${et(bell.closeAt)} → ${et(bell.reopenAt)}` : "—"],
          ["Buy before", closure ? et(closure.bellDeadlineAt) : "The Bell deadline"],
          ["Refunds", "None, even if you repay later"],
        ],
        confirm: "Buy Gap Cover",
        blocked: p?.covered
          ? "This loan is already covered for the next closure."
          : m.coverPaused
            ? "Gap Cover sales are paused for this market right now."
            : !needs || !bell?.premiumRaw
              ? "No cover needed: this loan is already at or below the weekend-safe LTV."
              : null,
        plan: () => {
          // 5% headroom over the quote; the contract charges the live premium, never more than this.
          const max = (bell!.premiumRaw! * 105n) / 100n + 1n;
          return {
            approve: { token: m.loanToken, spender: marketAddress(m), amount: max },
            write: write("buyCover", [id, max, false]),
            activity: { icon: "shield", title: `Gap Cover bought for ${sym}`, amount: `${num(premium ?? 0)} ${loan}`, kind: "borrow" },
          };
        },
      },
    },
    Borrow: {
      icon: "cash",
      title: "Borrow",
      sub: "Up to your limit",
      amount: `${num(canBorrow, 0)} ${loan}`,
      dialog: {
        title: `Borrow ${loan} against ${sym}`,
        description: `Limit ${pct(limit)} LTV at ${usd(m.price)} per ${sym}. Rate ${pct(m.borrowApr)} APR, variable.`,
        fields: [
          {
            key: "a",
            unit: loan,
            quick: [
              { label: "Half", value: plain(canBorrow / 2, 2) },
              { label: "Max", value: plain(canBorrow * 0.995, 2) },
            ],
          },
        ],
        preview: (v) => [...after(debt + (v.a ?? 0), tokens), ["Available in market", `${num(m.liquidity, 0)} ${loan}`]],
        confirm: "Borrow",
        blocked: borrowBlock(m) ?? (tokens <= 0 ? `Add ${sym} as collateral first.` : null),
        plan: (v) => {
          const a = units(v.a, decimals);
          return {
            write: write("borrow", [id, a, address]),
            activity: { icon: "cash", title: `Borrowed against ${sym}`, amount: `${num(Number(v.a))} ${loan}`, kind: "borrow" },
          };
        },
      },
    },
    Withdraw: {
      icon: "withdraw",
      title: "Withdraw",
      sub: `${sym} collateral`,
      amount: `${num(tokens)} ${sym}`,
      dialog: {
        title: `Withdraw ${sym}`,
        description: "Take collateral back while your LTV stays within the limit that applies right now.",
        fields: [{ key: "a", unit: sym, quick: debt <= 0 ? [{ label: "All", value: formatUnits(p?.collateralRaw ?? 0n, 18) }] : [] }],
        preview: (v) => after(debt, tokens - (v.a ?? 0)),
        confirm: "Withdraw",
        blocked: tokens <= 0 ? "There is no collateral in this loan." : null,
        plan: (v) => {
          const a = units(v.a, 18);
          return {
            write: write("withdrawCollateral", [id, a, address]),
            activity: { icon: "withdraw", title: `Withdrew ${sym}`, amount: `${num(Number(v.a))} ${sym}`, kind: "borrow" },
          };
        },
      },
    },
  };
  const titles = only ?? ["Repay", "Add collateral", "Gap Cover"];
  return <Row specs={titles.map((t) => specs[t]!).filter(Boolean)}>{children}</Row>;
}
