"use client";

import { Bar, GradientCard, H, InfoTile, KV, PageHead, Pill, StatBlock, Waterfall, pct, usd } from "../ui";
import { ErrorNote, Loading } from "./shared";
import { useRisk, useVault } from "@/lib/api";
import { useApp } from "@/lib/app";
import { usePoolChain } from "@/lib/chain";
import { ASSET_SYMBOL, ticker } from "@/lib/protocol";

/** The build guide's product principles (§1.5); each one is enforced by a test. */
const PRINCIPLES: [string, string][] = [
  ["P1", "Nobody is liquidated while their asset is closed, halted or in a corporate action"],
  ["P2", "Repay and add collateral never fail, in any state"],
  ["P3", "Senior lenders lose only after the pool and reserve are used up"],
  ["P4", "A weekend price can lower collateral value, never raise it"],
  ["P5", "Being fastest earns nothing in any liquidation"],
  ["P6", "Every parameter and clearing price is on-chain"],
  ["P7", "Keepers are untrusted; every keeper action is checked on-chain"],
];

export function RiskView() {
  const { markets, isLoading, error } = useApp();
  const risk = useRisk();
  const eqPool = usePoolChain("equity", undefined);
  const navPool = usePoolChain("nav", undefined);
  const eqVault = useVault("equity").data;
  const navVault = useVault("nav").data;
  const loans = markets.reduce((a, m) => a + m.borrowed, 0);
  const poolNav = eqPool.nav + navPool.nav;
  const reserve = (eqPool.reserve ?? 0) + (navPool.reserve ?? 0);
  const senior = (eqVault?.tvl ?? 0) + (navVault?.tvl ?? 0);
  const firstLoss = poolNav + reserve;
  const maxSigma = Math.max(0.0001, ...markets.map((m) => m.sigma));
  const policies = Object.values(risk.byMarket).reduce((a, m) => a + m.policies, 0);
  const used = eqPool.utilisation ?? 0;

  return (
    <>
      <PageHead
        title="Risk"
        sub="Every parameter, safe LTV, premium and clearing price is public. This page reads them live so anyone can check how the protocol is protected."
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>Protocol</H>
            <div className="cx-row">
              <GradientCard
                tag="PROTOCOL"
                big={`${usd(loans, 0)} lent`}
                label="First-loss capital"
                value={`${usd(firstLoss, 0)}${loans ? ` (${pct(firstLoss / loans, 0)})` : ""}`}
                pill={<Pill tone="good">Live</Pill>}
              />
              <InfoTile icon="shield" title="Pool capacity" sub="Stock pool, this epoch" amount={eqPool.utilisation === null ? "No epoch" : pct(used, 1)} />
              <InfoTile icon="pie" title="Covered loans" sub="All time" amount={String(policies)} />
            </div>
          </section>
          <section>
            <H right={<small>σ from the sigma oracle; safe LTV from the on-chain scenario set</small>}>Weekend risk by market</H>
            {error && !markets.length ? (
              <ErrorNote error={error} />
            ) : isLoading && !markets.length ? (
              <Loading what="Loading markets" />
            ) : (
              <div className="cx-table-wrap">
                <table className="cx-table">
                  <thead>
                    <tr>
                      <th>Market</th>
                      <th style={{ minWidth: 150 }}>σ next closure</th>
                      <th className="is-num">Weekend-safe LTV</th>
                      <th className="is-num">Max LTV</th>
                      <th className="is-num">Liq. threshold</th>
                      <th className="is-num">Premiums</th>
                    </tr>
                  </thead>
                  <tbody>
                    {markets.map((m) => (
                      <tr key={m.marketId}>
                        <td data-label="Market" className="is-strong">{ticker(m.symbol)}</td>
                        <td data-label="σ next closure">
                          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                            <div style={{ flex: 1 }}>
                              <Bar value={m.sigma / maxSigma} />
                            </div>
                            <span style={{ width: 52, textAlign: "right" }}>{pct(m.sigma)}</span>
                          </div>
                        </td>
                        <td data-label="Weekend-safe LTV" className="is-num">{m.safeLtv === null ? "—" : pct(m.safeLtv)}</td>
                        <td data-label="Max LTV" className="is-num">{pct(m.maxLtv, 0)}</td>
                        <td data-label="Liq. threshold" className="is-num">{pct(m.liqThreshold, 0)}</td>
                        <td data-label="Premiums" className="is-num">{usd(risk.byMarket[m.marketId.toLowerCase()]?.premiums ?? 0)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          <section>
            <H>Guarantees</H>
            <KV list rows={PRINCIPLES.map(([id, text]) => [<b key={id}>{id}</b>, <span key={text} style={{ fontWeight: 400 }}>{text}</span>])} />
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Loss cover" value={usd(firstLoss, 0)} chip="Before seniors" />
          <div>
            <H>Loss waterfall</H>
            <Waterfall
              layers={[
                { name: "Underwriter Pool", note: "Takes every reopen loss first", amount: usd(poolNav, 0), tone: "ink" },
                { name: "Protocol reserve", note: "Pays only after the pool", amount: usd(reserve, 0), tone: "tile" },
                { name: "Senior Vault", note: "Last in line", amount: usd(senior, 0), tone: "white" },
              ]}
            />
          </div>
          <div>
            <H>Pool capacity</H>
            <p className="cx-page-sub" style={{ margin: "0 0 10px" }}>
              {eqPool.utilisation === null
                ? "No epoch is open; capacity is measured from the Bell window on."
                : `The stock pool's worst replayed closure uses ${pct(used, 1)} of its capacity. New cover stops when it is full.`}
            </p>
            <Bar value={used} />
          </div>
          {risk.auctions.length > 0 && (
            <div>
              <H>Clearing vs open</H>
              <KV
                rows={risk.auctions.slice(0, 6).map((a) => [
                  `${ticker(ASSET_SYMBOL[a.assetId.toLowerCase()] ?? "?")} #${a.auctionId}`,
                  a.pStarVsOpenPrint ? `${Number(a.pStarVsOpenPrint.percent).toFixed(2)}%` : "—",
                ])}
              />
            </div>
          )}
        </aside>
      </div>
    </>
  );
}
