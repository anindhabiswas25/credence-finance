// Chainlink push Data Feeds (AggregatorV3 proxies): free to read on-chain (ADR-0009).
import { type Address, type PublicClient, parseAbi } from "viem";

export const AGGREGATOR_V3_ABI = parseAbi([
  "function description() view returns (string)",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

/** Equity push feeds on Arbitrum Sepolia (reference-data-directory, 2026-09-28): only SPY/USD exists. */
export const CHAINLINK_ARB_SEPOLIA: Record<string, Address> = {
  SPY: "0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06",
};

/** Arbitrum One equity push feeds (86,400 s heartbeat, 0.5% deviation) for the mainnet-secondary column. */
export const CHAINLINK_ARB_ONE: Record<string, Address> = {
  NVDA: "0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F",
  AAPL: "0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c",
  TSLA: "0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3",
  COIN: "0x950DC95D4E537A14283059bADC2734977C454498",
  MSFT: "0xDde33fb9F21739602806580bdd73BAd831DcA867",
  SPY: "0x46306F3795342117721D8DEd50fbcF6DF2b3cc10",
};

export interface AggregatorReading {
  proxy: Address;
  description: string;
  decimals: number;
  answer: bigint;
  updatedAt: number;
  roundId: bigint;
}

export async function readAggregator(client: PublicClient, proxy: Address): Promise<AggregatorReading> {
  const [description, decimals, round] = await Promise.all([
    client.readContract({ address: proxy, abi: AGGREGATOR_V3_ABI, functionName: "description" }),
    client.readContract({ address: proxy, abi: AGGREGATOR_V3_ABI, functionName: "decimals" }),
    client.readContract({ address: proxy, abi: AGGREGATOR_V3_ABI, functionName: "latestRoundData" }),
  ]);
  const [roundId, answer, , updatedAt] = round;
  return { proxy, description, decimals, answer, updatedAt: Number(updatedAt), roundId };
}
