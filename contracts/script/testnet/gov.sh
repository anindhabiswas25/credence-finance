#!/usr/bin/env bash
# Governance changes after the testnet deploy (S5 item 5, ADR-0122). After FinalizeTestnet no EOA keeps an admin role:
# a change goes Gov Safe (3-of-5) → timelock (1 h) → executeBatch (open to anyone), and an emergency goes Guardian Safe
# (2-of-4) → CredenceGuardian. This tool writes each change as a proposal directory, as Safe Transaction Builder JSON
# for Safe{Wallet}, and signs and executes it from the command line where Safe{Wallet} does not serve the chain
# (Arbitrum Sepolia 421614 is not in Safe's config service; Robinhood Testnet 46630 is, checked 2026-10-01).
#
#   gov.sh propose <action> [KEY=VALUE…]   STACK=equity|nav; writes deployments/gov/<chainId>/<id>-<action>/
#     list-market   TICKER TOKEN SUPPLY_CAP BORROW_CAP VAULT_CAP (load the asset's risk bundle first)
#     caps          TICKER SUPPLY_CAP BORROW_CAP [VAULT_CAP]
#     risk-bundle   RISK_BUNDLE (a calibration/out bundle file)
#     calendar      CALENDAR (a calibration/out calendar file; appends every session after the chain's last one)
#     pause         MARKET (tickers comma-separated, or "all")        Guardian Safe, instant
#     unpause       MARKET (tickers comma-separated, or "all")        Guardian Safe: schedule now, execute after 6 h
#     unpause-gov   MARKET (tickers comma-separated, or "all")        Gov Safe → timelock (1 h), no 6 h wait
#   gov.sh sign   <dir> <step>   an owner signs the step's Safe transaction (OWNER_KEYSTORE + OWNER_PASSWORD_FILE;
#                                 OWNER_KEY only on plain anvil). Writes <dir>/sigs/<step>.<owner>.sig (a signature, not a key)
#   gov.sh exec   <dir> <step>   sends the step: execTransaction with the collected signatures (a Safe step) or the call
#                                 itself (an "anyone" step, e.g. the timelock's executeBatch); SENDER_KEYSTORE +
#                                 SENDER_PASSWORD_FILE pay the gas (SENDER_KEY only on plain anvil)
#   gov.sh status <dir>          the steps, their signatures, and the timelock operations' state
#
# A proposal (proposal.json) is a list of steps; each step is one Safe transaction or one plain transaction:
#   {name, sender: "gov"|"guardian"|"anyone", [afterStep, delay], txs: [{to, value, data, what}]}
# A Safe step is signed at the Safe nonce it will run with: the Safe's nonce now plus the earlier Safe steps of this
# proposal not sent yet, so the owners can sign every step up front and the steps are sent in order.
# A Safe step with more than one call goes through the canonical MultiSendCallOnly v1.4.1 (delegatecall); the
# Safe Transaction Builder JSON lists the calls one by one (Safe{Wallet} batches them the same way).
# Env: RPC (default: the config's), BOOK (default: deployments/<chainId>.json; DRY_RUN=1: the dry-run book).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MULTISEND=0x9641d764fc13c8B624c04430C7356C1C7C8102e2   # MultiSendCallOnly v1.4.1 (canonical, on 46630 and 421614)
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
say() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { echo "gov: $*" >&2; exit 1; }

env_for_stack() {
  : "${STACK:?STACK=equity|nav}"
  # shellcheck source=env.sh
  source "$ROOT/contracts/script/testnet/env.sh"
  BOOK="${GOV_BOOK:-$BOOK}"
  [ -f "$BOOK" ] || die "no book $BOOK"
  [ "$(jq -r .finalized "$BOOK")" = true ] || die "$BOOK is not finalized: the deployer still holds the timelock"
  CHAIN="$(cast chain-id --rpc-url "$RPC")"
  [ "$CHAIN" = "$(jq -r .chainId "$BOOK")" ] || die "RPC is chain $CHAIN, the book is for $(jq -r .chainId "$BOOK")"
}
b() { jq -r "$1" "$BOOK"; }

