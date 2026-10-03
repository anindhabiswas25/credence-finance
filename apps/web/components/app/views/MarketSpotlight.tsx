"use client";

import Link from "next/link";
import { useEffect, useLayoutEffect, useRef } from "react";
import { Icon } from "../Icon";
import { Bar, CardMark, Pill, num, pct, usd } from "../ui";
import { STATE_TONE } from "./shared";
import type { Market, NextClosure } from "@/lib/api";
import { STACKS, shortAddress, ticker, tokenLogo } from "@/lib/protocol";
import { et } from "@/lib/time";

const CLOSURE: Record<string, string> = { OVERNIGHT: "Overnight", WEEKEND: "Weekend", HOLIDAY_WEEKEND: "Holiday weekend" };

function Group({ title, rows, children }: { title: string; rows: [string, React.ReactNode][]; children?: React.ReactNode }) {
  return (
    <section className="cx-spot-group">
      <h3>{title}</h3>
      <dl className="cx-kv">
        {rows.map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
      {children}
    </section>
  );
}

/**
 * One market, enlarged in the middle of the page: the card grown into a hero, with every figure
 * the details table used to show. Arrow keys (or the chevrons) step through the shown markets.
 */
export function MarketSpotlight({
  markets,
  index,
  closure,
  onIndex,
  onClose,
}: {
  markets: Market[];
  index: number | null;
  closure: NextClosure | null;
  onIndex: (i: number) => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const m = index === null ? undefined : markets[index];

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (m && !d.open) d.showModal();
    if (!m && d.open) d.close();
  }, [m]);

  useEffect(() => {
    if (index === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") onIndex((index + 1) % markets.length);
      if (e.key === "ArrowLeft") onIndex((index - 1 + markets.length) % markets.length);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [index, markets.length, onIndex]);

  // Safety net for very short screens: the CSS is sized to fit, and if the content is still
  // taller than the viewport it is scaled down so the spotlight never scrolls.
  const inner = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = inner.current;
    if (!m || !el) return;
    const fit = () => {
      el.style.setProperty("zoom", "1");
      const avail = window.innerHeight - 16;
      const h = el.getBoundingClientRect().height;
      el.style.setProperty("zoom", h > avail ? String(Math.max(0.6, avail / h)) : "1");
    };
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  }, [m]);

  const s = m ? STACKS[m.stack] : null;
  const nav = m?.kind === "Treasury fund";
  const closedNow = !!m?.nextClosure && m.nextClosure.closeAt <= Date.now() / 1000;

  return (
    <dialog
      ref={ref}
      className="cx-dialog cx-spotlight"
      aria-label={m ? `${ticker(m.symbol)} market` : "Market"}
      onClose={onClose}
      onClick={(e) => e.target === ref.current && ref.current?.close()}
    >
      {m && s && (
        <div className="cx-spot" key={m.marketId} ref={inner}>
          <div className="cx-spot-hero">
            <div className="cx-card-top">
              <CardMark logo={tokenLogo(m.symbol)} />
              <div className="cx-spot-tools">
                <button type="button" className="cx-icon-btn" aria-label="Previous market" onClick={() => onIndex((index! - 1 + markets.length) % markets.length)}>
                  <Icon name="chevron" size={18} strokeWidth={2} className="cx-rot-left" />
                </button>
                <button type="button" className="cx-icon-btn" aria-label="Next market" onClick={() => onIndex((index! + 1) % markets.length)}>
                  <Icon name="chevron" size={18} strokeWidth={2} className="cx-rot-right" />
                </button>
                <button type="button" className="cx-icon-btn" aria-label="Close" onClick={() => ref.current?.close()}>
                  <Icon name="close" size={18} strokeWidth={2} />
                </button>
              </div>
            </div>
            <div className="cx-spot-title">
              <span className="cx-spot-ticker">{ticker(m.symbol)}</span>
              <span className="cx-spot-name">{m.name}</span>
            </div>
            <div className="cx-spot-price">
              {m.price ? (nav ? `NAV ${usd(m.price, 4)}` : usd(m.price)) : "No price yet"}
            </div>
            {m.pause && <p className="cx-spot-pause">{m.pause.message}</p>}
            <div className="cx-card-foot">
              <div>
                <div className="cx-card-label">Borrow rate</div>
                <div className="cx-card-value">{pct(m.borrowApr, 2)} APR, variable</div>
              </div>
              <Pill tone={STATE_TONE[m.state]}>{m.state}</Pill>
            </div>
          </div>


          <div className="cx-spot-grid">
            <Group
              title="Lending"
              rows={[
                ["Supplied", `${num(m.supplied, 0)} ${m.loanSymbol}`],
                ["Borrowed", `${num(m.borrowed, 0)} ${m.loanSymbol}`],
                ["Available", `${num(m.liquidity, 0)} ${m.loanSymbol}`],
                ["Utilisation", pct(m.utilisation, 1)],
              ]}
            >
              <div className="cx-spot-use">
                <Bar value={m.utilisation} />
              </div>
            </Group>
            <Group
              title="Risk"
              rows={[
                ["Max LTV", m.maxLtvEffective < m.maxLtv ? `${pct(m.maxLtvEffective)} (cut from ${pct(m.maxLtv, 0)})` : pct(m.maxLtv, 0)],
                ["Weekend-safe LTV", m.safeLtv === null ? "—" : pct(m.safeLtv)],
                ["Liquidation threshold", pct(m.liqThreshold, 0)],
                ["σ next closure", pct(m.sigma)],
              ]}
            />
            <Group
              title="Market clock"
              rows={[
                ["Now", m.state],
                ["Next closure", m.nextClosure ? CLOSURE[m.nextClosure.type] ?? m.nextClosure.type : "—"],
                [closedNow ? "Closed since" : "Close", et(m.nextClosure?.closeAt)],
                ["Reopen", et(m.nextClosure?.reopenAt)],
              ]}
            />
            <Group
              title="On-chain"
              rows={[
                ["Network", s.chainName],
                ["Kind", m.kind],
                ["Collateral token", shortAddress(m.collateralToken)],
                [
                  "Gap Cover",
                  m.coverPaused ? "Paused" : nav ? "Not needed" : closure && !closure.inProgress ? `Until ${et(closure.bellDeadlineAt)}` : "Opens with the next Bell window",
                ],
              ]}
            />
          </div>

          <div className="cx-spot-cta">
            <Link href="/app/borrow" className="cx-btn">
              Borrow against {ticker(m.symbol)}
            </Link>
            <Link href={m.stack === "nav" ? "/app/lend?stack=nav" : "/app/lend"} className="cx-btn is-ghost">
              Lend {m.loanSymbol}
            </Link>
          </div>
        </div>
      )}
    </dialog>
  );
}
