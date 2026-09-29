// Notification templates (§10.5) with exact amounts, following the copy rules in §10.7 (R-18):
// "Gap Cover" always comes with what it buys, and nothing says "insured".
import { z } from "zod";
import {
  change,
  decimalNearest,
  etClock,
  etTime,
  pct,
  price,
  ratio,
  tokens,
  usd,
  usdNearest,
} from "./format.ts";

export const GAP_COVER_MEANS =
  "Gap Cover lets you keep your LTV through this closure, and exempts you from overnight emergency liquidation.";

const uint = z.string().regex(/^\d+$/, "a decimal string in base units");
const unix = z.number().int().positive();

/** What happens at the Bell if the borrower does nothing (mirrors `enforceBell`, §8.4.3). */
const Default = z.discriminatedUnion("kind", [
  /** auto-cover buys cover and adds the premium to the debt */
  z.object({ kind: z.literal("autoCover") }),
  /** LTV above max + δ_cover: pre-close sale down to max LTV, then cover for the rest */
  z.object({ kind: z.literal("autoCoverAfterSale"), saleQty: uint }),
  /** auto-cover is off (or cover is unavailable): pre-close sale down to the safe LTV */
  z.object({ kind: z.literal("precloseSale"), saleQty: uint }),
]);

export const BellHeadsUp = z.object({
  marketId: z.string(),
  asset: z.string(), // "NVDA"
  token: z.string(), // "tNVDA"
  closureId: z.string(),
  closureType: z.number().int().min(1).max(3), // OVERNIGHT, WEEKEND, HOLIDAY_WEEKEND
  stage: z.enum(["T-26h", "T-2h"]),
  bellAt: unix,
  ltv: uint, // WAD, at V_live with projected debt
  safeLtv: uint, // WAD, next closure
  cureRepay: uint, // loan-token base units (rounded up on-chain)
  cureCollateral: uint, // collateral base units (rounded up on-chain)
  premium: uint.nullable(), // null: cover not available for this closure
  coverUnavailable: z.string().optional(),
  default: Default,
  loanDecimals: z.number().int().default(6),
  collateralDecimals: z.number().int().default(18),
  /** Drop the message instead of delivering it late (the Bell deadline). */
  expiresAt: unix.optional(),
});
export type BellHeadsUp = z.infer<typeof BellHeadsUp>;

export const BellOutcome = z.object({
  marketId: z.string(),
  asset: z.string(),
  token: z.string(),
  closureId: z.string(),
  outcome: z.enum(["autoCover", "autoCoverAfterSale", "precloseSale"]),
  premium: uint.optional(),
  saleQty: uint.optional(),
  newLtv: uint, // WAD, after the action (the sale counted at its reserve price)
  txHash: z.string().optional(),
  loanDecimals: z.number().int().default(6),
  collateralDecimals: z.number().int().default(18),
});
export type BellOutcome = z.infer<typeof BellOutcome>;

export const EmailVerify = z.object({
  email: z.string().email(),
  link: z.string().url(),
});

const wad = uint;
const Decimals = {
  loanDecimals: z.number().int().default(6),
  collateralDecimals: z.number().int().default(18),
};

/** Flagged at the reopen (REOPEN auction queue), with the countdown until the lot is fixed. */
export const ReopenQueued = z.object({
  marketId: z.string(),
  asset: z.string(),
  token: z.string(),
  auctionId: z.string(),
  closureId: z.string(),
  healthFactor: wad, // at the open print
  openPrint: wad, // P°, per token
  cureRepay: uint, // leaves the queue (HF back to ≥ 1)
  cureCollateral: uint,
  deadline: unix, // lots fixed at openPrintAt + 2:00 (+ ext)
  ...Decimals,
});
export type ReopenQueued = z.infer<typeof ReopenQueued>;

