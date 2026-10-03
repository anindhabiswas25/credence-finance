/**
 * The app's building blocks, each one a piece of the dashboard mockup on the landing page.
 * All are server components; the interactive tiles live in actions.tsx.
 */
import type { ReactNode } from "react";
import { Icon } from "./Icon";

export type Activity = { icon: string; title: string; when: string; amount: string; href?: string };

export const usd = (n: number, digits = 2) =>
  n.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });
export const num = (n: number, digits = 2) =>
  n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
export const pct = (n: number, digits = 1) => `${(n * 100).toFixed(digits)}%`;

export function PageHead({ title, sub, right }: { title: string; sub?: string; right?: ReactNode }) {
  return (
    <header className="cx-page-head">
      <div>
        <h1 className="cx-page-title">{title}</h1>
        {sub && <p className="cx-page-sub">{sub}</p>}
      </div>
      {right}
    </header>
  );
}

export function H({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <h2 className="cx-h">
      <span>{children}</span>
      {right}
    </h2>
  );
}

export function Pill({ children, tone }: { children: ReactNode; tone?: "soft" | "good" | "warn" | "bad" }) {
  return <span className={`cx-pill${tone ? ` is-${tone}` : ""}`}>{children}</span>;
}

/** The gradient card: the loan card in the mockup, reused for vault, pool and market cards. */
export function GradientCard({
  tag,
  big,
  label,
  value,
  pill,
  logo,
}: {
  /** The asset's or token's logo; the Credence mark when absent. */
  logo?: string | null;
  tag: ReactNode;
  big: ReactNode;
  label: string;
  value: ReactNode;
  pill?: ReactNode;
}) {
  return (
    <div className="cx-card">
      <div className="cx-card-top">
        <CardMark logo={logo} />
        <span className="cx-card-tag">{tag}</span>
      </div>
      <div className="cx-card-big">{big}</div>
      <div className="cx-card-foot">
        <div>
          <div className="cx-card-label">{label}</div>
          <div className="cx-card-value">{value}</div>
        </div>
        {pill}
      </div>
    </div>
  );
}

export function CardMark({ logo }: { logo?: string | null }) {
  return logo ? (
    <img className="cx-card-mark is-token" src={logo} alt="" />
  ) : (
    <img className="cx-card-mark" src="/landing/mark-ink.svg" alt="" />
  );
}

export function ActivityList({ items, compact }: { items: Activity[]; compact?: boolean }) {
  return (
    <ul className={`cx-list${compact ? " is-compact" : ""}`}>
      {items.map((a, i) => (
        <li key={i}>
          <Icon name={a.icon} size={30} strokeWidth={1.6} />
          <span className="cx-list-title">{a.title}</span>
          <span className="cx-list-when">{a.when}</span>
          <span className="cx-list-amount">{a.amount}</span>
          <span className="cx-list-more">
            {a.href ? (
              <a href={a.href} target="_blank" rel="noreferrer" aria-label="View transaction">
                <Icon name="external" size={20} />
              </a>
            ) : (
              <Icon name="dots" size={22} />
            )}
          </span>
        </li>
      ))}
    </ul>
  );
}

/** The big readout at the top of the grey aside ("Health factor 1.07"). */
export function StatBlock({ label, value, chip }: { label: string; value: ReactNode; chip?: string }) {
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
        <div>
          <div className="cx-stat-label">{label}</div>
          <div className="cx-stat-value">{value}</div>
        </div>
        {chip && <span className="cx-chip">{chip}</span>}
      </div>
    </div>
  );
}

/** A blue row from the mockup's "Your markets" list. */
export function StatRow({ big, unit, sub, tag }: { big: string; unit?: string; sub?: ReactNode; tag?: string }) {
  return (
    <div className="cx-stat-row">
      <b>{big}</b>
      {unit && <span className="cx-unit">{unit}</span>}
      <span className="cx-stat-right">
        {sub && <span className="cx-sub">{sub}</span>}
        {tag && <span className="cx-tag">{tag}</span>}
      </span>
    </div>
  );
}

