# Build one Rust service from the workspace: --build-arg BIN=credence-relayer | credence-keeper
FROM rust:1.95-bookworm AS build
ARG BIN
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    cargo build --locked --release -p ${BIN} && cp target/release/${BIN} /usr/local/bin/service

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 credence
COPY --from=build /usr/local/bin/service /usr/local/bin/service
COPY calibration/out/calendars /app/calibration/out/calendars
COPY deployments /app/deployments
WORKDIR /app
USER credence
ENTRYPOINT ["/usr/local/bin/service"]
CMD ["run"]