# key material: a keystore on a real chain, a raw key only on plain anvil
wallet_args() { # PREFIX → args for cast
  local ks="${1}_KEYSTORE" pw="${1}_PASSWORD_FILE" k="${1}_KEY"
  if [ -n "${!k:-}" ]; then
    [ "$(cast chain-id --rpc-url "$RPC")" = 31337 ] || die "$k is for plain anvil only; use ${1}_KEYSTORE"
    echo "--private-key ${!k}"
  else
    [ -n "${!ks:-}" ] && [ -n "${!pw:-}" ] || die "set ${1}_KEYSTORE and ${1}_PASSWORD_FILE"
    echo "--keystore ${!ks} --password-file ${!pw}"
  fi
}

# ───────────── propose ─────────────

new_dir() {
  local d; d="$ROOT/deployments/gov/$CHAIN/$(date -u +%Y%m%d-%H%M%S)-$1"
  mkdir -p "$d"; echo "$d"
}

# calls.json ({calls: [{to, data, what}]}) → timelock steps. The calls are cut into batches of at most 20 calls and
# GOV_BATCH_BYTES of calldata (default 40 KB: a risk-bundle call is ~6 KB; a transaction must stay well under the
# node's 128 KB limit, and a hex argument under the 128 KB argv limit). Batch k is two steps: schedule-k (the Gov
# Safe's scheduleBatch) and execute-k (anyone's executeBatch, after the delay). Each batch's predecessor is the batch
# before it, so they execute in order.
timelock_steps() { # calls.json label → steps JSON
  local calls="$1" label="$2" tl delay n i=0 k=0 m bytes t p v salt pred="$ZERO32" id max="${GOV_BATCH_BYTES:-40960}" out=()
  tl="$(b .shared.timelock)"; delay="$(cast call "$tl" 'getMinDelay()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)"
  n="$(jq '.calls | length' "$calls")"
  while [ "$i" -lt "$n" ]; do
    m=0; bytes=0
    while [ $((i + m)) -lt "$n" ] && [ "$m" -lt 20 ]; do
      local sz; sz="$(jq --argjson j $((i + m)) '.calls[$j].data | length / 2 | floor' "$calls")"
      [ "$m" -gt 0 ] && [ $((bytes + sz)) -gt "$max" ] && break
      bytes=$((bytes + sz)); m=$((m + 1))
    done
    k=$((k + 1))
    t="[$(jq -r --argjson i $i --argjson m $m '.calls[$i:$i+$m] | map(.to) | join(",")' "$calls")]"
    p="[$(jq -r --argjson i $i --argjson m $m '.calls[$i:$i+$m] | map(.data) | join(",")' "$calls")]"
    v="[$(jq -r --argjson i $i --argjson m $m '.calls[$i:$i+$m] | map("0") | join(",")' "$calls")]"
    salt="$(cast keccak "credence-gov-$label-$k-$(date +%s%N)")"
    id="$(cast call "$tl" 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)' "$t" "$v" "$p" "$pred" "$salt" --rpc-url "$RPC")"
    out+=("$(jq -n --arg to "$tl" --argjson k $k --argjson delay "$delay" --arg id "$id" \
      --arg sd "$(cast calldata 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' "$t" "$v" "$p" "$pred" "$salt" "$delay")" \
      --arg ed "$(cast calldata 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' "$t" "$v" "$p" "$pred" "$salt")" \
      --arg w "$(jq -r --argjson i $i --argjson m $m '.calls[$i:$i+$m] | map(.what) | join("; ")' "$calls")" \
      '{name: "schedule-\($k)", sender: "gov", txs: [{to: $to, value: "0", data: $sd, what: "timelock.scheduleBatch: \($w)", operationId: $id}]},
       {name: "execute-\($k)", sender: "anyone", afterStep: "schedule-\($k)", delay: $delay,
        txs: [{to: $to, value: "0", data: $ed, what: "timelock.executeBatch: \($w)", operationId: $id}]}')")
    pred="$id"; i=$((i + m))
  done
  printf '%s\n' "${out[@]}" | jq -s .
}

market_ids() { # MARKET (all, a ticker, or tickers comma-separated) → ids, one per line
  local sk t; sk="$(b .stack)"
  if [ "$1" = all ]; then echo "$ZERO32"; return; fi
  for t in ${1//,/ }; do b ".$sk.markets[\"$t\"] // empty" | grep . || die "no market $t in the book"; done
}

write_txbuilder() { # dir
  local d="$1" safe name
  for name in $(jq -r '.steps[] | select(.sender != "anyone") | .name' "$d/proposal.json"); do
    safe="$(jq -r --arg n "$name" '.steps[] | select(.name == $n) | .safe' "$d/proposal.json")"
    jq --arg n "$name" --arg safe "$safe" --arg c "$CHAIN" --argjson t "$(date +%s000)" '
      (.steps[] | select(.name == $n)) as $s
      | {version: "1.0", chainId: $c, createdAt: $t,
         meta: {name: "\(.action) · \($n)", description: ([$s.txs[].what] | join(" | ")), txBuilderVersion: "1.16.5",
                createdFromSafeAddress: $safe, createdFromOwnerAddress: "", checksum: ""},
         transactions: [$s.txs[] | {to, value, data, contractMethod: null, contractInputsValues: null}]}' \
      "$d/proposal.json" > "$d/txbuilder.$name.json"
  done
}

propose() {
  local action="${1:?action}"; shift
  for kv in "$@"; do [ "${kv%%=*}" = STACK ] && export "${kv?}"; done
  env_for_stack
  # after env.sh, which exports the config's CALENDAR and RISK_BUNDLE: the arguments win
  for kv in "$@"; do export "${kv?}"; done
  local d calls steps safe_gov safe_guard guardian
  safe_gov="$(b .safes.gov)"; safe_guard="$(b .safes.guardian)"; guardian="$(b .shared.guardian)"
  d="$(new_dir "$action")"; calls="$d/calls.json"
  case "$action" in
    list-market|caps|calendar)
      local fn; fn="$(case "$action" in list-market) echo listMarket ;; caps) echo caps ;; calendar) echo calendar ;; esac)"
      # forge reads only calibration/out and deployments: the proposal keeps its own copy of the calendar
      if [ "$action" = calendar ]; then cp "${CALENDAR:?CALENDAR}" "$d/calendar.json"; export CALENDAR="$d/calendar.json"; fi
      (cd "$ROOT/contracts" && BOOK="$BOOK" PROPOSAL_OUT="$calls" forge script script/testnet/GovPropose.s.sol:GovPropose \
        --sig "$fn()" --rpc-url "$RPC" >/dev/null) || die "GovPropose.$fn failed"
      steps="$(timelock_steps "$calls" "$action")" ;;
    risk-bundle)
      local bundle plan; bundle="$(realpath "${RISK_BUNDLE:?RISK_BUNDLE}")"; plan="$d/risk-plan.json"
      (cd "$ROOT/contracts" && SENDER="$(b .shared.timelock)" RISK_ENGINE="$(b .shared.riskEngine)" RISK_BUNDLE="$bundle" \
        RISK_BUNDLE_DIR="$(dirname "$bundle")" PLAN_OUT="$plan" \
        forge script script/LoadScenarioSet.s.sol:LoadScenarioSet --sig "plan()" --rpc-url "$RPC" >/dev/null) \
        || die "LoadScenarioSet.plan failed"
      jq '{calls: [.calls[] | {to, data, what}]}' "$plan" > "$calls"
      steps="$(timelock_steps "$calls" "risk-bundle")" ;;
    pause)
      local txs=() id ids; ids="$(market_ids "${MARKET:?MARKET}")"
      for id in $ids; do
        txs+=("$(jq -n --arg to "$guardian" --arg d "$(cast calldata 'pauseBorrow(bytes32)' "$id")" --arg w "guardian.pauseBorrow $MARKET" \
          '{to: $to, value: "0", data: $d, what: $w}')")
      done
      steps="$(jq -n --argjson t "$(printf '%s\n' "${txs[@]}" | jq -s .)" '[{name: "pause", sender: "guardian", txs: $t}]')" ;;
    unpause)
      local s=() e=() id delay ids; ids="$(market_ids "${MARKET:?MARKET}")"
      delay="$(cast call "$guardian" 'UNPAUSE_DELAY()(uint40)' --rpc-url "$RPC" | cut -d' ' -f1)"
      for id in $ids; do
        s+=("$(jq -n --arg to "$guardian" --arg d "$(cast calldata 'scheduleUnpauseBorrow(bytes32)' "$id")" --arg w "guardian.scheduleUnpauseBorrow $MARKET" '{to: $to, value: "0", data: $d, what: $w}')")
        e+=("$(jq -n --arg to "$guardian" --arg d "$(cast calldata 'executeUnpause(bytes32)' "$id")" --arg w "guardian.executeUnpause $MARKET" '{to: $to, value: "0", data: $d, what: $w}')")
      done
      steps="$(jq -n --argjson s "$(printf '%s\n' "${s[@]}" | jq -s .)" --argjson e "$(printf '%s\n' "${e[@]}" | jq -s .)" --argjson delay "$delay" \
        '[{name: "schedule-unpause", sender: "guardian", txs: $s},
          {name: "execute-unpause", sender: "guardian", afterStep: "schedule-unpause", delay: $delay, txs: $e}]')" ;;
    unpause-gov)
      local id ids; ids="$(market_ids "${MARKET:?MARKET}")"
      echo '{"calls": []}' > "$calls"
      for id in $ids; do
        jq --arg to "$guardian" --arg d "$(cast calldata 'executeUnpause(bytes32)' "$id")" --arg w "guardian.executeUnpause $MARKET" \
          '.calls += [{to: $to, data: $d, what: $w}]' "$calls" > "$calls.n" && mv "$calls.n" "$calls"
      done
      steps="$(timelock_steps "$calls" "unpause-gov")" ;;
    *) die "unknown action $action" ;;
  esac
  echo "$steps" > "$d/.steps.json"   # through a file: a whole bundle is over the argv limit
  jq -n --arg a "$action" --arg s "$STACK" --argjson c "$CHAIN" --arg book "${BOOK#"$ROOT"/}" --slurpfile st "$d/.steps.json" \
    --arg gov "$safe_gov" --arg guard "$safe_guard" --arg at "$(date -u +%FT%TZ)" \
    '{action: $a, stack: $s, chainId: $c, book: $book, createdAt: $at,
      steps: ($st[0] | map(. + (if .sender == "gov" then {safe: $gov} elif .sender == "guardian" then {safe: $guard} else {} end)))}' \
    > "$d/proposal.json"
  rm -f "$d/.steps.json"
  write_txbuilder "$d"
  echo "$d"
  say "proposal $(basename "$d"): $(jq -r '[.steps[] | "\(.name) (\(.sender), \(.txs | length) call(s))"] | join(" → ")' "$d/proposal.json")"
}

