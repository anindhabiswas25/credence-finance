// EIP-712 for CredencePriceFeed reports (§8.3.1, ICredencePriceFeed.sol):
//   domain      = ("CredencePriceFeed", "1", chainId, verifyingContract)
//   reportsHash = keccak256(abi.encode(Report[]))
//   digest      = hashTypedData(Reports{ reportsHash })   // REPORTS_TYPEHASH = keccak256("Reports(bytes32 reportsHash)")
// The Rust signer (services/relayer/src/report.rs) must produce the same digest; see test/eip712.test.ts.
import { encodeAbiParameters, hashTypedData, keccak256, stringToHex, type Address, type Hex, type TypedDataDomain } from "viem";
import type { Report } from "./types.js";

export const REPORT_COMPONENTS = [
  { name: "assetId", type: "bytes32" },
  { name: "kind", type: "uint8" },
  { name: "price", type: "uint128" },
  { name: "observedAt", type: "uint40" },
  { name: "sessionDate", type: "uint40" },
  { name: "marketStatus", type: "uint8" },
  { name: "seq", type: "uint64" },
] as const;

export const REPORTS_TYPES = { Reports: [{ name: "reportsHash", type: "bytes32" }] } as const;

export const REPORTS_TYPEHASH: Hex = keccak256(stringToHex("Reports(bytes32 reportsHash)"));

export function priceFeedDomain(chainId: number | bigint, verifyingContract: Address): TypedDataDomain {
  return { name: "CredencePriceFeed", version: "1", chainId: Number(chainId), verifyingContract };
}

/** `abi.encode(reports)` for a single `Report[]` value. */
export function encodeReports(reports: readonly Report[]): Hex {
  return encodeAbiParameters(
    [{ type: "tuple[]", components: REPORT_COMPONENTS }],
    [
      reports.map((r) => ({
        assetId: r.assetId,
        kind: r.kind,
        price: r.price,
        observedAt: r.observedAt,
        sessionDate: r.sessionDate,
        marketStatus: r.marketStatus,
        seq: r.seq,
      })),
    ],
  );
}

export function reportsHash(reports: readonly Report[]): Hex {
  return keccak256(encodeReports(reports));
}

/** Typed data a committee member signs (e.g. with viem `signTypedData`). */
export function reportsTypedData(chainId: number | bigint, feed: Address, reports: readonly Report[]) {
  return {
    domain: priceFeedDomain(chainId, feed),
    types: REPORTS_TYPES,
    primaryType: "Reports" as const,
    message: { reportsHash: reportsHash(reports) },
  };
}

/** The digest `CredencePriceFeed.hashReports(reports)` returns. */
export function reportsDigest(chainId: number | bigint, feed: Address, reports: readonly Report[]): Hex {
  return hashTypedData(reportsTypedData(chainId, feed, reports));
}

/** `keccak256("<TICKER>:<MIC>")` (§7.5). */
export function assetId(ticker: string, mic: string): Hex {
  return keccak256(stringToHex(`${ticker.toUpperCase()}:${mic.toUpperCase()}`));
}

/** `bytes32("XNYS")`: ASCII, right-padded (ADR-0101). */
export function venueId(venue: string): Hex {
  if (venue.length > 32) throw new Error("venue longer than 32 bytes");
  return stringToHex(venue, { size: 32 });
}
