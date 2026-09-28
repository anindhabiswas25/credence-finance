// RedStone pull model (ADR-0009): signed data packages from the public gateway, verified off-chain
// exactly like RedStone's EVM connector does on-chain (`PrimaryProdDataServiceConsumerBase`).
//
// Package layout signed by each node (all big-endian):
//   dataPoints × (dataFeedId bytes32 ‖ value uint256, 8 decimals) ‖ timestampMs (6 B) ‖ valueByteSize (4 B) ‖ count (3 B)
// signature = secp256k1 over keccak256(package), no EIP-191 prefix, 65 B r‖s‖v.
// On-chain payload appended to calldata:
//   packages (each followed by its signature) ‖ packageCount (2 B) ‖ unsignedMetadata ‖ metadataSize (3 B) ‖ marker (9 B)
import { type Address, type Hex, concat, getAddress, keccak256, recoverAddress, stringToHex, toHex } from "viem";

export const REDSTONE_GATEWAYS = [
  "https://oracle-gateway-1.a.redstone.finance",
  "https://oracle-gateway-2.a.redstone.finance",
] as const;

export const PRIMARY_PROD = "redstone-primary-prod";

/** Authorised signers and threshold of `redstone-primary-prod`, as hard-coded in
 *  @redstone-finance/evm-connector `PrimaryProdDataServiceConsumerBase.sol` (checked 2026-09-28). */
export const PRIMARY_PROD_SIGNERS: readonly Address[] = [
  "0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774",
  "0xdEB22f54738d54976C4c0fe5ce6d408E40d88499",
  "0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202",
  "0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE",
  "0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de",
];
export const PRIMARY_PROD_THRESHOLD = 3;

/** RedStone connector defaults: data older than 3 min or more than 1 min ahead of block.timestamp is rejected. */
export const MAX_DELAY_S = 180;
export const MAX_AHEAD_S = 60;

export const REDSTONE_MARKER: Hex = "0x000002ed57011e0000";
const VALUE_DECIMALS = 8;

export interface GatewayDataPoint {
  dataFeedId: string;
  value: number | string;
}
export interface GatewayPackage {
  timestampMilliseconds: number;
  signature: string; // base64, 65 bytes
  dataPoints: GatewayDataPoint[];
  signerAddress: string;
  dataFeedId?: string;
  dataServiceId?: string;
}
export type GatewayResponse = Record<string, GatewayPackage[]>;

export interface VerifiedPackage {
  feedId: string;
  /** Price with 8 decimals, as the on-chain connector sees it. */
  value: bigint;
  timestampMs: number;
  signer: Address;
  claimedSigner: Address;
  authorised: boolean;
  bytes: Hex;
  signature: Hex;
}

/** Decimal number/string → integer with 8 decimals, without going through float multiplication. */
export function toValue8(v: number | string): bigint {
  const s = typeof v === "number" ? v.toFixed(VALUE_DECIMALS) : v;
  const neg = s.startsWith("-");
  const [int = "0", frac = ""] = (neg ? s.slice(1) : s).split(".");
  const out = BigInt(int) * 10n ** BigInt(VALUE_DECIMALS) + BigInt((frac + "0".repeat(VALUE_DECIMALS)).slice(0, VALUE_DECIMALS));
  return neg ? -out : out;
}

export function feedIdBytes32(feedId: string): Hex {
  return stringToHex(feedId, { size: 32 });
}

/** The exact bytes a RedStone node signs for one package. */
export function packageBytes(pkg: GatewayPackage): Hex {
  const points = [...pkg.dataPoints].sort((a, b) => (feedIdBytes32(a.dataFeedId) < feedIdBytes32(b.dataFeedId) ? -1 : 1));
  return concat([
    ...points.flatMap((p) => [feedIdBytes32(p.dataFeedId), toHex(toValue8(p.value), { size: 32 })]),
    toHex(BigInt(pkg.timestampMilliseconds), { size: 6 }),
    toHex(32, { size: 4 }),
    toHex(points.length, { size: 3 }),
  ]);
}

export function signatureHex(pkg: GatewayPackage): Hex {
  return `0x${Buffer.from(pkg.signature, "base64").toString("hex")}`;
}