/** One position's settlement after an auction cleared (PositionSettled). */
export const AuctionSettled = z.object({
  marketId: z.string(),
  asset: z.string(),
  token: z.string(),
  auctionId: z.string(),
  kind: z.enum(["REOPEN", "INTRADAY", "EMERGENCY", "PRECLOSE"]),
  collateralSold: uint,
  pStar: wad, // clearing price per token
  openPrint: wad.nullable(), // P° for REOPEN, else the reference V
  proceeds: uint,
  penalty: uint,
  repaid: uint,
  refund: uint,
  shortfall: uint,
  debtAfter: uint,
  healthFactorAfter: wad.nullable(), // null: no debt left
  ...Decimals,
});
export type AuctionSettled = z.infer<typeof AuctionSettled>;

/** NAV stack (§8.8, S4 E): a fund position sold at T+0, by a solver or advanced by the pool. */
export const NavSold = z.object({
  marketId: z.string(),
  asset: z.string(), // "TBILL"
  token: z.string(),
  settlementId: z.string(),
  path: z.enum(["solver_fill", "pool_advance"]),
  collateralSold: uint,
  price: wad, // per token: the winning bid, or the floor for a pool advance
  floorPrice: wad, // NAV × (1 − κ_nav)
  proceeds: uint,
  penalty: uint,
  repaid: uint,
  refund: uint,
  shortfall: uint,
  debtAfter: uint,
  healthFactorAfter: wad.nullable(),
  ...Decimals,
});
export type NavSold = z.infer<typeof NavSold>;

/** Underwriters: an epoch of their pool settled. */
export const EpochSettled = z.object({
  stack: z.enum(["equity", "nav"]),
  epochId: z.string(),
  premiums: uint,
  fees: uint,
  penalties: uint,
  bonds: uint,
  losses: uint,
  /** Loan-token base units per whole share (10^18 share units). */
  sharePriceBefore: uint.nullable(),
  sharePriceAfter: uint,
  shares: uint, // the underwriter's pool shares (18 decimals)
  value: uint, // those shares at sharePriceAfter, loan-token base units
  loanDecimals: z.number().int().default(6),
});
export type EpochSettled = z.infer<typeof EpochSettled>;

/** Underwriters: a withdrawal request was burned at settlement and can be claimed. */
export const WithdrawalClaimable = z.object({
  stack: z.enum(["equity", "nav"]),
  epochId: z.string(),
  shares: uint,
  assets: uint,
  loanDecimals: z.number().int().default(6),
});
export type WithdrawalClaimable = z.infer<typeof WithdrawalClaimable>;

export const EVENTS = {
  bell_headsup: BellHeadsUp,
  bell_outcome: BellOutcome,
  reopen_queued: ReopenQueued,
  auction_settled: AuctionSettled,
  nav_sold: NavSold,
  epoch_settled: EpochSettled,
  withdrawal_claimable: WithdrawalClaimable,
  email_verify: EmailVerify,
} as const;
export type EventName = keyof typeof EVENTS;
export type Channel = "email" | "push" | "telegram";

/** Default channels per event (§10.5 table); user preferences can turn each off. */
export const DEFAULT_CHANNELS: Record<EventName, Channel[]> = {
  bell_headsup: ["email", "push", "telegram"],
  bell_outcome: ["email", "push", "telegram"],
  reopen_queued: ["push", "telegram"],
  auction_settled: ["email", "push", "telegram"],
  nav_sold: ["email", "push", "telegram"],
  epoch_settled: ["email"],
  withdrawal_claimable: ["email", "push"],
  email_verify: ["email"],
};

export interface Rendered {
  subject: string;
  /** Full text: email body and Telegram message. */
  text: string;
  html: string;
  /** Short push notification. */
  push: { title: string; body: string; tag: string; url: string };
}

const closureWord = (t: number) =>
  t === 1 ? "tonight's" : t === 2 ? "this weekend's" : "this holiday weekend's";

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const html = (paragraphs: string[]) =>
  paragraphs.map((p) => `<p>${esc(p)}</p>`).join("\n");

