// Shared types that mirror contracts/src/libraries/Types.sol (interfaces v1). Enum values are part of
// the ABI: append only, never reorder.
import type { Address, Hex } from "viem";

export const ClockState = {
  REGULAR: 0,
  EXTENDED: 1,
  CLOSED: 2,
  REOPEN: 3,
  HALTED: 4,
  CORP_ACTION: 5,
} as const;
export type ClockState = (typeof ClockState)[keyof typeof ClockState];
export type ClockStateName = keyof typeof ClockState;

/** Restrictiveness (AssetClock): CORP_ACTION > HALTED > CLOSED > REOPEN > EXTENDED > REGULAR. */
export const CLOCK_RESTRICTIVENESS: readonly ClockStateName[] = [
  "REGULAR",
  "EXTENDED",
  "REOPEN",
  "CLOSED",
  "HALTED",
  "CORP_ACTION",
];

export const ClosureType = {
  NONE: 0,
  OVERNIGHT: 1,
  WEEKEND: 2,
  HOLIDAY_WEEKEND: 3,
  HALT: 4,
  CORP_ACTION: 5,
} as const;
export type ClosureType = (typeof ClosureType)[keyof typeof ClosureType];

export const ReportKind = { LIVE: 0, OPEN: 1, CLOSE: 2, NAV: 3, STATUS: 4 } as const;
export type ReportKind = (typeof ReportKind)[keyof typeof ReportKind];

export const FeedMarketStatus = { CLOSED: 0, PRE: 1, REGULAR: 2, POST: 3, OVERNIGHT: 4, HALTED: 5 } as const;
export type FeedMarketStatus = (typeof FeedMarketStatus)[keyof typeof FeedMarketStatus];

export const MarketKind = { EQUITY: 0, NAV: 1 } as const;
export type MarketKind = (typeof MarketKind)[keyof typeof MarketKind];

/** `struct Report` (§8.3.1). Prices are WAD per share. */
export interface Report {
  assetId: Hex;
  kind: number; // ReportKind
  price: bigint; // uint128
  observedAt: number; // uint40, unix seconds
  sessionDate: number; // uint40, floor(regularOpenUtc / 86400)
  marketStatus: number; // FeedMarketStatus
  seq: bigint; // uint64
}

/** `struct Session` (§8.2.1), UTC unix seconds. */
export interface Session {
  extOpen: number;
  open: number;
  close: number;
  extClose: number;
  closureTypeAfter: ClosureType;
}

/** `struct ClockData` (IAssetClock.closureInfo). */
export interface ClockData {
  state: ClockState;
  closureType: ClosureType;
  closureId: bigint;
  venueEpoch: bigint;
  refPrice: bigint;
  refTime: number;
  bellWindowAt: number;
  bellAt: number;
  closeAt: number;
  reopenAt: number;
  openPrint: bigint;
  openPrintAt: number;
  phaseExtension: number;
  sessionCursor: number;
  closedSessions: number;
  nextCloseAt: number;
  reopenPending: boolean;
  corporateAction: boolean;
}

export function clockStateName(s: number): ClockStateName {
  const e = Object.entries(ClockState).find(([, v]) => v === s);
  if (!e) throw new Error(`unknown ClockState ${s}`);
  return e[0] as ClockStateName;
}

export type { Address, Hex };

/** `BellEnforced.outcome` (v1). */
export const BellOutcome = { SAFE: 0, ALREADY_COVERED: 1, AUTO_COVERED: 2, PRECLOSE_THEN_COVER: 3, PRECLOSE_SALE: 4 } as const;
export type BellOutcome = (typeof BellOutcome)[keyof typeof BellOutcome];

/** `ActionNotAllowedInState.action` (v1). */
export const MarketAction = {
  BORROW: 0,
  WITHDRAW_COLLATERAL: 1,
  REPAY: 2,
  ADD_COLLATERAL: 3,
  BUY_COVER: 4,
  FLAG_FOR_AUCTION: 5,
  ENFORCE_BELL: 6,
} as const;
