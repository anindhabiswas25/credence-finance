// Reads pinned to an event's block (ADR-0011) need that block's state. A non-archive RPC (the nitro devnode keeps
// ~128 blocks; most free testnet RPCs are not archive) has pruned it for older events, so a (re)index from the
// deploy block fails with "missing trie node". Such a read falls back to the latest state: every later event of
// the same row re-reads it, so once the indexer has caught up the tables equal the chain; only the intermediate
// history of a pruned range is lost (event args, e.g. position_event amounts, are unaffected).
const PRUNED =
  /missing trie node|state .* is not available|historical state .* (?:is not available|unavailable)|required historical state|header not found|pruned/i;

/** True when `e` is an RPC refusing a read because that block's state was pruned. */
export function isPrunedStateError(e: unknown): boolean {
  if (!(e instanceof Error)) return PRUNED.test(String(e));
  const parts = [
    e.message,
    (e as { details?: string }).details ?? "",
    (e as { shortMessage?: string }).shortMessage ?? "",
  ];
  let c: unknown = (e as { cause?: unknown }).cause;
  for (let i = 0; c && i < 5; i++, c = (c as { cause?: unknown }).cause)
    parts.push(c instanceof Error ? c.message : String(c));
  return PRUNED.test(parts.join(" "));
}

let fallbacks = 0;
/** Pinned reads that fell back to the latest state (logged at the first and every 1,000th). */
export function notePrunedFallback(what: string, block: bigint | undefined) {
  fallbacks++;
  if (fallbacks === 1 || fallbacks % 1000 === 0)
    console.warn(
      `indexer: state at block ${block} is pruned on this RPC; ${what} read at latest instead (${fallbacks} so far). Use an archive RPC for a faithful history.`,
    );
}

type Reader = { readContract: (args: never) => Promise<unknown> };

/** `readContract` of `c` that, when the RPC pruned the pinned block's state, re-reads pinned to the head block
 * (`head()`, from a plain client on the same RPCs: Ponder's own `latest` read is cached under a fixed key, so a
 * second fallback would return a stale value). Other errors pass through. Ponder pins a read without an explicit
 * `blockNumber` to the event's block, so every read is eligible. */
export function withPrunedFallback<C extends Reader>(
  c: C,
  head: () => Promise<bigint>,
): C["readContract"] {
  return (async (args: { functionName?: unknown; blockNumber?: bigint }) => {
    try {
      return await c.readContract(args as never);
    } catch (e) {
      if (!isPrunedStateError(e)) throw e;
      notePrunedFallback(String(args.functionName), args.blockNumber);
      return c.readContract({ ...args, blockNumber: await head() } as never);
    }
  }) as C["readContract"];
}
