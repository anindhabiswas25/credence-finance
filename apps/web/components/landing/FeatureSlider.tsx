"use client";

import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { asset, type Slide } from "./content";

const DURATION = 1250;
/** Webflow's "ease-out-expo". */
const EASING = "cubic-bezier(0.190, 1.000, 0.220, 1.000)";
const SWIPE_PX = 40;

/**
 * Webflow's page math: slides are grouped into pages the width of the mask, and each page is
 * scrolled to by its x offset. With this template's CSS every slide is one page.
 */
function computePages(mask: HTMLElement): { x: number; slides: number[] }[] {
  const maskWidth = mask.clientWidth;
  const pages = [{ x: 0, slides: [] as number[] }];
  let pageStart = 0;
  let x = 0;
  Array.from(mask.children).forEach((child, i) => {
    const el = child as HTMLElement;
    if (!el.classList.contains("w-slide")) return;
    if (x - pageStart > maskWidth) {
      pageStart += maskWidth;
      pages.push({ x, slides: [] });
    }
    const cs = getComputedStyle(el);
    x += el.offsetWidth + parseFloat(cs.marginLeft) + parseFloat(cs.marginRight);
    pages[pages.length - 1]!.slides.push(i);
  });
  return pages;
}

export function FeatureSlider({ slides }: { slides: Slide[] }) {
  const maskRef = useRef<HTMLDivElement>(null);
  const [pages, setPages] = useState(() => slides.map((_, i) => ({ x: 0, slides: [i] })));
  const [index, setIndex] = useState(0);
  const [animate, setAnimate] = useState(false);
  const pointer = useRef<{ x: number; y: number } | null>(null);

  // Re-measure when the mask resizes; like Webflow, jump there without animating.
  useLayoutEffect(() => {
    const mask = maskRef.current;
    if (!mask) return;
    const measure = () => {
      const next = computePages(mask);
      setAnimate(false);
      setPages(next);
      setIndex((i) => Math.min(i, next.length - 1));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(mask);
    return () => ro.disconnect();
  }, []);

  // Webflow wraps around at either end even when the slider is not infinite.
  const go = (to: number) => {
    const n = to < 0 ? pages.length - 1 : to >= pages.length ? 0 : to;
    setAnimate(true);
    setIndex(n);
  };

  const [live, setLive] = useState("");
  useEffect(() => {
    if (animate) setLive(`Slide ${index + 1} of ${pages.length}.`);
  }, [index, animate, pages.length]);

  const active = new Set(pages[index]?.slides ?? []);
  const offset = -(pages[index]?.x ?? 0);

  const arrowKeys = (dir: -1 | 1) => (e: KeyboardEvent) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      go(index + dir);
    }
  };
  const onPointerDown = (e: PointerEvent) => {
    pointer.current = { x: e.clientX, y: e.clientY };
  };
  const onPointerUp = (e: PointerEvent) => {
    const start = pointer.current;
    pointer.current = null;
    if (!start) return;
    const dx = e.clientX - start.x;
    if (Math.abs(dx) > SWIPE_PX && Math.abs(dx) > Math.abs(e.clientY - start.y)) go(index + (dx < 0 ? 1 : -1));
  };

  return (
    <div
      className="slider w-slider"
      role="region"
      aria-label="carousel"
      onPointerDown={onPointerDown}
      onPointerUp={onPointerUp}
      onPointerCancel={() => (pointer.current = null)}
    >
      <div className="slider-mask w-slider-mask" id="w-slider-mask-0" ref={maskRef}>
        {slides.map((s, i) => (
          <div
            key={i}
            className={`slide w-slide${active.has(i) ? " is-active" : ""}`}
            role="group"
            aria-label={`${i + 1} of ${slides.length}`}
            aria-hidden={active.has(i) ? undefined : true}
            style={{
              transform: `translateX(${offset}px)`,
              transition: animate ? `transform ${DURATION}ms ${EASING}` : undefined,
            }}
          >
            <div className={`slider-wrapper${s.light ? " light" : ""}`}>
              <div className="slider-content">
                <div className="slider-title-holder">
                  <img src={s.icon} loading="lazy" alt="" className="slider-icon" />
                  <h5 className={s.light ? undefined : "white-text"}>{s.title}</h5>
                </div>
                <p className={s.light ? undefined : "white-paragraph"}>{s.body}</p>
              </div>
              {s.image && (
                <img
                  src={s.image.src}
                  srcSet={s.image.srcSet}
                  sizes={s.image.sizes}
                  loading="lazy"
                  alt=""
                  className="slider-image"
                />
              )}
            </div>
          </div>
        ))}
        <div aria-live="off" aria-atomic="true" className="w-slider-aria-label">
          {live}
        </div>
      </div>
      <div
        className="arrow-holder w-slider-arrow-left"
        role="button"
        tabIndex={0}
        aria-controls="w-slider-mask-0"
        aria-label="previous slide"
        onClick={() => go(index - 1)}
        onKeyDown={arrowKeys(-1)}
      >
        <div className="arrow-icon-holder">
          <img src={asset.arrowLeft} loading="lazy" alt="" className="arrow-icon" />
        </div>
      </div>
      <div
        className="arrow-holder right w-slider-arrow-right"
        role="button"
        tabIndex={0}
        aria-controls="w-slider-mask-0"
        aria-label="next slide"
        onClick={() => go(index + 1)}
        onKeyDown={arrowKeys(1)}
      >
        <div className="arrow-icon-holder">
          <img src={asset.arrowRight} loading="lazy" alt="" className="arrow-icon" />
        </div>
      </div>
      <div className="hide w-slider-nav w-round w-num" />
    </div>
  );
}
