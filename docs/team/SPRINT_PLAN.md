# Credence Finance: sprint plan

Owner: PM. It maps the 16-week milestone plan in Build Guide §17 onto sprints for the engineer sessions. Each sprint ends with the engineers' reports; the PM reviews them against the acceptance criteria and then issues the next prompts.

| Sprint | BE-chain | BE-backend | New role joining | Guide milestones |
| --- | --- | --- | --- | --- |
| ~~S1: Foundations~~ ✅ accepted 2026-09-28 (review: `docs/handoff/sprint-1-pm-review.md`) | Repo toolchain + CI; **interfaces v0 frozen first**; libraries; CalendarStore, AssetClock, CredencePriceFeed, OracleAdapter, SequencerHealth; test tokens + Faucet; `risk-core` math with golden vectors; `risk-cli`; Stylus spike on the devnode | pnpm workspace; infra (Postgres, nitro-devnode); DB migrations; calendar generator; **price relayer** (vendor adapters, 3 signer nodes + aggregator, EIP-712); keeper skeleton + J1/J12; indexer scaffold (clock + feed events); API skeleton; TS SDK | — | M0, M1, start of M2 |
| **S2: Lending core + risk data** | Full Stylus Risk Engine + differential harness; CredenceMarket; SeniorVault (4626 + queue); KinkedRateModel; SigmaOracle; Tips/Treasury/Reserve | Keeper J3–J5 dry-run mode, J7 σ job; indexer for market, vault and positions; API markets, positions and vault; `credence-bindings` integration | **Quant**: calibration data, scenario sets, joint set, backtest v1 | M2, M3 |
| S3: Risk transfer | UnderwriterPool (epochs, capacity), Bell and cover in the market, AuctionHouse (4 kinds, backstop, GDA) | Keeper full reopen driver, batch driver, epoch lifecycle; notifier; auction WebSocket feed; `/v1/risk` | **Frontend**: app shell, markets, borrow + Bell prompt, lend | M4, M5 |
| S4: NAV + integration | SettlementAdapter, SolverAuction, NAV test fund; scenarios A/B end to end; invariant hardening | NAV settlement jobs; full recorded-weekend run on the devnode; ops dashboards and alerts | **QA / Security**: invariant review, e2e Playwright, pre-audit gates | M6, M7, M8 |
| S5: Testnet | Deploy scripts, Arbiscan verification, Stylus verify, post-deploy checks | Production deploy of the services, KMS, RPC failover, on-call runbooks | **DevOps / SRE** | M9 |
| S6: Soak | Fixes from real weekends; audit package | Fixes; runbook drills | — | M10 |

## Sprint 1 cross-team dependency

```
BE-chain  ──(interfaces v0 + ABIs, first ~20% of the sprint)──►  BE-backend relayer, indexer, SDK
BE-backend ──(calendar JSON for XNYS/USBANK)──►  BE-chain LoadCalendar script + AssetClock fork tests
```

Until the interfaces land, BE-backend works on the parts with no ABI dependency: infra, DB, the calendar, the vendor adapters, and the signer/aggregator logic.