export function KV({ rows, list }: { rows: [ReactNode, ReactNode][]; list?: boolean }) {
  return (
    <dl className={`cx-kv${list ? " is-list" : ""}`}>
      {rows.map(([k, v], i) => (
        <div key={i}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Bar({ value, color }: { value: number; color?: string }) {
  return (
    <div className="cx-bar" role="presentation">
      <span style={{ width: `${Math.min(100, Math.max(0, value * 100))}%`, background: color }} />
    </div>
  );
}

export function Note({ icon = "clock", children }: { icon?: string; children: ReactNode }) {
  return (
    <div className="cx-note">
      <span className="cx-tile-icon">
        <Icon name={icon} size={20} strokeWidth={1.9} />
      </span>
      <div>{children}</div>
    </div>
  );
}

/** A static tile (no action), e.g. a figure in a row of tiles. */
export function InfoTile({ icon, title, sub, amount }: { icon: string; title: string; sub: string; amount: string }) {
  return (
    <div className="cx-tile" style={{ cursor: "default", transform: "none" }}>
      <span className="cx-tile-icon">
        <Icon name={icon} size={24} strokeWidth={1.9} />
      </span>
      <span className="cx-tile-title">{title}</span>
      <span className="cx-tile-sub">{sub}</span>
      <span className="cx-tile-amount">{amount}</span>
    </div>
  );
}

/** The loss waterfall: who pays first when a reopen goes badly. */
export function Waterfall({ layers }: { layers: { name: string; note: string; amount: string; tone: "ink" | "tile" | "white" }[] }) {
  const styles = {
    ink: { background: "var(--cx-ink)", color: "#fff" },
    tile: { background: "var(--cx-tile)", color: "var(--cx-ink)" },
    white: { background: "#fff", color: "var(--cx-ink)", border: "1px solid var(--cx-line)" },
  };
  return (
    <div className="cx-waterfall">
      {layers.map((l, i) => (
        <div key={l.name} className="cx-layer" style={styles[l.tone]}>
          <span>
            {i + 1}. {l.name}
            <small>{l.note}</small>
          </span>
          <b>{l.amount}</b>
        </div>
      ))}
    </div>
  );
}

/**
 * The mockup's line chart: a smooth line over four gridlines, with one highlighted reading
 * (a fading bar, a dot and a dark tooltip). Values are mapped between the first and last tick.
 */
export function LineChart({
  values,
  labels,
  ticks,
  highlight,
  tooltip,
  tickLabel = (t) => String(t),
  ariaLabel,
}: {
  values: number[];
  labels: string[];
  ticks: number[];
  highlight: number;
  tooltip: string;
  tickLabel?: (t: number) => string;
  ariaLabel: string;
}) {
  const W = 300;
  const H = 250;
  const left = 34;
  const right = 292;
  const top = 26;
  const bottom = 196;
  const lo = Math.min(...ticks);
  const hi = Math.max(...ticks);
  const x = (i: number) => left + 12 + (i * (right - left - 24)) / (values.length - 1);
  const y = (v: number) => bottom - ((v - lo) / (hi - lo)) * (bottom - top);
  const pts = values.map((v, i) => [x(i), y(v)] as const);
  // Catmull-Rom to Bezier for the smooth curve.
  let d = `M${pts[0]![0]},${pts[0]![1]}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[Math.max(0, i - 1)]!;
    const p1 = pts[i]!;
    const p2 = pts[i + 1]!;
    const p3 = pts[Math.min(pts.length - 1, i + 2)]!;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += `C${c1[0]},${c1[1]} ${c2[0]},${c2[1]} ${p2[0]},${p2[1]}`;
  }
  const [hx, hy] = pts[highlight]!;
  const tipW = Math.max(40, tooltip.length * 6.6 + 16);
  const gid = `g${ariaLabel.replace(/\W/g, "")}`;
  return (
    <svg className="cx-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={ariaLabel}>
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#2e335b" stopOpacity="0.45" />
          <stop offset="1" stopColor="#2e335b" stopOpacity="0" />
        </linearGradient>
      </defs>
      {ticks.map((t) => (
        <g key={t}>
          <line x1={left} x2={right} y1={y(t)} y2={y(t)} stroke="#e4e4e8" />
          <text x={0} y={y(t) + 4} fontSize="10.5" fill="#bbbcc6">
            {tickLabel(t)}
          </text>
        </g>
      ))}
      <rect x={hx - 5} y={hy} width={10} height={bottom - hy} fill={`url(#${gid})`} />
      <path d={d} fill="none" stroke="#2e335b" strokeWidth="2.2" strokeLinecap="round" />
      <circle cx={hx} cy={hy} r="4.5" fill="#fff" stroke="#2e335b" strokeWidth="2.2" />
      <g transform={`translate(${Math.min(Math.max(hx - tipW / 2, left), right - tipW)} ${hy - 34})`}>
        <rect width={tipW} height="22" rx="5" fill="#2e335b" />
        <path d={`M${hx - Math.min(Math.max(hx - tipW / 2, left), right - tipW) - 5} 22 l5 5 l5 -5z`} fill="#2e335b" />
        <text x={tipW / 2} y="15" fontSize="11" fontWeight="600" fill="#fff" textAnchor="middle">
          {tooltip}
        </text>
      </g>
      {labels.map((l, i) => (
        <text key={l + i} x={x(i)} y={H - 18} fontSize="11.5" textAnchor="middle" fill={i === highlight ? "#2e335b" : "#bbbcc6"}>
          {l}
        </text>
      ))}
    </svg>
  );
}
