import type { ReactNode } from "react";

/** Line icons in the dashboard's style: 24-unit grid, round caps, drawn in currentColor. */
const PATHS: Record<string, ReactNode> = {
  house: (
    <>
      <path d="M4 10.5L12 4l8 6.5V20H4z" fill="currentColor" fillOpacity={0.22} />
      <path d="M9.5 20v-5.5h5V20" />
    </>
  ),
  "house-line": (
    <>
      <path d="M4 10.5L12 4l8 6.5V20H4z" />
      <path d="M9.5 20v-5.5h5V20" />
    </>
  ),
  markets: (
    <>
      <path d="M3 3v18h18" />
      <path d="M7 15l4-5 3 3 6-7" />
    </>
  ),
  card: (
    <>
      <rect x="3" y="5" width="18" height="14" rx="2.5" />
      <path d="M3 9.5h5.5a3.5 3.5 0 0 0 7 0H21" />
    </>
  ),
  vault: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <circle cx="12" cy="12" r="3.5" />
      <path d="M12 8.5v1.2M12 14.3v1.2M8.5 12h1.2M14.3 12h1.2M6 20v1.5M18 20v1.5" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z" />
      <path d="M8.5 12l2.5 2.5 4.5-5" />
    </>
  ),
  "shield-plain": <path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z" />,
  gavel: (
    <>
      <path d="M13.5 4.5l6 6" />
      <path d="M11 7l6 6" />
      <path d="M12.2 5.8l-4.4 4.4 6 6 4.4-4.4" />
      <path d="M10.5 13.5L4 20" />
      <path d="M13 21h8" />
    </>
  ),
  pie: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 3v9l6.4 6.4" />
      <path d="M12 12L3.4 9.4" />
    </>
  ),
  mail: (
    <>
      <rect x="2.5" y="5" width="19" height="14" rx="1.5" />
      <path d="M3 6l9 7.5L21 6" />
      <path d="M3 18.5l6.5-6.5M21 18.5L14.5 12" />
    </>
  ),
  user: (
    <>
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="10" r="3" />
      <path d="M6.5 18.5c1.4-2 3.3-3 5.5-3s4.1 1 5.5 3" />
    </>
  ),
  settings: (
    <>
      <path d="M12 2.8l8 4.6v9.2l-8 4.6-8-4.6V7.4z" />
      <circle cx="12" cy="12" r="3" />
    </>
  ),
  search: (
    <>
      <circle cx="11" cy="11" r="6.5" />
      <path d="M16 16l4.5 4.5" />
    </>
  ),
  bell: (
    <>
      <path d="M6 17V11a6 6 0 0 1 12 0v6l1.5 1.5h-15z" />
      <path d="M10 20.5a2 2 0 0 0 4 0" />
    </>
  ),
  repay: (
    <>
      <path d="M12 19V7" />
      <path d="M7 11l5-5 5 5" />
      <path d="M4 21h16" />
    </>
  ),
  deposit: (
    <>
      <path d="M12 3v12" />
      <path d="M7 10l5 5 5-5" />
      <path d="M4 21h16" />
    </>
  ),
  withdraw: (
    <>
      <path d="M12 15V3" />
      <path d="M7 8l5-5 5 5" />
      <path d="M4 21h16" />
    </>
  ),
  cash: (
    <>
      <rect x="2.5" y="6" width="19" height="12" rx="2" />
      <circle cx="12" cy="12" r="3" />
    </>
  ),
  percent: (
    <>
      <path d="M19 5L5 19" />
      <circle cx="6.5" cy="6.5" r="2.5" />
      <circle cx="17.5" cy="17.5" r="2.5" />
    </>
  ),
  plus: <path d="M12 5v14M5 12h14" />,
  clock: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </>
  ),
  alert: (
    <>
      <path d="M12 3.5l9.5 16.5h-19z" />
      <path d="M12 10v4.5M12 17.2v.3" />
    </>
  ),
  lock: (
    <>
      <rect x="5" y="10.5" width="14" height="10" rx="2" />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
    </>
  ),
  dots: (
    <>
      <circle cx="5" cy="12" r="1.3" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none" />
      <circle cx="19" cy="12" r="1.3" fill="currentColor" stroke="none" />
    </>
  ),
  chevron: <path d="M6 9l6 6 6-6" />,
  close: <path d="M6 6l12 12M18 6L6 18" />,
  menu: <path d="M4 7h16M4 12h16M4 17h16" />,
  external: (
    <>
      <path d="M14 4h6v6" />
      <path d="M20 4l-9 9" />
      <path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" />
    </>
  ),
};

export type IconName = keyof typeof PATHS;

export function Icon({
  name,
  size = 22,
  strokeWidth = 1.7,
  className,
}: {
  name: string;
  size?: number;
  strokeWidth?: number;
  className?: string;
}) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {PATHS[name] ?? PATHS.dots}
    </svg>
  );
}
