"""Proposal calldata: the ABI encoders against Foundry's `cast calldata` (skipped without Foundry), and the
RiskParams mapping."""

import shutil
import subprocess

import pytest

from credence_cal import proposal as pr

AID = "0x2ba7fe0221993f0b564e6bd78704eab0e0162888663625d7124a5d01aa95c620"
PACKED = ["0x" + "ab" * 32, "0x" + "00" * 31 + "07"]


def test_risk_params_are_the_struct_in_order_and_fit_the_types():
    p = pr.risk_params()
    assert list(p) == ["alpha", "kappa", "theta", "costOfCap", "eta", "beta", "uMax", "minPremium", "kStress"]
    assert all(int(p[k]) < 2**64 for k in p) and p["kStress"] == 256
    assert len(pr.enc_params(p)) == 4 + 9 * 32


@pytest.mark.skipif(shutil.which("cast") is None, reason="Foundry cast not installed")
def test_encoders_match_cast():
    def cast(*a):
        return subprocess.run(["cast", "calldata", *a], capture_output=True, text=True, check=True).stdout.strip()

    p = pr.risk_params()
    tup = "(" + ",".join(str(p[k]) for k in p) + ")"
    arr = "[" + ",".join(PACKED) + "]"
    assert cast(pr.SIG_PARAMS, tup) == "0x" + pr.enc_params(p).hex()
    assert cast(pr.SIG_FLOOR, AID, "2", "12345") == "0x" + pr.enc_floor(AID, 2, 12345).hex()
    assert cast(pr.SIG_SET, AID, "3", arr, "17") == "0x" + pr.enc_set(AID, 3, PACKED, 17).hex()
    assert cast(pr.SIG_JOINT, AID, arr) == "0x" + pr.enc_joint(AID, PACKED).hex()
