"""The calibration pipeline driver (§10.6). `make cal-all` = `python -m credence_cal.pipeline all`.

    python -m credence_cal.pipeline all      [--vendor alpaca|tiingo|sample] [--out DIR]
    python -m credence_cal.pipeline <stage>  (gaps | sigma | sets | joint | backtest | proposal)

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


STAGES = {"gaps": stage_gaps, "sigma": stage_sigma}


def hashes(c: Ctx) -> None:
    files = sorted(p for p in c.out.rglob("*.json") if not p.name.startswith("HASHES") and "calendars" not in p.parts)
    doc = {str(p.relative_to(c.out)): sha256_hex(p.read_bytes()) for p in files}
    write_json(c.out / f"HASHES.{c.vendor}.json", doc)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="credence_cal.pipeline")
    ap.add_argument("stage", choices=["all", *STAGES])
    ap.add_argument("--vendor", default="alpaca")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    c = Ctx.make(a.vendor, a.out)
    for name, fn in STAGES.items():
        if a.stage in ("all", name):
            fn(c)
    if a.stage == "all":
        hashes(c)


if __name__ == "__main__":
    sys.exit(main())
