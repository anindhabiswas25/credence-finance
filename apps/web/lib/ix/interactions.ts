/**
 * The landing page's interactions, transcribed from the template's IX2 export. The comments name
 * the original event and action-list ids so each block can be checked against the source.
 *
 * `html.ix` (set in the root layout before first paint) hides elements in their IX2 initial
 * state, so nothing flashes before this runs. Without it (no JS, or reduced motion) the page
 * renders fully visible and static.
 */
import {
  Engine,
  easings,
  inViewProgress,
  pageProgress,
  type Keyframe,
  type Props,
  type Track,
} from "./engine";

/** IX2's "main" breakpoint; below it the "medium/small/tiny" variants run. */
const DESKTOP = "(min-width: 992px)";

const all = (sel: string, root: ParentNode = document) =>
  Array.from(root.querySelectorAll<HTMLElement>(sel));

const kf = (at: number, ...value: number[]): Keyframe<number[]> => ({ at, value });
const rgba = ([r, g, b, a]: number[]) => `rgba(${r}, ${g}, ${b}, ${a})`;

/** a: "Fade In On Scroll", with the scroll offset (percent of the viewport) of each event. */
const FADE_IN_ON_SCROLL: [selector: string, offset: number][] = [
  [".fade-in-on-scroll", 0], // e
  [".paragraph-holder", 0], // e-16
  [".title-holder", 0], // e-122
  [".tag", 10], // e-132
  [".line", 10], // e-384
  [".cta-dashboard-holder", 15], // e-347
];

/** Webflow's slide-in presets, used through `data-ix="slideInBottom"` and friends. */
const PRESETS: Record<string, Props> = {
  slideInBottom: { y: 100 },
  slideInLeft: { x: -100 },
  slideInRight: { x: 100 },
};

function onceInView(els: HTMLElement[], offset: number, run: (el: HTMLElement) => void) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        // IX2 tests rectangles, so a hidden element (an empty rect at 0,0) counts as in view
        // when the offset is 0; that is how the inactive tab panes' copy is already revealed.
        const { width, height, top } = e.boundingClientRect;
        const hiddenInView = offset === 0 && width === 0 && height === 0 && top === 0;
        if (!e.isIntersecting && !hiddenInView) continue;
        io.unobserve(e.target);
        run(e.target as HTMLElement);
      }
    },
    { rootMargin: `-${offset}% 0px -${offset}% 0px` },
  );
  els.forEach((el) => io.observe(el));
  return () => io.disconnect();
}

/** a-2 "Animate On Load" (e-3, page start). */
function animateOnLoad(ix: Engine) {
  const outExpo = { duration: 1200, easing: easings.outExpo };
  [1, 2, 3, 4].forEach((n, i) => {
    for (const el of all(`.animate-on-load-0${n}`)) {
      ix.set(el, { y: 45, scale: 0.96, opacity: 0 });
      ix.to(el, { y: 0, scale: 1, opacity: 1 }, { ...outExpo, delay: 300 + i * 100 });
    }
  });
  for (const el of all(".navbar")) {
    ix.set(el, { opacity: 0 });
    ix.to(el, { opacity: 1 }, { duration: 1200, delay: 600, easing: easings.ease });
  }
  for (const el of all(".home-content-wrapper")) {
    ix.set(el, { y: 120 });
    ix.to(el, { y: 0 }, { duration: 2000, delay: 300, easing: easings.outExpo });
  }
}

function scrollIntoView(ix: Engine): Array<() => void> {
  const stops = FADE_IN_ON_SCROLL.map(([selector, offset]) => {
    const els = all(selector);
    els.forEach((el) => ix.set(el, { y: 45, opacity: 0 }));
    return onceInView(els, offset, (el) =>
      ix.to(el, { y: 0, opacity: 1 }, { duration: 1200, delay: 300, easing: easings.outExpo }),
    );
  });

  // Preset slide effects (e-349..e-400): 10% offset, per-element delay, 1s outQuart.
  const presetEls = all("[data-ix]");
  presetEls.forEach((el) => ix.set(el, { opacity: 0 }));
  stops.push(
    onceInView(presetEls, 10, (el) => {
      const from = PRESETS[el.dataset.ix ?? ""] ?? {};
      ix.set(el, from);
      ix.to(
        el,
        { x: 0, y: 0, opacity: 1 },
        { duration: 1000, delay: Number(el.dataset.ixDelay ?? 0), easing: easings.outQuart },
      );
    }),
  );
  return stops;
}

/**
 * a-3 "Hero Animation -> While Scrolling" (e-382, desktop) and a-65, its mobile variant (e-432):
 * the dashboard tilts away while the second hero block slides in. Both run on the children of
 * the hero `.wrapper`, which is scrolled through its own height (starts entering: off).
 */
