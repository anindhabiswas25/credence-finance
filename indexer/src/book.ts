// Address book for the indexer. On a clean checkout (CI typecheck/codegen) there is no deployment yet:
// fall back to placeholder addresses so `ponder codegen` works; `ponder start` then indexes nothing.
import { loadAddressBook, type AddressBook } from "@credence/sdk/node";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export function indexerBook(chainId: number, dir: string): AddressBook {
  try {
    return loadAddressBook(chainId, dir);
  } catch (e) {
    console.warn(
      `[indexer] ${(e as Error).message}; using placeholder addresses`,
    );
    return {
      chainId,
      startBlock: 0,
      shared: { calendar: ZERO, clock: ZERO, feedA: ZERO },
    } as AddressBook;
  }
}

export type Stack = "equity" | "nav";

/** Distinct `equity.<key>` / `nav.<key>` addresses (one market singleton and one vault per stack, R-01). */
export function stackAddresses(
  book: Pick<AddressBook, "equity" | "nav">,
  key: "market" | "vault" | "pool" | "auctionHouse",
): `0x${string}`[] {
  // the NAV stack has no auction house (its settlement adapter replaces it)
  const get = (st: unknown) =>
    (st as Partial<Record<typeof key, `0x${string}`>> | null | undefined)?.[
      key
    ];
  const out = [get(book.equity), get(book.nav)].filter(
    (a): a is `0x${string}` => !!a,
  );
  return [...new Set(out.map((a) => a.toLowerCase() as `0x${string}`))];
}

/** Which stack a market or vault address belongs to (equity when both stacks share one address). */
export function stackOf(
  book: Pick<AddressBook, "equity" | "nav">,
  key: "market" | "vault" | "pool" | "auctionHouse",
) {
  const get = (st: unknown) =>
    (st as Partial<Record<typeof key, string>> | null | undefined)?.[key];
  const eq = get(book.equity)?.toLowerCase();
  const nav = get(book.nav)?.toLowerCase();
  return (addr: string): Stack => {
    const a = addr.toLowerCase();
    return a === eq ? "equity" : a === nav ? "nav" : "equity";
  };
}

/** "A" / "B" for the two relayer feeds, "NAV" for the NAV stack's feed (S5), else the address itself. */
export function feedLabeler(book: Pick<AddressBook, "shared">) {
  const a = book.shared.feedA?.toLowerCase();
  const b = book.shared.feedB?.toLowerCase();
  const nav = book.shared.feedNav?.toLowerCase();
  return (addr: string): string => {
    const x = addr.toLowerCase();
    return x === a ? "A" : x === b ? "B" : x === nav ? "NAV" : addr;
  };
}

/** The indexer's RPCs in failover order: PONDER_RPC_URL, else PONDER_RPC_URL_<chainId>, else RPC_URL, each a
 * comma-separated list (Ponder falls back through them in order; ADR-0014 wants ≥ 2 per chain in prod). */
export function rpcUrls(
  chainId: number,
  env: Record<string, string | undefined> = process.env,
): string[] {
  const raw =
    env.PONDER_RPC_URL ??
    env[`PONDER_RPC_URL_${chainId}`] ??
    env.RPC_URL ??
    "http://127.0.0.1:8547";
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** The book's collateral tokens (`tokens.*` except the loan token: `loan` on testnet books, `usdc` locally). */
export function collateralTokenAddresses(book: AddressBook): `0x${string}`[] {
  return Object.entries(book.tokens ?? {})
    .filter(([k]) => k !== "loan" && k.toLowerCase() !== "usdc")
    .map(([, a]) => a as `0x${string}`);
}
