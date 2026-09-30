"""Alias assets (ADR-0120): a second collateral token on the same underlying, e.g. the official Robinhood test TSLA
listed as `RHTSLA:XNAS` next to our test token `TSLA:XNAS`. The oracle binds one token per asset id, so the alias needs
its own sets, σ, floors and joint column: exactly the underlying's, under the alias key. The joint column is the
underlying's column of the same joint file, so its rows stay aligned with the other equity markets in the pool.

Writes `out/alias/risk-bundle-alias-<sha8>.json`, loaded after the equity bundle.
"""

from __future__ import annotations

import json
from pathlib import Path

from .common import OUT, canonical_json, keccak256, sha256_hex, write_json

ALIASES = {"RHTSLA:XNAS": "TSLA:XNAS"}


def _aid(key: str) -> str:
    return "0x" + keccak256(key.encode()).hex()


def stage(out: Path = OUT) -> Path:
    from .engine import default_engine
    from .setfile import write_chain_file

    eng = default_engine()
    eq_path = next(out.glob("risk-bundle-*.json"))
    eq = json.loads(eq_path.read_text())
    joint = json.loads((out / eq["jointSet"]).read_text())
    d = out / "alias"
    for old in list(d.glob("*.json")) if d.exists() else []:
        old.unlink()
    sets, cols = [], []
    floors = {"assetIds": [], "closureTypes": [], "floors": []}
    sigmas = {"assetIds": [], "closureTypes": [], "values": []}
    for alias, under in ALIASES.items():
        uid = _aid(under)
        for rel in eq["scenarioSets"]:
            s = json.loads((out / rel).read_text())
            if s["asset"] != under:
                continue
            doc = eng.build_set(alias, s["closureType"], s["z"], {**s.get("meta", {}), "aliasOf": under, "adr": "ADR-0120"})
            sets.append(write_chain_file(d, doc).name)
        cols.append((alias, joint["z"][joint["assets"].index(under)]))
        for src, dst, key in ((eq["sigmaFloors"], floors, "floors"), (eq["sigmas"], sigmas, "values")):
            for a, t, v in zip(src["assetIds"], src["closureTypes"], src[key]):
                if a == uid:
                    dst["assetIds"].append(_aid(alias))
                    dst["closureTypes"].append(t)
                    dst[key].append(v)
    jdoc = eng.build_joint(cols, {"aliasOf": dict(ALIASES), "from": eq["jointSet"], "adr": "ADR-0120"})
    jp = write_chain_file(d, jdoc)
    bundle = {"format": "credence.risk-bundle/v1", "params": eq["params"], "scenarioSets": sorted(sets),
              "jointSet": jp.name, "sigmaFloors": floors, "sigmas": sigmas,
              "meta": {"aliases": dict(ALIASES), "equityBundle": eq_path.name, "adr": "ADR-0120",
                       "note": "Alias assets: the underlying's sets, σ, floors and joint column under the alias key. "
                               "Load AFTER the equity bundle."}}
    h = sha256_hex(canonical_json(bundle))[:8]
    bpath = d / f"risk-bundle-alias-{h}.json"
    write_json(bpath, bundle)
    eng.validate_file(bpath)
    print(f"alias: {', '.join(f'{a} = {u}' for a, u in ALIASES.items())} -> alias/{bpath.name}")
    return bpath

