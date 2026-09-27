"""σ methodology: the committed vectors are current, and the two modes (cold replay, keeper resume)
agree with each other and with the formulas in docs/sigma.md."""

import json
import math

import pandas as pd

from credence_cal import sigma_vectors
from credence_cal.common import canonical_json
from credence_cal.sigma import LAM, SEED, W, State, keeper_step, replay, to_wad


def test_committed_vectors_are_current():
    committed = json.loads(sigma_vectors.PATH.read_text())
    assert canonical_json(committed) == canonical_json(sigma_vectors.build())


def test_to_wad_rounds_to_nano_half_up():
    assert to_wad(0.0123456784) == 12345678 * 10**9
    assert to_wad(0.0123456785) == 12345679 * 10**9 or to_wad(0.0123456785) == 12345678 * 10**9  # float tie
    assert to_wad(0.015) == 15 * 10**15


def test_gap_return_split_and_dividend():
    # 10:1 split at the open: 1208.88 before, 121.44 after is a +0.457% gap
    assert math.isclose(sigma_vectors.gap_return(1208.88, 121.44, 10.0, 0.0), 0.0045662100456620, rel_tol=1e-12)
    # dividend going ex is added back
    assert sigma_vectors.gap_return(100.0, 99.5, 1.0, 0.5) == 0.0


def test_keeper_resume_equals_cold_replay_continuation():
    gaps = sigma_vectors._lcg_gaps(700, 5)
    st = State()
    for t, r in gaps[:600]:
        st.update(t, r)
    assert all(st.warm(t) for t in (1, 2, 3))
    rho2 = {t: st.rho2(t) for t in (2, 3)}
    v = {t: st.v[t] for t in (1, 2, 3)}
    for t, r in gaps[600:]:
        st.update(t, r)
        v, sig = keeper_step(v, rho2, [(t, r)])
        assert v == st.v
        assert sig[1] == st.sigma(1)
    # with rho2 frozen, σ[2], σ[3] follow the formula exactly
    for t in (2, 3):
        assert sig[t] == math.sqrt(W * v[t] + ((1.0 - W) * rho2[t]) * v[1])


def test_seed_and_update_rule():
    st = State()
    rs = [0.01 * (i % 7 - 3) for i in range(SEED[1])]
    for r in rs:
        st.update(1, r)
    s = 0.0
    for r in rs:
        s = s + r * r
    assert st.v[1] == s / SEED[1]
    st.update(1, 0.02)
    assert st.v[1] == LAM * (s / SEED[1]) + (1.0 - LAM) * (0.02 * 0.02)


def test_replay_z_is_ex_ante():
    gaps = sigma_vectors._lcg_gaps(600, 9)
    g = pd.DataFrame({"date": [f"d{i:04d}" for i in range(len(gaps))], "type": [t for t, _ in gaps],
                      "r": [r for _, r in gaps]})
    out, _, daily = replay(g)
    st = State()
    for i, (t, r) in enumerate(gaps):
        if st.warm(t):
            assert out["z"].iloc[i] == r / st.sigma(t)
        else:
            assert math.isnan(out["z"].iloc[i])
        st.update(t, r)
    assert daily, "all three types warm by the end"
