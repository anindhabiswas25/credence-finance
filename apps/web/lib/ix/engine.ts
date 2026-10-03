/**
 * A small re-implementation of the parts of Webflow's IX2 runtime that the landing page uses.
 * The semantics are copied from the template's published runtime so the motion matches it:
 *
 * - Timed actions tween from the element's current value, after a delay, with an easing.
 * - Continuous (scroll-linked) actions sample keyframes linearly at a 0-100 progress. Each frame
 *   the progress moves toward its target by `max(1 - smoothing, 0.01)` of the remaining distance.
 * - Keyframe sampling takes the first action item of a keyframe, holds the first keyframe's value
 *   before it and the last keyframe's value after it.
 * - Transforms render in IX2's order: translate3d, scale3d, rotateX/Y/Z, skew.
 */

export type Easing = (t: number) => number;

function cubicBezier(x1: number, y1: number, x2: number, y2: number): Easing {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const slopeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sampleX(t) - x;
      if (Math.abs(err) < 1e-6) return sampleY(t);
      const d = slopeX(t);
      if (Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    let lo = 0;
    let hi = 1;
    t = x;
    while (hi - lo > 1e-6) {
      if (sampleX(t) < x) lo = t;
      else hi = t;
      t = (lo + hi) / 2;
    }
    return sampleY(t);
  };
}

/** The IX2 easing functions this page uses, with IX2's own formulas. */
export const easings = {
  linear: (t: number) => t,
  ease: cubicBezier(0.25, 0.1, 0.25, 1),
  outExpo: (t: number) => (t === 1 ? 1 : 1 - Math.pow(2, -10 * t)),
  outQuart: (t: number) => -(Math.pow(t - 1, 4) - 1),
} satisfies Record<string, Easing>;

/** Values the engine animates. Translations are in px, rotations in degrees. */
export interface Props {
  x?: number;
  y?: number;
  scale?: number;
  rotateY?: number;
  opacity?: number;
}
type Key = keyof Props;
const KEYS: Key[] = ["x", "y", "scale", "rotateY", "opacity"];

interface ElState {
  x: number;
  y: number;
  scale: number;
  rotateY: number;
  opacity: number | null;
  transform: boolean;
}

interface Tween {
  el: HTMLElement;
  keys: Key[];
  from: Partial<Record<Key, number>>;
  to: Props;
  start: number;
  duration: number;
  easing: Easing;
}

export interface Keyframe<V> {
  at: number;
  value: V;
}

/** One animated property of one element, driven by a scroll progress. */
export interface Track {
  sample(progress: number): void;
}

interface Driver {
  /** Target progress, 0..1. */
  target(): number;
  smoothing: number;
  position: number | null;
  tracks: Track[];
}

/** Returns the keyframe value at `pos` (0-100), interpolating numeric arrays linearly. */
export function sampleKeyframes(frames: Keyframe<number[]>[], pos: number): number[] {
  let from = frames[0]!;
  let to: Keyframe<number[]> | null = null;
  for (let i = 0; i < frames.length; i++) {
    const f = frames[i]!;
    if (pos >= f.at) {
      from = f;
      const next = frames[i + 1];
      to = next && pos !== f.at ? next : null;
    }
  }
  if (!to) return from.value;
  const t = (pos - from.at) / (to.at - from.at);
  return from.value.map((v, i) => v + (to.value[i]! - v) * t);
}

export class Engine {
  private states = new Map<HTMLElement, ElState>();
  private dirty = new Set<HTMLElement>();
  private tweens: Tween[] = [];
  private drivers: Driver[] = [];
  private frame = 0;
  private destroyed = false;

  private state(el: HTMLElement): ElState {
    let s = this.states.get(el);
    if (!s) {
      s = { x: 0, y: 0, scale: 1, rotateY: 0, opacity: null, transform: false };
      this.states.set(el, s);
    }
    return s;
  }

  private read(el: HTMLElement, key: Key): number {
    const s = this.state(el);
    if (key === "opacity") return s.opacity ?? Number(getComputedStyle(el).opacity);
    return s[key];
  }

  private write(el: HTMLElement, key: Key, value: number) {
    const s = this.state(el);
    if (key === "opacity") s.opacity = value;
    else {
      s[key] = value;
      s.transform = true;
    }
    this.dirty.add(el);
  }

  /** Applies values immediately (an IX2 initial state). */
  set(el: HTMLElement, props: Props) {
    for (const k of KEYS) if (props[k] !== undefined) this.write(el, k, props[k]);
    this.cancel(el, KEYS.filter((k) => props[k] !== undefined));
    this.kick();
  }

  /** Tweens to `props`, cancelling any running tween of the same properties on the element. */
  to(el: HTMLElement, props: Props, opts: { duration: number; delay?: number; easing?: Easing }) {
    const keys = KEYS.filter((k) => props[k] !== undefined);
    this.cancel(el, keys);
    const from: Partial<Record<Key, number>> = {};
    for (const k of keys) from[k] = this.read(el, k);
    this.tweens.push({
      el,
      keys,
      from,
      to: props,
      start: performance.now() + (opts.delay ?? 0),
      duration: opts.duration,
      easing: opts.easing ?? easings.linear,
    });
    this.kick();
  }

