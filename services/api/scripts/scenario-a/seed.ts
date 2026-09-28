// Scenario A seeding: the only manual transactions of the run (ADR-0012). After this, only the keeper,
// the relayer (replay vendor) and the bidder bot act.
//
// Underwriters (before the Bell window: a deposit after it only counts from the next epoch):
//   Uma 30,000 USDC, Sara 10,000 USDC, and Sara asks to withdraw half her shares (claimable after settlement).
// Borrowers, sized from the on-chain price and params:
//   Priya  NVDA 500, LTV 74.4%: after the −1% drift she is above the safe LTV but coverable → auto-cover at the Bell.
//   Maya   NVDA 300, LTV 74.6%, auto-cover OFF → pre-close sale at the Bell.
//   Dev    TSLA 100, LTV 74.0%: the −30% Monday gap takes him under HF 1 → REOPEN auction, full close, shortfall.
// Bidders: honest-1, honest-2, lowball, noreveal (bidders.json for the bot), each with 200,000 USDC, allowlisted.
// Notification accounts: every actor gets a verified email and a Telegram chat id (mock providers).
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import postgres from "postgres";
import { parseAbi, parseEther, type Address, type Hex } from "viem";
import {
  ICredenceMarketAbi,
  IOracleAdapterAbi,
  IUnderwriterPoolAbi,
} from "@credence/sdk";
import {
  Erc20,
  OUT,
  WAD,
  actor,
  actorKey,
  book,
  dev,
  pub,
  send,
  wallet,
} from "./lib.ts";

const market = book.equity.market as Address;
const pool = book.equity.pool as Address;
const usdc = book.tokens.usdc as Address;
const registry = book.shared.registry as Address | undefined;
const Registry = parseAbi([
  "function setAllowedBatch(address[] accounts, bool allowed)",
  "function isAllowed(address) view returns (bool)",
]);

const who = {
  uma: actor("uma"),
  sara: actor("sara"),
  priya: actor("priya"),
  maya: actor("maya"),
  dev: actor("dev"),
  honest1: actor("bidder-honest-1"),
  honest2: actor("bidder-honest-2"),
  lowball: actor("bidder-lowball"),
  noreveal: actor("bidder-noreveal"),
};

// gas for everyone, and the keeper's and the relayer's own senders (never the seeding dev key: no nonce races)
for (const a of [...Object.values(who), actor("keeper"), actor("relayer")]) {
  if ((await pub.getBalance({ address: a.address })) < parseEther("0.05"))
    await pub.waitForTransactionReceipt({
      hash: await dev.sendTransaction({
        to: a.address,
        value: parseEther("0.2"),
      }),
    });
}
// allowlist (testnet ComplianceRegistry): bidders receive collateral at claim, borrowers hold it
if (registry) {
  const all = Object.values(who).map((a) => a.address);
  await send(dev, {
    abi: Registry,
    address: registry,
    functionName: "setAllowedBatch",
    args: [all, true],
  });
}

// ── underwriters ──
const poolBal = async (a: Address) =>
  pub.readContract({
    abi: IUnderwriterPoolAbi,
    address: pool,
    functionName: "balanceOf",
    args: [a],
  });
for (const [name, a, amount] of [
  ["uma", who.uma, 30_000n],
  ["sara", who.sara, 10_000n],
] as const) {
  if ((await poolBal(a.address)) > 0n) continue;
  const w = wallet(a);
  const assets = amount * 1_000_000n;
  await send(dev, {
    abi: Erc20,
    address: usdc,
    functionName: "mint",
    args: [a.address, assets],
  });
  await send(w, {
    abi: Erc20,
    address: usdc,
    functionName: "approve",
    args: [pool, assets],
  });
  await send(w, {
    abi: IUnderwriterPoolAbi,
    address: pool,
    functionName: "deposit",
    args: [assets, a.address],
  });
  console.log(
    `${name}: deposited ${amount} USDC, shares ${await poolBal(a.address)}`,
  );
}
{
  const shares = (await poolBal(who.sara.address)) / 2n;
  if (shares > 0n)
    await send(wallet(who.sara), {
      abi: IUnderwriterPoolAbi,
      address: pool,
      functionName: "requestWithdraw",
      args: [shares],
    });
  console.log(`sara: requested a withdrawal of ${shares} shares`);
}

