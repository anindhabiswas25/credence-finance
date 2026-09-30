// ADR-0014 (S5 Amendment 1): one notifier for both chains, the market's own loan token, the corporate-action
// alert (ERC-8056, ADR-0119).
import { describe, expect, it } from "vitest";
import { chainScans, loadConfig } from "../src/config.ts";
import { decodeString, resolveLoanToken } from "../src/loan.ts";
import { usd, usdNearest } from "../src/format.ts";
import {
  corporateActionPayload,
  labelsFromBook,
  type Labels,
} from "../src/producer.ts";
import { isLargeStep, render } from "../src/templates.ts";

const base = { DATABASE_URL: "postgres://x" };
const WAD = 10n ** 18n;

describe("per-chain scans", () => {
  it("one chain keeps the legacy variables", () => {
    const c = loadConfig({
      ...base,
      INDEXER_SCHEMA: "indexer_e2e",
      DEPLOYMENTS_FILE: "b.json",
    }).scan.chains;
    expect(c).toEqual([
      expect.objectContaining({
        chainId: 412346,
        schema: "indexer_e2e",
        bookFile: "b.json",
      }),
    ]);
  });
  it("two chains get their own schema, book, loan token and RPC", () => {
    const c = loadConfig({
      ...base,
      NOTIFIER_CHAINS: "46630, 421614",
      LOAN_SYMBOL_46630: "tUSDG",
      LOAN_DECIMALS_46630: "6",
      RPC_URL_421614: "https://arb",
      RPC_URL: "https://ignored-with-two-chains",
    }).scan.chains;
    expect(c).toEqual([
      {
        chainId: 46630,
        schema: "ix_46630",
        bookFile: "deployments/46630.json",
        loanSymbol: "tUSDG",
        loanDecimals: 6,
        rpcUrl: undefined,
      },
      {
        chainId: 421614,
        schema: "ix_421614",
        bookFile: "deployments/421614.json",
        loanSymbol: undefined,
        loanDecimals: undefined,
        rpcUrl: "https://arb",
      },
    ]);
  });
  it("refuses a duplicate chain or a bad schema", () => {
    expect(() =>
      loadConfig({ ...base, NOTIFIER_CHAINS: "46630,46630" }),
    ).toThrow(/duplicate/);
    expect(() =>
      loadConfig({
        ...base,
        NOTIFIER_CHAINS: "46630,421614",
        INDEXER_SCHEMA_46630: "ix; drop",
      }),
    ).toThrow(/bad schema/);
    expect(chainScans).toBeTypeOf("function");
  });
});

describe("the loan token is never assumed", () => {
  const abiString = (s: string) => {
    const hex = Buffer.from(s, "utf8").toString("hex");
    return `0x${(32).toString(16).padStart(64, "0")}${s.length.toString(16).padStart(64, "0")}${hex.padEnd(64, "0")}`;
  };
  it("decodes string and bytes32 symbols", () => {
    expect(decodeString(abiString("tUSDG"))).toBe("tUSDG");
    expect(
      decodeString(`0x${Buffer.from("USDC").toString("hex").padEnd(64, "0")}`),
    ).toBe("USDC");
  });
  it("reads symbol and decimals of the book's loan token through the chain's RPC", async () => {
    const calls: string[] = [];
    const t = await resolveLoanToken(
      {
        chainId: 46630,
        schema: "ix_46630",
        bookFile: "",
        rpcUrl: "https://rh",
      },
      { tokens: { loan: "0xabc", tNVDA: "0xdef" } },
      async (_rpc, to, data) => {
        calls.push(`${to}:${data}`);
        return data === "0x95d89b41" ? abiString("tUSDG") : "0x06";
      },
    );
    expect(t).toEqual({ symbol: "tUSDG", decimals: 6 });
    expect(calls).toEqual(["0xabc:0x95d89b41", "0xabc:0x313ce567"]);
  });
  it("a testnet book without RPC or override fails at start; a local usdc book is USDC", async () => {
    const c = { chainId: 421614, schema: "ix", bookFile: "" };
    await expect(
      resolveLoanToken(c, { tokens: { loan: "0x1" } }),
    ).rejects.toThrow(/LOAN_SYMBOL_421614/);
    expect(await resolveLoanToken(c, { tokens: { usdc: "0x1" } })).toEqual({
      symbol: "USDC",
      decimals: 6,
    });
  });
  it("money prints the market's symbol, or $ without one", () => {
    expect(usd(2_896_775_001n, 6, "tUSDG")).toBe("2,896.78 tUSDG");
    expect(usdNearest(2_896_775_001n, 6, "USDC")).toBe("2,896.78 USDC");
    expect(usd(2_896_775_001n, 6)).toBe("$2,896.78");
  });
  it("a withdrawal on Robinhood Chain says tUSDG and links with its chain", () => {
    const { rendered } = render(
      "withdrawal_claimable",
      {
        stack: "equity",
        epochId: "7",
        shares: "1000000000000000000000",
        assets: "1234560000",
        loanDecimals: 6,
        loanSymbol: "tUSDG",
        chainId: 46630,
        chainName: "Robinhood Chain testnet",
      },
      "https://app.test",
    );
    expect(rendered.subject).toBe("Withdrawal ready: claim 1,234.56 tUSDG");
    expect(rendered.text).toContain("claim=equity:7&chain=46630");
    expect(rendered.text).not.toContain("$");
  });
});

