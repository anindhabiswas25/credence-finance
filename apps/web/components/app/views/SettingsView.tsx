"use client";

import { ICredenceMarketAbi } from "@credence/sdk";
import { useState } from "react";
import { useAccount } from "wagmi";
import { H, KV, Note, PageHead, StatBlock } from "../ui";
import { ConnectNote } from "./shared";
import { useApp, type Loan } from "@/lib/app";
import { STACKS, ticker } from "@/lib/protocol";
import { humanError, useTx } from "@/lib/tx";

/** Auto-cover lives on-chain per loan; switching it sends `setAutoCover`. */
function AutoCover({ loan: { p, m } }: { loan: Loan }) {
  const { run } = useTx();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const toggle = async () => {
    setError(null);
    try {
      await run(
        {
          write: { chainId: m.chainId, address: STACKS[m.stack].market, abi: ICredenceMarketAbi, functionName: "setAutoCover", args: [m.marketId, !p.autoCover] },
          activity: { icon: "shield", title: `Auto-cover ${p.autoCover ? "off" : "on"} for ${ticker(m.symbol)}`, amount: "", kind: "borrow" },
        },
        setBusy,
      );
    } catch (e) {
      setError(humanError(e));
    } finally {
      setBusy(null);
    }
  };
  return (
    <div>
      <label className="cx-switch">
        <span>
          {ticker(m.symbol)} loan: auto-cover at the Bell deadline (premium added to debt){busy ? ` · ${busy}` : ""}
        </span>
        <input type="checkbox" role="switch" checked={p.autoCover} disabled={!!busy} onChange={toggle} />
      </label>
      {error && <p className="cx-hint is-bad">{error}</p>}
    </div>
  );
}

export function SettingsView() {
  const { chain } = useAccount();
  const app = useApp();
  return (
    <>
      <PageHead title="Settings" sub="How the app behaves for you. Loan settings live on-chain, per loan." />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>Loans</H>
            {!app.isConnected ? (
              <ConnectNote>Connect a wallet to change your loans&apos; settings.</ConnectNote>
            ) : app.loans.length === 0 ? (
              <p className="cx-page-sub" style={{ margin: 0 }}>Auto-cover is set per loan; open a loan on Borrow first.</p>
            ) : (
              <div style={{ display: "grid", gap: 16 }}>
                {app.loans.map((l) => (
                  <AutoCover key={l.p.marketId} loan={l} />
                ))}
              </div>
            )}
          </section>
          <Note icon="shield">
            With auto-cover off, a loan still above the weekend-safe LTV at the Bell deadline has just enough collateral sold in the
            15:45–16:00 batch to reach the safe LTV, at a 1% penalty instead of 3%.
          </Note>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Language" value="EN" chip="English" />
          <KV rows={[["Network", chain?.name ?? "Not connected"], ["Theme", "Light"], ["Time zone", "US Eastern (market time)"]]} />
        </aside>
      </div>
    </>
  );
}
