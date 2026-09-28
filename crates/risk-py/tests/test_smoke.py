"""risk-py smoke test: every exported function runs, matches risk-cli / the golden figures, and the ADR-0106 file
helpers agree with the files risk-core wrote. Runs with plain `python` (no pytest needed) or under pytest.

    make risk-py-test                       # builds into crates/risk-py/.venv, then runs this file
    RISK_CLI=target/release/risk-cli python crates/risk-py/tests/test_smoke.py   # also cross-checks risk-cli
"""

import json
import os
import subprocess
import tempfile
from pathlib import Path

import credence_risk as cr

ROOT = Path(__file__).resolve().parents[3]
FIX = ROOT / "contracts" / "test" / "fixtures" / "risk"
WAD = 10**18


def cli(cmd, args):
    b = os.environ.get("RISK_CLI") or str(ROOT / "target" / "release" / "risk-cli")
    if not Path(b).exists():
        return None
    r = subprocess.run([b, cmd, "-"], input=json.dumps(args), capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def test_scalar_functions_match_known_values():
    # the same vectors as risk-cli's own tests (and G-10 / Appendix A for the safe LTV prefix)
    assert cr.kinked_rate(850 * WAD // 1000, 2 * WAD // 100, 6 * WAD // 100, 80 * WAD // 100, 9 * WAD // 10) == 76666666666666666
    assert str(cr.safe_ltv(-5897, 4 * WAD // 100, 0, 3 * WAD // 100, 75 * WAD // 100)).startswith("7411")
    x = cr.liquidation_lot(13_500_000_000, 100 * WAD, 153648 * WAD // 1000, 1584 * WAD // 10, 8 * WAD // 10,
                           11 * WAD // 10, 3 * WAD // 100)
    assert str(x).startswith("585131")
    p_star, fills, q_pool = cr.clear([300, 300], [12440, 12411], [b"\x01" * 32, "0x" + "02" * 32], 500, 12222)
    assert (p_star, fills, q_pool) == (12411, [300, 200], 0)
    status, repay, add = cr.bell_status(18000, 13500, 741182000000000000, False)
    assert status == 1 and repay > 0 and add > 0
    assert cr.bell_status(18000, 13500, 741182000000000000, True)[0] == 2
    assert cr.utilization(1, 2) == WAD // 2
    assert cr.projected_debt(1_000_000, 0, 3) == 1_000_000
    assert cr.sigma_min_allowed(WAD, 0) == WAD
    assert cr.elapsed_days(0, 86400 * 2 + 5) == 2
    assert cr.quantile_index(3000, WAD // 1000) == 2
    assert cr.gap_factor(0, 4 * WAD // 100, 0, 3 * WAD // 100) == 97 * WAD // 100
    assert cr.accrue_interest(10**6, 0, 3600) == 0
    assert cr.senior_rate(10 * WAD // 100, WAD // 2, WAD // 10, WAD // 10) > 0
    assert cr.blended_price(500, 12411, 0, 12222) == 12411
    s = cr.settle_position(50 * WAD, 100 * WAD, 150 * WAD, 13_500_000_000, 3 * WAD // 100)
    assert set(s) == {"proceeds", "penalty", "repaid", "refund", "shortfall", "debtAfter", "fullClose"}
    assert s["fullClose"] is False and s["proceeds"] == 7_500_000_000
    assert cr.preclose_lot(13_500_000_000, 100 * WAD, 150 * WAD, 150 * WAD, 7 * WAD // 10, WAD // 100) >= 0
    repay, add_q, add_v = cr.cure_amounts(13_500_000_000, 100 * WAD, 180 * WAD, 7 * WAD // 10)
    assert repay > 0 and add_q > 0 and add_v > 0
    # big ints and strings in, big ints out
    assert cr.utilization(str(2**200), "0x" + format(2**201, "x")) == WAD // 2


def test_sets_premium_capacity_against_cli():
    z = [-9000, -6000, -100, 0, 500]
    s = cr.load_set(z)
    assert len(s) == 5 and s.n == 5 and s.z == z and s.asset_id is None
    args = dict(sigma=4 * WAD // 100, dividend=0, kappa=3 * WAD // 100, collateral_value=18_000_000_000,
                debt_projected=13_500_000_000, closure_days=3, util_after=0, theta=WAD, cost_of_cap=15 * WAD // 100,
                eta=4 * WAD, beta=975 * WAD // 1000)
    q = cr.quote_cover(s, **args)
    assert q == cr.quote_cover(z, **args)  # list or ScenarioSet
    assert q[0] > 0
    ref = cli("quote-cover", {"set": z, "sigma": str(args["sigma"]), "kappa": str(args["kappa"]),
                              "collateralValue": "18000000000", "debtProjected": "13500000000", "closureDays": 3,
                              "theta": str(WAD), "costOfCap": str(args["cost_of_cap"]), "eta": str(4 * WAD),
                              "beta": str(args["beta"])})
    if ref:
        assert q == (int(ref["premium"]), int(ref["expectedLoss"]), int(ref["expectedShortfall"]))
    ltv = cr.safe_ltv_from_set(s, WAD // 1000, 4 * WAD // 100, 0, 3 * WAD // 100, 75 * WAD // 100)
    assert ltv == cr.safe_ltv(-9000, 4 * WAD // 100, 0, 3 * WAD // 100, 75 * WAD // 100)
    joint = [-8000, 300, -2000, 50]
    lv = cr.cover_loss_vector(joint, 18_000_000_000, 13_500_000_000, 4 * WAD // 100, 0, 3 * WAD // 100)
    assert cr.loss_vector(joint, 18_000_000_000, 13_500_000_000, 4 * WAD // 100, 0, 3 * WAD // 100) == lv
    ref = cli("loss-vector", {"joint": joint, "collateralValue": "18000000000", "debtProjected": "13500000000",
                              "sigma": str(4 * WAD // 100), "kappa": str(3 * WAD // 100)})
    if ref:
        assert lv == [int(x) for x in ref["losses"]]
        assert cr.pack_losses(lv) == [int(w) for w in ref["packed"]]
    ok, util, worst = cr.pool_capacity([0] * 4, lv, [(joint, 4 * WAD // 100, 0, 1_000_000, 7 * WAD // 10)],
                                       3 * WAD // 100, 10**12, WAD // 2)
    assert ok and worst >= max(lv)
    try:
        cr.load_set([1, 0])
        raise AssertionError("unsorted set accepted")
    except cr.MathError as e:
        assert e.args == ("NotSorted", 5)
    try:
        cr.kinked_rate(1, 0, 0, 0, 0)
        raise AssertionError("bad kink accepted")
    except ValueError as e:  # MathError is a ValueError
        assert e.args[1] == 3


def test_files_round_trip():
    s = cr.load_set_file(str(FIX / "NVDA-XNAS-2-63c7ce73.json"))
    assert s.n == 1000 and s.closure_type == 2 and s.asset == "NVDA:XNAS"
    assert s.asset_id == cr.asset_id("NVDA:XNAS")
    assert s.scenario_hash == "0xdba636a4e91124b94b147e6db290603769636de2331e87f86a453071b50b13d9"
    assert cr.unpack_z(s.packed(), s.n) == s.z
    doc, name = cr.build_set("NVDA:XNAS", 2, s.z, meta={"x": 1})
    assert name == "NVDA-XNAS-2-63c7ce73.json" and doc["scenarioHash"] == s.scenario_hash and doc["meta"] == {"x": 1}
    b = cr.load_bundle(str(FIX / "example-bundle.json"))
    assert b["params"]["kStress"] == 256 and b["params"]["alpha"] == WAD // 1000
    assert b["sets"][0].content_hash == s.content_hash
    assert b["sigmas"] == [(s.asset_id, 2, 4 * WAD // 100)]
    j = b["joint"]
    assert j["k"] == 256 and len(j["columns"]) == 2
    assert j["columns"][s.asset_id]["columnHash"] == "0xeb29fd7416935eaed593e06e349f633cfc9bfce3ca3144440da8cf23bfc32eea"
    cols = [(c["asset"], c["z"]) for c in j["columns"].values()]
    jdoc, jname = cr.build_joint(cols)
    assert jname == "joint-256adcb5.json" and jdoc["contentHash"] == j["contentHash"]
    assert cr.validate_file(str(FIX / "example-bundle.json"))["ok"] is True
    with tempfile.TemporaryDirectory() as d:
        bad = dict(doc)
        bad["scenarioHash"] = "0x" + "00" * 32
        p = Path(d) / "bad.json"
        p.write_text(json.dumps(bad))
        try:
            cr.validate_file(str(p))
            raise AssertionError("bad hash accepted")
        except cr.FileError as e:
            assert ".scenarioHash" in str(e)


if __name__ == "__main__":
    n = 0
    for k, f in sorted(globals().items()):
        if k.startswith("test_") and callable(f):
            f()
            n += 1
            print(f"ok  {k}")
    print(f"risk-py smoke: {n} passed (credence_risk {cr.__version__})")
