// Notification templates (§10.5) with exact amounts, following the copy rules in §10.7 (R-18):
// "Gap Cover" always comes with what it buys, and nothing says "insured".
import { z } from "zod";
import { etTime, pct, tokens, usd } from "./format.ts";

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

export const EVENTS = {
  bell_headsup: BellHeadsUp,
  bell_outcome: BellOutcome,
  email_verify: EmailVerify,
} as const;
export type EventName = keyof typeof EVENTS;
export type Channel = "email" | "push" | "telegram";

/** Default channels per event (§10.5 table); user preferences can turn each off. */
export const DEFAULT_CHANNELS: Record<EventName, Channel[]> = {
  bell_headsup: ["email", "push", "telegram"],
  bell_outcome: ["email", "push", "telegram"],
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
    case "email_verify": {
      const r = EmailVerify.safeParse(payload);
      if (!r.success) throw new BadPayload(r.error.message);
      return { rendered: renderEmailVerify(r.data), data: r.data };
    }
    default:
      throw new BadPayload(`unknown event ${event}`);
  }
}
