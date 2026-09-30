# ADR-0117 · BE-chain · `SeniorVault.disable(id)`: an empty market leaves the vault (QA-11)

Status: accepted (S5) · Date: 2026-09-30

## Context
QA-11 (Low, QA-sec 2026-09-29 18:55): `SeniorVault.setCap` enables markets append-only, up to `MAX_QUEUE = 32`, and
nothing removes one (a cap of 0 keeps the slot). `CredenceMarket` lists up to 64 markets, so the 33rd market could
never receive senior liquidity. PM ruling (board 2026-09-29 22:00): add `disable(id)` for a market with 0 supplied.

## Decision
- `disable(bytes32 id)`, **timelock only** (so it has the governance delay, 1 h on testnet), reverts
  - `UnknownMarket(id)` if the market is not enabled (never had a cap, or already disabled);
  - `MarketNotEmpty(id, supplied)` while the market's `totalSupplyAssets` is not 0, **dust included**.
    `totalAssets` sums the enabled markets, so disabling a market that still holds money would drop that money from
    the share price. The allocator first pulls it out with `deallocate` (a market with borrowers must be wound down
    first).
- It sets the cap to 0 and removes the market from the enabled list and from both queues. The other entries keep
  their order (the order is the allocator's policy), so a market in the middle of the withdraw queue is removed
  without reordering the rest.
- `setCap` enables a disabled market again (it is pushed at the end of the list).
- New view `enabledMarkets()` (for the testnet post-deploy check), new event `MarketDisabled(id)`, new error
  `MarketNotEmpty(bytes32,uint256)`. All additive; the frozen ABIs are regenerated.
- `MAX_QUEUE` stays 32 (testnet lists 7 markets).

## Tests
`contracts/test/security/edge/VaultEdges.t.sol`: `test_E_V04_QA11_disableFreesASlotAt32` (the old pin, flipped into a
regression), `test_E_V05_QA11_disableEmptyMarketInBothQueues`, `test_E_V06_QA11_disableRefusesDustSupplied`,
`test_E_V07_QA11_disableAccessAndUnknown`.
