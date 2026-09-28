// Scenario A on the devnode (make scenario-a-e2e, ADR-0012): shared setup for the scenario scripts.
import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  stringToHex,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

export const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8547";
export const ROOT = resolve(import.meta.dirname, "../../../..");
export const OUT = resolve(
  ROOT,
  process.env.SCENARIO_DIR ?? "target/be/scenario-a",
);
mkdirSync(OUT, { recursive: true });
export const WAD = 10n ** 18n;
export const DEV_KEY =
  "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659" as const; // public nitro dev key
export const book = JSON.parse(
  readFileSync(
    resolve(
      ROOT,
      process.env.DEPLOYMENTS_FILE ?? "deployments/412346.local.json",
    ),
    "utf8",
  ),
);
export const pub: PublicClient = createPublicClient({ transport: http(RPC) });
export const chain = {
  id: 412346,
  name: "devnode",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
} as const;
export type Wallet = WalletClient<Transport, Chain, Account>;
export const dev: Wallet = createWalletClient({
  account: privateKeyToAccount(DEV_KEY),
  transport: http(RPC),
  chain,
});

/** Scenario actors: deterministic keys, one per role (a fresh SALT gives a fresh cast). */
const SALT = process.env.SCENARIO_SALT ?? "s3";
export const actorKey = (name: string): Hex =>
  keccak256(stringToHex(`credence-scenario-a:${SALT}:${name}`));
export const actor = (name: string): PrivateKeyAccount =>
  privateKeyToAccount(actorKey(name));
export const wallet = (a: PrivateKeyAccount): Wallet =>
  createWalletClient({ account: a, transport: http(RPC), chain });

export const assetId = (ticker: string) =>
  (book.assetIds?.[ticker] as Hex | undefined) ??
  keccak256(stringToHex(`${ticker}:${ticker === "SPY" ? "ARCX" : "XNAS"}`));
export const venueId = (v: string) => stringToHex(v, { size: 32 });

export const CalendarAbi = parseAbi([
  "struct Session { uint40 extOpen; uint40 open; uint40 close; uint40 extClose; uint8 closureTypeAfter; }",
  "function sessionCount(bytes32 venue) view returns (uint256)",
  "function sessions(bytes32 venue, uint256 from, uint256 count) view returns (Session[])",
]);
export const Erc20 = parseAbi([
  "function mint(address,uint256)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

type Call = {
  abi: readonly unknown[];
  address: Address;
  functionName: string;
  args?: readonly unknown[];
};
/** Send with gas = estimate × 1.5 (Nitro's reentrancy-sentry margin, BE-chain 00:26) and require success. */
export async function send(w: Wallet, req: Call) {
  const est = await pub.estimateContractGas({
    ...req,
    account: w.account!.address,
  } as never);
  const h = await w.writeContract({ ...req, gas: (est * 3n) / 2n } as never);
  const r = await pub.waitForTransactionReceipt({ hash: h });
  if (r.status !== "success") throw new Error(`reverted: ${req.functionName}`);
  return r;
}

export interface Sess {
  extOpen: number;
  open: number;
  close: number;
  extClose: number;
  closureTypeAfter: number;
}
export async function chainSessions(venue: string): Promise<Sess[]> {
  const cal = book.shared.calendar as Address;
  const n = await pub.readContract({
    abi: CalendarAbi,
    address: cal,
    functionName: "sessionCount",
    args: [venueId(venue)],
  });
  const rows = await pub.readContract({
    abi: CalendarAbi,
    address: cal,
    functionName: "sessions",
    args: [venueId(venue), 0n, n],
  });
  return rows.map((s) => ({
    extOpen: Number(s.extOpen),
    open: Number(s.open),
    close: Number(s.close),
    extClose: Number(s.extClose),
    closureTypeAfter: Number(s.closureTypeAfter),
  }));
}

/** The first session still ahead of `now` (its close is the scenario's Friday close). */
export function friday(
  s: Sess[],
  now: number,
): { i: number; s: Sess; next: Sess } {
  const i = s.findIndex((x) => x.close > now);
  if (i < 0 || !s[i + 1])
    throw new Error("no upcoming close in the on-chain calendar");
  return { i, s: s[i]!, next: s[i + 1]! };
}
