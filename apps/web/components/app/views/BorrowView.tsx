"use client";

import { useState } from "react";
import { BorrowActions, borrowBlock } from "../actions";
import { GradientCard, H, KV, Note, PageHead, Pill, StatBlock, num, pct, usd } from "../ui";
import { ConnectNote, ErrorNote, LoanCard, Loading, STATE_TONE } from "./shared";
import { useBell, type NextClosure } from "@/lib/api";
import { useApp, type Loan } from "@/lib/app";
import { ticker, tokenLogo } from "@/lib/protocol";
import { et } from "@/lib/time";

function LoanSection({ loan: { p, m }, closure, owner }: { loan: Loan; closure: NextClosure | null; owner?: `0x${string}` }) {
  const bell = useBell(p, owner).data;
  const needs = bell?.status === "NEEDS_ACTION" && !p.covered;
  return (
    <section>
      <H right={<small>{num(p.tokens)} {ticker(m.symbol)} · {usd(p.value, 0)} collateral</small>}>{m.name} loan</H>
      <BorrowActions
        market={m}
        position={p}
        bell={bell}
        closure={closure}
        only={needs ? ["Repay", "Add collateral", "Gap Cover"] : ["Borrow", "Repay", "Add collateral", "Withdraw"]}
      >
        <LoanCard p={p} m={m} bell={bell} />
      </BorrowActions>
      {p.inAuction && (
        <div style={{ marginTop: 16 }}>
          <Note icon="gavel">This loan is in auction #{p.inAuction}. Only enough collateral is sold to bring it back to health 1.10.</Note>
        </div>
      )}
    </section>
  );
}

export function BorrowView() {
  const app = useApp();
  const debt = app.loans.reduce((a, l) => a + l.p.debt, 0);
  const open = new Set(app.loans.map((l) => l.m.marketId));
  const choices = app.markets.filter((m) => !open.has(m.marketId));
  const [pick, setPick] = useState<string | null>(null);
  const chosen = choices.find((m) => m.marketId === pick) ?? choices.find((m) => !borrowBlock(m)) ?? choices[0];
  const closure = app.closure;

  return (
    <>
      <PageHead
        title="Borrow"
        sub="Borrow against tokenized stocks. Weeknights need no action; before a risky close, each loan must reach the weekend-safe LTV or carry Gap Cover."
      />
      <div className="cx-grid">
        <div className="cx-col">
          {app.error && !app.markets.length ? (
            <ErrorNote error={app.error} />
          ) : !app.isConnected ? (
            <section>
              <H>Your loans</H>
              <ConnectNote>Connect a wallet to open a loan or manage the ones you have.</ConnectNote>
            </section>
          ) : app.loansLoading ? (
            <Loading what="Loading your loans" />
          ) : (
            app.loans.map((l) => <LoanSection key={l.p.marketId} loan={l} closure={closure} owner={app.address} />)
          )}
          {app.isConnected && chosen && (
            <section>
              <H right={<small>Add collateral, then borrow</small>}>Open a loan</H>
              <div className="cx-seg" role="group" aria-label="Market" style={{ marginBottom: 18 }}>
                {choices.map((m) => (
                  <button key={m.marketId} type="button" aria-pressed={m.marketId === chosen.marketId} onClick={() => setPick(m.marketId)}>
                    {ticker(m.symbol)}
                  </button>
                ))}
              </div>
              <BorrowActions key={chosen.marketId} market={chosen} closure={closure} only={["Add collateral", "Borrow"]}>
                <GradientCard
                  logo={tokenLogo(chosen.symbol)}
                  tag={ticker(chosen.symbol)}
                  big={chosen.price ? usd(chosen.price) : "No price yet"}
                  label={`Max LTV ${pct(chosen.maxLtvEffective, 0)} · ${chosen.loanSymbol}`}
                  value={`Borrow ${pct(chosen.borrowApr, 2)} APR`}
                  pill={<Pill tone={STATE_TONE[chosen.state]}>{chosen.state}</Pill>}
                />
              </BorrowActions>
            </section>
          )}
          <Note icon="card">
            <b>Treasury-fund loans</b> (TBILL, on Arbitrum Sepolia) borrow up to 90% of NAV. Their price barely moves, so the Bell
            almost never binds; if a loan ever falls under water it is closed through a settlement-solver auction.
          </Note>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Total debt" value={usd(debt, 0)} chip={`${app.loans.filter((l) => l.p.debt > 0).length} loans`} />
          {app.loans.length > 0 && (
            <div>
              <H>Health factor</H>
              <KV
                rows={app.loans.map(({ p, m }) => [
                  ticker(m.symbol),
                  p.hf === null ? "No debt" : `${num(p.hf)} · LTV ${pct(p.ltv, 1)}`,
                ])}
              />
            </div>
          )}
          <div>
            <H>At the reopen</H>
            <KV
              rows={[
                ["Reopen", et(closure?.reopenAt)],
                ["If health ≥ 1", "Nothing happens"],
                ["If under 1", "Queued for the batch auction"],
                ["Leave the queue", "Repay or add in the first 2 min"],
                ["Sold", "Only enough to reach 1.10"],
              ]}
            />
          </div>
        </aside>
      </div>
    </>
  );
}
