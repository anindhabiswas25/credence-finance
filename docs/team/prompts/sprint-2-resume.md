# Sprint 2 resume · PM checkpoint (2026-09-28)

From: PM. The first Sprint 2 sessions of all three engineers were cut off by a rate limit around 02:45. This note records where each role stopped. A new engineer continues each role **from that point**. The original briefs (`sprint-2-{blockchain,backend,quant}.md`) are still the scope and the acceptance criteria. Nothing in them changes.

## Where each role stopped

### BE-chain (about 15% of the sprint)
| Item | State |
| --- | --- |
| Foundry 1.8.3 | ✅ installed (board DECISION 09:10) |
| A1 interfaces v1 + `deployments/abis/v1/` | ✅ READY, commit `c1b32ea` (+ guardian correction in the A5 READY) |
| A5 one local address book | ✅ READY, commit `274d1c0` |
| **A2 scenario-set format** | 🟡 **in progress, uncommitted**: `crates/risk-core/src/setfile.rs` (873 lines, untracked, **not yet `mod`-declared in `lib.rs`**). It references **ADR-0106**, which does not exist yet. There is no `risk-cli validate-set` and no `LoadScenarioSet.s.sol` yet. |
| A3 `risk-py`, A4 `risk-wasm` | ❌ not started. **QE and BE-backend are waiting on these.** |
| B carry-overs (R-23 NAV, Stylus.toml, G-vectors v1.1, differential nightly, reproducible WASM) | ❌ |
| C full Stylus engine | ❌ (the S1 spike only) |
| D lending core, `DeployCoreLocal`, `credence-bindings` | ❌ (`contracts/src/core` and `src/governance` do not exist) |
| E tests, report | ❌ |

**Resume order:** review and finish `setfile.rs` → ADR-0106 → `risk-cli validate-set` → READY A2. Then A3 `risk-py` (with `load set from file`) → READY. Then A4 `risk-wasm` → READY. After that, work through B, C, D and E as in the brief. Post the READY for `credence-bindings` + `DeployCoreLocal` as soon as the market and vault deploy locally, even before the full test suites, because BE-backend's section B is waiting on them.

### BE-backend (about 25%)
| Item | State |
| --- | --- |
| A3 relayer WebSocket streaming | ✅ commit `c498692` |
| A2 notifier | ✅ commit `4e78ea8` (ADR-0010) |
| **A1 R-26 licensing spike** | ❌ no ADR yet. **Do this first.** |
| B indexer / API / keeper / SDK | ❌. It waits on the BE-chain READYs. **J7 does not wait:** QE's σ spec and vectors are READY (board 10:05), so implement J7's σ computation and vector reproduction now, and post the ANSWER to QE. Wire the submit to `SigmaOracle` when the bindings land. |
| C Grafana/Prometheus (`make obs-up`) | ❌ (independent: do it while you wait for BE-chain) |
| Address-book migration off the flat keys (A5 READY) | ❌ |

**Resume order:** A1 licensing ADR → J7 σ math and vectors → C observability → address-book migration → section B as each BE-chain READY lands. The shared devnode is **not running** right now (`make infra-up db-migrate` is yours to run).

### QE (about 55%)
| Item | State |
| --- | --- |
| 1 data | ✅ on Alpaca SIP 2016+, labelled `dev-unlicensed`. The licensed data is **BLOCKED on a user decision** (board 02:40): keep going on the dev data. |
| 2 gaps + quality | ✅ |
| 3 σ spec + vectors | ✅ READY (ADR-0202). Waiting for BE-backend's ANSWER. |
| 4 scenario sets, 5 joint K=256 | ✅ generated (ADR-0203). **Not yet validated** with `risk-cli validate-set` (it waits on BE-chain A2), and the format must be re-checked against ADR-0106 once it lands. |
| **6 backtest** | 🟡 **in progress, uncommitted**: `calibration/credence_cal/engine.py` (the risk-py / risk-cli wrapper), `backtest.py`, `.github/workflows/calibration.yml`, `calibration/out/HASHES.alpaca.json`, and a modification to `gaps.py` (new `d` column). These wait on BE-chain A3 (`risk-py`). `CliEngine` can run against today's `risk-cli` for any functions it already exposes. |
| 7 proposal, 8 reproducibility, 9 model validation note, report | ❌ |

**Resume order:** review and commit the in-progress files (the test suite stays offline and green) → the model validation note (item 9, which needs no BE-chain input) → validate the sets when A2 lands → the backtest through `risk-py` when A3 lands → the proposal and calldata JSON → reproducibility (`make cal-all`, CI hashes) → the report.

## Rules that matter for the restart
- **Uncommitted work belongs to the role whose path it is in.** Review it, finish it, and commit it. Do not throw it away.
- Read the **whole** `docs/handoff/BOARD.md` before starting, and post a `DECISION` entry "`<role>` resumed S2" first.
- The charter applies in full: your paths only, stage only your paths, the §2a shared-machine rules, and your own `CARGO_TARGET_DIR`.
- Commit at every finished item, so that a new cutoff loses as little as possible.
