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

Joint stress set: every historical WEEKEND or HOLIDAY_WEEKEND closure where the index has a z. Each
listed asset contributes its own z of that closure's type; where it has none (COIN before its 2021
listing, a warm-up, a missing bar) it is back-filled as β_a × z_index, with β_a the OLS slope through
the origin of z_a on z_index over the non-overnight closures where both exist. Closures are ranked by
the equal-weighted mean z of the six assets, and the K worst are kept, worst first.
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


def build_set(z: pd.DataFrame, asset: str, t: int, alpha: float = 0.001) -> tuple[np.ndarray, dict]:
    group = GROUPS[ASSET_GROUP[asset]]
    names = [asset] + [s for s in group if s != asset]
    parts = _zs(z, names, t)
    padded = []
    if sum(len(v) for _, v in parts) < N_MIN and t == ClosureType.HOLIDAY_WEEKEND:
        padded = _zs(z, names, int(ClosureType.WEEKEND))
    pool = np.concatenate([v for _, v in parts] + [v for _, v in padded])
    same_type = np.concatenate([v for _, v in parts])
    x = thin(pool, N_MAX)
    q = quantise(x)
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
            "ownN": int(len(own)),
            "zAlphaOwn": (int(math.floor(own_q[max(0, math.ceil(alpha * len(own_q)) - 1)] * 1000)) if len(own) else None),
            "zMinOwn": int(math.floor(own_q[0] * 1000)) if len(own) else None,
            "p01Pooled": int(q[max(0, math.ceil(0.01 * n) - 1)]),
        },
    }
    return q, info


def joint(z: pd.DataFrame, k: int = K_STRESS) -> tuple[dict[str, np.ndarray], dict]:
    nz = z[(z["type"] != int(ClosureType.OVERNIGHT)) & z["symbol"].isin(list(LISTED))]
    wide = nz.pivot_table(index="date", columns="symbol", values="z", aggfunc="first")
    types = nz.groupby("date")["type"].first()
    wide = wide[wide[INDEX].notna()].copy()
    betas, filled = {}, {}
    zi = wide[INDEX]
    for a in LISTED:
        if a == INDEX:
            continue
        both = wide[[a, INDEX]].dropna()
        betas[a] = float((both[a] * both[INDEX]).sum() / (both[INDEX] ** 2).sum())
        miss = wide[a].isna()
        filled[a] = int(miss.sum())
        wide.loc[miss, a] = betas[a] * zi[miss]
    wide = wide[list(LISTED)]
    basket = wide.mean(axis=1)
    order = basket.sort_values(kind="mergesort").index[:k]
    cols = {a: np.clip(np.floor(wide.loc[order, a].to_numpy() * 1000.0), -Z_CLIP, Z_CLIP).astype(np.int64) for a in LISTED}
    info = {
        "k": int(len(order)),
        "candidates": int(len(wide)),
        "firstClosure": str(wide.index.min()),
        "lastClosure": str(wide.index.max()),
        "ranking": "equal-weighted mean z of the six assets, ascending (worst first)",
        "betaMethod": "OLS through the origin of z_a on z_SPY over non-overnight closures where both exist",
        "beta": {a: round(b, 6) for a, b in betas.items()},
        "backfilled": filled,
        "closures": [{"date": d, "type": ClosureType(int(types[d])).name, "basketZ": round(float(basket[d]), 4)}
                     for d in order],
    }
    return cols, info
