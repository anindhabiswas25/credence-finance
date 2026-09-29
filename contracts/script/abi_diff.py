#!/usr/bin/env python3
"""Compare two frozen ABI directories (deployments/abis/<old> → <new>) and write a changelog.

Every entry is keyed by its signature (type + name + input types). The check fails if an entry of `old` is
missing from `new` (a breaking change) unless the signature is listed in ALLOWED_BREAKS with a reason.

    python3 contracts/script/abi_diff.py deployments/abis/v1 deployments/abis/v2 [--write CHANGELOG.md]
"""
import json
import sys
from pathlib import Path

# Deliberate breaking changes per release pair (old dir name → new dir name), with the rule that requires them.
_V1_POOL = "ADR-0110: v2 pool events carry the epoch and the resulting state (indexer projections, Guide §10.3)"
_V1_AH = "ADR-0110: v2 auction events carry market, epoch, tranche and escrow (indexer projections)"
ALLOWED = {
    ("v0", "v1"): {
        "event ReportAccepted(bytes32,uint8,uint256,uint40,uint64)": "R-25: replaced by the 6-argument event with marketStatus",
        # R-24 / ADR-0108: the engine is a router in front of two Stylus programs, so its auction math forwards (pure →
        # view). Same selectors and outputs; both are called with STATICCALL, so no caller changes.
        "function liquidationLot(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint8)": "R-24: pure → view",
        "function precloseLot(uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint8)": "R-24: pure → view",
        "function clear(uint256[],uint256[],bytes32[],uint256,uint256)": "R-24: pure → view",
    },
    ("v1", "v2"): {
        "event PositionSettled(uint64,address,uint256,uint256,uint256,uint256)":
            "ADR-0110 (PM ruling S2 BE-backend #1): marketId, borrower, auctionId, collateralSold, proceeds, penalty, "
            "shortfall, refund, debtAfter",
        "function writeCover((bytes32,bytes32,address,uint8,uint16,uint64,uint64,uint256,uint256),uint256)":
            "ADR-0110: one pool computation per cover; the second argument is maxPremium and it returns the premium",
        "function backstopBuy(bytes32,address,uint256,uint256)": "ADR-0110: takes the auctionId, returns the amount paid",
        "function epoch(uint64)": "ADR-0110: the Epoch struct records the epoch's flows (INV-POOL-01)",
        "function auction(uint64)": "ADR-0110: the Auction struct adds venueEpoch, startPrice, full, settled",
        "function startGda(bytes32,address,uint256,uint256,uint256,uint256)": "ADR-0110: returns the gdaId",
        "function gdaBuy(uint64,uint256,uint256)": "ADR-0110: returns the cost",
        "event EpochOpened(uint64)": _V1_POOL,
        "event EpochSnapshotted(uint64,uint256)": _V1_POOL,
        "event EpochSettled(uint64,uint256,uint256,uint256,uint256,uint256,uint256)": _V1_POOL,
        "event CoverWritten(uint64,bytes32,address,uint64,uint256,uint256)": _V1_POOL,
        "event ShortfallPaid(uint256)": _V1_POOL,
        "event BackstopBought(bytes32,uint256,uint256)": _V1_POOL,
        "event WithdrawClaimed(uint64,address,uint256)": _V1_POOL,
        "event RiskFeeCredited(uint256)": _V1_POOL,
        "event PenaltyCredited(uint256)": _V1_POOL,
        "event BondCredited(uint256)": _V1_POOL,
        "event AuctionCreated(uint64,uint8,bytes32,uint64,uint40[4])": _V1_AH,
        "event LotsFixed(uint64,uint256,uint256)": _V1_AH,
        "event BidCommitted(uint64,address,bytes32,uint256)": _V1_AH,
        "event BidRevealed(uint64,address,uint256,uint256)": _V1_AH,
        "event BidPlaced(uint64,address,uint256,uint256)": _V1_AH,
        "event AuctionCleared(uint64,uint256,uint256,uint256,uint256)": _V1_AH,
        "event GdaStarted(uint64,bytes32,address,uint256,uint256,uint256,uint256)": _V1_AH,
        "event GdaBuy(uint64,address,uint256,uint256)": "ADR-0110: renamed GdaBought (S3 brief A2)",
    },
    ("v2", "v3"): {
        "function openSettlement(bytes32,address[])": "ADR-0111: returns the new settlementId (the market lot id)",
        "function fallbackAdvance(bytes32,uint256,uint256)":
            "ADR-0111: implemented (S3 reverted NotImplemented, so the implementation ABI said pure)",
        "event RedemptionClaimed(uint256,uint256)":
            "ADR-0111: never emitted; the pool claims redemptions and emits RedemptionClaimed(epochId, requestId, assets, pnl)",
        "event FallbackAdvanced(bytes32,uint256,uint256,uint256)":
            "ADR-0111: never emitted by the pool; the adapter emits FallbackAdvanced(id, …) and the pool RedemptionRequested",
    },
}
ALLOWED_BREAKS = {}


