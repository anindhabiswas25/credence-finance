"""Scenario-set, joint-set and risk-bundle files in BE-chain's format (ADR-0106). The payload and both hashes
(`scenarioHash` = keccak of the packed words, `contentHash` = sha256 over tag ‖ ids ‖ words) are built by
risk-core itself (`Engine.build_set` / `build_joint`), so a file this module writes is exactly what
`risk-cli validate-set` and `LoadScenarioSet.s.sol` check. Files are named by `contentHash` as the ADR says:
`<TICKER>-<MIC>-<closureType>-<contentHash[0..8]>.json` and `joint-<contentHash[0..8]>.json`.
`pack_i16` stays as the independent reference the tests compare risk-core's packing with."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .common import LISTED, ClosureType, write_json


def pack_i16(values: list[int]) -> list[str]:
    words = []
    for i in range(0, len(values), 16):
        w = 0
        for lane, v in enumerate(values[i:i + 16]):
            w |= (int(v) & 0xFFFF) << (16 * lane)
        words.append("0x" + format(w, "064x"))
    return words


def asset_key(symbol: str) -> str:
    return f"{symbol}:{LISTED[symbol]}"


def _provenance(c) -> dict:
    return {"vendor": c.vendor, "dataGrade": c.grade, "dataEnd": c.end}


def set_document(eng, symbol: str, t: int, q: np.ndarray, info: dict, c) -> dict:
    z = [int(v) for v in q]
    meta = {**_provenance(c), "symbol": symbol, "closureTypeName": ClosureType(t).name,
            "pooling": {k: info[k] for k in ("group", "poolSize", "contributors", "paddedWithWeekend")},
            "tail": info["tail"], "method": "ADR-0203 (pooling), ADR-0204 (t3 tail floor)"}
    doc = eng.build_set(asset_key(symbol), t, z, meta)
    assert doc["packed"] == pack_i16(z) and doc["z"] == z
    return doc


def joint_document(eng, cols: dict[str, np.ndarray], info: dict, c) -> dict:
    meta = {**_provenance(c), "beta": info["beta"], "backfilled": info["backfilled"], "ranking": info["ranking"],
            "betaMethod": info["betaMethod"], "synthetic": info["synthetic"], "closures": info["closures"],
            "method": "ADR-0203 (joint set), ADR-0204 (synthetic stress closures)"}
    return eng.build_joint([(asset_key(a), [int(v) for v in col]) for a, col in cols.items()], meta)


def file_name(doc: dict) -> str:
    h = doc["contentHash"][2:10]
    if doc["format"] == "credence.joint-set/v1":
        return f"joint-{h}.json"
    return f"{doc['asset'].replace(':', '-')}-{doc['closureType']}-{h}.json"


def write_chain_file(directory: Path, doc: dict) -> Path:
    """Write an ADR-0106 document under its content-addressed name; remove older versions of the same
    (asset, type) or joint file, so the directory holds exactly one of each."""
    name = file_name(doc)
    stem = name.rsplit("-", 1)[0]
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob(f"{stem}-*.json"):
        if old.name != name:
            old.unlink()
    path = directory / name
    write_json(path, doc)
    return path
