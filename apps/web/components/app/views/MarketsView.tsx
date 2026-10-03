"use client";

import Link from "next/link";
import { useState } from "react";
import { GradientCard, H, KV, Note, PageHead, Pill, StatBlock, pct, usd } from "../ui";
import { MarketSpotlight } from "./MarketSpotlight";
import { ErrorNote, Loading, STATE_TONE } from "./shared";
import { useApp } from "@/lib/app";
import { ticker, tokenLogo } from "@/lib/protocol";
import { et } from "@/lib/time";

const CLOCK_LABEL: Record<string, string> = {
  REGULAR: "Regular hours",
  EXTENDED: "Extended hours",
  CLOSED: "Closed",
  REOPEN: "Reopening",
  HALTED: "Halted",
  CORP_ACTION: "Corporate action",
};

export function MarketsView({ q }: { q: string }) {
  const { markets, closure, isLoading, error } = useApp();
  const query = q.trim().toLowerCase();
  const shown = query
    ? markets.filter(
        (m) => m.symbol.toLowerCase().includes(query) || ticker(m.symbol).toLowerCase().includes(query) || m.name.toLowerCase().includes(query),
      )
    : markets;
  const supplied = markets.reduce((a, m) => a + m.supplied, 0);
  const borrowed = markets.reduce((a, m) => a + m.borrowed, 0);
  const [open, setOpen] = useState<number | null>(null);
  const equity = markets.find((m) => m.stack === "equity" && !m.pause) ?? markets.find((m) => m.stack === "equity");

  return (
    <>
      <PageHead
        title="Markets"
        sub="Isolated markets for tokenized stocks and a Treasury money fund. Every rule follows each asset's market clock."
        right={query ? <Link className="cx-chip" href="/app/markets">Clear “{q}” ×</Link> : undefined}
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H right={<small>{shown.length} of {markets.length} · tap a card for details</small>}>All markets</H>
            {error && !markets.length ? (
              <ErrorNote error={error} />
            ) : isLoading && !markets.length ? (
              <Loading what="Loading markets" />
            ) : shown.length === 0 ? (
              <Note icon="search">No market matches “{q}”. Try a ticker like NVDA or TBILL.</Note>
            ) : (
              <div className="cx-cards">
                {shown.map((m, i) => (
                  <button
                    key={m.marketId}
                    type="button"
                    className="cx-card-btn"
                    aria-label={`${ticker(m.symbol)} market details`}
                    onClick={() => setOpen(i)}
                  >
                  <GradientCard
                    logo={tokenLogo(m.symbol)}
                    tag={ticker(m.symbol)}
                    big={m.price ? (m.kind === "Treasury fund" ? `NAV ${usd(m.price, 4)}` : usd(m.price)) : "No price yet"}
                    label={`Max LTV ${pct(m.maxLtv, 0)} · Weekend-safe ${m.safeLtv === null ? "—" : pct(m.safeLtv)}`}
                    value={`Borrow ${pct(m.borrowApr, 2)} APR`}
                    pill={<Pill tone={STATE_TONE[m.state]}>{m.state}</Pill>}
                  />
                  </button>
                ))}
              </div>
            )}
          </section>
          {shown
            .filter((m) => m.pause)
            .slice(0, 3)
            .map((m) => (
              <Note key={m.marketId} icon="alert">
                <b>{ticker(m.symbol)}:</b> {m.pause!.message}
              </Note>
            ))}
        </div>
        <MarketSpotlight markets={shown} index={open} closure={closure} onIndex={setOpen} onClose={() => setOpen(null)} />
        <aside className="cx-aside">
          <StatBlock label="Total supplied" value={usd(supplied, 0)} chip="All markets" />
          <KV rows={[["Borrowed", usd(borrowed, 0)], ["Utilisation", supplied ? pct(borrowed / supplied, 0) : "—"]]} />
          <div>
            <H>Market clock</H>
            <KV
              rows={[
                [
                  "Now",
                  equity ? (
                    <Pill key="s" tone={STATE_TONE[equity.state]}>
                      {CLOCK_LABEL[equity.stateName] ?? equity.state}
                    </Pill>
                  ) : (
                    "—"
                  ),
                ],
                ...((closure?.inProgress
                  ? [["Closed since", et(closure.closeAt)]]
                  : [
                      ["Bell window", et(closure?.bellWindowAt)],
                      ["Bell deadline", et(closure?.bellDeadlineAt)],
                      ["Close", et(closure?.closeAt)],
                    ]) as [string, string][]),
                ["Reopen auction", et(closure?.reopenAt)],
              ]}
            />
          </div>
          <Note icon="lock">
            While a market is closed, nobody can be liquidated. A weekend price can lower collateral value, never raise it.
          </Note>
        </aside>
      </div>
    </>
  );
}
