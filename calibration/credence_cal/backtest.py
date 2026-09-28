"""Step 7: the backtest (§10.6 step 7, brief item 6). Every piece of engine math goes through
`credence_cal.engine` (risk-py, i.e. risk-core natively), never numpy, so the backtest and the chain
cannot disagree. Only bookkeeping (sums, counts, confidence intervals) is done here.

Replay. Every XNYS closure (OVERNIGHT, WEEKEND, HOLIDAY_WEEKEND) from `START` to the data end is one pool
epoch (R-10). **Walk-forward:** closures in calendar year Y use scenario sets, the joint set and σ floors
built only from data before 1 January Y (the synthetic stress levels of ADR-0204 are the full-sample
ones, passed in: a look-ahead only in the conservative direction, because an early year has too few
closures to fit a tail); σ is the ex-ante EWMA of sigma.md. The engine's 10%/day σ
rate limit is not replayed; it can only raise σ, so the breach counts here are an upper bound.

Synthetic book (per asset, rebuilt each closure with a seeded draw): `N_LOANS` loans sharing the
market's borrow cap B = $1.4M (§12.2); 30% sit at LTV_max ("at the limit"), 70% are uniform on
[40%, LTV_max]. At the Bell, D_proj = D(1 + r_b τ) (R-08) at the U = 85% kinked rate.

Cover-uptake rule: a loan above the closure's safe LTV either buys Gap Cover or cures. Loans at the limit
buy cover (they borrowed to the cap and want to stay there); a loan strictly inside the cap buys cover if
its index is even, else it repays down to the safe LTV. Cover is sold only if the pool passes
`pool_capacity` (u_after ≤ u_max); a refused loan cures instead, and the epoch counts as capacity-bound.

Reopen. The open is V(1 + r_px), r_px the price gap (dividends are known and handled by d). A loan with
HF < 1 at the open is liquidated: lot from `liquidation_lot` at the reserve R = (1 − κ)P, cleared at R
(the pool backstop price; the worst case for the borrower and the pool), settled by `settle_position`.
The pool pays every shortfall (it is first loss for covered and uncovered loans alike, R-18) and earns
premiums, ⅓ of penalties and its ρ_J share of interest for τ. Pool equity J is held at J0 for every
epoch (underwriters withdraw profits and top up losses), so epochs are comparable; a **senior loss**
is an epoch whose shortfalls exceed J0.

Breach test (α). For each (asset, closure) the uncapped safe factor g_α = safe_ltv(…, maxLtv = 1) is the
LTV that exactly survives the α-quantile gap; a breach is a realised (1 + r_px)(1 − κ) < g_α.
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field, replace

import numpy as np
import pandas as pd
from scipy import stats

from . import sets as sets_mod
from . import sigma as sigma_mod
from .common import LISTED, ClosureType
from .engine import Engine

WAD = 10**18
USD = 10**6  # loan token decimals (USDC)
START_YEAR = 2018
N_LOANS = 40
BORROW_CAP_USD = 1_400_000


@dataclass(frozen=True)
class Params:
    alpha: float = 0.001
    kappa: float = 0.03
    theta: float = 1.00
    cost_of_cap: float = 0.15
    eta: float = 4.0
    beta: float = 0.975
    u_max: float = 0.50
    min_premium_usd: float = 0.50
    lam: float = 0.03
    h_star: float = 1.10
    rho_pool: float = 0.10
    util: float = 0.85
    pool_equity_usd: float = 2_000_000.0
    max_ltv: dict = field(default_factory=lambda: {a: (0.80 if a == "SPY" else 0.75) for a in LISTED})
    lt: dict = field(default_factory=lambda: {a: (0.85 if a == "SPY" else 0.80) for a in LISTED})


def w(x: float) -> int:
    """Decimal parameter → WAD integer (parameters are round decimals, so this is exact)."""
    return int(round(x * 1e18))


@dataclass
class YearSets:
    sets: dict  # (asset, type) -> engine set handle
    n: dict
    joint: dict  # asset -> engine set handle (K entries, closure order)
    k: int
    floors: dict  # (asset, type) -> σ floor (float)


def build_year_sets(eng: Engine, z: pd.DataFrame, daily: dict[str, list[dict]], year: int, synth: dict) -> YearSets:
    cut = f"{year}-01-01"
    zp = z[z["date"] < cut]
    out, n = {}, {}
    for a in LISTED:
        for t in (1, 2, 3):
            q, info = sets_mod.build_set(zp, a, t)
            out[(a, t)] = eng.load_set([int(v) for v in q])
            n[(a, t)] = info["n"]
    cols, jinfo = sets_mod.joint(zp, synthetic=synth)
    joint = {a: eng.load_set([int(v) for v in cols[a]]) for a in LISTED}
    floors = {}
    for a in LISTED:
        past = [d for d in daily[a] if d["date"] < cut]
        f = sigma_mod.floors(past) if past else {1: 0.0, 2: 0.0, 3: 0.0}
        for t in (1, 2, 3):
            floors[(a, t)] = f[t]
    return YearSets(out, n, joint, jinfo["k"], floors)


def run(eng: Engine, gaps: pd.DataFrame, z: pd.DataFrame, daily: dict[str, list[dict]], p: Params, synth: dict,
        years_cache: dict | None = None, start: str = f"{START_YEAR}-01-01", end: str = "9999-12-31") -> dict:
    """One full replay. `gaps` holds the listed assets with the ex-ante `sigma` column (sigma.replay);
    `synth` the synthetic stress levels {horizon: basket z} of the full-sample joint set. A pre-filled
    `years_cache` ({year: YearSets}) replaces the walk-forward sets (the in-sample replay)."""
    g = gaps[gaps["symbol"].isin(list(LISTED)) & gaps["sigma"].notna()].copy()
    g = g[(g["date"] >= start) & (g["date"] <= end)]
    closures = sorted(set(zip(g["date"], g["type"])))
    by = {(s, d): row for s, d, row in zip(g["symbol"], g["date"], g.itertuples(index=False))}
    cache = years_cache if years_cache is not None else {}
    r_b = eng.kinked_rate(w(p.util), w(0.02), w(0.06), w(0.80), w(0.90))

    breaches = defaultdict(lambda: [0, 0])  # (asset, type) -> [breaches, trials]
    epochs = []
    for ci, (date, t) in enumerate(closures):
        year = int(date[:4])
        if year not in cache:
            cache[year] = build_year_sets(eng, z, daily, year, synth)
        ys = cache[year]
        rows = {a: by.get((a, date)) for a in LISTED}
        days = (pd.Timestamp(date) - pd.Timestamp(next(r.prev for r in rows.values() if r is not None))).days
        mkt = {}
        for a, row in rows.items():
            if row is None:
                continue
            sig = max(float(row.sigma), ys.floors[(a, t)])
            sig_w, d_w = sigma_mod.to_wad(sig), w(float(row.d))
            s = ys.sets[(a, t)]
            safe = eng.safe_ltv_from_set(s, w(p.alpha), sig_w, d_w, w(p.kappa), w(p.max_ltv[a]))
            g_alpha = eng.safe_ltv_from_set(s, w(p.alpha), sig_w, d_w, w(p.kappa), WAD)
            r_px = float(row.r) - float(row.d)
            realised = max(0.0, 1.0 + r_px) * (1.0 - p.kappa)
            b = breaches[(a, t)]
            b[0] += int(realised * WAD < g_alpha)
            b[1] += 1
            mkt[a] = {"sigma": sig_w, "d": d_w, "safe": safe, "r_px": r_px, "set": s}
        epochs.append(_epoch(eng, ci, date, t, days, mkt, ys, p, r_b))
    return {"breaches": {f"{a}:{ClosureType(t).name}": v for (a, t), v in sorted(breaches.items())},
            "epochs": epochs, "params": p}


def _book(ci: int, asset: str, max_ltv: float) -> list[float]:
    rng = np.random.default_rng([ci, list(LISTED).index(asset)])
    n_lim = int(round(0.3 * N_LOANS))
    ltv = [max_ltv] * n_lim + list(rng.uniform(0.40, max_ltv, N_LOANS - n_lim))
    return ltv


def _epoch(eng: Engine, ci: int, date: str, t: int, days: int, mkt: dict, ys: YearSets, p: Params, r_b: int) -> dict:
    kappa, lam = w(p.kappa), w(p.lam)
    J = int(p.pool_equity_usd * USD)
    current = [0] * ys.k
    loans = []
    requests, refused, premiums = 0, 0, 0
    d_each = BORROW_CAP_USD * USD // N_LOANS
    d_proj = eng.projected_debt(d_each, r_b, days)  # every loan carries the same debt; only C differs
    for a in mkt:
        for i, ltv in enumerate(_book(ci, a, p.max_ltv[a])):
            c = int(d_each / ltv)
            loans.append({"a": a, "C": c, "D": d_proj, "covered": False, "limit": ltv >= p.max_ltv[a], "i": i})
    # Bell: cover or cure. Covers are processed market by market, in loan order.
    for ln in loans:
        m = mkt[ln["a"]]
        if ln["D"] * WAD <= m["safe"] * ln["C"]:
            continue
        wants = ln["limit"] or ln["i"] % 2 == 0
        if wants:
            requests += 1
            add = eng.loss_vector(ys.joint[ln["a"]], ln["C"], ln["D"], m["sigma"], m["d"], kappa)
            unc = _uncovered(loans, mkt, ys, exclude=ln)
            ok, util, _ = eng.pool_capacity(current, add, unc, kappa, J, w(p.u_max))
            if ok:
                prem, _, _ = eng.quote_cover(m["set"], m["sigma"], m["d"], kappa, ln["C"], ln["D"], days, util,
                                             w(p.theta), w(p.cost_of_cap), w(p.eta), w(p.beta), int(p.min_premium_usd * USD))
                premiums += prem
                current = [x + y for x, y in zip(current, add)]
                ln["covered"] = True
                continue
            refused += 1
        ln["D"] = m["safe"] * ln["C"] // WAD  # cure: repay down to the safe LTV
    # Reopen.
    shortfall, penalties, liquidated = 0, 0, 0
    for ln in loans:
        m = mkt[ln["a"]]
        lt = w(p.lt[ln["a"]])
        open_factor = max(0.0, 1.0 + m["r_px"])
        c_open = int(ln["C"] * open_factor)
        if c_open * lt >= ln["D"] * WAD:
            continue  # HF ≥ 1
        liquidated += 1
        # One whole token = $1 of value at V (price WAD 1e18, 18 decimals): q = C in 18-dec units.
        q = ln["C"] * 10**12
        price = w(open_factor)
        reserve = price * (WAD - kappa) // WAD
        x = eng.liquidation_lot(ln["D"], q, reserve, price, lt, w(p.h_star), lam, 18, 6)
        st = eng.settle_position(x, q, reserve, ln["D"], lam, 18, 6)
        shortfall += st["shortfall"]
        penalties += st["penalty"]
    debt = sum(ln["D"] for ln in loans)
    interest_share = debt * r_b // WAD * days // 365 * w(p.rho_pool) // WAD
    pnl = premiums + penalties // 3 + interest_share - shortfall
    return {"i": ci, "date": date, "type": int(t), "days": days, "premiums": premiums, "penalties": penalties,
            "interest": interest_share, "shortfall": shortfall, "pnl": pnl, "requests": requests, "refused": refused,
            "covered": sum(1 for ln in loans if ln["covered"]), "liquidated": liquidated,
            "seniorLoss": max(0, shortfall - J)}


def _uncovered(loans: list[dict], mkt: dict, ys: YearSets, exclude: dict) -> list[tuple]:
    out = []
    for a, m in mkt.items():
        c_unc = sum(ln["C"] for ln in loans if ln["a"] == a and not ln["covered"] and ln is not exclude)
        out.append((ys.joint[a], m["sigma"], m["d"], c_unc, m["safe"]))
    return out


# ── reporting ────────────────────────────────────────────────────────────────────────────────────────────

def summarize(res: dict) -> dict:
    p: Params = res["params"]
    br = {}
    tot = [0, 0]
    by_type = defaultdict(lambda: [0, 0])
    for key, (k, n) in res["breaches"].items():
        br[key] = _binom(k, n, p.alpha)
        tot[0] += k
        tot[1] += n
        t = key.split(":")[1]
        by_type[t][0] += k
        by_type[t][1] += n
    e = pd.DataFrame(res["epochs"])
    J0 = p.pool_equity_usd
    e["pnlUsd"] = e["pnl"] / USD
    e["year"] = e["date"].str[:4]
    yearly = e.groupby("year")["pnlUsd"].sum()
    worst = e.loc[e["pnlUsd"].idxmin()]
    q = e["pnlUsd"].quantile([0.001, 0.01, 0.05, 0.5, 0.95]).to_dict()
    return {
        "breach": {"total": _binom(tot[0], tot[1], p.alpha), "byType": {t: _binom(*v, p.alpha) for t, v in by_type.items()},
                   "byAssetType": br},
        "pool": {
            "epochs": int(len(e)),
            "equityUsd": J0,
            "meanEpochPnlUsd": round(float(e["pnlUsd"].mean()), 2),
            "sdEpochPnlUsd": round(float(e["pnlUsd"].std()), 2),
            "quantilesUsd": {f"{k:g}": round(float(v), 2) for k, v in q.items()},
            "totalPnlUsd": round(float(e["pnlUsd"].sum()), 2),
            "annualReturnOnJ0": round(float(yearly.mean() / J0), 4),
            "premiumsUsd": round(float(e["premiums"].sum() / USD), 2),
            "shortfallsUsd": round(float(e["shortfall"].sum() / USD), 2),
            "worstEpoch": {"date": worst["date"], "type": ClosureType(int(worst["type"])).name,
                           "pnlUsd": round(float(worst["pnlUsd"]), 2), "shortfallUsd": round(float(worst["shortfall"] / USD), 2),
                           "shareOfJ0": round(float(-worst["pnlUsd"] / J0), 4)},
            "worstYear": {"year": str(yearly.idxmin()), "pnlUsd": round(float(yearly.min()), 2)},
            "yearly": {k: round(float(v), 2) for k, v in yearly.items()},
            "capacityBindingRate": round(float((e["refused"] > 0).mean()), 4),
            "capacityBindingRateNonOvernight": round(float((e.loc[e["type"] != 1, "refused"] > 0).mean()), 4),
            "coverRequests": int(e["requests"].sum()),
            "coverRefused": int(e["refused"].sum()),
            "liquidations": int(e["liquidated"].sum()),
        },
        "seniorLossEvents": [{"date": r["date"], "shortfallUsd": round(r["shortfall"] / USD, 2), "seniorLossUsd": round(r["seniorLoss"] / USD, 2)}
                             for r in res["epochs"] if r["seniorLoss"] > 0],
        "worstShortfallEpochs": [{"date": r["date"], "type": ClosureType(int(r["type"])).name, "shortfallUsd": round(r["shortfall"] / USD, 2)}
                                 for r in sorted(res["epochs"], key=lambda r: -r["shortfall"])[:10] if r["shortfall"] > 0],
    }


def _binom(k: int, n: int, alpha: float) -> dict:
    if n == 0:
        return {"breaches": 0, "trials": 0}
    ci = stats.binomtest(k, n).proportion_ci(confidence_level=0.95, method="exact")
    # Kupiec proportion-of-failures LR test against alpha
    ph = k / n
    ll0 = (n - k) * math.log(1 - alpha) + k * math.log(alpha)
    ll1 = ((n - k) * math.log(1 - ph) if ph < 1 else 0.0) + (k * math.log(ph) if k > 0 else 0.0)
    lr = -2 * (ll0 - ll1)
    return {"breaches": k, "trials": n, "rate": round(ph, 6), "ci95": [round(ci.low, 6), round(ci.high, 6)],
            "expected": round(alpha * n, 3), "kupiecP": round(float(stats.chi2.sf(lr, 1)), 4)}


SENSITIVITY = {
    "alpha": [0.0005, 0.001, 0.002, 0.005],
    "kappa": [0.02, 0.03, 0.04, 0.05],
    "theta": [0.5, 1.0, 1.5],
    "u_max": [0.4, 0.5, 0.6],
    "eta": [2.0, 4.0, 6.0],
}


def sensitivity(eng: Engine, gaps, z, daily, base: Params, synth: dict, cache: dict, **kw) -> list[dict]:
    out = []
    for name, vals in SENSITIVITY.items():
        for v in vals:
            p = replace(base, **{name: v})
            s = summarize(run(eng, gaps, z, daily, p, synth, cache, **kw))
            out.append({"param": name, "value": v, "breachRate": s["breach"]["total"]["rate"],
                        "breaches": s["breach"]["total"]["breaches"], "trials": s["breach"]["total"]["trials"],
                        "annualReturnOnJ0": s["pool"]["annualReturnOnJ0"], "worstEpochUsd": s["pool"]["worstEpoch"]["pnlUsd"],
                        "worstYearUsd": s["pool"]["worstYear"]["pnlUsd"], "capacityBindingRate": s["pool"]["capacityBindingRate"],
                        "premiumsUsd": s["pool"]["premiumsUsd"], "shortfallsUsd": s["pool"]["shortfallsUsd"],
                        "seniorLossEvents": len(s["seniorLossEvents"])})
    return out


def full_sample_cache(eng: Engine, z: pd.DataFrame, daily: dict[str, list[dict]], synth: dict, years: range) -> dict:
    """The in-sample replay: every year uses the sets, joint set and floors built from all the data."""
    ys = build_year_sets(eng, z, daily, 9999, synth)
    return {y: ys for y in years}


def params_doc(p: Params) -> dict:
    return {k: v for k, v in p.__dict__.items()}


def book_doc() -> dict:
    return {"loansPerMarket": N_LOANS, "borrowCapUsdPerMarket": BORROW_CAP_USD, "atLimitShare": 0.3,
            "ltvOtherwise": "uniform on [0.40, LTV_max], seeded per (closure, asset)",
            "coverRule": "above the safe LTV at the Bell: at-the-limit loans buy cover; others buy cover if their index "
                         "is even, else cure to the safe LTV; a cover refused by pool_capacity cures",
            "reopen": "liquidation lot sized and cleared at R = (1 - kappa) x open; the pool pays every shortfall",
            "poolEquity": "held at J0 every epoch; a senior loss is an epoch whose shortfalls exceed J0"}


def _ci(b: dict) -> str:
    if not b.get("trials"):
        return "—"
    return f"{b['breaches']} / {b['trials']} = {b['rate']:.4%} [{b['ci95'][0]:.4%}, {b['ci95'][1]:.4%}], Kupiec p {b['kupiecP']}"


def markdown(doc: dict, fname: str) -> str:
    p = doc["params"]
    L = [f"# Backtest ({doc['vendor']}, data grade `{doc['dataGrade']}`, through {doc['end']})", "",
         f"Machine-readable: `{fname}`. Every safe LTV, premium, loss vector, capacity check, lot and settlement is "
         f"risk-core output through `credence_cal.engine` ({doc['engine']}); this report only counts and sums. "
         f"Method: `credence_cal/backtest.py` (module docstring). Base parameters: α {p['alpha']:.2%}, κ {p['kappa']:.0%}, "
         f"θ {p['theta']:.0%}, c {p['cost_of_cap']:.0%}, η {p['eta']:g}, β {p['beta']:.1%}, u_max {p['u_max']:.0%}, "
         f"pool equity ${p['pool_equity_usd']:,.0f}. Synthetic stress levels (ADR-0204): {doc['syntheticStressLevels']}.", ""]
    for name, key in (("Walk-forward (headline, out of sample)", "walkForward"), ("In-sample (every closure since the data start)", "inSample")):
        s = doc[key]
        pool = s["pool"]
        L += [f"## {name}, from {s['from']}", "",
              f"Breach frequency vs α (a breach: the realised open factor (1 + r)(1 − κ) below the α-quantile safe factor g_α): "
              f"**{_ci(s['breach']['total'])}**, expected {s['breach']['total'].get('expected', 0)}.", "",
              "| Closure type | breaches / trials, 95% CI, Kupiec |", "| --- | --- |"]
        for t, b in s["breach"]["byType"].items():
            L.append(f"| {t} | {_ci(b)} |")
        L += ["", "| Asset:type | breaches / trials, 95% CI, Kupiec |", "| --- | --- |"]
        for k, b in s["breach"]["byAssetType"].items():
            L.append(f"| {k} | {_ci(b)} |")
        wy, we = pool["worstYear"], pool["worstEpoch"]
        L += ["", f"Pool: {pool['epochs']} epochs; mean epoch P&L ${pool['meanEpochPnlUsd']:,.2f} (sd ${pool['sdEpochPnlUsd']:,.2f}); "
              f"total ${pool['totalPnlUsd']:,.2f}; mean annual return on J0 {pool['annualReturnOnJ0']:.2%}; premiums ${pool['premiumsUsd']:,.2f}; "
              f"shortfalls ${pool['shortfallsUsd']:,.2f}; liquidations {pool['liquidations']}.", "",
              f"Epoch P&L quantiles (USD): {pool['quantilesUsd']}.", "",
              f"Worst epoch: {we['date']} ({we['type']}) ${we['pnlUsd']:,.2f}, shortfall ${we['shortfallUsd']:,.2f} ({we['shareOfJ0']:.2%} of J0). "
              f"Worst year: {wy['year']} ${wy['pnlUsd']:,.2f}.", "",
              f"Capacity binding rate (epochs with at least one cover refused): {pool['capacityBindingRate']:.2%} "
              f"(weekend and holiday closures only: {pool['capacityBindingRateNonOvernight']:.2%}); "
              f"{pool['coverRefused']} of {pool['coverRequests']} cover requests refused.", "",
              f"Senior-loss events: {len(s['seniorLossEvents'])}" + (": " + ", ".join(f"{e['date']} (${e['seniorLossUsd']:,.2f})" for e in s["seniorLossEvents"]) if s["seniorLossEvents"] else " (none)."), "",
              "Largest shortfall epochs: " + (", ".join(f"{e['date']} {e['type']} ${e['shortfallUsd']:,.2f}" for e in s["worstShortfallEpochs"]) or "none") + ".", ""]
    L += ["## Sensitivity (walk-forward; one parameter moved from the base at a time)", "",
          "| Parameter | value | breaches / trials | rate | annual return on J0 | premiums | shortfalls | worst epoch | worst year | capacity binding | senior-loss events |",
          "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for r in doc["sensitivity"]:
        L.append(f"| {r['param']} | {r['value']:g} | {r['breaches']} / {r['trials']} | {r['breachRate']:.4%} | {r['annualReturnOnJ0']:.2%} | "
                 f"${r['premiumsUsd']:,.0f} | ${r['shortfallsUsd']:,.0f} | ${r['worstEpochUsd']:,.0f} | ${r['worstYearUsd']:,.0f} | "
                 f"{r['capacityBindingRate']:.2%} | {r['seniorLossEvents']} |")
    return "\n".join(L) + "\n"
