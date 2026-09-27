"""Shared constants and helpers for the calibration pipeline (Build Guide §10.6).

Every output is content-addressed: the payload is serialised as canonical JSON (sorted keys, no
whitespace, integers only where the chain reads it) and named by the first 16 hex chars of its sha256.
"""

from __future__ import annotations

import hashlib
import json
from enum import IntEnum
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent  # calibration/
DATA = ROOT / "data"  # git-ignored: raw vendor data, derived Parquet
OUT = ROOT / "out"  # committed: content-addressed outputs
MANIFESTS = ROOT / "manifests"  # committed: data manifests (source, pull date, rows, checksums)
SAMPLE = ROOT / "sample"  # committed: synthetic CI sample (no vendor data)

# The six listed markets (Build Guide §1.3). Asset ids are keccak256("<SYMBOL>:<VENUE>") (ADR-0101).
LISTED = {
    "NVDA": "XNAS",
    "AAPL": "XNAS",
    "TSLA": "XNAS",
    "COIN": "XNAS",
    "MSFT": "XNAS",
    "SPY": "XNAS",  # sic: DeployClockLocal.s.sol derives every listing as "<TICKER>:XNAS"; follow the chain
}
INDEX = "SPY"  # back-fill reference (§10.6 step 5)

# Comparable-name groups for pooling standardised gaps (ADR-0203). Order = pooling priority.
GROUPS: dict[str, list[str]] = {
    "MEGA_TECH": ["NVDA", "AAPL", "MSFT", "AMD", "AVGO", "GOOGL", "AMZN", "META", "INTC", "CSCO",
                  "ORCL", "QCOM", "ADBE", "TXN", "MU", "NFLX"],
    "HIGH_VOL": ["TSLA", "COIN", "MSTR", "MARA", "RIOT", "HOOD", "PLTR", "SHOP", "ROKU", "AMD", "NFLX"],
    "INDEX_ETF": ["SPY", "QQQ", "IWM", "DIA", "XLK", "XLF", "XLE", "XLV", "XLI", "XLY", "XLP", "XLU"],
}
ASSET_GROUP = {"NVDA": "MEGA_TECH", "AAPL": "MEGA_TECH", "MSFT": "MEGA_TECH",
               "TSLA": "HIGH_VOL", "COIN": "HIGH_VOL", "SPY": "INDEX_ETF"}


def universe() -> list[str]:
    seen: dict[str, None] = {}
    for t in list(LISTED) + [t for g in GROUPS.values() for t in g]:
        seen.setdefault(t, None)
    return list(seen)


class ClosureType(IntEnum):
    """Mirror of `enum ClosureType` in contracts/src/libraries/Types.sol (§8.1)."""

    NONE = 0
    OVERNIGHT = 1
    WEEKEND = 2
    HOLIDAY_WEEKEND = 3


CLOSURE_TYPES = (ClosureType.OVERNIGHT, ClosureType.WEEKEND, ClosureType.HOLIDAY_WEEKEND)


def canonical_json(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, obj: Any) -> str:
    """Write pretty JSON deterministically; return sha256 of the canonical form."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, sort_keys=True, indent=1, ensure_ascii=True, allow_nan=False) + "\n")
    return sha256_hex(canonical_json(obj))


def write_addressed(directory: Path, stem: str, obj: dict) -> tuple[Path, str]:
    """Write `obj` as <stem>-<hash16>.json, where the hash is over the canonical payload. Removes stale
    siblings with the same stem so the directory always holds exactly one version."""
    h = sha256_hex(canonical_json(obj))
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob(f"{stem}-*.json"):
        if old.stem.rsplit("-", 1)[-1] != h[:16]:
            old.unlink()
    path = directory / f"{stem}-{h[:16]}.json"
    write_json(path, obj)
    return path, h


def keccak256(data: bytes) -> bytes:
    from Crypto.Hash import keccak  # type: ignore[import-not-found]

    k = keccak.new(digest_bits=256)
    k.update(data)
    return k.digest()


def asset_id(symbol: str) -> str:
    return "0x" + keccak256(f"{symbol}:{LISTED[symbol]}".encode()).hex()


def load_env() -> dict[str, str]:
    """Read the repo-root .env without exporting it (keys never leave this process)."""
    env: dict[str, str] = {}
    p = ROOT.parent / ".env"
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env