  private cancel(el: HTMLElement, keys: Key[]) {
    for (const t of this.tweens) {
      if (t.el === el) t.keys = t.keys.filter((k) => !keys.includes(k));
    }
    this.tweens = this.tweens.filter((t) => t.keys.length > 0);
  }

  /** A transform track (px / degrees) on one element. */
  transformTrack(el: HTMLElement, keys: Key[], frames: Keyframe<number[]>[]): Track {
    return {
      sample: (pos) => {
        const v = sampleKeyframes(frames, pos);
        keys.forEach((k, i) => this.write(el, k, v[i]!));
      },
    };
  }

  /**
   * A style track: `format` turns the sampled numbers into a CSS value. Targets are resolved on
   * every sample, so elements React re-mounts (the collapsing nav menu) stay styled.
   */
  styleTrack(
    targets: () => Iterable<HTMLElement>,
    prop: string,
    frames: Keyframe<number[]>[],
    format: (v: number[]) => string,
  ): Track {
    return {
      sample: (pos) => {
        const css = format(sampleKeyframes(frames, pos));
        for (const el of targets()) el.style.setProperty(prop, css);
      },
    };
  }

  /** Registers scroll-linked tracks. Returns a function that removes them. */
  continuous(target: () => number, smoothing: number, tracks: Track[]): () => void {
    const driver: Driver = { target, smoothing: smoothing / 100, position: null, tracks };
    this.drivers.push(driver);
    this.kick();
    return () => {
      this.drivers = this.drivers.filter((d) => d !== driver);
    };
  }

  /** Clears the inline styles the engine wrote (used when a breakpoint swaps interactions). */
  reset(els: Iterable<HTMLElement>, styleProps: string[] = []) {
    for (const el of els) {
      this.states.delete(el);
      this.dirty.delete(el);
      el.style.removeProperty("transform");
      for (const p of styleProps) el.style.removeProperty(p);
    }
  }

  /** Starts the frame loop if it is idle. Scroll and resize listeners call this. */
  kick = () => {
    if (!this.frame && !this.destroyed) this.frame = requestAnimationFrame(this.tick);
  };

  private tick = (now: number) => {
    this.frame = 0;
    let busy = false;

    for (const t of this.tweens) {
      const elapsed = now - t.start;
      if (elapsed < 0) {
        busy = true;
        continue;
      }
      const p = t.duration > 0 ? Math.min(elapsed / t.duration, 1) : 1;
      const e = t.easing(p);
      for (const k of t.keys) this.write(t.el, k, t.from[k]! + (t.to[k]! - t.from[k]!) * e);
      if (p < 1) busy = true;
      else t.keys = [];
    }
    this.tweens = this.tweens.filter((t) => t.keys.length > 0);

    for (const d of this.drivers) {
      const target = Math.max(d.target(), 0) || 0;
      if (d.position === null) d.position = target;
      else {
        const next = d.position + (target - d.position) * Math.max(1 - d.smoothing, 0.01);
        d.position = Math.abs(target - next) < 1e-4 ? target : next;
      }
      if (d.position !== target) busy = true;
      for (const tr of d.tracks) tr.sample(d.position * 100);
    }

    this.flush();
    if (busy) this.kick();
  };

  private flush() {
    for (const el of this.dirty) {
      const s = this.state(el);
      if (s.transform) {
        el.style.transform =
          `translate3d(${s.x}px, ${s.y}px, 0px) scale3d(${s.scale}, ${s.scale}, 1) ` +
          `rotateX(0deg) rotateY(${s.rotateY}deg) rotateZ(0deg) skew(0deg, 0deg)`;
      }
      if (s.opacity !== null) el.style.opacity = String(s.opacity);
    }
    this.dirty.clear();
  }

  destroy() {
    this.destroyed = true;
    cancelAnimationFrame(this.frame);
    this.tweens = [];
    this.drivers = [];
  }
}

/**
 * IX2 "scrolling in view" progress for an element (both "starts entering" variants; this page
 * never uses the start/end offsets).
 */
export function inViewProgress(el: HTMLElement, startsEntering: boolean): number {
  const vh = document.documentElement.clientHeight;
  const rect = el.getBoundingClientRect();
  const startFrac = startsEntering ? 0 : 1;
  const start = rect.top + Math.min(rect.height * startFrac, vh);
  const end = rect.top + rect.height;
  const span = Math.min(vh + (end - start), document.documentElement.scrollHeight);
  return Math.min(Math.max(0, vh - start), span) / span;
}

/** IX2 "page scrolled" progress. */
export function pageProgress(): number {
  const { scrollTop, scrollHeight, clientHeight } = document.documentElement;
  const max = scrollHeight - clientHeight;
  return max > 0 ? scrollTop / max : 0;
}
