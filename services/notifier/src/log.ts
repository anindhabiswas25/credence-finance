// JSON logs through pino (Build Guide §6.4, §10). LOG_LEVEL filters.
import { pino } from "pino";

export const log = pino({
  name: "credence-notifier",
  level: process.env.LOG_LEVEL ?? "info",
});
