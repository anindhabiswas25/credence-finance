// Acceptance 4, engine level (make api-engine-e2e): the API's risk-wasm math equals the Stylus Risk
// Engine on the devnode for 100 random positions over QE's 18 loaded scenario sets. For each: the
// set whose hash equals `engine.scenarioHash` (as the API picks it), then
//   safeLtv   == engine.safeLtv(asset, type, maxLtv, 0)
//   bell      == engine.bellStatus(asset, type, C, D_proj, maxLtv, 0, false)   (status, cure repay, cure value)
//   premium   == engine.quoteCover(asset, type, days, C, D_proj, uAfter)       (premium, E[L], ES)
// The market-level check (/bell == CredenceMarket.bellStatus) runs once DeployCoreLocal is on the devnode.
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { IRiskEngineAbi } from "@credence/sdk";
import { bellFromSafeLtv, coverQuote, loadScenarioSet, ready, safeLtvFor, type RiskParams, type ScenarioSet } from "@credence/sdk/risk";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8547";
const N = Number(process.env.N ?? 100);
const root = resolve(import.meta.dirname, "../../..");
const book = JSON.parse(readFileSync(resolve(root, "deployments/412346.local.json"), "utf8"));
const engine = book.shared.riskEngine as Address;
const client = createPublicClient({ transport: http(RPC) });
const WAD = 10n ** 18n;

// deterministic PRNG (mulberry32), seed from env for reproducibility
let seed = Number(process.env.SEED ?? 20260928) >>> 0;
const rnd = () => {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const between = (lo: bigint, hi: bigint) => lo + (BigInt(Math.floor(rnd() * 1e9)) * (hi - lo)) / 1_000_000_000n;

await ready;
const dir = resolve(root, "calibration/out/scenarios");
const sets = new Map<string, ScenarioSet>();
for (const f of readdirSync(dir).filter((x) => x.endsWith(".json"))) {
  const s = loadScenarioSet(readFileSync(resolve(dir, f), "utf8"));
  sets.set(`${s.assetId!.toLowerCase()}:${s.closureType}`, s);
}
const read = <T>(functionName: string, args: unknown[]) =>
  client.readContract({ abi: IRiskEngineAbi, address: engine, functionName: functionName as never, args: args as never }) as Promise<T>;
const p = await read<{ alpha: bigint; kappa: bigint; theta: bigint; costOfCap: bigint; eta: bigint; beta: bigint; uMax: bigint; minPremium: bigint }>("params", []);
const params: RiskParams = { alpha: p.alpha, kappa: p.kappa, theta: p.theta, costOfCap: p.costOfCap, eta: p.eta, beta: p.beta, uMax: p.uMax, minPremium: p.minPremium };

const keys = [...sets.keys()];
let checked = 0;
let needs = 0;
let binding = 0;
const fail: string[] = [];
for (let i = 0; i < N; i++) {
  const key = keys[Math.floor(rnd() * keys.length)]!;
  const set = sets.get(key)!;
  const asset = set.assetId as Hex;
  const t = set.closureType!;
  const onHash = await read<Hex>("scenarioHash", [asset, t]);
  if (onHash.toLowerCase() !== set.scenarioHash!.toLowerCase()) {
    fail.push(`${key}: engine hash ${onHash} != file ${set.scenarioHash}`);
    continue;
  }
  const sigma = await read<bigint>("sigma", [asset, t]);
  const maxLtv = between(50n * WAD / 100n, 95n * WAD / 100n);
  const c = between(1_000n * 10n ** 6n, 5_000_000n * 10n ** 6n); // $1k … $5M
  const d = (c * between(30n * WAD / 100n, 110n * WAD / 100n)) / WAD; // LTV 30% … 110%
  const days = BigInt(t === 1 ? 1 : t === 2 ? 3 : 4);
  const uAfter = between(0n, 50n * WAD / 100n);

  const safe = safeLtvFor({ set, params, sigma, maxLtv });
  const onSafe = await read<bigint>("safeLtv", [asset, t, maxLtv, 0n]);
  // the market takes min(maxLtvEff, engine.safeLtv); the engine already caps at maxLtv
  const bell = bellFromSafeLtv({ collateralValue: c, debtProjected: d, valuationPrice: WAD, collDecimals: 18, loanDecimals: 6 }, safe);
  const [st, repay, cureValue] = await read<[number, bigint, bigint]>("bellStatus", [asset, t, c, d, maxLtv, 0n, false]);
  const q = coverQuote({ set, params, sigma, collateralValue: c, debtProjected: d, maxLtv, valuationPrice: WAD, collDecimals: 18, loanDecimals: 6, closureDays: days, utilAfter: uAfter });
  const [prem, el, es] = await read<[bigint, bigint, bigint]>("quoteCover", [asset, t, Number(days), c, d, uAfter]);

  const ok = safe === onSafe && bell.status === Number(st) && bell.cureRepay === repay && bell.cureCollateralValue === cureValue && q.premium === prem && q.expectedLoss === el && q.expectedShortfall === es;
  if (!ok) fail.push(JSON.stringify({ key, maxLtv: String(maxLtv), c: String(c), d: String(d), uAfter: String(uAfter), safe: [String(safe), String(onSafe)], status: [bell.status, Number(st)], repay: [String(bell.cureRepay), String(repay)], premium: [String(q.premium), String(prem)] }));
  checked++;
  if (bell.status === 1) needs++;
  if (safe < maxLtv) binding++;
}
console.log(`engine ${engine} @ ${RPC}: ${checked} positions checked over ${keys.length} sets (NEEDS_ACTION ${needs}, safe LTV below max ${binding}), mismatches ${fail.length}`);
if (fail.length) {
  for (const f of fail.slice(0, 5)) console.error(f);
  process.exit(1);
}
console.log("OK: risk-wasm safeLtv, bellStatus and quoteCover == the Stylus engine for every position");
