// risk-wasm smoke test: the Node and web builds both load, every export runs, and results equal risk-cli.
//   make risk-wasm-test
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const pkg = join(here, "..", "pkg");
const fix = join(root, "contracts", "test", "fixtures", "risk");
const cliBin = process.env.RISK_CLI ?? join(root, "target", "release", "risk-cli");
const cli = (cmd, args) =>
  existsSync(cliBin) ? JSON.parse(execFileSync(cliBin, [cmd, "-"], { input: JSON.stringify(args) }).toString()) : null;
const WAD = 10n ** 18n;

const node = await import(join(pkg, "node.mjs"));
await node.ready;
const web = await import(join(pkg, "web", "credence_risk_wasm.js"));
web.initSync({ module: readFileSync(join(pkg, "web", "credence_risk_wasm_bg.wasm")) });

let n = 0;
for (const [name, r] of [["node", node], ["web", web]]) {
  // scalar vectors shared with risk-cli's and risk-py's tests
  assert.equal(r.kinkedRate(850n * WAD / 1000n, 2n * WAD / 100n, 6n * WAD / 100n, 80n * WAD / 100n, 9n * WAD / 10n), 76666666666666666n);
  assert.match(String(r.safeLtv(-5897, 4n * WAD / 100n, 0n, 3n * WAD / 100n, 75n * WAD / 100n)), /^7411/);
  const x = r.liquidationLot(13_500_000_000n, 100n * WAD, 153648n * WAD / 1000n, 1584n * WAD / 10n, 8n * WAD / 10n,
    11n * WAD / 10n, 3n * WAD / 100n, 18, 6);
  assert.match(String(x), /^585131/);
  const c = r.clear([300n, 300n], [12440n, 12411n], ["0x" + "01".repeat(32), "0x" + "02".repeat(32)], 500n, 12222n);
  assert.deepEqual(c, { pStar: 12411n, fills: [300n, 200n], qPool: 0n });
  assert.equal(r.bellStatus(18000n, 13500n, 741182000000000000n, false).status, 1);
  assert.equal(r.utilization(2n ** 200n, 2n ** 201n), WAD / 2n);
  assert.equal(r.value(100n * WAD, 180n * WAD, 0n, 0n, 18, 6).collateralValue, 18_000_000_000n);
  assert.equal(r.quantileIndex(3000, WAD / 1000n), 2);
  assert.equal(r.projectedDebt(1_000_000n, 0n, 3), 1_000_000n);
  assert.equal(r.sigmaMinAllowed(WAD, 0n), WAD);
  assert.equal(r.elapsedDays(0n, 2n * 86400n + 5n), 2n);
  assert.equal(r.blendedPrice(500n, 12411n, 0n, 12222n), 12411n);
  assert.equal(r.accrueInterest(1_000_000n, 0n, 3600n), 0n);
  assert.ok(r.seniorRate(WAD / 10n, WAD / 2n, WAD / 10n, WAD / 10n) > 0n);
  assert.equal(r.gapFactor(0, 4n * WAD / 100n, 0n, 3n * WAD / 100n), 97n * WAD / 100n);
  const s = r.settlePosition(50n * WAD, 100n * WAD, 150n * WAD, 13_500_000_000n, 3n * WAD / 100n, 18, 6);
  assert.equal(s.proceeds, 7_500_000_000n);
  assert.equal(s.fullClose, false);
  assert.ok(r.precloseLot(13_500_000_000n, 100n * WAD, 150n * WAD, 150n * WAD, 7n * WAD / 10n, WAD / 100n, 18, 6) >= 0n);
  assert.ok(r.cureAmounts(13_500_000_000n, 100n * WAD, 180n * WAD, 7n * WAD / 10n, 18, 6).repay > 0n);

  // quote + capacity against risk-cli
  const z = [-9000, -6000, -100, 0, 500];
  const set = new r.ScenarioSet(Int16Array.from(z));
  const input = { sigma: 4n * WAD / 100n, kappa: 3n * WAD / 100n, collateralValue: 18_000_000_000n,
    debtProjected: 13_500_000_000n, closureDays: 3n, theta: WAD, costOfCap: 15n * WAD / 100n, eta: 4n * WAD,
    beta: 975n * WAD / 1000n };
  const q = r.quoteCover(set, input);
  const ref = cli("quote-cover", { set: z, sigma: String(input.sigma), kappa: String(input.kappa),
    collateralValue: "18000000000", debtProjected: "13500000000", closureDays: 3, theta: String(WAD),
    costOfCap: String(input.costOfCap), eta: String(input.eta), beta: String(input.beta) });
  if (ref) {
    assert.deepEqual(q, { premium: BigInt(ref.premium), expectedLoss: BigInt(ref.expectedLoss),
      expectedShortfall: BigInt(ref.expectedShortfall) });
  }
  assert.equal(r.safeLtvFromSet(set, WAD / 1000n, 4n * WAD / 100n, 0n, 3n * WAD / 100n, 75n * WAD / 100n),
    r.safeLtv(-9000, 4n * WAD / 100n, 0n, 3n * WAD / 100n, 75n * WAD / 100n));
  const joint = Int16Array.from([-8000, 300, -2000, 50]);
  const lv = r.coverLossVector(joint, 18_000_000_000n, 13_500_000_000n, 4n * WAD / 100n, 0n, 3n * WAD / 100n);
  const lref = cli("loss-vector", { joint: [...joint], collateralValue: "18000000000", debtProjected: "13500000000",
    sigma: String(4n * WAD / 100n), kappa: String(3n * WAD / 100n) });
  if (lref) {
    assert.deepEqual([...lv], lref.losses.map(BigInt));
    assert.deepEqual(r.packLosses(lv), lref.packed.map(BigInt));
  }
  const cap = r.poolCapacity(new BigUint64Array(4), lv, 3n * WAD / 100n, 10n ** 12n, WAD / 2n);
  assert.equal(cap.ok, true);
  const unc = new r.Uncovered(joint, 4n * WAD / 100n, 0n, 1_000_000n, 7n * WAD / 10n);
  const cap2 = r.poolCapacityWithUncovered(new BigUint64Array(4), lv, [unc], 3n * WAD / 100n, 10n ** 12n, WAD / 2n);
  assert.ok(cap2.worstLoss >= cap.worstLoss);
  assert.throws(() => new r.ScenarioSet(Int16Array.from([1, 0])), /MathError\(NotSorted, 5\)/);
  assert.throws(() => r.kinkedRate(1n, 0n, 0n, 0n, 0n), /MathError\(InvalidInput, 3\)/);

  // ADR-0106 files
  const text = readFileSync(join(fix, "NVDA-XNAS-2-63c7ce73.json"), "utf8");
  const fs = r.ScenarioSet.fromFile(text);
  assert.equal(fs.n, 1000);
  assert.equal(fs.closureType, 2);
  assert.equal(fs.assetId, r.assetId("NVDA:XNAS"));
  assert.equal(fs.scenarioHash, "0xdba636a4e91124b94b147e6db290603769636de2331e87f86a453071b50b13d9");
  assert.deepEqual([...r.unpackZ(fs.packed(), fs.n)], [...fs.z]);
  assert.equal(r.validateSetFile(text).ok, true);
  const bad = JSON.parse(text);
  bad.scenarioHash = "0x" + "00".repeat(32);
  assert.throws(() => r.validateSetFile(JSON.stringify(bad)), /FileError\(\.scenarioHash/);
  const jointText = readFileSync(join(fix, "joint-256adcb5.json"), "utf8");
  assert.equal(r.jointColumnFromFile(jointText, r.assetId("AAPL:XNAS")).length, 256);
  n++;
  console.log(`ok  ${name} build`);
}
console.log(`risk-wasm smoke: ${n} builds passed`);
