"use client";

import { IAuctionHouseAbi } from "@credence/sdk";
import { useRef } from "react";
import { encodeAbiParameters, formatUnits, keccak256, toHex, type Address, type Hex } from "viem";
import { useAccount } from "wagmi";
import { Row, units, type Spec } from "../actions";
import { GradientCard, H, KV, Note, PageHead, Pill, StatBlock, num, pct, usd } from "../ui";
import { ErrorNote } from "./shared";
import { useAuctionDetails, useAuctions, useSettlements, type Auction } from "@/lib/api";
import { useLocalRecords } from "@/lib/activity";
import { useApp, useNow } from "@/lib/app";
import { ASSET_SYMBOL, MARKET_INDEX, STACKS, ticker, tokenLogo } from "@/lib/protocol";
import { et, until } from "@/lib/time";

/** A sealed bid kept on this device: the salt is the only way to reveal it. */
type SavedBid = { auctionId: string; qty: string; price: string; salt: Hex; at: number };

const E = STACKS.equity;
const sym = (a: { assetId: string }) => ticker(ASSET_SYMBOL[a.assetId.toLowerCase()] ?? "?");
const wadNum = (s: string | null | undefined) => (s ? Number(formatUnits(BigInt(s), 18)) : 0);
/** qty (18 dp tokens) × price (WAD USD) → loan-token units (6 dp), rounded up like the contract. */
const notional = (qty: bigint, price: bigint) => {
  const den = 10n ** 18n * 10n ** BigInt(18 - E.loanDecimals);
  return (qty * price + den - 1n) / den;
};

function phase(a: Auction, now: number): "commit" | "reveal" | "open" | "queue" | "done" {
  const { biddingStartAt: s, biddingEndAt: e, clearAt: c } = a.deadlines;
  if (a.status === "cleared" || a.status === "settled") return "done";
  if (a.status === "queue" || !s || !e) return "queue";
  if (a.kind.name === "REOPEN") {
    if (now >= s && now < e) return "commit";
    if (c && now >= e && now < c) return "reveal";
    return now < s ? "queue" : "done";
  }
  return now >= s && now < e ? "open" : now < s ? "queue" : "done";
}

function download(name: string, data: unknown) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: name });
  a.click();
  URL.revokeObjectURL(url);
}

