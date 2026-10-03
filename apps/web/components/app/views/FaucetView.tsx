"use client";

import { IFaucetAbi } from "@credence/sdk";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { formatUnits, parseAbi, type Address } from "viem";
import { useAccount, useBalance, useReadContracts } from "wagmi";
import { ActionTile, ConnectFirst } from "../actions";
import { GradientCard, H, KV, Note, PageHead, Pill, StatBlock, num } from "../ui";
import { SignInGate } from "./AlertsView";
import { api, useMe } from "@/lib/api";
import { useNow } from "@/lib/app";
import { useTokenBalance } from "@/lib/chain";
import { STACKS, ticker, tokenLogo, type StackBook } from "@/lib/protocol";
import { useSiwe } from "@/lib/siwe";
import { until } from "@/lib/time";

const CanHoldAbi = parseAbi(["function canHold(address) view returns (bool)"]);
const ZERO = "0x0000000000000000000000000000000000000000" as Address;

type Tok = { symbol: string; address: Address; decimals: number };

const tokensOf = (s: StackBook): Tok[] => [
  { symbol: s.loanSymbol, address: s.loanToken, decimals: s.loanDecimals },
  ...Object.entries(s.markets)
    .filter(([, m]) => m.token)
    .map(([sym, m]) => ({ symbol: `t${sym}`, address: m.token!, decimals: 18 })),
];

function DripTile({ s, t, owner, now }: { s: StackBook; t: Tok; owner: Address | undefined; now: number }) {
  const bal = useTokenBalance(s.chainId, t.address, owner, t.decimals);
  const faucet = { chainId: s.chainId, address: s.faucet ?? ZERO, abi: IFaucetAbi } as const;
  const r = useReadContracts({
    contracts: [
      { ...faucet, functionName: "dripAmount", args: [t.address] },
      { ...faucet, functionName: "nextDripAt", args: [owner ?? ZERO, t.address] },
    ],
    query: { enabled: !!s.faucet, refetchInterval: 30_000 },
  });
  const amount = (r.data?.[0]?.result as bigint | undefined) ?? 0n;
  const next = Number((r.data?.[1]?.result as number | bigint | undefined) ?? 0);
  if (r.isSuccess && amount === 0n) return null; // not handed out by the faucet (e.g. the real Robinhood TSLA token)
  const wait = owner ? until(next, now) : null;
  const label = t.symbol.startsWith("t") && t.symbol !== s.loanSymbol ? `t${ticker(t.symbol.slice(1))}` : t.symbol;
  const per = num(Number(formatUnits(amount, t.decimals)), 0);
  return (
    <ActionTile
      spec={{
        icon: t.symbol === s.loanSymbol ? "cash" : "deposit",
        logo: tokenLogo(t.symbol),
        title: label,
        sub: `${per} per day`,
        amount: wait ? `In ${wait}` : owner ? `${num(bal.value)} held` : "Ready",
        dialog: {
          title: `Get ${label}`,
          description: `Test tokens on ${s.chainName}, with no value. One drip per token every 24 hours.`,
          preview: () => [
            ["You receive", `${per} ${label}`],
            ["Wallet balance", `${num(bal.value)} ${label}`],
            ["Next drip", wait ? `In ${wait}` : "Now"],
          ],
          confirm: `Get ${label}`,
          blocked: wait ? `You already used the faucet for ${label} today. Try again in ${wait}.` : null,
          plan: () => ({
            write: { chainId: s.chainId, address: s.faucet!, abi: IFaucetAbi, functionName: "drip", args: [t.address] },
            activity: { icon: "cash", title: `Faucet: ${label}`, amount: `${per} ${label}`, kind: "faucet" },
          }),
        },
      }}
    />
  );
}

