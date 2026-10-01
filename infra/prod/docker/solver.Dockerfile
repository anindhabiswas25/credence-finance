# syntax=docker/dockerfile:1.7
# solver (credence-solver) image for the local testnet stack and Railway (infra/prod, owner: DevOps).
# Build context: the repo root. Config is env only; secrets come as FILE__<NAME> paths (entrypoint.sh).
# Health: /healthz and /readyz on the metrics listener (METRICS_ADDR).
FROM rust:1.95-bookworm AS build
# Charter §2a: a shared machine, so the build is capped (override with --build-arg CARGO_BUILD_JOBS=n)
ARG CARGO_BUILD_JOBS=4
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates crates
COPY services services
COPY stylus stylus
# credence-bindings compiles the frozen ABIs (deployments/abis/<tag>)
COPY deployments/abis deployments/abis
RUN --mount=type=cache,id=credence-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=credence-prod-target,target=/src/target,sharing=locked \
    cargo build --locked --release -p credence-bidder --bin credence-solver && cp target/release/credence-solver /usr/local/bin/credence-solver

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /app credence
COPY --from=build /usr/local/bin/credence-solver /usr/local/bin/credence-solver
COPY infra/prod/docker/entrypoint.sh /usr/local/bin/credence-entrypoint
# runtime data the service reads relative to /app: calendars, σ snapshots, the address books
COPY calibration/out /app/calibration/out
COPY deployments /app/deployments
WORKDIR /app
USER credence
ENTRYPOINT ["/usr/local/bin/credence-entrypoint", "/usr/local/bin/credence-solver"]
CMD []
