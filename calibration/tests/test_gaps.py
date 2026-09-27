"""Gap construction and closure labels on a hand-built frame (no vendor data)."""

import datetime as dt

import pandas as pd

from credence_cal import gaps
from credence_cal.common import ClosureType


def frame(rows):
    return pd.DataFrame(rows, columns=["date", "open", "high", "low", "close", "volume", "split_ratio", "dividend"])


def test_labels_split_dividend_and_missing_bar():
    sessions, holidays = gaps.xnys("2024-06-03", "2024-06-24")
    rows = []
    for d in sessions:
        rows.append([d.isoformat(), 100.0, 101.0, 99.0, 100.0, 1e6, 1.0, 0.0])
    raw = frame(rows)
    # 10:1 split effective 2024-06-10 (a Monday after a weekend)
    raw.loc[raw.date == "2024-06-10", ["open", "high", "low", "close", "split_ratio"]] = [9.9, 10.1, 9.8, 10.0, 10.0]
    later = raw.date > "2024-06-10"
    raw.loc[later, ["open", "high", "low", "close"]] = [10.0, 10.1, 9.9, 10.0]
    raw.loc[raw.date == "2024-06-13", "dividend"] = 0.1
    raw = raw[raw.date != "2024-06-17"]  # missing bar: the gap into 06-18 spans two closures
    g, q = gaps.compute("X", raw, sessions, holidays)
    by = g.set_index("date")
    assert abs(by.loc["2024-06-10", "r"] - (-0.01)) < 1e-12
    assert by.loc["2024-06-10", "type"] == ClosureType.WEEKEND
    assert abs(by.loc["2024-06-13", "r"] - 0.01) < 1e-12
    assert "2024-06-17" in q["missingSessions"] and "2024-06-18" not in set(g.date)
    # Juneteenth (Wed 2024-06-19) is a mid-week holiday: 06-18 -> 06-20 is HOLIDAY_WEEKEND
    assert by.loc["2024-06-20", "type"] == ClosureType.HOLIDAY_WEEKEND
    assert by.loc["2024-06-21", "type"] == ClosureType.OVERNIGHT


def test_xnys_knows_unscheduled_closure():
    sessions, holidays = gaps.xnys("2025-01-02", "2025-01-15")
    assert dt.date(2025, 1, 9) in holidays and dt.date(2025, 1, 9) not in sessions
