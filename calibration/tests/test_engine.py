"""The engine door (credence_cal.engine): packing, and the risk-cli backend against the guide's golden vectors
(Appendix A). The risk-cli checks are skipped when no binary is built; they never touch the network."""

import json

import pytest

from credence_cal import engine

WAD = 10**18


def w(x: float) -> int:
    return int(round(x * 1e18))


def test_pack_u64_lane_order():
    words = engine.pack_u64([1, 2, 3, 4, 5])
    assert words[0] == "0x" + format(4 << 192 | 3 << 128 | 2 << 64 | 1, "064x")
    assert words[1] == "0x" + format(5, "064x")


@pytest.fixture(scope="module")
def cli():
    try:
        return engine.CliEngine()
    except RuntimeError:
        pytest.skip("risk-cli not built (CARGO_TARGET_DIR=target/quant cargo build --release -p credence-risk-cli)")


def test_g01_kinked_rate(cli):
    r = cli.kinked_rate(w(0.85), w(0.02), w(0.06), w(0.80), w(0.90))
    assert abs(r - 76666666666666666) <= 1


def test_g05_safe_ltv_capped(cli):
    assert cli.safe_ltv_from_set(cli.load_set([-5897] * 10), w(0.001), w(0.03), 0, w(0.03), w(0.75)) == w(0.75)


def test_g12_liquidation_lot(cli):
    usd, tok = 10**6, 10**18
    x = cli.liquidation_lot(13_500 * usd, 100 * tok, w(153.648), w(158.40), w(0.80), w(1.10), w(0.03), 18, 6)
    assert abs(x / tok - 58.5131) < 1e-4


def test_loss_vector_and_capacity_agree(cli):
    joint = cli.load_joint_column([-9000, -5000, 0, 1000])
    add = cli.loss_vector(joint, 18_000 * 10**6, 13_500 * 10**6, w(0.04), 0, w(0.03))
    assert len(add) == 4 and add[0] >= add[1] >= add[2] == add[3] == 0
    ok, util, worst = cli.pool_capacity([0] * 4, add, [], w(0.03), 100_000 * 10**6, w(0.5))
    assert ok and worst == add[0] and util == add[0] * WAD // (100_000 * 10**6)


def test_build_set_matches_reference_packing_and_validates(cli, tmp_path):
    from credence_cal.setfile import file_name, pack_i16

    z = [-9318, -5000, -5000, 0, 12, 7000] * 3
    z.sort()
    doc = cli.build_set("NVDA:XNAS", 2, z, {"test": True})
    assert doc["packed"] == pack_i16(z) and doc["n"] == len(z) and doc["format"] == "credence.scenario-set/v1"
    p = tmp_path / file_name(doc)
    p.write_text(json.dumps(doc))
    assert cli.validate_file(p)["fileName"] == p.name


@pytest.fixture(scope="module")
def py():
    try:
        return engine.PyEngine()
    except ImportError:
        pytest.skip("risk-py not installed (make cal-install)")


def test_py_and_cli_agree_call_by_call(py, cli):
    """The backtest runs on PyEngine; every call it makes must equal risk-cli's answer."""
    z = sorted([-11144, -7208, -5898, -3000, -1200, -40, 0, 15, 900, 2500] * 30)
    joint = [-8160, -9330, -4484, -6734, 300, 0, -1000, 1200]  # closure order, not sorted
    ps, cs = py.load_set(z), cli.load_set(z)
    for sig in (w(0.012), w(0.04), w(0.09)):
        assert py.safe_ltv_from_set(ps, w(0.001), sig, w(0.004), w(0.03), w(0.75)) == \
            cli.safe_ltv_from_set(cs, w(0.001), sig, w(0.004), w(0.03), w(0.75))
        args = (sig, w(0.004), w(0.03), 18_000 * 10**6, 13_560 * 10**6, 3, w(0.2), w(1.0), w(0.15), w(4), w(0.975), 500_000)
        assert py.quote_cover(ps, *args) == cli.quote_cover(cs, *args)
        lv = py.loss_vector(py.load_joint_column(joint), 18_000 * 10**6, 13_560 * 10**6, sig, 0, w(0.03))
        assert lv == cli.loss_vector(cli.load_joint_column(joint), 18_000 * 10**6, 13_560 * 10**6, sig, 0, w(0.03))
        unc_p = [(py.load_joint_column(joint), sig, 0, 500_000 * 10**6, w(0.74))]
        unc_c = [(cli.load_joint_column(joint), sig, 0, 500_000 * 10**6, w(0.74))]
        assert py.pool_capacity([0] * 8, lv, unc_p, w(0.03), 200_000 * 10**6, w(0.5)) == \
            cli.pool_capacity([0] * 8, lv, unc_c, w(0.03), 200_000 * 10**6, w(0.5))
    lot = (13_500 * 10**6, 100 * 10**18, w(153.648), w(158.40), w(0.80), w(1.10), w(0.03), 18, 6)
    x = py.liquidation_lot(*lot)
    assert x == cli.liquidation_lot(*lot)
    assert py.settle_position(x, 100 * 10**18, w(156.024), 13_500 * 10**6, w(0.03), 18, 6) == \
        cli.settle_position(x, 100 * 10**18, w(156.024), 13_500 * 10**6, w(0.03), 18, 6)
    assert py.kinked_rate(w(0.85), w(0.02), w(0.06), w(0.8), w(0.9)) == cli.kinked_rate(w(0.85), w(0.02), w(0.06), w(0.8), w(0.9))
    assert py.projected_debt(10**12, w(0.0766), 4) == cli.projected_debt(10**12, w(0.0766), 4)
    assert py.build_set("SPY:XNAS", 3, z, {"m": 1}) == cli.build_set("SPY:XNAS", 3, z, {"m": 1})
