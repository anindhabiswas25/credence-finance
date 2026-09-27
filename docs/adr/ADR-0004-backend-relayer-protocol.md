# ADR-0004 · Relayer OCR-lite protocol details

Status: accepted · Role: BE-backend · Date: 2026-09-27 · Guide §10.1, §8.3.1

The guide fixes the topology (3 signer nodes + 1 aggregator per feed, median proposal, sign only within 0.10%, 2-of-3, one `submit` per tick). This ADR records what it leaves open.

1. **Transport.** Nodes serve `GET /v1/observations` and `POST /v1/sign` over HTTP with a shared bearer token (`RELAYER_NODE_TOKEN`, constant-time compare). In production nodes sit on a private network per feed (S5 adds mTLS). `credence-relayer run` wires three in-process nodes for dev only (refused on non-dev chains).
2. **A node never trusts the aggregator for the domain.** Each node builds the EIP-712 domain from its own `CHAIN_ID` and `FEED_ADDRESS`, re-verifies every report against its own observation, and signs only if **all** pass.
3. **Two rounds.** Round 1 sends the full batch. If fewer than `threshold` nodes sign, the aggregator uses each node's refusals to pick the node set (≥ threshold) with the largest common accepted sub-batch, and asks exactly those nodes to sign it (round 2). Seqs keep their round-1 values (gaps are allowed: seq only has to increase).
4. **Median.** The lower median by price (3 nodes → the middle one). The report carries the chosen observation's own `observedAt`, so the timestamp belongs to the print. A proposal needs a quorum (≥ threshold) agreeing on the market status and session. Otherwise nothing is published for that asset (fail closed; on-chain staleness takes over).
5. **Tolerance for each kind.** LIVE, OPEN and CLOSE: |proposal − own| ≤ 0.10% of own, same session and status. STATUS: an identical status and session.
6. **Market status.** Calendar window, overridden toward less open: a halt (Nasdaq Trader feed) → HALTED; vendor says closed while the calendar says REGULAR → CLOSED; calendar closed → CLOSED even if the vendor says open.
7. **Batch order per asset:** STATUS, OPEN, CLOSE, LIVE. Seq is assigned in that order (strictly increasing per asset across kinds, ADR-0101).
8. **Seq recovery.** The next seq is `max(on-chain latestSeq, max(ops.relayer_report.seq)) + 1`, recomputed at start and after any rejected or reverted submit. Every signed report is written to `ops.relayer_report` **before** submission, then marked `accepted` or `rejected` with the tx hash.
9. **Gas.** `eth_estimateGas × 1.3`. A revert at estimation is decoded against the Credence error ABI and the batch is not sent. On a chain that mines only on demand (nitro devnode, quiet periods), the head block can be minutes old, and `observedAt ≤ block.timestamp + 5 s` would reject fresh reports at estimation only. When the head is more than 2 s old, estimation uses a block-timestamp override of "now" (`eth_estimateGas` block overrides), falling back to a plain estimate.
10. **Replay vendor guard.** The guide requires the replay vendor to refuse `CHAIN_ID=421614`. It refuses **every non-dev chain** (only 31337 and 412346 are allowed), which is stricter. The same rule gates local key files.
11. **Cadence** is applied by the aggregator on what the chain **accepted**, so a rejected tick republishes on the next one.
