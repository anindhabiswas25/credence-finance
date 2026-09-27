# ADR-0102 · BE-chain · risk-core golden vectors, the Rust toolchain, and the Stylus build

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain

## 1. Golden vectors whose doc figures do not follow from their stated inputs (Appendix A)

The engine is tested against values derived by hand from each vector's stated inputs. It is also tested to sit within a documented tolerance of the doc figure. The doc figures were computed from unrounded intermediates, or from a model that isn't the one stated.

| Vector | Stated inputs give | Doc says | Test asserts |
| --- | --- | --- | --- |
| G-10 cure repay | 67,028.99 − 0.712580 × 90,000 = **2,896.79** | 2,896.78 | exact 2,896.79; within $0.01 of the doc |
| G-11 cure repay | 55,535.10 − 0.626773 × 75,000 = **8,527.125** | 8,527.09 | exact 8,527.125; within $0.05 of the doc |
| G-17 pre-close lot | 8,528.045 / 88.33175 = **96.545636** | 96.5454 | exact to 1e-6 tokens; within 0.0005 of the doc |
| G-22 premium (t₃) | E[L] **2.1444**, ES **85.77**, π **4.394** | 2.26, 90.51, 4.64 | engine = closed form ± $0.01 |

The G-10, G-11 and G-17 doc figures come from an unrounded safe LTV: the unit-variance t₃ quantile is −5.89736σ, but the vector's input is the rounded 0.712580 / 0.626773.

For G-22, the closed form was computed independently by numerical integration against the unit-variance t₃ density (2M cells over [−3000σ, z0]). That integration shares no code with the engine and lives in `tests/golden.rs::g22_reference`. The engine, running on a 1,000,000-point quantile set, matches it to $0.0001. None of these model variants reproduces the doc's figures: κ applied additively, no κ, projected debt, or κ = 3.5%. This is reported to the PM under "Spec issues" (charter §5.4). If the guide's numbers are the intended ones, the model statement is what has to change.

## 2. Rust toolchain: 1.95.0

Guide §6.1 pins `1.91.0` as an example of "stable 1.9x", but the workspace dependencies it also pins (alloy 2.5.0) declare `rust-version = 1.94.1`. BE-backend asked for the bump on the board (2026-09-27 22:25). `rust-toolchain.toml` and `.tool-versions` now pin **1.95.0**.

## 3. The on-chain Stylus build

- **Size.** On ArbOS 40 (the devnode reports `arbOSVersion` 95 = 55 + 40), a program must fit in one code fragment: ≤ 24 KB compressed. The stable `--profile stylus` build is 28.6 KB in 2 fragments, and activation reverts. The standard library's panic-formatting code is the main cost. It can only be removed with `-Zbuild-std … panic_immediate_abort`, which is nightly-only. This is the approach Arbitrum's Stylus docs describe, and cargo-stylus applies it automatically on a non-stable toolchain.
- **Pinned nightly: `nightly-2025-08-01`.** Later nightlies turned `panic_immediate_abort` into the `immediate-abort` panic strategy, and cargo-stylus 0.10.9 still passes the old feature flag. With this nightly the engine is **23,581 bytes compressed**, one fragment.
- **wasm-opt.** Binaryen 129 `-Oz` output shrank the engine to 22.6 KB but failed Stylus parsing ("failed to parse wasm"), so the `[wasm-opt]` step is not used.
- **Workspace.** cargo-stylus requires a `Stylus.toml` at the cargo workspace root, and the repo root is shared (not in BE-chain's paths). `stylus/risk-engine/scripts/stylus-ws.sh` generates a Stylus workspace under `target/stylus-ws` (git-ignored). It symlinks `crates/risk-core` and `stylus/risk-engine`, copies the root `[workspace.*]` tables, pins the nightly, and sets `opt-level = "z"`. Every on-chain command (`stylus-check`, `devnode-deploy-engine`) runs there. The native builds and tests of the same crates still run on the pinned stable toolchain in the root workspace. Both builds use identical integer code, and the differential run proves the outputs match bit for bit.
- **Deploy.** `cargo stylus deploy` runs through the devnode's `StylusDeployer`, so deploy, activation and the constructor happen in one transaction. A `--wasm-file` deploy skips the constructor and would leave `timelock` / `sigmaOracle` unset.

Revisit when cargo-stylus supports the `immediate-abort` strategy, or when the target chain's ArbOS supports multi-fragment programs.

## 4. Measured gas (devnode, L1 price 0)

This is `eth_estimateGas` of one call, including the 21,000 intrinsic gas and calldata. It is unchanged after `cargo stylus cache bid`.

| Call | Gas |
| --- | --- |
| `safeLtv` (N = 3,000 set) | 80,719 |
| `liquidationLot` | 71,295 |
| `clear` (64 bids) | 143,618 |

These are well above the guide's §8.9.3 estimates (< 15k for `safeLtv`). The estimates probably leave out the per-call Stylus program entry cost. S2 profiles this with `cargo stylus trace` before the market depends on it.
