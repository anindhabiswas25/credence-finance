"""Exchange-calendar generator (Build Guide §8.2.1, §10.6 step 8).

Produces the `Session[]` that `CalendarStore.appendSessions` consumes, precomputed in UTC so that the
chain never needs timezone or DST logic:

    struct Session {
        uint40 extOpen;                 // start of the extended window before `open`
        uint40 open;                    // regular-session open
        uint40 close;                   // regular-session close (early closes included)
        uint40 extClose;                // end of post-market
        ClosureType closureTypeAfter;   // type of the closure that starts at `close`
    }

Venues:
  XNYS    NYSE (also used for Nasdaq listings). Sessions from `exchange_calendars`.
          Overnight 24/5: 20:00 ET of the previous calendar day -> extOpen of the session.
          Pre-market to 09:30, regular 09:30 -> 16:00 (13:00 on early-close days),
          post-market to 20:00 (17:00 on early-close days, see ADR-0003).
  USBANK  Federal Reserve bank holidays. `open`/`close` bound the issuer's redemption window
          (09:00 -> 17:00 ET, the NAV strike); a 1 h window on either side is EXTENDED (ADR-0003).

Closure classification (`closureTypeAfter`), from this session's close to the next session's open:
  OVERNIGHT        the next session is the next calendar day
  WEEKEND          the only non-session days in between are Saturday and Sunday
  HOLIDAY_WEEKEND  any holiday lies in between (long weekends and mid-week holidays alike)
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path
from zoneinfo import ZoneInfo

import exchange_calendars as xcals
import pandas as pd
from pandas.tseries.holiday import (
    AbstractHolidayCalendar,
    Holiday,
    USColumbusDay,
    USLaborDay,
    USMartinLutherKingJr,
    USMemorialDay,
    USPresidentsDay,
    USThanksgivingDay,
    sunday_to_monday,
)

ET = ZoneInfo("America/New_York")
UTC = dt.timezone.utc
FORMAT_VERSION = 1
UINT40_MAX = (1 << 40) - 1


class ClosureType(IntEnum):
    """Mirror of `enum ClosureType` in contracts/src/libraries/Types.sol (Build Guide §8.1)."""

    NONE = 0
    OVERNIGHT = 1
    WEEKEND = 2
    HOLIDAY_WEEKEND = 3
    HALT = 4
    CORP_ACTION = 5


@dataclass(frozen=True, slots=True)
class Session:
    ext_open: int
    open: int
    close: int
    ext_close: int
    closure_type_after: ClosureType
    date: dt.date  # the session's local (ET) date; not part of the on-chain struct

    def to_json(self) -> dict[str, int]:
        # Field names and order exactly as the Solidity struct.
        return {
            "extOpen": self.ext_open,
            "open": self.open,
            "close": self.close,
            "extClose": self.ext_close,
            "closureTypeAfter": int(self.closure_type_after),
        }


# ── USBANK: Federal Reserve holidays ─────────────────────────────────────────────────────────────
# The Fed observes a Sunday holiday on Monday, but a Saturday holiday is NOT moved to Friday
# (banks are open that Friday), so pandas' USFederalHolidayCalendar (nearest_workday) is wrong here.
class FedHolidayCalendar(AbstractHolidayCalendar):
    rules = [
        Holiday("New Year's Day", month=1, day=1, observance=sunday_to_monday),
        USMartinLutherKingJr,
        USPresidentsDay,
        USMemorialDay,
        Holiday("Juneteenth", month=6, day=19, start_date="2022-01-01", observance=sunday_to_monday),
        Holiday("Independence Day", month=7, day=4, observance=sunday_to_monday),
        USLaborDay,
        USColumbusDay,
        Holiday("Veterans Day", month=11, day=11, observance=sunday_to_monday),
        USThanksgivingDay,
        Holiday("Christmas Day", month=12, day=25, observance=sunday_to_monday),
    ]


def _et(day: dt.date, hour: int, minute: int = 0) -> int:
    """Unix seconds (UTC) of a wall-clock time in America/New_York on `day`."""
    return int(dt.datetime(day.year, day.month, day.day, hour, minute, tzinfo=ET).timestamp())


def _classify(this_day: dt.date, next_day: dt.date, holidays: set[dt.date]) -> ClosureType:
    gap = (next_day - this_day).days
    if gap == 1:
        return ClosureType.OVERNIGHT
    between = [this_day + dt.timedelta(days=i) for i in range(1, gap)]
    if any(d in holidays or d.weekday() < 5 for d in between):
        return ClosureType.HOLIDAY_WEEKEND
    return ClosureType.WEEKEND


def _session_days(venue: str, start: dt.date, end_inclusive_lookahead: dt.date) -> tuple[list[dt.date], set[dt.date], dict]:
    """Session dates in [start, lookahead], the venue's weekday holidays, and XNYS open/close overrides."""
    if venue == "XNYS":
        cal = xcals.get_calendar(
            "XNYS",
            start=(start - dt.timedelta(days=10)).isoformat(),
            end=end_inclusive_lookahead.isoformat(),
        )
        sched = cal.schedule.loc[start.isoformat() : end_inclusive_lookahead.isoformat()]
        days = [ts.date() for ts in sched.index]
        times = {
            ts.date(): (int(row.open.timestamp()), int(row.close.timestamp()))
            for ts, row in sched.iterrows()
        }
        sessions = set(days)
        holidays = {
            d.date()
            for d in pd.date_range(start, end_inclusive_lookahead, freq="D")
            if d.weekday() < 5 and d.date() not in sessions
        }
        return days, holidays, times
    if venue == "USBANK":
        hol = {
            d.date()
            for d in FedHolidayCalendar().holidays(
                start=pd.Timestamp(start) - pd.Timedelta(days=10),
                end=pd.Timestamp(end_inclusive_lookahead),
            )
        }
        days = [
            d.date()
            for d in pd.date_range(start, end_inclusive_lookahead, freq="D")
            if d.weekday() < 5 and d.date() not in hol
        ]
        return days, hol, {}
    raise ValueError(f"unknown venue {venue!r}")