# ───────────── the Safe transaction of a step ─────────────

step() { jq -c --arg n "$2" '.steps[] | select(.name == $n)' "$1/proposal.json"; }

# one Safe transaction for the step: the call itself, or MultiSendCallOnly.multiSend (operation 1) for several
safe_tx() { # step JSON → "to value data operation"
  local s="$1" n; n="$(echo "$s" | jq '.txs | length')"
  if [ "$n" = 1 ]; then
    echo "$(echo "$s" | jq -r '.txs[0] | "\(.to) \(.value) \(.data)"') 0"
  else
    local packed="0x" i to v data
    for ((i = 0; i < n; i++)); do
      to="$(echo "$s" | jq -r ".txs[$i].to")"; v="$(echo "$s" | jq -r ".txs[$i].value")"; data="$(echo "$s" | jq -r ".txs[$i].data")"
      packed+="00${to#0x}$(printf '%064x' "$v")$(printf '%064x' $(( (${#data} - 2) / 2 )))${data#0x}"
    done
    # a delegatecall to an address without code "succeeds" and does nothing: refuse that
    [ "$(cast code "$MULTISEND" --rpc-url "$RPC")" != 0x ] || die "no MultiSendCallOnly at $MULTISEND on this chain"
    echo "$MULTISEND 0 $(cast calldata 'multiSend(bytes)' "$packed") 1"
  fi
}

