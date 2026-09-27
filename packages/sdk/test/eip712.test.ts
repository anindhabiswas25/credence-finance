// Cross-language check (Sprint 1 acceptance 3): the Rust relayer's EIP-712 digest equals viem's for the
// same reports. Vectors come from services/relayer/tests/eip712_vectors.rs.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { getAddress, hashDomain, recoverAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { encodeReports, priceFeedDomain, reportsDigest, reportsHash, reportsTypedData, REPORTS_TYPEHASH } from "../src/eip712.js";
import type { Report } from "../src/types.js";

interface Vector {
  name: string;
  chainId: number;
  verifyingContract: Address;
  domainSeparator: Hex;
  reports: { assetId: Hex; kind: number; price: string; observedAt: bigint; sessionDate: bigint; marketStatus: number; seq: bigint }[];
  reportsHash: Hex;
  digest: Hex;
  signatures: { signer: Address; signature: Hex }[];
}

// big integers keep full precision through JSON.parse's source text access (Node ≥ 22)
const BIG = new Set(["seq", "observedAt", "sessionDate"]);
const file = readFileSync(resolve(__dirname, "vectors/eip712-reports.json"), "utf8");
const doc = JSON.parse(file, function (this: unknown, key: string, value: unknown, ctx?: { source?: string }) {
  return BIG.has(key) && ctx?.source !== undefined ? BigInt(ctx.source) : value;
} as (this: unknown, key: string, value: unknown) => unknown) as { privateKeys: Hex[]; vectors: Vector[] };

const toReport = (r: Vector["reports"][number]): Report => ({
  assetId: r.assetId,
  kind: r.kind,
  price: BigInt(r.price),
  observedAt: Number(r.observedAt),
  sessionDate: Number(r.sessionDate),
  marketStatus: r.marketStatus,
  seq: r.seq,
});

describe("EIP-712 digest: Rust signer == viem", () => {
  it("has vectors", () => {
    expect(doc.vectors.length).toBeGreaterThanOrEqual(6);
    expect(REPORTS_TYPEHASH).toBe("0x938467764371b0575b861939ff6c16adfb3824b6311badedafde3e3ca8b801c2"); // cast keccak "Reports(bytes32 reportsHash)"
  });

  for (const v of doc.vectors) {
    describe(`${v.name} @ ${v.chainId}`, () => {
      const reports = v.reports.map(toReport);

      it("domain separator", () => {
        const p = priceFeedDomain(v.chainId, v.verifyingContract);
        const d = { name: p.name!, version: p.version!, chainId: BigInt(p.chainId!), verifyingContract: p.verifyingContract! };
        expect(hashDomain({ domain: d, types: { EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" },
        ] } })).toBe(v.domainSeparator);
      });

      it("reportsHash = keccak256(abi.encode(Report[]))", () => {
        expect(reportsHash(reports)).toBe(v.reportsHash);
        // offset word + length word + 7 words per report
        expect((encodeReports(reports).length - 2) / 2).toBe(32 * (2 + 7 * reports.length));
      });

      it("digest", () => {
        expect(reportsDigest(v.chainId, v.verifyingContract, reports)).toBe(v.digest);
      });

      it("Rust signatures recover to their signers, sorted ascending", async () => {
        const signers: string[] = [];
        for (const s of v.signatures) {
          expect(await recoverAddress({ hash: v.digest, signature: s.signature })).toBe(getAddress(s.signer));
          signers.push(s.signer.toLowerCase());
        }
        expect([...signers].sort()).toEqual(signers);
      });

      it("viem signTypedData produces byte-identical signatures (RFC 6979)", async () => {
        const td = reportsTypedData(v.chainId, v.verifyingContract, reports);
        for (const pk of doc.privateKeys) {
          const acct = privateKeyToAccount(pk);
          const sig = await acct.signTypedData(td);
          const rust = v.signatures.find((s) => getAddress(s.signer) === acct.address);
          expect(rust?.signature).toBe(sig);
        }
      });
    });
  }
});
