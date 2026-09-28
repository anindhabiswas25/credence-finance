// Indexer-triggered notifications (§10.5): the notifier scans Ponder's views for new rows and enqueues
// one job per recipient and event. Dedupe keys make every scan idempotent, so the scan window may
// overlap and a restart never sends twice:
//
// | event                | source rows                                             | dedupe key                         |
// | -------------------- | ------------------------------------------------------- | ---------------------------------- |
// | bell_outcome         | position_event kind auto_cover_applied                  | AUTO:<market>:<closure>:<owner>    |
// | reopen_queued        | position_event kind flagged, auction kind REOPEN        | REOPENQ:<auction>:<owner>          |
// | auction_settled      | lot_position settled (every kind; PRECLOSE = the sale)  | SETTLED:<auction>:<owner>          |
// | epoch_settled        | epoch settled × pool_holder                             | EPOCH:<pool>:<epoch>:<owner>       |
// | withdrawal_claimable | epoch settled × pool_request withdraw of that epoch     | WITHDRAW:<pool>:<epoch>:<owner>    |
//
// J2's Bell heads-ups are enqueued by the keeper (it computes the Bell natively).
import type postgres from "postgres";
import { enqueue, type Sql } from "./queue.ts";
import type {
  AuctionSettled,
  BellOutcome,
  EpochSettled,
  ReopenQueued,
  WithdrawalClaimable,
} from "./templates.ts";

const WAD = 10n ** 18n;
const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;
const KINDS = ["REOPEN", "INTRADAY", "EMERGENCY", "PRECLOSE"] as const;

export interface Units {
  loanDecimals: number;
  collateralDecimals: number;
}
const DEFAULT_UNITS: Units = { loanDecimals: 6, collateralDecimals: 18 };

/** Collateral value in loan base units: qty (collateral units) × price (WAD per whole token), rounded down. */
export function collateralValue(
  qty: bigint,
  priceWad: bigint,
  u: Units = DEFAULT_UNITS,
): bigint {
  return (
    (qty * priceWad) /
    10n ** BigInt(u.collateralDecimals) /
    10n ** BigInt(18 - u.loanDecimals)
  );
}

/** HF (WAD) = C·V·LT / D, rounded down; null without debt. */
export function healthFactor(
  qty: bigint,
  priceWad: bigint,
  lt: bigint,
  debt: bigint,
  u: Units = DEFAULT_UNITS,
): bigint | null {
  if (debt === 0n) return null;
  return (collateralValue(qty, priceWad, u) * lt) / debt;
}

/** What leaves the REOPEN queue (HF back to ≥ 1), rounded up against the borrower (§7.2). */
export function leaveQueueCure(
  qty: bigint,
  priceWad: bigint,
  lt: bigint,
  debt: bigint,
  u: Units = DEFAULT_UNITS,
) {
  const cv = collateralValue(qty, priceWad, u);
  const limit = (cv * lt) / WAD; // borrowable at HF = 1
  const repay = debt > limit ? debt - limit : 0n;
  // value needed: D / LT; extra collateral = (D/LT − cv) in tokens at V
  const need = ceilDiv(debt * WAD, lt);
  const missing = need > cv ? need - cv : 0n;
  const scale =
    10n ** BigInt(u.collateralDecimals) * 10n ** BigInt(18 - u.loanDecimals);
  const add = missing === 0n ? 0n : ceilDiv(missing * scale, priceWad);
  return { repay, add };
}

export interface Labels {
  /** marketId (lower-case) → ticker, e.g. NVDA */
  ticker: (marketId: string) => string;
  /** pool address (lower-case) → stack */
  stack: (pool: string) => "equity" | "nav";
}

export function reopenQueuedPayload(
  r: {
    marketId: string;
    auctionId: bigint;
    closureId: bigint;
    collateral: bigint;
    debt: bigint;
    lt: bigint;
    openPrint: bigint;
    lotFixAt: number;
  },
  l: Labels,
  u: Units = DEFAULT_UNITS,
): ReopenQueued {
  const t = l.ticker(r.marketId);
  const cure = leaveQueueCure(r.collateral, r.openPrint, r.lt, r.debt, u);
  return {
    marketId: r.marketId,
    asset: t,
    token: `t${t}`,
    auctionId: r.auctionId.toString(),
    closureId: r.closureId.toString(),
    healthFactor: (
      healthFactor(r.collateral, r.openPrint, r.lt, r.debt, u) ?? 0n
    ).toString(),
    openPrint: r.openPrint.toString(),
    cureRepay: cure.repay.toString(),
    cureCollateral: cure.add.toString(),
    deadline: r.lotFixAt,
    ...u,
  };
}

