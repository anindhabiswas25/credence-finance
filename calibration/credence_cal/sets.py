"""Steps 4 and 5: pooled scenario sets and the joint stress set (§10.6, ADR-0203).

Scenario set for (asset a, closure type t):
  1. Pool the z of type t from every name in a's comparable group (a itself first). Names in
     `COMPARABLE_FROM` contribute only from that date.
  2. If the pool has fewer than N_MIN values (only HOLIDAY_WEEKEND can), add the group's WEEKEND z
     (both are standardised by their own type's σ, so they share one shape; the KS distance is reported).
  3. If it has more than N_MAX values, thin it to exactly N_MAX by midpoint quantiles:
     y_i = x_(floor((2i + 1) · M / (2 · N_MAX))) of the ascending pool x (M values), i = 0 .. N_MAX − 1.
     This keeps the empirical quantile function (and so G_α) of the whole pool.
  4. Quantise to int16 thousandths of σ rounding DOWN (toward −∞, the conservative side for lenders),
     clip to [−32767, 32767], sort ascending.
  5. Tail floor (ADR-0204, the free data starts in 2016): at every position i with plotting position
     p_i = (i + 0.5) / N ≤ TAIL_P, take the more severe of the history and the docs' t₃ stand-in,
     z_i ← min(z_i, floor(1000 · t₃⁻¹(p_i) / √3)). Both sequences ascend, so the set stays sorted.

Joint stress set: every historical WEEKEND or HOLIDAY_WEEKEND closure where the index has a z. Each
listed asset contributes its own z of that closure's type; where it has none (COIN before its 2021
listing, a warm-up, a missing bar) it is back-filled as β_a × z_index, with β_a the OLS slope through
the origin of z_a on z_index over the non-overnight closures where both exist. Closures are ranked by
the equal-weighted mean z of the six assets, and the K worst are kept, worst first.

Synthetic stress weekends (ADR-0204): the data has no 2000–2015 closures, so the joint set gets
|SYNTH_SHAPES| × |SYNTH_HORIZONS| synthetic closures ahead of the historical ones (K stays fixed). The
basket level L_T is the peaks-over-threshold return level of the historical basket z for a horizon of
T years (a GPD fitted to the worst SYNTH_TAIL share of −basket, rounded to 0.01 toward the severe side): the worst basket z a
sample that long would be expected to hold once. Each level is laid out in two cross-sections: the
worst historical closure's z vector scaled to basket −L_T, and all six assets at −L_T (co-movement 1).
"""

from __future__ import annotations

import math

import numpy as np
import pandas as pd
from scipy import stats

from .common import ASSET_GROUP, GROUPS, INDEX, LISTED, ClosureType

N_MIN, N_MAX = 1000, 3000
K_STRESS = 256
Z_CLIP = 32767
TAIL_P = 0.025  # the t₃ floor covers the α range (≤ 0.5%) and the ES tail (β = 97.5%)
T3_DF = 3
SYNTH_TAIL = 0.10  # POT threshold: the worst 10% of basket z
SYNTH_MIN_EXCEEDANCES = 40  # below this the GPD fit is not trusted and levels must be given
SYNTH_HORIZONS = {"since2000": None, "40y": 40.0}  # None = from 2000-01-01 to the last closure
SYNTH_SHAPES = ("worstHistorical", "uniform")


def t3_floor(n: int) -> np.ndarray:
    """The docs' t₃ stand-in in set units: floor(1000 · t₃⁻¹((i + 0.5)/N) / √3), i = 0..N−1."""
    p = (np.arange(n, dtype=float) + 0.5) / n
    return np.clip(np.floor(1000.0 * stats.t.ppf(p, T3_DF) / math.sqrt(T3_DF)), -Z_CLIP, Z_CLIP).astype(np.int64)


def tail_floor(q: np.ndarray) -> tuple[np.ndarray, int]:
    """min(history, t₃) at the tail positions p_i ≤ TAIL_P. Returns the set and how many values moved."""
    n = len(q)
    mask = (np.arange(n, dtype=float) + 0.5) / n <= TAIL_P
    out = q.copy()
    out[mask] = np.minimum(q[mask], t3_floor(n)[mask])
    return out, int((out != q).sum())


def quantise(z: np.ndarray) -> np.ndarray:
    q = np.floor(np.asarray(z, dtype=float) * 1000.0)
    return np.sort(np.clip(q, -Z_CLIP, Z_CLIP).astype(np.int64))


