import { readFileSync } from "node:fs";
import { keccak256, recoverAddress, size } from "viem";
import { describe, expect, it } from "vitest";
import {
  type GatewayResponse,
  PRIMARY_PROD_SIGNERS,
  REDSTONE_MARKER,
  aggregate,
  buildPayload,
  freshAt,
  packageBytes,
  signatureHex,
  toValue8,
  verifyPackage,
} from "../src/redstone.js";

// Captured from oracle-gateway-1 on 2026-09-28 07:22 UTC (Monday, before the open).
const fx = JSON.parse(readFileSync(new URL("./fixtures/redstone-primary-prod-20260928.json", import.meta.url), "utf8")) as GatewayResponse;
const nvda = fx.NVDA!;

describe("RedStone package verification", () => {
  it("recovers every signer of the fixture from the raw keccak of the package bytes", async () => {
    for (const p of nvda) {
      const v = await verifyPackage(p);
      expect(v.signer).toBe(v.claimedSigner);
      expect(v.authorised).toBe(true);
    }
    expect(new Set(nvda.map((p) => p.signerAddress)).size).toBe(PRIMARY_PROD_SIGNERS.length);
  });

  it("package bytes: 1 point = 32 + 32 + 6 + 4 + 3 bytes", () => {
    expect(size(packageBytes(nvda[0]!))).toBe(77);
  });

  it("a changed value no longer recovers an authorised signer", async () => {
    const p = structuredClone(nvda[0]!);
    p.dataPoints[0]!.value = 1;
    const v = await verifyPackage(p);
    expect(v.authorised).toBe(false);
    expect(await recoverAddress({ hash: keccak256(packageBytes(p)), signature: signatureHex(p) })).not.toBe(p.signerAddress);
  });

  it("aggregates the median of 5 authorised signers", async () => {
    const agg = await aggregate("NVDA", nvda);
    expect(agg.signers).toHaveLength(5);
    expect(agg.rejected).toBe(0);
    const sorted = nvda.map((p) => toValue8(p.dataPoints[0]!.value)).sort((a, b) => (a < b ? -1 : 1));
    expect(agg.value).toBe(sorted[2]);
  });

  it("refuses fewer than 3 unique authorised signers (duplicates count once)", async () => {
    await expect(aggregate("NVDA", [nvda[0]!, nvda[0]!, nvda[1]!])).rejects.toThrow(/threshold/);
  });

  it("refuses packages of another feed", async () => {
    await expect(aggregate("AAPL", nvda)).rejects.toThrow(/threshold/);
  });
});

describe("helpers", () => {
  it("toValue8 is exact for decimal strings and numbers", () => {
    expect(toValue8("225.04013925")).toBe(22504013925n);
    expect(toValue8(225.04013925)).toBe(22504013925n);
    expect(toValue8("0.1")).toBe(10000000n);
    expect(toValue8("-1.5")).toBe(-150000000n);
  });

  it("freshness matches the connector defaults (3 min behind, 1 min ahead)", () => {
    expect(freshAt(1_000_000, 1_000 + 180).ok).toBe(true);
    expect(freshAt(1_000_000, 1_000 + 181).ok).toBe(false);
    expect(freshAt(1_060_000, 1_000).ok).toBe(true);
    expect(freshAt(1_061_000, 1_000).ok).toBe(false);
  });

  it("payload ends with count, metadata size and the RedStone marker", () => {
    const payload = buildPayload(nvda.slice(0, 3), "x");
    expect(payload.endsWith(REDSTONE_MARKER.slice(2))).toBe(true);
    // 3 × (77 + 65) + 2 (count) + 1 (metadata "x") + 3 (size) + 9 (marker)
    expect(size(payload)).toBe(3 * 142 + 2 + 1 + 3 + 9);
  });
});
