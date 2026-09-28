// Pyth Core (ADR-0009). Since the Core upgrade (switch 2026-07-31, completed 2026-08-26) Hermes price
// updates need a paid API key, so nobody pushes equity updates to the public Sepolia contract any more.
// The reader shows that: the on-chain price is frozen at its last pushed publishTime.
import { type Address, type Hex, type PublicClient, parseAbi } from "viem";

export const PYTH_ARB_SEPOLIA: Address = "0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF";
export const HERMES = "https://hermes.pyth.network";

export const PYTH_ABI = parseAbi([
  "struct Price { int64 price; uint64 conf; int32 expo; uint256 publishTime; }",
  "function getPriceUnsafe(bytes32 id) view returns (Price)",
]);

/** `Equity.US.<T>/USD` regular-session feed ids (Hermes /v2/price_feeds, 2026-09-28). */
export const PYTH_EQUITY_IDS: Record<string, Hex> = {
  NVDA: "0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593",
  AAPL: "0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688",
  TSLA: "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1",
  COIN: "0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245",
  MSFT: "0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1",
  SPY: "0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5",
};

export interface PythReading {
  id: Hex;
  price: bigint;
  conf: bigint;
  expo: number;
  publishTime: number;
}

export async function readPythUnsafe(client: PublicClient, id: Hex, pyth: Address = PYTH_ARB_SEPOLIA): Promise<PythReading> {
  const p = await client.readContract({ address: pyth, abi: PYTH_ABI, functionName: "getPriceUnsafe", args: [id] });
  return { id, price: p.price, conf: p.conf, expo: p.expo, publishTime: Number(p.publishTime) };
}

/** HTTP status of an unauthenticated Hermes price-update request (401 since the Core upgrade). */
export async function hermesUpdateStatus(id: Hex, fetchImpl: typeof fetch = fetch): Promise<number> {
  const res = await fetchImpl(`${HERMES}/v2/updates/price/latest?ids%5B%5D=${id.slice(2)}&parsed=true`, {
    signal: AbortSignal.timeout(15_000),
  });
  return res.status;
}
