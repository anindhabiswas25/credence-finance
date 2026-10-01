// The loan token of a chain's markets (ADR-0014): tUSDG on Robinhood Chain, USDC on Arbitrum. Never assumed:
// an explicit LOAN_SYMBOL_<id> / LOAN_DECIMALS_<id>, else `symbol()` / `decimals()` of the book's loan token
// through the chain's RPC, else a local book whose loan token is keyed `usdc`.
import type { ChainScanConfig } from "./config.ts";

export interface LoanToken {
  symbol: string;
  decimals: number;
}

type Book = { tokens?: Record<string, string> };

/** The loan token's address in a book: `tokens.loan` (testnet books) or `tokens.usdc` (local books). */
export function loanAddress(book: Book): string | undefined {
  return book.tokens?.loan ?? book.tokens?.usdc;
}

/** ABI-decode a `string` return value (or a bytes32 one, as some old tokens return). */
export function decodeString(hex: string): string {
  const h = hex.replace(/^0x/, "");
  if (h.length === 64)
    return Buffer.from(h, "hex").toString("utf8").replace(/\0+$/, "");
  const off = Number(BigInt(`0x${h.slice(0, 64)}`)) * 2;
  const len = Number(BigInt(`0x${h.slice(off, off + 64)}`));
  return Buffer.from(h.slice(off + 64, off + 64 + len * 2), "hex").toString(
    "utf8",
  );
}

async function ethCall(rpc: string, to: string, data: string): Promise<string> {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to, data }, "latest"],
    }),
    signal: AbortSignal.timeout(5000),
  });
  const j = (await res.json()) as {
    result?: string;
    error?: { message: string };
  };
  if (!j.result || j.result === "0x")
    throw new Error(
      `eth_call ${data} on ${to}: ${j.error?.message ?? "empty"}`,
    );
  return j.result;
}

export async function resolveLoanToken(
  c: ChainScanConfig,
  book: Book,
  call: typeof ethCall = ethCall,
): Promise<LoanToken> {
  if (c.loanSymbol)
    return { symbol: c.loanSymbol, decimals: c.loanDecimals ?? 6 };
  const addr = loanAddress(book);
  if (c.rpcUrl && addr) {
    // S5: RPC_URL_<id> may be an ordered failover list (comma-separated): the first that answers
    let last: unknown;
    for (const url of c.rpcUrl
      .split(",")
      .map((u) => u.trim())
      .filter(Boolean)) {
      try {
        const [s, d] = await Promise.all([
          call(url, addr, "0x95d89b41"), // symbol()
          call(url, addr, "0x313ce567"), // decimals()
        ]);
        return {
          symbol: decodeString(s),
          decimals: c.loanDecimals ?? Number(BigInt(d)),
        };
      } catch (e) {
        last = e;
      }
    }
    throw last;
  }
  if (book.tokens?.usdc && !book.tokens.loan)
    return { symbol: "USDC", decimals: c.loanDecimals ?? 6 }; // a local book names its loan token
  throw new Error(
    `chain ${c.chainId}: set LOAN_SYMBOL_${c.chainId} (and LOAN_DECIMALS_${c.chainId}) or RPC_URL_${c.chainId}`,
  );
}
