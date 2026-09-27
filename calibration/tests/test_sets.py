"""Scenario-set construction: thinning, quantisation, packing, pooling rules, the joint set."""

import numpy as np
import pandas as pd

from credence_cal import sets
from credence_cal.common import LISTED
from credence_cal.setfile import pack_i16


def test_thin_keeps_quantiles_and_size():
    x = np.arange(10_000, dtype=float)
    y = sets.thin(x, 3000)
    assert len(y) == 3000 and np.all(np.diff(y) >= 0)
    assert y[0] == 1.0 and y[-1] == 9998.0  # midpoint rule: floor(M/6000), floor((5999 M)/6000)
    assert abs(np.quantile(y, 0.5) - np.quantile(x, 0.5)) < 5
    assert np.array_equal(sets.thin(x[:500], 3000), x[:500])


def test_quantise_rounds_down_and_clips():
    q = sets.quantise(np.array([0.0015, -0.0015, 40.0, -40.0, 1.2345]))
    assert list(q) == [-32767, -2, 1, 1234, 32767]


def test_pack_matches_risk_core_lane_order():
    w = pack_i16([1, -1] + [0] * 14 + [7])
    assert w[0] == "0x" + "0" * 56 + "ffff0001"
    assert w[1] == "0x" + "0" * 63 + "7"


def _z(rows):
    return pd.DataFrame(rows, columns=["symbol", "date", "type", "z"])


def test_holiday_padding_and_contributors():
    rng = np.random.default_rng(1)
    rows = []
    for s in ["TSLA", "COIN", "MSTR"]:
        rows += [[s, f"w{i}", 2, float(v)] for i, v in enumerate(rng.standard_normal(400))]
        rows += [[s, f"h{i}", 3, float(v)] for i, v in enumerate(rng.standard_normal(50))]
    q, info = sets.build_set(_z(rows), "TSLA", 3)
    assert info["contributors"] == {"TSLA": 50, "COIN": 50, "MSTR": 50}
    assert info["paddedWithWeekend"] == {"TSLA": 400, "COIN": 400, "MSTR": 400}
    assert info["n"] == 1350 and np.all(np.diff(q) >= 0)


def test_joint_backfills_with_beta_and_ranks_worst_first():
    rows = []
    for i in range(300):
        base = np.sin(i) * 2
        for a in LISTED:
            if a == "COIN" and i < 100:
                continue
            rows.append([a, f"d{i:03d}", 2, base * (0.5 if a == "COIN" else 1.0)])
    cols, info = sets.joint(_z(rows), k=10)
    assert abs(info["beta"]["COIN"] - 0.5) < 1e-12 and info["backfilled"]["COIN"] == 100
    b = [c["basketZ"] for c in info["closures"]]
    assert b == sorted(b) and len(cols["SPY"]) == 10
