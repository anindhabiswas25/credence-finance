# Sprint 3 PM review

Date: 2026-09-29 · Reviewer: PM · Commit reviewed: `7c8e321`
**BE-chain: ACCEPTED.** **BE-backend: interim.** Acceptance 1, 2 and 7 are met. Items 3–6 run in `make scenario-a-e2e` on the devnode, and the verdict follows the final report.

## 1. Independent verification (BE-chain)

| Check | Command (clean clone of `7c8e321`, no devnode) | Result |
| --- | --- | --- |
| Acceptance 1 | `make contracts-build contracts-test risk-test contracts-coverage abis-check` | ✅ EXIT 0 in 14 m 45 s: **193 tests passed, 0 failed** (26 suites); coverage core 97.76, governance 100, clock 98.69, oracle 96.69, pool 98.65, auction 97.95 (%); `abis-check` v0→v1 ok, v1→v2 ok (25 allowed breaks, ADR-0110) |
| Acceptance 2 | Board: A1 00:25, A2 00:40, A3 01:05; BE-backend ANSWER 00:40 (`api-bell-e2e` 100 positions, 0 mismatches) | ✅ S2 carry-over closed |
| Acceptance 3–6 | The engineer's logs in the report; the devnode is held by BE-backend's run, so the PM re-runs `devnode-integration` / `devnode-gas` in S4 | ✅ accepted on evidence |

## 2. Rulings

### BE-chain
| # | Issue | Ruling |
| --- | --- | --- |
| 1 | S-A debts compound (R-09), 2 cents off the doc | **The chain is right.** Guide v1.2 states the S-A debts "with the borrow index"; tests keep the chain identity exact and the doc figure within 3 cents. |
| 2 | S-A pool line uses the pre-R-06 penalty | Accepted: v1.2 restates it with the R-06 penalty (NAV after 35,125.22, share price 0.878130). |
| 3 | INV-POOL-01 wording with the fee receivable and inventory mark | Accepted as implemented; v1.2 rewords it. |
| 4 | J3 = 10 auto-covers per tx | **Accepted for testnet.** Arbitrum blocks are ~0.25 s, so 100 J3 txs (1,000 auto-covers) fit well inside the 15-min Bell deadline window, and J2 heads-ups cure most positions before the Bell. S4 prototypes the per-batch cached uncovered bound and keeps it if it at least doubles the batch. A third Stylus program is not approved (more ops and audit surface). |
| — | ADR-0109 (gas-guarded try/catch) | Good catch. A caller could force HALTED by choosing a gas limit. Accepted. |
| — | Lots 128 instead of 256; `writeCover(maxPremium)`; one unsettled epoch per pool | Accepted (ADR-0110). |

### BE-backend
| # | Issue | Ruling |
| --- | --- | --- |
| 1 | ADR-0012: the devnode scenario A checks amounts against the chain's events, not Appendix A's cents | **Accepted.** Appendix A to the cent is owned by the forge scenarios; the e2e proves the off-chain stack equals the chain. |
| 2 | J2 "binding" when the safe LTV equals the max LTV | Accepted: heads-up to any position above the safe LTV. Safer, and matches §10.2's "for any live position". |
| 3 | J8 cannot claim for underwriters (claims pay `msg.sender` only) | Accepted: a notification instead. No `claimFor`, because pulling funds to a third party adds attack surface for no user benefit. |

## 3. Security gaps found in the PM review (assigned to S4 BE-chain)
- §15.1 concentration limit (≤ 35% of the pool's worst loss from one asset) is not implemented.
- There are no reentrancy tests with a malicious collateral token, and `contracts/test/fuzz/` is empty (vault/pool inflation).
- Slither and Aderyn have never been run, and `docs/security/triage.md` does not exist.

## 4. User actions (still open)
1. Rotate the vendor keys (open since S1).
2. ADR-0009 D2 (COIN/SPY) and D3 (RedStone written permission). Plan: ask RedStone, swap to GOOGL/AMZN in S4 if there's no answer. Gates S5.

## 5. Next
BE-chain starts S4 (`docs/team/prompts/sprint-4-blockchain.md`) off the devnode until BE-backend's final S3 READY. BE-backend's S4 brief follows their S3 close.
