"""Generate `calibration/docs/sigma-vectors.json`, the test vectors for `sigma.md` (keeper J7).

Vendor-independent: every input is synthetic and written into the file, so the vectors never change
when the data vendor does. `python -m credence_cal.sigma_vectors` rewrites the file; the test suite
checks the committed file is current.
"""

from __future__ import annotations

import datetime as dt
import math

from .calendar import _classify, _session_days
from .common import ROOT, ClosureType, write_json
from .sigma import LAM, SEED, W, WARM_N1, State, keeper_step, to_wad

PATH = ROOT / "docs" / "sigma-vectors.json"
WAD = 10**18


def gap_return(prev_close: float, open_: float, split: float, dividend: float) -> float:
    return split * (open_ + dividend) / prev_close - 1.0


def _lcg_gaps(n: int, seed: int) -> list[tuple[int, float]]:
    """Deterministic pseudo-gaps: types cycle like a real week (4 overnights, 1 weekend, a holiday every
    ~9 weeks), sizes from an LCG with occasional 5x jumps. Only the listed values matter."""
    x, out = seed, []
    for i in range(n):
        x = (6364136223846793005 * x + 1442695040888963407) % (1 << 64)
        u = (x >> 11) / float(1 << 53)  # [0, 1)
        week_day = i % 5
        t = 1 if week_day else (3 if (i // 5) % 9 == 8 else 2)
        size = {1: 0.012, 2: 0.015, 3: 0.014}[t] * (5.0 if u > 0.97 else 1.0)
        r = round((2.0 * u - 1.0) * size * 1.7, 6)
        out.append((t, r))
    return out


def min_allowed(current: int, days: int) -> int:
    """risk-core `sigma_min_allowed` for the small `days` used in the vectors: current × 0.9^days rounded
    up. 0.9^d is exact in WAD for d ≤ 3, so this integer form equals the engine's."""
    assert 0 <= days <= 3
    f = [WAD, 9 * 10**17, 81 * 10**16, 729 * 10**15][days]
    return -(-current * f // WAD)


def publish(model: int, floor: int, current: int, days: int) -> int:
    return max(model, floor, min_allowed(current, days)) if current else max(model, floor)


def build() -> dict:
    gr = [
        (100.0, 101.0, 1.0, 0.0), (180.0, 158.4, 1.0, 0.0), (1208.88, 121.44, 10.0, 0.0),
        (227.52, 228.1, 1.0, 0.25), (134.27, 33.9, 4.0, 0.04), (0.5, 0.25, 1.0, 0.0),
    ]
    gap_vectors = [{"prevClose": repr(a), "open": repr(b), "split": repr(c), "dividend": repr(d),
                    "r": repr(gap_return(a, b, c, d))} for a, b, c, d in gr]

    pairs = [("2026-09-24", "2026-09-25"), ("2026-09-25", "2026-09-28"), ("2026-11-25", "2026-11-27"),
             ("2026-11-27", "2026-11-30"), ("2027-03-25", "2027-03-29"), ("2027-07-02", "2027-07-06"),
             ("2025-01-08", "2025-01-10"), ("2025-06-18", "2025-06-20"), ("2025-12-31", "2026-01-02"),
             ("2026-01-16", "2026-01-20")]
    lo, hi = dt.date(2025, 1, 1), dt.date(2027, 8, 1)
    _, holidays, _ = _session_days("XNYS", lo, hi)
    classify = [{"prevSession": a, "session": b,
                 "closureType": int(_classify(dt.date.fromisoformat(a), dt.date.fromisoformat(b), holidays)),
                 "name": _classify(dt.date.fromisoformat(a), dt.date.fromisoformat(b), holidays).name}
                for a, b in pairs]

    # Keeper mode: resume from a snapshot, constant rho2.
    resume = []
    for vi, (v0, rho2, seed) in enumerate([
        ({1: 2.5e-4, 2: 3.1e-4, 3: 1.9e-4}, {2: 1.25, 3: 0.72}, 7),
        ({1: 1.2e-4, 2: 1.0e-4, 3: 2.2e-4}, {2: 1.6478450243428109, 3: 1.0502063802411914}, 11),
        ({1: 9.0e-4, 2: 8.2e-4, 3: 4.9e-4}, {2: 1.2376516150933499, 3: 0.6620825877846462}, 13),
    ]):
        v = dict(v0)
        steps = []
        for t, r in _lcg_gaps(40, seed):
            v, sig = keeper_step(v, rho2, [(t, r)])
            steps.append({"type": t, "r": repr(r), "v": {str(k): repr(v[k]) for k in (1, 2, 3)},
                          "sigmaWad": {str(k): str(to_wad(sig[k])) for k in (1, 2, 3)}})
        resume.append({"id": f"K-{vi + 1}", "v0": {str(k): repr(x) for k, x in v0.items()},
                       "rho2": {str(k): repr(x) for k, x in rho2.items()}, "steps": steps})

    # Pipeline mode (cold start, expanding rho2): what the calibration replay does.
    st, replay = State(), []
    for t, r in _lcg_gaps(560, 3):
        pre = {str(k): str(to_wad(st.sigma(k))) for k in (1, 2, 3)} if all(st.warm(k) for k in (1, 2, 3)) else None
        st.update(t, r)
        replay.append({"type": t, "r": repr(r), "sigmaBeforeWad": pre})

    pub = []
    for model, floor, cur, days in [
        (15 * 10**15, 12 * 10**15, 0, 0), (15 * 10**15, 12 * 10**15, 20 * 10**15, 1),
        (15 * 10**15, 12 * 10**15, 20 * 10**15, 2), (15 * 10**15, 12 * 10**15, 20 * 10**15, 3),
        (11 * 10**15, 12 * 10**15, 12 * 10**15, 3), (30 * 10**15, 12 * 10**15, 20 * 10**15, 1),
        (19 * 10**15, 12 * 10**15, 20 * 10**15, 0),
    ]:
        pub.append({"modelWad": str(model), "floorWad": str(floor), "currentWad": str(cur), "days": days,
                    "submitWad": str(publish(model, floor, cur, days))})

    return {
        "kind": "credence.sigma-vectors.v1",
        "spec": "calibration/docs/sigma.md",
        "constants": {"lambda": repr(LAM), "w": repr(W), "seed": {str(k): v for k, v in SEED.items()},
                      "warmOvernight": WARM_N1},
        "gapReturn": gap_vectors,
        "classify": classify,
        "keeperResume": resume,
        "pipelineReplay": replay,
        "publish": pub,
    }


def main() -> None:
    write_json(PATH, build())
    print(f"wrote {PATH}")


if __name__ == "__main__":
    main()
