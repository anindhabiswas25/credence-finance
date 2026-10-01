# syntax=docker/dockerfile:1.7
# Indexer (@credence/indexer, Ponder 0.17), one per chain, image for the local testnet stack and Railway (infra/prod, owner: DevOps).
# Build context: the repo root. Config is env only; secrets come as FILE__<NAME> paths (entrypoint.sh).
# Health: GET /health and /ready on PORT (42069, private network only: OFF-07). Metrics: /metrics on the same port.
# Per chain: PONDER_CHAIN_ID, PONDER_RPC_URL_<id>, DATABASE_SCHEMA=indexer_<id>, VIEWS_SCHEMA=ix_<id>.

# @credence/risk-wasm (crates/risk-wasm/pkg), which @credence/sdk links: the same steps as `make risk-wasm`
FROM rust:1.95-bookworm AS wasm
ARG CARGO_BUILD_JOBS=4
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}
RUN --mount=type=cache,id=credence-cargo-registry,target=/usr/local/cargo/registry \
    cargo install wasm-pack --version 0.15.0 --locked
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates crates
# every workspace member must be present for cargo to load the workspace
COPY services/relayer services/relayer
COPY services/keeper services/keeper
COPY services/bidder services/bidder
COPY stylus stylus
RUN --mount=type=cache,id=credence-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=credence-wasm-target,target=/src/target,sharing=locked \
    set -eu; P=crates/risk-wasm/pkg; rm -rf $P; \
    wasm-pack build crates/risk-wasm --release --no-pack --target nodejs --out-dir pkg/node --out-name credence_risk_wasm; \
    wasm-pack build crates/risk-wasm --release --no-pack --target web --out-dir pkg/web --out-name credence_risk_wasm; \
    cp crates/risk-wasm/js/package.json crates/risk-wasm/js/node.mjs crates/risk-wasm/js/web.mjs crates/risk-wasm/js/index.d.ts $P/; \
    echo '{ "type": "commonjs" }' > $P/node/package.json; rm -f $P/node/.gitignore $P/web/.gitignore

FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages packages
COPY indexer indexer
COPY deployments deployments
COPY --from=wasm /src/crates/risk-wasm/pkg crates/risk-wasm/pkg
RUN --mount=type=cache,id=credence-pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --filter "@credence/indexer..." && pnpm --filter "@credence/indexer^..." build

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /app credence
COPY --from=build /app /app
COPY infra/prod/docker/entrypoint.sh /usr/local/bin/credence-entrypoint
WORKDIR /app/indexer
# ponder writes its build cache and generated schema at start; the container may run as the host user

RUN mkdir -p .ponder generated && touch ponder-env.d.ts && chmod -R a+rwX .ponder generated ponder-env.d.ts && chmod a+rwx .
ENV NODE_ENV=production
USER credence
EXPOSE 42069
ENTRYPOINT ["/usr/local/bin/credence-entrypoint"]
CMD ["sh", "-c", "exec node_modules/.bin/ponder start --schema \"${DATABASE_SCHEMA:?}\" --views-schema \"${VIEWS_SCHEMA:?}\" --port \"${PORT:-42069}\""]
