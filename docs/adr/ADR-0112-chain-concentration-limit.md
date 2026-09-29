# ADR-0112 · BE-chain · §15.1 concentration limit (35 % of the pool's worst loss from one asset)

Status: accepted (S4), for QA-sec review · Date: 2026-09-29

## Context
Guide §15.1 lists "concentration limits (≤ 35 % of pool worst-loss from one asset)" as a control against a gap worse
than history, but no rule in §8.6 or §9.5 enforced it (PM S3 review §3). The brief asks whether R-13 / §9.5 change the
number.

## Decision
`UnderwriterPool.writeCover` reverts `ConcentrationExceeded(assetId, worstAfter, cap)` when

```text
W_a,e + w_p  >  maxAssetShare × u_max × J
```

- `W_a,e` = the asset's worst covered loss in epoch e: Σ over its policies of max_j L_{p,j}, already stored for R-11
  (`worstCovered(e, asset)`), and `w_p` = max_j L_{p,j} of the new policy (from its K-vector).
- `J` = the same equity the capacity check uses (the Bell-deadline snapshot once taken, else the live NAV), `u_max` the
  engine's (0.50).
- `maxAssetShare` = **0.35** (WAD), timelock-settable in (0, 1] (`setMaxAssetShare`, event `ConcentrationLimitSet`).

**Why it is exact.** Every policy on asset a loses `max(0, D_p − C_p × g_{a,j})`, which is decreasing in g_{a,j}, so all
of an asset's policies take their worst loss in the same stress weekend (the one with the lowest g_{a,j}). Hence
Σ_p max_j L_{p,j} = max_j Σ_p L_{p,j}: the stored sum is the asset's true worst covered loss, not an upper bound.

**Why the denominator is the capacity budget u_max × J, not the realised worst loss.** "35 % of the pool's worst loss"
read literally as "of max_j Λ_j" fails the first policy of every epoch (one asset = 100 % of the worst loss), and the
NAV stack, which has one asset, could never sell cover. The budget reading keeps the intent (no asset may use more than
35 % of what the pool is allowed to lose in a closure, so at least three assets are needed to fill it) and is monotone:
buying cover on another asset never makes an earlier policy non-compliant. At launch this is 17.5 % of J per asset.

**What counts.** Covered policies only. The uncovered bound B_m (§9.5) is part of the capacity check but not of this
limit: the pool does not choose it, it shrinks when a borrower buys cover, and counting it would make cover *harder* to
buy for exactly the assets that need it.

**R-13 / §9.5 do not change the number.** The aggregate K-vector has no per-asset split, but `worstCovered` (R-11) does,
so no new storage or engine call is needed. Cost: one `engine.params()` read per write (≈ 3k gas).

## Consequences
- The NAV stack (one asset) can use at most 35 % of its capacity budget for covered policies. NAV safe LTVs sit above the
  max LTV, so NAV cover is rare; the PM may set `maxAssetShare` = 1 on the NAV pool if that proves too tight.
- Tests: `test/unit/ConcentrationLimit.t.sol` (default, the cap binds on a second same-asset policy while another asset
  still sells, the launch cap binds before u_max after dozens of small NVDA policies, setter guards). QA-sec reviews.
