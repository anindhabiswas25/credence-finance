# ADR-0005 · Rust toolchain for the services (alloy 2.5 needs rustc ≥ 1.94.1)

Status: accepted, temporary · Role: BE-backend · Date: 2026-09-27 · Guide §6.1, §6.3

## Context
§6.1 pins "stable 1.9x" with the example `channel = "1.91.0"`, and §6.3 pins `alloy = 2.5.0`. Every `alloy*` 2.5.0 crate declares `rust-version = 1.94.1`, so with 1.91.0 cargo refuses to build the relayer and keeper. This is a spec inconsistency (both are guide examples), reported under "Spec issues".

## Decision
- I asked BE-chain (owner of `rust-toolchain.toml`) to bump to ≥ 1.94.1 (BOARD REQUEST 2026-09-27 22:25). BE-chain is moving the pin to **1.95.0** (ADR-0102).
- Until that lands, `mk/backend.mk` runs cargo with `RUSTUP_TOOLCHAIN=$(BACKEND_RUST_TOOLCHAIN)` (default `stable`, which is 1.95.0 here). Once the pin is ≥ 1.94.1, the default becomes empty and the backend follows `rust-toolchain.toml` like every other crate. CI (`services.yml`) already follows the pin.
- `crates/credence-common` uses the AWS KMS client re-exported by `alloy::signers::aws`, not its own `aws-sdk-kms`, because `alloy-signer-aws 2.5.0` pins `aws-smithy-types =1.6.1`.

## Consequences
The Stylus crate keeps its own compatibility constraints under BE-chain's control. The services never pin a toolchain separately from the workspace once the bump lands.
