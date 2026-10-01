// Why a market is paused (PM 16:30 ruling 2, S5): a tester must see the reason, not a silent "paused".
// Derived from the indexed clock state and the age of the newest LIVE print per feed, with the OracleAdapter's
// limits (STALE_REGULAR 60 s, STALE_EXTENDED 300 s). The authoritative check stays OracleAdapter.feedHealth.
import { z } from "@hono/zod-openapi";
import { ClockState } from "@credence/sdk";

export const STALE_REGULAR_S = 60;
export const STALE_EXTENDED_S = 300;

export const PauseBody = z
  .object({
    reason: z.enum([
      "STALE_REGULAR",
      "STALE_EXTENDED",
      "CLOSED",
      "REOPEN",
      "HALTED",
      "CORP_ACTION",
    ]),
    message: z.string(),
  })
  .nullable()
  .openapi("Pause", {
    description:
      "Why borrowing is paused on this asset now (null: not paused by the clock or a stale feed)",
  });
export type Pause = z.infer<typeof PauseBody>;

/** `feedTimes`: each feed's newest LIVE observedAt (unix s); the oldest one decides (a stale feed pauses). No LIVE
 * feed at all (a NAV asset, or nothing indexed yet) is not reported as stale: the clock state still is. */
export function pauseReason(
  state: number,
  feedTimes: readonly (number | bigint)[],
  nowS: number,
): Pause {
  const age =
    feedTimes.length === 0
      ? 0
      : Math.max(...feedTimes.map((t) => nowS - Number(t)));
  switch (state) {
    case ClockState.REGULAR:
      return age > STALE_REGULAR_S
        ? {
            reason: "STALE_REGULAR",
            message: `No price newer than ${STALE_REGULAR_S} s in the regular session: borrowing is paused until the feed publishes again.`,
          }
        : null;
    case ClockState.EXTENDED:
      return age > STALE_EXTENDED_S
        ? {
            reason: "STALE_EXTENDED",
            message:
              "No extended-hours price for this asset, so borrowing is paused until the regular session opens. " +
              "On testnet RedStone publishes no extended-hours feed for MSFT, GOOGL and AMZN: this is expected, not a fault.",
          }
        : null;
    case ClockState.CLOSED:
      return {
        reason: "CLOSED",
        message:
          "The venue is closed: new borrowing waits for the next session.",
      };
    case ClockState.REOPEN:
      return {
        reason: "REOPEN",
        message:
          "The market is reopening after a closure (open print and settlement); borrowing resumes when it completes.",
      };
    case ClockState.HALTED:
      return {
        reason: "HALTED",
        message:
          "Trading in the asset is halted (or, for a NAV asset, no NAV print yet): borrowing is paused.",
      };
    case ClockState.CORP_ACTION:
      return {
        reason: "CORP_ACTION",
        message:
          "A corporate action is in progress: borrowing is paused until it is confirmed.",
      };
    default:
      return null;
  }
}