export function AuctionsView() {
  const { address } = useAccount();
  const { closure } = useApp();
  const now = useNow(1000);
  const list = useAuctions();
  const settlements = useSettlements();
  const [saved, save] = useLocalRecords<SavedBid>("bids", address);
  const latest = useRef<SavedBid[]>(saved);
  const auctions = list.data ?? [];
  const details = useAuctionDetails(saved.map((b) => b.auctionId));
  const commitLot = auctions.find((a) => phase(a, now) === "commit");
  const openLot = auctions.find((a) => phase(a, now) === "open");
  const toReveal = saved.find((b) => {
    const a = auctions.find((x) => x.auctionId === b.auctionId);
    const mine = details.find((d) => d.data?.auctionId === b.auctionId)?.data?.bidList.find((x) => x.bidder.toLowerCase() === address?.toLowerCase());
    return a && phase(a, now) === "reveal" && mine?.status !== "revealed";
  });
  const claimable = saved.filter((b) => {
    const d = details.find((x) => x.data?.auctionId === b.auctionId)?.data;
    const mine = d?.bidList.find((x) => x.bidder.toLowerCase() === address?.toLowerCase());
    return d && (d.status === "cleared" || d.status === "settled") && mine && mine.status !== "claimed";
  });
  const write = (functionName: string, args: readonly unknown[]) => ({ chainId: E.chainId, address: E.auctionHouse!, abi: IAuctionHouseAbi, functionName, args });
  const lotLabel = (a: Auction) => `${sym(a)} lot #${a.auctionId}`;
  const priceFields = (a: Auction | undefined) => [
    { key: "q", unit: a ? sym(a) : "tokens", label: "Quantity", quick: a?.lot ? [{ label: "Whole lot", value: formatUnits(BigInt(a.lot), 18) }] : [] },
    { key: "p", unit: "USD each", label: "Price", quick: a?.reserve ? [{ label: "Reserve", value: wadNum(a.reserve).toFixed(2) }] : [] },
  ];

  const specs: Spec[] = [
    {
      icon: "gavel",
      title: "Commit bid",
      sub: "Sealed, uniform price",
      amount: commitLot ? `Ends in ${until(commitLot.deadlines.biddingEndAt, now)}` : closure ? et(closure.reopenAt).split(",")[0]! : "—",
      dialog: {
        title: commitLot ? `Commit a sealed bid · ${lotLabel(commitLot)}` : "Commit a sealed bid",
        description: "Bids are hidden until reveal, and every winner pays the same clearing price. Your bond is 10% of the maximum you might spend.",
        fields: priceFields(commitLot),
        preview: (v) => [
          ["Max spend", usd((v.q ?? 0) * (v.p ?? 0))],
          ["Bond now", usd((v.q ?? 0) * (v.p ?? 0) * 0.1)],
          ["Lot", commitLot ? `${num(wadNum(commitLot.lot))} ${sym(commitLot)}` : "—"],
          ["Reserve price", commitLot?.reserve ? usd(wadNum(commitLot.reserve)) : "97% of the open"],
          ["Reveal window", commitLot ? `${et(commitLot.deadlines.biddingEndAt)} → ${et(commitLot.deadlines.clearAt)}` : "Reopen +5:00 → +7:00"],
          ["If you don't reveal", "The bond goes to the Underwriter Pool"],
        ],
        confirm: "Commit bid",
        blocked: !commitLot ? "No lot is open for sealed bids. Lots are fixed at the open +2:00 after a closure, if any loan is under water." : null,
        hint: "Your salt is saved on this device; download the backup after committing. Without it the bid can't be revealed.",
        plan: (v) => {
          const qty = units(v.q, 18, "a quantity");
          const price = units(v.p, 18, "a price");
          const salt = keccak256(toHex(crypto.getRandomValues(new Uint8Array(32))));
          const commitment = keccak256(
            encodeAbiParameters(
              [{ type: "uint256" }, { type: "address" }, { type: "uint64" }, { type: "address" }, { type: "uint128" }, { type: "uint128" }, { type: "bytes32" }],
              [BigInt(E.chainId), E.auctionHouse!, BigInt(commitLot!.auctionId), address as Address, qty, price, salt],
            ),
          );
          const max = notional(qty, price);
          // Saved before sending, so a closed tab can't lose the salt.
          latest.current = [{ auctionId: commitLot!.auctionId, qty: qty.toString(), price: price.toString(), salt, at: Date.now() }, ...saved];
          save(latest.current);
          return {
            approve: { token: E.loanToken, spender: E.auctionHouse!, amount: max },
            write: write("commitBid", [BigInt(commitLot!.auctionId), commitment, max]),
            activity: { icon: "gavel", title: `Sealed bid on ${lotLabel(commitLot!)}`, amount: `${v.q} @ ${usd(Number(v.p))}`, kind: "auction" },
          };
        },
        onDone: () => download(`credence-bids-${address}.json`, latest.current),
      },
    },
    {
      icon: "clock",
      title: "Reveal",
      sub: "After the commit window",
      amount: toReveal ? `Lot #${toReveal.auctionId}` : "None due",
      dialog: {
        title: "Reveal your bid",
        description: "Reveal the quantity, price and salt you committed, and escrow full payment. Unfilled amounts and bonds are returned at settlement.",
        preview: () => [
          ["Bid to reveal", toReveal ? `${num(wadNum(toReveal.qty))} @ ${usd(wadNum(toReveal.price))}` : "None"],
          ["Pay now", toReveal ? `Up to ${usd(Number(formatUnits(notional(BigInt(toReveal.qty), BigInt(toReveal.price)), E.loanDecimals)))}, less your bond` : "—"],
          ["Next reopen", et(closure?.reopenAt)],
        ],
        confirm: "Reveal",
        blocked: !toReveal ? "No committed bid from this device is in its reveal window." : null,
        plan: () => ({
          approve: { token: E.loanToken, spender: E.auctionHouse!, amount: notional(BigInt(toReveal!.qty), BigInt(toReveal!.price)) },
          write: write("revealBid", [BigInt(toReveal!.auctionId), BigInt(toReveal!.qty), BigInt(toReveal!.price), toReveal!.salt]),
          activity: { icon: "clock", title: `Revealed bid on lot #${toReveal!.auctionId}`, amount: usd(wadNum(toReveal!.price)), kind: "auction" },
        }),
      },
    },
  ];
  if (openLot)
    specs.push({
      icon: "cash",
      title: "Place bid",
      sub: `${openLot.kind.name === "INTRADAY" ? "Intraday" : "Open"}, 60 s`,
      amount: `Ends in ${until(openLot.deadlines.biddingEndAt, now)}`,
      dialog: {
        title: `Bid on ${lotLabel(openLot)}`,
        description: "An open batch auction: bids are visible, and every winner pays the same clearing price. Full payment is escrowed now.",
        fields: priceFields(openLot),
        preview: (v) => [
          ["Pay now", usd((v.q ?? 0) * (v.p ?? 0))],
          ["Reserve price", openLot.reserve ? usd(wadNum(openLot.reserve)) : "—"],
          ["Clears", et(openLot.deadlines.clearAt)],
        ],
        confirm: "Place bid",
        plan: (v) => {
          const qty = units(v.q, 18, "a quantity");
          const price = units(v.p, 18, "a price");
          save([{ auctionId: openLot.auctionId, qty: qty.toString(), price: price.toString(), salt: "0x", at: Date.now() }, ...saved]);
          return {
            approve: { token: E.loanToken, spender: E.auctionHouse!, amount: notional(qty, price) },
            write: write("placeBid", [BigInt(openLot.auctionId), qty, price]),
            activity: { icon: "gavel", title: `Bid on ${lotLabel(openLot)}`, amount: `${v.q} @ ${usd(Number(v.p))}`, kind: "auction" },
          };
        },
      },
    });
  if (claimable.length)
    specs.push({
      icon: "cash",
      title: "Claim",
      sub: "Tokens and refunds",
      amount: `${claimable.length} lot${claimable.length > 1 ? "s" : ""}`,
      dialog: {
        title: `Claim lot #${claimable[0]!.auctionId}`,
        description: "Collect the tokens you won and any refund of unfilled escrow or bond.",
        preview: () => claimable.map((b) => [`Lot #${b.auctionId}`, `${num(wadNum(b.qty))} @ ${usd(wadNum(b.price))}`] as [string, string]),
        confirm: "Claim",
        plan: () => ({
          write: write("claim", [BigInt(claimable[0]!.auctionId)]),
          activity: { icon: "cash", title: `Claimed lot #${claimable[0]!.auctionId}`, amount: "", kind: "auction" },
        }),
      },
    });

  const live = auctions.filter((a) => ["commit", "reveal", "open"].includes(phase(a, now)));
  const navSettlements = settlements.data ?? [];

  return (
    <>
      <PageHead
        title="Auctions"
        sub="Every liquidation clears in a batch at one uniform price, so being fastest earns nothing. At the reopen, bids are sealed with commit and reveal."
        right={
          saved.length ? (
            <button type="button" className="cx-chip" onClick={() => download(`credence-bids-${address}.json`, saved)}>
              Download bid backup
            </button>
          ) : undefined
        }
      />
      <div className="cx-grid">
        <div className="cx-col">
          <section>
            <H>{commitLot ? "Sealed bids open" : "Next reopen auction"}</H>
            <Row specs={specs}>
              <GradientCard
                logo={commitLot ? tokenLogo(ASSET_SYMBOL[commitLot.assetId.toLowerCase()] ?? "") : null}
                tag={commitLot ? sym(commitLot) : "REOPEN"}
                big={commitLot ? `${num(wadNum(commitLot.lot))} ${sym(commitLot)}` : et(closure?.reopenAt)}
                label={commitLot ? "Commit closes" : "Lots announced"}
                value={commitLot ? et(commitLot.deadlines.biddingEndAt) : "At the open +2:00, after the queue closes"}
                pill={<Pill>Sealed bids</Pill>}
              />
            </Row>
          </section>
          <section>
            <H>Recent auctions</H>
            {list.error ? (
              <ErrorNote error={list.error} />
            ) : auctions.length === 0 ? (
              <Note icon="gavel">No auction has run yet. A lot appears here when a loan falls under water at a reopen or during the day.</Note>
            ) : (
              <div className="cx-table-wrap">
                <table className="cx-table">
                  <thead>
                    <tr>
                      <th>Lot</th>
                      <th>Type</th>
                      <th className="is-num">Quantity</th>
                      <th className="is-num">Open / live</th>
                      <th className="is-num">Reserve</th>
                      <th className="is-num">Cleared</th>
                      <th className="is-num">vs open</th>
                    </tr>
                  </thead>
                  <tbody>
                    {auctions.map((a) => {
                      const open = wadNum(a.clearing?.openPrint);
                      const p = wadNum(a.clearing?.pStar);
                      return (
                        <tr key={a.auctionId}>
                          <td data-label="Lot" className="is-strong">
                            {sym(a)} <span style={{ color: "var(--cx-grey)", fontWeight: 400 }}>{et(a.clearedAt ?? a.createdAt)}</span>
                          </td>
                          <td data-label="Type">{a.kind.name === "REOPEN" ? "Reopen, sealed" : a.kind.name === "INTRADAY" ? "Intraday, 60 s" : a.kind.name.toLowerCase()}</td>
                          <td data-label="Quantity" className="is-num">{a.lot ? num(wadNum(a.lot)) : "Queue"}</td>
                          <td data-label="Open / live" className="is-num">{open ? usd(open) : "—"}</td>
                          <td data-label="Reserve" className="is-num">{a.reserve ? usd(wadNum(a.reserve)) : "—"}</td>
                          <td data-label="Cleared" className="is-num is-strong">{p ? usd(p) : phase(a, now)}</td>
                          <td data-label="vs open" className="is-num">{p && open ? pct(p / open - 1, 2) : "—"}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          <section>
            <H>Your bids</H>
            {saved.length === 0 ? (
              <Note icon="lock">Bids you place from this device are listed here, with the salt needed to reveal sealed ones.</Note>
            ) : (
              <div className="cx-table-wrap">
                <table className="cx-table">
                  <thead>
                    <tr>
                      <th>Lot</th>
                      <th className="is-num">Quantity</th>
                      <th className="is-num">Your price</th>
                      <th>Result</th>
                    </tr>
                  </thead>
                  <tbody>
                    {saved.map((b) => {
                      const d = details.find((x) => x.data?.auctionId === b.auctionId)?.data;
                      const mine = d?.bidList.find((x) => x.bidder.toLowerCase() === address?.toLowerCase());
                      const filled = mine?.tokens ? wadNum(mine.tokens) : 0;
                      return (
                        <tr key={b.auctionId + b.at}>
                          <td data-label="Lot" className="is-strong">{d ? sym(d) : "Lot"} #{b.auctionId}</td>
                          <td data-label="Quantity" className="is-num">{num(wadNum(b.qty))}</td>
                          <td data-label="Your price" className="is-num">{usd(wadNum(b.price))}</td>
                          <td data-label="Result">
                            <Pill tone={filled ? "good" : "soft"}>
                              {filled ? `Filled ${num(filled)}${d?.clearing ? ` at ${usd(wadNum(d.clearing.pStar))}` : ""}` : mine?.status ?? "Committed"}
                            </Pill>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </section>
          {navSettlements.length > 0 && (
            <section>
              <H right={<small>Arbitrum Sepolia, allowlisted solvers</small>}>Treasury-fund settlements</H>
              <div className="cx-table-wrap">
                <table className="cx-table">
                  <thead>
                    <tr>
                      <th>Settlement</th>
                      <th className="is-num">Quantity</th>
                      <th className="is-num">Floor</th>
                      <th>Outcome</th>
                    </tr>
                  </thead>
                  <tbody>
                    {navSettlements.map((x) => (
                      <tr key={x.settlementId}>
                        <td data-label="Settlement" className="is-strong">
                          {MARKET_INDEX[x.marketId.toLowerCase()]?.symbol ?? "NAV"} #{x.settlementId}
                        </td>
                        <td data-label="Quantity" className="is-num">{num(wadNum(x.qty))}</td>
                        <td data-label="Floor" className="is-num">{usd(wadNum(x.floorPrice), 4)}</td>
                        <td data-label="Outcome">
                          <Pill tone={x.status === "open" ? "warn" : "good"}>
                            {x.status === "open" ? `Open, ${x.bids} bids` : x.status === "filled" ? "Solver fill" : "Pool advance"}
                          </Pill>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          )}
        </div>
        <aside className="cx-aside">
          <StatBlock label="Live lots" value={String(live.length)} chip={live.length ? "Bidding now" : "None right now"} />
          <div>
            <H>Reopen timeline</H>
            <KV
              rows={[
                ["0:00", "Official opening price"],
                ["0:00–2:00", "Queue under-water loans"],
                ["2:00", "Lots sized"],
                ["2:00–5:00", "Commit sealed bids + 10% bond"],
                ["5:00–7:00", "Reveal and escrow payment"],
                ["7:00", "Clear, settle, refund"],
              ]}
            />
          </div>
          <Note icon="shield">
            Bids below the reserve (97% of the open) are ignored. Any unsold part of a lot is bought by the Underwriter Pool at the
            reserve.
          </Note>
        </aside>
      </div>
    </>
  );
}
