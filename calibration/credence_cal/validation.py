"""Model validation note (brief item 9, ADR-0204): the historical scenario sets against the docs' t₃
stand-in, and the effect of the free-data tail compensation. Every safe LTV, premium and loss vector here
comes from risk-core through `credence_cal.engine`; this module only tabulates.

Per (asset, closure type) and σ ∈ {3%, 4%, 4.5%, 6%} (the docs' worked examples, §2.3) plus the asset's
published σ today, the uncapped safe factor g_α = (1 + σ z_{i*} − d)(1 − κ) (safe LTV with maxLtv = 1) under
  - the t₃ stand-in: z = floor(1000 · t₃⁻¹(α) / √3) = −5898 at α = 0.1% (G-06 uses −5.897362714633),
  - the pooled history alone (ADR-0203, before the tail floor),
  - the published set (history with the t₃ tail floor, ADR-0204).
It also prices the G-22 policy (C = 18,000, D = 13,500, τ = 3/365, u = 0, σ = 4%) on each set, and measures
how the synthetic stress closures change the worst joint loss of a reference book (the capacity check).
"""

from __future__ import annotations

import math

import numpy as np
from scipy import stats

from . import sets as sets_mod
from .common import LISTED, ClosureType
from .engine import Engine

WAD = 10**18
USD = 10**6
ALPHA, KAPPA = 0.001, 0.03
SIGMAS = (0.03, 0.04, 0.045, 0.06)
G22 = {"C": 18_000, "D": 13_500, "days": 3, "sigma": 0.04}
REF_BOOK_USD = 1_000_000  # per market, all covered at LTV 75% (SPY 80%): the capacity reference book


def w(x: float) -> int:
    return int(round(x * 1e18))


def t3_z(alpha: float = ALPHA) -> int:
    return math.floor(1000.0 * stats.t.ppf(alpha, 3) / math.sqrt(3))


def _g(eng: Engine, s, sigma_w: int) -> int:
    return eng.safe_ltv_from_set(s, w(ALPHA), sigma_w, 0, w(KAPPA), WAD)


def _premium(eng: Engine, s) -> int:
    prem, _, _ = eng.quote_cover(s, w(G22["sigma"]), 0, w(KAPPA), G22["C"] * USD, G22["D"] * USD, G22["days"], 0,
                                 w(1.0), w(0.15), w(4.0), w(0.975), 0)
    return prem


def run(eng: Engine, z, sigma_doc: dict, cols: dict, jinfo: dict) -> dict:
    """`z`: the pooled z table (as for the sets); `sigma_doc`: the σ calibration file; `cols`/`jinfo`: the
    published joint set."""
    t3 = eng.load_set([t3_z()])
    t3_set = eng.load_set([int(v) for v in sets_mod.t3_floor(sets_mod.N_MAX)])
    ref = {"t3Z": t3_z(), "g": {repr(s): _g(eng, t3, w(s)) for s in SIGMAS}, "g22PremiumT3Set": _premium(eng, t3_set)}
    rows = []
    for a in LISTED:
        for t in (1, 2, 3):
            q_hist, _ = sets_mod.build_set(z, a, t, tail=False)
            q_pub, _ = sets_mod.build_set(z, a, t)
            hist, pub = eng.load_set([int(v) for v in q_hist]), eng.load_set([int(v) for v in q_pub])
            n = len(q_pub)
            i_star = max(0, math.ceil(ALPHA * n) - 1)
            sig_now = int(sigma_doc["assets"][a]["sigmaWad"][ClosureType(t).name])
            grid = {}
            for s in [*SIGMAS, "today"]:
                sw = sig_now if s == "today" else w(s)
                grid[repr(s) if s != "today" else "today"] = {"t3": _g(eng, t3, sw), "history": _g(eng, hist, sw),
                                                               "published": _g(eng, pub, sw)}
            zh = int(q_hist[i_star])
            rows.append({"asset": a, "closureType": ClosureType(t).name, "n": n, "iStar": i_star,
                         "zHistory": zh, "zPublished": int(q_pub[i_star]), "zT3": ref["t3Z"],
                         "verdict": "history more severe" if zh < ref["t3Z"] else ("history less severe" if zh > ref["t3Z"] else "equal"),
                         "sigmaTodayWad": str(sig_now), "g": {k: {m: str(v) for m, v in d.items()} for k, d in grid.items()},
                         "g22Premium": {"history": str(_premium(eng, hist)), "published": str(_premium(eng, pub))}})
    return {"reference": {**ref, "g": {k: str(v) for k, v in ref["g"].items()}, "g22PremiumT3Set": str(ref["g22PremiumT3Set"])},
            "sets": rows, "capacity": _capacity(eng, cols, jinfo, sigma_doc)}


