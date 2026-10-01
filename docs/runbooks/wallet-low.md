# A hot wallet is low (KeeperWalletLow, WalletLow, WalletBelowFloor, TipsBudgetLow)

The keeper reads the balances hourly (`credence_keeper_wallet_balance_gwei{wallet=…}`, per chain). Watched wallets: on 46630 `keeper`, `relayer-a-submitter`, `relayer-b-submitter`; on 421614 `keeper`, `nav-submitter`, `issuer`, `solver-main`. Their addresses: `cat infra/prod/generated/46630/roles.txt`.

1. Which wallet and chain: the alert's `wallet` and `chain` labels. Its balance:
   ```sh
   cast balance --ether $(sed -n 's/^keeper=//p' infra/prod/generated/46630/roles.txt) --rpc-url $RPC
   ```
2. Top it up with test ETH: from the deployer / your own wallet (`cast send --rpc-url $RPC --keystore <your keystore> <addr> --value 0.05ether`), or a faucet (Arbitrum Sepolia: the Alchemy / QuickNode faucets; Robinhood Chain testnet: its faucet). Keep the keeper at ≥ 0.05 ETH, the submitters at ≥ 0.02 ETH.
3. **The issuer on 421614** also needs test USDC for T+1 redemptions (it is the reserve wallet, ADR-0122): `cast call <usdc> 'balanceOf(address)(uint256)' <issuer> --rpc-url $RPC`.
4. **TipsBudgetLow** (the KeeperTips budget lasts < 3 days at the last 24 h's spend): fund the stack's tips contract with its loan token (tUSDG on 46630, USDC on 421614): approve and transfer to `jq -r .equity.tips infra/prod/generated/46630/book.json` (or `.nav.tips`).
5. The page resolves at the next hourly read (J12 `wallet-balances`); `make testnet-services-check` stays green.
