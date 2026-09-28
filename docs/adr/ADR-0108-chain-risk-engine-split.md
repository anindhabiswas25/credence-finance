# ADR-0108 · BE-chain · Risk Engine split (R-24), reproducible builds, gas and Stylus tooling

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain (Sprint 2 items B and C)

## Context

S2 completes every `IRiskEngine` function (§8.9). Built as one program with the pinned nightly `build-std` profile
(ADR-0102), the full engine is **33.0 KB compressed, two code fragments**, and ArbOS 40 on the devnode refuses to
activate it. R-24 anticipates this: "split into `PricingEngine` + `AuctionMath` behind the same Solidity interface".

## Decisions

### 1. Two programs behind a Solidity router
- **PricingEngine** (`stylus/risk-engine`, 22.4 KB): scenario sets, σ (floors, rate limit, `sigmaAt`), `RiskParams`;
  `safeLtv`, `bellStatus`, `quoteCover`.
- **AuctionMath** (`stylus/auction-math`, 24.2 KB): the joint stress columns (`setJointColumn`, `jointHash`),
  `coverLossVector`, `poolCapacity`, and the pure `liquidationLot`, `precloseLot`, `clear`.
- **`RiskEngineRouter`** (`contracts/src/risk`) implements `IRiskEngine`, and is the one engine address everyone uses
  (`shared.riskEngine`). It gates the writers (timelock; σ oracle, settable by the timelock), forwards each call, feeds
  the capacity math σ / κ / u_max / K read from the PricingEngine, and re-emits every engine event. Program reverts
  bubble up unchanged (the programs use the `IRiskEngine` error selectors). Both programs are constructed with the
  router as their only writer and wired once.
- **Deviation from the guide's grouping:** the guide puts capacity in the PricingEngine. The PricingEngine with
  capacity is 26.7 KB (two fragments), so capacity moved to the second program, next to the joint columns it reads.

### 2. Interface changes (v1, re-exported, `make abis-check`)
- Additive: `jointHash(bytes32)`, `sigmaAt(bytes32,uint8) → uint64` (keeper J7, BE-backend request).
- `liquidationLot`, `precloseLot`, `clear`: `pure` → `view` (the router forwards them). Same selectors and outputs,
  called with STATICCALL either way; listed as allowed changes in `contracts/script/abi_diff.py`.
- `make stylus-abi-check` compares each program with its router-facing interface (`IStylusPrograms.sol`) in both
  directions; the compiler checks that the router implements `IRiskEngine`.

### 3. Reproducible artifacts
The S1 artifact differed by 122 bytes between checkouts. The generated build workspace now (a) always copies the
repo's `Cargo.lock` (a stale copy used to survive) and (b) builds with `--remap-path-prefix` for the checkout, the
cargo home and the rustup home. `make stylus-repro` builds both programs from two fresh clones at different paths and
requires identical WASM sha256 (it passes: PricingEngine `aca7feaa…`, AuctionMath `912eafd9…` at `f9475ae`); CI job
`stylus-repro`.

### 4. `Stylus.toml` and the generated workspace (kept)
The root `Stylus.toml` stays absent and the build keeps its generated workspace (`target/stylus-ws`), because
cargo-stylus 0.10 builds from the cargo workspace root with `--locked` and the root workspace (a) pins Rust 1.95.0
while the on-chain build needs the pinned nightly with `build-std`, and (b) contains the backend crates (alloy 2.5,
tokio), which must not join a `wasm32` build. The generated workspace holds only risk-core and the two programs, its
own `rust-toolchain.toml`, the path remapping and a fresh copy of the lock.

### 5. Gas (§8.9.3), measured through the router on the devnode
| Call | Gas | Ceiling | |
| --- | ---: | ---: | --- |
| `safeLtv` (N = 3,000) | 86,465 | 100k | met |
| `quoteCover` (N = 3,000, G-22 position) | 90,764 | 250k | met (229,732 at 90% LTV) |
| `clear` (64 bids) | 158,954 | 200k | met |
| `coverLossVector` (K = 256) | 331,861 | 300k | **not met** |
| `poolCapacity` (K = 256, 10 markets) | 2,019,551 | 600k | **not met** |

The two misses are exact 256-bit mul-divs per scenario per market (≈ 1.2k gas each in WASM) plus the router hop and
two cross-program reads (≈ 50k). A native `u128` path would help but costs ≈ 0.7 KB, and AuctionMath has ≈ 350 B left
in its fragment. CI (`make stylus-diff`, `--gas-check`) enforces the §8.9.3 ceiling where it is met and a regression
limit (measured + 10%) for these two. Options for the PM: raise the two ceilings, allow multi-fragment programs when
ArbOS supports them, or a third program for capacity.

### 6. Tooling constraints
- forge cannot execute Stylus WASM, so no forge script can call into the engine. Bundles load with
  `LoadScenarioSet.plan()` + `contracts/script/load_risk_bundle.sh` (cast), and `DeployCoreLocal` lists markets
  against a Solidity stand-in, then `setEngine`s the router.
- The differential rewrites params and sets, so `make stylus-diff` runs against its own engine
  (`deployments/<chain>.diff.local.json`), never the shared one. 10k per function per PR; nightly 1M per function in
  four parallel groups (`.github/workflows/differential.yml`).
- risk-core `mul_div` takes a 256-bit path when the product fits (bit-identical, proven by the differential).
