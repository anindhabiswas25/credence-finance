// Node-only helpers (filesystem).
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { parseAddressBook, type AddressBook } from "./addresses.js";

/**
 * Load `deployments/<chainId>.json` (or the git-ignored `<chainId>.local.json` written by local deploys,
 * which wins when present). `dir` defaults to `$DEPLOYMENTS_DIR` or `./deployments`.
 */
export function loadAddressBook(chainId: number, dir = process.env.DEPLOYMENTS_DIR ?? "deployments"): AddressBook {
  const candidates = [resolve(dir, `${chainId}.local.json`), resolve(dir, `${chainId}.json`)];
  const file = process.env.DEPLOYMENTS_FILE ? resolve(process.env.DEPLOYMENTS_FILE) : candidates.find((f) => existsSync(f));
  if (!file) throw new Error(`no address book for chain ${chainId} in ${dir}`);
  return parseAddressBook(JSON.parse(readFileSync(file, "utf8")), chainId);
}

export * from "./index.js";
