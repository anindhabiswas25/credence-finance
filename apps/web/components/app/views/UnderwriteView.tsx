"use client";

import { IUnderwriterPoolAbi } from "@credence/sdk";
import { parseEventLogs } from "viem";
import { useAccount } from "wagmi";
import { ActionTile, Row, plain, units, type Spec } from "../actions";
import { ActivityList, Bar, GradientCard, H, KV, LineChart, Note, PageHead, Pill, StatBlock, num, pct } from "../ui";
import { ConnectNote, ErrorNote, NoActivity, StackSwitch, useActivityRows } from "./shared";
import { usePoolApi, usePoolEpochs } from "@/lib/api";
import { useLocalRecords } from "@/lib/activity";
import { usePoolChain, usePoolTickets } from "@/lib/chain";
import { STACKS, tokenLogo, type Stack } from "@/lib/protocol";
import { et } from "@/lib/time";

const signed = (r: number) => `${r < 0 ? "−" : "+"}${Math.abs(r * 100).toFixed(2)}%`;

export function UnderwriteView({ stack }: { stack: Stack }) {
  const s = STACKS[stack];
  const { address, isConnected } = useAccount();
  const pool = usePoolChain(stack, address);
  const api = usePoolApi(stack).data;
  const epochs = usePoolEpochs(stack);
  const activity = useActivityRows(address, `pool-${stack}`);
  const [tickets, saveTickets] = useLocalRecords<string>(`pool-epochs-${stack}`, address);
  const claims = usePoolTickets(stack, address, tickets).filter((t) => t.depositPending || t.withdrawPending);
  const loan = s.loanSymbol;
  const d = s.loanDecimals;
  const ep = pool.epoch;
  const write = (functionName: string, args: readonly unknown[]) => ({ chainId: s.chainId, address: s.pool, abi: IUnderwriterPoolAbi, functionName, args });
  const remember = (ids: string[]) => {
    const fresh = ids.filter((id) => !tickets.includes(id));
    if (fresh.length) saveTickets([...tickets, ...fresh]);
  };

  const specs: Spec[] = [
    {
      icon: "deposit",
      title: "Deposit",
      sub: "Earn premiums & fees",
      amount: `${num(pool.wallet, 0)} ${loan}`,
      dialog: {
        title: "Deposit into the pool",
        description:
          "Your capital takes first loss at each reopen and earns every Gap Cover premium, a risk fee on all borrow interest, and a share of penalties.",
        fields: [
          {
            key: "a",
            unit: loan,
            quick: [
              { label: "100", value: "100" },
              { label: "500", value: "500" },
              { label: "Wallet", value: plain(pool.wallet, 2) },
            ],
          },
        ],
        preview: (x) => [
          ["Pool shares received", num((x.a ?? 0) / (pool.sharePrice || 1))],
          ["Counts from", ep ? `After epoch #${ep.epochId} (deposits queue from the Bell window on)` : "Now, at today's share price"],
          ["Your new position", `${num(pool.position + (x.a ?? 0))} ${loan}`],
        ],
        confirm: "Deposit",
        plan: (x) => {
          const a = units(x.a, d);
          return {
            approve: { token: s.loanToken, spender: s.pool, amount: a },
            write: write("deposit", [a, address]),
            activity: { icon: "deposit", title: `Deposited ${loan} into the pool`, amount: `${num(Number(x.a))} ${loan}`, kind: `pool-${stack}` },
          };
        },
        onDone: (r) =>
          remember(parseEventLogs({ abi: IUnderwriterPoolAbi, logs: r.receipt.logs, eventName: "DepositQueued" }).map((l) => l.args.epochId.toString())),
      },
    },
    {
      icon: "withdraw",
      title: "Request exit",
      sub: "Paid after the epoch",
      amount: `${num(pool.sharesNum, 0)} sh`,
      dialog: {
        title: "Request a withdrawal",
        description:
          "Requests are paid after the next epoch's reopen settles, at the post-closure share price. You can also sell pool shares on a DEX.",
        fields: [
          {
            key: "a",
            unit: "shares",
            quick: [
              { label: "Half", value: plain(pool.sharesNum / 2, 4) },
              { label: "All", value: plain(pool.sharesNum, 6) },
            ],
          },
        ],
        preview: (x) => [
          ["Shares to redeem", num(x.a ?? 0)],
          ["Value at today's price", `${num((x.a ?? 0) * pool.sharePrice)} ${loan}`],
          ["Paid", "After the next epoch settles"],
        ],
        confirm: "Request withdrawal",
        blocked: pool.shares === 0n ? "You hold no pool shares." : null,
        plan: (x) => {
          const want = units(x.a, 18, "a number of shares");
          const shares = want > pool.shares || plain(pool.sharesNum, 6) === x.a ? pool.shares : want;
          return {
            write: write("requestWithdraw", [shares]),
            activity: { icon: "clock", title: "Requested pool exit", amount: `${num(Number(x.a))} sh`, kind: `pool-${stack}` },
          };
        },
        onDone: (r) =>
          remember(parseEventLogs({ abi: IUnderwriterPoolAbi, logs: r.receipt.logs, eventName: "WithdrawRequested" }).map((l) => l.args.epochId.toString())),
      },
    },
  ];

  const history = epochs.data ?? [];
  const chart = history.filter((e) => e.sharePriceAfter !== null).slice(0, 6).reverse();
  const used = pool.utilisation ?? 0;

  return (
    <>
      <PageHead
        title="Underwrite"
        sub="Hold first-loss capital through each market closure. Every closure is an epoch: you earn the premiums for exactly the risk you carried, and take any reopen loss before senior lenders."
        right={<StackSwitch stack={stack} base="/app/underwrite" />}
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H right={<small>{s.chainName}</small>}>Underwriter Pool</H>
            <Row specs={specs}>
              <GradientCard
                logo={tokenLogo(loan)}
                tag="POOL"
                big={isConnected ? `${num(pool.position)} ${loan}` : "—"}
                label="Share price"
                value={pool.sharePrice.toFixed(4)}
                pill={<Pill>{pool.activeEpoch !== null ? `Epoch #${pool.activeEpoch}` : "Between epochs"}</Pill>}
              />
            </Row>
            {!isConnected && (
              <div style={{ marginTop: 18 }}>
                <ConnectNote>Connect a wallet to deposit and see your shares.</ConnectNote>
              </div>
            )}
          </section>
          {claims.length > 0 && (
            <section>
              <H>Your epoch requests</H>
              <div className="cx-row">
                {claims.map((t) => {
                  const isDeposit = t.depositPending;
                  return (
                    <ActionTile
                      key={t.epochId + (isDeposit ? "d" : "w")}
                      spec={{
                        icon: isDeposit ? "deposit" : "withdraw",
                        title: `Epoch #${t.epochId}`,
                        sub: t.settled ? "Ready to claim" : `Settles after ${et(t.reopenAt)}`,
                        amount: isDeposit ? `${num(t.deposit)} ${loan}` : `${num(t.withdrawShares)} sh`,
                        dialog: {
                          title: isDeposit ? `Claim shares from epoch #${t.epochId}` : `Claim exit from epoch #${t.epochId}`,
                          description: isDeposit
                            ? "Deposits made during an epoch are priced after it settles; claim the pool shares here."
                            : "Withdrawals are paid after the epoch settles, oldest first.",
                          preview: () => [
                            ["Epoch", `#${t.epochId}`],
                            ["Status", t.settled ? "Settled" : "Not settled yet"],
                          ],
                          confirm: "Claim",
                          blocked: t.settled ? null : "That epoch hasn't settled yet. Claims open after the reopen settles.",
                          plan: () => ({
                            write: write(isDeposit ? "claimDeposit" : "claimWithdraw", [BigInt(t.epochId)]),
                            activity: { icon: "cash", title: `Claimed epoch #${t.epochId}`, amount: isDeposit ? `${num(t.deposit)} ${loan}` : `${num(t.withdrawShares)} sh`, kind: `pool-${stack}` },
                          }),
                        },
                      }}
                    />
                  );
                })}
              </div>
            </section>
          )}
          <section>
            <H right={<small>{ep ? `Bell window ${et(ep.bellWindowAt)}` : "Opens at the next Bell window"}</small>}>This epoch</H>
            <KV
              rows={[
                ["Your shares", isConnected ? num(pool.sharesNum) : "—"],
                ["Covered positions", ep ? String(ep.policies) : "—"],
                ["Premiums written", ep ? `${num(Number(ep.premiums) / 10 ** d)} ${loan}` : "—"],
                ["Equity at risk", ep ? `${num(Number(ep.equityAtRisk) / 10 ** d, 0)} ${loan}` : "—"],
                ["Cover headroom", pool.headroom !== null ? `${num(pool.headroom, 0)} ${loan}` : "—"],
              ]}
            />
            <div style={{ marginTop: 18 }}>
              <div className="cx-page-sub" style={{ margin: "0 0 8px" }}>
                Capacity used {pct(used, 1)}. Cover sales stop when the pool is full.
              </div>
              <Bar value={used} />
            </div>
          </section>
          <section>
            <H>Past epochs</H>
            {epochs.error ? (
              <ErrorNote error={epochs.error} />
            ) : history.length === 0 ? (
              <Note icon="clock">No epoch has settled yet. The first one opens at the next Bell window and settles after the reopen.</Note>
            ) : (
              <div className="cx-table-wrap">
                <table className="cx-table">
                  <thead>
                    <tr>
                      <th>Epoch</th>
                      <th>Closure</th>
                      <th className="is-num">Premiums</th>
                      <th className="is-num">Losses</th>
                      <th className="is-num">Share price</th>
                    </tr>
                  </thead>
                  <tbody>
                    {history.map((e) => (
                      <tr key={e.id}>
                        <td data-label="Epoch" className="is-strong">#{e.id}</td>
                        <td data-label="Closure">{e.closeAt ? `${et(e.closeAt)} → ${et(e.reopenAt)}` : e.status}</td>
                        <td data-label="Premiums" className="is-num">{num(e.premiums)}</td>
                        <td data-label="Losses" className="is-num">{e.losses ? num(e.losses) : "None"}</td>
                        <td data-label="Share price" className="is-num" style={{ color: e.result !== null && e.result < 0 ? "var(--cx-bad)" : "var(--cx-good)" }}>
                          {e.result === null ? "Open" : signed(e.result)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </div>
        <aside className="cx-aside">
          <StatBlock label="Pool size" value={`${num(pool.nav, 0)} ${loan}`} chip={api ? `${num(api.premiums, 0)} premiums all time` : "All time"} />
          {chart.length >= 2 ? (
            <LineChart
              values={chart.map((e) => e.sharePriceAfter!)}
              labels={chart.map((e) => `#${e.id}`)}
              ticks={ticksFor(chart.map((e) => e.sharePriceAfter!))}
              highlight={chart.length - 1}
              tooltip={chart[chart.length - 1]!.sharePriceAfter!.toFixed(4)}
              tickLabel={(t) => t.toFixed(3)}
              ariaLabel="Underwriter Pool share price by epoch"
            />
          ) : (
            <p className="cx-page-sub" style={{ margin: 0 }}>The share-price chart appears once two epochs have settled.</p>
          )}
          <div>
            <H>Where returns come from</H>
            <KV
              rows={[
                ["Gap Cover premiums", "All of them"],
                ["Risk fee", "10% of borrow interest"],
                ["Liquidation penalties", "One-third"],
                ["Backstop resales", "Profit or loss"],
              ]}
            />
          </div>
          <div>
            <H>Recent activity</H>
            {activity.length ? <ActivityList compact items={activity.slice(0, 3)} /> : <NoActivity />}
          </div>
        </aside>
      </div>
    </>
  );
}

/** Four evenly spaced gridlines around the readings. */
export function ticksFor(values: number[]) {
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const pad = (hi - lo || Math.abs(hi) * 0.002 || 0.001) * 0.25;
  const a = lo - pad;
  const step = (hi + pad - a) / 3;
  return [a, a + step, a + 2 * step, a + 3 * step];
}

