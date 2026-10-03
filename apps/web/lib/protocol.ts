/**
 * The deployed protocol, as the web app sees it: the two testnet chains, each stack's contracts
 * (from the generated address book) and display names for every market. Equity (stock tokens)
 * lives on Robinhood Chain testnet; the NAV stack (Treasury funds) on Arbitrum Sepolia.
 */
import { defineChain, type Address, type Hex } from "viem";
import { arbitrumSepolia } from "viem/chains";
import { BOOKS } from "./generated/books";

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.NEXT_PUBLIC_RPC_46630 ?? "https://rpc.testnet.chain.robinhood.com"] },
  },
  blockExplorers: {
    default: { name: "Explorer", url: "https://explorer.testnet.chain.robinhood.com" },
  },
  testnet: true,
});

export const arbSepolia = defineChain({
  ...arbitrumSepolia,
  rpcUrls: {
    default: { http: [process.env.NEXT_PUBLIC_RPC_421614 ?? "https://sepolia-rollup.arbitrum.io/rpc"] },
  },
});

export const CHAINS = [robinhoodTestnet, arbSepolia] as const;
export type ChainId = (typeof CHAINS)[number]["id"];
export type Stack = "equity" | "nav";

export type StackBook = {
  chainId: ChainId;
  stack: Stack;
  chainName: string;
  loanSymbol: string;
  loanDecimals: number;
  market: Address;
  vault: Address;
  pool: Address;
  reserve: Address | null;
  auctionHouse: Address | null;
  faucet: Address | null;
  loanToken: Address;
  markets: Record<string, { marketId: Hex; assetId: Hex; token: Address | null }>;
};

const LOAN: Record<Stack, { symbol: string; chainName: string }> = {
  equity: { symbol: "tUSDG", chainName: "Robinhood Chain" },
  nav: { symbol: "USDC", chainName: "Arbitrum Sepolia" },
};

export const STACKS: Record<Stack, StackBook> = Object.fromEntries(
  BOOKS.map((b) => [
    b.stack,
    {
      chainId: b.chainId as ChainId,
      stack: b.stack as Stack,
      chainName: LOAN[b.stack as Stack].chainName,
      loanSymbol: LOAN[b.stack as Stack].symbol,
      loanDecimals: 6,
      market: b.market as Address,
      vault: b.vault as Address,
      pool: b.pool as Address,
      reserve: (b.reserve ?? null) as Address | null,
      auctionHouse: (b.auctionHouse ?? null) as Address | null,
      faucet: (b.faucet ?? null) as Address | null,
      loanToken: b.loanToken as Address,
      markets: b.markets as StackBook["markets"],
    },
  ]),
) as Record<Stack, StackBook>;

export const stackOfChain = (chainId: number): StackBook =>
  chainId === STACKS.nav.chainId ? STACKS.nav : STACKS.equity;

export const MARKET_NAMES: Record<string, string> = {
  AAPL: "Apple",
  AMZN: "Amazon",
  GOOGL: "Alphabet",
  MSFT: "Microsoft",
  NVDA: "NVIDIA",
  TSLA: "Tesla",
  RHTSLA: "Tesla (Robinhood Stock Token)",
  TBILL: "Credence Test T-Bill Fund",
};

/** Market id (lower-case) → symbol and stack, from the address book. */
export const MARKET_INDEX: Record<string, { symbol: string; stack: Stack; chainId: ChainId; assetId: Hex; token: Address | null }> =
  Object.fromEntries(
    Object.values(STACKS).flatMap((s) =>
      Object.entries(s.markets).map(([symbol, m]) => [
        m.marketId.toLowerCase(),
        { symbol, stack: s.stack, chainId: s.chainId, assetId: m.assetId, token: m.token },
      ]),
    ),
  );

/** Asset id (lower-case) → symbol. */
export const ASSET_SYMBOL: Record<string, string> = Object.fromEntries(
  Object.values(MARKET_INDEX).map((m) => [m.assetId.toLowerCase(), m.symbol]),
);

/** Display ticker: the Robinhood token keeps the TSLA ticker with a suffix. */
export const ticker = (symbol: string) => (symbol === "RHTSLA" ? "TSLA·RH" : symbol);

/** Logo of an asset or loan token in /public/tokens (test tokens use their real counterpart's logo); null = no logo. */
const LOGO: Record<string, string> = {
  AAPL: "aapl", NVDA: "nvda", TSLA: "tsla", RHTSLA: "tsla", MSFT: "msft", GOOGL: "googl", AMZN: "amzn",
  TBILL: "tbill", USDC: "usdc", USDG: "usdg",
};
export const tokenLogo = (symbol: string): string | null => {
  const s = symbol.replace(/^t(?=[A-Z])/, "");
  return LOGO[s] ? `/tokens/${LOGO[s]}.svg` : null;
};

export const explorerTx = (chainId: number, hash: string) =>
  `${(chainId === arbSepolia.id ? arbSepolia : robinhoodTestnet).blockExplorers.default.url}/tx/${hash}`;

export const shortAddress = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
