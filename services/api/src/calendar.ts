// Next calendar boundaries for GET /v1/clock (§10.4 "next transitions"), from the same generated
// calendars the CalendarStore holds (calibration/out/calendars).
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { keccak256, stringToHex, type Hex } from "viem";
import type { Session } from "@credence/sdk";

const VENUE_OF: Record<string, string> = {
  XNAS: "XNYS",
  XNYS: "XNYS",
  ARCX: "XNYS",
  XASE: "XNYS",
  BATS: "XNYS",
  USBANK: "USBANK",
};

function findDir(start: string): string | undefined {
  let dir = resolve(start);
  for (;;) {
    const d = join(dir, "calibration/out/calendars");
    if (existsSync(d)) return d;
    const up = resolve(dir, "..");
    if (up === dir) return undefined;
    dir = up;
  }
}

export function loadCalendars(
  dir = process.env.CALENDAR_DIR ?? findDir(process.cwd()),
): Map<string, Session[]> {
  const out = new Map<string, Session[]>();
  if (!dir) return out;
  for (const f of readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()) {
    const doc = JSON.parse(readFileSync(join(dir, f), "utf8")) as {
      venue: string;
      sessions: Session[];
    };
    const prev = out.get(doc.venue) ?? [];
    const merged = [...prev, ...doc.sessions]
      .sort((a, b) => a.open - b.open)
      .filter((s, i, a) => i === 0 || s.open !== a[i - 1]!.open);
    out.set(doc.venue, merged);
  }
  return out;
}

export function boundariesAfter(
  sessions: Session[],
  now: number,
  horizonS = 36 * 3600,
): { at: number; kind: string }[] {
  const out: { at: number; kind: string }[] = [];
  for (const s of sessions) {
    if (s.extClose < now) continue;
    if (s.extOpen > now + horizonS) break;
    const b: [number, string][] = [
      [s.extOpen, "extOpen"],
      [s.open, "open"],
      [s.close - 7200, "bellWindow"],
      [s.close - 900, "bell"],
      [s.close, "close"],
      [s.extClose, "extClose"],
    ];
    for (const [at, kind] of b)
      if (at > now && at <= now + horizonS) out.push({ at, kind });
  }
  out.sort((a, b) => a.at - b.at);
  return out.filter((x, i, a) => i === 0 || x.at !== a[i - 1]!.at);
}

/** asset id → venue, from ASSETS=NVDA:XNAS,…,TBILL:USBANK */
export function assetVenues(specs: string[]): Map<Hex, string> {
  const m = new Map<Hex, string>();
  for (const s of specs) {
    const [t, mic] = s.split(":").map((x) => x.trim().toUpperCase());
    if (!t || !mic || !VENUE_OF[mic]) continue;
    m.set(keccak256(stringToHex(`${t}:${mic}`)), VENUE_OF[mic]!);
  }
  return m;
}