export async function verifyPackage(
  pkg: GatewayPackage,
  signers: readonly Address[] = PRIMARY_PROD_SIGNERS,
): Promise<VerifiedPackage> {
  const bytes = packageBytes(pkg);
  const signature = signatureHex(pkg);
  const signer = await recoverAddress({ hash: keccak256(bytes), signature });
  const point = pkg.dataPoints[0];
  if (!point) throw new Error("RedStone package without data points");
  return {
    feedId: point.dataFeedId,
    value: toValue8(point.value),
    timestampMs: pkg.timestampMilliseconds,
    signer,
    claimedSigner: getAddress(pkg.signerAddress),
    authorised: signers.some((s) => getAddress(s) === signer),
    bytes,
    signature,
  };
}

export interface Aggregated {
  feedId: string;
  /** Median (lower median for an even count) of the authorised, unique-signer values; 8 decimals. */
  value: bigint;
  timestampMs: number;
  signers: Address[];
  rejected: number;
}

/** Aggregate the packages of one feed like the connector: unique authorised signers, one timestamp, ≥ threshold, median. */
export async function aggregate(
  feedId: string,
  pkgs: GatewayPackage[],
  opts: { signers?: readonly Address[]; threshold?: number } = {},
): Promise<Aggregated> {
  const threshold = opts.threshold ?? PRIMARY_PROD_THRESHOLD;
  const verified = await Promise.all(pkgs.map((p) => verifyPackage(p, opts.signers)));
  const seen = new Set<Address>();
  const good: VerifiedPackage[] = [];
  for (const v of verified) {
    if (!v.authorised || v.feedId !== feedId || seen.has(v.signer)) continue;
    seen.add(v.signer);
    good.push(v);
  }
  const ts = good[0]?.timestampMs;
  if (good.length < threshold || ts === undefined) {
    throw new Error(`RedStone ${feedId}: ${good.length} authorised signers < threshold ${threshold}`);
  }
  if (good.some((g) => g.timestampMs !== ts)) throw new Error(`RedStone ${feedId}: packages disagree on timestamp`);
  const values = good.map((g) => g.value).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  // The connector takes the median; for an even count it averages the two middle values.
  const mid = values.length >> 1;
  const value = values.length % 2 ? values[mid]! : (values[mid - 1]! + values[mid]!) / 2n;
  return { feedId, value, timestampMs: ts, signers: good.map((g) => g.signer), rejected: pkgs.length - good.length };
}

/** Freshness as the on-chain connector checks it against `block.timestamp`. */
export function freshAt(timestampMs: number, blockTimestamp: number): { ok: boolean; ageS: number } {
  const ts = Math.floor(timestampMs / 1000);
  const ageS = blockTimestamp - ts;
  return { ok: ageS <= MAX_DELAY_S && -ageS <= MAX_AHEAD_S, ageS };
}

/** Calldata suffix the connector parses (`getOracleNumericValuesFromTxMsg`). */
export function buildPayload(pkgs: GatewayPackage[], unsignedMetadata = "credence"): Hex {
  const meta = stringToHex(unsignedMetadata);
  return concat([
    ...pkgs.flatMap((p) => [packageBytes(p), signatureHex(p)]),
    toHex(pkgs.length, { size: 2 }),
    meta,
    toHex((meta.length - 2) / 2, { size: 3 }),
    REDSTONE_MARKER,
  ]);
}

export async function fetchLatest(
  dataServiceId = PRIMARY_PROD,
  fetchImpl: typeof fetch = fetch,
): Promise<{ gateway: string; data: GatewayResponse }> {
  let last: unknown;
  for (const gw of REDSTONE_GATEWAYS) {
    try {
      const res = await fetchImpl(`${gw}/data-packages/latest/${dataServiceId}`, { signal: AbortSignal.timeout(15_000) });
      if (!res.ok) throw new Error(`${gw}: HTTP ${res.status}`);
      return { gateway: gw, data: (await res.json()) as GatewayResponse };
    } catch (e) {
      last = e;
    }
  }
  throw new Error(`every RedStone gateway failed: ${String(last)}`);
}
