# ADR-0106 · BE-chain · Scenario-set, joint-set and risk-bundle file format

Status: Accepted · Date: 2026-09-28 · Owner: BE-chain (Sprint 2 item A2)

## Context

The Build Guide fixes the on-chain side (`setScenarioSet(assetId, closureType, packedSortedZ, n)`,
`setJointColumn(assetId, packedZ)`, `setParams(RiskParams)`, `setSigmaFloor`, `scenarioHash(assetId, type)`,
§8.9.1) and the deploy step (`LoadScenarioSet.s.sol`, §13.2 step 8; post-deploy check "`engine.scenarioHash` equals
the hash of the calibration output", §13.3). It does not define the file that carries calibration output (QE) to
the chain. This ADR defines it. The code is `crates/risk-core/src/setfile.rs` (feature `files`), exposed through
`risk-cli validate-set | build-set | build-joint` and `risk-py` (`credence_risk.build_set`, `load_set_file`, …).

## Decision

### 1. Three file kinds, one `format` tag each

| `format` | What | Consumed by |
| --- | --- | --- |
| `credence.scenario-set/v1` | one (asset, closure type): N ascending z | `setScenarioSet` |
| `credence.joint-set/v1` | the K joint stress weekends, one column per asset | `setJointColumn` |
| `credence.risk-bundle/v1` | `RiskParams` + references to set files and one joint file + σ floors + initial σ | `LoadScenarioSet.s.sol` |

Integers that can exceed 2^53 (WAD values) are **decimal strings**; small integers (`n`, `closureType`, `k`, `z`)
are JSON numbers (decimal strings are accepted too). 32-byte values are `0x` + 64 lowercase hex digits.

### 2. Scenario set (`credence.scenario-set/v1`)

```json
{
  "format": "credence.scenario-set/v1",
  "asset": "NVDA:XNAS",
  "assetId": "0x2ba7fe02…c620",
  "closureType": 2,
  "n": 3000,
  "packed": ["0x…", "…"],
  "scenarioHash": "0x…",
  "contentHash": "0x…",
  "z": [-9318, -8028, "…"],
  "meta": { "dataGrade": "free-2016", "vendor": "alpaca", "…": "free-form, not hashed" }
}
```

Rules (every one is enforced by `risk-cli validate-set`, and each has a unit test):

1. `assetId = keccak256(asset)` with `asset = "<TICKER>:<MIC>"` (ADR-0101). `asset` is optional; if present it
   must hash to `assetId`.
2. `closureType ∈ {1 OVERNIGHT, 2 WEEKEND, 3 HOLIDAY_WEEKEND}` (§8.1 enum; `NONE` has no set).
3. `1 ≤ n ≤ 16,384`. The guide's target is 1,000–3,000; outside that range the validator **warns** (exit 0).
4. **Packing** (== `PackedInt.sol`, risk-core `pack_i16`): 16 × int16 per uint256 word, value `i` in word `i / 16`,
   lane `i % 16`, lane 0 = the **least-significant** 16 bits, two's complement. `packed.length = ceil(n / 16)`.
   Unused lanes of the last word must be 0 (canonical payload, so one set has exactly one hash).
5. The unpacked values are **ascending** (non-strict). The engine rejects anything else with `NotSorted`.
6. `z`, if present, equals the unpacked `packed` (it is a readable copy; the chain never sees it).
7. `scenarioHash = keccak256(word_0 ‖ … ‖ word_{m−1})`, each word 32 bytes big-endian, i.e.
   `keccak256(abi.encodePacked(uint256[] packed))`. This is exactly what the engine stores in `setScenarioSet` and
   returns from `scenarioHash(assetId, closureType)`, so the §13.3 check is a string comparison.
8. `contentHash = sha256("credence.scenario-set/v1" ‖ assetId (32 B) ‖ closureType (1 B) ‖ n (u32 BE) ‖ words)`.
   It addresses the file by content: independent of JSON formatting, key order and `meta`.
9. File name: `<TICKER>-<MIC>-<closureType>-<contentHash[0..8]>.json`, e.g. `NVDA-XNAS-2-63c7ce73.json`
   (`fileName` in the validator output). A different name is not an error.

### 3. Joint set (`credence.joint-set/v1`)

```json
{
  "format": "credence.joint-set/v1",
  "k": 256,
  "assets": ["NVDA:XNAS", "AAPL:XNAS"],
  "assetIds": ["0x…", "0x…"],
  "columns": [["0x…", "…"], ["0x…", "…"]],
  "columnHashes": ["0x…", "0x…"],
  "contentHash": "0x…",
  "z": [[…], […]],
  "meta": { "closures": "…free-form…" }
}
```

- `columns[i]` is asset `i`'s K values, packed as in §2.4, **in weekend order** (row j of every column is the same
  historical closure; not sorted). `assetIds`, `columns`, `columnHashes` (and `assets`, `z` when present) are
  parallel arrays; no asset twice; `1 ≤ k ≤ 16,384`.