step_nonce() { # dir step safe → the nonce this step runs at
  local d="$1" name="$2" safe="$3" base earlier
  base="$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)"
  earlier="$(jq -r --arg n "$name" --arg s "$safe" \
    '[.steps[] | select(.safe == $s) | .name] | .[:index($n)] | .[]' "$d/proposal.json")"
  for e in $earlier; do [ -f "$d/sent.$e.json" ] || base=$((base + 1)); done
  echo "$base"
}

safe_hash() { # safe to value data op nonce → safeTxHash
  cast call "$1" 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
    "$2" "$3" "$4" "$5" 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$6" \
    --rpc-url "$RPC"
}

load_dir() { # dir → env from the proposal
  local d="$1"; [ -f "$d/proposal.json" ] || die "no proposal in $d"
  STACK="$(jq -r .stack "$d/proposal.json")"; export STACK
  GOV_BOOK="$ROOT/$(jq -r .book "$d/proposal.json")"
  env_for_stack
}

sign() {
  local d="${1:?dir}" name="${2:?step}" s safe to v data op nonce h me sig
  load_dir "$d"; s="$(step "$d" "$name")"; [ -n "$s" ] || die "no step $name"
  safe="$(echo "$s" | jq -r '.safe // empty')"; [ -n "$safe" ] || die "step $name is not a Safe step"
  [ -f "$d/sent.$name.json" ] && die "step $name is sent already"
  read -r to v data op <<<"$(safe_tx "$s")"
  nonce="$(step_nonce "$d" "$name" "$safe")"
  h="$(safe_hash "$safe" "$to" "$v" "$data" "$op" "$nonce")"
  # shellcheck disable=SC2046
  me="$(cast wallet address $(wallet_args OWNER))"
  cast call "$safe" 'isOwner(address)(bool)' "$me" --rpc-url "$RPC" | grep -q true || die "$me is not an owner of $safe"
  # an owner's ECDSA signature of the Safe transaction hash itself (v = 27/28), as Safe's checkSignatures wants
  # shellcheck disable=SC2046
  sig="$(cast wallet sign --no-hash $(wallet_args OWNER) "$h")"
  mkdir -p "$d/sigs"
  jq -n --arg o "$me" --arg s "$sig" --arg h "$h" --argjson n "$nonce" '{owner: $o, signature: $s, safeTxHash: $h, nonce: $n}' \
    > "$d/sigs/$name.$me.sig"
  say "signed $name for $safe (nonce $nonce, $h) as $me"
}

