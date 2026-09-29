# Credence Finance: team charter

Owner: Product Manager · Applies to every engineer session working in this repo.

## 1. Roles

| Role | Status | Owns | Joins in |
| --- | --- | --- | --- |
| Product Manager (PM) | Active | Specs, sprint scope, acceptance, reviews every sprint report, writes the next prompts | S0 |
| **Blockchain Engineer (BE-chain)** | **Active** | Solidity contracts, the `risk-core` crate, the Stylus Risk Engine, `risk-cli`, contract CI | S1 |
| **Backend Engineer (BE-backend)** | **Active** | Relayer, keeper, indexer, API, notifier, DB, infra, TS SDK, calendar generator | S1 |
| **Quant Engineer (QE)** | **Active from S2** | Calibration pipeline, scenario sets, joint stress set, σ methodology, backtest, launch parameters | S2 |
| Frontend Engineer | Planned | Web app, risk page, bidder console | S3 |
| **QA / Security Engineer (QA-sec)** | **Active from S4** | Static analysis and triage, reentrancy / fuzz / security invariants, invariant review, threat-model walkthrough, off-chain security review, pre-audit gates | S4 |
| DevOps / SRE | Planned | Testnet deploy pipeline, monitoring, on-call tooling | S5 |

## 2. Path ownership (the most important rule)

Engineers run **at the same time, in the same working tree**. Never create, edit or delete a file outside your paths. If you need a change in someone else's paths, write a request on the board (§4).

| Path | Owner |
| --- | --- |
| `contracts/**` (except the two QA-sec paths below) | BE-chain |
| `contracts/test/security/**`, `contracts/test/fuzz/**` | **QA-sec from S4** |
| `docs/security/**`, `docs/qa/**`, `mk/security.mk`, `.github/workflows/security.yml`, `.tools/` (project-local tool installs, git-ignored) | **QA-sec from S4** |
| `crates/risk-core/**`, `crates/risk-cli/**`, `crates/risk-py/**`, `crates/risk-wasm/**`, `stylus/**`, root `Stylus.toml` | BE-chain |
| `crates/credence-bindings/**` | BE-chain (generated from contract ABIs) |
| `deployments/abis/**` | BE-chain (frozen ABIs) |
| `mk/contracts.mk`, `.github/workflows/contracts.yml`, `.github/workflows/rust.yml`, `rust-toolchain.toml`, `.tool-versions` | BE-chain |
| Root `Cargo.toml` | BE-chain creates it. BE-backend may **only append** its own crates to `members` (re-read the file immediately before editing) |
| `crates/credence-common/**`, `services/**` | BE-backend |
| `indexer/**`, `packages/**`, `infra/**` | BE-backend |
| Root `package.json`, `pnpm-workspace.yaml`, `turbo.json`, `.env.example` | BE-backend |
| `calibration/**` | **QE from S2** (includes the calendar generator BE-backend wrote in S1; the output format is frozen at v1) |
| `mk/quant.mk`, `.github/workflows/calibration.yml` | QE |
| `mk/backend.mk`, `.github/workflows/ts.yml`, `.github/workflows/services.yml` | BE-backend |
| `docs/CREDENCE_BUILD_GUIDE.md`, `docs/Architecture.md`, the money docs, `docs/team/**` | PM only |
| `docs/adr/**` | Anyone; one file per decision, numbered `ADR-XXXX-<role>-<slug>.md` |
| `docs/handoff/BOARD.md` | Everyone, **append only** |
| `docs/handoff/sprint-N-<role>-report.md` | That role |
| Root `Makefile`, `README.md`, `.gitignore` | PM. Put your make targets in your `mk/*.mk` fragment |

## 2a. Shared machine rules (added after S1)

- **Separate Cargo target dirs** (S1 had lock contention): BE-chain uses the default `target/`, BE-backend `CARGO_TARGET_DIR=target/be`, QE `CARGO_TARGET_DIR=target/quant`, and QA-sec `CARGO_TARGET_DIR=target/qa` (forge: `FOUNDRY_OUT=target/qa/forge-out FOUNDRY_CACHE_PATH=target/qa/forge-cache`).
- **Global tools** (rustup toolchains, foundry, cargo-stylus, node, uv): before installing or upgrading one, post a `DECISION` on the board and wait until no other role's build is running. Two concurrent rustup installs corrupted a toolchain in S1.
- **Three engineers at once (from S4):** the user runs up to three sessions at the same time. The machine has 16 threads and 15 GB of RAM. While a real-time devnode run is live (from its owner's DECISION to its READY), every other role runs heavy jobs with `nice -n 19`, `forge … --threads 4` and `CARGO_BUILD_JOBS=4`. A slow machine must never make the keeper miss a deadline.
- **Long runs survive the session:** any run longer than 30 min is started with `setsid nohup` inside `systemd-inhibit --what=idle:sleep:handle-lid-switch`, and it must write an explicit `ABORTED` line if it dies.
- **Local chain:** the devnode is shared (`make infra-up`, owned by BE-backend). Do not run `make infra-down` or `infra-reset` without posting on the board first.
- **Address book:** every local deploy writes to **one** file, `deployments/<chainId>.local.json`, owned by BE-chain, with the `shared.riskEngine` key included. No separate per-component address files.

## 3. Git rules

- One branch: `main`. There is no branch switching, because you share the working tree with another engineer.
- Commit often, and **stage only your own paths**: `git add contracts crates/risk-core …`. **Never** run `git add -A`, `git add .`, `git commit -a`, `git stash`, `git reset --hard`, `git checkout -- .` or `git clean`, because they touch other engineers' work.
- Use conventional commits, for example `feat(clock): lazy poke transitions`, `test(risk-core): golden vectors G-01..G-11`.
- Never commit secrets, private keys or vendor API keys. `.env` is ignored.
- Never push to a remote unless the PM's prompt says so.

## 4. Coordination board (`docs/handoff/BOARD.md`)

This is an append-only log that both sessions read at the start of each work block and before touching a shared interface. The format is one entry per line group:

```
## 2026-09-28 14:05 · BE-chain · READY
Interfaces v0 frozen: contracts/src/interfaces/*.sol, ABIs in deployments/abis/v0/. Build: `make contracts-build`.
```

Entry types:

| Type | Meaning |
| --- | --- |
| `READY` | Something another role depends on is available (interfaces, ABIs, devnode scripts) |
| `REQUEST` | You need a change in someone else's paths. Include the exact need and why |
| `ANSWER` | A reply to a REQUEST (reference its timestamp) |
| `BLOCKED` | You cannot continue without the PM or the user (credentials, a spec contradiction) |
| `DECISION` | You chose something the guide leaves open. Also write an ADR |

## 5. Spec authority

1. `docs/CREDENCE_BUILD_GUIDE.md` is binding. Section 2 (R-01…R-22) overrides the Architecture where they differ.
2. If the guide is silent, follow `docs/Architecture.md`.
3. If both are silent, decide, write an ADR, and post a `DECISION` on the board.
4. If the guide looks **wrong** (a math error, an impossible requirement), do not silently "fix" it. Implement the closest correct behaviour, write an ADR, and flag it in your sprint report under "Spec issues". The PM updates the guide.

## 6. Definition of done for a sprint

- Every item in the sprint prompt's acceptance list is met, and the proof is a command the PM can re-run.
- `make <your>-build` and `make <your>-test` are green from a clean checkout.
- A sprint report is written from `docs/handoff/REPORT_TEMPLATE.md` and committed.
- Nothing is left uncommitted in your paths.
