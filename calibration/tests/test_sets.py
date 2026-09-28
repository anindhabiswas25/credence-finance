"""Scenario-set construction: thinning, quantisation, packing, pooling rules, the joint set."""

import math

import numpy as np
import pandas as pd
from scipy import stats

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
    cols, info = sets.joint(_z(rows), k=10, synthetic=False)
    assert abs(info["beta"]["COIN"] - 0.5) < 1e-12 and info["backfilled"]["COIN"] == 100
    b = [c["basketZ"] for c in info["closures"]]
    assert b == sorted(b) and len(cols["SPY"]) == 10


def test_t3_floor_matches_the_docs_stand_in():
    # G-06: the docs' t3 quantile at alpha = 0.1% is -5.897362714633 sigma; at N = 3000, i* = 2 has p = 2.5/3000
    t = sets.t3_floor(3000)
    assert t[2] == math.floor(1000 * stats.t.ppf(2.5 / 3000, 3) / math.sqrt(3))
    assert np.all(np.diff(t) >= 0)
    assert sets.t3_floor(1000)[0] == math.floor(1000 * stats.t.ppf(0.0005, 3) / math.sqrt(3))


def test_tail_floor_takes_the_more_severe_and_stays_sorted():
    q = np.sort(np.linspace(-3000, 3000, 1000).astype(np.int64))  # a thin-tailed history
    out, moved = sets.tail_floor(q)
    t = sets.t3_floor(1000)
    n_tail = int(np.sum((np.arange(1000) + 0.5) / 1000 <= sets.TAIL_P))
    assert np.array_equal(out[:n_tail], np.minimum(q[:n_tail], t[:n_tail]))
    assert np.array_equal(out[n_tail:], q[n_tail:]) and np.all(np.diff(out) >= 0) and moved > 0
    fat = q.copy()
    fat[0] = -30000  # a history already more severe than t3 is kept
    assert sets.tail_floor(fat)[0][0] == -30000


def test_joint_synthetic_closures_lead_and_keep_k():
    rng = np.random.default_rng(7)
    rows = []
    for i in range(800):
        m = float(rng.standard_t(3))
        for a in LISTED:
            rows.append([a, f"2016-{1 + i // 70:02d}-{1 + i % 28:02d}x{i}", 2, m + 0.3 * float(rng.standard_normal())])
    zdf = _z(rows)
    zdf["date"] = pd.date_range("2010-01-01", periods=800, freq="7D").strftime("%Y-%m-%d").repeat(len(LISTED)).to_numpy()
    cols, info = sets.joint(zdf, k=64)
    syn = [c for c in info["closures"] if c["type"] == "SYNTHETIC"]
    assert len(syn) == len(sets.SYNTH_HORIZONS) * len(sets.SYNTH_SHAPES) and info["k"] == 64
    assert info["closures"][: len(syn)] == syn and all(len(c) == 64 for c in cols.values())
    lv = info["synthetic"]["levels"]
    assert lv["40y"]["basketZ"] <= lv["since2000"]["basketZ"] <= -info["synthetic"]["worstObserved"]
    cols2, info2 = sets.joint(zdf, k=64, synthetic={"since2000": -9.0})
    assert [c["basketZ"] for c in info2["closures"][:2]] == [-9.0, -9.0]
    assert all(v[1] == -9000 for v in cols2.values())  # the uniform shape