def thin(x: np.ndarray, n: int) -> np.ndarray:
    x = np.sort(x)
    m = len(x)
    if m <= n:
        return x
    idx = ((2 * np.arange(n, dtype=np.int64) + 1) * m) // (2 * n)
    return x[idx]


def _zs(z: pd.DataFrame, names: list[str], t: int) -> list[tuple[str, np.ndarray]]:
    out = []
    for s in names:
        v = z.loc[(z["symbol"] == s) & (z["type"] == t), "z"].dropna().to_numpy()
        if len(v):
            out.append((s, v))
    return out


def build_set(z: pd.DataFrame, asset: str, t: int, alpha: float = 0.001, tail: bool = True) -> tuple[np.ndarray, dict]:
    """The published set (steps 1–5); `tail=False` returns the pooled history alone (steps 1–4)."""
    group = GROUPS[ASSET_GROUP[asset]]
    names = [asset] + [s for s in group if s != asset]
    parts = _zs(z, names, t)
    padded = []
    if sum(len(v) for _, v in parts) < N_MIN and t == ClosureType.HOLIDAY_WEEKEND:
        padded = _zs(z, names, int(ClosureType.WEEKEND))
    pool = np.concatenate([v for _, v in parts] + [v for _, v in padded])
    same_type = np.concatenate([v for _, v in parts])
    x = thin(pool, N_MAX)
    q_hist = quantise(x)
    q, moved = tail_floor(q_hist) if tail else (q_hist, 0)
    n = len(q)
    i_star = max(0, math.ceil(alpha * n) - 1)
    own = parts[0][1] if parts and parts[0][0] == asset else np.array([])
    own_q = np.sort(own)
    info = {
        "asset": asset,
        "closureType": ClosureType(t).name,
        "group": ASSET_GROUP[asset],
        "n": int(n),
        "poolSize": int(len(pool)),
        "contributors": {s: int(len(v)) for s, v in parts},
        "paddedWithWeekend": {s: int(len(v)) for s, v in padded},
        "ksWeekendVsHoliday": (round(float(stats.ks_2samp(same_type, np.concatenate([v for _, v in padded])).statistic), 4)
                               if padded else None),
        "tail": {
            "iStar": i_star,
            "zAlphaPooled": int(q[i_star]),
            "zMinPooled": int(q[0]),
            "zAlphaHistory": int(q_hist[i_star]),
            "zAlphaT3": int(t3_floor(n)[i_star]),
            "t3FloorValuesMoved": moved,
            "ownN": int(len(own)),
            "zAlphaOwn": (int(math.floor(own_q[max(0, math.ceil(alpha * len(own_q)) - 1)] * 1000)) if len(own) else None),
            "zMinOwn": int(math.floor(own_q[0] * 1000)) if len(own) else None,
            "p01Pooled": int(q[max(0, math.ceil(0.01 * n) - 1)]),
        },
    }
    return q, info


def stress_levels(basket: pd.Series) -> dict:
    """Peaks-over-threshold return levels of the basket z (ADR-0204). x = −basket; u = the (1 − SYNTH_TAIL)
    quantile; a GPD (shape ξ, scale s) is fitted to x − u over x > u; the level for T closures is
    u + s/ξ ((T ζ)^ξ − 1), ζ = the exceedance share. T = closures per year of the sample × the horizon.
    A level is never milder than the worst observed basket z. Rounded to 0.01 toward the severe side, so
    solver noise cannot reach the set."""
    x = -basket.to_numpy(dtype=float)
    first, last = pd.Timestamp(basket.index.min()), pd.Timestamp(basket.index.max())
    per_year = len(x) / ((last - first).days / 365.25)
    u = float(np.quantile(x, 1.0 - SYNTH_TAIL))
    exc = x[x > u] - u
    if len(exc) < SYNTH_MIN_EXCEEDANCES:
        raise ValueError(f"{len(exc)} exceedances < {SYNTH_MIN_EXCEEDANCES}: pass the stress levels explicitly")
    xi, _, sc = stats.genpareto.fit(exc, floc=0)
    zeta = len(exc) / len(x)
    out = {"threshold": round(u, 4), "exceedances": int(len(exc)), "xi": round(float(xi), 4), "scale": round(float(sc), 4),
           "closuresPerYear": round(per_year, 2), "worstObserved": round(float(x.max()), 4), "levels": {}}
    for name, yrs in SYNTH_HORIZONS.items():
        years = yrs if yrs is not None else (last - pd.Timestamp("2000-01-01")).days / 365.25
        t = per_year * years
        lvl = u + sc / xi * ((t * zeta) ** xi - 1.0) if abs(xi) > 1e-9 else u + sc * math.log(t * zeta)
        out["levels"][name] = {"years": round(years, 2), "closures": round(t, 1), "basketZ": -math.ceil(max(lvl, x.max()) * 100.0) / 100.0}
    return out


