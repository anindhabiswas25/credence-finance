"use client";

import { ISeniorVaultAbi } from "@credence/sdk";
import { parseEventLogs, parseUnits } from "viem";
import { useAccount } from "wagmi";
import { ActionTile, Row, plain, units, type Spec } from "../actions";
import { ActivityList, Bar, GradientCard, H, KV, Note, PageHead, Pill, StatBlock, Waterfall, num, pct, usd } from "../ui";
import { ConnectNote, ErrorNote, NoActivity, StackSwitch, useActivityRows } from "./shared";
import { useVault } from "@/lib/api";
import { useLocalRecords } from "@/lib/activity";
import { usePoolChain, useRedeemRequests, useVaultChain } from "@/lib/chain";
import { STACKS, tokenLogo, type Stack } from "@/lib/protocol";

export function LendView({ stack }: { stack: Stack }) {
  const s = STACKS[stack];
  const { address, isConnected } = useAccount();
  const v = useVault(stack);
  const me = useVaultChain(stack, address);
  const pool = usePoolChain(stack, undefined);
  const activity = useActivityRows(address, `lend-${stack}`);
  const [reqs, saveReqs] = useLocalRecords<string>(`vault-req-${stack}`, address);
  const requests = useRedeemRequests(stack, reqs).filter((r) => r.req && !r.req.claimed);
  const vault = v.data;
  const loan = s.loanSymbol;
  const d = s.loanDecimals;
  const write = (functionName: string, args: readonly unknown[]) => ({ chainId: s.chainId, address: s.vault, abi: ISeniorVaultAbi, functionName, args });
  const cushion = pool.nav + (pool.reserve ?? 0);
  const apy = vault?.apy ?? 0;

  const specs: Spec[] = [
    {
      icon: "deposit",
      title: "Deposit",
      sub: "Earn senior interest",
      amount: `${pct(apy, 2)} APY`,
      dialog: {
        title: `Deposit ${loan}`,
        description: "Deposits earn the senior share of borrow interest and are never locked by the market clock.",
        fields: [
          {
            key: "a",
            unit: loan,
            quick: [
              { label: "100", value: "100" },
              { label: "500", value: "500" },
              { label: "Wallet", value: plain(me.wallet, 2) },
            ],
          },
        ],
        preview: (x) => [
          ["Wallet balance", `${num(me.wallet)} ${loan}`],
          ["Your new position", `${num(me.position + (x.a ?? 0))} ${loan}`],
          ["Est. yearly interest", `${num((me.position + (x.a ?? 0)) * apy)} ${loan}`],
          ["Protected by", `${num(cushion, 0)} ${loan} of first-loss capital`],
        ],
        confirm: "Deposit",
        hint: stack === "equity" ? "Test tUSDG comes from the Faucet page." : "Arbitrum Sepolia USDC comes from Circle's faucet (linked on the Faucet page).",
        plan: (x) => {
          const a = units(x.a, d);
          return {
            approve: { token: s.loanToken, spender: s.vault, amount: a },
            write: write("deposit", [a, address]),
            activity: { icon: "deposit", title: `Deposited ${loan}`, amount: `${num(Number(x.a))} ${loan}`, kind: `lend-${stack}` },
          };
        },
      },
    },
    {
      icon: "withdraw",
      title: "Withdraw",
      sub: "Any time liquidity allows",
      amount: `${num(me.position, 0)} ${loan}`,
      dialog: {
        title: `Withdraw ${loan}`,
        description: "Withdraw up to the vault's idle liquidity now; anything larger is queued and paid as borrowers repay.",
        fields: [
          {
            key: "a",
            unit: loan,
            quick: [
              { label: "Half", value: plain(me.position / 2, 2) },
              { label: "Max", value: plain(me.position, 6) },
            ],
          },
        ],
        preview: (x) => [
          ["Remaining position", `${num(Math.max(0, me.position - (x.a ?? 0)))} ${loan}`],
          ["Withdrawable now", `${num(me.maxWithdraw)} ${loan}`],
          ["Paid", (x.a ?? 0) <= me.maxWithdraw ? "Now, from idle liquidity" : "Queued, paid as borrowers repay"],
        ],
        confirm: "Withdraw",
        blocked: me.shares === 0n ? "You have no deposit in this vault." : null,
        plan: (x) => {
          const a = units(x.a, d);
          if (a <= me.maxWithdrawRaw) {
            return {
              write: write("withdraw", [a, address, address]),
              activity: { icon: "withdraw", title: `Withdrew ${loan}`, amount: `${num(Number(x.a))} ${loan}`, kind: `lend-${stack}` },
            };
          }
          // Larger than idle liquidity: queue a redemption for the matching shares (all of them for Max).
          const pos = parseUnits(plain(me.position, 6), d);
          const shares = a >= pos ? me.shares : (me.shares * a) / (pos || 1n);
          return {
            write: write("requestRedeem", [shares, address]),
            activity: { icon: "clock", title: `Queued ${loan} withdrawal`, amount: `${num(Number(x.a))} ${loan}`, kind: `lend-${stack}` },
          };
        },
        onDone: (r) => {
          const ids = parseEventLogs({ abi: ISeniorVaultAbi, logs: r.receipt.logs, eventName: "RedeemRequested" }).map((l) => l.args.id.toString());
          if (ids.length) saveReqs([...reqs, ...ids]);
        },
      },
    },
  ];

  return (
    <>
      <PageHead
        title="Lend"
        sub="Deposit into the Senior Vault and earn the senior share of borrow interest. You sit behind the Underwriter Pool and the protocol reserve, and the market clock never locks your deposit."
        right={<StackSwitch stack={stack} base="/app/lend" />}
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H right={<small>{s.chainName}</small>}>Senior Vault</H>
            <Row specs={specs}>
              <GradientCard
                logo={tokenLogo(loan)}
                tag={loan}
                big={isConnected ? `${num(me.position)} ${loan}` : "—"}
                label="Share price"
                value={vault ? vault.sharePrice.toFixed(4) : "—"}
                pill={<Pill>Never locked</Pill>}
              />
            </Row>
            {!isConnected && (
              <div style={{ marginTop: 18 }}>
                <ConnectNote>Connect a wallet to deposit and see your position.</ConnectNote>
              </div>
            )}
          </section>
          {requests.length > 0 && (
            <section>
              <H>Queued withdrawals</H>
              <div className="cx-row">
                {requests.map(({ id, req }) => (
                  <ActionTile
                    key={id}
                    spec={{
                      icon: req!.processed ? "cash" : "clock",
                      title: `Request #${id}`,
                      sub: req!.processed ? "Ready to claim" : "In the queue",
                      amount: req!.processed ? `${num(Number(req!.assets) / 10 ** d)} ${loan}` : `${num(Number(req!.shares) / 1e18)} sh`,
                      dialog: {
                        title: `Claim request #${id}`,
                        description: "Queued withdrawals are paid in order as borrowers repay; once processed, claim the funds here.",
                        preview: () => [
                          ["Status", req!.processed ? "Processed" : "Waiting for liquidity"],
                          ["Amount", req!.processed ? `${num(Number(req!.assets) / 10 ** d)} ${loan}` : "Set when processed"],
                        ],
                        confirm: "Claim",
                        blocked: req!.processed ? null : "This withdrawal is still in the queue. It is paid as borrowers repay.",
                        plan: () => ({
                          write: write("claimRedeem", [BigInt(id)]),
                          activity: { icon: "cash", title: `Claimed ${loan} withdrawal`, amount: `${num(Number(req!.assets) / 10 ** d)} ${loan}`, kind: `lend-${stack}` },
                        }),
                      },
                    }}
                  />
                ))}
              </div>
            </section>
          )}
          <section>
            <H>Vault</H>
            {v.error ? (
              <ErrorNote error={v.error} />
            ) : (
              <>
                <KV
                  rows={[
                    ["Total deposits", `${num(vault?.tvl ?? 0, 0)} ${loan}`],
                    ["Lent to borrowers", `${num(vault?.borrowed ?? 0, 0)} ${loan}`],
                    ["Idle, withdrawable now", `${num(vault?.idle ?? 0, 0)} ${loan}`],
                    ["Senior APY", pct(apy, 2)],
                    ["Your shares", isConnected ? num(me.sharesValue) : "—"],
                    ["Withdrawal queue", vault ? `${vault.queueLength} waiting` : "—"],
                  ]}
                />
                <div style={{ marginTop: 16 }}>
                  <div className="cx-page-sub" style={{ margin: "0 0 8px" }}>
                    Utilisation {vault?.tvl ? pct(vault.borrowed / vault.tvl, 0) : "0%"}
                  </div>
                  <Bar value={vault?.tvl ? vault.borrowed / vault.tvl : 0} />
                </div>
              </>
            )}
          </section>
          <section>
            <H>Recent activity</H>
            {activity.length ? <ActivityList items={activity} /> : <NoActivity />}
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock
            label="Your cushion"
            value={`${num(cushion, 0)} ${loan}`}
            chip={vault?.borrowed ? `${pct(cushion / vault.borrowed, 0)} of loans` : "No loans yet"}
          />
          <p className="cx-page-sub" style={{ margin: "-18px 0 0" }}>
            First-loss capital that absorbs any reopen shortfall before senior lenders lose anything.
          </p>
          <div>
            <H>Who pays first</H>
            <Waterfall
              layers={[
                { name: "Underwriter Pool", note: "Paid premiums to take first loss", amount: usd(pool.nav, 0), tone: "ink" },
                { name: "Protocol reserve", note: "Funded from fees and penalties", amount: usd(pool.reserve ?? 0, 0), tone: "tile" },
                { name: "Senior Vault", note: "You, only after both are used up", amount: usd(vault?.tvl ?? 0, 0), tone: "white" },
              ]}
            />
          </div>
          <Note icon="vault">
            Each chain has its own vault: tUSDG on Robinhood Chain lends to the stock markets, USDC on Arbitrum Sepolia to the
            Treasury-fund market.
          </Note>
        </aside>
      </div>
    </>
  );
}
