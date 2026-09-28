"""Scenario-set and joint-column files in BE-chain's format (the format ADR is BE-chain's; this module
only serialises). Packing: 16 × int16 per uint256 word, lane 0 in the least-significant bits,
two's complement (== risk-core `pack_i16`, PackedInt.sol)."""

from __future__ import annotations

import numpy as np

from .common import ClosureType, asset_id


def pack_i16(values: list[int]) -> list[str]:
    words = []
    for i in range(0, len(values), 16):
        w = 0
        for lane, v in enumerate(values[i:i + 16]):
            w |= (int(v) & 0xFFFF) << (16 * lane)
        words.append("0x" + format(w, "064x"))
    return words


def _provenance(c) -> dict:
    return {"vendor": c.vendor, "dataGrade": c.grade, "dataEnd": c.end}


def set_document(symbol: str, t: int, q: np.ndarray, info: dict, c) -> dict:
    z = [int(v) for v in q]
    assert all(z[i] <= z[i + 1] for i in range(len(z) - 1))
    return {
        "kind": "credence.scenario-set.v1",
        "assetId": asset_id(symbol),
        "symbol": symbol,
        "closureType": int(t),
        "closureTypeName": ClosureType(t).name,
        "n": len(z),
        "z": z,
        "packedWords": pack_i16(z),
        "provenance": {**_provenance(c), "pooling": {k: info[k] for k in ("group", "poolSize", "contributors",
                                                                           "paddedWithWeekend")}},
    }


def joint_document(cols: dict[str, np.ndarray], info: dict, c) -> dict:
    return {
        "kind": "credence.joint-set.v1",
        "k": info["k"],
        "columns": [{"assetId": asset_id(a), "symbol": a, "z": [int(v) for v in col],
                     "packedWords": pack_i16([int(v) for v in col])} for a, col in cols.items()],
        "closures": info["closures"],
        "provenance": {**_provenance(c), "beta": info["beta"], "backfilled": info["backfilled"],
                       "ranking": info["ranking"], "betaMethod": info["betaMethod"], "synthetic": info["synthetic"]},
    }