def canon(t):
    if t["type"].startswith("tuple"):
        return "(" + ",".join(canon(c) for c in t["components"]) + ")" + t["type"][5:]
    return t["type"]


def sig(e):
    if e["type"] in ("constructor", "fallback", "receive"):
        return e["type"]
    return f'{e["type"]} {e["name"]}(' + ",".join(canon(i) for i in e.get("inputs", [])) + ")"


def load(d):
    out = {}
    for f in sorted(Path(d).glob("*.json")):
        out[f.stem] = {sig(e): e for e in json.loads(f.read_text())}
    return out


def main():
    old_dir, new_dir = sys.argv[1], sys.argv[2]
    write = sys.argv[sys.argv.index("--write") + 1] if "--write" in sys.argv else None
    old, new = load(old_dir), load(new_dir)
    ALLOWED_BREAKS.update(ALLOWED.get((Path(old_dir).name, Path(new_dir).name), {}))
    breaks, lines = [], []
    lines.append(f"# ABI changes {Path(old_dir).name} → {Path(new_dir).name}\n")
    lines.append("Generated by `contracts/script/abi_diff.py`. Additive unless listed under *Breaking*.\n")
    # errors added to the shared catalogue show up in every ABI that inherits it; list them once
    common_added = set(new.get("ICredenceErrors", {})) - set(old.get("ICredenceErrors", {}))
    per_file = {}
    for name in sorted(set(old) | set(new)):
        o, n = old.get(name, {}), new.get(name, {})
        if name not in new:
            breaks.append(f"{name}: file removed")
            continue
        added = sorted(set(n) - set(o))
        removed = sorted(set(o) - set(n))
        changed = sorted(s for s in set(o) & set(n) if o[s].get("outputs") != n[s].get("outputs")
                         or o[s].get("stateMutability") != n[s].get("stateMutability"))
        for s in removed + changed:
            if s not in ALLOWED_BREAKS:
                breaks.append(f"{name}: {s}")
        per_file[name] = (name not in old, added, removed, changed)
    if common_added:
        lines.append("## Added to every ABI (the shared `ICredenceErrors` catalogue)\n")
        lines += [f"- `{s}`" for s in sorted(common_added)]
        lines.append("")
    lines.append("## Breaking\n")
    lines += [f"- `{s}`: {why}" for s, why in ALLOWED_BREAKS.items()] or ["- none"]
    lines.append("")
    lines.append("## Per file\n")
    for name, (is_new, added, removed, changed) in per_file.items():
        own = [s for s in added if s not in common_added]
        if not (is_new or own or removed or changed):
            continue
        lines.append(f"### {name}{' (new)' if is_new else ''}\n")
        if is_new:
            lines.append(f"- {len(added)} entries")
        lines += [f"- added `{s}`" for s in own if not is_new]
        lines += [f"- removed `{s}`" for s in removed]
        lines += [f"- changed outputs/mutability `{s}`" for s in changed]
        lines.append("")
    text = "\n".join(lines)
    if write:
        Path(write).write_text(text)
    if breaks:
        print("UNEXPECTED BREAKING CHANGES:\n  " + "\n  ".join(breaks), file=sys.stderr)
        sys.exit(1)
    print(f"ok: {len(per_file)} ABIs, additive except {len(ALLOWED_BREAKS)} allowed break(s)")


if __name__ == "__main__":
    main()
