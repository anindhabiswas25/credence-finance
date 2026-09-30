import { describe, expect, it } from "vitest";
import { getAddress } from "viem";
import { parseAddressBook } from "../src/addresses.js";
import { assetId, venueId } from "../src/eip712.js";
import { ClockState, clockStateName } from "../src/types.js";
import {
  ABI_VERSION,
  abis,
  ICredenceMarketAbi,
  ICredencePriceFeedAbi,
  IAssetClockAbi,
  ISeniorVaultAbi,
  AssetClockAbi,
  IOracleAdapterAbi,
  IScaledUIAmountAbi,
} from "../src/generated/abis.js";

const book = {
  chainId: 412346,
  startBlock: 0,
  release: "local",
  shared: {
    timelock: "0x3f1eae7d46d88f08fc2f8ed27fcb2ab183eb2d0e",
    calendar: "0x0000000000000000000000000000000000000001",
    clock: "0x0000000000000000000000000000000000000002",
    feedA: "0x0000000000000000000000000000000000000003",
  },
  equity: { markets: { NVDA: "0x" + "11".repeat(32) } },
};

describe("address book (§13.2)", () => {
  it("parses and checksums", () => {
    const b = parseAddressBook(book, 412346);
    expect(b.shared.timelock).toBe(
      "0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E",
    );
    expect(b.equity?.markets?.NVDA).toBe("0x" + "11".repeat(32));
  });
  it("rejects a wrong chain and bad addresses", () => {
    expect(() => parseAddressBook(book, 421614)).toThrow(/chain 412346/);
    expect(() =>
      parseAddressBook({ ...book, shared: { ...book.shared, clock: "0x12" } }),
    ).toThrow();
  });
});

describe("local (flat) address book", () => {
  it("is lifted into the §13.2 shape", () => {
    const b = parseAddressBook(
      {
        chainId: 31337,
        startBlock: 3,
        calendar: "0x0000000000000000000000000000000000000001",
        clock: "0x0000000000000000000000000000000000000002",
        feedA: "0x0000000000000000000000000000000000000003",
        feedB: "0x0000000000000000000000000000000000000004",
        tNVDA: "0x0000000000000000000000000000000000000005",
        assetId_NVDA: "0x" + "22".repeat(32),
      },
      31337,
    );
    expect(b.shared.clock).toBe("0x0000000000000000000000000000000000000002");
    expect(b.shared.feedB).toBe("0x0000000000000000000000000000000000000004");
    expect(b.tokens?.tNVDA).toBe("0x0000000000000000000000000000000000000005");
    expect(b.assetIds?.NVDA).toBe("0x" + "22".repeat(32));
    expect(b.startBlock).toBe(3);
  });
});

describe("ids and enums", () => {
  it("asset and venue ids", () => {
    expect(assetId("nvda", "xnas")).toBe(
      "0x2ba7fe0221993f0b564e6bd78704eab0e0162888663625d7124a5d01aa95c620",
    );
    expect(venueId("XNYS")).toBe("0x584e5953" + "00".repeat(28));
  });
  it("clock states match Types.sol", () => {
    expect(ClockState.REOPEN).toBe(3);
    expect(clockStateName(4)).toBe("HALTED");
  });
});