/** Sale lots are informational (the lot is fixed on-chain); 4 decimals, rounded up. */
const qty = (base: string, d: number) => tokens(base, d, 4);

export function renderBellHeadsUp(p: BellHeadsUp, webOrigin: string): Rendered {
  const deadline = etTime(p.bellAt);
  const repay = usd(p.cureRepay, p.loanDecimals);
  const add = `${tokens(p.cureCollateral, p.collateralDecimals)} ${p.token}`;
  const premium = p.premium === null ? null : usd(p.premium, p.loanDecimals);
  const options =
    premium === null
      ? `repay ${repay}, or add ${add}`
      : `repay ${repay}, or add ${add}, or buy Gap Cover for ${premium}`;
  const lead =
    `Your ${p.asset} loan is above ${closureWord(p.closureType)} safe LTV (${pct(p.ltv)} vs ${pct(p.safeLtv)}). ` +
    `Before ${deadline}: ${options}.`;
  let dflt: string;
  switch (p.default.kind) {
    case "autoCover":
      if (premium === null)
        throw new Error("autoCover default needs a premium");
      dflt = `If you do nothing, auto-cover will add ${premium} to your debt.`;
      break;
    case "autoCoverAfterSale":
      dflt =
        `If you do nothing, auto-cover will first sell ${qty(p.default.saleQty, p.collateralDecimals)} ${p.token} ` +
        `in the pre-close sale, then buy Gap Cover for the rest and add the premium to your debt.`;
      break;
    case "precloseSale":
      dflt =
        `If you do nothing, ${qty(p.default.saleQty, p.collateralDecimals)} ${p.token} will be sold in the ` +
        `pre-close sale at the Bell${premium === null ? "" : ", because auto-cover is off"}.`;
      break;
  }
  const paras = [lead];
  if (premium !== null || p.default.kind === "autoCoverAfterSale")
    paras.push(GAP_COVER_MEANS);
  else if (p.coverUnavailable)
    paras.push(
      `Gap Cover is not available for this closure: ${p.coverUnavailable}.`,
    );
  paras.push(dflt);
  const url = `${webOrigin}/markets/${p.marketId}`;
  return {
    subject: `${p.asset}: action needed before ${deadline}`,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html:
      html(paras) +
      `\n<p><a href="${esc(url)}">Open your ${esc(p.asset)} position</a></p>`,
    push: {
      title: `${p.asset}: act before ${deadline}`,
      body: `${lead} ${dflt}`,
      tag: `bell:${p.marketId}:${p.closureId}`,
      url,
    },
  };
}

export function renderBellOutcome(p: BellOutcome, webOrigin: string): Rendered {
  const premium =
    p.premium === undefined ? null : usd(p.premium, p.loanDecimals);
  const sale =
    p.saleQty === undefined
      ? null
      : `${qty(p.saleQty, p.collateralDecimals)} ${p.token}`;
  const paras: string[] = [];
  switch (p.outcome) {
    case "autoCover":
      paras.push(
        `Your ${p.asset} loan was above the safe LTV at the Bell, so auto-cover bought Gap Cover for ${premium} ` +
          `and added it to your debt. Your LTV is now ${pct(p.newLtv)}.`,
        GAP_COVER_MEANS,
      );
      break;
    case "autoCoverAfterSale":
      paras.push(
        `Your ${p.asset} loan was above the maximum LTV at the Bell, so ${sale} went into the pre-close sale and ` +
          `auto-cover bought Gap Cover for ${premium}, added to your debt. At the sale's reserve price your LTV is ${pct(p.newLtv)}.`,
        GAP_COVER_MEANS,
      );
      break;
    case "precloseSale":
      paras.push(
        `Your ${p.asset} loan was above the safe LTV at the Bell and auto-cover is off, so ${sale} went into the ` +
          `pre-close sale. At the sale's reserve price your LTV is ${pct(p.newLtv)}. You will get the sale result when it settles.`,
      );
      break;
  }
  const url = `${webOrigin}/markets/${p.marketId}`;
  const title =
    p.outcome === "precloseSale"
      ? `${p.asset}: pre-close sale of ${sale}`
      : `${p.asset}: auto-cover applied (${premium})`;
  return {
    subject: title,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html:
      html(paras) +
      `\n<p><a href="${esc(url)}">Open your ${esc(p.asset)} position</a></p>`,
    push: {
      title,
      body: paras[0]!,
      tag: `bell-outcome:${p.marketId}:${p.closureId}`,
      url,
    },
  };
}

