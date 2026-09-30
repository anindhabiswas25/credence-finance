"""The calibration pipeline driver (§10.6). `make cal-all` = `python -m credence_cal.pipeline all`.

    python -m credence_cal.pipeline all      [--vendor alpaca|tiingo|sample] [--out DIR]   (every stage)
    python -m credence_cal.pipeline core     [...]   (gaps, sigma, sets, validation: fast; the CI sample check)
    python -m credence_cal.pipeline <stage>  (gaps | sigma | sets | validation | backtest | proposal)

Stages read the pinned raw data (checked against the committed manifest first) and write
content-addressed JSON under `--out` (default `calibration/out`). Intermediate tables go to
`calibration/data/work/<vendor>/` (git-ignored). `out/HASHES.<vendor>.json` lists the sha256 of every
output file; CI compares it with the committed copy.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from . import data as data_mod
from . import gaps as gaps_mod
from . import sigma as sigma_mod
from .common import (ASSET_GROUP, DATA, GROUPS, LISTED, OUT, ClosureType, asset_id, sha256_hex, universe,
                     write_addressed, write_json)

# Comparable names contribute to pooled sets only from this date (ADR-0203): before it RIOT and MARA were
# micro-cap shells (RIOT's 2016-03-31 +670% bar is an unadjusted reverse split), not crypto proxies.
COMPARABLE_FROM = {"RIOT": "2021-01-01", "MARA": "2021-01-01"}


@dataclass
class Ctx:
    vendor: str
    out: Path
    work: Path
    end: str
    manifest: dict

    @classmethod
    def make(cls, vendor: str, out: Path | None) -> "Ctx":
        if vendor == "sample":
            from .sample import manifest as sample_manifest

            m = sample_manifest()
        else:
            m = data_mod.verify(vendor)
        work = DATA / "work" / vendor
        work.mkdir(parents=True, exist_ok=True)
        return cls(vendor, out or OUT, work, m["window"]["end"], m)

    def symbols(self) -> list[str]:
        return [s for s in universe() if s in self.manifest["symbols"]]

    @property
    def grade(self) -> str:
        return self.manifest["licence"]["grade"]


def stage_gaps(c: Ctx) -> None:
    sessions, holidays = gaps_mod.xnys("2000-01-01", c.end)
    frames, quality = [], {}
    for s in c.symbols():
        g, q = gaps_mod.compute(s, data_mod.load_raw(c.vendor, s), sessions, holidays)
        frames.append(g)
        quality[s] = {**q, "stats": gaps_mod.summary_stats(g)}
    allg = pd.concat(frames, ignore_index=True)
    allg.to_parquet(c.work / "gaps.parquet", index=False)
    doc = {"kind": "credence.quality.v1", "dataGrade": c.grade, "vendor": c.vendor, "end": c.end,
           "outlierAbsR": gaps_mod.OUTLIER_ABS_R, "comparableFrom": COMPARABLE_FROM, "symbols": quality}
    p, _ = write_addressed(c.out / "quality", "quality", doc)
    (c.out / "quality" / "README.md").write_text(quality_markdown(doc, p.name))
    print(f"gaps: {len(allg)} rows; quality -> {p.relative_to(c.out.parent) if c.out.parent in p.parents else p}")


def quality_markdown(doc: dict, fname: str) -> str:
    L = [f"# Data-quality report ({doc['vendor']}, data grade `{doc['dataGrade']}`, through {doc['end']})", "",
         f"Machine-readable: `{fname}`. Outliers are |r| > {doc['outlierAbsR']:.0%}; they are flagged, never dropped.", "",
         "| Symbol | First session | Overnight | Weekend | Holiday | Missing sessions | Zero-volume | Bad bars | Outliers | Suspect splits |",
         "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for s, q in doc["symbols"].items():
        g = q["gaps"]
        L.append(f"| {s} | {q['firstSession']} | {g['OVERNIGHT']} | {g['WEEKEND']} | {g['HOLIDAY_WEEKEND']} | "
                 f"{len(q['missingSessions'])} | {len(q['zeroVolumeDays'])} | {len(q['badBars'])} | {len(q['outliers'])} | "
                 f"{', '.join(q['suspectUnadjustedSplits']) or '—'} |")
    L += ["", "## Outliers of the listed assets", "", "| Symbol | Date | Closure | r |", "| --- | --- | --- | ---: |"]
    for s in LISTED:
        for o in doc["symbols"].get(s, {}).get("outliers", []):
            L.append(f"| {s} | {o['date']} | {o['type']} | {o['r']:+.2%} |")
    return "\n".join(L) + "\n"


def stage_sigma(c: Ctx) -> None:
    g = pd.read_parquet(c.work / "gaps.parquet")
    zs, assets, per_name = [], {}, []
    for s in c.symbols():
        gs = g[(g["symbol"] == s) & (g["date"] >= COMPARABLE_FROM.get(s, ""))].sort_values("date").reset_index(drop=True)
        rep, st, daily = sigma_mod.replay(gs)
        zs.append(rep)
        per_name.append(gs)
        if s in LISTED:
            fl = sigma_mod.floors(daily)
            cur = {t: max(st.sigma(t), fl[t]) for t in (1, 2, 3)}
            assets[s] = {
                "assetId": asset_id(s),
                "state": sigma_mod.snapshot(st, gs["date"].iloc[-1]),
                "floorWad": {ClosureType(t).name: str(sigma_mod.to_wad(fl[t])) for t in (1, 2, 3)},
                "sigmaWad": {ClosureType(t).name: str(sigma_mod.to_wad(cur[t])) for t in (1, 2, 3)},
                "publishedDays": len(daily),
            }
    z = pd.concat(zs, ignore_index=True)
    z.to_parquet(c.work / "z.parquet", index=False)
    doc = {"kind": "credence.sigma.v1", "dataGrade": c.grade, "vendor": c.vendor, "end": c.end,
           "method": {"spec": "calibration/docs/sigma.md", "lambda": repr(sigma_mod.LAM), "w": repr(sigma_mod.W),
                      "seed": {str(k): v for k, v in sigma_mod.SEED.items()}, "warmOvernight": sigma_mod.WARM_N1,
                      "impliedVol": "off (no licensed IV source in v1)", "floorQuantile": "0.25"},
           "blendEvaluation": sigma_mod.evaluate(per_name),
           "assets": assets}
    p, _ = write_addressed(c.out / "sigma", "sigma", doc)
    print(f"sigma: z for {int(z['z'].notna().sum())} gaps; calibration -> {p.name}")


def stage_sets(c: Ctx) -> None:
    from . import sets as sets_mod
    from .engine import default_engine
    from .setfile import joint_document, set_document, write_chain_file

    eng = default_engine()
    for d in ("scenarios", "joint"):  # this stage owns both directories: drop every older file first
        for old in (c.out / d).glob("*.json"):
            old.unlink()
    z = _pooled_z(c)
    index = []
    for a in LISTED:
        for t in (1, 2, 3):
            q, info = sets_mod.build_set(z, a, t)
            doc = set_document(eng, a, t, q, info, c)
            p = write_chain_file(c.out / "scenarios", doc)
            index.append({**info, "file": p.name, "scenarioHash": doc["scenarioHash"]})
    cols, jinfo = sets_mod.joint(z)
    jp = write_chain_file(c.out / "joint", joint_document(eng, cols, jinfo, c))
    write_json(c.work / "sets-index.json", {"sets": index, "joint": {**jinfo, "file": jp.name}})
    (c.out / "scenarios" / "README.md").write_text(sets_markdown(index, jinfo, jp.name, c))
    print(f"sets: {len(index)} scenario sets, joint K={jinfo['k']} -> {jp.name}")


def sets_markdown(index: list[dict], jinfo: dict, jname: str, c: Ctx) -> str:
    from . import sets as sets_mod

    L = [f"# Scenario sets ({c.vendor}, data grade `{c.grade}`, through {c.end})", "",
         "Pooling rule and its effect on the tail: ADR-0203. Tail floor (the more severe of history and the t₃ "
         "stand-in below the 2.5% quantile): ADR-0204. z in thousandths of σ; i* = ceil(α N) − 1 at α = 0.1%.", "",
         "| Asset | Closure | N | Pool | z at i* (set) | pooled history | t₃ | values moved by t₃ | min (set) | own N | z at α (own only) | min (own) | padded with weekend | File |",
         "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"]
    for x in index:
        t = x["tail"]
        pad = ", ".join(x["paddedWithWeekend"]) or "—"
        L.append(f"| {x['asset']} | {x['closureType']} | {x['n']} | {x['poolSize']} | {t['zAlphaPooled']} | {t['zAlphaHistory']} | "
                 f"{t['zAlphaT3']} | {t['t3FloorValuesMoved']} | {t['zMinPooled']} | "
                 f"{t['ownN']} | {t['zAlphaOwn']} | {t['zMinOwn']} | {pad} | `{x['file']}` |")
    L += ["", f"## Joint stress set (`{jname}`)", "",
          f"K = {jinfo['k']} worst of {jinfo['candidates']} non-overnight closures ({jinfo['firstClosure']} → {jinfo['lastClosure']}), "
          f"ranked by {jinfo['ranking']}. Back-fill: {jinfo['betaMethod']}.", "",
          "| Asset | β to SPY (z) | back-filled closures |", "| --- | ---: | ---: |"]
    for a, b in jinfo["beta"].items():
        L.append(f"| {a} | {b:.3f} | {jinfo['backfilled'][a]} |")
    syn = jinfo["synthetic"]
    if syn.get("levels"):
        L += ["", f"Synthetic stress closures (ADR-0204): {syn['method']}"
              + (f"; GPD over the worst {sets_mod.SYNTH_TAIL:.0%} of basket z ({syn['exceedances']} exceedances, ξ = {syn['xi']}, "
                 f"scale {syn['scale']}, {syn['closuresPerYear']} closures/year, worst observed −{syn['worstObserved']})" if "xi" in syn else "")
              + f". Shapes: the worst historical closure ({syn['worstHistoricalShapeFrom']}) scaled, and all assets equal.", "",
              "| Horizon | years | closures | basket z |", "| --- | ---: | ---: | ---: |"]
        for h, v in syn["levels"].items():
            L.append(f"| {h} | {v.get('years', '—')} | {v.get('closures', '—')} | {v['basketZ']} |")
    L += ["", "Worst ten:", "", "| # | Reopen session | Closure | basket mean z |", "| ---: | --- | --- | ---: |"]
    for i, x in enumerate(jinfo["closures"][:10]):
        L.append(f"| {i + 1} | {x['date']} | {x['type']} | {x['basketZ']:.3f} |")
    return "\n".join(L) + "\n"


def _pooled_z(c: Ctx) -> pd.DataFrame:
    z = pd.read_parquet(c.work / "z.parquet")
    return z[[d >= COMPARABLE_FROM.get(s, "") for s, d in zip(z["symbol"], z["date"])]]


def stage_validation(c: Ctx) -> None:
    """Model validation note (ADR-0204): the sets against the t₃ stand-in, through risk-core."""
    from . import sets as sets_mod
    from . import validation
    from .engine import default_engine

    z = _pooled_z(c)
    sigma_doc = json.loads(next((c.out / "sigma").glob("sigma-*.json")).read_text())
    cols, jinfo = sets_mod.joint(z)
    doc = {"kind": "credence.validation.v1", "dataGrade": c.grade, "vendor": c.vendor, "end": c.end,
           **validation.run(default_engine(), z, sigma_doc, cols, jinfo)}
    p, _ = write_addressed(c.out / "validation", "validation", doc)
    (c.out / "validation" / "README.md").write_text(validation.markdown(doc, p.name, c.grade, c.end))
    print(f"validation: {len(doc['sets'])} sets vs t3 -> {p.name}")


def backtest_inputs(c: Ctx) -> tuple[pd.DataFrame, dict, dict]:
    """(pooled z table with the ex-ante σ, per-asset daily σ series, synthetic stress levels)."""
    from . import sets as sets_mod

    z = _pooled_z(c)
    gaps = pd.read_parquet(c.work / "gaps.parquet")
    daily = {}
    for a in LISTED:
        gs = gaps[gaps["symbol"] == a].sort_values("date").reset_index(drop=True)
        daily[a] = sigma_mod.replay(gs)[2]
    _, jinfo = sets_mod.joint(z)
    synth = {h: v["basketZ"] for h, v in jinfo["synthetic"]["levels"].items()}
    return z, daily, synth


def stage_backtest(c: Ctx, end: str = "9999-12-31") -> None:
    """§10.6 step 7 through risk-core (credence_cal.engine): walk-forward from START_YEAR (headline), an
    in-sample replay of every closure since the data start, and the parameter sensitivity."""
    from . import backtest as bt
    from .engine import default_engine

    eng = default_engine()
    z, daily, synth = backtest_inputs(c)
    base = bt.Params()
    cache: dict = {}
    wf = bt.run(eng, z, z, daily, base, synth, cache, end=end)
    first = str(z.loc[z["symbol"].isin(list(LISTED)) & z["sigma"].notna(), "date"].min())
    ins_cache = bt.full_sample_cache(eng, z, daily, synth, range(int(first[:4]), int(c.end[:4]) + 1))
    ins = bt.run(eng, z, z, daily, base, synth, ins_cache, start=first, end=end)
    sens = bt.sensitivity(eng, z, z, daily, base, synth, cache, end=end)
    doc = {"kind": "credence.backtest.v1", "dataGrade": c.grade, "vendor": c.vendor, "end": c.end,
           "engine": type(eng).__name__, "params": bt.params_doc(base), "syntheticStressLevels": synth,
           "book": bt.book_doc(), "walkForward": {"from": f"{bt.START_YEAR}-01-01", **bt.summarize(wf)},
           "inSample": {"from": first, **bt.summarize(ins)}, "sensitivity": sens}
    p, _ = write_addressed(c.out / "backtest", "backtest", doc)
    (c.out / "backtest" / "README.md").write_text(bt.markdown(doc, p.name))
    print(f"backtest: {doc['walkForward']['pool']['epochs']} walk-forward epochs, "
          f"{doc['inSample']['pool']['epochs']} in-sample -> {p.name}")


def stage_proposal(c: Ctx) -> None:
    """The S2 testnet proposal: risk bundle (LoadScenarioSet), timelock calldata, reasoning (brief item 7)."""
    from . import proposal
    from .engine import default_engine

    sigma_doc = json.loads(next((c.out / "sigma").glob("sigma-*.json")).read_text())
    bt_path = next((c.out / "backtest").glob("backtest-*.json"))
    val_path = next((c.out / "validation").glob("validation-*.json"))
    bpath, cpath, bundle = proposal.build(c.out, sigma_doc, default_engine(), c.grade)
    md = proposal.markdown(json.loads(bt_path.read_text()), json.loads(val_path.read_text()), sigma_doc, bundle,
                           {"bundle": bpath.name, "calldata": cpath.name, "backtest": bt_path.name, "validation": val_path.name})
    (c.out / "proposal" / f"{proposal.PROPOSAL_DATE}.md").write_text(md)
    print(f"proposal: {bpath.name}, {cpath.relative_to(c.out)}, proposal/{proposal.PROPOSAL_DATE}.md")


def stage_nav(c: Ctx) -> None:
    """TBILL:USBANK from the T-bill ETF proxies (ADR-0118): its own pinned manifest, so only for real vendor data."""
    if c.vendor != "alpaca":
        print(f"nav: skipped for vendor {c.vendor} (the proxies are pinned in manifests/data-alpaca-nav.json)")
        return
    from . import nav

    nav.stage(c.out)


def stage_alias(c: Ctx) -> None:
    """Alias assets (ADR-0120): the underlying's risk data under a second collateral token's asset key."""
    from . import alias

    alias.stage(c.out)


STAGES = {"gaps": stage_gaps, "sigma": stage_sigma, "sets": stage_sets, "validation": stage_validation,
          "backtest": stage_backtest, "proposal": stage_proposal, "nav": stage_nav, "alias": stage_alias}
CORE = ("gaps", "sigma", "sets", "validation")  # fast; the CI sample check runs these


def hashes(c: Ctx) -> None:
    files = sorted(p for p in c.out.rglob("*") if p.suffix in (".json", ".md") and not p.name.startswith("HASHES")
                   and "calendars" not in p.parts)
    doc = {str(p.relative_to(c.out)): sha256_hex(p.read_bytes()) for p in files}
    write_json(c.out / f"HASHES.{c.vendor}.json", doc)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="credence_cal.pipeline")
    ap.add_argument("stage", choices=["all", "core", *STAGES])
    ap.add_argument("--vendor", default="alpaca")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    c = Ctx.make(a.vendor, a.out)
    for name, fn in STAGES.items():
        if a.stage == "all" or (a.stage == "core" and name in CORE) or a.stage == name:
            fn(c)
    hashes(c)  # after any stage, so HASHES always describes what is on disk


if __name__ == "__main__":
    sys.exit(main())