describe("ABIs (deployments/abis/v4)", () => {
  it("exposes the price feed and clock", () => {
    const names = (
      ICredencePriceFeedAbi as readonly { type: string; name?: string }[]
    ).map((x) => x.name);
    expect(names).toContain("submit");
    expect(names).toContain("ReportAccepted");
    expect(
      (IAssetClockAbi as readonly { name?: string }[]).some(
        (x) => x.name === "StateChanged",
      ),
    ).toBe(true);
    expect(Object.keys(abis).length).toBeGreaterThanOrEqual(37);
    expect(ABI_VERSION).toBe("v4");
  });

  it("v4 carries the ERC-8056 multiplier the API and notifier read (ADR-0119)", () => {
    const names = (a: readonly unknown[]) =>
      (a as readonly { name?: string }[]).map((x) => x.name);
    expect(names(IOracleAdapterAbi)).toEqual(
      expect.arrayContaining(["sharesPerToken", "multiplierState"]),
    );
    expect(names(AssetClockAbi)).toEqual(
      expect.arrayContaining([
        "multiplierAction",
        "CorporateActionBegun",
        "CorporateActionConfirmed",
      ]),
    );
    expect(names(IScaledUIAmountAbi)).toContain("UIMultiplierUpdated");
  });

  it("ReportAccepted carries marketStatus (R-25) and the market/vault v1 views exist", () => {
    const ev = (
      ICredencePriceFeedAbi as unknown as readonly {
        type: string;
        name?: string;
        inputs?: readonly { name: string }[];
      }[]
    ).find((x) => x.type === "event" && x.name === "ReportAccepted");
    expect(ev?.inputs?.map((i) => i.name)).toEqual([
      "asset",
      "kind",
      "price",
      "observedAt",
      "seq",
      "marketStatus",
    ]);
    const market = (ICredenceMarketAbi as readonly { name?: string }[]).map(
      (x) => x.name,
    );
    for (const f of [
      "bellStatus",
      "projectedDebt",
      "marketIds",
      "upcomingClosureId",
      "claimFees",
    ])
      expect(market).toContain(f);
    const vault = (ISeniorVaultAbi as readonly { name?: string }[]).map(
      (x) => x.name,
    );
    for (const f of [
      "processQueue",
      "requestRedeem",
      "queueHead",
      "pendingRedeemShares",
    ])
      expect(vault).toContain(f);
  });
});

describe("S2 address book (ADR-0105)", () => {
  it("parses the nested book with null stacks and ignores the deprecated flat keys", () => {
    const b = parseAddressBook({
      chainId: 412346,
      startBlock: 1,
      clock: "0x0000000000000000000000000000000000000009",
      shared: {
        calendar: "0x0000000000000000000000000000000000000001",
        clock: "0x0000000000000000000000000000000000000002",
        feedA: "0x0000000000000000000000000000000000000003",
        riskEngine: "0x0000000000000000000000000000000000000004",
      },
      assetIds: { NVDA: "0x" + "22".repeat(32) },
      equity: null,
      nav: null,
    });
    expect(b.shared.clock).toBe("0x0000000000000000000000000000000000000002");
    expect(b.shared.riskEngine).toBe(
      "0x0000000000000000000000000000000000000004",
    );
    expect(b.equity ?? undefined).toBeUndefined();
    expect(b.assetIds?.NVDA).toBe("0x" + "22".repeat(32));
  });
});

describe("ABIs v3 (S4, ADR-0111): the NAV settlement stack", () => {
  it("binds the adapter, the solver venue and the pool's redemption claims", async () => {
    const { ISettlementAdapterAbi, ISolverAuctionAbi, IUnderwriterPoolAbi } =
      await import("../src/index.js");
    const names = (abi: readonly { name?: string }[]) => abi.map((x) => x.name);
    expect(names(ISettlementAdapterAbi)).toEqual(
      expect.arrayContaining([
        "openSettlement",
        "finalize",
        "SettlementOpened",
      ]),
    );
    expect(names(ISolverAuctionAbi)).toEqual(
      expect.arrayContaining(["bid", "minBid", "SolverBid"]),
    );
    expect(names(IUnderwriterPoolAbi)).toEqual(
      expect.arrayContaining([
        "claimRedemption",
        "redemptionClaimsOutstanding",
      ]),
    );
  });
});

describe("per-chain books (ADR-0014)", () => {
  it("parses a NAV-only book (421614: feedNav, no equity feeds) and an equity-only one", () => {
    const a = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
    const nav = parseAddressBook({
      chainId: 421614,
      startBlock: 1,
      shared: { clock: a(1), calendar: a(2), oracle: a(3), feedNav: a(4) },
      nav: {
        market: a(5),
        settlement: a(6),
        markets: { TBILL: `0x${"07".repeat(32)}` },
      },
      tokens: { loan: a(8), tTBILL: a(9) },
    });
    expect(nav.shared.feedA).toBeUndefined();
    expect(nav.shared.feedNav).toBe(getAddress(a(4)));
    const eq = parseAddressBook({
      chainId: 46630,
      startBlock: 1,
      shared: { clock: a(1), calendar: a(2), feedA: a(3), feedB: a(4) },
      equity: { market: a(5) },
      tokens: { loan: a(8) },
    });
    expect(eq.nav).toBeUndefined();
  });
});
