// Prometheus metrics (§10: every service exposes /metrics).
import {
  Counter,
  Gauge,
  Histogram,
  Registry,
  collectDefaultMetrics,
} from "prom-client";

export function createMetrics() {
  const registry = new Registry();
  collectDefaultMetrics({ register: registry, prefix: "credence_notifier_" });
  return {
    registry,
    jobs: new Counter({
      name: "credence_notifier_jobs_total",
      help: "jobs finished, by event and status (sent, retry, dead, expired, skipped)",
      labelNames: ["event", "status"],
      registers: [registry],
    }),
    deliveries: new Counter({
      name: "credence_notifier_deliveries_total",
      help: "channel deliveries by result (ok, transient, permanent)",
      labelNames: ["channel", "result"],
      registers: [registry],
    }),
    latency: new Histogram({
      name: "credence_notifier_delivery_seconds",
      help: "provider call latency",
      labelNames: ["channel"],
      buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
      registers: [registry],
    }),
    queueDepth: new Gauge({
      name: "credence_notifier_queue_depth",
      help: "jobs by status (pending, retry, sending, dead)",
      labelNames: ["status"],
      registers: [registry],
    }),
    oldestDueSeconds: new Gauge({
      name: "credence_notifier_oldest_due_seconds",
      help: "age of the oldest due job (delivery lag)",
      registers: [registry],
    }),
  };
}

export type Metrics = ReturnType<typeof createMetrics>;
