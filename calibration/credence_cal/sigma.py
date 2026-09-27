"""Step 3: σ methodology, the reference implementation of `calibration/docs/sigma.md` (§10.6 step 3).

The keeper (J7) must reproduce this bit for bit; `sigma.md` is normative and this module is its
executable form. All arithmetic is IEEE-754 binary64 in the exact order written here.

Per asset, three EWMA variances are kept, one per closure type t ∈ {1 OVERNIGHT, 2 WEEKEND,
3 HOLIDAY_WEEKEND}. Each is updated only by gaps of its own type:

    v_t ← LAM * v_t + (1.0 - LAM) * (r * r)            LAM = 0.94

Published scale (before the floor):

    σ_1 = sqrt(v_1)
    σ_t = sqrt(W * v_t + ((1.0 - W) * rho2_t) * v_1)   for t = 2, 3;  W = 0.5

rho2_t is the long-run ratio mean(r_t²) / mean(r_1²) of the asset's own history. The keeper reads it
as a constant from the proposal; the historical replay that builds the z-sets uses its expanding value
(only past gaps), so no z ever sees the future.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

LAM = 0.94
W = 0.5
SEED = {1: 20, 2: 10, 3: 10}  # v_t starts as the mean r² of the first SEED[t] gaps of type t
WARM_N1 = 60  # a z (or a published σ) needs ≥ 60 overnight gaps and ≥ SEED[t] gaps of type t
NANO = 10**9


def to_wad(x: float) -> int:
    """σ as WAD, rounded to 1e-9 (half away from zero), so float noise never reaches the chain."""
    return int(math.floor(x * 1e9 + 0.5)) * NANO


@dataclass
class State:
    """Per-asset σ state. `v[t]` is None until type t is seeded."""

    v: dict[int, float | None] = field(default_factory=lambda: {1: None, 2: None, 3: None})
    n: dict[int, int] = field(default_factory=lambda: {1: 0, 2: 0, 3: 0})
    sumsq: dict[int, float] = field(default_factory=lambda: {1: 0.0, 2: 0.0, 3: 0.0})
    seed: dict[int, list[float]] = field(default_factory=lambda: {1: [], 2: [], 3: []})

    def warm(self, t: int) -> bool:
        return self.v[1] is not None and self.v[t] is not None and self.n[1] >= WARM_N1 and self.n[t] >= SEED[t]

    def rho2(self, t: int) -> float:
        return (self.sumsq[t] / self.n[t]) / (self.sumsq[1] / self.n[1])

    def sigma(self, t: int, rho2: float | None = None, w: float = W) -> float:
        v1 = self.v[1]
        if t == 1:
            return math.sqrt(v1)
        r2 = self.rho2(t) if rho2 is None else rho2
        return math.sqrt(w * self.v[t] + ((1.0 - w) * r2) * v1)

    def update(self, t: int, r: float) -> None:
        rr = r * r
        if self.v[t] is None:
            self.seed[t].append(rr)
            if len(self.seed[t]) == SEED[t]:
                s = 0.0
                for x in self.seed[t]:
                    s = s + x
                self.v[t] = s / SEED[t]
        else:
            self.v[t] = LAM * self.v[t] + (1.0 - LAM) * rr
        self.n[t] += 1
        self.sumsq[t] += rr


def replay(g: pd.DataFrame) -> tuple[pd.DataFrame, State, list[dict]]:
    """Walk one asset's gaps in date order. Returns the gaps with the ex-ante σ of their own type and
    z = r / σ (NaN while cold), the final state, and the daily series of published σ per type (the
    value that would have been in force for the next closure of each type, used for the floors)."""
    st = State()
    sig, zs, daily = [], [], []
    for date, t, r in zip(g["date"], g["type"], g["r"]):
        t = int(t)
        if st.warm(t):
            s = st.sigma(t)
            sig.append(s)
            zs.append(r / s)
        else:
            sig.append(np.nan)
            zs.append(np.nan)
        st.update(t, float(r))
        if all(st.warm(k) for k in (1, 2, 3)):
            daily.append({"date": date, **{k: st.sigma(k) for k in (1, 2, 3)}})
    out = g.copy()
    out["sigma"] = sig
    out["z"] = zs
    return out, st, daily


def floors(daily: list[dict], q: float = 0.25) -> dict[int, float]:
    """Long-run 25th percentile of the published σ per closure type (§10.6 step 6). numpy's default
    'linear' interpolation between order statistics."""
    return {t: float(np.quantile(np.array([d[t] for d in daily]), q)) for t in (1, 2, 3)}


def snapshot(st: State, as_of: str) -> dict:
    """The state the keeper resumes from. Floats are written with repr (round-trip exact)."""
    return {
        "asOf": as_of,
        "v": {str(t): repr(st.v[t]) for t in (1, 2, 3)},
        "n": {str(t): st.n[t] for t in (1, 2, 3)},
        "rho2": {str(t): repr(st.rho2(t)) for t in (2, 3)},
    }


def keeper_step(v: dict[int, float], rho2: dict[int, float], gaps: list[tuple[int, float]]) -> tuple[dict[int, float], dict[int, float]]:
    """Keeper mode (J7): constant rho2, state already seeded. Applies each (type, r) in order and returns
    the new state and the unfloored σ per type after the last gap."""
    v = dict(v)
    for t, r in gaps:
        v[t] = LAM * v[t] + (1.0 - LAM) * (r * r)
    sig = {1: math.sqrt(v[1])}
    for t in (2, 3):
        sig[t] = math.sqrt(W * v[t] + ((1.0 - W) * rho2[t]) * v[1])
    return v, sig


BLEND_GRID = (0.0, 0.25, 0.5, 0.75, 1.0)


def evaluate(groups: list[pd.DataFrame]) -> dict:
    """Out-of-sample comparison of blend weights (ADR-0202). For every warm gap, the ex-ante variance
    s² under each weight w is scored with QLIKE = r²/s² + ln s² (lower is better; robust to noisy r²
    proxies, Patton 2011). Also reports sd(z) and the share of |z| > 4 per weight."""
    acc: dict[tuple[int, float], list[tuple[float, float]]] = {}
    for g in groups:
        st = State()
        for t, r in zip(g["type"], g["r"]):
            t, r = int(t), float(r)
            if all(st.warm(k) for k in (1, 2, 3)):
                ws = BLEND_GRID if t != 1 else (1.0,)
                for w in ws:
                    s = st.sigma(t, w=w)
                    acc.setdefault((t, w), []).append((r * r / (s * s) + 2.0 * math.log(s), r / s))
            st.update(t, r)
    out: dict[str, dict] = {}
    for (t, w), xs in sorted(acc.items()):
        a = np.array(xs)
        out.setdefault(str(t), {})[repr(w)] = {
            "n": int(len(a)), "qlike": round(float(a[:, 0].mean()), 5), "sdZ": round(float(a[:, 1].std()), 4),
            "shareAbsZ>4": round(float(np.mean(np.abs(a[:, 1]) > 4)), 5)}
    return out
