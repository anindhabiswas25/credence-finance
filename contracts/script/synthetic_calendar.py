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
a = ap.parse_args()
# an idle devnode's latest block can lag the wall clock by hours; its next block is stamped ~now
a.now = max(a.now, int(time.time()))
# the next session's extended open is at NOW - 2 h + 1 d - 5.5 h; today's extended close must stay before it
assert 0 < a.regular_hours <= 12, "--regular-hours must be in (0, 12]"

rows = []
for k in range(-3, a.after + 1):
    o = a.now - 2 * 3600 + k * DAY
    c = o + (int(a.regular_hours * 3600) + 2 * 3600 if k == 0 else 6 * 3600)
    rows.append((o - 5 * 3600 - 1800, o, c, c + 4 * 3600, WEEKEND if k == 0 else OVERNIGHT))
arg = "[" + ",".join("(%d,%d,%d,%d,%d)" % r for r in rows) + "]"
enc = subprocess.check_output(["cast", "abi-encode", "f((uint40,uint40,uint40,uint40,uint8)[])", arg]).decode().strip()
for v in ("XNYS", "USBANK"):
    with open(f"{a.out}/{v}-synthetic.json", "w") as f:
        json.dump({"venue": v, "source": f"synthetic (centred on chain time {a.now})", "sessionsAbiEncoded": enc}, f)
print(f"synthetic calendars: {len(rows)} sessions, REGULAR until {rows[3][2]}, WEEKEND closure after it -> {a.out}")
