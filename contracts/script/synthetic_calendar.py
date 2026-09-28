#!/usr/bin/env python3
"""Synthetic XNYS + USBANK calendars centred on a local chain's clock (devnode clocks cannot be warped).

    synthetic_calendar.py NOW OUT_DIR [--after N] [--regular-hours H]

Today's session opens at NOW - 2 h and closes at NOW + H h (default 12), so the chain is in REGULAR with live prices
for H hours; a WEEKEND closure follows it, then N (default 10) more daily sessions with OVERNIGHT closures. Three
past sessions precede it. Writes OUT_DIR/{XNYS,USBANK}-synthetic.json in the calendar v1 format DeployClockLocal
reads (`sessionsAbiEncoded`). Used by `make local-deploy-core CALENDAR=synthetic` and devnode_integration.sh.
"""
import argparse
import json
import subprocess
import time

DAY = 86400
OVERNIGHT, WEEKEND = 1, 2

ap = argparse.ArgumentParser()
ap.add_argument("now", type=int)
ap.add_argument("out")
ap.add_argument("--after", type=int, default=10)
ap.add_argument("--regular-hours", type=float, default=12)
# compressed mode (BE-backend REQUEST 2026-09-29 01:10, `make scenario-a-e2e`): minutes instead of days
ap.add_argument("--regular-minutes", type=int, help="today's session closes at NOW + M min")
ap.add_argument("--closure-minutes", type=int, help="the WEEKEND closure after today lasts C min")
ap.add_argument("--session-minutes", type=int, help="later sessions and their OVERNIGHT closures last S min each")
a = ap.parse_args()
# an idle devnode's latest block can lag the wall clock by hours; its next block is stamped ~now
a.now = max(a.now, int(time.time()))
# the next session's extended open is at NOW - 2 h + 1 d - 5.5 h; today's extended close must stay before it
assert 0 < a.regular_hours <= 12, "--regular-hours must be in (0, 12]"

rows = []
compressed = a.regular_minutes is not None or a.closure_minutes is not None or a.session_minutes is not None
if compressed:
    M, C, S = a.regular_minutes or 140, a.closure_minutes or 15, a.session_minutes or 15
    assert M > 0 and C >= 2 and S >= 2, "minutes must be positive (closures ≥ 2 min)"
    # three past sessions a day apart, today's session, then compressed sessions; the extended windows are 1 min
    # (half the shortest closure at most), so extClose ≤ the next extOpen always holds
    ext = min(60, C * 30, S * 30)
    for k in (-3, -2, -1):
        o = a.now - 2 * 3600 + k * DAY
        rows.append((o - 5 * 3600 - 1800, o, o + 6 * 3600, o + 10 * 3600, OVERNIGHT))
    o, c = a.now - 2 * 3600, a.now + M * 60
    rows.append((o - ext, o, c, c + ext, WEEKEND))
    for k in range(a.after):
        o = c + (C if k == 0 else S) * 60
        c = o + S * 60
        rows.append((o - ext, o, c, c + ext, OVERNIGHT))
for k in (range(0) if compressed else range(-3, a.after + 1)):
    o = a.now - 2 * 3600 + k * DAY
    c = o + (int(a.regular_hours * 3600) + 2 * 3600 if k == 0 else 6 * 3600)
    rows.append((o - 5 * 3600 - 1800, o, c, c + 4 * 3600, WEEKEND if k == 0 else OVERNIGHT))
arg = "[" + ",".join("(%d,%d,%d,%d,%d)" % r for r in rows) + "]"
enc = subprocess.check_output(["cast", "abi-encode", "f((uint40,uint40,uint40,uint40,uint8)[])", arg]).decode().strip()
for v in ("XNYS", "USBANK"):
    with open(f"{a.out}/{v}-synthetic.json", "w") as f:
        json.dump({"venue": v, "source": f"synthetic (centred on chain time {a.now})", "sessionsAbiEncoded": enc}, f)
print(f"synthetic calendars: {len(rows)} sessions, REGULAR until {rows[3][2]}, WEEKEND closure after it -> {a.out}")