- `columnHashes[i] = keccak256(abi.encodePacked(columns[i]))` == the new engine view `jointHash(assetId)` after
  `setJointColumn` (an **additive** v1 ABI change, `deployments/abis/v1/IRiskEngine.json`).
- `contentHash = sha256("credence.joint-set/v1" ‖ k (u32 BE) ‖ for each column in file order: assetId ‖ words)`.
- File name: `joint-<contentHash[0..8]>.json`.

### 4. Risk bundle (`credence.risk-bundle/v1`)

```json
{
  "format": "credence.risk-bundle/v1",
  "params": { "alpha": "1000000000000000", "kappa": "30000000000000000", "theta": "1000000000000000000",
              "costOfCap": "150000000000000000", "eta": "4000000000000000000", "beta": "975000000000000000",
              "uMax": "500000000000000000", "minPremium": "500000", "kStress": 256 },
  "scenarioSets": ["NVDA-XNAS-2-63c7ce73.json", "…"],
  "jointSet": "joint-256adcb5.json",
  "sigmaFloors": { "assetIds": ["0x…"], "closureTypes": [2], "floors": ["20000000000000000"] },
  "sigmas":      { "assetIds": ["0x…"], "closureTypes": [2], "values": ["40000000000000000"] },
  "meta": { }
}
```

- `params` is `RiskParams` (Types.sol, struct order alpha, kappa, theta, costOfCap, eta, beta, uMax, minPremium,
  kStress) with the engine's own `setParams` checks: `0 < alpha ≤ 1e18`, `kappa < 1e18`, `beta ≤ 1e18`,
  `uMax ≤ 1e18`.
- Paths are **relative to the bundle's directory**. Every referenced file is fully validated (§2, §3); a second set
  for the same (assetId, closureType) is an error; the joint set's `k` must equal `params.kStress`.
- `sigmaFloors` / `sigmas` are parallel arrays (no key twice); an initial σ below its floor is an error (the engine
  would revert `SigmaBelowFloor`).

### 5. Loading (`contracts/script/LoadScenarioSet.s.sol`)

Order: `setParams` → `setSigmaFloor`* → `setScenarioSet`* → `setJointColumn`* → `updateSigma`* (only when the
broadcaster is the engine's `sigmaOracle`, which is true on local chains; on a live chain σ goes through
`SigmaOracle` / keeper J7). Before each write the script recomputes `keccak256(abi.encodePacked(words))` and compares
it with the file; after the broadcast it reads `params()`, every `scenarioHash` and every `jointHash` back from the
engine. `make risk-load-set RISK_BUNDLE=<file> [LOCAL_RPC=…] [RISK_ENGINE=…]` runs `risk-cli validate-set` first.
The script sends the calls directly, so it refuses chain ids 421614 and 42161; the testnet flow schedules the same
calls through the timelock (S5).

### 6. Producing files (QE)

Use the same code that validates them, so hashes can never drift:
- Rust / CLI: `risk-cli build-set '{"asset":"NVDA:XNAS","closureType":2,"z":[…],"meta":{…}}'`,
  `risk-cli build-joint '{"columns":[{"asset":"NVDA:XNAS","z":[…]}, …],"meta":{…}}'`.
- Python: `credence_risk.build_set(asset, closure_type, z, meta=None) -> dict` and
  `credence_risk.build_joint([(asset, z), …], meta=None) -> dict` (A3, `crates/risk-py`).

**Mapping from QE's pre-ADR documents** (`kind: "credence.scenario-set.v1"`, `packedWords`, `symbol`,
`provenance`): `kind` → `format` (note `/v1`), `packedWords` → `packed`, `symbol` → `asset` as `"<TICKER>:<MIC>"`,
`provenance` → `meta`, `closureTypeName` → `meta`; add `scenarioHash` and `contentHash`. Joint:
`columns[{assetId, symbol, z, packedWords}]` → the parallel arrays of §3; `closures` → `meta`. The packing itself is
already identical (checked: QE's NVDA `assetId` and packing match risk-core). The validator recognises a
pre-ADR document and says so.

### 7. Example

`contracts/test/fixtures/risk/`: `example-bundle.json`, `NVDA-XNAS-2-63c7ce73.json` (N = 1,000, synthetic 1.3 ×
normal quantiles, `meta.example = true`), `joint-256adcb5.json` (K = 256, NVDA + AAPL). `forge test --match-contract
LoadScenarioSetTest` loads it into `MockRiskEngine` and checks the stored hashes against the values risk-core wrote.

## Consequences

- One definition of the payload and both hashes, in risk-core; the Stylus build does not compile it (feature
  `files` pulls `serde_json` + `sha2`, `std` only), so the engine size is unaffected.
- `IRiskEngine` v1 gains `jointHash(bytes32)`; the Stylus engine implements it with `setJointColumn` (S2 item C).
- A v2 format would get a new `format` tag; `validate-set` rejects unknown tags.