export function auctionSettledPayload(
  r: {
    marketId: string;
    auctionId: bigint;
    kind: number;
    collateralSold: bigint;
    pStar: bigint;
    reference: bigint | null;
    proceeds: bigint;
    penalty: bigint;
    shortfall: bigint;
    refund: bigint;
    debtAfter: bigint;
    collateralAfter: bigint;
    lt: bigint;
  },
  l: Labels,
  u: Units = DEFAULT_UNITS,
): AuctionSettled {
  const t = l.ticker(r.marketId);
  const repaid =
    r.proceeds - r.penalty - r.refund > 0n
      ? r.proceeds - r.penalty - r.refund
      : 0n;
  const v = r.reference ?? r.pStar;
  return {
    marketId: r.marketId,
    asset: t,
    token: `t${t}`,
    auctionId: r.auctionId.toString(),
    kind: KINDS[r.kind] ?? "REOPEN",
    collateralSold: r.collateralSold.toString(),
    pStar: r.pStar.toString(),
    openPrint: r.reference === null ? null : r.reference.toString(),
    proceeds: r.proceeds.toString(),
    penalty: r.penalty.toString(),
    repaid: repaid.toString(),
    refund: r.refund.toString(),
    shortfall: r.shortfall.toString(),
    debtAfter: r.debtAfter.toString(),
    healthFactorAfter:
      r.debtAfter === 0n
        ? null
        : (
            healthFactor(r.collateralAfter, v, r.lt, r.debtAfter, u) ?? 0n
          ).toString(),
    ...u,
  };
}

/** The pool's share price is WAD dollars per whole share (1e18 = $1.00; BE-chain 02:10): WAD → loan base units. */
const toLoan = (wad: bigint, u: Units) =>
  wad / 10n ** BigInt(18 - u.loanDecimals);

/** Share prices go out in loan base units per whole share (the template's unit), converted from the pool's WAD dollars. */
export function epochSettledPayload(
  r: {
    stack: "equity" | "nav";
    epochId: bigint;
    premiums: bigint;
    riskFees: bigint;
    penalties: bigint;
    bonds: bigint;
    lossesPaid: bigint;
    before: bigint | null;
    after: bigint;
    shares: bigint;
  },
  u: Units = DEFAULT_UNITS,
): EpochSettled {
  return {
    stack: r.stack,
    epochId: r.epochId.toString(),
    premiums: r.premiums.toString(),
    fees: r.riskFees.toString(),
    penalties: r.penalties.toString(),
    bonds: r.bonds.toString(),
    losses: r.lossesPaid.toString(),
    sharePriceBefore: r.before === null ? null : toLoan(r.before, u).toString(),
    sharePriceAfter: toLoan(r.after, u).toString(),
    shares: r.shares.toString(),
    value: toLoan((r.shares * r.after) / WAD, u).toString(),
    loanDecimals: u.loanDecimals,
  };
}

/** The assets reserved for a withdrawal: shares burned at sharePriceAfter, rounded down (against the withdrawer). */
export function withdrawalPayload(
  r: {
    stack: "equity" | "nav";
    epochId: bigint;
    shares: bigint;
    sharePriceAfter: bigint;
  },
  u: Units = DEFAULT_UNITS,
): WithdrawalClaimable {
  return {
    stack: r.stack,
    epochId: r.epochId.toString(),
    shares: r.shares.toString(),
    assets: toLoan((r.shares * r.sharePriceAfter) / WAD, u).toString(),
    loanDecimals: u.loanDecimals,
  };
}

