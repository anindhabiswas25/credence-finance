// Address book for the indexer. On a clean checkout (CI typecheck/codegen) there is no deployment yet:
// fall back to placeholder addresses so `ponder codegen` works; `ponder start` then indexes nothing.
import { loadAddressBook, type AddressBook } from "@credence/sdk/node";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export function indexerBook(chainId: number, dir: string): AddressBook {
  try {
    return loadAddressBook(chainId, dir);
  } catch (e) {
    console.warn(`[indexer] ${(e as Error).message}; using placeholder addresses`);
    return { chainId, startBlock: 0, shared: { calendar: ZERO, clock: ZERO, feedA: ZERO } } as AddressBook;
  }
}

export type Stack = "equity" | "nav";

/** Distinct `equity.<key>` / `nav.<key>` addresses (one market singleton and one vault per stack, R-01). */
export function stackAddresses(book: Pick<AddressBook, "equity" | "nav">, key: "market" | "vault"): `0x${string}`[] {
  const out = [book.equity?.[key], book.nav?.[key]].filter((a): a is `0x${string}` => !!a);
  return [...new Set(out.map((a) => a.toLowerCase() as `0x${string}`))];
}

/** Which stack a market or vault address belongs to (equity when both stacks share one address). */
export function stackOf(book: Pick<AddressBook, "equity" | "nav">, key: "market" | "vault") {
  const eq = book.equity?.[key]?.toLowerCase();
  const nav = book.nav?.[key]?.toLowerCase();
  return (addr: string): Stack => {
    const a = addr.toLowerCase();
    return a === eq ? "equity" : a === nav ? "nav" : "equity";
  };
}

/** "A" / "B" for the two relayer feeds, else the address itself. */
export function feedLabeler(book: Pick<AddressBook, "shared">) {
  const a = book.shared.feedA?.toLowerCase();
  const b = book.shared.feedB?.toLowerCase();
  return (addr: string): string => {
    const x = addr.toLowerCase();
    return x === a ? "A" : x === b ? "B" : addr;
  };
}
