# ADR-0116 · BE-chain · The NAV asset on the real Stylus engine: a local TBILL fixture set until QE calibrates it

Status: accepted (S4, local only) · Date: 2026-09-30

## Context
Item E ran the NAV stack against the real Stylus engine for the first time: until then, every NAV test ran in forge
against `MockRiskEngine` (`NavFixture`). On the devnode the first TBILL borrow reverted
`UnknownSet(TBILL:USBANK, 2)`. QE's bundle (`calibration/out/risk-bundle-889d50e4.json`) holds scenario sets, σ and σ
floors for the six equity assets only, so on a Stylus-backed book the NAV market can open no position: `borrow`,
`bellStatus` and `safeLtv` all need the asset's set. The S3 main book had the same gap; nobody hit it, because
scenario A is equity only.

## Decision
- **A local-only fixture** in BE-chain's paths, `contracts/test/fixtures/risk/tbill-local/`:
  - three `credence.scenario-set/v1` files for `TBILL:USBANK` (closure types 1, 2 and 3), built with
    `risk-cli build-set` from the standard-normal quantiles z_i = Φ⁻¹((i + ½)/3000) (×1000, n = 3000);
  - `bundle.json`, which holds those sets, σ = 0.10 % and a σ floor of 0.05 % per closure type, and a copy of QE's
    params (so reloading them changes nothing). It has no joint column.
  It is labelled "LOCAL DEVNODE FIXTURE ONLY" in each file. It is **not a calibration**. A T-bill fund's NAV moves
  about 0.01 % a day, so 0.10 % is deliberately wide.
- `make local-deploy-core` (the Stylus path) and `devnode_integration.sh` load it **after** QE's bundle
  (`NAV_LOCAL_BUNDLE` / `NAV_RISK_BUNDLE` override it). `risk-load-set` validates it like any bundle.
- **Not for testnet.** S5 needs a real TBILL set, σ and a joint column from QE (board REQUEST 2026-09-30). The
  fixture must not be loaded on Arbitrum Sepolia.

## Also fixed in the devnode scripts (test tooling, no contract change)
- Signed reports were stamped with the *latest block's* timestamp. On a quiet devnode that block can be tens of
  seconds old, so a report could already be stale (60 s in REGULAR) when the next borrow landed: `BorrowPaused` (the
  adapter's disagreement flag) or a HALTED clock. The scripts now stamp with `max(latest block, wall clock − 1 s)`,
  within the feed's 5 s `MAX_FUTURE_SKEW`, and `devnode_gas.sh` re-prices and retries a borrow.
- NAV prints must be strictly time-ordered (the feed ignores one at or before the last), so
  `devnode_integration.sh` never reuses a second for consecutive NAV prints.

## Consequences
- The NAV integration (phase 6) and the redeployed main book run on the real engine with TBILL priced by the
  fixture. The NAV pool's `writeCover` needs a TBILL joint column, and this fixture has none. NAV cover on a
  Stylus-backed book therefore waits for QE's set. Item E and J10 do not buy NAV cover.
