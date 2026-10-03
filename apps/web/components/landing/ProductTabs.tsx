"use client";

import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { tabs } from "./content";

/** Webflow tab timings for this block: 100ms out, 500ms in, "ease-out-expo". */
const OUT_MS = 100;
const IN_MS = 500;
const EASING = "cubic-bezier(0.190, 1.000, 0.220, 1.000)";

const tabId = (i: number) => `w-tabs-0-data-w-tab-${i}`;
const paneId = (i: number) => `w-tabs-0-data-w-pane-${i}`;

export function ProductTabs() {
  const [current, setCurrent] = useState(0);
  const [shown, setShown] = useState(0);
  const [fade, setFade] = useState<{ opacity: number; transition?: string }>({ opacity: 1 });
  const timers = useRef<number[]>([]);
  const links = useRef<(HTMLAnchorElement | null)[]>([]);

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  const select = (i: number) => {
    if (i === current) return;
    timers.current.forEach(clearTimeout);
    setCurrent(i);
    links.current[i]?.focus({ preventScroll: true });
    // Fade the open pane out, swap, then fade the new one in.
    setFade({ opacity: 0, transition: `opacity ${OUT_MS}ms ${EASING}` });
    timers.current = [
      window.setTimeout(() => {
        setShown(i);
        setFade({ opacity: 0 });
        timers.current.push(
          window.setTimeout(() => setFade({ opacity: 1, transition: `opacity ${IN_MS}ms ${EASING}` }), 20),
        );
      }, OUT_MS),
    ];
  };

  const onKeyDown = (e: KeyboardEvent) => {
    const last = tabs.length - 1;
    const next: Record<string, number> = {
      ArrowLeft: current - 1,
      ArrowUp: current - 1,
      ArrowRight: current + 1,
      ArrowDown: current + 1,
      Home: 0,
      End: last,
    };
    const to = next[e.key];
    if (to === undefined) return;
    e.preventDefault();
    select(to < 0 ? last : to > last ? 0 : to);
  };

  return (
    <div className="tabs w-tabs">
      <div className="tabs-menu w-tab-menu" role="tablist" onKeyDown={onKeyDown}>
        {tabs.map((t, i) => (
          <a
            key={t.label}
            ref={(el) => {
              links.current[i] = el;
            }}
            id={tabId(i)}
            href={`#${paneId(i)}`}
            role="tab"
            aria-controls={paneId(i)}
            aria-selected={i === current}
            tabIndex={i === current ? undefined : -1}
            className={`tab-link w-inline-block w-tab-link${i === current ? " w--current" : ""}`}
            onClick={(e) => {
              e.preventDefault();
              select(i);
            }}
          >
            <div>{t.label}</div>
          </a>
        ))}
      </div>
      <div className="tab-content-holder w-tab-content">
        {tabs.map((t, i) => (
          <div
            key={t.label}
            id={paneId(i)}
            role="tabpanel"
            aria-labelledby={tabId(i)}
            className={`tab-pane-holder w-tab-pane${i === shown ? " w--tab-active" : ""}`}
            style={i === shown ? fade : undefined}
          >
            <div className="tab-pane">
              <img loading="eager" src={t.image} alt="" className="tab-pane-image" />
              <div className="paragraph-holder">
                <p>{t.body}</p>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
