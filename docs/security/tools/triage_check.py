#!/usr/bin/env python3
"""Static-analysis triage gate (QA-sec, Build Guide §15.2: "Slither and Aderyn with no high or medium findings left
unexplained").

Every High / Medium Slither result and every High Aderyn instance gets a stable key: a short hash of the finding's
description with the line numbers removed, so the key survives unrelated edits that move code, and changes (forcing a
re-triage) when the flagged code itself changes. docs/security/triage.md must carry a row for every key.

  triage_check.py slither target/qa/slither.json docs/security/triage.md   # exit 1 on an untriaged finding
  triage_check.py aderyn  target/qa/aderyn.json  docs/security/triage.md
  add --emit to print markdown rows (key, location, detector, summary) for the untriaged ones
"""
import hashlib
import json
import re
import sys

LINE_REFS = re.compile(r"#\d+(-\d+)?")
SPACES = re.compile(r"\s+")
GATED = ("High", "Medium")


def _key(prefix: str, text: str) -> str:
    norm = SPACES.sub(" ", LINE_REFS.sub("", text)).strip()
    return f"{prefix}-{hashlib.sha1(norm.encode()).hexdigest()[:8]}"


def slither(path):
    out = []
    for r in json.load(open(path))["results"].get("detectors", []):
        if r["impact"] not in GATED:
            continue
        desc = r["description"].strip()
        sm = (r.get("elements") or [{}])[0].get("source_mapping", {})
        lines = sm.get("lines") or [0]
        loc = f'{sm.get("filename_relative", "?")}#{lines[0]}'

        summary = desc.splitlines()[0]
        extra = [l.strip() for l in desc.splitlines()[1:3] if l.strip().startswith("-")]
        if r["check"] in ("incorrect-equality", "divide-before-multiply") and extra:
            summary += " " + " ".join(extra)
        out.append((_key("S", r["check"] + "|" + desc), r["impact"], r["check"], loc, summary))
    return out


def aderyn(path):
    out = []
    rep = json.load(open(path))
    issues = rep.get("high_issues", {}).get("issues", [])
    for issue in issues:
        for inst in issue.get("instances", []):
            where = f'{inst.get("contract_path", "")}:{inst.get("line_no", "")}'
            # src is "offset:length"; the flagged source text itself is not in the report, so the key is the detector,
            # the file and the hint (line numbers move with unrelated edits and are left out)
            text = "|".join((issue["detector_name"], inst.get("contract_path", ""), inst.get("hint") or ""))
            out.append((_key("A", text), "High", issue["detector_name"], where, issue["title"]))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    emit = "--emit" in sys.argv
    kind, report, triage = args
    found = slither(report) if kind == "slither" else aderyn(report)
    doc = open(triage).read()
    missing = [f for f in found if f"`{f[0]}`" not in doc]
    seen = {f[0] for f in found}
    print(f"{kind}: {len(found)} gated finding(s) ({len(seen)} keys); untriaged: {len(missing)}")
    for k, imp, chk, loc, summ in missing:
        if emit:
            print(f"| `{k}` | {imp} | {chk} | `{loc}` | {summ.replace('|', '/')[:220]} | ? | ? |")
        else:
            print(f"  UNTRIAGED {k} {imp} {chk} {loc}: {summ[:160]}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
