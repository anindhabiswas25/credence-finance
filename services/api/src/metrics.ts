// Prometheus metrics (§10: every service exposes /metrics; §16.1 API latency dashboard).
import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export function createMetrics(withDefaults = true) {
  const registry = new Registry();
  if (withDefaults) collectDefaultMetrics({ register: registry, prefix: "credence_api_" });
  return {
    registry,
    /** By route *pattern* (e.g. /v1/clock/:assetId), never the raw path, so cardinality stays bounded. */
    duration: new Histogram({
      name: "credence_api_http_request_duration_seconds",
      help: "HTTP request duration",
      labelNames: ["method", "route", "status"] as const,
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
      registers: [registry],
    }),
    requests: new Counter({
      name: "credence_api_http_requests_total",
      help: "HTTP requests",
      labelNames: ["method", "route", "status"] as const,
      registers: [registry],
    }),
  };
}

export type ApiMetrics = ReturnType<typeof createMetrics>;