sendargs() { wallet_args SENDER; }

exec_step() {
  local d="${1:?dir}" name="${2:?step}" s safe to v data op nonce h thr sigs after delay
  load_dir "$d"; s="$(step "$d" "$name")"; [ -n "$s" ] || die "no step $name"
  [ -f "$d/sent.$name.json" ] && die "step $name is sent already"
  after="$(echo "$s" | jq -r '.afterStep // empty')"
  if [ -n "$after" ]; then
    [ -f "$d/sent.$after.json" ] || die "step $after is not sent yet"
    delay="$(echo "$s" | jq -r .delay)"
    local ready=$(( $(jq -r .timestamp "$d/sent.$after.json") + delay )) now
    now="$(cast block latest -f timestamp --rpc-url "$RPC")"
    [ "$now" -ge "$ready" ] || die "step $name is ready at $(date -u -d @$ready +%FT%TZ) (chain time $(date -u -d @"$now" +%FT%TZ))"
  fi
  local out
  if [ "$(echo "$s" | jq -r .sender)" = anyone ]; then
    local i n; n="$(echo "$s" | jq '.txs | length')"
    for ((i = 0; i < n; i++)); do
      # shellcheck disable=SC2046
      out="$(cast send --rpc-url "$RPC" $(sendargs) "$(echo "$s" | jq -r ".txs[$i].to")" "$(echo "$s" | jq -r ".txs[$i].data")" --json)"
      echo "$out" | jq -e '.status == "0x1"' >/dev/null || die "$name call $i reverted"
    done
  else
    safe="$(echo "$s" | jq -r .safe)"
    read -r to v data op <<<"$(safe_tx "$s")"
    nonce="$(step_nonce "$d" "$name" "$safe")"
    [ "$nonce" = "$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)" ] \
      || die "send the earlier Safe steps of this proposal first (this one runs at nonce $nonce)"
    h="$(safe_hash "$safe" "$to" "$v" "$data" "$op" "$nonce")"
    thr="$(cast call "$safe" 'getThreshold()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)"
    # the signatures for this hash, sorted by owner address (Safe requires ascending owners)
    sigs="0x$(cat "$d"/sigs/"$name".*.sig 2>/dev/null | jq -rs --arg h "$h" \
      '[.[] | select(.safeTxHash == $h)] | sort_by(.owner | ascii_downcase) | map(.signature | ltrimstr("0x")) | join("")')"
    [ $(( (${#sigs} - 2) / 130 )) -ge "$thr" ] || die "$(( (${#sigs} - 2) / 130 )) signature(s) for $h (nonce $nonce), the Safe needs $thr"
    # shellcheck disable=SC2046
    out="$(cast send --rpc-url "$RPC" $(sendargs) "$safe" \
      'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
      "$to" "$v" "$data" "$op" 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$sigs" --json)"
    echo "$out" | jq -e '.status == "0x1"' >/dev/null || die "execTransaction reverted"
    # a Safe that ran the call but saw it revert emits ExecutionFailure (it does not revert itself)
    echo "$out" | jq -e '[.logs[].topics[0]] | index("0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23") == null' >/dev/null \
      || die "the Safe executed $name but the call failed (ExecutionFailure)"
  fi
  local blk ts; blk="$(echo "$out" | jq -r .blockNumber)"; ts="$(cast block "$blk" -f timestamp --rpc-url "$RPC")"
  jq -n --arg tx "$(echo "$out" | jq -r .transactionHash)" --argjson ts "$ts" '{tx: $tx, timestamp: $ts}' > "$d/sent.$name.json"
  say "sent $name: $(echo "$out" | jq -r .transactionHash)"
}

status() {
  local d="${1:?dir}"; load_dir "$d"
  jq -r '"\(.action) on \(.chainId) (\(.stack)), created \(.createdAt)"' "$d/proposal.json"
  local name tl; tl="$(b .shared.timelock)"
  for name in $(jq -r '.steps[].name' "$d/proposal.json"); do
    printf '  %-18s %s, %s signature(s)\n' "$name" \
      "$([ -f "$d/sent.$name.json" ] && echo "sent $(jq -r .tx "$d/sent.$name.json")" || echo "not sent")" \
      "$(ls "$d"/sigs/"$name".*.sig 2>/dev/null | wc -l)"
    for id in $(step "$d" "$name" | jq -r '.txs[].operationId // empty'); do
      printf '    timelock op %s: ready %s, done %s\n' "$id" \
        "$(cast call "$tl" 'isOperationReady(bytes32)(bool)' "$id" --rpc-url "$RPC")" \
        "$(cast call "$tl" 'isOperationDone(bytes32)(bool)' "$id" --rpc-url "$RPC")"
    done
  done
}

cmd="${1:?usage: gov.sh propose|sign|exec|status …}"; shift
case "$cmd" in
  propose) propose "$@" ;;
  sign) sign "$@" ;;
  exec) exec_step "$@" ;;
  status) status "$@" ;;
  *) die "unknown command $cmd" ;;
esac