def _capacity(eng: Engine, cols: dict, jinfo: dict, sigma_doc: dict) -> dict:
    """Worst joint loss Λ = max_j Σ_a L_{a,j} of a reference book (every market fully covered at its max LTV,
    today's WEEKEND σ) over the published joint set, with and without its synthetic closures. The pool
    needs J ≥ Λ / u_max to sell that book."""
    n_syn = sum(1 for c in jinfo["closures"] if c["type"] == "SYNTHETIC")
    tot_all = np.zeros(jinfo["k"], dtype=object)
    for a in LISTED:
        ltv = 0.80 if a == "SPY" else 0.75
        c = REF_BOOK_USD * USD
        sig = int(sigma_doc["assets"][a]["sigmaWad"]["WEEKEND"])
        lv = eng.loss_vector(eng.load_joint_column([int(v) for v in cols[a]]), c, int(c * ltv), sig, 0, w(KAPPA))
        tot_all += np.array(lv, dtype=object)
    with_syn = int(max(tot_all))
    hist_only = int(max(tot_all[n_syn:])) if n_syn < len(tot_all) else 0
    j_worst = int(np.argmax(tot_all))
    return {"referenceBookUsdPerMarket": REF_BOOK_USD, "syntheticClosures": n_syn,
            "worstLossUsd": {"withSynthetic": round(with_syn / USD, 2), "historicalOnly": round(hist_only / USD, 2)},
            "worstClosure": jinfo["closures"][j_worst]["date"],
            "requiredEquityAtUmaxUsd": {"withSynthetic": round(with_syn / USD / 0.5, 2), "historicalOnly": round(hist_only / USD / 0.5, 2)},
            "increase": round(with_syn / hist_only - 1.0, 4) if hist_only else None}


def pct(x: str | int) -> str:
    return f"{int(x) / 1e16:.2f}%"


def markdown(doc: dict, fname: str, grade: str, end: str) -> str:
    ref = doc["reference"]
    L = [f"# Model validation: historical sets against the t₃ stand-in (data grade `{grade}`, through {end})", "",
         f"Machine-readable: `{fname}`. Method: `credence_cal/validation.py`; every number is risk-core output. "
         f"α = 0.1%, κ = 3%, d = 0. The g columns are the **uncapped** safe factor (safe LTV with maxLtv = 1); "
         f"the product caps it at LTV_max (75%, SPY 80%).", "",
         f"t₃ stand-in: z = {ref['t3Z']}‰σ; g = " + ", ".join(f"{pct(v)} at σ {float(k):.1%}" for k, v in ref["g"].items())
         + f" (the docs' §2.3 values before the cap). G-22 premium on the N = 3,000 t₃ set: ${int(ref['g22PremiumT3Set']) / USD:.2f} "
           "(docs, continuous t₃: $4.39).", "",
         "| Asset | Closure | N | z at i*: t₃ / history / published | verdict | g at σ 4%: t₃ / history / published | "
         "g at today's σ: history / published (σ) | G-22 premium: history / published |",
         "| --- | --- | ---: | --- | --- | --- | --- | --- |"]
    for r in doc["sets"]:
        g4, gt = r["g"]["0.04"], r["g"]["today"]
        L.append(f"| {r['asset']} | {r['closureType']} | {r['n']} | {r['zT3']} / {r['zHistory']} / {r['zPublished']} | {r['verdict']} | "
                 f"{pct(g4['t3'])} / {pct(g4['history'])} / {pct(g4['published'])} | "
                 f"{pct(gt['history'])} / {pct(gt['published'])} ({int(r['sigmaTodayWad']) / 1e16:.2f}%) | "
                 f"${int(r['g22Premium']['history']) / USD:.2f} / ${int(r['g22Premium']['published']) / USD:.2f} |")
    cap = doc["capacity"]
    L += ["", "## Joint stress set: effect of the synthetic closures on capacity", "",
          f"Reference book: ${cap['referenceBookUsdPerMarket']:,} of collateral per market, all covered at max LTV, today's WEEKEND σ. "
          f"Worst joint loss with the {cap['syntheticClosures']} synthetic closures: ${cap['worstLossUsd']['withSynthetic']:,.2f} "
          f"(at {cap['worstClosure']}); historical closures only: ${cap['worstLossUsd']['historicalOnly']:,.2f}. "
          f"Pool equity needed at u_max = 50%: ${cap['requiredEquityAtUmaxUsd']['withSynthetic']:,.2f} vs "
          f"${cap['requiredEquityAtUmaxUsd']['historicalOnly']:,.2f} "
          f"({cap['increase']:+.1%})." if cap["increase"] is not None else ""]
    return "\n".join(L) + "\n"
