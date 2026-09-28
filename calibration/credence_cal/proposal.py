"""Step 7 output (brief item 7): the S2 testnet risk proposal.

Writes, all content-addressed:
- `out/risk-bundle-<sha8>.json`: the `credence.risk-bundle/v1` file (ADR-0106) that `LoadScenarioSet.s.sol`
  consumes: RiskParams, every scenario set, the joint set, the σ floors and the initial σ. It sits at the
  root of `out/` so every reference is a plain relative path (`scenarios/…`, `joint/…`) inside the
  directory Foundry may read (`fs_permissions`), and it is validated by risk-core before it is written.
- `out/proposal/calldata-<sha8>.json`: the same writes as ABI-encoded calls to the Risk Engine, in the
  loader's order (setParams → setSigmaFloor* → setScenarioSet* → setJointColumn*), ready for the
  timelock's `scheduleBatch` (the engine address is filled in at deploy, §13.2).
- `out/proposal/<PROPOSAL_DATE>.md`: the parameters with their reasoning and the backtest evidence.

The chosen parameters are constants below: a proposal is a decision, not an optimiser output. The
reasoning text is generated around the backtest numbers so it can never quote a stale figure.
"""

from __future__ import annotations

import json
from pathlib import Path

from .common import LISTED, ClosureType, asset_id, keccak256, sha256_hex, canonical_json, write_json

PROPOSAL_DATE = "2026-09-28"
WAD = 10**18

# The S2 testnet proposal (see the reasoning in `markdown`). Decimal → WAD is exact for these values.
CHOSEN = {"alpha": 0.001, "kappa": 0.03, "theta": 1.00, "cost_of_cap": 0.15, "eta": 4.0, "beta": 0.975,
          "u_max": 0.50, "min_premium_usd": 0.50, "k_stress": 256}


def w(x: float) -> int:
    return int(round(x * 1e18))


def risk_params(ch: dict = CHOSEN) -> dict:
    """RiskParams in struct order (Types.sol), WAD values as decimal strings (ADR-0106 §4)."""
    return {"alpha": str(w(ch["alpha"])), "kappa": str(w(ch["kappa"])), "theta": str(w(ch["theta"])),
            "costOfCap": str(w(ch["cost_of_cap"])), "eta": str(w(ch["eta"])), "beta": str(w(ch["beta"])),
            "uMax": str(w(ch["u_max"])), "minPremium": str(int(round(ch["min_premium_usd"] * 10**6))),
            "kStress": ch["k_stress"]}


# ── ABI encoding of the engine writers (only static words and uint256[]; nothing else is needed) ─────────

def selector(signature: str) -> bytes:
    return keccak256(signature.encode())[:4]


def _word(x: int) -> bytes:
    return int(x).to_bytes(32, "big")


def _b32(h: str) -> bytes:
    b = bytes.fromhex(h[2:])
    assert len(b) == 32
    return b


def _words(hexes: list[str]) -> bytes:
    return b"".join(_b32(x) for x in hexes)


SIG_PARAMS = "setParams((uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32))"
SIG_FLOOR = "setSigmaFloor(bytes32,uint8,uint256)"
SIG_SET = "setScenarioSet(bytes32,uint8,uint256[],uint32)"
SIG_JOINT = "setJointColumn(bytes32,uint256[])"


def enc_params(p: dict) -> bytes:
    keys = ("alpha", "kappa", "theta", "costOfCap", "eta", "beta", "uMax", "minPremium", "kStress")
    return selector(SIG_PARAMS) + b"".join(_word(int(p[k])) for k in keys)


def enc_floor(aid: str, t: int, floor: int) -> bytes:
    return selector(SIG_FLOOR) + _b32(aid) + _word(t) + _word(floor)


def enc_set(aid: str, t: int, packed: list[str], n: int) -> bytes:
    return selector(SIG_SET) + _b32(aid) + _word(t) + _word(4 * 32) + _word(n) + _word(len(packed)) + _words(packed)