// ── borrowers ──
async function borrower(
  name: string,
  a: ReturnType<typeof actor>,
  ticker: string,
  qtyTokens: bigint,
  ltvBps: bigint,
  autoCover: boolean,
) {
  const id = book.equity.markets[ticker] as Hex;
  const pos = await pub.readContract({
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "position",
    args: [id, a.address],
  });
  if (pos.borrowShares > 0n) return console.log(`${name}: position exists`);
  const p = await pub.readContract({
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "marketParams",
    args: [id],
  });
  const w = await pub.readContract({
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "wiring",
  });
  const v = await pub.readContract({
    abi: IOracleAdapterAbi,
    address: w.oracle,
    functionName: "valuationPrice",
    args: [p.assetId],
  });
  const qty = qtyTokens * WAD;
  const value = (qty * v) / WAD / 10n ** 12n; // USDC units
  const debt = (value * ltvBps) / 10_000n;
  const wl = wallet(a);
  await send(dev, {
    abi: Erc20,
    address: p.collateralToken,
    functionName: "mint",
    args: [a.address, qty],
  });
  await send(wl, {
    abi: Erc20,
    address: p.collateralToken,
    functionName: "approve",
    args: [market, qty],
  });
  await send(wl, {
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "addCollateral",
    args: [id, a.address, qty],
  });
  if (!autoCover)
    await send(wl, {
      abi: ICredenceMarketAbi,
      address: market,
      functionName: "setAutoCover",
      args: [id, false],
    });
  await send(wl, {
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "borrow",
    args: [id, debt, a.address],
  });
  console.log(
    `${name}: ${qtyTokens} ${ticker} at ${Number(v / 10n ** 14n) / 10_000}, borrowed ${Number(debt) / 1e6} USDC (LTV ${Number(ltvBps) / 100}%)${autoCover ? "" : ", auto-cover off"}`,
  );
}
await borrower("priya", who.priya, "NVDA", 500n, 7_440n, true);
await borrower("maya", who.maya, "NVDA", 300n, 7_460n, false);
await borrower("dev", who.dev, "TSLA", 100n, 7_400n, true);

// ── bidders ──
for (const a of [who.honest1, who.honest2, who.lowball, who.noreveal]) {
  if (
    (await pub.readContract({
      abi: Erc20,
      address: usdc,
      functionName: "balanceOf",
      args: [a.address],
    })) <
    100_000n * 1_000_000n
  )
    await send(dev, {
      abi: Erc20,
      address: usdc,
      functionName: "mint",
      args: [a.address, 200_000n * 1_000_000n],
    });
}
// the bot's profiles (priced against the reserve R; INV-AH-03: the low-ball never fills; the non-revealer
// forfeits its bond to the pool)
const bidders = {
  bidders: [
    {
      name: "honest-1",
      key: actorKey("bidder-honest-1"),
      qtyBps: 6_000,
      priceBps: 10_150,
      reveal: true,
    },
    {
      name: "honest-2",
      key: actorKey("bidder-honest-2"),
      qtyBps: 3_000,
      priceBps: 10_050,
      reveal: true,
    },
    {
      name: "lowball",
      key: actorKey("bidder-lowball"),
      qtyBps: 5_000,
      priceBps: 9_000,
      reveal: true,
    },
    {
      name: "noreveal",
      key: actorKey("bidder-noreveal"),
      qtyBps: 2_000,
      priceBps: 10_200,
      reveal: false,
      kinds: ["REOPEN"],
    },
  ],
};
writeFileSync(resolve(OUT, "bidders.json"), JSON.stringify(bidders, null, 1));

// ── notification accounts (email verified + Telegram; the runner points both providers at a mock) ──
if (process.env.DATABASE_URL) {
  const sql = postgres(process.env.DATABASE_URL, {
    max: 1,
    onnotice: () => {},
  });
  for (const [name, a] of Object.entries(who)) {
    const addr = Buffer.from(a.address.slice(2).toLowerCase(), "hex");
    await sql`insert into app.account (address, email, email_verified_at, telegram_chat_id)
              values (${addr}, ${`${name}@scenario-a.test`}, now(), ${`tg-${name}`})
              on conflict (address) do update set email = excluded.email, email_verified_at = now(), telegram_chat_id = excluded.telegram_chat_id`;
  }
  await sql.end();
}
writeFileSync(
  resolve(OUT, "actors.json"),
  JSON.stringify(
    Object.fromEntries(Object.entries(who).map(([k, a]) => [k, a.address])),
    null,
    1,
  ),
);
console.log(
  `seeded: ${Object.keys(who).length} actors → ${resolve(OUT, "actors.json")}`,
);
