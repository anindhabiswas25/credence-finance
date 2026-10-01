# syntax=docker/dockerfile:1.7
# Notifier (@credence/notifier, Node 24) image for the local testnet stack and Railway (infra/prod, owner: DevOps).
# Build context: the repo root. Config is env only; secrets come as FILE__<NAME> paths (entrypoint.sh).
# Health: GET /healthz and /readyz (and /metrics) on NOTIFIER_HOST:NOTIFIER_PORT (private, 9103).
FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/config packages/config
COPY services/notifier services/notifier
RUN --mount=type=cache,id=credence-pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --filter "@credence/notifier..." && pnpm --filter "@credence/notifier" build

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /app credence
COPY --from=build /app /app
COPY infra/prod/docker/entrypoint.sh /usr/local/bin/credence-entrypoint
# the loan token's symbol and decimals come from each chain's address book (DEPLOYMENTS_FILE_<id>)
COPY deployments /app/deployments
WORKDIR /app/services/notifier
ENV NODE_ENV=production
USER credence
ENTRYPOINT ["/usr/local/bin/credence-entrypoint"]
CMD ["node", "dist/main.js"]
