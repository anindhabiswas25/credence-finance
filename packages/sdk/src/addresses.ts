// Typed address book `deployments/<chainId>.json` (Build Guide §13.2). Browser-safe: parse only.
// Node callers use `loadAddressBook` from "@credence/sdk/node".
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";
import { z } from "zod";

const address = z
  .string()
  .refine((s) => isAddress(s, { strict: false }), "not an address")
  .transform((s) => getAddress(s) as Address);
const bytes32 = z
  .string()
  .refine((s) => isHex(s) && s.length === 66, "not bytes32")
  .transform((s) => s as Hex);

export const AddressBookSchema = z.object({
  chainId: z.number().int().positive(),
  startBlock: z.number().int().nonnegative(),
  release: z.string().optional(),
  shared: z
    .object({
      timelock: address,
      guardian: address,
      calendar: address,
      clock: address,
      oracle: address,
      feedA: address,
      feedB: address,
      feedNav: address.optional(),
      riskEngine: address.optional(),
      sigmaOracle: address.optional(),
      sequencerHealth: address.optional(),
    })
    // A NAV-only book (421614, ADR-0014) has feedNav and no equity feeds.
    .partial({
      timelock: true,
      guardian: true,
      oracle: true,
      feedA: true,
      feedB: true,
    }),
  equity: z
    .object({
      market: address,
      vault: address,
      pool: address,
      auctionHouse: address,
      reserve: address,
      treasury: address,
      tips: address,
      markets: z.record(z.string(), bytes32),
    })
    .partial()
    .nullish(), // null until a core stack is deployed (DeployCoreLocal)
  nav: z
    .object({
      market: address,
      vault: address,
      pool: address,
      settlement: address,
      solverAuction: address,
      reserve: address,
      treasury: address,
      tips: address,
      markets: z.record(z.string(), bytes32),
    })
    .partial()
    .nullish(), // null until a core stack is deployed (DeployCoreLocal)
  tokens: z.record(z.string(), address).optional(),
  /** Asset ids by ticker (local deployments list them; on testnet they are keccak256("TICKER:MIC")). */
  assetIds: z.record(z.string(), bytes32).optional(),
});

export type AddressBook = z.infer<typeof AddressBookSchema>;

/**
 * Legacy (S1): the local deploy script used to write a flat book
 * (`{ chainId, startBlock, clock, calendar, feedA, … }`). Lift it into the §13.2 shape.
 */
export function normalizeAddressBook(json: unknown): unknown {
  if (!json || typeof json !== "object" || "shared" in json) return json;
  const j = json as Record<string, unknown>;
  const pick = (k: string) => (typeof j[k] === "string" ? j[k] : undefined);
  const shared = {
    timelock: pick("timelock"),
    guardian: pick("guardian"),
    calendar: pick("calendar"),
    clock: pick("clock"),
    oracle: pick("oracle"),
    feedA: pick("feedA"),
    feedB: pick("feedB"),
    feedNav: pick("navFeed") ?? pick("feedNav"),
    sequencerHealth: pick("sequencerHealth"),
  };
  const tokens = Object.fromEntries(
    Object.entries(j).filter(
      ([k, v]) =>
        typeof v === "string" && (/^t[A-Z]+$/.test(k) || k === "usdc"),
    ),
  );
  const markets = Object.fromEntries(
    Object.entries(j)
      .filter(([k]) => k.startsWith("assetId_"))
      .map(([k, v]) => [k.slice("assetId_".length), v]),
  );
  return {
    chainId: Number(j.chainId),
    startBlock: Number(j.startBlock ?? 0),
    release: "local",
    shared: Object.fromEntries(
      Object.entries(shared).filter(([, v]) => v !== undefined),
    ),
    tokens,
    assetIds: markets,
  };
}

/** Validate and normalise (checksum) an address book. Throws with every problem listed. */
export function parseAddressBook(
  json: unknown,
  expectChainId?: number,
): AddressBook {
  const book = AddressBookSchema.parse(normalizeAddressBook(json));
  if (expectChainId !== undefined && book.chainId !== expectChainId) {
    throw new Error(
      `address book is for chain ${book.chainId}, expected ${expectChainId}`,
    );
  }
  return book;
}
