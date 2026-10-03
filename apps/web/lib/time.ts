/** Market time: every clock in the app is shown in US Eastern, like the exchanges. */
const parts = (ts: number) =>
  Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "America/New_York",
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    })
      .formatToParts(new Date(ts * 1000))
      .map((p) => [p.type, p.value]),
  );

/** "Fri 2 Oct, 16:00 ET" from unix seconds. */
export function et(ts: number | null | undefined): string {
  if (!ts) return "—";
  const p = parts(ts);
  return `${p.weekday} ${p.day} ${p.month}, ${p.hour}:${p.minute} ET`;
}

/** "Fri 16:00" (short form for stat blocks). */
export function etShort(ts: number | null | undefined): string {
  if (!ts) return "—";
  const p = parts(ts);
  return `${p.weekday} ${p.hour}:${p.minute}`;
}

/** "28 Sep 2026, 14:12" in the viewer's own time (for their activity). */
export function local(ms: number): string {
  return new Date(ms).toLocaleString("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

/** "2h 14m" until a unix-seconds deadline, or null once it has passed. */
export function until(ts: number | null | undefined, now = Date.now() / 1000): string | null {
  if (!ts || ts <= now) return null;
  const s = Math.floor(ts - now);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m ${s % 60}s`;
}
