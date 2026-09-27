# ADR-0008 · Relayer WebSocket streaming with REST fallback

Status: accepted · Sprint 2 · Owner: BE-backend

## Context
§10.1 asks for a LIVE report "immediately on a ≥ 0.10% move". In S1 the nodes polled REST every 2 s and the aggregator ticked every 1 s, so a move took 1–3 s to reach a submit. Both vendors offer WebSocket streams (Alpaca `v2/{iex|sip}`: trades, quotes, statuses, lulds; Massive/Polygon `stocks`: `T`, `Q`, `LULD`).

## Decision
1. **One stream per signer node**, into a per-node `StreamCache` (recent trades for 10 min, the latest NBBO, the stream's halt state and LULD band). The in-process `run` mode shares one stream across its 3 nodes, because the Alpaca free plan allows one connection.
2. **`Streaming` wraps the REST vendor.** `live` reads the cache while the stream is healthy (authenticated, subscribed, a frame within 45 s, pings every 15 s) *and* has data for the symbol; otherwise it uses REST. `status` is REST, cached 5 s (`RELAYER_STATUS_TTL_MS`), merged with the stream's halt state and **failing closed**: halted if either source says halted. OPEN/CLOSE use the listing exchange's auction print seen on the stream (conditions Q/M), else REST.
3. **Event-driven nodes.** Every stream event broadcasts its symbol. The node coalesces a 20 ms burst and re-observes only those assets. The REST poll keeps running as the fallback.
4. **Aggregator tick: 250 ms** (`RELAYER_TICK_MS`). An idle tick only collects snapshots; the cadence rules still decide what is due.
5. **Halt semantics.** Alpaca status codes `2`, `H`, `P`, `Q` → halted; `3`, `T` → trading. `Q` (quotation resumption) keeps the asset halted until `T`. Imbalance and indication codes are ignored. Massive LULD indicator 17 → halted, 18 → resumed (Nasdaq-listed symbols only, per the Massive docs; other halts still come from the Nasdaq Trader feed). Timestamps of unknown unit (the docs say ms, but LULD samples carry ns) are normalised by magnitude.
6. **Reconnect.** Exponential back-off from 0.5 s to 30 s. A vendor rejection (bad key, plan not entitled, connection limit: Alpaca 401/402/404/405/406/409, Massive `auth_failed` / `max_connections` / "not authorized") backs off 5 min, and REST carries on. `relayer_stream_connected{vendor}` is 0 whenever the fallback is in use.

## Consequences
- Measured on the mock-stream test (3 nodes, each with its own connection, aggregator at 250 ms): a 0.20% move reaches `submit` in **~0.2 s** (`services/relayer/tests/stream_latency.rs`, asserted < 1 s). A 0.01% move is not published before the heartbeat.
- The free Massive Basic plan has no real-time WebSocket. Alpaca's free stream is IEX only. The paid plans in ADR-0002 / ADR-0009 are still required for SIP-quality LIVE.
- The delayed Massive endpoint (`delayed.polygon.io`) must never feed LIVE; the URL is config (`POLYGON_WS_URL`).
