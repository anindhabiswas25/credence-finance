# ADR-0010 · Notifier queue, delivery semantics and copy rounding

Status: accepted · Sprint 2 · Owner: BE-backend

## Context
§10.5 specifies a Postgres queue (`app.notification_job`, `FOR UPDATE SKIP LOCKED`) with Resend, VAPID Web Push and Telegram, retries, dead-lettering and `notification_log`. It leaves open the retry model, per-channel semantics, email ownership, and how amounts are rounded in the copy.

## Decision
1. **Queue** (migration `20260928000001_notifier.sql`, additive). Status `pending → sending → sent | retry | dead | expired | skipped`. A worker claims a batch with `FOR UPDATE SKIP LOCKED` and sets `locked_at`/`locked_by`. A job left in `sending` by a dead worker is reclaimed after `NOTIFIER_LOCK_TIMEOUT_S` (120 s). An insert trigger does `pg_notify('notification_job')` so the worker wakes at once; a 1 s poll is the safety net.
2. **Dedupe.** Producers insert with `on conflict (dedupe_key) do nothing` (`enqueue()` in `@credence/notifier`). Keeper J2 keys are `J2:<closureId>:<borrower>:<stage>`.
3. **Per-channel retries.** `delivered_channels` and `failed_channels` persist across attempts, so a retry never re-sends a channel that already went out. Transient errors (network, 408/425/429/5xx) retry with back-off `30 s × 2^(k−1)`, capped at 1 h, for up to 6 attempts; after that the job is dead-lettered (`status = 'dead'`, `last_error`). Permanent errors (other 4xx, a blocked bot, a push 404/410) are not retried. Gone push subscriptions are deleted. Resend gets `Idempotency-Key: <dedupe_key>:email`, so a reclaimed job cannot send the same email twice.
4. **Outcome.** `sent` if at least one channel delivered and nothing transient remains; `dead` if every channel failed permanently or retries ran out; `skipped` if the account has no deliverable channel; `expired` if the payload's `expiresAt` (the Bell deadline for heads-ups) passed before delivery. A late heads-up is worse than none.
5. **Channels.** The event defaults follow §10.5. `app.notification_pref (event, channel, enabled=false)` turns a channel off. Email goes only to **verified** addresses (the verification mail itself excepted: `app.email_verification` stores `sha256(token)`, and the API flow ships with `PUT /v1/me/notifications`), so nobody can point Bell alerts at someone else's inbox. A channel without provider credentials is disabled at start.
6. **Web Push** uses `web-push` to build the RFC 8291 aes128gcm body and the VAPID JWT, and sends it with `fetch`. The e2e decrypts the payload with the subscriber's key.
7. **Copy rounding (§7.2).** An amount the user must pay or add is rounded **up** at the shown precision: USD to the cent, tokens to 3 decimals. Doing exactly what the message says therefore always cures. Sale lots are shown to 4 decimals. Ratios are rounded to the nearest 0.01%. R-18: whenever "Gap Cover" appears, the sentence on what it buys appears too, and nothing says "insured" (tested on every variant).

## Consequences
- G-10's "add 22.584 tokens" (Appendix A) and "22.58 tNVDA" (§10.5 example) are rounded to nearest; either leaves the loan about 0.0004 tNVDA short of the safe LTV. The notifier shows **22.585**. G-11 (54.419) and all USD amounts match Appendix A exactly. This is flagged in the S2 report under "Spec issues".
- Throughput is bounded by the providers, not the queue. Workers scale horizontally on the same table.
