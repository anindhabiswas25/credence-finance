// Ponder 0.17 config (Build Guide §10.3). Sprint 1 indexes the clock and the price feeds; the money
// contracts (market, vault, pool, auctions, settlement) join in S2/S3 with their handlers.
//
// Env: PONDER_CHAIN_ID (default 412346, the devnode), PONDER_RPC_URL (else PONDER_RPC_URL_<chainId>,
// else RPC_URL), PONDER_WS_URL, DATABASE_URL, DEPLOYMENTS_FILE (else deployments/<chainId>[.local].json).
import { createConfig } from "ponder";
import { AssetClockAbi, CredencePriceFeedAbi } from "@credence/sdk";
import { indexerBook } from "./src/book";

const chainId = Number(process.env.PONDER_CHAIN_ID ?? 412346);
const rpc =
  process.env.PONDER_RPC_URL ?? process.env[`PONDER_RPC_URL_${chainId}`] ?? process.env.RPC_URL ?? "http://127.0.0.1:8547";
const ws = process.env.PONDER_WS_URL ?? process.env[`PONDER_WS_URL_${chainId}`];
const book = indexerBook(chainId, process.env.DEPLOYMENTS_DIR ?? "../deployments");
const feeds = [book.shared.feedA, book.shared.feedB].filter((a): a is `0x${string}` => !!a);

export default createConfig({
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : { kind: "pglite" },
  chains: {
    credence: { id: chainId, rpc, ws, pollingInterval: Number(process.env.PONDER_POLLING_MS ?? 1000) },
  },
  contracts: {
    AssetClock: { chain: "credence", abi: AssetClockAbi, address: book.shared.clock, startBlock: book.startBlock },
    PriceFeed: { chain: "credence", abi: CredencePriceFeedAbi, address: feeds, startBlock: book.startBlock },
  },
});
