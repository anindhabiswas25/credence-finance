#!/usr/bin/env python3
"""Cut a contiguous slice of a BE-backend calendar JSON into a test fixture of the same shape.

Usage: make_calendar_fixture.py <calendar.json> <first> <count> <out.json>
The fixture keeps the generator's keys (venue, coverageEnd, sessions, sessionsAbiEncoded, sessionDates) and
re-encodes `sessionsAbiEncoded` = abi.encode(Session[]) for the slice, so tests decode it exactly like the full file.
"""
import json
import sys

FIELDS = ("extOpen", "open", "close", "extClose", "closureTypeAfter")


def abi_encode_sessions(sessions):
    words = [0x20, len(sessions)]
    for s in sessions:
        words.extend(int(s[k]) for k in FIELDS)
    return "0x" + "".join(f"{w:064x}" for w in words)


def main():
    src, first, count, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    d = json.load(open(src))
    sessions = d["sessions"][first : first + count]
    dates = d["sessionDates"][first : first + count]
    fixture = {
        "formatVersion": d.get("formatVersion"),
        "venue": d["venue"],
        "source": src.split("/")[-1],
        "firstIndex": first,
        "count": len(sessions),
        "coverageEnd": sessions[-1]["close"],
        "sessions": sessions,
        "sessionsAbiEncoded": abi_encode_sessions(sessions),
        "sessionDates": dates,
    }
    json.dump(fixture, open(out, "w"), indent=1)
    print(f"{out}: {len(sessions)} sessions {dates[0]} .. {dates[-1]}")


if __name__ == "__main__":
    main()