const link = (url: string, label: string) =>
  `\n<p><a href="${esc(url)}">${esc(label)}</a></p>`;
const shares = (base: string) => tokens(base, 18, 4);

export function renderReopenQueued(
  p: ReopenQueued,
  webOrigin: string,
): Rendered {
  const until = etClock(p.deadline);
  const repay = usd(p.cureRepay, p.loanDecimals);
  const add = `${tokens(p.cureCollateral, p.collateralDecimals)} ${p.token}`;
  const lead =
    `${p.asset} reopened at ${price(p.openPrint)} and your loan's health factor is ${ratio(p.healthFactor)}, ` +
    `so it is queued for the reopen auction #${p.auctionId}.`;
  const cta = `You can leave the queue by repaying ${repay} or adding ${add} until ${until}.`;
  const url = `${webOrigin}/markets/${p.marketId}`;
  const paras = [
    lead,
    cta,
    "After that, the lot is fixed and part of your collateral is sold at the auction's clearing price.",
  ];
  return {
    subject: `${p.asset}: queued for the reopen auction, act before ${until}`,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html: html(paras) + link(url, `Open your ${p.asset} position`),
    push: {
      title: `${p.asset}: leave the auction queue before ${until}`,
      body: cta,
      tag: `reopen:${p.marketId}:${p.closureId}`,
      url,
    },
  };
}

const KIND_WORD: Record<AuctionSettled["kind"], string> = {
  REOPEN: "reopen auction",
  INTRADAY: "intraday auction",
  EMERGENCY: "emergency auction",
  PRECLOSE: "pre-close sale",
};

export function renderAuctionSettled(
  p: AuctionSettled,
  webOrigin: string,
): Rendered {
  const sold = `${tokens(p.collateralSold, p.collateralDecimals, 4)} ${p.token}`;
  const ref =
    p.openPrint === null
      ? ""
      : ` (${p.kind === "REOPEN" ? "open print" : "reference"} ${price(p.openPrint)}, ${change(p.pStar, p.openPrint)})`;
  const paras = [
    `Your ${p.asset} position was settled in ${KIND_WORD[p.kind]} #${p.auctionId}: ${sold} sold at ${price(p.pStar)}${ref}, ` +
      `for ${usdNearest(p.proceeds, p.loanDecimals)}.`,
    `Liquidation penalty ${usdNearest(p.penalty, p.loanDecimals)}; ${usdNearest(p.repaid, p.loanDecimals)} repaid your loan; ` +
      `${usdNearest(p.refund, p.loanDecimals)} refunded to you.`,
  ];
  if (BigInt(p.shortfall) > 0n)
    paras.push(
      `The sale did not cover the whole debt: a shortfall of ${usdNearest(p.shortfall, p.loanDecimals)} was absorbed by the protocol's loss layers.`,
    );
  paras.push(
    p.healthFactorAfter === null
      ? "Your loan is fully repaid."
      : `Your remaining debt is ${usdNearest(p.debtAfter, p.loanDecimals)} and your health factor is now ${ratio(p.healthFactorAfter)}.`,
  );
  const url = `${webOrigin}/auctions/${p.auctionId}`;
  return {
    subject: `${p.asset}: ${KIND_WORD[p.kind]} settled (${sold} at ${price(p.pStar)})`,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html: html(paras) + link(url, `Auction #${p.auctionId}`),
    push: {
      title: `${p.asset}: ${sold} sold at ${price(p.pStar)}`,
      body: paras[1]!,
      tag: `settled:${p.marketId}:${p.auctionId}`,
      url,
    },
  };
}

