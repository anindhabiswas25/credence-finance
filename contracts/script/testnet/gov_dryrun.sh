#!/usr/bin/env bash
# make gov-dry-run (S5 item 5): every gov.sh action once, end to end, on an anvil dry-run book of the equity stack
# (finalized: the timelock belongs to the Gov Safe at 1 h). Each action: propose → the owners sign (anvil accounts 1-5
# are the dry run's Safe owners) → execTransaction → chain time moved past the delay → execute → the state read back.
# Actions: pause and unpause of two markets (Guardian, 6 h; a MultiSendCallOnly transaction), pause all + unpause-gov
# (timelock), caps, calendar (two more months of XNYS), risk-bundle (the main equity bundle again: several chained
# batches, every Safe step signed before any is sent; every hash read back), list-market (a new test token, META).
# Its own anvil (GOV_DRY_PORT, default 8562) and book (deployments/31337.equity.gov-dryrun.json); proposals under
# deployments/gov/31337/ (git-ignored). Plain anvil only: the owner keys are anvil's public test keys.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PORT="${GOV_DRY_PORT:-8562}"
export STACK=equity DRY_RUN=1 DRY_RPC="http://127.0.0.1:$PORT" DRY_BOOK="${DRY_BOOK:-$ROOT/deployments/31337.equity.gov-dryrun.json}"
RPC="$DRY_RPC"; BOOK="$DRY_BOOK"
GOV="$ROOT/contracts/script/testnet/gov.sh"
MNEMONIC="test test test test test test test test test test test junk"
pk() { cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "GOV DRY RUN FAILED: $*" >&2; exit 1; }

T="$(mktemp -d)"
if [ "${GOV_DRY_REUSE:-0}" = 1 ]; then
  # an anvil already holding a finalized dry-run book (DRY_BOOK): run on it and put its state back afterwards
  [ -f "$BOOK" ] || fail "GOV_DRY_REUSE=1 needs the book $BOOK on $RPC"
  SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')"
  trap 'cast rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null || true; rm -rf "$T"' EXIT
else
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && fail "something already answers on $RPC (GOV_DRY_PORT)"
  anvil --port "$PORT" --chain-id 31337 --silent & ANVIL_PID=$!
  trap 'kill $ANVIL_PID 2>/dev/null || true; rm -rf "$T"' EXIT
  until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.2; done
  rm -f "$BOOK"
  say "deploy the equity dry-run book"
  bash "$ROOT/contracts/script/testnet/deploy.sh" equity > "$T/deploy.log" 2>&1 || { tail -20 "$T/deploy.log"; fail "deploy"; }
fi

