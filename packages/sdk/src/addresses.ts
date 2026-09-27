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
    .partial({ guardian: true, oracle: true, feedB: true }),
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
    .optional(),
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
    .optional(),
  tokens: z.record(z.string(), address).optional(),
});

export type AddressBook = z.infer<typeof AddressBookSchema>;

/** Validate and normalise (checksum) an address book. Throws with every problem listed. */
export function parseAddressBook(json: unknown, expectChainId?: number): AddressBook {
  const book = AddressBookSchema.parse(json);
  if (expectChainId !== undefined && book.chainId !== expectChainId) {
    throw new Error(`address book is for chain ${book.chainId}, expected ${expectChainId}`);
  }
  return book;
}
