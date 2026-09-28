// The relayer's replay recording for scenario A (VENDOR=replay), stamped on the chain's own calendar.
// Recording time == wall time: the runner starts the relayer with REPLAY_START_OFFSET_S = now − recStart.
//
// Prices (per ticker): `base` until `driftAt` (the Friday session, 2 h 10 min before the close), then
// `base × drift` (NVDA −1%: Priya and Maya cross the safe LTV before the T−2h heads-up), the official
// close print at that level, and at the Monday open `close × gap` (NVDA −14%, TSLA −30%).
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { OUT, chainSessions, friday, pub } from "./lib.ts";

export const PATH: Record<
  string,
  { base: number; drift: number; gap: number }
> = {
  NVDA: { base: 180, drift: 0.99, gap: 0.86 },
  TSLA: { base: 372, drift: 1, gap: 0.7 },
  AAPL: { base: 340, drift: 1, gap: 1 },
};
export const DRIFT_BEFORE_CLOSE_S = 2 * 3600 + 10 * 60;

const round2 = (x: number) => Math.round(x * 100) / 100;
export function priceAt(
  sym: string,
  t: number,
  fri: { close: number },
  mondayOpen: number,
): number {
  const p = PATH[sym]!;
  const friClose = round2(p.base * p.drift);
  if (t >= mondayOpen) return round2(friClose * p.gap);
  if (t >= fri.close - DRIFT_BEFORE_CLOSE_S) return friClose;
  return p.base;
}

if (import.meta.main ?? process.argv[1]?.endsWith("replay.ts")) {
  const sessions = await chainSessions("XNYS");
  const now = Number((await pub.getBlock()).timestamp);
  const start = Math.max(now, Math.floor(Date.now() / 1000)) - 60;
  const { s: fri, next: mon } = friday(sessions, start);
  const end = mon.close + 15 * 60;
  const ns = (t: number) => BigInt(Math.round(t * 1e9)).toString();
  const lines: string[] = [
    JSON.stringify({ ev: "header", venue: "XNYS", sessions }),
  ];
  const ev: [number, string][] = [];
  for (const s of sessions) {
    if (s.extClose < start || s.extOpen > end) continue;
    ev.push([
      s.extOpen,
      JSON.stringify({ ev: "market", t: ns(s.extOpen), m: "extended" }).replace(
        /"t":"(\d+)"/,
        '"t":$1',
      ),
    ]);
    ev.push([
      s.open,
      JSON.stringify({ ev: "market", t: ns(s.open), m: "open" }).replace(
        /"t":"(\d+)"/,
        '"t":$1',
      ),
    ]);
    ev.push([
      s.close,
      JSON.stringify({ ev: "market", t: ns(s.close), m: "extended" }).replace(
        /"t":"(\d+)"/,
        '"t":$1',
      ),
    ]);
    ev.push([
      s.extClose,
      JSON.stringify({ ev: "market", t: ns(s.extClose), m: "closed" }).replace(
        /"t":"(\d+)"/,
        '"t":$1',
      ),
    ]);
  }
  const put = (t: number, o: Record<string, unknown>) =>
    ev.push([
      t,
      JSON.stringify({ ...o, t: "__T__" }).replace('"__T__"', ns(t)),
    ]);
  for (const sym of Object.keys(PATH)) {
    const px = (t: number) => priceAt(sym, t, fri, mon.open);
    for (const s of sessions) {
      if (s.extClose < start || s.extOpen > end) continue;
      // extended hours: Form T every 30 s
      for (let t = Math.max(s.extOpen, start); t < s.open; t += 30)
        put(t, {
          ev: "trade",
          sym,
          p: px(t),
          s: 100,
          x: "ARCX",
          c: ["@", "T"],
          z: "C",
        });
      for (
        let t = Math.max(s.close, start);
        t < Math.min(s.extClose, end);
        t += 30
      )
        put(t + 2, {
          ev: "trade",
          sym,
          p: px(t),
          s: 100,
          x: "ARCX",
          c: ["@", "T"],
          z: "C",
        });
      if (s.close <= start) continue;
      // the official opening print on the listing market, then regular trades every 5 s
      if (s.open >= start)
        put(s.open + 1, {
          ev: "trade",
          sym,
          p: px(s.open),
          s: 1000,
          x: "XNAS",
          c: ["Q"],
          z: "C",
        });
      for (let t = Math.max(s.open + 2, start); t < s.close; t += 5) {
        put(t, { ev: "quote", sym, bp: px(t) - 0.01, ap: px(t) + 0.01 });
        put(t + 0.001, {
          ev: "trade",
          sym,
          p: px(t),
          s: 100,
          x: "XNAS",
          c: ["@"],
          z: "C",
        });
      }
      put(s.close + 1, {
        ev: "trade",
        sym,
        p: px(s.close - 1),
        s: 1000,
        x: "XNAS",
        c: ["M"],
        z: "C",
      });
    }
  }
  ev.sort((a, b) => a[0] - b[0]);
  for (const [, l] of ev) lines.push(l);
  const file = resolve(OUT, "replay.jsonl");
  writeFileSync(file, lines.join("\n") + "\n");
  const recStart = ev[0]![0];
  writeFileSync(
    resolve(OUT, "replay.meta.json"),
    JSON.stringify({
      recStart: Math.floor(recStart),
      fridayClose: fri.close,
      mondayOpen: mon.open,
      mondayClose: mon.close,
    }),
  );
  console.log(
    `replay: ${ev.length} events from ${recStart} (Friday close ${fri.close}, Monday open ${mon.open}) → ${file}`,
  );
}
