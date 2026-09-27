"""Synthetic CI sample (ADR-0201): no vendor data may be committed, so CI runs the whole pipeline on
prices generated here. `python -m credence_cal.sample` regenerates `calibration/sample/*.csv`; the
pipeline only ever reads the committed CSV, so a numpy upgrade cannot change CI hashes.

Model: per symbol, a GARCH(1,1)-like variance on log returns; the overnight gap is Student-t(4) scaled
by the closure type (weekend × 1.25, holiday × 1.1 in sd), plus rare jump days; the intraday move is
normal. A 3:1 split on NVDA and quarterly dividends on AAPL/MSFT/SPY exercise the adjustments. COIN
starts at its real listing date so the joint back-fill is exercised.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from .common import SAMPLE, sha256_hex
from .vendors import COLUMNS

START, END = "2016-01-04", "2023-12-29"
SYMBOLS = {  # symbol: (start, base sd of the gap, start price)
    "NVDA": (START, 0.016, 30.0), "AAPL": (START, 0.011, 25.0), "MSFT": (START, 0.011, 55.0),
    "TSLA": (START, 0.021, 45.0), "COIN": ("2021-04-14", 0.030, 380.0), "SPY": (START, 0.006, 200.0),
    "AMD": (START, 0.021, 3.0), "MSTR": (START, 0.024, 150.0), "QQQ": (START, 0.008, 105.0),
}
SPLITS = {("NVDA", "2019-06-03"): 3.0}
DIVIDENDS = {"AAPL": 0.20, "MSFT": 0.35, "SPY": 1.10}


def generate() -> None:
    from .gaps import xnys
    from .calendar import _classify

    sessions, holidays = xnys(START, END)
    rng = np.random.default_rng(20260928)
    market = rng.standard_t(4, size=len(sessions)) / np.sqrt(2.0)
    SAMPLE.mkdir(parents=True, exist_ok=True)
    for sym, (start, sd, px) in SYMBOLS.items():
        days = [d for d in sessions if d.isoformat() >= start]
        off = len(sessions) - len(days)
        h, close, rows = sd * sd, px, []
        for i, d in enumerate(days):
            t = int(_classify(days[i - 1], d, holidays)) if i else 1
            mult = {1: 1.0, 2: 1.25, 3: 1.1}[t]
            eps = 0.6 * market[off + i] + 0.8 * rng.standard_t(4) / np.sqrt(2.0)
            if rng.random() < 0.004:
                eps *= 6.0
            gap = np.sqrt(h) * mult * eps
            h = 0.02 * sd * sd + 0.08 * gap * gap + 0.90 * h
            split = SPLITS.get((sym, d.isoformat()), 1.0)
            div = DIVIDENDS.get(sym, 0.0) if (d.month in (2, 5, 8, 11) and 8 <= d.day <= 12 and d.weekday() == 2) else 0.0
            open_ = max(0.01, (close * (1.0 + gap)) / split - div)
            c = max(0.01, open_ * float(np.exp(rng.normal(0.0, sd * 0.9))))
            hi, lo = max(open_, c) * (1.0 + abs(rng.normal(0, sd / 3))), min(open_, c) * (1.0 - abs(rng.normal(0, sd / 3)))
            rows.append([d.isoformat(), round(open_, 4), round(hi, 4), round(lo, 4), round(c, 4),
                         float(int(rng.integers(1_000_000, 50_000_000))), split, div])
            close = rows[-1][4]
        pd.DataFrame(rows, columns=COLUMNS).to_csv(SAMPLE / f"{sym}.csv", index=False, lineterminator="\n")
    print(f"wrote {len(SYMBOLS)} synthetic symbols to {SAMPLE}")


def sample_frame(symbol: str) -> pd.DataFrame:
    return pd.read_csv(SAMPLE / f"{symbol}.csv", dtype={"date": str})


def manifest() -> dict:
    syms = {}
    for s in SYMBOLS:
        p = SAMPLE / f"{s}.csv"
        syms[s] = {"rows": int(len(sample_frame(s))), "fileSha256": sha256_hex(p.read_bytes())}
    return {"vendor": "sample", "licence": {"grade": "synthetic", "terms": "synthetic, credence_cal.sample"},
            "window": {"start": START, "end": END}, "symbols": syms}


if __name__ == "__main__":
    generate()