function heroScroll(ix: Engine, desktop: boolean) {
  const wrapper = document.querySelector<HTMLElement>(".wrapper");
  if (!wrapper) return { stop: () => {}, els: [] as HTMLElement[] };
  const tracks: Track[] = [];
  const els: HTMLElement[] = [];
  const each = (sel: string, make: (el: HTMLElement) => Track[]) => {
    for (const el of all(sel, wrapper)) {
      els.push(el);
      tracks.push(...make(el));
    }
  };

  each(".dashobard-wrapper", (el) => [
    ix.transformTrack(
      el,
      ["x", "y"],
      desktop
        ? [kf(9, 0, 0), kf(23, 150, 210), kf(42, 500, 820), kf(100, 500, 1220)]
        : [kf(9, 0, 0), kf(23, 0, 290), kf(42, 0, 350), kf(100, 0, 900)],
    ),
    // Keyframe 23 lists scale 1 before 0.9; IX2 samples the first item, so scale stays 1.
    ix.transformTrack(el, ["scale"], [kf(9, 1), kf(23, 1)]),
    ix.transformTrack(el, ["rotateY"], [kf(23, 0), kf(42, -28), kf(100, -45)]),
  ]);
  each(".content-holder", (el) => [ix.transformTrack(el, ["y"], [kf(9, 0), kf(23, 200)])]);
  const opacity = (el: HTMLElement, frames: Keyframe<number[]>[]) =>
    ix.styleTrack(() => [el], "opacity", frames, ([v]) => String(v));
  each(".blue-blur", (el) => [opacity(el, [kf(23, 0), kf(42, 0.2)])]);
  each(".feature-grid-content-holder-2", (el) =>
    desktop
      ? [
          opacity(el, [kf(23, 0), kf(45, 1), kf(100, 1)]),
          ix.transformTrack(el, ["x", "y"], [kf(23, -260, 0), kf(45, 0, 0), kf(100, 0, 380)]),
        ]
      : [
          opacity(el, [kf(9, 0), kf(23, 1), kf(100, 1)]),
          ix.transformTrack(el, ["x", "y"], [kf(9, -260, 0), kf(23, 0, 0), kf(100, 0, 380)]),
        ],
  );

  const stop = ix.continuous(() => inViewProgress(wrapper, false), desktop ? 94 : 93, tracks);
  return { stop, els };
}

/**
 * a-61 "Transparent Navbar -> Solid Navbar" (e-383, desktop) and a-66 (e-433, mobile): over the
 * sky the bar is clear with a white logo; at 4% of the page it turns solid.
 */
function navbarScroll(ix: Engine, desktop: boolean) {
  const navbar = () => all(".navbar");
  const brand = () => all(".brand-image");
  const text = () => all(desktop ? ".nav-link" : ".menu-button");
  const light = [245, 244, 253, 1];
  const ink = [46, 51, 91, 1];
  const tracks = [
    ix.styleTrack(
      navbar,
      "background-color",
      [kf(0, 255, 255, 255, 0.05), kf(3, 255, 255, 255, 0.05), kf(4, ...light)],
      rgba,
    ),
    ix.styleTrack(
      navbar,
      "border-color",
      [kf(0, 255, 255, 255, 0.08), kf(3, 255, 255, 255, 0.08), kf(4, 46, 51, 91, 0.4)],
      rgba,
    ),
    ix.styleTrack(brand, "filter", [kf(0, 100), kf(3, 100), kf(4, 0)], ([v]) => `invert(${v}%)`),
    ix.styleTrack(text, "color", [kf(0, ...light), kf(3, ...light), kf(4, ...ink)], rgba),
  ];
  const stop = ix.continuous(pageProgress, 93, tracks);
  const clear = () => {
    for (const el of navbar()) {
      el.style.removeProperty("background-color");
      el.style.removeProperty("border-color");
    }
    brand().forEach((el) => el.style.removeProperty("filter"));
    text().forEach((el) => el.style.removeProperty("color"));
  };
  return { stop, clear };
}

/** a-58 "Apple Watch Animation While Scrolling" (e-436, all breakpoints). */
function watchScroll(ix: Engine) {
  const section = document.querySelector<HTMLElement>(".section.apple-watch-section");
  if (!section) return () => {};
  const tracks = [
    ...all(".hand-holder", section).map((el) =>
      ix.transformTrack(el, ["y"], [kf(0, -100), kf(55, 0)]),
    ),
    ...all(".center-hand-text", section).map((el) =>
      ix.transformTrack(el, ["y"], [kf(0, 140), kf(55, 0)]),
    ),
  ];
  return ix.continuous(() => inViewProgress(section, true), 93, tracks);
}

export function startInteractions(): () => void {
  const ix = new Engine();
  const stops: Array<() => void> = [];

  animateOnLoad(ix);
  stops.push(...scrollIntoView(ix));
  stops.push(watchScroll(ix));

  // Breakpoint-specific continuous interactions. IX2 tears them down and clears their inline
  // styles when the breakpoint changes, then starts the other variant.
  const mq = window.matchMedia(DESKTOP);
  let current: { stop: () => void } | null = null;
  const startBreakpoint = () => {
    current?.stop();
    const hero = heroScroll(ix, mq.matches);
    const nav = navbarScroll(ix, mq.matches);
    current = {
      stop: () => {
        hero.stop();
        nav.stop();
        ix.reset(hero.els, ["opacity"]);
        nav.clear();
      },
    };
  };
  startBreakpoint();
  mq.addEventListener("change", startBreakpoint);

  window.addEventListener("scroll", ix.kick, { passive: true });
  window.addEventListener("resize", ix.kick);

  return () => {
    mq.removeEventListener("change", startBreakpoint);
    window.removeEventListener("scroll", ix.kick);
    window.removeEventListener("resize", ix.kick);
    current?.stop();
    stops.forEach((s) => s());
    ix.destroy();
  };
}
