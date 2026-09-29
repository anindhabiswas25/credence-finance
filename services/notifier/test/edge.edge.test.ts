// S4 H edge cases (make backend-edge), notifier: provider rate limits, a user with no channel, extreme amounts.
import { describe, expect, it } from "vitest";
import { httpError, retryAfterOf } from "../src/channels/types.ts";
import { sendTelegram } from "../src/channels/telegram.ts";
import {
  navSoldPayload,
  labelsFromBook,
  auctionSettledPayload,
} from "../src/producer.ts";
import { render } from "../src/templates.ts";
import { backoffS, channelsFor, type WorkerConfig } from "../src/worker.ts";

const cfg: WorkerConfig = {
  email: { apiKey: "k", from: "a@b.c", apiUrl: "http://x" } as never,
  push: {} as never,
  telegram: { botToken: "t", apiUrl: "http://tg" },
  webOrigin: "https://app",
  maxAttempts: 8,
  backoffBaseS: 30,
  backoffMaxS: 3600,
  pushTtlS: 3600,
};

describe("edge: Telegram rate limit (429)", () => {
  it("is transient and carries the bot API's retry_after", async () => {
    const f = (async () =>
      new Response(
        JSON.stringify({
          ok: false,
          error_code: 429,
          description: "Too Many Requests: retry after 37",
          parameters: { retry_after: 37 },
        }),
        { status: 429 },
      )) as typeof fetch;
    const e = await sendTelegram(cfg.telegram!, "42", "hi", f).catch((x) => x);
    expect(e.permanent).toBe(false);
    expect(e.retryAfterS).toBe(37);
    // the worker waits max(own back-off, retry_after): 37 s beats the first 30 s back-off
    expect(Math.max(backoffS(cfg, 1), e.retryAfterS)).toBe(37);
  });
  it("other statuses: 403 (bot blocked) is permanent, 5xx transient without a hint", () => {
    expect(httpError("telegram", 403, "{}").permanent).toBe(true);
    const e = httpError("telegram", 502, "bad gateway");
    expect([e.permanent, e.retryAfterS]).toEqual([false, undefined]);
    expect(retryAfterOf("not json")).toBeUndefined();
    expect(retryAfterOf('{"parameters":{"retry_after":-5}}')).toBeUndefined();
  });
});

describe("edge: a user with no deliverable channel", () => {
  const none = {
    email: null,
    emailVerified: false,
    telegramChatId: null,
    push: [],
    prefs: new Map<string, boolean>(),
  };
  it("gets no channel (the job ends skipped, never retried)", () => {
    expect(channelsFor("auction_settled", none, cfg)).toEqual([]);
    // an unverified email does not count, and a switched-off channel is not used
    expect(channelsFor("nav_sold", { ...none, email: "u@x.io" }, cfg)).toEqual(
      [],
    );
    expect(
      channelsFor(
        "nav_sold",
        {
          ...none,
          telegramChatId: "1",
          prefs: new Map([["nav_sold:telegram", false]]),
        },
        cfg,
      ),
    ).toEqual([]);
  });
});

describe("edge: amounts of 1 base unit and at the maximum", () => {
  const TB = "0x" + "22".repeat(32);
  const MID = "0x" + "11".repeat(32);
  const labels = labelsFromBook({
    equity: { pool: "0xp", markets: { NVDA: MID } },
    nav: { pool: "0xn", markets: { TBILL: TB } },
  });
  const MAX = 2n ** 128n - 1n;
  it("render exactly, with no rounding to zero lost in the raw payload and no overflow", () => {
    for (const v of [1n, MAX]) {
      const p = navSoldPayload(
        {
          marketId: TB,
          settlementId: v,
          status: "filled",
          collateralSold: v,
          price: v,
          floorPrice: v,
          proceeds: v,
          penalty: 0n,
          shortfall: 0n,
          refund: 0n,
          debtAfter: v,
          collateralAfter: v,
          lt: 10n ** 18n,
        },
        labels,
      );
      expect(p.proceeds).toBe(v.toString());
      const r = render("nav_sold", p, "https://app").rendered;
      expect(r.text.length).toBeGreaterThan(0);
      expect(r.text).not.toMatch(/NaN|Infinity|e\+/);
    }
    const one = render(
      "auction_settled",
      auctionSettledPayload(
        {
          marketId: MID,
          auctionId: 1n,
          kind: 1,
          collateralSold: 1n,
          pStar: 1n,
          reference: null,
          proceeds: 1n,
          penalty: 0n,
          shortfall: 1n,
          refund: 0n,
          debtAfter: 0n,
          collateralAfter: 0n,
          lt: 10n ** 18n,
        },
        labels,
      ),
      "https://app",
    ).rendered;
    expect(one.text).toContain("shortfall of $0.00"); // a 1-unit shortfall is still reported
  });
});
