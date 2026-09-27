#!/usr/bin/env python3
"""Fail if line coverage of any given source directory is below a threshold.

Usage: check_coverage.py <lcov.info> <dir> [<dir> ...] <min-percent>
Reads the LCOV report written by `forge coverage --report lcov` and aggregates LF/LH per directory prefix.
"""
import sys


def main() -> int:
    lcov, *dirs, minimum = sys.argv[1:]
    minimum = float(minimum)
    found = {d: [0, 0] for d in dirs}
    current = None
    for line in open(lcov):
        line = line.strip()
        if line.startswith("SF:"):
            path = line[3:]
            current = next((d for d in dirs if path.startswith(d + "/") or f"/{d}/" in path), None)
        elif current and line.startswith("LF:"):
            found[current][0] += int(line[3:])
        elif current and line.startswith("LH:"):
            found[current][1] += int(line[3:])
    ok = True
    for d, (lf, lh) in found.items():
        pct = 100.0 * lh / lf if lf else 0.0
        status = "ok" if pct >= minimum else "FAIL"
        print(f"{status:4} {d:14} lines {lh}/{lf} = {pct:.2f}% (min {minimum}%)")
        ok &= pct >= minimum
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
