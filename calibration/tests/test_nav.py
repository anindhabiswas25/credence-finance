"""TBILL:USBANK NAV proxy (ADR-0118): total returns between USBANK sessions, set pooling / padding, the joint column."""

import datetime as dt
import math

import numpy as np
import pandas as pd

from credence_cal import nav, sets
from credence_cal.common import ClosureType


def _raw(days, closes, split=None, div=None):
    n = len(days)
    return pd.DataFrame({"date": [d.isoformat() for d in days], "open": closes, "high": closes, "low": closes,
                         "close": closes, "volume": [1.0] * n,
                         "split_ratio": split or [1.0] * n, "dividend": div or [0.0] * n})


def test_returns_are_total_returns_typed_by_usbank_and_span_dropped():
    d = [dt.date(2026, 10, 5) + dt.timedelta(days=i) for i in range(12)]  # Mon Oct 5 .. Fri Oct 16 2026
    sessions = [x for x in d if x.weekday() < 5 and x != dt.date(2026, 10, 12)]  # Columbus Day: USBANK holiday
    holidays = {dt.date(2026, 10, 12)}
    bars = [x for x in sessions if x != dt.date(2026, 10, 15)]  # a missing ETF bar on Thursday
    closes = [100.0 + 0.01 * i for i in range(len(bars))]
    div = [0.0] * len(bars)
    div[2] = 0.3  # ex-dividend on Wednesday: the close drops, the total return does not
    closes[2] -= 0.3
    g, q = nav.returns("BIL", _raw(bars, closes, div=div), sessions, holidays)
    by = {r.date: r for r in g.itertuples()}
    assert "2026-10-15" not in by and "2026-10-15" in q["spansDropped"]
    assert "2026-10-16" not in by, "Fri spans two closures (Thu missing): dropped"
    assert math.isclose(by["2026-10-07"].r, (closes[2] + 0.3) / closes[1] - 1.0)
    # Fri Oct 9 → Tue Oct 13 spans a weekend and the Columbus Day holiday: one HOLIDAY_WEEKEND closure
    assert by["2026-10-13"].prev == "2026-10-09"
    assert by["2026-10-13"].type == int(ClosureType.HOLIDAY_WEEKEND)
    assert by["2026-10-06"].type == int(ClosureType.OVERNIGHT)


def test_returns_apply_the_split_ratio():
    days = [dt.date(2026, 10, 5), dt.date(2026, 10, 6)]
    g, _ = nav.returns("BIL", _raw(days, [100.0, 50.0], split=[1.0, 2.0]), days, set())
    assert math.isclose(g["r"].iloc[0], 0.0)


def _z(rows):
    return pd.DataFrame(rows, columns=["symbol", "date", "type", "z"])


def test_build_set_pads_a_short_type_and_reports_ks():
    rng = np.random.default_rng(1)
    rows = [("BIL", f"d{i}", 1, z) for i, z in enumerate(rng.standard_normal(2500))]
    rows += [("BIL", f"w{i}", 2, z) for i, z in enumerate(rng.standard_normal(400))]
    rows += [("SGOV", f"s{i}", 2, z) for i, z in enumerate(rng.standard_normal(200))]
    q, info = nav.build_set(_z(rows), int(ClosureType.WEEKEND), 0.001)
    assert info["contributors"] == {"BIL": 400, "SGOV": 200}
    assert info["paddedWith"]["OVERNIGHT"] == 2500 and "ksOvernight" in info["paddedWith"]
    assert info["poolSize"] == 3100 and info["n"] == sets.N_MAX
    assert np.all(np.diff(q) >= 0)
    q2, info2 = nav.build_set(_z(rows), int(ClosureType.OVERNIGHT), 0.001)
    assert info2["paddedWith"] == {} and info2["n"] == 2500, "≥ N_MIN: no padding, ≤ N_MAX: not thinned"


def test_joint_column_synthetic_rows_first_then_worst_history():
    rows = [("BIL", f"2020-01-{i:02d}", 2, -0.1 * i) for i in range(1, 11)] + [("BIL", "2020-02-01", 1, -9.0)]
    weekend_set = np.array(sorted([-9000, -7000, -6276] + [0] * 2997))  # z_α at i* = ceil(0.001 × 3000) − 1 = 2
    col, info = nav.joint_column(_z(rows), 5, 0.000136, weekend_set, 0.001)
    assert len(col) == 5 and info["k"] == 5
    assert col[0] == -32767, "0.5 % / 0.0136 % = 36.8 σ, clipped"
    assert col[1] == -6276
    assert list(col[2:]) == [-1000, -900, -800], "worst non-overnight BIL closures, worst first"
