import { describe, expect, it } from "vitest";
import {
  onBid,
  onFinalized,
  outstandingAtCost,
  type SettlementRow,
} from "../settlement-model";
import { PoolV3EventsAbi } from "../abis/settlement";

const row: SettlementRow = {
  settlementId: 1n,
  status: "open",
  bids: 0,
  bestPrice: null,
  bestSolver: null,
  solver: null,
  price: null,
  proceeds: null,
  requestId: null,
  positionsSettled: null,
};

describe("settlement projection", () => {
  it("counts bids and keeps the latest (best) one", () => {
    const a = onBid(row, "0xAbC0000000000000000000000000000000000001", 995n);
    expect(a).toEqual({
      bids: 1,
      bestPrice: 995n,
      bestSolver: "0xabc0000000000000000000000000000000000001",
    });
    expect(onBid({ ...row, ...a }, "0x02", 996n).bids).toBe(2);
  });

  it("a fill records the solver, an advance the redemption request", () => {
    const solver = "0x00000000000000000000000000000000000000Aa" as const;
    expect(
      onFinalized({
        filled: true,
        solver,
        price: 996n,
        proceeds: 9960n,
        requestId: 0n,
      }),
    ).toEqual({
      status: "filled",
      solver: solver.toLowerCase(),
      price: 996n,
      proceeds: 9960n,
      requestId: null,
    });
    expect(
      onFinalized({
        filled: false,
        solver: "0x0000000000000000000000000000000000000000",
        price: 995n,
        proceeds: 9950n,
        requestId: 7n,
      }),
    ).toMatchObject({ status: "advanced", solver: null, requestId: 7n });
  });

  it("NAV carries only outstanding claims, at cost (§8.6.1)", () => {
    expect(
      outstandingAtCost([
        { status: "outstanding", cost: 9950n },
        { status: "claimed", cost: 1000n },
        { status: "outstanding", cost: 50n },
      ]),
    ).toBe(10000n);
    expect(outstandingAtCost([])).toBe(0n);
  });

  it("binds the v3 pool redemption events", () => {
    expect(PoolV3EventsAbi.map((x) => x.name)).toEqual([
      "RedemptionRequested",
      "RedemptionClaimed",
    ]);
  });
});
