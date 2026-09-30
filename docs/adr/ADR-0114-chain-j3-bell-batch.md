# ADR-0114 · BE-chain · J3: the Bell-batch bracket (cached uncovered bound) is measured and reverted

Status: accepted (S5, PM ruling 2026-09-30 14:30: revert) · Date: 2026-09-30

## Context
J3 (the keeper's Bell job, §8.4.3 / §10.2) calls `enforceBell(id, borrowers[])` in `[bellAt, closeAt)`. Each borrower with
auto-cover on gets a `writeCover` through the pool, and each `writeCover` recomputes the pool's capacity: the uncovered
bound Σ_m B_{m,j} of §9.5 over every market, plus `coverLossVector` and `quoteCover` on the Stylus engine. In S3 this
made one auto-cover cost about 2.2M gas, so a 24M-gas J3 batch held **10 positions** (S3 report §4: 10 ≈ 22.9M,
11 ≈ 25.1M). A busy Friday then needs many batches inside the 15-min Bell window (spec issue 4, S3).

S4 prototyped a bracket: `CoverLogic.enforceBell` called `pool.beginBellBatch()` / `endBellBatch()` around its loop, and
`PoolLib.quoteBatch` built the uncovered bound once per batch in transient storage, taking each written position's own
B term out of it (rounded so the cache never understates the bound, INV-POOL-02). The S4 brief's rule: **keep it only if
the J3 batch at least doubles (10 → ≥ 20 positions); otherwise revert it.**

## Measurement (`make devnode-gas`, own engine + book, real Stylus router, 2026-09-30 07:45 IST, with the bracket)
`target/chain/devnode-gas.measure.0745-bracket.log`: N = 32 AAPL positions at 72 %, every borrower auto-covered.

| Call | Gas |
| --- | --- |
| `enforceBell`, 1 position | 3,905,299 |
| `enforceBell`, 2 | 5,415,421 |
| `enforceBell`, 4 | 8,554,936 |
| `enforceBell`, 8 | 14,834,113 |
| `enforceBell`, 12 | 21,176,700 |
| `enforceBell`, 16 | 27,537,118 |
| `enforceBell`, 20 / 24 / 32 | estimate fails (over the block gas limit) |
| **largest J3 batch within 24M** | **13** (sent for real: status 1, 22,153,450 gas, 13 auto-covered) |
| `buyCover` / `writeCover` (one) | 3,216,943 |
| `clear`, 64 bids | 1,503,684 |
| `fixLots` (1) / `settlePositions` (1) | 546,876 / 340,338 |

The marginal cost with the bracket is about 1.59M gas per position (12 → 16: +6.36M for 4). The cache removes the
per-market reads, but `coverLossVector` and `quoteCover` on the engine remain per position, and they dominate. The batch
went from 10 to 13 (+30 %), short of the ≥ 20 rule.

## Decision
- **Revert the bracket** (commit `dbf9d01`): `beginBellBatch` / `endBellBatch` (pool and `IUnderwriterPool`),
  `PoolLib.quoteBatch`, `PackedInt.subU64Floor`, the bracket calls in `CoverLogic.enforceBell`, the mock's hooks and
  `BellBatch.t.sol`. `writeCover` always computes capacity in full, as in S3.
- **ABIs v5** (`deployments/abis/v5/`, `CHANGELOG.md`): the only breaking entries are the two removed onlyMarket hooks,
  listed in `abi_diff.py` with this ADR as the reason. Nothing off-chain calls them. v4 stays as it was handed over.
  `credence-bindings` is on v5. v5 also adds `TestStablecoin` (tUSDG, ADR-0120), which is additive.
- **J3 batch after the revert:** it has to be measured again, because the 13 above needed the bracket. The measurement
  is `devnode-gas` on the reverted code, recorded below. The keeper's `KEEPER_J3_BATCH` uses that number.

## Post-revert measurement
_Pending: `devnode-gas` PHASE=setup at 14:45 IST, measure at bellAt. Filled in with the result._

## Consequences
- The J3 batch stays near S3's size, so a Bell with many auto-cover borrowers needs several batches. The keeper sends
  as many batches as it needs from `bellAt`. The 15-min window and the J3 QA-10 guard (no pre-close candidate after
  `close − 5 min − 60 s`) are unchanged.
- The larger saving would come from fewer engine calls per position (one `coverLossVector` for a batch of positions on
  the same asset and closure type), which is an engine interface change. That is left for after testnet (not needed for
  M9).
- INV-POOL-02 no longer depends on a cache argument: every write computes the bound from state.