export function autoCoverPayload(
  r: {
    marketId: string;
    closureId: bigint;
    premium: bigint;
    debtAfter: bigint;
    collateral: bigint;
    price: bigint;
  },
  l: Labels,
  u: Units = DEFAULT_UNITS,
): BellOutcome {
  const t = l.ticker(r.marketId);
  const cv = collateralValue(r.collateral, r.price, u);
  return {
    marketId: r.marketId,
    asset: t,
    token: `t${t}`,
    closureId: r.closureId.toString(),
    outcome: "autoCover",
    premium: r.premium.toString(),
    newLtv: (cv === 0n ? 0n : ceilDiv(r.debtAfter * WAD, cv)).toString(),
    ...u,
  };
}

// ── the scan ─────────────────────────────────────────────────────────────────────────────────────

const big = (v: unknown) => BigInt(v as string);
const hex = (v: unknown) => String(v).toLowerCase();

export interface ScanResult {
  enqueued: number;
  maxTs: bigint;
}

/** Enqueue every notification due from rows at or after `sinceTs` (unix s). */
export async function scan(
  sql: Sql,
  schema: string,
  sinceTs: bigint,
  l: Labels,
  u: Units = DEFAULT_UNITS,
): Promise<ScanResult> {
  const ix = (t: string) => sql(`${schema}.${t}`);
  let enqueued = 0;
  let maxTs = sinceTs;
  const seen = (ts: unknown) => {
    const t = big(ts);
    if (t > maxTs) maxTs = t;
  };
  const add = async (
    dedupeKey: string,
    address: string,
    event: string,
    payload: object,
  ) => {
    if ((await enqueue(sql, { dedupeKey, address, event, payload })) !== null)
      enqueued++;
  };
  const since = sinceTs.toString();

  // auto-cover applied (the premium added to debt), with the LTV at the latest LIVE price before it
  for (const r of (await sql`
      select e.owner, e.market_id, e.amounts, e.ts, p.collateral,
             (select pp.price from ${ix("price_point")} pp where pp.asset_id = m.asset_id and pp.kind = 0 and pp.observed_at <= e.ts
               order by pp.observed_at desc limit 1) as price
        from ${ix("position_event")} e
        join ${ix("market")} m on m.market_id = e.market_id
        join ${ix("position")} p on p.market_id = e.market_id and p.owner = e.owner
       where e.kind = 'auto_cover_applied' and e.ts >= ${since}`) as postgres.Row[]) {
    seen(r.ts);
    if (r.price === null) continue;
    const a = r.amounts as {
      closureId: string;
      premium: string;
      debtAfter: string;
    };
    const payload = autoCoverPayload(
      {
        marketId: hex(r.market_id),
        closureId: big(a.closureId),
        premium: big(a.premium),
        debtAfter: big(a.debtAfter),
        collateral: big(r.collateral),
        price: big(r.price),
      },
      l,
      u,
    );
    await add(
      `AUTO:${hex(r.market_id)}:${a.closureId}:${hex(r.owner)}`,
      hex(r.owner),
      "bell_outcome",
      payload,
    );
  }

  // queued at the reopen: flagged into a REOPEN auction; cure at the open print, countdown to lotFixAt
  for (const r of (await sql`
      select e.owner, e.market_id, e.amounts, e.ts, a.auction_id, a.closure_id, a.deadlines, o.price as open_print,
             p.collateral, p.debt_snapshot, m.lt
        from ${ix("position_event")} e
        join ${ix("auction")} a on a.auction_id = (e.amounts->>'auctionId')::numeric
        join ${ix("open_print")} o on o.asset_id = a.asset_id and o.closure_id = a.closure_id
        join ${ix("position")} p on p.market_id = e.market_id and p.owner = e.owner
        join ${ix("market")} m on m.market_id = e.market_id
       where e.kind = 'flagged' and a.kind = 0 and e.ts >= ${since}`) as postgres.Row[]) {
    seen(r.ts);
    const payload = reopenQueuedPayload(
      {
        marketId: hex(r.market_id),
        auctionId: big(r.auction_id),
        closureId: big(r.closure_id),
        collateral: big(r.collateral),
        debt: big(r.debt_snapshot),
        lt: big(r.lt),
        openPrint: big(r.open_print),
        lotFixAt: Number((r.deadlines as (string | number)[])[0]),
      },
      l,
      u,
    );
    await add(
      `REOPENQ:${r.auction_id}:${hex(r.owner)}`,
      hex(r.owner),
      "reopen_queued",
      payload,
    );
  }

  // settled in an auction (a PRECLOSE auction is the pre-close sale)
  for (const r of (await sql`
      select lp.*, a.kind, a.p_star, o.price as open_print, p.collateral as collateral_after, m.lt
        from ${ix("lot_position")} lp
        join ${ix("auction")} a on a.auction_id = lp.auction_id
        left join ${ix("open_print")} o on a.kind = 0 and o.asset_id = a.asset_id and o.closure_id = a.closure_id
        join ${ix("position")} p on p.market_id = lp.market_id and p.owner = lp.owner
        join ${ix("market")} m on m.market_id = lp.market_id
       where lp.settled_at is not null and lp.settled_at >= ${since} and a.p_star is not null`) as postgres.Row[]) {
    seen(r.settled_at);
    const payload = auctionSettledPayload(
      {
        marketId: hex(r.market_id),
        auctionId: big(r.auction_id),
        kind: Number(r.kind),
        collateralSold: big(r.collateral_sold),
        pStar: big(r.p_star),
        reference: r.open_print === null ? null : big(r.open_print),
        proceeds: big(r.proceeds),
        penalty: big(r.penalty),
        shortfall: big(r.shortfall),
        refund: big(r.refund),
        debtAfter: big(r.debt_after),
        collateralAfter: big(r.collateral_after),
        lt: big(r.lt),
      },
      l,
      u,
    );
    await add(
      `SETTLED:${r.auction_id}:${hex(r.owner)}`,
      hex(r.owner),
      "auction_settled",
      payload,
    );
  }

  // epoch settled: every shareholder (the pool's own escrow excluded), and the epoch's withdrawals
  for (const e of (await sql`
      select e.*, (select e2.share_price_after from ${ix("epoch")} e2 where e2.pool = e.pool and e2.status = 'settled' and e2.epoch_id < e.epoch_id
                   order by e2.epoch_id desc limit 1) as before
        from ${ix("epoch")} e where e.status = 'settled' and e.settled_at >= ${since}`) as postgres.Row[]) {
    seen(e.settled_at);
    const pool = hex(e.pool);
    const stack = l.stack(pool);
    for (const h of await sql`select owner, shares from ${ix("pool_holder")} where pool = ${pool} and shares > 0 and owner <> ${pool}`) {
      const payload = epochSettledPayload(
        {
          stack,
          epochId: big(e.epoch_id),
          premiums: big(e.premiums),
          riskFees: big(e.risk_fees ?? 0),
          penalties: big(e.penalties ?? 0),
          bonds: big(e.bonds ?? 0),
          lossesPaid: big(e.losses_paid ?? 0),
          before: e.before === null ? null : big(e.before),
          after: big(e.share_price_after),
          shares: big(h.shares),
        },
        u,
      );
      await add(
        `EPOCH:${pool}:${e.epoch_id}:${hex(h.owner)}`,
        hex(h.owner),
        "epoch_settled",
        payload,
      );
    }
    for (const w of await sql`select owner, shares from ${ix("pool_request")} where pool = ${pool} and epoch_id = ${e.epoch_id} and kind = 'withdraw' and shares > 0`) {
      const payload = withdrawalPayload(
        {
          stack,
          epochId: big(e.epoch_id),
          shares: big(w.shares),
          sharePriceAfter: big(e.share_price_after),
        },
        u,
      );
      await add(
        `WITHDRAW:${pool}:${e.epoch_id}:${hex(w.owner)}`,
        hex(w.owner),
        "withdrawal_claimable",
        payload,
      );
    }
  }
  return { enqueued, maxTs };
}

/** Labels from the address book (`equity.markets` / `nav.markets`, `equity.pool` / `nav.pool`). */
export function labelsFromBook(book: {
  equity?: { pool?: string; markets?: Record<string, string> } | null;
  nav?: { pool?: string; markets?: Record<string, string> } | null;
}): Labels {
  const tickers = new Map<string, string>();
  for (const st of [book.equity, book.nav])
    for (const [t, id] of Object.entries(st?.markets ?? {}))
      tickers.set(id.toLowerCase(), t);
  const navPool = book.nav?.pool?.toLowerCase();
  return {
    ticker: (id) => tickers.get(id.toLowerCase()) ?? id.slice(0, 10),
    stack: (p) => (p.toLowerCase() === navPool ? "nav" : "equity"),
  };
}