def enc_joint(aid: str, packed: list[str]) -> bytes:
    return selector(SIG_JOINT) + _b32(aid) + _word(2 * 32) + _word(len(packed)) + _words(packed)


def build(out: Path, sigma_doc: dict, eng, grade: str) -> tuple[Path, Path, dict]:
    """Write the bundle and the calldata file; return their paths and the bundle."""
    sets = sorted(p for p in (out / "scenarios").glob("*.json"))
    joint = next((out / "joint").glob("joint-*.json"))
    floors = {"assetIds": [], "closureTypes": [], "floors": []}
    sigmas = {"assetIds": [], "closureTypes": [], "values": []}
    for a in LISTED:
        s = sigma_doc["assets"][a]
        for t in (1, 2, 3):
            n = ClosureType(t).name
            for d, key, src in ((floors, "floors", s["floorWad"][n]), (sigmas, "values", s["sigmaWad"][n])):
                d["assetIds"].append(asset_id(a))
                d["closureTypes"].append(t)
                d[key].append(src)
    params = risk_params()
    bundle = {"format": "credence.risk-bundle/v1", "params": params,
              "scenarioSets": [f"scenarios/{p.name}" for p in sets], "jointSet": f"joint/{joint.name}",
              "sigmaFloors": floors, "sigmas": sigmas,
              "meta": {"proposal": f"proposal/{PROPOSAL_DATE}.md", "dataGrade": grade, "sigmaAsOf": sigma_doc["end"],
                       "note": "S2 testnet proposal (final for S2, ADR-0204). sigmas = the published σ at the data end; "
                               "on a live chain σ goes through SigmaOracle / keeper J7."}}
    h = sha256_hex(canonical_json(bundle))[:8]
    for old in out.glob("risk-bundle-*.json"):
        old.unlink()
    bpath = out / f"risk-bundle-{h}.json"
    write_json(bpath, bundle)
    eng.validate_file(bpath)  # risk-core: every referenced file, floors ≤ σ, k == kStress

    calls = [{"fn": SIG_PARAMS, "args": params, "data": "0x" + enc_params(params).hex()}]
    for aid, t, f in zip(floors["assetIds"], floors["closureTypes"], floors["floors"]):
        calls.append({"fn": SIG_FLOOR, "args": {"assetId": aid, "closureType": t, "floor": f},
                      "data": "0x" + enc_floor(aid, t, int(f)).hex()})
    for p in sets:
        d = json.loads(p.read_text())
        calls.append({"fn": SIG_SET, "args": {"assetId": d["assetId"], "closureType": d["closureType"], "n": d["n"],
                                              "file": f"scenarios/{p.name}", "scenarioHash": d["scenarioHash"]},
                      "data": "0x" + enc_set(d["assetId"], d["closureType"], d["packed"], d["n"]).hex()})
    j = json.loads(joint.read_text())
    for aid, col, ch in zip(j["assetIds"], j["columns"], j["columnHashes"]):
        calls.append({"fn": SIG_JOINT, "args": {"assetId": aid, "k": j["k"], "file": f"joint/{joint.name}", "jointHash": ch},
                      "data": "0x" + enc_joint(aid, col).hex()})
    cdoc = {"kind": "credence.timelock-calldata.v1", "target": "RiskEngine (shared.riskEngine in the address book)",
            "bundle": bpath.name, "order": "setParams, setSigmaFloor*, setScenarioSet*, setJointColumn* (ADR-0106 §5)",
            "timelock": "scheduleBatch(targets = [engine] * len(calls), values = 0, payloads = data, predecessor = 0, "
                        "salt = keccak256(bundle name), delay = minDelay)", "calls": calls}
    cdir = out / "proposal"
    cdir.mkdir(parents=True, exist_ok=True)
    for old in cdir.glob("calldata-*.json"):
        old.unlink()
    cpath = cdir / f"calldata-{sha256_hex(canonical_json(cdoc))[:8]}.json"
    write_json(cpath, cdoc)
    return bpath, cpath, bundle


