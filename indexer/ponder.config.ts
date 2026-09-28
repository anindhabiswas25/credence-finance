// Ponder 0.17 config (Build Guide §10.3). S1: clock + price feeds. S2: markets, positions, Senior Vaults
// and σ. S3: the underwriter pools and the auction house (interfaces v2).
//
// Env: PONDER_CHAIN_ID (default 412346, the devnode), PONDER_RPC_URL (else PONDER_RPC_URL_<chainId>,
// else RPC_URL), PONDER_WS_URL, DATABASE_URL, DEPLOYMENTS_FILE (else deployments/<chainId>[.local].json).
import { createConfig } from "ponder";
import { parseAbiItem } from "viem";
import {
  AssetClockAbi,
  CredencePriceFeedAbi,
  IAuctionHouseAbi,
  ICredenceMarketAbi,
  IRiskEngineAbi,
  ISeniorVaultAbi,
  IUnderwriterPoolAbi,
} from "@credence/sdk";
import { indexerBook, stackAddresses } from "./src/book";

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 412346);
const rpc =
  process.env.PONDER_RPC_URL ??
  process.env[`PONDER_RPC_URL_${chainId}`] ??
  process.env.RPC_URL ??
  "http://127.0.0.1:8547";
const ws = process.env.PONDER_WS_URL ?? process.env[`PONDER_WS_URL_${chainId}`];
const book = indexerBook(
  chainId,
  process.env.DEPLOYMENTS_DIR ?? "../deployments",
);
const feeds = [book.shared.feedA, book.shared.feedB].filter(
  (a): a is `0x${string}` => !!a,
);
const ZERO = "0x0000000000000000000000000000000000000000" as const;
const markets = stackAddresses(book, "market");
// Feeds deployed before interfaces v1 (e.g. the S1 devnode stack) still emit the v0 event without
// `marketStatus` (R-25); index both so a redeploy is not required.
const reportAcceptedV0 = parseAbiItem(
  "event ReportAccepted(bytes32 indexed asset, uint8 kind, uint256 price, uint40 observedAt, uint64 seq)",
);
const priceFeedAbi = [...CredencePriceFeedAbi, reportAcceptedV0] as const;
const vaults = stackAddresses(book, "vault");
const pools = stackAddresses(book, "pool");
const houses = stackAddresses(book, "auctionHouse");

export default createConfig({
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : { kind: "pglite" },
  chains: {
    credence: {
      id: chainId,
      rpc,
      ws,
      pollingInterval: Number(process.env.PONDER_POLLING_MS ?? 1000),
    },
  },
  contracts: {
    AssetClock: {
      chain: "credence",
      abi: AssetClockAbi,
      address: book.shared.clock,
      startBlock: book.startBlock,
    },
    PriceFeed: {
      chain: "credence",
      abi: priceFeedAbi,
      address: feeds,
      startBlock: book.startBlock,
    },
    // Until a core stack is deployed these watch the zero address and index nothing.
    Market: {
      chain: "credence",
      abi: ICredenceMarketAbi,
      address: markets.length ? markets : ZERO,
      startBlock: book.startBlock,
    },
    SeniorVault: {
      chain: "credence",
      abi: ISeniorVaultAbi,
      address: vaults.length ? vaults : ZERO,
      startBlock: book.startBlock,
    },
    // S3 (interfaces v2, ADR-0110): pure projections of the pool and auction house events
    Pool: {
      chain: "credence",
      abi: IUnderwriterPoolAbi,
      address: pools.length ? pools : ZERO,
      startBlock: book.startBlock,
    },
    AuctionHouse: {
      chain: "credence",
      abi: IAuctionHouseAbi,
      address: houses.length ? houses : ZERO,
      startBlock: book.startBlock,
    },
    RiskEngine: {
      chain: "credence",
      abi: IRiskEngineAbi,
      address: book.shared.riskEngine ?? ZERO,
      startBlock: book.startBlock,
    },
  },
});
