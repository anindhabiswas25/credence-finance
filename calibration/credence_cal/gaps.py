"""Step 2: close-to-open gaps with XNYS closure labels, plus the data-quality report (§10.6 step 2).

For consecutive XNYS sessions p → s where the vendor has a bar for both:

    r_s = split_s × (open_s + dividend_s) / close_p − 1

`split_s` (new shares per old share) and `dividend_s` (cash per share) go ex at s's open, so r is the
holder's total return over the closure; known dividends are handled separately by the engine (d in
F-4.2), so they must not leak into the z-sets. The closure type comes from the same classifier the
calendar generator uses for `closureTypeAfter` (OVERNIGHT / WEEKEND / HOLIDAY_WEEKEND; a mid-week
holiday is HOLIDAY_WEEKEND), so labels match the on-chain clock exactly.

A gap whose previous session has no bar (a halt, a late listing, a vendor hole) spans more than one
closure and is dropped; the quality report lists every such case.
"""

from __future__ import annotations

import datetime as dt
import math

import numpy as np
import pandas as pd

from .calendar import _classify, _session_days
from .common import ClosureType

OUTLIER_ABS_R = 0.20  # flagged for review, never dropped
SPLIT_RATIOS = (2, 3, 4, 5, 8, 10, 15, 20, 1 / 2, 1 / 3, 1 / 4, 1 / 5, 1 / 8, 1 / 10, 1 / 20)


def xnys(start: str, end: str) -> tuple[list[dt.date], set[dt.date]]:
    s, e = dt.date.fromisoformat(start), dt.date.fromisoformat(end)
    days, holidays, _ = _session_days("XNYS", s, e)
    return [d for d in days if d <= e], holidays


def compute(symbol: str, raw: pd.DataFrame, sessions: list[dt.date], holidays: set[dt.date]) -> tuple[pd.DataFrame, dict]:
    raw = raw.copy()
    raw["d"] = pd.to_datetime(raw["date"]).dt.date
    sess = set(sessions)
    off_calendar = sorted(str(d) for d in raw["d"] if d not in sess)
    bars = raw[raw["d"].isin(sess)].set_index("d")
    first = bars.index.min()
    rows, spans, halted, bad = [], [], [], []
    idx = [d for d in sessions if first is not None and d >= first]
    for p, s in zip(idx, idx[1:]):
        if s not in bars.index:
            spans.append(str(s))
            continue
        b = bars.loc[s]
        if p not in bars.index:
            continue  # already reported as a span on p
        c_prev = float(bars.loc[p, "close"])
        o, sr, dv = float(b["open"]), float(b["split_ratio"]), float(b["dividend"])
        if not (o > 0 and c_prev > 0) or not (b["low"] - 1e-9 <= o <= b["high"] + 1e-9):
            bad.append({"date": str(s), "open": o, "low": float(b["low"]), "high": float(b["high"]), "prevClose": c_prev})
            continue
        if float(b["volume"]) == 0:
            halted.append(str(s))
            continue
        r = sr * (o + dv) / c_prev - 1.0
        rows.append({"symbol": symbol, "date": str(s), "prev": str(p), "type": int(_classify(p, s, holidays)),
                     "r": r, "split": sr, "dividend": dv})
    g = pd.DataFrame(rows, columns=["symbol", "date", "prev", "type", "r", "split", "dividend"])
    outliers = g[g["r"].abs() > OUTLIER_ABS_R]
    suspect = []
    for _, x in outliers.iterrows():
        ratio = 1.0 + x["r"]
        if x["split"] == 1.0 and any(abs(math.log(ratio / k)) < 0.08 for k in SPLIT_RATIOS):
            suspect.append(x["date"])
    q = {
        "symbol": symbol,
        "bars": int(len(raw)),
        "firstSession": str(first) if first is not None else None,
        "gaps": {ClosureType(t).name: int((g["type"] == t).sum()) for t in (1, 2, 3)},
        "missingSessions": spans,
        "offCalendarBars": off_calendar,
        "zeroVolumeDays": halted,
        "badBars": bad,
        "outliers": [{"date": x["date"], "type": ClosureType(int(x["type"])).name, "r": round(float(x["r"]), 6)}
                     for _, x in outliers.iterrows()],
        "suspectUnadjustedSplits": suspect,
    }
    return g, q


def summary_stats(g: pd.DataFrame) -> dict:
    out = {}
    for t in (1, 2, 3):
        r = g.loc[g["type"] == t, "r"].to_numpy()
        if len(r) == 0:
            continue
        out[ClosureType(t).name] = {
            "n": int(len(r)),
            "sd": round(float(np.sqrt(np.mean(r * r))), 6),
            "min": round(float(r.min()), 6),
            "max": round(float(r.max()), 6),
        }
    return out