def joint(z: pd.DataFrame, k: int = K_STRESS, synthetic: bool | dict = True) -> tuple[dict[str, np.ndarray], dict]:
    """`synthetic`: True fits the stress levels on this sample, a dict ({horizon: basketZ}) uses given levels
    (the walk-forward backtest passes the full-sample levels), False adds none."""
    nz = z[(z["type"] != int(ClosureType.OVERNIGHT)) & z["symbol"].isin(list(LISTED))]
    wide = nz.pivot_table(index="date", columns="symbol", values="z", aggfunc="first")
    types = nz.groupby("date")["type"].first()
    wide = wide[wide[INDEX].notna()].copy()
    betas, filled = {}, {}
    zi = wide[INDEX]
    for a in LISTED:
        if a == INDEX:
            continue
        if a not in wide.columns:  # no z at all yet (a walk-forward year before the listing)
            wide[a] = np.nan
        both = wide[[a, INDEX]].dropna()
        # β = 1 when there is no overlap: the asset then has no closures of its own to replay either
        betas[a] = float((both[a] * both[INDEX]).sum() / (both[INDEX] ** 2).sum()) if len(both) else 1.0
        miss = wide[a].isna()
        filled[a] = int(miss.sum())
        wide.loc[miss, a] = betas[a] * zi[miss]
    wide = wide[list(LISTED)]
    basket = wide.mean(axis=1)
    ranked = basket.sort_values(kind="mergesort")
    synth_info: dict = {"method": "none"}
    synth_rows: list[tuple[dict, np.ndarray]] = []
    if synthetic is not False:
        if synthetic is True:
            synth_info = {"method": "POT/GPD return levels of the historical basket z", **stress_levels(basket)}
            levels = {h: v["basketZ"] for h, v in synth_info["levels"].items()}
        else:
            levels = dict(synthetic)
            synth_info = {"method": "given levels", "levels": {h: {"basketZ": v} for h, v in levels.items()}}
        worst = wide.loc[ranked.index[0]].to_numpy(dtype=float)
        shapes = {"worstHistorical": worst / worst.mean(), "uniform": np.ones(len(LISTED))}  # mean 1; × the (negative) level
        synth_info["worstHistoricalShapeFrom"] = str(ranked.index[0])
        for h, lvl in levels.items():
            for sh in SYNTH_SHAPES:
                vec = shapes[sh] * lvl
                synth_rows.append(({"date": f"SYN-{h}-{sh}", "type": "SYNTHETIC", "basketZ": round(float(vec.mean()), 4)}, vec))
        synth_rows.sort(key=lambda r: r[0]["basketZ"])
    order = ranked.index[:max(0, k - len(synth_rows))]
    hist = {a: wide.loc[order, a].to_numpy() for a in LISTED}
    cols = {}
    for j, a in enumerate(LISTED):
        v = np.concatenate([np.array([vec[j] for _, vec in synth_rows]), hist[a]])
        cols[a] = np.clip(np.floor(v * 1000.0), -Z_CLIP, Z_CLIP).astype(np.int64)
    closures = [row for row, _ in synth_rows] + [
        {"date": d, "type": ClosureType(int(types[d])).name, "basketZ": round(float(basket[d]), 4)} for d in order]
    info = {
        "k": int(len(closures)),
        "candidates": int(len(wide)),
        "firstClosure": str(wide.index.min()),
        "lastClosure": str(wide.index.max()),
        "ranking": "synthetic stress closures first (ADR-0204), then historical closures by equal-weighted mean z "
                   "of the six assets, ascending (worst first)",
        "betaMethod": "OLS through the origin of z_a on z_SPY over non-overnight closures where both exist",
        "beta": {a: round(b, 6) for a, b in betas.items()},
        "backfilled": filled,
        "synthetic": synth_info,
        "closures": closures,
    }
    return cols, info
