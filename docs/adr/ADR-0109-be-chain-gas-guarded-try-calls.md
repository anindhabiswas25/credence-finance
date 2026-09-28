# ADR-0109 · BE-chain · Gas-guarded try/catch (no fail-closed branch by gas starvation)

Status: accepted (S3) · Date: 2026-09-28

## Context
The S3 A1 smoke run of `make api-bell-e2e` on the devnode failed on `poke` with `ReentrancySentryOOG` at the node's
own gas estimate (estimate 136,031; the same call at that limit reverts). The trace showed the cause: `AssetClock`
wraps its oracle reads in `try … catch`, and at a tight limit the *inner* call runs out of gas (EIP-150 leaves the
caller 1/64), the catch branch runs, and the transaction takes a different, cheaper-then-more-expensive path. The
estimate binary search is not monotone over such a path, so `eth_estimateGas` under-estimates.

The same mechanism is a griefing vector. Every catch in the protocol selects a fail-closed or "skip" branch:
`feedHealth` failing → **HALTED** (and an unscheduled closure opens), `lastRegularClose` → no reference → HALTED,
`openPrint` → no open print, `autoCover` → the borrower is not covered, `payShortfall` → the pool does not pay and the
loss moves to the reserve / seniors, `creditPenalty`, `fund`, `cover`, keeper tips, the DEX TWAP reads. Any
permissionless caller (`poke`, `enforceBell`, `settlePositions`) could choose a gas limit that starves only the inner
call and force that branch.

## Decision
`libraries/GasGuard.sol`: read `g = gasleft()` just before every `try`, and in the `catch` call `GasGuard.check(g)`,
which reverts `InsufficientGas()` when `gasleft() < g / 63`, i.e. the callee consumed (nearly) all the gas it was
forwarded. A genuine callee revert uses far less gas and keeps the catch branch unchanged. Applied to all 16 try sites
(clock 5, oracle adapter 4, TWAP source 1, market 1, market libs 4 + tips 1, reserve 1, guardian 1).

`InsufficientGas()` is appended to `ICredenceErrors` (additive; `abis-check` passes, v1 re-exported).

## Consequences
- A starved call reverts as a whole; no state is committed. Test: `AssetClockTest.test_gasStarvedPokeRevertsInsteadOfHalting`.
- `eth_estimateGas` becomes monotone again over these paths, so client estimates are sufficient. Clients should still
  add a margin (Nitro L1 component); BE-backend is told on the board.
- Cost: ~30 gas per guarded call.
