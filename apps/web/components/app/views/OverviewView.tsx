"use client";

import Link from "next/link";
import { BorrowActions } from "../actions";
import { ActivityList, Bar, H, KV, PageHead, StatBlock, StatRow, num, pct, usd } from "../ui";
import { ConnectNote, ErrorNote, LoanCard, Loading, NoActivity, NoLoans, useActivityRows } from "./shared";
import { useBell } from "@/lib/api";
import { useApp, type Loan } from "@/lib/app";
import { ticker } from "@/lib/protocol";
import { et } from "@/lib/time";

/** The loan that matters most before the Bell: past the safe LTV first, then the highest LTV. */
function focusOf(loans: Loan[]) {
  return [...loans]
    .filter((l) => l.p.debt > 0)
    .sort((a, b) => {
      const over = (l: Loan) => (l.m.safeLtv !== null && l.p.ltv > l.m.safeLtv ? 1 : 0);
      return over(b) - over(a) || b.p.ltv - a.p.ltv;
    })[0] ?? loans[0];
}

export function OverviewView() {
  const app = useApp();
  const focus = focusOf(app.loans);
  const bell = useBell(focus?.p, app.address).data;
  const activity = useActivityRows(app.address);
  const closure = app.closure;
  const total = app.loans.reduce((a, l) => a + l.p.value, 0);

  return (
    <>
      <PageHead
        title="Dashboard"
        sub={
          !closure
            ? "Reading the market clock…"
            : closure.inProgress
              ? `Markets closed since ${et(closure.closeAt)} · Reopen ${et(closure.reopenAt)}`
              : `Next closure: ${et(closure.closeAt)} · Bell deadline ${et(closure.bellDeadlineAt)}`
        }
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>Before the {closure ? closure.label.toLowerCase() : "next"} Bell</H>
            {app.error ? (
              <ErrorNote error={app.error} />
            ) : !app.isConnected ? (
              <ConnectNote>Connect a wallet to see your loans and what each one needs before the Bell.</ConnectNote>
            ) : app.loansLoading ? (
              <Loading what="Loading your loans" />
            ) : !focus ? (
              <NoLoans />
            ) : (
              <BorrowActions market={focus.m} position={focus.p} bell={bell} closure={closure} only={["Repay", "Gap Cover"]}>
                <LoanCard p={focus.p} m={focus.m} bell={bell} />
              </BorrowActions>
            )}
          </section>
          <section>
            <H right={<span className="cx-chip">Newest first</span>}>Recent activity</H>
            {activity.length ? <ActivityList items={activity.slice(0, 6)} /> : <NoActivity />}
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock
            label="Health factor"
            value={focus?.p.hf != null ? num(focus.p.hf) : "—"}
            chip={focus ? ticker(focus.m.symbol) : "No loan"}
          />
          {focus && (
            <div>
              <KV
                rows={[
                  ["LTV now", pct(focus.p.ltv, 1)],
                  ["Weekend-safe LTV", focus.m.safeLtv === null ? "—" : pct(focus.m.safeLtv, 1)],
                  ["Liquidation at", pct(focus.m.liqThreshold, 0)],
                ]}
              />
              <div style={{ marginTop: 14 }}>
                <Bar value={focus.m.liqThreshold ? focus.p.ltv / focus.m.liqThreshold : 0} />
              </div>
            </div>
          )}
          <div>
            <H right={<Link href="/app/borrow"><small>View all</small></Link>}>Your markets</H>
            {app.loans.length ? (
              <div className="cx-stat-rows">
                {app.loans.map(({ p, m }) => (
                  <StatRow
                    key={p.marketId}
                    big={num(p.value, 0)}
                    unit="USD"
                    sub={`${num(p.tokens)} ${ticker(m.symbol)}`}
                    tag={p.inAuction ? "In auction" : m.safeLtv !== null && p.ltv > m.safeLtv && !p.covered ? "Bell due" : "Safe"}
                  />
                ))}
              </div>
            ) : (
              <p className="cx-page-sub" style={{ margin: 0 }}>No collateral yet.</p>
            )}
          </div>
          <p className="cx-page-sub" style={{ margin: 0 }}>
            Total collateral {usd(total, 0)}
          </p>
        </aside>
      </div>
    </>
  );
}
