#!/usr/bin/env python3
"""Frozen ABI tags (S5 item 4): a tag is a byte-for-byte copy of a released ABI set plus a MANIFEST.json, and the
contracts at the tagged commit must compile to exactly those ABIs.

  abi_tag.py create <abis-dir> <base> <tag>   copy <base>/*.json to <tag>/ and write <tag>/MANIFEST.json
  abi_tag.py check  <abis-dir> <tag> <out>    the tag still equals its base, the manifest hashes hold, and every ABI
                                              in the tag equals the build's (forge's <out>/<File>.sol/<Name>.json)

A failed build comparison means an ABI changed after the tag: bump the tag (v5-testnet.2, …) before the deploy, and
post it on the board (B's SDK pins to it)."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys


def sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def canon(abi) -> str:
    return json.dumps(sorted(abi, key=lambda e: json.dumps(e, sort_keys=True)), sort_keys=True)


def create(root: pathlib.Path, base: str, tag: str) -> None:
    src, dst = root / base, root / tag
    if dst.exists():
        sys.exit(f"{dst} exists: a tag is never rewritten, make a new one")
    dst.mkdir()
    files = sorted(p for p in src.glob("*.json"))
    for p in files:
        shutil.copyfile(p, dst / p.name)
    commit = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    manifest = {
        "tag": tag,
        "base": base,
        "baseCommit": commit,
        "note": "frozen testnet ABI set; the deployed contracts compile to exactly these (make abis-check)",
        "files": {p.name: sha(dst / p.name) for p in files},
    }
    (dst / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"tag {tag}: {len(files)} ABIs from {base}")


def check(root: pathlib.Path, tag: str, out: pathlib.Path) -> None:
    d = root / tag
    m = json.loads((d / "MANIFEST.json").read_text())
    bad = []
    names = sorted(p.name for p in d.glob("*.json") if p.name != "MANIFEST.json")
    if names != sorted(m["files"]):
        bad.append("the tag's files differ from its manifest")
    for n, h in m["files"].items():
        if not (d / n).exists() or sha(d / n) != h:
            bad.append(f"{n}: changed after the tag was cut")
        b = root / m["base"] / n
        if not b.exists() or sha(b) != h:
            bad.append(f"{n}: differs from {m['base']}/{n}")
    if not out.is_dir():
        sys.exit(f"no forge build output at {out}: run make contracts-build first")
    for n in names:
        stem = n[: -len(".json")]
        hits = sorted(out.glob(f"*/{n}"), key=lambda h: h.parent.name != f"{stem}.sol")
        if not hits:
            bad.append(f"{n}: not in the build")
            continue
        built = json.loads(hits[0].read_text())["abi"]
        if canon(built) != canon(json.loads((d / n).read_text())):
            bad.append(f"{n}: the build's ABI differs from the tag (bump the tag)")
    if bad:
        print(f"ABI tag {tag}: FAILED")
        for b in bad:
            print("  " + b)
        sys.exit(1)
    print(f"ABI tag {tag}: {len(names)} ABIs == {m['base']} == the build")


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "create":
        create(pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 5 and sys.argv[1] == "check":
        check(pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]))
    else:
        sys.exit(__doc__)
