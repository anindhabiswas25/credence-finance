// Scenario sets for off-chain quotes (ADR-0106 files). The engine stores only packed words and
// `scenarioHash(asset, type)`; the API loads the same files QE ships and picks the one whose hash
// equals the engine's, so a quote can never use a set the chain does not hold.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { loadScenarioSet, type ScenarioSet } from "@credence/sdk/risk";
import type { Hex } from "viem";
import { log } from "./log.ts";

export interface SetStore {
  byHash(scenarioHash: Hex): ScenarioSet | undefined;
  size(): number;
}

/** Every `credence.scenario-set/v1` file under `dirs` (non-recursive), indexed by scenarioHash. */
export function loadSetStore(dirs: string[]): SetStore {
  const sets = new Map<string, ScenarioSet>();
  for (const dir of dirs) {
    let files: string[];
    try {
      files = readdirSync(dir).filter((f) => f.endsWith(".json"));
    } catch {
      log.warn({ dir }, "scenario-set directory not found");
      continue;
    }
    for (const f of files) {
      const path = join(dir, f);
      if (!statSync(path).isFile()) continue;
      const text = readFileSync(path, "utf8");
      if (!text.includes('"credence.scenario-set/v1"')) continue;
      try {
        const s = loadScenarioSet(text);
        if (s.scenarioHash) sets.set(s.scenarioHash.toLowerCase(), s);
      } catch (err) {
        log.warn({ path, err: String(err) }, "invalid scenario-set file skipped");
      }
    }
  }
  log.info({ sets: sets.size, dirs }, "scenario sets loaded");
  return memorySetStore([...sets.values()]);
}

export function memorySetStore(list: ScenarioSet[]): SetStore {
  const m = new Map(list.filter((s) => s.scenarioHash).map((s) => [s.scenarioHash!.toLowerCase(), s]));
  return { byHash: (h) => m.get(h.toLowerCase()), size: () => m.size };
}
