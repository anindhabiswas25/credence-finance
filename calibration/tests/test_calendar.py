"""Calendar edge cases (Sprint 1 brief item 4). Times are asserted in America/New_York wall-clock."""

import datetime as dt
import json
from zoneinfo import ZoneInfo

import pytest

from credence_cal.calendar import ClosureType, Session, abi_encode, document, generate, validate

ET = ZoneInfo("America/New_York")
D = dt.date


def at(t: int) -> tuple[str, str]:
    x = dt.datetime.fromtimestamp(t, ET)
    return x.strftime("%a %Y-%m-%d"), x.strftime("%H:%M")


def by_date(sessions: list[Session]) -> dict[dt.date, Session]:
    return {s.date: s for s in sessions}


@pytest.fixture(scope="module")
def xnys_2026_2027() -> dict[dt.date, Session]:
    return by_date(generate("XNYS", D(2026, 10, 1), D(2027, 10, 31)))


def test_regular_weekday(xnys_2026_2027):
    s = xnys_2026_2027[D(2026, 10, 7)]  # Wednesday
    assert at(s.ext_open) == ("Tue 2026-10-06", "20:00")
    assert at(s.open)[1] == "09:30"
    assert at(s.close)[1] == "16:00"
    assert at(s.ext_close) == ("Wed 2026-10-07", "20:00")
    assert s.closure_type_after == ClosureType.OVERNIGHT
    # 24/5: the weeknight overnight window runs straight through into the next session
    assert xnys_2026_2027[D(2026, 10, 8)].ext_open == s.ext_close


def test_normal_weekend(xnys_2026_2027):
    fri, mon = xnys_2026_2027[D(2026, 10, 9)], xnys_2026_2027[D(2026, 10, 12)]
    assert fri.closure_type_after == ClosureType.WEEKEND
    assert at(fri.ext_close) == ("Fri 2026-10-09", "20:00")
    assert at(mon.ext_open) == ("Sun 2026-10-11", "20:00")


def test_thanksgiving_and_black_friday(xnys_2026_2027):
    wed = xnys_2026_2027[D(2026, 11, 25)]
    assert D(2026, 11, 26) not in xnys_2026_2027  # Thanksgiving
    fri = xnys_2026_2027[D(2026, 11, 27)]
    # mid-week holiday closure uses the HOLIDAY_WEEKEND table (Types.sol comment)
    assert wed.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    # overnight window reopens Thursday evening for the Friday session
    assert at(fri.ext_open) == ("Thu 2026-11-26", "20:00")
    # Black Friday early close 13:00, post-market ends 17:00
    assert at(fri.open)[1] == "09:30"
    assert at(fri.close) == ("Fri 2026-11-27", "13:00")
    assert at(fri.ext_close) == ("Fri 2026-11-27", "17:00")
    assert fri.closure_type_after == ClosureType.WEEKEND


def test_good_friday(xnys_2026_2027):
    assert D(2027, 3, 26) not in xnys_2026_2027
    thu = xnys_2026_2027[D(2027, 3, 25)]
    mon = xnys_2026_2027[D(2027, 3, 29)]
    assert thu.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    assert at(thu.close)[1] == "16:00"
    assert at(mon.ext_open) == ("Sun 2027-03-28", "20:00")


def test_july_4_on_a_weekday():
    # 2028-07-04 is a Tuesday: Monday 3 July is an early close, then a mid-week holiday.
    cal = by_date(generate("XNYS", D(2028, 6, 26), D(2028, 7, 14)))
    assert D(2028, 7, 4) not in cal
    mon = cal[D(2028, 7, 3)]
    assert at(mon.close) == ("Mon 2028-07-03", "13:00")
    assert at(mon.ext_close)[1] == "17:00"
    assert mon.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    wed = cal[D(2028, 7, 5)]
    assert at(wed.ext_open) == ("Tue 2028-07-04", "20:00")
    assert cal[D(2028, 6, 30)].closure_type_after == ClosureType.WEEKEND


def test_july_4_on_a_friday_2025():
    cal = by_date(generate("XNYS", D(2025, 6, 30), D(2025, 7, 11)))
    thu = cal[D(2025, 7, 3)]
    assert at(thu.close)[1] == "13:00"
    assert thu.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    assert at(cal[D(2025, 7, 7)].ext_open) == ("Sun 2025-07-06", "20:00")


def test_dst_fall_back_weekend(xnys_2026_2027):
    # US DST ends Sun 2026-11-01 02:00: EDT (UTC-4) → EST (UTC-5)
    fri, mon = xnys_2026_2027[D(2026, 10, 30)], xnys_2026_2027[D(2026, 11, 2)]
    assert fri.open == int(dt.datetime(2026, 10, 30, 13, 30, tzinfo=dt.UTC).timestamp())
    assert mon.open == int(dt.datetime(2026, 11, 2, 14, 30, tzinfo=dt.UTC).timestamp())
    assert at(mon.ext_open) == ("Sun 2026-11-01", "20:00")
    assert mon.ext_open == int(dt.datetime(2026, 11, 2, 1, 0, tzinfo=dt.UTC).timestamp())
    # the weekend closure is 1 hour longer than a normal one in UTC seconds
    assert mon.open - fri.close == 235_800 + 3600  # 65.5 h + 1 h
    assert fri.closure_type_after == ClosureType.WEEKEND


