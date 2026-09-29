// Pure projections of the NAV settlement events (S4 D), shared by the handlers and the unit tests.

export type SettlementStatus = "open" | "filled" | "advanced";

export interface SettlementRow {
  settlementId: bigint;
  status: SettlementStatus;
  bids: number;
  bestPrice: bigint | null;
  bestSolver: `0x${string}` | null;
  solver: `0x${string}` | null;
  price: bigint | null;
  proceeds: bigint | null;
  requestId: bigint | null;
  positionsSettled: number | null;
}

/** A `SolverBid`: the venue only accepts a better price, so the new bid is the best. */
export function onBid(
  s: SettlementRow,
  solver: `0x${string}`,
  price: bigint,
): Partial<SettlementRow> {
  return {
    bids: s.bids + 1,
    bestPrice: price,
    bestSolver: solver.toLowerCase() as `0x${string}`,
  };
}

/** `SettlementFinalized`: filled by a solver, or advanced by the pool (the price is then the floor). */
export function onFinalized(f: {
  filled: boolean;
  solver: `0x${string}`;
  price: bigint;
  proceeds: bigint;
  requestId: bigint;
}): Partial<SettlementRow> {
  return {
    status: f.filled ? "filled" : "advanced",
    solver: f.filled ? (f.solver.toLowerCase() as `0x${string}`) : null,
    price: f.price,
    proceeds: f.proceeds,
    requestId: f.filled ? null : f.requestId,
  };
}

export type ClaimStatus = "outstanding" | "claimed";

/** NAV contribution of the pool's redemption claims (§8.6.1): outstanding ones at cost. */
export function outstandingAtCost(
  claims: { status: ClaimStatus; cost: bigint }[],
): bigint {
  return claims
    .filter((c) => c.status === "outstanding")
    .reduce((a, c) => a + c.cost, 0n);
}
