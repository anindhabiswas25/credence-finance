"""The engine door (credence_cal.engine): packing, and the risk-cli backend against the guide's golden vectors
(Appendix A). The risk-cli checks are skipped when no binary is built; they never touch the network."""

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
    joint = cli.load_set([-9000, -5000, 0, 1000])
    add = cli.loss_vector(joint, 18_000 * 10**6, 13_500 * 10**6, w(0.04), 0, w(0.03))
    assert len(add) == 4 and add[0] >= add[1] >= add[2] == add[3] == 0
    ok, util, worst = cli.pool_capacity([0] * 4, add, [], w(0.03), 100_000 * 10**6, w(0.5))
    assert ok and worst == add[0] and util == add[0] * WAD // (100_000 * 10**6)
