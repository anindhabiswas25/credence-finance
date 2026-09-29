# Off-chain security review (read-only) · S4

Owner: QA-sec · Scope: `services/api`, `services/relayer`, `services/keeper`, `services/notifier`, `indexer/`,
`crates/credence-common` (signer) at `07fbebe`. Read-only: no file in these paths was changed. Findings go to
BE-backend as board REQUESTs (2026-09-29 14:50); OFF-01 also has a contract side (QA-08, BE-chain).
Method: code reading against the brief's checklist (API auth, zod, SQL, relayer signature and staleness, keeper keys
and nonces, notifier templates), plus one on-chain proof test (`contracts/test/security/OracleFindings.t.sol`).

## Findings (ranked)

| ID | Sev. | Where | Finding | Recommendation | Owner |
| --- | --- | --- | --- | --- | --- |
| OFF-01 | **Medium** | `services/relayer/src/ocr.rs: verify`, `aggregator.rs: assign_seqs`; `CredencePriceFeed._store` | A node checks a proposed report's price (±0.10 %), status, session and future skew, but **not its `seq`**, which the aggregator alone assigns. The feed accepts any `seq` above the stored one. So a compromised aggregator (or anyone who can reach an unauthenticated node, OFF-02) gets two honest signatures on a report with `seq = 2^64 − 1`, and the asset's feed can never advance again: the clock goes stale → CLOSED / HALTED until the timelock replaces the price source (48 h on mainnet). Proven on-chain: `test_QA08_maxSeqEndsTheFeedToday`. The §15.1 control ("2-of-3 signing") assumes the aggregator cannot hurt, and here it can. | Nodes: refuse a `seq` outside `[chain seq + 1, chain seq + W]` (read the chain seq, W ≈ 10,000). Contract (QA-08, BE-chain): bound the step, e.g. `r.seq ≤ f.seq + 2^32`. Also compare the draft's `observedAt` with the node's own observation time (today only the future bound is checked, so a backdated report can be signed). | BE-backend (+ BE-chain QA-08) |
| OFF-02 | **Medium** | `relayer/src/main.rs:51,148`, `node.rs: authorised` | The node API (`POST /v1/sign`) listens on `0.0.0.0:8080` by default and `RELAYER_NODE_TOKEN` is **optional**: without it every request is authorised. Anyone who can reach the port can drive the node's KMS key (within `verify`'s rules, which OFF-01 shows are not enough). | Refuse to start a node without a token off dev chains (as the signer already does for local keys); default the bind to `127.0.0.1` / the private network. | BE-backend |
| OFF-03 | **Medium** | `services/api/src/ratelimit.ts: clientIp`, `app.ts: ipOf` | Every per-IP limit (general, `/v1/auth/*`, and the testnet allowlist's 5 / IP / hour) keys on the **first `X-Forwarded-For` value, which the client sets**; the comment says "trust it only when set by our proxy" but nothing checks that. A script rotates XFF and bypasses all of them: unlimited SIWE nonces (DB rows), unlimited allowlist requests (each queues an ops allowlist transaction, gas from the ops key), and an ever-growing in-memory limiter map. | Trust XFF only when the socket peer is a configured proxy, and then take the right-most untrusted hop; otherwise use the socket address. Cap the limiter map. | BE-backend |
| OFF-04 | Low | `services/api/src/stream.ts: attachStream` | The WS upgrade: (a) checks no `Origin` (cross-site WebSocket hijacking is stopped only by `SameSite=Lax`, and cookies are not `Secure` outside production); (b) sets no `maxPayload` (the `ws` default is 100 MiB, parsed with `JSON.parse`) and no per-IP socket cap; (c) keeps a socket's `owner` after logout or session expiry, so `bell:<owner>` keeps flowing until the client reconnects. `bell:<owner>` itself is correctly bound to the upgrade's SIWE session: one wallet cannot read another's. | Check `Origin` against `CORS_ORIGINS` at the upgrade; `maxPayload` ≈ 16 KiB and a per-IP connection cap; re-check the session on a timer (or close the owner's sockets on logout). | BE-backend |
| OFF-05 | Low | `api/src/me.ts` (push subscribe), `notifier/src/channels/push.ts` | A push subscription's `endpoint` may be **any** `https://` URL, and the notifier POSTs to it: blind server-side request to attacker-chosen hosts (internal HTTPS services, other tenants). | Allowlist the push services' hosts (FCM, Mozilla autopush, Apple, WNS). | BE-backend |
| OFF-06 | Low | `api/src/me.ts` (`telegramChatId`) | The Telegram chat id is taken as given: an account can route its alerts to any chat that has started the bot (spam through Credence's bot; no data of another user leaks). | Link the chat through a `/start <token>` deep link, as email does with its verification link. | BE-backend |
| OFF-07 | Low | `indexer/src/api/index.ts` | Ponder's `/sql/*` (arbitrary read-only SQL) and `/graphql` are mounted; if the indexer port is reachable they allow unbounded queries on the database the API and keeper read. | Keep the indexer on the private network (the API is the public read surface) or set a `statement_timeout` for that role. | BE-backend |
| OFF-08 | Low | `api/src/app.ts: /metrics`; relayer `METRICS_ADDR` 0.0.0.0:9101 | Prometheus metrics on the public API port and on all interfaces. | Serve metrics on a separate private listener. | BE-backend |
| OFF-09 | Info | `keeper/src/tx.rs` | A stuck transaction is re-signed at the same nonce with +20 % fees every 3 blocks until the timeout, with **no fee ceiling** (bounded in practice on Arbitrum, which charges the base fee, but §15.1 asks for caps on hot wallets). | `max_fee ≤ KEEPER_MAX_FEE_GWEI`. | BE-backend |
| OFF-10 | Info | `notifier/src/templates.ts: esc` | `esc` escapes `& < >` but not quotes, and is also used inside `href="…"`. Safe today (URLs are built server-side from config and hex ids). | Escape `"` and `'` too. | BE-backend |
| OFF-11 | Info | `api/src/app.ts` (SIWE verify) | The nonce is consumed before the signature is checked and is not bound to the requesting client: whoever learns a user's nonce can burn it (that one login fails; no takeover). | Verify the signature first, or bind the nonce to a pre-session cookie. | BE-backend |

## What is sound (checked, no finding)
- **SIWE:** EIP-4361 parse + `validateSiweMessage` (domain, time) + chain id + single-use 10-min nonce (deleted on use) +
  EOA or ERC-1271/6492 signature; session = random UUID in an HMAC-SHA256 cookie (timing-safe compare) backed by a DB
  row (logout and expiry delete it); `httpOnly`, `SameSite=Lax`, `Secure` in production. Every `/v1/me/*` route takes the
  address **from the session, never from the body**.
- **CORS:** explicit origin allowlist with credentials; methods GET/POST/PUT; only `content-type` allowed.
- **Input validation:** every public route is an OpenAPI route with a zod schema (bodies `.strict()`, bounded strings,
  regex-checked hex, `https://` push endpoints, email format). Raw `app.get` routes are `/healthz`, `/metrics`,
  `/readyz` and the WS upgrade, whose frames are parsed and whitelisted by channel regex.
- **SQL:** postgres.js tagged templates everywhere (parameterised); the only `sql(identifier)` interpolates the indexer
  schema name from configuration. No string-built SQL from inputs (API, notifier, indexer).
- **Relayer signing:** EIP-712 domain with chain id and feed address; low-s normalised signatures; nodes refuse
  reports > 0.10 % from their own view, with another status or session, or > 5 s in the future; vendor prints older
  than 60 s (REGULAR) / 300 s (EXTENDED) are not observed at all (fail closed); keys in KMS (local keys refuse to load
  off dev chains). On-chain: sorted unique signers, threshold, per-asset `seq` replay guard (but see OFF-01).
- **Keeper:** KMS signer; one sender per chain with a local nonce resynced from the pending nonce on leadership change
  or nonce errors; same-nonce replacement; Postgres advisory-lock leader election with fencing (a stale leader's
  backend is terminated), so two instances never send with the same key.
- **Notifier:** Telegram messages are plain text (no `parse_mode`: no markup injection); email HTML escapes every
  interpolated value; payloads are zod-parsed per event before rendering.
