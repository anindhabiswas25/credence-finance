#!/usr/bin/env bash
# make relayer-redstone-smoke: VENDOR=redstone (R-26, the public testnet's equity feeds) against the live public
# RedStone gateway, for the testnet asset set. Needs the internet, no keys. Checks, per asset: STATUS from the
# calendar, OPEN and CLOSE of the last session derived from RedStone packages (OracleFirstRegular), and LIVE
# (in the session: the regular feed; in extended hours: `<T>---EXTENDED`, which RedStone lists for some tickers
# only; while the venue is closed there is no LIVE by design). Results: target/be/redstone-smoke/<T>.json.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ASSETS=${ASSETS:-NVDA:XNAS,AAPL:XNAS,TSLA:XNAS,MSFT:XNAS,GOOGL:XNAS,AMZN:XNAS}
OUT=target/be/redstone-smoke; mkdir -p "$OUT"
# a calendar that covers today (calibration/out holds the deploy's, from next month on)
(cd calibration && ${UV:-$HOME/.local/bin/uv} run --frozen python -m credence_cal.calendar \
  --from "$(date -u -d '-35 days' +%Y-%m-01)" --months 3 --venue XNYS --out "../$OUT" >/dev/null)
CAL=$(ls "$OUT"/XNYS-*.json | tail -1)
BIN=${RELAYER_BIN:-target/be/debug/credence-relayer}
fail=0
for spec in ${ASSETS//,/ }; do
  t=${spec%%:*}
  VENDOR=redstone CHAIN_ID=${CHAIN_ID:-46630} ASSETS=$spec CALENDAR_FILES=$CAL RUST_LOG=warn \
    timeout 90 "$BIN" smoke --out "$OUT/$t.json" >/dev/null 2>"$OUT/$t.err" || { echo "FAIL $t: $(tail -1 "$OUT/$t.err")"; fail=1; continue; }
  line=$(jq -r '"\(.results.status.detail.market) live=\(.results.live.detail.newest.price // "none") open=\(.results.official_open.detail.price // "MISSING") close=\(.results.official_close.detail.price // "MISSING")"' "$OUT/$t.json")
  echo "$t: $line"
  market=$(jq -r .results.status.detail.market "$OUT/$t.json")
  [[ $line == *MISSING* ]] && { echo "FAIL $t: no OPEN/CLOSE from RedStone"; fail=1; }
  [[ $market == Open && $line == *live=none* ]] && { echo "FAIL $t: no LIVE in the regular session"; fail=1; }
done
[ $fail = 0 ] && echo "PASSED: relayer-redstone-smoke" || { echo "FAILED: relayer-redstone-smoke"; exit 1; }