describe("corporate-action alert", () => {
  const labels: Labels = labelsFromBook({
    equity: { markets: { NVDA: "0x" + "11".repeat(32) } },
  });
  const id = "0x" + "11".repeat(32);
  const tag = { chainId: 46630, chainName: "Robinhood Chain testnet" };
  const out = (p: object) =>
    render("corporate_action", { ...p, ...tag }, "https://app.test").rendered;

  it("a 2-for-1 split, days ahead: the early warning names the pause", () => {
    const p = corporateActionPayload(
      {
        kind: "scheduled",
        marketId: id,
        oldValue: WAD,
        newValue: 2n * WAD,
        effectiveAt: 1_790_870_400n,
        closureId: null,
      },
      labels,
    );
    const r = out(p);
    expect(r.subject).toMatch(/^NVDA: tNVDA multiplier changes /);
    expect(r.text).toContain("from 1.00 to 2.00 shares per token");
    expect(r.text).toContain("on Robinhood Chain testnet");
    expect(r.text).toContain("no new borrowing and no liquidations");
    expect(r.text).toContain(`/markets/${id}?chain=46630`);
  });
  it("a reverse split (1:3) is a large step too; a 1 % dividend is not", () => {
    expect(isLargeStep(WAD.toString(), (WAD / 3n).toString())).toBe(true);
    expect(isLargeStep(WAD.toString(), ((WAD * 101n) / 100n).toString())).toBe(
      false,
    );
    expect(isLargeStep(WAD.toString(), ((WAD * 102n) / 100n).toString())).toBe(
      false,
    ); // exactly 2 %: applied at once
    const r = out(
      corporateActionPayload(
        {
          kind: "scheduled",
          marketId: id,
          oldValue: WAD,
          newValue: (WAD * 101n) / 100n,
          effectiveAt: 1_790_870_400n,
          closureId: null,
        },
        labels,
      ),
    );
    expect(r.text).toContain("applied at once with no pause");
  });
  it("begun, confirmed and cancelled", () => {
    const mk = (kind: "begun" | "confirmed" | "cancelled") =>
      out(
        corporateActionPayload(
          {
            kind,
            marketId: id,
            oldValue: null,
            newValue: kind === "confirmed" ? 2n * WAD : null,
            effectiveAt: null,
            closureId: kind === "begun" ? 9n : null,
          },
          labels,
        ),
      );
    expect(mk("begun").subject).toBe("NVDA: corporate action started");
    expect(mk("confirmed").text).toContain("now counts 2.00 shares per token");
    expect(mk("cancelled").subject).toBe(
      "NVDA: tNVDA multiplier change cancelled",
    );
  });
});

describe("Amendment 2: channels", () => {
  it("in-app only by default; others only when listed; unknown refused", () => {
    expect([...loadConfig(base).worker.enabled!]).toEqual(["inapp"]);
    expect([
      ...loadConfig({ ...base, NOTIFIER_CHANNELS: "inapp,telegram" }).worker
        .enabled!,
    ]).toEqual(["inapp", "telegram"]);
    expect(() =>
      loadConfig({ ...base, NOTIFIER_CHANNELS: "inapp,sms" }),
    ).toThrow(/unknown channel sms/);
  });
});