def test_dst_spring_forward_weekend(xnys_2026_2027):
    # US DST starts Sun 2027-03-14 02:00: EST (UTC-5) → EDT (UTC-4)
    fri, mon = xnys_2026_2027[D(2027, 3, 12)], xnys_2026_2027[D(2027, 3, 15)]
    assert fri.open == int(dt.datetime(2027, 3, 12, 14, 30, tzinfo=dt.UTC).timestamp())
    assert mon.open == int(dt.datetime(2027, 3, 15, 13, 30, tzinfo=dt.UTC).timestamp())
    assert mon.ext_open == int(dt.datetime(2027, 3, 15, 0, 0, tzinfo=dt.UTC).timestamp())
    assert mon.open - fri.close == 235_800 - 3600  # 65.5 h - 1 h


def test_new_year(xnys_2026_2027):
    # Fri 2027-01-01 is a holiday; Thu 2026-12-31 is a full session.
    assert D(2027, 1, 1) not in xnys_2026_2027
    thu = xnys_2026_2027[D(2026, 12, 31)]
    assert at(thu.close)[1] == "16:00"
    assert thu.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    assert at(xnys_2026_2027[D(2027, 1, 4)].ext_open) == ("Sun 2027-01-03", "20:00")


def test_christmas_2026(xnys_2026_2027):
    # Christmas Friday 2026-12-25; Christmas Eve Thursday is an early close.
    thu = xnys_2026_2027[D(2026, 12, 24)]
    assert D(2026, 12, 25) not in xnys_2026_2027
    assert at(thu.close)[1] == "13:00"
    assert thu.closure_type_after == ClosureType.HOLIDAY_WEEKEND


def test_mlk_long_weekend(xnys_2026_2027):
    fri = xnys_2026_2027[D(2027, 1, 15)]
    assert D(2027, 1, 18) not in xnys_2026_2027
    assert fri.closure_type_after == ClosureType.HOLIDAY_WEEKEND
    assert at(xnys_2026_2027[D(2027, 1, 19)].ext_open) == ("Mon 2027-01-18", "20:00")


def test_usbank_fed_rules():
    cal = by_date(generate("USBANK", D(2026, 10, 1), D(2027, 12, 31)))
    assert D(2026, 10, 12) not in cal  # Columbus Day: Fed closed, NYSE open
    assert D(2026, 11, 11) not in cal  # Veterans Day (Wednesday): mid-week holiday
    assert cal[D(2026, 11, 10)].closure_type_after == ClosureType.HOLIDAY_WEEKEND
    assert D(2027, 6, 18) in cal  # Juneteenth 2027 is a Saturday: the Fed stays open on Friday
    assert D(2027, 12, 24) in cal  # Christmas 2027 is a Saturday: open Friday the 24th
    s = cal[D(2026, 10, 1)]
    assert [at(t)[1] for t in (s.ext_open, s.open, s.close, s.ext_close)] == ["08:00", "09:00", "17:00", "18:00"]


def test_usbank_sunday_holiday_observed_monday():
    cal = by_date(generate("USBANK", D(2028, 1, 1), D(2028, 1, 31)))
    # 2028-01-01 is Saturday → not observed; 2027-07-04 Sunday → Monday observed
    assert D(2028, 1, 3) in cal
    cal = by_date(generate("USBANK", D(2027, 7, 1), D(2027, 7, 9)))
    assert D(2027, 7, 5) not in cal


@pytest.mark.parametrize("venue", ["XNYS", "USBANK"])
def test_thirteen_months_valid_and_append_rules(venue):
    sessions = generate(venue, D(2026, 10, 1), D(2027, 10, 31))
    validate(sessions)
    assert 250 < len(sessions) < 300
    assert sessions[0].date == D(2026, 10, 1)
    assert sessions[-1].date <= D(2027, 10, 31)
    types = {s.closure_type_after for s in sessions}
    assert types == {ClosureType.OVERNIGHT, ClosureType.WEEKEND, ClosureType.HOLIDAY_WEEKEND}


def test_abi_encoding_layout():
    s = generate("XNYS", D(2026, 10, 5), D(2026, 10, 6))
    enc = bytes.fromhex(abi_encode(s)[2:])
    assert len(enc) == 32 * (2 + 5 * len(s))
    assert int.from_bytes(enc[0:32]) == 0x20
    assert int.from_bytes(enc[32:64]) == 2
    assert int.from_bytes(enc[64:96]) == s[0].ext_open
    assert int.from_bytes(enc[64 + 4 * 32 : 64 + 5 * 32]) == ClosureType.OVERNIGHT


def test_document_is_deterministic():
    s = generate("XNYS", D(2026, 10, 1), D(2026, 12, 31))
    a = json.dumps(document("XNYS", D(2026, 10, 1), D(2026, 12, 31), s))
    b = json.dumps(document("XNYS", D(2026, 10, 1), D(2026, 12, 31), generate("XNYS", D(2026, 10, 1), D(2026, 12, 31))))
    assert a == b
    assert list(json.loads(a)["sessions"][0]) == ["extOpen", "open", "close", "extClose", "closureTypeAfter"]
