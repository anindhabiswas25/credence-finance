# shellcheck shell=bash
# Sourced by deploy.sh and postdeploy_check.sh (ADR-0122): the environment of the testnet scripts, from
# config/<chainId>.json. Needs STACK (equity|nav) and ROOT; DRY_RUN=1 replaces the user / Engineer B inputs (Safe owners,
# signer committees, fund issuer) with anvil accounts and uses plain anvil (chain 31337) at DRY_RPC.
case "$STACK" in
  equity) CID=46630 ;;
  nav) CID=421614 ;;
  *) echo "usage: STACK=equity|nav" >&2; return 2 2>/dev/null || exit 2 ;;
esac
CFG="$ROOT/contracts/script/testnet/config/$CID.json"
cfg() { jq -r "$1" "$CFG"; }
csv() { jq -r "($1 // []) | map(tostring) | join(\",\")" "$CFG"; }

export STACK CID
export RELEASE="$(cfg .release)"
export TIMELOCK_DELAY="$(cfg .timelockDelay)"
export CALENDAR="$ROOT/$(cfg .calendar)"
export RISK_BUNDLE="$ROOT/$(cfg '.riskBundles[0]')"
export ASSETS="$(csv '[.assets[].ticker]')"
export ASSET_TOKENS="$(csv '[.assets[].token]')"
export ASSET_SUPPLY_CAPS="$(csv '[.assets[].supplyCap]')"
export ASSET_BORROW_CAPS="$(csv '[.assets[].borrowCap]')"
export ASSET_VAULT_CAPS="$(csv '[.assets[].vaultCap]')"
export ASSET_FAUCET="$(csv '[.assets[].faucet]')"
export RELAYER_THRESHOLD="$(cfg .relayers.threshold)"
export SIGMA_SIGNERS="$(csv .sigma.signers)" SIGMA_THRESHOLD="$(cfg .sigma.threshold)"
for s in gov guardian ops; do
  u="$(echo "$s" | tr a-z A-Z)"
  export "SAFE_${u}_OWNERS=$(csv ".safes.$s.owners")" "SAFE_${u}_THRESHOLD=$(cfg ".safes.$s.threshold")"
done
if [ "$STACK" = equity ]; then
  export RELAYER_A_SIGNERS="$(csv .relayers.feedA)" RELAYER_B_SIGNERS="$(csv .relayers.feedB)"
  export MIN_BID="$(cfg .minBid)"
else
  export NAV_SIGNERS="$(csv .relayers.nav)" NAV_SOLVERS="$(csv .navSolvers)" REGISTRY_OPERATORS="$(csv .registryOperators)"
  export FUND_ISSUER="$(cfg '.fund.issuer // ""')" FUND_RESERVE="$(cfg '.fund.reserveWallet // ""')"
  export SETTLEMENT_WINDOW="$(cfg .settlementWindow)"
fi
if [ "$(cfg '.loanToken.address // ""')" != "" ]; then
  export LOAN_TOKEN="$(cfg .loanToken.address)"
else
  unset LOAN_TOKEN
  export LOAN_NAME="$(cfg .loanToken.name)" LOAN_SYMBOL="$(cfg .loanToken.symbol)"
  export LOAN_DECIMALS="$(cfg .loanToken.decimals)" LOAN_FAUCET="$(cfg '.loanToken.faucet // 0')"
fi
RISK_BUNDLES=()
while IFS= read -r b; do RISK_BUNDLES+=("$ROOT/$b"); done < <(cfg '.riskBundles[]')

if [ "${DRY_RUN:-0}" = 1 ]; then
  export DRY_RUN=1
  RPC="${DRY_RPC:-http://127.0.0.1:8560}"
  MNEMONIC="test test test test test test test test test test test junk"
  acct() { cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }
  export PRIVATE_KEY="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)"
  export DEPLOYER="$(acct 0)"
  # anvil accounts 1-5 for the Safes, 6-8 for the committees, 9 for the fund's issuer and reserve wallet
  export SAFE_GOV_OWNERS="$(acct 1),$(acct 2),$(acct 3),$(acct 4),$(acct 5)" SAFE_GOV_THRESHOLD=3
  export SAFE_GUARDIAN_OWNERS="$(acct 1),$(acct 2),$(acct 3),$(acct 4)" SAFE_GUARDIAN_THRESHOLD=2
  export SAFE_OPS_OWNERS="$(acct 1),$(acct 2)" SAFE_OPS_THRESHOLD=2
  COMMITTEE="$(acct 6),$(acct 7),$(acct 8)"
  export SIGMA_SIGNERS="$COMMITTEE"
  if [ "$STACK" = equity ]; then
    export RELAYER_A_SIGNERS="$COMMITTEE" RELAYER_B_SIGNERS="$COMMITTEE"
  else
    export NAV_SIGNERS="$COMMITTEE" FUND_ISSUER="$(acct 9)" FUND_RESERVE="$(acct 9)" NAV_SOLVERS="$(acct 9)"
    # no Circle USDC on plain anvil: a 6-decimal test stablecoin stands in
    unset LOAN_TOKEN
    export LOAN_NAME="Dry-run USDC" LOAN_SYMBOL="USDC" LOAN_DECIMALS=6 LOAN_FAUCET=0
  fi
  BOOK="$ROOT/deployments/31337.$STACK.dryrun.json"
else
  unset DRY_RUN PRIVATE_KEY
  RPC="${RPC:-$(cfg .rpc)}"
  BOOK="$ROOT/deployments/$CID.json"
fi
export BOOK_OUT="$BOOK" BOOK
