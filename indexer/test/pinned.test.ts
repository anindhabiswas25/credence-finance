import { describe, expect, it } from "vitest";
import { isPrunedStateError, withPrunedFallback } from "../src/pinned";

describe("pinned reads on a non-archive RPC", () => {
  it("recognises pruned-state errors, also nested in viem's cause chain", () => {
    const nitro = new Error("ContractFunctionExecutionError: idle()");
    (nitro as { details?: string }).details =
      "missing trie node 053dd9f9 (path ) state 0x053dd9f9 is not available, not found";
    expect(isPrunedStateError(nitro)).toBe(true);
    expect(
      isPrunedStateError(
        new Error("outer", { cause: new Error("header not found") }),
      ),
    ).toBe(true);
    expect(
      isPrunedStateError("required historical state unavailable (reexec=128)"),
    ).toBe(true);
  });
  it("does not swallow real reverts or transport errors", () => {
    expect(
      isPrunedStateError(new Error("execution reverted: NoReferencePrice()")),
    ).toBe(false);
    expect(
      isPrunedStateError(new Error("HTTP request failed. Status: 503")),
    ).toBe(false);
  });
});

describe("withPrunedFallback", () => {
  const pruned = new Error("missing trie node abc");
  function fake(fail: (block: bigint | undefined) => Error | undefined) {
    const calls: (bigint | undefined)[] = [];
    let head = 500n;
    const c = {
      async readContract(args: { blockNumber?: bigint }) {
        calls.push(args.blockNumber);
        const e = fail(args.blockNumber);
        if (e) throw e;
        return args.blockNumber;
      },
    };
    return { c, calls, head: async () => head++ };
  }
  it("re-reads a pruned pinned read at the current head, each time afresh", async () => {
    const f = fake((b) => (b === 10n ? pruned : undefined));
    const read = withPrunedFallback(f.c, f.head);
    expect(
      await read({ functionName: "idle", blockNumber: 10n } as never),
    ).toBe(500n);
    expect(
      await read({ functionName: "idle", blockNumber: 10n } as never),
    ).toBe(501n);
    expect(f.calls).toEqual([10n, 500n, 10n, 501n]);
  });
  it("also covers a read Ponder pins implicitly (no blockNumber)", async () => {
    const f = fake((b) => (b === undefined ? pruned : undefined));
    expect(await withPrunedFallback(f.c, f.head)({} as never)).toBe(500n);
  });
  it("passes a read through when the state is there", async () => {
    const f = fake(() => undefined);
    expect(
      await withPrunedFallback(f.c, f.head)({ blockNumber: 480n } as never),
    ).toBe(480n);
    expect(f.calls).toEqual([480n]);
  });
  it("rethrows a revert without a second read", async () => {
    const revert = new Error("execution reverted: NoReferencePrice()");
    const f = fake(() => revert);
    await expect(
      withPrunedFallback(f.c, f.head)({ blockNumber: 10n } as never),
    ).rejects.toBe(revert);
    expect(f.calls).toEqual([10n]);
  });
});
