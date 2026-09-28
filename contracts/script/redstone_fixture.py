#!/usr/bin/env python3
"""Build RedStone on-chain payload fixtures from a recorded gateway response (clean-room, from the documented layout).

    redstone_fixture.py GATEWAY_JSON OUT_JSON

Package (big-endian): n × (feedId bytes32 ‖ value uint256, 8 decimals) ‖ timestampMs (6 B) ‖ valueByteSize (4 B = 32)
‖ n (3 B), followed by its 65-byte signature r‖s‖v. Payload: packages ‖ packageCount (2 B) ‖ unsignedMetadata ‖
metadataSize (3 B) ‖ marker 0x000002ed57011e0000. Values are converted from decimal strings exactly.
"""
import base64
import json
import sys
from decimal import Decimal

MARKER = bytes.fromhex("000002ed57011e0000")


def value8(v):
    return int((Decimal(str(v)) * Decimal(10**8)).to_integral_exact())


def package(p):
    pts = sorted(p["dataPoints"], key=lambda x: x["dataFeedId"].encode().ljust(32, b"\0"))
    b = b"".join(x["dataFeedId"].encode().ljust(32, b"\0") + value8(x["value"]).to_bytes(32, "big") for x in pts)
    b += p["timestampMilliseconds"].to_bytes(6, "big") + (32).to_bytes(4, "big") + len(pts).to_bytes(3, "big")
    return b + base64.b64decode(p["signature"])


src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
res = {}
for feed, pkgs in d.items():
    meta = b"credence"
    payload = b"".join(package(p) for p in pkgs) + len(pkgs).to_bytes(2, "big") + meta + len(meta).to_bytes(3, "big") + MARKER
    vals = sorted(value8(p["dataPoints"][0]["value"]) for p in pkgs)
    res[feed] = {
        "payload": "0x" + payload.hex(),
        "timestampMs": pkgs[0]["timestampMilliseconds"],
        "median8": vals[len(vals) // 2],
        "signers": [p["signerAddress"] for p in pkgs],
        "values8": [value8(p["dataPoints"][0]["value"]) for p in pkgs],
    }
json.dump(res, open(out, "w"), indent=1)
print({k: (v["median8"], len(v["signers"])) for k, v in res.items()})
