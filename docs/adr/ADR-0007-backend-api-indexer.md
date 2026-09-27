# ADR-0007 · Indexer and API choices for Sprint 1

Status: accepted · Role: BE-backend · Date: 2026-09-27 · Guide §10.3, §10.4, §11.1

1. **Ponder views schema.** `ponder start --schema <deployment> --views-schema indexer`. The API reads `indexer.clock_state`, `indexer.clock_transition` and `indexer.price_point`, which are stable view names across redeploys. Handlers are pure event projections.
2. **`price_point.status`** is nullable: `ReportAccepted` does not carry the market status (§11.1 lists it). It stays null until the event or a STATUS projection provides it.
3. **Address book.** `@credence/sdk` validates the §13.2 format and also lifts the flat book written by BE-chain's `DeployClockLocal.s.sol` (`deployments/<chainId>.local.json`). On a clean checkout the indexer uses placeholder addresses, so `ponder codegen` / typecheck work without a deployment.
4. **SIWE** uses `viem/siwe` (EIP-4361 parse/validate, plus `verifySiweMessage` for ERC-1271/6492 wallets when `RPC_URL` is set) instead of the `siwe` package. That avoids an ethers dependency next to viem; the protocol is the same. Nonces are single-use rows in `app.siwe_nonce` (10 min). The session cookie `credence_session` is `<uuid>.<HMAC-SHA256>`: httpOnly, SameSite=Lax, Secure in production. `app.siwe_session` is the source of truth (logout and expiry delete it).
5. **Rate limits** are fixed-window, per IP and per session, in-process (`RATE_LIMIT_PER_MIN`, stricter `RATE_LIMIT_AUTH_PER_MIN` on `/v1/auth/*`). Each replica limits independently. A shared store comes with the production deploy (S5).
6. **CORS** reflects only origins in `CORS_ORIGINS` (default `API_PUBLIC_ORIGIN`), with credentials.
7. **Indexer TypeScript** is pinned to 5.9 (Ponder 0.17 peers `typescript ^5`); the other packages use 6.0.
8. **`GET /v1/clock/:assetId`** accepts a bytes32 id or `TICKER:MIC`. Feed health in this response is an **indexed view** (age of the latest LIVE per feed, stale > 60 s). The authoritative health is `OracleAdapter.feedHealth`, which the S2 API will read.
