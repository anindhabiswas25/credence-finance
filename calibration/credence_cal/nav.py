"""TBILL:USBANK risk data for the NAV stack (ADR-0118): scenario sets, σ and σ floors, and a joint column, from a
free T-bill ETF proxy. Writes its own bundle, `out/nav/risk-bundle-nav-<sha8>.json`, which is loaded after the
equity bundle (the NAV stack is independent of the equity stack, R-01, and the loader takes one joint file per
bundle). It replaces the local-only fixture of ADR-0116.

What is modelled: the change of the fund's NAV from one USBANK NAV strike to the next. The Credence treasury fund
accrues (it pays no distribution), so the proxy is the ETF's **total return** between the closes of consecutive
USBANK sessions:

    r_s = split_s × (close_s + dividend_s) / close_p − 1        (p → s consecutive USBANK sessions, both with a bar)

typed by the USBANK classifier (OVERNIGHT / WEEKEND / HOLIDAY_WEEKEND), so the types match the NAV asset's clock.
A USBANK session with no ETF bar (Good Friday: the bond market trades, NYSE is shut) makes the span cover two
closures, and it is dropped. An NYSE day that is not a USBANK session (Columbus Day, Veterans Day) is skipped, so
p → s spans it, as the NAV does.

NAV versus price: an ETF close is a traded price, not the NAV. It carries the bid/ask bounce and a small premium or
discount to NAV (a few bp for BIL, less for SGOV), so the proxy's day-to-day variance is *larger* than a NAV's.
For lenders that errs on the safe side (wider sets, a larger σ); the report states the size of the effect.

Then the pipeline's own methods: σ is the §10.6 EWMA (`sigma.py`, bit for bit), z = r / σ ex ante; a set pools the
z of every proxy (BIL, then SGOV from its listing), pads a type below N_MIN with the adjacent shorter type
(HOLIDAY_WEEKEND ← WEEKEND ← OVERNIGHT; all are standardised by their own type's σ, the KS distance is reported),
thins to N_MAX, quantises down and takes the t₃ tail floor (ADR-0203/0204). The σ floor is the long-run 25th
percentile of BIL's published σ.

Joint column (K = kStress rows, the NAV pool is the only reader): two synthetic stress rows first, then BIL's worst
non-overnight z, worst first:
  - `navMaxDrop`: the largest one-step NAV drop the oracle still accepts (NAV_MAX_DROP = 0.5 %, R-23; a larger drop
    halts the asset), in units of the published WEEKEND σ;
  - `setAlpha`: the WEEKEND set's own α-quantile.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

from . import data as data_mod
from . import sets as sets_mod
from . import sigma as sigma_mod
from .calendar import _classify, _session_days
from .common import DATA, MANIFESTS, OUT, ClosureType, canonical_json, keccak256, load_env, sha256_hex, write_json

ASSET = "TBILL:USBANK"
PROXIES = ("BIL", "SGOV")  # SPDR 1-3 Month T-Bill ETF (2007), iShares 0-3 Month Treasury Bond ETF (2020)
MAIN = "BIL"
VENDOR = "alpaca"
NAV_MAX_DROP = 0.005  # OracleAdapter.NAV_MAX_DROP (R-23)
Z_CLIP = sets_mod.Z_CLIP
PAD_FROM = {int(ClosureType.HOLIDAY_WEEKEND): [2, 1], int(ClosureType.WEEKEND): [1], int(ClosureType.OVERNIGHT): []}


def asset_id() -> str:
    return "0x" + keccak256(ASSET.encode()).hex()


def manifest_path() -> Path:
    return MANIFESTS / "data-alpaca-nav.json"


# ── data: its own pinned manifest, so the equity manifest is never rewritten ─────────────────────────────────

def pull(end: str) -> None:
    from .vendors import Alpaca

    v = Alpaca(load_env())
    out = data_mod.raw_dir(VENDOR)
    out.mkdir(parents=True, exist_ok=True)
    entries = {}
    for s in PROXIES:
        df = v.daily(s, data_mod.START[VENDOR], end)
        df.to_parquet(out / f"{s}.parquet", index=False)
        entries[s] = {"rows": len(df), "first": df["date"].iloc[0], "last": df["date"].iloc[-1],
                      "dividends": int((df["dividend"] != 0.0).sum()), "splits": int((df["split_ratio"] != 1.0).sum()),
                      "contentSha256": data_mod.content_sha(df)}
        print(f"{s:5} {len(df)} rows {entries[s]['first']} .. {entries[s]['last']}", flush=True)
    write_json(manifest_path(), {"vendor": VENDOR, "licence": data_mod.LICENCE[VENDOR],
                                 "pulledAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                 "window": {"start": data_mod.START[VENDOR], "end": end}, "asset": ASSET,
                                 "symbols": entries})


def verify() -> dict:
    m = json.loads(manifest_path().read_text())
    for s, e in m["symbols"].items():
        got = data_mod.content_sha(pd.read_parquet(data_mod.raw_dir(VENDOR) / f"{s}.parquet"))
        if got != e["contentSha256"]:
            raise SystemExit(f"{s}: raw data does not match {manifest_path().name}")
    return m


# ── returns, σ, z ─────────────────────────────────────────────────────────────────────────────────────────────

def usbank(end: str) -> tuple[list[dt.date], set[dt.date]]:
    e = dt.date.fromisoformat(end)
    days, holidays, _ = _session_days("USBANK", dt.date(2000, 1, 1), e)
    return [d for d in days if d <= e], holidays


def returns(symbol: str, raw: pd.DataFrame, sessions: list[dt.date], holidays: set[dt.date]) -> tuple[pd.DataFrame, dict]:
    raw = raw.copy()
    raw["d"] = pd.to_datetime(raw["date"]).dt.date
    bars = raw.set_index("d")
    first = bars.index.min()
    idx = [d for d in sessions if d >= first]
    rows, spans = [], []
    for p, s in zip(idx, idx[1:]):
        if s not in bars.index:
            spans.append(str(s))
            continue
        if p not in bars.index:
            continue
        b, c_prev = bars.loc[s], float(bars.loc[p, "close"])
        r = float(b["split_ratio"]) * (float(b["close"]) + float(b["dividend"])) / c_prev - 1.0
        rows.append({"symbol": symbol, "date": str(s), "prev": str(p), "type": int(_classify(p, s, holidays)), "r": r})
    g = pd.DataFrame(rows, columns=["symbol", "date", "prev", "type", "r"])
    return g, {"symbol": symbol, "firstBar": str(first), "spansDropped": spans,
               "n": {ClosureType(t).name: int((g["type"] == t).sum()) for t in (1, 2, 3)}}


def premium_noise(raw: pd.DataFrame) -> dict:
    """The price-vs-NAV effect, measured without a NAV series: the lag-1 autocorrelation of daily total returns.
    Bid/ask bounce and a mean-reverting premium make it negative; −ρ₁ ≈ the share of the variance that is price
    noise a NAV would not have (Roll 1984)."""
    c = raw["close"].to_numpy(dtype=float)
    sr = raw["split_ratio"].to_numpy(dtype=float)[1:]
    r = sr * (c[1:] + raw["dividend"].to_numpy(dtype=float)[1:]) / c[:-1] - 1.0
    r = r - r.mean()
    rho1 = float((r[1:] * r[:-1]).sum() / (r * r).sum())
    return {"lag1Autocorrelation": round(rho1, 4), "noiseShareOfVariance": round(max(0.0, -2.0 * rho1), 4),
            "dailyStdBp": round(float(r.std()) * 1e4, 3)}


# ── sets and joint column ─────────────────────────────────────────────────────────────────────────────────────

def build_set(z: pd.DataFrame, t: int, alpha: float) -> tuple[np.ndarray, dict]:
    own = [(s, z.loc[(z["symbol"] == s) & (z["type"] == t), "z"].dropna().to_numpy()) for s in PROXIES]
    own = [(s, v) for s, v in own if len(v)]
    pool = np.concatenate([v for _, v in own])
    padded: dict[str, int] = {}
    for u in PAD_FROM[t]:
        if len(pool) >= sets_mod.N_MIN:
            break
        extra = z.loc[(z["type"] == u), "z"].dropna().to_numpy()
        padded[ClosureType(u).name] = int(len(extra))
        ks = round(float(stats.ks_2samp(pool, extra).statistic), 4)
        padded[f"ks{ClosureType(u).name.title()}"] = ks
        pool = np.concatenate([pool, extra])
    q_hist = sets_mod.quantise(sets_mod.thin(pool, sets_mod.N_MAX))
    q, moved = sets_mod.tail_floor(q_hist)
    n = len(q)
    i_star = max(0, math.ceil(alpha * n) - 1)
    return q, {"closureType": ClosureType(t).name, "n": int(n), "poolSize": int(len(pool)),
               "contributors": {s: int(len(v)) for s, v in own}, "paddedWith": padded,
               "tail": {"iStar": i_star, "zAlpha": int(q[i_star]), "zMin": int(q[0]), "zAlphaHistory": int(q_hist[i_star]),
                        "t3FloorValuesMoved": moved}}


def joint_column(z: pd.DataFrame, k: int, sigma_weekend: float, weekend_set: np.ndarray, alpha: float) -> tuple[np.ndarray, dict]:
    hist = z[(z["symbol"] == MAIN) & (z["type"] != int(ClosureType.OVERNIGHT))].dropna(subset=["z"])
    hist = hist.sort_values("z", kind="mergesort")
    synth = [("navMaxDrop", math.floor(-NAV_MAX_DROP / sigma_weekend * 1000.0)),
             ("setAlpha", int(weekend_set[max(0, math.ceil(alpha * len(weekend_set)) - 1)]))]
    synth.sort(key=lambda x: x[1])
    take = hist.iloc[:k - len(synth)]
    col = np.array([v for _, v in synth] + [math.floor(x * 1000.0) for x in take["z"]], dtype=np.int64)
    col = np.clip(col, -Z_CLIP, Z_CLIP)
    rows = [{"row": name, "type": "SYNTHETIC", "z": int(np.clip(v, -Z_CLIP, Z_CLIP))} for name, v in synth] + \
           [{"date": d, "type": ClosureType(int(t)).name, "z": round(float(x), 4)}
            for d, t, x in zip(take["date"], take["type"], take["z"])]
    return col, {"k": int(len(col)), "candidates": int(len(hist)), "rows": rows,
                 "navMaxDrop": {"drop": NAV_MAX_DROP, "sigmaWeekend": sigma_weekend}}


# ── the stage ─────────────────────────────────────────────────────────────────────────────────────────────────

def stage(out: Path = OUT, equity_bundle: Path | None = None) -> Path:
    from .engine import default_engine
    from .setfile import write_chain_file

    m = verify()
    end = m["window"]["end"]
    eq = equity_bundle or next(out.glob("risk-bundle-*.json"))
    params = json.loads(eq.read_text())["params"]
    alpha = int(params["alpha"]) / 1e18
    sessions, holidays = usbank(end)
    zs, quality, noise, main_state, main_daily = [], {}, {}, None, None
    for s in PROXIES:
        raw = data_mod.load_raw(VENDOR, s)
        g, q = returns(s, raw, sessions, holidays)
        rep, st, daily = sigma_mod.replay(g.sort_values("date").reset_index(drop=True))
        zs.append(rep)
        quality[s], noise[s] = q, premium_noise(raw)
        if s == MAIN:
            main_state, main_daily = st, daily
    z = pd.concat(zs, ignore_index=True)
    fl = sigma_mod.floors(main_daily)
    cur = {t: max(main_state.sigma(t), fl[t]) for t in (1, 2, 3)}

    eng = default_engine()
    d = out / "nav"
    for old in list(d.glob("*.json")) if d.exists() else []:
        old.unlink()
    sets, infos = {}, []
    for t in (1, 2, 3):
        q, info = build_set(z, t, alpha)
        meta = {"vendor": VENDOR, "dataGrade": m["licence"]["grade"], "dataEnd": end, "proxies": list(PROXIES),
                "method": "ADR-0118 (TBILL NAV proxy), ADR-0203/0204 (thinning, t3 tail floor)", **info}
        doc = eng.build_set(ASSET, t, [int(v) for v in q], meta)
        p = write_chain_file(d, doc)
        sets[t] = q
        infos.append({**info, "file": p.name, "scenarioHash": doc["scenarioHash"]})
    col, jinfo = joint_column(z, int(params["kStress"]), cur[2], sets[2], alpha)
    jdoc = eng.build_joint([(ASSET, [int(v) for v in col])],
                           {"vendor": VENDOR, "dataGrade": m["licence"]["grade"], "dataEnd": end,
                            "method": "ADR-0118", **jinfo})
    jp = write_chain_file(d, jdoc)

    aid = asset_id()
    bundle = {"format": "credence.risk-bundle/v1", "params": params,
              "scenarioSets": [i["file"] for i in infos], "jointSet": jp.name,
              "sigmaFloors": {"assetIds": [aid] * 3, "closureTypes": [1, 2, 3], "floors": [str(sigma_mod.to_wad(fl[t])) for t in (1, 2, 3)]},
              "sigmas": {"assetIds": [aid] * 3, "closureTypes": [1, 2, 3], "values": [str(sigma_mod.to_wad(cur[t])) for t in (1, 2, 3)]},
              "meta": {"asset": ASSET, "dataGrade": m["licence"]["grade"], "sigmaAsOf": end, "adr": "ADR-0118",
                       "note": "TBILL:USBANK for the NAV stack, loaded AFTER the equity bundle; params are a copy of "
                               f"{eq.name} (reloading them changes nothing). Replaces the ADR-0116 local fixture."}}
    h = sha256_hex(canonical_json(bundle))[:8]
    for old in d.glob("risk-bundle-nav-*.json"):
        old.unlink()
    bpath = d / f"risk-bundle-nav-{h}.json"
    write_json(bpath, bundle)
    eng.validate_file(bpath)

    # validation: the share of each proxy's own z below the set's α-quantile (a set is not too mild if ≤ α)
    val = {}
    for t, info in zip((1, 2, 3), infos):
        za = info["tail"]["zAlpha"] / 1000.0
        val[ClosureType(t).name] = {s: {"n": int(v.size), "belowZAlpha": int((v < za).sum()),
                                        "share": round(float((v < za).mean()), 5) if v.size else None,
                                        "worstZ": round(float(v.min()), 3) if v.size else None}
                                    for s in PROXIES
                                    for v in [z.loc[(z["symbol"] == s) & (z["type"] == t), "z"].dropna().to_numpy()]}
    report = {"kind": "credence.nav-calibration.v1", "asset": ASSET, "assetId": aid, "end": end, "alpha": alpha,
              "quality": quality, "priceVsNav": noise, "sigmaWad": {ClosureType(t).name: str(sigma_mod.to_wad(cur[t])) for t in (1, 2, 3)},
              "floorWad": {ClosureType(t).name: str(sigma_mod.to_wad(fl[t])) for t in (1, 2, 3)},
              "sets": infos, "joint": {"file": jp.name, **{k: v for k, v in jinfo.items() if k != "rows"},
                                       "worstRows": jinfo["rows"][:8]},
              "validation": val, "bundle": bpath.name}
    write_json(d / "nav-report.json", report)
    (d / "README.md").write_text(markdown(report))
    print(f"nav: {ASSET} sets {[i['n'] for i in infos]}, joint K={jinfo['k']} -> nav/{bpath.name}")
    return bpath


def markdown(r: dict) -> str:
    L = [f"# TBILL:USBANK risk data (ADR-0118), data through {r['end']}", "",
         f"Bundle: `{r['bundle']}` (load after the equity bundle). Proxies: {', '.join(PROXIES)} (Alpaca SIP daily, free).", "",
         "| Closure | σ (published) | σ floor | set n | pool | z_α (set) | z_min (set) | padded with |",
         "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for s in r["sets"]:
        n = s["closureType"]
        L.append(f"| {n} | {int(r['sigmaWad'][n]) / 1e16:.4f} % | {int(r['floorWad'][n]) / 1e16:.4f} % | {s['n']} | "
                 f"{s['poolSize']} | {s['tail']['zAlpha'] / 1000:.3f} | {s['tail']['zMin'] / 1000:.3f} | "
                 f"{', '.join(f'{k} {v}' for k, v in s['paddedWith'].items()) or '—'} |")
    L += ["", "## Price versus NAV", "",
          "An ETF close is a traded price. Its bid/ask bounce and premium/discount add variance a NAV does not have, "
          "so these sets and σ are wider than the fund's (the safe side for lenders). No free daily NAV series is "
          "available to measure the difference directly; the Roll estimate below (−2ρ₁, from the lag-1 "
          "autocorrelation of daily total returns) is the free proxy. A value near 0 means the bounce is not "
          "measurable at a daily horizon; the proxy's variance is then used as it is.", "",
          "| Proxy | daily σ (bp) | lag-1 autocorrelation | ≈ noise share of variance |", "| --- | ---: | ---: | ---: |"]
    for s, v in r["priceVsNav"].items():
        L.append(f"| {s} | {v['dailyStdBp']} | {v['lag1Autocorrelation']} | {v['noiseShareOfVariance']:.0%} |")
    L += ["", "## Validation (own history below the set's z_α; α = %.3f %%)" % (r["alpha"] * 100), "",
          "| Closure | Proxy | n | below z_α | share | worst z |", "| --- | --- | ---: | ---: | ---: | ---: |"]
    for t, per in r["validation"].items():
        for s, v in per.items():
            L.append(f"| {t} | {s} | {v['n']} | {v['belowZAlpha']} | {v['share']} | {v['worstZ']} |")
    L += ["", f"Joint column: K = {r['joint']['k']} ({r['joint']['candidates']} BIL non-overnight closures ranked); "
          "worst rows:", ""] + [f"- {json.dumps(x)}" for x in r["joint"]["worstRows"]] + ["",
          f"`navMaxDrop` = −{NAV_MAX_DROP:.1%} / σ_WEEKEND, clipped to the int16 range (−32.767 σ): with σ_WEEKEND "
          f"= {int(r['sigmaWad']['WEEKEND']) / 1e16:.4f} % it stands for a "
          f"{min(NAV_MAX_DROP, 32.767 * int(r['sigmaWad']['WEEKEND']) / 1e18):.3%} drop."]
    return "\n".join(L) + "\n"


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="credence_cal.nav")
    ap.add_argument("cmd", choices=["pull", "verify", "build"])
    ap.add_argument("--end", default=None, help="last date to pull (default: the equity manifest's end)")
    ap.add_argument("--out", type=Path, default=OUT)
    a = ap.parse_args(argv)
    if a.cmd == "pull":
        pull(a.end or json.loads(data_mod.manifest_path(VENDOR).read_text())["window"]["end"])
    elif a.cmd == "verify":
        print(f"{len(verify()['symbols'])} proxies match {manifest_path().name}")
    else:
        stage(a.out)


if __name__ == "__main__":
    sys.exit(main())
