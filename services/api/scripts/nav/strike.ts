// Issuer NAV strike for the local NAV stack (dev chains only; S4 G tooling). The relayer does not publish the
// NAV kind (`UnsupportedKind`), so on the devnode the issuer's daily strike is played by this script:
//   1. a signed NAV report (kind 3, CLOSED) to the NAV feed (`shared.feedNav`), signed by the feed's committee
//      (DeployClockLocal: feed A's three node keys, the well-known anvil keys 1–3);
//   2. `fund.publishNav(price)` as the issuer (the deployer), so redemptions pay the same NAV.
// Usage: node scripts/nav/strike.ts --price 0.9955 | --drop-bps 45   [--session-open <unix s>]
// Env: RPC_URL, DEPLOYMENTS_FILE (else deployments/<chainId>.local.json), ISSUER_KEY (default: the nitro dev key).
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseArgs } from "node:util";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { reportsTypedData } from "@credence/sdk";

const NITRO_DEV_KEY =
  "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";
// feed A's committee on the local stack (mk/contracts.mk RELAYER_A_SIGNERS): anvil keys 1–3 (public dev keys)
const COMMITTEE = [
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
] as const;
const WAD = 10n ** 18n;
export const NAV_KIND = 3;
export const CLOSED = 0;

const feedAbi = parseAbi([
  "struct Report { bytes32 assetId; uint8 kind; uint128 price; uint40 observedAt; uint40 sessionDate; uint8 marketStatus; uint64 seq; }",
  "function submit(Report[] reports, bytes[] signatures)",
  "function latestSeq(bytes32 assetId) view returns (uint64)",
]);
const fundAbi = parseAbi([
  "function publishNav(uint256 navPerShare)",
  "function navPerShare() view returns (uint256 nav, uint40 at)",
]);

/** A price in WAD from a decimal string ("0.9955"), exactly. */
export function wad(dec: string): bigint {
  const [i, f = ""] = dec.split(".");
  return BigInt(i!) * WAD + BigInt((f + "0".repeat(18)).slice(0, 18));
}

/** The next NAV after a drop of `bps` (rounded down), e.g. the scenario's −0.45 % per strike. */
export function dropped(nav: bigint, bps: number): bigint {
  return (nav * BigInt(10_000 - bps)) / 10_000n;
}

async function main() {
  const { values } = parseArgs({
    options: {
      price: { type: "string" },
      "drop-bps": { type: "string" },
      "session-open": { type: "string" },
    },
  });
  const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8547";
  const pub = createPublicClient({ transport: http(rpc) });
  const chainId = await pub.getChainId();
  if (![31337, 412346].includes(chainId))
    throw new Error(`dev chains only (chain ${chainId})`);
  const book = JSON.parse(
    readFileSync(
      resolve(
        process.env.DEPLOYMENTS_FILE ??
          `../../deployments/${chainId}.local.json`,
      ),
      "utf8",
    ),
  ) as {
    shared: { feedNav: Address };
    tokens: { tTBILL?: Address };
    assetIds: { TBILL?: Hex };
  };
  const feed = book.shared.feedNav;
  const fund = book.tokens.tTBILL;
  if (!fund) throw new Error("no tTBILL fund in the book");
  const asset = book.assetIds.TBILL ?? keccak256(stringToHex("TBILL:USBANK"));
  const issuer = privateKeyToAccount(
    (process.env.ISSUER_KEY ?? NITRO_DEV_KEY) as Hex,
  );
  const wallet = createWalletClient({ account: issuer, transport: http(rpc) });
  const [current] = await pub.readContract({
    address: fund,
    abi: fundAbi,
    functionName: "navPerShare",
  });
  const price = values.price
    ? wad(values.price)
    : dropped(current, Number(values["drop-bps"] ?? 0));
  const now = Number((await pub.getBlock()).timestamp);
  const sessionOpen = Number(values["session-open"] ?? now);
  const seq =
    (await pub.readContract({
      address: feed,
      abi: feedAbi,
      functionName: "latestSeq",
      args: [asset],
    })) + 1n;
  const report = {
    assetId: asset,
    kind: NAV_KIND,
    price,
    observedAt: now,
    sessionDate: Math.floor(sessionOpen / 86_400),
    marketStatus: CLOSED,
    seq,
  };
  const signers = COMMITTEE.map((k) => privateKeyToAccount(k)).sort((a, b) =>
    a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
  );
  const typed = reportsTypedData(chainId, feed, [report]);
  const sigs = await Promise.all(signers.map((s) => s.signTypedData(typed)));
  const h1 = await wallet.writeContract({
    chain: null,
    address: feed,
    abi: feedAbi,
    functionName: "submit",
    args: [[report], sigs],
  });
  await pub.waitForTransactionReceipt({ hash: h1 });
  const h2 = await wallet.writeContract({
    chain: null,
    address: fund,
    abi: fundAbi,
    functionName: "publishNav",
    args: [price],
  });
  await pub.waitForTransactionReceipt({ hash: h2 });
  console.log(
    `NAV strike ${price} (was ${current}) seq ${seq} at ${now}: feed ${h1}, fund ${h2}`,
  );
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