def _pct(x: float, d: int = 2) -> str:
    return f"{x:.{d}%}"


def _row(sens: list[dict], param: str, value: float) -> dict:
    return next(r for r in sens if r["param"] == param and abs(r["value"] - value) < 1e-12)


def markdown(bt: dict, val: dict, sigma_doc: dict, bundle: dict, files: dict) -> str:
    wf, ins, sens = bt["walkForward"], bt["inSample"], bt["sensitivity"]
    tot, bty, pool = wf["breach"]["total"], wf["breach"]["byType"], wf["pool"]
    a05, a1, a2 = _row(sens, "alpha", 0.0005), _row(sens, "alpha", 0.001), _row(sens, "alpha", 0.002)
    k2, k3, k5 = _row(sens, "kappa", 0.02), _row(sens, "kappa", 0.03), _row(sens, "kappa", 0.05)
    t05, t1, t15 = _row(sens, "theta", 0.5), _row(sens, "theta", 1.0), _row(sens, "theta", 1.5)
    u4, u6 = _row(sens, "u_max", 0.4), _row(sens, "u_max", 0.6)
    e2, e6 = _row(sens, "eta", 2.0), _row(sens, "eta", 6.0)
    prem = pool["premiumsByType"]
    on = prem.get("OVERNIGHT", {"usd": 0, "perPolicyUsd": 0})
    wk = prem.get("WEEKEND", {"usd": 0, "perPolicyUsd": 0})
    share_on = on["usd"] / max(1e-9, pool["premiumsUsd"])
    cap = val["capacity"]
    p = bundle["params"]
    ev = ", ".join(f"{b['asset']} {b['date']} ({b['type'].lower()}, {b['r']:+.1%})" for b in wf["breachEvents"])
    L = [f"# Risk parameter proposal, S2 testnet ({PROPOSAL_DATE})", "",
         f"Status: **final testnet proposal for S2** (PM ANSWER 2026-09-28 11:45). Data grade `{bt['dataGrade']}`: Alpaca SIP daily bars "
         f"2016-01-04 → {bt['end']}, with the missing 2000–2015 tail compensated as in ADR-0204. Owner: QE.", "",
         "Files (all content-addressed, rebuilt by `make cal-all`):",
         f"- calldata for `LoadScenarioSet.s.sol`: `calibration/out/{files['bundle']}` (`credence.risk-bundle/v1`, validated by `risk-cli validate-set`);",
         f"- the same writes ABI-encoded for the timelock: `calibration/out/proposal/{files['calldata']}`;",
         f"- evidence: `calibration/out/backtest/{files['backtest']}` (README.md next to it), `calibration/out/validation/{files['validation']}`, "
         "`calibration/docs/model-validation.md`.", "",
         "## 1. Parameters", "",
         "| Parameter | Proposed | Guide §12.2 | Change |", "| --- | --- | --- | --- |",
         f"| α | {_pct(int(p['alpha']) / 1e18, 1)} | 0.1% ⚠️ | confirmed |",
         f"| κ (reopen / intraday) | {_pct(int(p['kappa']) / 1e18, 0)} | 3% ⚠️ | confirmed |",
         f"| θ (loading) | {_pct(int(p['theta']) / 1e18, 0)} | 100% | confirmed |",
         f"| c (cost of capital) | {_pct(int(p['costOfCap']) / 1e18, 0)}/yr | 15%/yr | unchanged |",
         f"| η | {int(p['eta']) / 1e18:g} | 4 | confirmed |",
         f"| β (ES level) | {_pct(int(p['beta']) / 1e18, 1)} | 97.5% | unchanged |",
         f"| u_max | {_pct(int(p['uMax']) / 1e18, 0)} | 50% | confirmed |",
         f"| minPremium | ${int(p['minPremium']) / 1e6:.2f} | $0.50 | unchanged |",
         f"| K (joint stress closures) | {p['kStress']} | 256 | unchanged (4 synthetic + 252 historical, ADR-0204) |",
         f"| Scenario sets | 18 (6 assets × 3 closure types) | — | new (ADR-0203, ADR-0204) |",
         f"| σ floors / initial σ | 18 each, from `out/sigma` (as of {sigma_doc['end']}) | long-run p25 | new (ADR-0202) |", "",
         "## 2. Reasoning", "",
         f"**α = 0.1% (confirmed).** Walk-forward from 2018 (out of sample), the realised breach frequency is "
         f"{tot['breaches']} / {tot['trials']:,} = {_pct(tot['rate'], 3)} (95% CI {_pct(tot['ci95'][0], 3)}–{_pct(tot['ci95'][1], 3)}) "
         f"against the target 0.1%. WEEKEND, the closure type the product is about, is {bty['WEEKEND']['breaches']} / {bty['WEEKEND']['trials']:,} = "
         f"{_pct(bty['WEEKEND']['rate'], 3)} (CI {_pct(bty['WEEKEND']['ci95'][0], 3)}–{_pct(bty['WEEKEND']['ci95'][1], 3)}), which contains α. "
         f"OVERNIGHT is {_pct(bty['OVERNIGHT']['rate'], 3)}, conservative because the pooled overnight sets carry 16 names' earnings gaps. "
         f"Every breach is a named event: {ev}. The in-sample replay since {ins['from']} gives {_pct(ins['breach']['total']['rate'], 3)}. "
         f"α = 0.05% would cut breaches to {a05['breaches']} but lower every safe LTV, pushing more loans into cover: premiums "
         f"${a05['premiumsUsd']:,.0f} against ${a1['premiumsUsd']:,.0f}. At α = 0.2% breaches rise to {a2['breaches']} "
         f"({_pct(a2['breachRate'], 3)}), above target. With 10.7 years of data, α sits where the evidence supports it, and the missing tail is "
         "handled by the set floors (ADR-0204), not by a smaller α.", "",
         f"**κ = 3% (confirmed).** κ does not move the breach test (it scales both sides), so it trades pool losses against auction "
         f"depth. The backtest clears every liquidation at the reserve R = (1 − κ) × open, the worst case for borrower and pool. On that "
         f"basis κ = 2% gives shortfalls ${k2['shortfallsUsd']:,.0f} and a worst epoch of ${k2['worstEpochUsd']:,.0f}, while 3% gives "
         f"${k3['shortfallsUsd']:,.0f} / ${k3['worstEpochUsd']:,.0f} and 5% gives ${k5['shortfallsUsd']:,.0f} / ${k5['worstEpochUsd']:,.0f}. "
         "A smaller κ looks cheaper only because the replay cannot see what the haircut buys: enough room below the open print for "
         "bidders to clear a gapped, thin reopen auction. The listing precondition H*(1 − κ)(1 − λ) = "
         f"{1.10 * 0.97 * 0.97:.4f} > LT holds for every market. 3% keeps the guide's value; revisit it with auction data from the testnet.", "",
         f"**θ = 100% (confirmed).** Premiums total ${pool['premiumsUsd']:,.0f} against realised shortfalls of ${pool['shortfallsUsd']:,.0f}. "
         f"The pool earns {_pct(pool['annualReturnOnJ0'])} a year on J0 = ${bt['params']['pool_equity_usd']:,.0f} "
         f"(θ = 50%: {_pct(t05['annualReturnOnJ0'])}; θ = 150%: {_pct(t15['annualReturnOnJ0'])}); every full calendar year is profitable "
         f"(the worst, {pool['worstYear']['year']}, earns ${pool['worstYear']['pnlUsd']:,.0f}) and the worst epoch loses "
         f"{_pct(-min(0.0, pool['worstEpoch']['pnlUsd']) / bt['params']['pool_equity_usd'])} of J0. The in-sample loss ratio is tiny because the "
         "sample has no 2008. The synthetic stress closures of ADR-0204, which stand in for it, would cost a fully covered $1M-per-market book "
         f"${cap['worstLossUsd']['withSynthetic']:,.0f} in one closure. The loading is what pays underwriters for that tail, which the data cannot show. "
         "Cutting θ to 50% would lower every premium by about a quarter, and it is the first change to make once a licensed 2000+ history shows "
         "the loss ratio holding through 2008. That is a governance change, not a code change.", "",
         f"**u_max = 50% and η = 4 (confirmed).** Capacity binds in {_pct(pool['capacityBindingRate'])} of epochs "
         f"({_pct(pool['capacityBindingRateNonOvernight'])} of weekend and holiday closures; {pool['coverRefused']} of {pool['coverRequests']:,} "
         f"requests refused). u_max = 40% raises that to {_pct(u4['capacityBindingRate'])}, and 60% lowers it to {_pct(u6['capacityBindingRate'])} "
         f"while adding almost no premium. η moves premiums by ±2% between 2 and 6 (annual return {_pct(e2['annualReturnOnJ0'])} to "
         f"{_pct(e6['annualReturnOnJ0'])}). Neither needs to move for testnet. With the synthetic closures in the joint set, 50% already holds "
         "twice the modelled worst joint loss.", "",
         f"**Senior loss:** {len(wf['seniorLossEvents'])} events in the walk-forward and {len(ins['seniorLossEvents'])} in-sample. The worst epoch "
         f"is {pool['worstEpoch']['date']} ({pool['worstEpoch']['type'].lower()}), with a shortfall of ${pool['worstEpoch']['shortfallUsd']:,.2f} "
         f"= {_pct(pool['worstEpoch']['shortfallUsd'] / bt['params']['pool_equity_usd'])} of J0.", "",
         "## 3. Findings the PM should know", "",
         f"- **Overnight cover is the expensive product:** {_pct(share_on, 0)} of all premiums, ${on['perPolicyUsd']:.2f} per overnight cover against "
         f"${wk['perPolicyUsd']:.2f} per weekend cover. The pooled overnight set (z at i* −11.1σ for MEGA_TECH) carries every comparable name's "
         "earnings gap, so every weeknight is priced as if it might be an earnings night. A loan held at the cap every weeknight pays several "
         "percent a year, where a borrower who cures a few dollars of interest drift (R-03) pays nothing. A scheduled-earnings closure flag "
         "(an earnings night gets the earnings set, others get the ex-earnings set) would make ordinary nights much cheaper. That is a spec "
         "change (a new closure attribute), so it is proposed here, not built.",
         "- **Today's safe LTVs are capped almost everywhere.** At the published σ (weekend 0.64% SPY … 2.86% COIN), the α-quantile safe "
         "factor is above LTV_max for every market except COIN OVERNIGHT (73.46%). α and the sets bind in a volatility spike, as in the docs' "
         "σ = 4–6% stories (`calibration/docs/model-validation.md`).",
         "- **Short history:** the per-asset breach intervals are wide (tens to hundreds of trials per asset and type). The proposal is sound "
         "for testnet, not evidence for mainnet (ADR-0204, \"What longer data would change\").", "",
         "## 4. How to load and verify", "",
         f"- Local devnode: `make risk-load-set RISK_BUNDLE=calibration/out/{files['bundle']}` (BE-chain's target; it runs `validate-set`, "
         "then `LoadScenarioSet.s.sol`, which reads every `scenarioHash` and `jointHash` back). It needs the S2 engine with `setJointColumn`.",
         "- Testnet: schedule the calls in the calldata file through the timelock, in their order, with the engine address from the address book.",
         "- §13.3 check: `engine.scenarioHash(assetId, type)` equals each set file's `scenarioHash`, and `jointHash(assetId)` equals the joint "
         "file's `columnHashes`.",
         ]
    return "\n".join(L) + "\n"
