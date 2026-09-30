import { describe, expect, it } from "vitest";
import {
  feedLabeler,
  indexerBook,
  rpcUrls,
  stackAddresses,
  stackOf,
} from "../src/book";

describe("indexer address book", () => {
  it("labels the two relayer feeds", () => {
    const label = feedLabeler({
      shared: {
        calendar: "0x0000000000000000000000000000000000000001",
        clock: "0x0000000000000000000000000000000000000002",
        feedA: "0x1B9CbDC65a7BebB0bE7F18d93A1896ea1FD46d7A",
        feedB: "0x47Cec0749BD110bc11F9577a70061202b1b6C034",
      },
    });
    expect(label("0x1b9cbdc65a7bebb0be7f18d93a1896ea1fd46d7a")).toBe("A");
    expect(
      label("0x47CEC0749BD110BC11F9577A70061202B1B6C034".replace("0X", "0x")),
    ).toBe("B");
    expect(label("0x0000000000000000000000000000000000000009")).toBe(
      "0x0000000000000000000000000000000000000009",
    );
  });
  it("maps market and vault addresses to their stack", () => {
    const book = {
      equity: {
        market: "0x00000000000000000000000000000000000000Aa" as const,
        vault: "0x00000000000000000000000000000000000000B1" as const,
      },
      nav: {
        market: "0x00000000000000000000000000000000000000aA" as const,
        vault: "0x00000000000000000000000000000000000000B2" as const,
      },
    };
    expect(stackAddresses(book, "market")).toEqual([
      "0x00000000000000000000000000000000000000aa",
    ]);
    expect(stackAddresses(book, "vault")).toHaveLength(2);
    expect(
      stackOf(book, "vault")("0x00000000000000000000000000000000000000b2"),
    ).toBe("nav");
    expect(
      stackOf(book, "vault")("0x00000000000000000000000000000000000000B1"),
    ).toBe("equity");
  });
  it("falls back to placeholders when no deployment exists", () => {
    const b = indexerBook(999_999, "/nonexistent");
    expect(b.shared.clock).toBe("0x0000000000000000000000000000000000000000");
  });
});

describe("rpcUrls", () => {
  it("reads a comma-separated failover list, most specific variable first", () => {
    expect(
      rpcUrls(46630, {
        PONDER_RPC_URL_46630: "https://a, https://b",
        RPC_URL: "x",
      }),
    ).toEqual(["https://a", "https://b"]);
    expect(
      rpcUrls(421614, {
        PONDER_RPC_URL_46630: "https://a",
        RPC_URL: "https://r",
      }),
    ).toEqual(["https://r"]);
    expect(rpcUrls(1, {})).toEqual(["http://127.0.0.1:8547"]);
  });
});
