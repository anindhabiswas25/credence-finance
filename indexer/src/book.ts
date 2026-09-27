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

/** "A" / "B" for the two relayer feeds, else the address itself. */
export function feedLabeler(book: Pick<AddressBook, "shared">) {
  const a = book.shared.feedA?.toLowerCase();
  const b = book.shared.feedB?.toLowerCase();
  return (addr: string): string => {
    const x = addr.toLowerCase();
    return x === a ? "A" : x === b ? "B" : addr;
  };
}