def generate(venue: str, start: dt.date, end: dt.date) -> list[Session]:
    """Sessions whose local date lies in [start, end]. The last session's closure type is classified by
    looking ahead to the following session, which is not emitted (it belongs to the next load)."""
    if end < start:
        raise ValueError("end before start")
    days, holidays, times = _session_days(venue, start, end + dt.timedelta(days=21))
    out: list[Session] = []
    for i, day in enumerate(days):
        if day > end:
            break
        if i + 1 >= len(days):
            raise RuntimeError(f"{venue}: no session after {day} within the lookahead")
        nxt = days[i + 1]
        prev_calendar_day = day - dt.timedelta(days=1)
        if venue == "XNYS":
            open_, close = times[day]
            early_close = close < _et(day, 16)
            ext_open = _et(prev_calendar_day, 20)
            ext_close = _et(day, 17 if early_close else 20)
        else:  # USBANK
            ext_open, open_, close, ext_close = _et(day, 8), _et(day, 9), _et(day, 17), _et(day, 18)
        out.append(
            Session(
                ext_open=ext_open,
                open=open_,
                close=close,
                ext_close=ext_close,
                closure_type_after=_classify(day, nxt, holidays),
                date=day,
            )
        )
    validate(out)
    return out


def validate(sessions: list[Session]) -> None:
    """The CalendarStore rules (§8.2.1), checked before anything is written."""
    for i, s in enumerate(sessions):
        if not (0 < s.ext_open < s.open < s.close < s.ext_close <= UINT40_MAX):
            raise AssertionError(f"session {i} ({s.date}) is not strictly increasing: {s}")
        if s.closure_type_after not in (
            ClosureType.OVERNIGHT,
            ClosureType.WEEKEND,
            ClosureType.HOLIDAY_WEEKEND,
        ):
            raise AssertionError(f"session {i} ({s.date}) has closure type {s.closure_type_after!r}")
        if i:
            p = sessions[i - 1]
            if not s.open > p.close:
                raise AssertionError(f"session {i} ({s.date}) opens before the previous close")
            if not s.ext_open >= p.ext_close:
                raise AssertionError(f"session {i} ({s.date}) extended window overlaps the previous one")


def abi_encode(sessions: list[Session]) -> str:
    """`abi.encode(Session[])`: offset, length, then 5 static words per session."""
    words = [0x20, len(sessions)]
    for s in sessions:
        words += [s.ext_open, s.open, s.close, s.ext_close, int(s.closure_type_after)]
    return "0x" + b"".join(w.to_bytes(32, "big") for w in words).hex()


def document(venue: str, start: dt.date, end: dt.date, sessions: list[Session]) -> dict:
    body = [s.to_json() for s in sessions]
    canonical = json.dumps(body, separators=(",", ":")).encode()
    return {
        "formatVersion": FORMAT_VERSION,
        "venue": venue,
        "from": start.isoformat(),
        "to": end.isoformat(),
        "timezone": "UTC unix seconds",
        "closureTypeEnum": {t.name: int(t) for t in ClosureType},
        "count": len(sessions),
        "coverageEnd": sessions[-1].close if sessions else 0,
        "contentHash": "0x" + hashlib.sha256(canonical).hexdigest(),
        "sessions": body,
        "sessionsAbiEncoded": abi_encode(sessions),
        "sessionDates": [s.date.isoformat() for s in sessions],
    }


def add_months(day: dt.date, months: int) -> dt.date:
    """Last day of the month `months - 1` after `day`'s month (13 months from Oct 1 → Oct 31 next year)."""
    y, m = divmod(day.month - 1 + months, 12)
    first_after = dt.date(day.year + y, m + 1, 1)
    return first_after - dt.timedelta(days=1)


def write(venue: str, start: dt.date, end: dt.date, out_dir: Path) -> Path:
    sessions = generate(venue, start, end)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{venue}-{start:%Y%m%d}-{end:%Y%m%d}.json"
    path.write_text(json.dumps(document(venue, start, end, sessions), indent=1) + "\n")
    return path


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description="Generate Session[] calendars for CalendarStore.")
    ap.add_argument("--from", dest="start", type=dt.date.fromisoformat, help="first date (default: 1st of next month)")
    ap.add_argument("--months", type=int, default=13)
    ap.add_argument("--venue", action="append", choices=["XNYS", "USBANK"])
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "out" / "calendars")
    args = ap.parse_args(argv)
    start = args.start
    if start is None:
        today = dt.date.today()
        start = add_months(today, 1) + dt.timedelta(days=1)
    end = add_months(start, args.months)
    for venue in args.venue or ["XNYS", "USBANK"]:
        print(write(venue, start, end, args.out))


if __name__ == "__main__":
    main()