/** A fund price per token to 4 decimals ("$0.9950"): NAV prices move in tenths of a cent. */
const navPrice = (wad: string) => `$${decimalNearest(wad, 18, 4)}`;

export function renderNavSold(p: NavSold, webOrigin: string): Rendered {
  const sold = `${tokens(p.collateralSold, p.collateralDecimals, 4)} ${p.token}`;
  const how =
    p.path === "solver_fill"
      ? `sold to a solver at ${navPrice(p.price)} (floor ${navPrice(p.floorPrice)}, ${change(p.price, p.floorPrice)})`
      : `bought by the NAV underwriter pool at the floor, ${navPrice(p.price)} (no solver bid in the window)`;
  const paras = [
    `Your ${p.asset} position was settled today (settlement #${p.settlementId}): ${sold} ${how}, ` +
      `for ${usdNearest(p.proceeds, p.loanDecimals)}.`,
    `Liquidation penalty ${usdNearest(p.penalty, p.loanDecimals)}; ${usdNearest(p.repaid, p.loanDecimals)} repaid your loan; ` +
      `${usdNearest(p.refund, p.loanDecimals)} refunded to you.`,
  ];
  if (BigInt(p.shortfall) > 0n)
    paras.push(
      `The sale did not cover the whole debt: a shortfall of ${usdNearest(p.shortfall, p.loanDecimals)} was absorbed by the protocol's loss layers.`,
    );
  paras.push(
    p.healthFactorAfter === null
      ? "Your loan is fully repaid."
      : `Your remaining debt is ${usdNearest(p.debtAfter, p.loanDecimals)} and your health factor is now ${ratio(p.healthFactorAfter)}.`,
  );
  const url = `${webOrigin}/settlements/${p.settlementId}`;
  return {
    subject: `${p.asset}: position settled (${sold} at ${navPrice(p.price)})`,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html: html(paras) + link(url, `Settlement #${p.settlementId}`),
    push: {
      title: `${p.asset}: ${sold} sold at ${navPrice(p.price)}`,
      body: paras[1]!,
      tag: `navsold:${p.marketId}:${p.settlementId}`,
      url,
    },
  };
}

const POOL: Record<"equity" | "nav", string> = {
  equity: "equity underwriter pool (cfUP-EQ)",
  nav: "NAV underwriter pool (cfUP-NAV)",
};

export function renderEpochSettled(
  p: EpochSettled,
  webOrigin: string,
): Rendered {
  const d = p.loanDecimals;
  const px = (v: string) => `$${decimalNearest(v, d, 6)}`;
  const paras = [
    `Epoch ${p.epochId} of the ${POOL[p.stack]} settled. Premiums ${usdNearest(p.premiums, d)}, risk fees ${usdNearest(p.fees, d)}, ` +
      `penalties ${usdNearest(p.penalties, d)}, forfeited bonds ${usdNearest(p.bonds, d)}; losses paid ${usdNearest(p.losses, d)}.`,
    `The new share price is ${px(p.sharePriceAfter)}${p.sharePriceBefore === null ? "" : ` (was ${px(p.sharePriceBefore)})`}. ` +
      `Your ${shares(p.shares)} shares are worth ${usdNearest(p.value, d)}.`,
  ];
  const url = `${webOrigin}/underwrite`;
  return {
    subject: `Underwriter pool epoch ${p.epochId} settled: share price ${px(p.sharePriceAfter)}`,
    text: `${paras.join("\n\n")}\n\n${url}`,
    html: html(paras) + link(url, "Your pool position"),
    push: {
      title: `Epoch ${p.epochId} settled`,
      body: paras[1]!,
      tag: `epoch:${p.stack}:${p.epochId}`,
      url,
    },
  };
}

