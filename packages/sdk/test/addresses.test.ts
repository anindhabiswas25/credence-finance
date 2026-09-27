import { describe, expect, it } from "vitest";
import { parseAddressBook } from "../src/addresses.js";
import { assetId, venueId } from "../src/eip712.js";
import { ClockState, clockStateName } from "../src/types.js";
import { abis, ICredencePriceFeedAbi, IAssetClockAbi } from "../src/generated/abis.js";

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

describe("ABIs (deployments/abis/v0)", () => {
  it("exposes the price feed and clock", () => {
    const names = (ICredencePriceFeedAbi as readonly { type: string; name?: string }[]).map((x) => x.name);
    expect(names).toContain("submit");
    expect(names).toContain("ReportAccepted");
    expect((IAssetClockAbi as readonly { name?: string }[]).some((x) => x.name === "StateChanged")).toBe(true);
    expect(Object.keys(abis).length).toBeGreaterThanOrEqual(27);
  });
});