b() { jq -r "$1" "$BOOK"; }
now() { cast block latest -f timestamp --rpc-url "$RPC"; }
# run every step of a proposal in order: Safe steps signed by enough owners, waits skipped by moving chain time
run() { # dir
  local d="$1" name sender after delay ready signers
  [ -f "$d/proposal.json" ] || fail "no proposal ($d)"
  # the owners sign every Safe step before any is sent (each at its future nonce), as they would on a real chain
  for name in $(jq -r '.steps[] | select(.sender != "anyone") | .name' "$d/proposal.json"); do
    sender="$(jq -r --arg n "$name" '.steps[] | select(.name == $n) | .sender' "$d/proposal.json")"
    case "$sender" in gov) signers="1 2 3" ;; *) signers="1 2" ;; esac
    for i in $signers; do OWNER_KEY="$(pk "$i")" bash "$GOV" sign "$d" "$name" 2>&1 | grep -v '^\[' || true; done
  done
  for name in $(jq -r '.steps[].name' "$d/proposal.json"); do
    sender="$(jq -r --arg n "$name" '.steps[] | select(.name == $n) | .sender' "$d/proposal.json")"
    after="$(jq -r --arg n "$name" '.steps[] | select(.name == $n) | .afterStep // empty' "$d/proposal.json")"
    if [ -n "$after" ]; then
      delay="$(jq -r --arg n "$name" '.steps[] | select(.name == $n) | .delay' "$d/proposal.json")"
      ready=$(( $(jq -r .timestamp "$d/sent.$after.json") + delay ))
      [ "$(now)" -ge "$ready" ] || { cast rpc evm_setNextBlockTimestamp $((ready + 1)) --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
    fi
    SENDER_KEY="$(pk 0)" bash "$GOV" exec "$d" "$name"
  done
}
propose() { local d; d="$(bash "$GOV" propose "$@" | tail -1)"; [ -f "$d/proposal.json" ] || fail "propose $1"; echo "$d"; }
word() { # hex return, index → the 32-byte word as decimal
  cast to-dec "0x$(echo "${1#0x}" | cut -c$(( $2 * 64 + 1 ))-$(( $2 * 64 + 64 )))"
}
paused() { word "$(cast call "$(b .equity.market)" 'overlay(bytes32)' "$1" --rpc-url "$RPC")" 2; }   # GuardianOverlay.borrowPaused

NVDA="$(b .equity.markets.NVDA)"; TSLA="$(b .equity.markets.TSLA)"
n=0

AAPL="$(b .equity.markets.AAPL)"
say "1. pause NVDA and AAPL (Guardian Safe, 2-of-4; two calls, so one MultiSendCallOnly transaction)"
run "$(propose pause MARKET=NVDA,AAPL)"
[ "$(paused "$NVDA")" = 1 ] && [ "$(paused "$AAPL")" = 1 ] || fail "NVDA / AAPL not paused"
[ "$(paused "$TSLA")" = 0 ] || fail "TSLA paused too"; n=$((n + 1))

say "2. unpause NVDA and AAPL (Guardian Safe: schedule, 6 h, execute)"
run "$(propose unpause MARKET=NVDA,AAPL)"
[ "$(paused "$NVDA")" = 0 ] && [ "$(paused "$AAPL")" = 0 ] || fail "still paused"; n=$((n + 1))

say "3. pause every market, then unpause through the Gov Safe and the timelock (1 h)"
run "$(propose pause MARKET=all)"
# "all" is the guardian's bytes32(0): the market's global overlay (id 0), which every market reads with its own
ALL=0x0000000000000000000000000000000000000000000000000000000000000000
[ "$(paused "$ALL")" = 1 ] || fail "the global overlay is not paused by pause all"
run "$(propose unpause-gov MARKET=all)"
[ "$(paused "$ALL")" = 0 ] && [ "$(paused "$NVDA")" = 0 ] || fail "still paused after unpause-gov"; n=$((n + 1))

say "4. caps NVDA 3,000,000 / 2,100,000, vault cap 3,000,000"
run "$(propose caps TICKER=NVDA SUPPLY_CAP=3000000 BORROW_CAP=2100000 VAULT_CAP=3000000)"
p="$(cast call "$(b .equity.market)" 'marketParams(bytes32)' "$NVDA" --rpc-url "$RPC")"
[ "$(word "$p" 9)" = 3000000000000 ] && [ "$(word "$p" 10)" = 2100000000000 ] || fail "NVDA caps $(word "$p" 9) / $(word "$p" 10)"
[ "$(cast call "$(b .equity.vault)" 'cap(bytes32)(uint256)' "$NVDA" --rpc-url "$RPC" | cut -d' ' -f1)" = 3000000000000 ] \
  || fail "NVDA vault cap"; n=$((n + 1))

say "5. calendar: XNYS 2027-11-01 + 2 months"
CAL="$T/cal"; (cd "$ROOT/calibration" && uv run --quiet python -m credence_cal.calendar --from 2027-11-01 --months 2 --venue XNYS --out "$CAL" >/dev/null)
before="$(cast call "$(b .shared.calendar)" 'sessionCount(bytes32)(uint256)' "$(cast format-bytes32-string XNYS)" --rpc-url "$RPC" | cut -d' ' -f1)"
run "$(propose calendar CALENDAR="$(ls "$CAL"/XNYS-*.json)")"
after="$(cast call "$(b .shared.calendar)" 'sessionCount(bytes32)(uint256)' "$(cast format-bytes32-string XNYS)" --rpc-url "$RPC" | cut -d' ' -f1)"
want="$(jq '.sessions | length' "$(ls "$CAL"/XNYS-*.json)" 2>/dev/null || echo 0)"
[ "$after" -gt "$before" ] || fail "no session appended ($before → $after)"
say "   sessions $before → $after (file: $want)"; n=$((n + 1))

say "6. risk bundle (the main equity bundle again: 57 calls, so several chained batches signed up front), every hash read back"
d="$(propose risk-bundle RISK_BUNDLE="$ROOT/$(jq -r '.riskBundles[0]' "$ROOT/contracts/script/testnet/config/46630.json")")"
[ "$(jq '[.steps[] | select(.sender == "gov")] | length' "$d/proposal.json")" -gt 1 ] || fail "the bundle fit one batch"
run "$d"
m="$(jq '.checks | length' "$d/risk-plan.json")"
for i in $(seq 0 $((m - 1))); do
  [ "$(cast call --rpc-url "$RPC" "$(b .shared.riskEngine)" "$(jq -r ".checks[$i].data" "$d/risk-plan.json")")" = \
    "$(jq -r ".checks[$i].want" "$d/risk-plan.json")" ] || fail "bundle hash $(jq -r ".checks[$i].what" "$d/risk-plan.json")"
done
say "   $m hashes"; n=$((n + 1))

say "7. list a market: META (a new test token)"
TOKEN="$(cd "$ROOT/contracts" && forge create src/testnet/CredenceStockToken.sol:CredenceStockToken --rpc-url "$RPC" \
  --private-key "$(pk 0)" --broadcast --constructor-args "Credence Test META" tMETA "$(cast wallet address --private-key "$(pk 0)")" \
  0x0000000000000000000000000000000000000000 | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')"
run "$(propose list-market TICKER=META TOKEN="$TOKEN" SUPPLY_CAP=1000000 BORROW_CAP=700000 VAULT_CAP=1000000)"
AID="$(cast keccak "META:XNAS")"
ID="$(cast keccak "$(cast abi-encode 'f(address,address,bytes32)' "$(b .tokens.loan)" "$TOKEN" "$AID")")"
p="$(cast call "$(b .equity.market)" 'marketParams(bytes32)' "$ID" --rpc-url "$RPC")"
[ "$(word "$p" 9)" = 1000000000000 ] || fail "META market caps"
cast call "$(b .equity.vault)" 'enabledMarkets()(bytes32[])' --rpc-url "$RPC" | grep -qi "${ID#0x}" || fail "META not in the vault"
cast call "$(b .equity.vault)" 'supplyQueue()(bytes32[])' --rpc-url "$RPC" | grep -qi "${ID#0x}" || fail "META not in the supply queue"
n=$((n + 1))

say "GOV DRY RUN PASSED: $n actions on $BOOK (proposals in deployments/gov/31337/)"