export function FaucetView() {
  const { address, isConnected } = useAccount();
  const now = useNow(30_000);
  const siwe = useSiwe();
  const me = useMe(siwe.signedIn);
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);
  const eqGas = useBalance({ chainId: STACKS.equity.chainId, address, query: { enabled: !!address, refetchInterval: 30_000 } });
  const navGas = useBalance({ chainId: STACKS.nav.chainId, address, query: { enabled: !!address, refetchInterval: 30_000 } });
  const firstStock = Object.values(STACKS.equity.markets).find((m) => m.token)?.token ?? ZERO;
  const fund = Object.values(STACKS.nav.markets).find((m) => m.token)?.token ?? ZERO;
  const holds = useReadContracts({
    contracts: [
      { chainId: STACKS.equity.chainId, address: firstStock, abi: CanHoldAbi, functionName: "canHold", args: [address ?? ZERO] },
      { chainId: STACKS.nav.chainId, address: fund, abi: CanHoldAbi, functionName: "canHold", args: [address ?? ZERO] },
    ],
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const allowed = [holds.data?.[0]?.result === true, holds.data?.[1]?.result === true];
  const attest = useMutation({
    mutationFn: () => api("/v1/testnet/allowlist", { method: "POST", body: JSON.stringify({ attest: true }) }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["me"] }),
    onError: (e) => setErr(e instanceof Error ? e.message : String(e)),
  });
  const chainStatus = (id: number) => me.data?.testnet.allowlistChains.find((c) => c.chainId === id)?.status ?? null;
  const status = (i: 0 | 1, id: number) =>
    allowed[i] ? <Pill tone="good">Allowlisted</Pill> : chainStatus(id) ? <Pill tone="warn">{chainStatus(id)}</Pill> : <Pill tone="soft">Not yet</Pill>;
  const fully = allowed[0] && allowed[1];

  return (
    <>
      <PageHead
        title="Faucet"
        sub="Everything you need to try Credence on testnet: allowlist access for the test stock and fund tokens, then a daily drip of each."
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>1. Testnet access</H>
            <div className="cx-row">
              <GradientCard
                tag="ACCESS"
                big={!isConnected ? "Not connected" : fully ? "Allowlisted" : "Not yet"}
                label="Stock and fund tokens"
                value="Only allowlisted wallets can hold them"
                pill={fully ? <Pill tone="good">Ready</Pill> : <Pill>Step 1</Pill>}
              />
            </div>
            <div style={{ marginTop: 18, display: "grid", gap: 14, justifyItems: "start" }}>
              {!isConnected ? (
                <ConnectFirst label="Connect wallet" />
              ) : fully ? (
                <Note icon="shield">This wallet is allowlisted on both chains.</Note>
              ) : !siwe.signedIn ? (
                <SignInGate why="Sign in with your wallet (one signature, no transaction), then confirm you understand these are test assets." />
              ) : (
                <>
                  <Note icon="shield">
                    I understand Credence testnet uses test assets with no value. The ops wallet allowlists this address on both chains,
                    usually within a minute.
                  </Note>
                  <button
                    type="button"
                    className="cx-btn"
                    aria-disabled={attest.isPending || undefined}
                    onClick={() => {
                      setErr(null);
                      if (!attest.isPending) attest.mutate();
                    }}
                  >
                    {attest.isPending ? "Requesting…" : "Get testnet access"}
                  </button>
                  {err && <p className="cx-hint is-bad">{err}</p>}
                </>
              )}
            </div>
          </section>
          <section>
            <H right={<small>tUSDG and test stock tokens</small>}>2. {STACKS.equity.chainName}</H>
            {isConnected && !allowed[0] && <p className="cx-page-sub" style={{ margin: "0 0 14px" }}>Stock tokens need step 1 first; tUSDG works now.</p>}
            <div className="cx-row cx-row-even">
              {tokensOf(STACKS.equity).map((t) => (
                <DripTile key={t.address} s={STACKS.equity} t={t} owner={address} now={now} />
              ))}
            </div>
          </section>
          <section>
            <H right={<small>Test T-Bill fund</small>}>3. {STACKS.nav.chainName}</H>
            <div className="cx-row">
              {tokensOf(STACKS.nav).map((t) => (
                <DripTile key={t.address} s={STACKS.nav} t={t} owner={address} now={now} />
              ))}
            </div>
            <div style={{ marginTop: 16 }}>
              <Note icon="cash">
                The Treasury-fund market lends Circle&apos;s testnet USDC. Get it from{" "}
                <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" style={{ textDecoration: "underline" }}>
                  faucet.circle.com
                </a>{" "}
                (choose Arbitrum Sepolia).
              </Note>
            </div>
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Gas" value={eqGas.data ? `${num(Number(eqGas.data.formatted), 4)}` : "—"} chip="ETH · Robinhood" />
          <KV
            rows={[
              [`${STACKS.equity.chainName}`, eqGas.data ? `${num(Number(eqGas.data.formatted), 4)} ETH` : "—"],
              [`${STACKS.nav.chainName}`, navGas.data ? `${num(Number(navGas.data.formatted), 4)} ETH` : "—"],
            ]}
          />
          <div>
            <H>Allowlist</H>
            <KV
              rows={[
                [STACKS.equity.chainName, status(0, STACKS.equity.chainId)],
                [STACKS.nav.chainName, status(1, STACKS.nav.chainId)],
              ]}
            />
          </div>
          <Note icon="alert">Every transaction needs a little testnet ETH for gas on its chain. Each chain&apos;s public faucet hands it out.</Note>
        </aside>
      </div>
    </>
  );
}
