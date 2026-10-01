# Key rotation, per chain (RB-11)

The service keys are encrypted keystores, `~/.credence/keys/<chainId>/<role>.json` + `<role>.password`, 0600 (layout agreed with A, 2026-10-01). Roles: 46630 `keeper`, `relayer-{a,b}-node-{1,2,3}`, `relayer-{a,b}-submitter`, `sigma-{1,2,3}`; 421614 `keeper`, `sigma-{1,2,3}`, `nav-{1,2,3}`, `nav-submitter`, `issuer`, `solver-main`.

**A gas-only key** (`keeper`, `relayer-*-submitter`, `nav-submitter`): no on-chain role to change, except the 421614 keeper (the registry's operator) and `solver-main` (`navSolvers`).
1. New keystore: `cast wallet new ~/.credence/keys/46630 --unsafe-password "$(openssl rand -hex 16 | tee ~/.credence/keys/46630/keeper.password.new)"`, then rename it `keeper.json`, the password file `keeper.password`, both `chmod 600` (keep the old pair as `keeper.old.*`).
2. Fund the new address ([wallet-low.md](wallet-low.md)) and move the old balance.
3. For the 421614 keeper or the solver: the timelock grants the new address (a `make gov-propose` batch from A's tooling), then revokes the old one.
4. `make services-config CHAIN=46630` (re-reads the addresses), then restart the service: `docker compose -p credence-testnet -f infra/prod/docker-compose.yml restart keeper-46630`.

**A committee key** (`relayer-*-node-*`, `sigma-*`, `nav-*`): the contract only accepts reports signed by its configured signers.
1. Make the new keystore as above (a new role file, e.g. `relayer-a-node-4`), and have the timelock add it to the committee (`gov-propose`).
2. Overlap for 24 h: point the node at the new key (rename the files to the node's role, restart the node).
3. The timelock removes the old signer. Delete the old keystore.

**The issuer** (421614, also the reserve wallet, ADR-0122): the fund's issuer change goes through the Ops Safe / timelock; move the test USDC and the allowance to the new EOA, then restart `navstrike-421614`.

Never paste a key or a password on the board; post the new address only.
