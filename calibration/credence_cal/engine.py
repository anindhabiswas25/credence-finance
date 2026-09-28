"""The only door to engine math (risk-core). Two interchangeable backends with one interface:

- `PyEngine`: BE-chain's PyO3 bindings (`crates/risk-py`, module `credence_risk`, built into
  calibration/.venv by `make cal-install`). Fast; the default.
- `CliEngine`: BE-chain's `risk-cli` (JSON in/out, one process per call). Slow; used by the tests to
  cross-check `PyEngine` call by call, and as a fallback.

Both run the same risk-core integer code, so they return identical integers. Nothing in this package
may compute a safe LTV, premium, loss vector, capacity, lot or settlement any other way.
All amounts are integers: WAD ratios/prices, loan units (6 decimals), collateral base units.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Protocol

from .common import ROOT

REPO = ROOT.parent


def pack_u64(values: list[int]) -> list[str]:
    out = []
    for i in range(0, len(values), 4):
        wd = 0
        for lane, v in enumerate(values[i:i + 4]):
            wd |= int(v) << (64 * lane)
        out.append("0x" + format(wd, "064x"))
    return out


class Engine(Protocol):
    def load_set(self, z: list[int]) -> Any: ...  # ascending scenario set
    def load_joint_column(self, z: list[int]) -> Any: ...  # K joint values in closure order (not sorted)
    def safe_ltv_from_set(self, s: Any, alpha: int, sigma: int, dividend: int, kappa: int, max_ltv: int) -> int: ...
    def quote_cover(self, s: Any, sigma: int, dividend: int, kappa: int, collateral_value: int, debt_projected: int,
                    closure_days: int, util_after: int, theta: int, cost_of_cap: int, eta: int, beta: int,
                    min_premium: int) -> tuple[int, int, int]: ...
    def loss_vector(self, joint: Any, collateral_value: int, debt_projected: int, sigma: int, dividend: int,
                    kappa: int) -> list[int]: ...
    def pool_capacity(self, current: list[int], add: list[int], uncovered: list[tuple], kappa: int, equity: int,
                      u_max: int) -> tuple[bool, int, int]: ...
    def liquidation_lot(self, debt: int, qty: int, sizing_price: int, hf_price: int, lt: int, h_star: int, lam: int,
                        coll_dec: int, loan_dec: int) -> int: ...
    def settle_position(self, x: int, q_before: int, blended_price: int, debt: int, lam: int, coll_dec: int,
                        loan_dec: int) -> dict: ...
    def kinked_rate(self, u: int, r0: int, s1: int, s2: int, u_kink: int) -> int: ...
    def projected_debt(self, debt: int, rate: int, days: int) -> int: ...
    def sigma_min_allowed(self, current: int, days: int) -> int: ...
    # ADR-0106 files, built by the same risk-core code that validates them (so the hashes cannot drift)
    def build_set(self, asset: str, closure_type: int, z: list[int], meta: dict) -> dict: ...
    def build_joint(self, columns: list[tuple[str, list[int]]], meta: dict) -> dict: ...


class CliEngine:
    """risk-cli backend. Binary: $RISK_CLI, else target/quant/release/risk-cli (built by
    `CARGO_TARGET_DIR=target/quant cargo build --release -p credence-risk-cli`), else PATH."""

    def __init__(self, binary: str | None = None):
        cand = binary or os.environ.get("RISK_CLI") or str(REPO / "target" / "quant" / "release" / "risk-cli")
        self.bin = cand if Path(cand).exists() else shutil.which("risk-cli")
        if not self.bin:
            raise RuntimeError("risk-cli not found; build it with CARGO_TARGET_DIR=target/quant cargo build --release -p credence-risk-cli")

    def _call(self, cmd: str, args: dict) -> dict:
        r = subprocess.run([self.bin, cmd, "-"], input=json.dumps(args), capture_output=True, text=True)
        out = json.loads(r.stdout or "{}")
        if r.returncode != 0 or "error" in out:
            raise ValueError(f"risk-cli {cmd}: {out or r.stderr}")
        return out

    def load_set(self, z: list[int]) -> list[int]:
        return list(z)

    def load_joint_column(self, z: list[int]) -> list[int]:
        return [int(v) for v in z]

    def safe_ltv_from_set(self, s, alpha, sigma, dividend, kappa, max_ltv):
        return int(self._call("safe-ltv-from-set", {"set": s, "alpha": str(alpha), "sigma": str(sigma),
                                                    "dividend": str(dividend), "kappa": str(kappa), "maxLtv": str(max_ltv)})["safeLtv"])

    def quote_cover(self, s, sigma, dividend, kappa, collateral_value, debt_projected, closure_days, util_after, theta,
                    cost_of_cap, eta, beta, min_premium):
        o = self._call("quote-cover", {"set": s, "sigma": str(sigma), "dividend": str(dividend), "kappa": str(kappa),
                                       "collateralValue": str(collateral_value), "debtProjected": str(debt_projected),
                                       "closureDays": closure_days, "utilAfter": str(util_after), "theta": str(theta),
                                       "costOfCap": str(cost_of_cap), "eta": str(eta), "beta": str(beta),
                                       "minPremium": str(min_premium)})
        return int(o["premium"]), int(o["expectedLoss"]), int(o["expectedShortfall"])

    def loss_vector(self, joint, collateral_value, debt_projected, sigma, dividend, kappa):
        o = self._call("loss-vector", {"joint": joint, "collateralValue": str(collateral_value),
                                       "debtProjected": str(debt_projected), "sigma": str(sigma),
                                       "dividend": str(dividend), "kappa": str(kappa)})
        return [int(x) for x in o["losses"]]

    def pool_capacity(self, current, add, uncovered, kappa, equity, u_max):
        o = self._call("pool-capacity", {
            "k": len(current), "packedCurrent": pack_u64(current), "packedAdd": pack_u64(add),
            "uncovered": [{"joint": j, "sigma": str(s), "dividend": str(d), "collateralValue": str(c), "safeLtv": str(sl)}
                          for j, s, d, c, sl in uncovered],
            "kappa": str(kappa), "equity": str(equity), "uMax": str(u_max)})
        return bool(o["ok"]), int(o["utilAfter"]), int(o["worstLoss"])

    def liquidation_lot(self, debt, qty, sizing_price, hf_price, lt, h_star, lam, coll_dec, loan_dec):
        return int(self._call("liquidation-lot", {"debt": str(debt), "qty": str(qty), "sizingPrice": str(sizing_price),
                                                  "hfPrice": str(hf_price), "lt": str(lt), "hStar": str(h_star),
                                                  "lambda": str(lam), "collDec": coll_dec, "loanDec": loan_dec})["x"])

    def settle_position(self, x, q_before, blended_price, debt, lam, coll_dec, loan_dec):
        o = self._call("settle", {"x": str(x), "qtyBefore": str(q_before), "blendedPrice": str(blended_price),
                                  "debt": str(debt), "lambda": str(lam), "collDec": coll_dec, "loanDec": loan_dec})
        return {k: (bool(v) if k == "fullClose" else int(v)) for k, v in o.items()}

    def kinked_rate(self, u, r0, s1, s2, u_kink):
        return int(self._call("kinked-rate", {"utilization": str(u), "r0": str(r0), "s1": str(s1), "s2": str(s2),
                                              "uKink": str(u_kink)})["rate"])

    def projected_debt(self, debt, rate, days):
        return int(self._call("projected-debt", {"debt": str(debt), "rate": str(rate), "days": days})["debtProjected"])

    def sigma_min_allowed(self, current, days):
        return int(self._call("sigma-min-allowed", {"current": str(current), "days": days})["minAllowed"])

    def build_set(self, asset, closure_type, z, meta):
        return self._call("build-set", {"asset": asset, "closureType": int(closure_type), "z": [int(v) for v in z], "meta": meta})

    def build_joint(self, columns, meta):
        return self._call("build-joint", {"columns": [{"asset": a, "z": [int(v) for v in z]} for a, z in columns], "meta": meta})

    def validate_file(self, path: Path) -> dict:
        """`risk-cli validate-set <file>`: the ADR-0106 validator (a bundle validates every file it references)."""
        r = subprocess.run([self.bin, "validate-set", str(path)], capture_output=True, text=True)
        out = json.loads(r.stdout or "{}")
        if r.returncode != 0 or not out.get("ok", False):
            raise ValueError(f"validate-set {path}: {out or r.stderr}")
        return out


class PyEngine:
    """risk-py backend (`credence_risk`, BE-chain A3): risk-core in-process through PyO3. Every method is a
    passthrough with the same argument order; sets stay in Rust memory as `ScenarioSet` handles."""

    def __init__(self):
        import credence_risk  # type: ignore[import-not-found]

        self.m = credence_risk

    def load_set(self, z):
        return self.m.load_set([int(v) for v in z])

    def load_joint_column(self, z):
        return [int(v) for v in z]  # risk-py takes joint columns as int16 lists (unsorted, closure order)

    def safe_ltv_from_set(self, s, alpha, sigma, dividend, kappa, max_ltv):
        return int(self.m.safe_ltv_from_set(s, alpha, sigma, dividend, kappa, max_ltv))

    def quote_cover(self, s, sigma, dividend, kappa, collateral_value, debt_projected, closure_days, util_after, theta,
                    cost_of_cap, eta, beta, min_premium):
        p, el, es = self.m.quote_cover(s, sigma, dividend, kappa, collateral_value, debt_projected, closure_days,
                                       util_after, theta, cost_of_cap, eta, beta, min_premium)
        return int(p), int(el), int(es)

    def loss_vector(self, joint, collateral_value, debt_projected, sigma, dividend, kappa):
        return [int(x) for x in self.m.loss_vector(joint, collateral_value, debt_projected, sigma, dividend, kappa)]

    def pool_capacity(self, current, add, uncovered, kappa, equity, u_max):
        ok, util, worst = self.m.pool_capacity(current, add, list(uncovered), kappa, equity, u_max)
        return bool(ok), int(util), int(worst)

    def liquidation_lot(self, debt, qty, sizing_price, hf_price, lt, h_star, lam, coll_dec, loan_dec):
        return int(self.m.liquidation_lot(debt, qty, sizing_price, hf_price, lt, h_star, lam, coll_dec, loan_dec))

    def settle_position(self, x, q_before, blended_price, debt, lam, coll_dec, loan_dec):
        o = self.m.settle_position(x, q_before, blended_price, debt, lam, coll_dec, loan_dec)
        return {k: (bool(v) if k == "fullClose" else int(v)) for k, v in o.items()}

    def kinked_rate(self, u, r0, s1, s2, u_kink):
        return int(self.m.kinked_rate(u, r0, s1, s2, u_kink))

    def projected_debt(self, debt, rate, days):
        return int(self.m.projected_debt(debt, rate, days))

    def sigma_min_allowed(self, current, days):
        return int(self.m.sigma_min_allowed(current, days))

    def build_set(self, asset, closure_type, z, meta):
        return self.m.build_set(asset, int(closure_type), [int(v) for v in z], meta)[0]

    def build_joint(self, columns, meta):
        return self.m.build_joint([(a, [int(v) for v in z]) for a, z in columns], meta)[0]

    def validate_file(self, path: Path) -> dict:
        return self.m.validate_file(str(path))


def default_engine() -> Engine:
    """risk-py when it is installed (`make cal-install`), else risk-cli."""
    try:
        return PyEngine()
    except ImportError:
        return CliEngine()
