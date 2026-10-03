"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { asset, navCta, navLinks } from "./content";

/** Webflow collapses this navbar at its "medium" breakpoint. */
const COLLAPSED = "(max-width: 991px)";
const DURATION = 400;

type Phase = "closed" | "opening" | "open" | "closing";

function Menu({ open, onNavigate }: { open: boolean; onNavigate?: () => void }) {
  const linkClass = `nav-link w-nav-link${open ? " w--nav-link-open" : ""}`;
  return (
    <nav
      role="navigation"
      className="nav-menu w-nav-menu"
      {...(open ? { "data-nav-menu-open": "" } : {})}
    >
      <div className="nav-menu-link-holder">
        <div className="nav-menu-link-container">
          <div className="nav-links">
            {navLinks.map((l) => (
              <a key={l.label} href={l.href} className={linkClass} onClick={onNavigate}>
                {l.label}
              </a>
            ))}
          </div>
        </div>
        <div className="nav-button-holder">
          <a
            href={navCta.href}
            {...(navCta.href.startsWith("http") ? { target: "_blank", rel: "noopener noreferrer" } : {})}
            className="button w-button"
          >
            {navCta.label}
          </a>
        </div>
      </div>
    </nav>
  );
}

/**
 * Webflow's `w-nav`: on small screens the menu moves into an overlay under the bar and slides
 * down from behind it (transform, 400ms ease), and slides back up to close.
 */
export function Navbar() {
  const [phase, setPhase] = useState<Phase>("closed");
  const barRef = useRef<HTMLDivElement>(null);
  const overlayRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLDivElement>(null);
  const shown = phase !== "closed";

  const menuEl = () => overlayRef.current?.querySelector<HTMLElement>(".w-nav-menu") ?? null;
  const hiddenOffset = (menu: HTMLElement) =>
    -((barRef.current?.offsetHeight ?? 0) + menu.offsetHeight);

  const close = useCallback(() => setPhase((p) => (p === "closed" ? p : "closing")), []);
  const toggle = () => setPhase((p) => (p === "open" || p === "opening" ? "closing" : "opening"));

  // Drive the slide. The overlay spans the viewport below the bar, as Webflow sizes it.
  useLayoutEffect(() => {
    const menu = menuEl();
    const overlay = overlayRef.current;
    if (!menu || !overlay) return;
    if (phase === "opening") {
      overlay.style.height = `${window.innerHeight - (barRef.current?.offsetHeight ?? 0)}px`;
      menu.style.transition = "none";
      menu.style.transform = `translateY(${hiddenOffset(menu)}px)`;
      void menu.offsetHeight;
      menu.style.transition = `transform ${DURATION}ms ease`;
      menu.style.transform = "translateY(0px)";
      const t = window.setTimeout(() => setPhase("open"), DURATION);
      return () => window.clearTimeout(t);
    }
    if (phase === "closing") {
      menu.style.transition = `transform ${DURATION}ms ease`;
      menu.style.transform = `translateY(${hiddenOffset(menu)}px)`;
      const t = window.setTimeout(() => setPhase("closed"), DURATION);
      return () => window.clearTimeout(t);
    }
  }, [phase]);

  // Close on a click outside the menu and button, on Escape, and when the bar un-collapses.
  useEffect(() => {
    if (!shown) return;
    const onClick = (e: MouseEvent) => {
      const t = e.target as Node;
      if (overlayRef.current?.contains(t) || buttonRef.current?.contains(t)) return;
      close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        close();
        buttonRef.current?.focus();
      }
    };
    const mq = window.matchMedia(COLLAPSED);
    const onBreakpoint = () => !mq.matches && setPhase("closed");
    document.addEventListener("click", onClick);
    document.addEventListener("keydown", onKey);
    mq.addEventListener("change", onBreakpoint);
    return () => {
      document.removeEventListener("click", onClick);
      document.removeEventListener("keydown", onKey);
      mq.removeEventListener("change", onBreakpoint);
    };
  }, [shown, close]);

  return (
    <div className="fixed-nav">
      <div ref={barRef} role="banner" className="navbar w-nav" data-collapse="medium" data-animation="default">
        <div className="container navbar-container">
          <div className="navbar-holder">
            <div className="navbar-container">
              <a href="/" aria-current="page" aria-label="home" className="brand w-nav-brand w--current">
                <img src={asset.logo} alt="Credence" className="brand-image" />
              </a>
              {!shown && <Menu open={false} />}
              <div
                ref={buttonRef}
                className={`menu-button w-nav-button${phase === "open" || phase === "opening" ? " w--open" : ""}`}
                role="button"
                tabIndex={0}
                aria-label="menu"
                aria-haspopup="menu"
                aria-controls="w-nav-overlay-0"
                aria-expanded={phase === "open" || phase === "opening"}
                style={{ WebkitUserSelect: "text" }}
                onClick={toggle}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    toggle();
                  }
                }}
              >
                <div className="icon w-icon-nav-menu" />
              </div>
            </div>
          </div>
        </div>
        <div
          ref={overlayRef}
          className="w-nav-overlay"
          id="w-nav-overlay-0"
          data-wf-ignore=""
          style={{ display: shown ? "block" : "none" }}
        >
          {shown && <Menu open onNavigate={close} />}
        </div>
      </div>
    </div>
  );
}
