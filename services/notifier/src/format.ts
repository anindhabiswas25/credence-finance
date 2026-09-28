// Amount formatting for notification copy. Amounts arrive as decimal strings in base units (§10.4).
// §7.2 rounds against the user who acts: an amount the user must pay or add is rounded UP at the shown
// precision, so doing exactly what the message says always cures. Ratios are informational (nearest).

export const WAD = 10n ** 18n;

const group = (int: string) => int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");

/** `base / 10^decimals`, rounded up to `dp` decimals, with thousands separators. */
export function decimalUp(
  base: bigint | string,
  decimals: number,
  dp: number,
): string {
  const v = BigInt(base);
  if (v < 0n) throw new Error("negative amount");
  const shift = decimals - dp;
  const scaled =
    shift >= 0
      ? (v + 10n ** BigInt(shift) - 1n) / 10n ** BigInt(shift)
      : v * 10n ** BigInt(-shift);
  const s = scaled.toString().padStart(dp + 1, "0");
  const int = s.slice(0, s.length - dp);
  const frac = s.slice(s.length - dp);
  return dp > 0 ? `${group(int)}.${frac}` : group(int);
}

/** USD (the loan token), rounded up to the cent: "$2,896.78". */
export function usd(base: bigint | string, decimals = 6): string {
  return `$${decimalUp(base, decimals, 2)}`;
}

/** Collateral tokens to add, rounded up to 3 decimals: "54.419". */
export function tokens(base: bigint | string, decimals = 18, dp = 3): string {
  return decimalUp(base, decimals, dp);
}

/** A WAD ratio as a percentage, nearest, 2 decimals: "74.48%". */
export function pct(wad: bigint | string): string {
  const v = BigInt(wad);
  const bps100 = (v * 10_000n + WAD / 2n) / WAD; // hundredths of a percent
  const s = bps100.toString().padStart(3, "0");
  return `${s.slice(0, -2)}.${s.slice(-2)}%`;
}

const ET = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** "Fri 15:45 ET" */
export function etTime(unixS: number): string {
  const parts = Object.fromEntries(
    ET.formatToParts(new Date(unixS * 1000)).map((p) => [p.type, p.value]),
  );
  return `${parts.weekday} ${parts.hour}:${parts.minute} ET`;
}

/** base / 10^decimals, nearest at `dp` decimals (informational figures: prices, ratios of value). */
export function decimalNearest(
  base: bigint | string,
  decimals: number,
  dp: number,
): string {
  const v = BigInt(base);
  if (v < 0n) throw new Error("negative amount");
  const shift = decimals - dp;
  const scaled =
    shift >= 0
      ? (v + 10n ** BigInt(shift) / 2n) / 10n ** BigInt(shift)
      : v * 10n ** BigInt(-shift);
  const s = scaled.toString().padStart(dp + 1, "0");
  const int = s.slice(0, s.length - dp);
  return dp > 0 ? `${group(int)}.${s.slice(s.length - dp)}` : group(int);
}

/** An amount the user receives or a figure they read (not one they must pay): nearest cent. */
export function usdNearest(base: bigint | string, decimals = 6): string {
  return `$${decimalNearest(base, decimals, 2)}`;
}

/** A WAD price per token: "$171.23". */
export function price(wad: bigint | string): string {
  return usdNearest(wad, 18);
}

/** A WAD ratio as a plain number, 2 decimals: "0.87". */
export function ratio(wad: bigint | string): string {
  return decimalNearest(wad, 18, 2);
}

/** Signed percentage change of `a` against `b` (both WAD prices): "−2.15%". */
export function change(a: bigint | string, b: bigint | string): string {
  const x = BigInt(a);
  const y = BigInt(b);
  if (y === 0n) return "n/a";
  const bps100 = ((x - y) * 1_000_000n) / y; // ten-thousandths
  const r = bps100 < 0n ? -bps100 : bps100;
  const h = (r + 50n) / 100n; // hundredths of a percent, nearest
  const s = h.toString().padStart(3, "0");
  return `${bps100 < 0n ? "−" : "+"}${s.slice(0, -2)}.${s.slice(-2)}%`;
}

const ET_S = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

/** "09:32:00 ET" (the reopen countdown needs seconds). */
export function etClock(unixS: number): string {
  const parts = Object.fromEntries(
    ET_S.formatToParts(new Date(unixS * 1000)).map((p) => [p.type, p.value]),
  );
  return `${parts.hour}:${parts.minute}:${parts.second} ET`;
}
