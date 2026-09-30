"""Alias assets (ADR-0120): the alias bundle carries the underlying's data bit for bit, under the alias key."""

import json

import pytest

from credence_cal.common import OUT, keccak256


@pytest.mark.skipif(not list((OUT / "alias").glob("risk-bundle-alias-*.json")), reason="no alias bundle built")
def test_alias_bundle_equals_the_underlying():
    b = json.loads(next((OUT / "alias").glob("risk-bundle-alias-*.json")).read_text())
    eq = json.loads((OUT / b["meta"]["equityBundle"]).read_text())
    under = {json.loads((OUT / r).read_text())["closureType"]: json.loads((OUT / r).read_text())
             for r in eq["scenarioSets"] if "/TSLA-XNAS-" in "/" + r.split("/")[-1]}
    for r in b["scenarioSets"]:
        s = json.loads((OUT / "alias" / r).read_text())
        assert s["asset"] == "RHTSLA:XNAS"
        assert s["scenarioHash"] == under[s["closureType"]]["scenarioHash"], "same packed words"
    j = json.loads((OUT / "alias" / b["jointSet"]).read_text())
    ej = json.loads((OUT / eq["jointSet"]).read_text())
    assert j["z"][0] == ej["z"][ej["assets"].index("TSLA:XNAS")] and j["k"] == ej["k"]
    tsla = "0x" + keccak256(b"TSLA:XNAS").hex()
    assert b["sigmas"]["values"] == [v for a, v in zip(eq["sigmas"]["assetIds"], eq["sigmas"]["values"]) if a == tsla]
    assert b["sigmaFloors"]["floors"] == [
        f for a, f in zip(eq["sigmaFloors"]["assetIds"], eq["sigmaFloors"]["floors"]) if a == tsla]