export function renderWithdrawalClaimable(
  p: WithdrawalClaimable,
  webOrigin: string,
): Rendered {
  const amount = usdNearest(p.assets, p.loanDecimals);
  const url = `${webOrigin}/underwrite?claim=${p.stack}:${p.epochId}`;
  const lead = `Your withdrawal of ${shares(p.shares)} ${p.stack === "equity" ? "cfUP-EQ" : "cfUP-NAV"} shares settled with epoch ${p.epochId}: ${amount} is ready to claim.`;
  return {
    subject: `Withdrawal ready: claim ${amount}`,
    text: `${lead}\n\nClaim it here: ${url}`,
    html: html([lead]) + link(url, `Claim ${amount}`),
    push: {
      title: `Claim ${amount}`,
      body: lead,
      tag: `withdraw:${p.stack}:${p.epochId}`,
      url,
    },
  };
}

export function renderEmailVerify(p: z.infer<typeof EmailVerify>): Rendered {
  const text = `Confirm that ${p.email} should receive Credence loan alerts: ${p.link}\n\nIf you did not ask for this, ignore this email.`;
  return {
    subject: "Confirm your email for Credence alerts",
    text,
    html: `<p>Confirm that ${esc(p.email)} should receive Credence loan alerts.</p>\n<p><a href="${esc(p.link)}">Confirm</a></p>\n<p>If you did not ask for this, ignore this email.</p>`,
    push: {
      title: "Confirm your email",
      body: text,
      tag: "email-verify",
      url: p.link,
    },
  };
}

export class BadPayload extends Error {}

function parsed<S extends z.ZodTypeAny>(
  schema: S,
  payload: unknown,
  f: (d: z.infer<S>) => Rendered,
): { rendered: Rendered; data: unknown } {
  const r = schema.safeParse(payload);
  if (!r.success) throw new BadPayload(r.error.message);
  return { rendered: f(r.data), data: r.data };
}

/** Validate and render one job. Throws `BadPayload` for unknown events or invalid payloads. */
export function render(
  event: string,
  payload: unknown,
  webOrigin: string,
): { rendered: Rendered; data: unknown } {
  switch (event) {
    case "bell_headsup": {
      const r = BellHeadsUp.safeParse(payload);
      if (!r.success) throw new BadPayload(r.error.message);
      return { rendered: renderBellHeadsUp(r.data, webOrigin), data: r.data };
    }
    case "bell_outcome": {
      const r = BellOutcome.safeParse(payload);
      if (!r.success) throw new BadPayload(r.error.message);
      return { rendered: renderBellOutcome(r.data, webOrigin), data: r.data };
    }
    case "reopen_queued":
      return parsed(ReopenQueued, payload, (d) =>
        renderReopenQueued(d, webOrigin),
      );
    case "auction_settled":
      return parsed(AuctionSettled, payload, (d) =>
        renderAuctionSettled(d, webOrigin),
      );
    case "nav_sold":
      return parsed(NavSold, payload, (d) => renderNavSold(d, webOrigin));
    case "epoch_settled":
      return parsed(EpochSettled, payload, (d) =>
        renderEpochSettled(d, webOrigin),
      );
    case "withdrawal_claimable":
      return parsed(WithdrawalClaimable, payload, (d) =>
        renderWithdrawalClaimable(d, webOrigin),
      );
    case "email_verify": {
      const r = EmailVerify.safeParse(payload);
      if (!r.success) throw new BadPayload(r.error.message);
      return { rendered: renderEmailVerify(r.data), data: r.data };
    }
    default:
      throw new BadPayload(`unknown event ${event}`);
  }
}
