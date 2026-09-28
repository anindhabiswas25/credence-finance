import { describe, expect, it } from "vitest";
import { parseAddressBook } from "../src/addresses.js";
import { assetId, venueId } from "../src/eip712.js";
import { ClockState, clockStateName } from "../src/types.js";
import { ABI_VERSION, abis, ICredenceMarketAbi, ICredencePriceFeedAbi, IAssetClockAbi, ISeniorVaultAbi } from "../src/generated/abis.js";

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
    expect(b.shared.timelock).toBe("0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E");
    expect(b.equity?.markets?.NVDA).toBe("0x" + "11".repeat(32));
  });
  it("rejects a wrong chain and bad addresses", () => {
    expect(() => parseAddressBook(book, 421614)).toThrow(/chain 412346/);
    expect(() => parseAddressBook({ ...book, shared: { ...book.shared, clock: "0x12" } })).toThrow();
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
    expect(assetId("nvda", "xnas")).toBe("0x2ba7fe0221993f0b564e6bd78704eab0e0162888663625d7124a5d01aa95c620");
    expect(venueId("XNYS")).toBe("0x584e5953" + "00".repeat(28));
  });
  it("clock states match Types.sol", () => {
    expect(ClockState.REOPEN).toBe(3);
    expect(clockStateName(4)).toBe("HALTED");
  });
});

describe("ABIs (deployments/abis/v2)", () => {
  it("exposes the price feed and clock", () => {
    const names = (ICredencePriceFeedAbi as readonly { type: string; name?: string }[]).map((x) => x.name);
    expect(names).toContain("submit");
    expect(names).toContain("ReportAccepted");
    expect((IAssetClockAbi as readonly { name?: string }[]).some((x) => x.name === "StateChanged")).toBe(true);
    expect(Object.keys(abis).length).toBeGreaterThanOrEqual(37);
    expect(ABI_VERSION).toBe("v2");
  });

  it("ReportAccepted carries marketStatus (R-25) and the market/vault v1 views exist", () => {
    const ev = (ICredencePriceFeedAbi as unknown as readonly { type: string; name?: string; inputs?: readonly { name: string }[] }[]).find(
      (x) => x.type === "event" && x.name === "ReportAccepted",
    );
    expect(ev?.inputs?.map((i) => i.name)).toEqual(["asset", "kind", "price", "observedAt", "seq", "marketStatus"]);
    const market = (ICredenceMarketAbi as readonly { name?: string }[]).map((x) => x.name);
    for (const f of ["bellStatus", "projectedDebt", "marketIds", "upcomingClosureId", "claimFees"]) expect(market).toContain(f);
    const vault = (ISeniorVaultAbi as readonly { name?: string }[]).map((x) => x.name);
    for (const f of ["processQueue", "requestRedeem", "queueHead", "pendingRedeemShares"]) expect(vault).toContain(f);
  });
});

describe("S2 address book (ADR-0105)", () => {
  it("parses the nested book with null stacks and ignores the deprecated flat keys", () => {
    const b = parseAddressBook({
      chainId: 412346,
      startBlock: 1,
      clock: "0x0000000000000000000000000000000000000009",
      shared: { calendar: "0x0000000000000000000000000000000000000001", clock: "0x0000000000000000000000000000000000000002", feedA: "0x0000000000000000000000000000000000000003", riskEngine: "0x0000000000000000000000000000000000000004" },
      assetIds: { NVDA: "0x" + "22".repeat(32) },
      equity: null,
      nav: null,
    });
    expect(b.shared.clock).toBe("0x0000000000000000000000000000000000000002");
    expect(b.shared.riskEngine).toBe("0x0000000000000000000000000000000000000004");
    expect(b.equity ?? undefined).toBeUndefined();
    expect(b.assetIds?.NVDA).toBe("0x" + "22".repeat(32));
  });
});
