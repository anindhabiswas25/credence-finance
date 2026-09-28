// R-26 probe (ADR-0009): read every candidate feed against Arbitrum Sepolia and print one JSON report.
//
//   node dist/probe.js [--rpc <url>] [--verifier <forge artifact json>] [--out <file>]
//
// --verifier: a compiled RedStone consumer exposing `read(bytes32[]) returns (uint256[], uint256)`
// (built by `make r26-probe` from the npm connector into target/, never committed: BUSL-1.1). When
// given, the RedStone payload is verified by RedStone's own Solidity code on Sepolia state through an
// `eth_call` with a state override, and a tampered payload must revert.
import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { type Abi, type Address, type Hex, type PublicClient, concat, createPublicClient, decodeFunctionResult, encodeFunctionData, http, toHex } from "viem";
import { arbitrumSepolia } from "viem/chains";
import { CHAINLINK_ARB_SEPOLIA, readAggregator } from "./chainlink.js";
import { PYTH_EQUITY_IDS, hermesUpdateStatus, readPythUnsafe } from "./pyth.js";
import { type GatewayPackage, aggregate, buildPayload, feedIdBytes32, fetchLatest, freshAt, packageBytes } from "./redstone.js";

const TICKERS = ["NVDA", "AAPL", "TSLA", "COIN", "MSFT", "SPY"] as const;
const PROBE_ADDRESS: Address = "0x000000000000000000000000000000000000c0de";

const fmt = (v: bigint, decimals: number): string => {
  const neg = v < 0n;
  const a = neg ? -v : v;
  const s = a.toString().padStart(decimals + 1, "0");
  return `${neg ? "-" : ""}${s.slice(0, -decimals)}.${s.slice(-decimals)}`;
};
const iso = (s: number): string => new Date(s * 1000).toISOString();

async function redstoneOnChain(client: PublicClient, artifactPath: string, pkgs: Record<string, GatewayPackage[]>) {
  const art = JSON.parse(readFileSync(artifactPath, "utf8")) as { abi: Abi; deployedBytecode: { object: Hex } };
  const ids = Object.keys(pkgs);
  const flat = ids.flatMap((id) => pkgs[id]!.slice(0, 3));
  const call = encodeFunctionData({ abi: art.abi, functionName: "read", args: [ids.map((i) => feedIdBytes32(i))] });
  const run = (payload: Hex) =>
    client.call({ to: PROBE_ADDRESS, data: concat([call, payload]), stateOverride: [{ address: PROBE_ADDRESS, code: art.deployedBytecode.object }] });
  const res = await run(buildPayload(flat, "credence-r26-probe"));
  const [values, ts] = decodeFunctionResult({ abi: art.abi, functionName: "read", data: res.data! }) as [bigint[], bigint];
  // Tamper: replace the first package's value with 1 (the signature no longer matches).
  const first = flat[0]!;
  const good = packageBytes(first);
  const tampered = buildPayload(flat).replace(good.slice(2), (good.slice(0, 66) + toHex(1n, { size: 32 }).slice(2) + good.slice(130)).slice(2)) as Hex;
  let tamperedReverted = false;
  try {
    await run(tampered);
  } catch {
    tamperedReverted = true;
  }
  return {
    verifiedBy: "RedStone PrimaryProdDataServiceConsumerBase (eth_call + state override)",
    dataTimestamp: iso(Number(ts) / 1000),
    values: Object.fromEntries(ids.map((id, k) => [id, fmt(values[k]!, 8)])),
    tamperedReverted,
  };
}

async function main(): Promise<void> {
  const { values: args } = parseArgs({
    options: { rpc: { type: "string" }, verifier: { type: "string" }, out: { type: "string" } },
  });
  const rpc = args.rpc ?? process.env.ARB_SEPOLIA_RPC_URL ?? "https://sepolia-rollup.arbitrum.io/rpc";
  const client = createPublicClient({ chain: arbitrumSepolia, transport: http(rpc) }) as PublicClient;
  const chainId = await client.getChainId();
  if (chainId !== 421614) throw new Error(`expected Arbitrum Sepolia (421614), got ${chainId}`);
  const block = await client.getBlock();
  const blockTime = Number(block.timestamp);

  // RedStone
  const { gateway, data } = await fetchLatest();
  const redstone: Record<string, unknown> = {};
  const covered: Record<string, GatewayPackage[]> = {};
  for (const t of TICKERS) {
    const pkgs = data[t];
    if (!pkgs) {
      redstone[t] = { available: false, variants: [] };
      continue;
    }
    const agg = await aggregate(t, pkgs);
    covered[t] = pkgs;
    redstone[t] = {
      available: true,
      value: fmt(agg.value, 8),
      timestamp: iso(agg.timestampMs / 1000),
      signers: agg.signers.length,
      freshOnSepolia: freshAt(agg.timestampMs, blockTime),
      variants: Object.keys(data).filter((k) => k.startsWith(`${t}---`)),
    };
  }
  const redstoneVerify = args.verifier ? await redstoneOnChain(client, args.verifier, covered) : null;

  // Chainlink push feeds on Sepolia
  const chainlink: Record<string, unknown> = {};
  for (const t of TICKERS) {
    const proxy = CHAINLINK_ARB_SEPOLIA[t];
    if (!proxy) {
      chainlink[t] = { available: false };
      continue;
    }
    const r = await readAggregator(client, proxy);
    chainlink[t] = { available: true, proxy, description: r.description, value: fmt(r.answer, r.decimals), updatedAt: iso(r.updatedAt), ageH: +((blockTime - r.updatedAt) / 3600).toFixed(1) };
  }

  // Pyth on Sepolia
  const pyth: Record<string, unknown> = {};
  for (const t of TICKERS) {
    const r = await readPythUnsafe(client, PYTH_EQUITY_IDS[t]!);
    pyth[t] = { value: fmt(r.price, -r.expo), publishTime: iso(r.publishTime), ageDays: +((blockTime - r.publishTime) / 86400).toFixed(1) };
  }
  const hermesStatus = await hermesUpdateStatus(PYTH_EQUITY_IDS.NVDA!);

  const report = {
    probe: "credence.r26-probe/v1",
    chainId,
    rpc,
    block: Number(block.number),
    blockTime: iso(blockTime),
    redstone: { gateway, dataService: "redstone-primary-prod", feeds: redstone, onChain: redstoneVerify },
    chainlink: { network: "arbitrum-sepolia push feeds", feeds: chainlink },
    pyth: { contract: "0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF", hermesUnauthenticatedStatus: hermesStatus, feeds: pyth },
  };
  const json = JSON.stringify(report, null, 2);
  if (args.out) writeFileSync(args.out, `${json}\n`);
  console.log(json);
}

main().catch((e: unknown) => {
  console.error(e);
  process.exit(1);
});
