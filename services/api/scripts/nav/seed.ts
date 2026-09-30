// make nav-settlement-e2e (S4 G, PM ruling 2026-09-30: positions seeded near LT, ≤ 30 min): the last manual
// transactions before the keeper-only run. As the deployer (timelock, issuer and registry operator on local
// chains):
//   * the settlement window at its 5-min minimum (launch: 15 min);
//   * actors: Nia and Omar (TBILL borrowers), the solver (allowlisted on the venue, compliance-allowed to hold
//     tTBILL, 1M USDC), the keeper; 1 ETH each;
//   * NAV 1.0 on the feed and the fund; Nia borrows at 89.9 % (the max LTV; LT 93 %, HF 1.0345), Omar at 88 %
//     (HF 1.0568): 8 strikes of −0.45 % take Nia under HF 1, 5 more take Omar under (one step > 0.5 % HALTs);
//   * notification accounts (verified email + Telegram) for both borrowers.
// Writes actors.json to SCENARIO_DIR.
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import postgres from "postgres";
import { parseAbi, parseEther, type Address } from "viem";
import { ICredenceMarketAbi } from "@credence/sdk";
import {
  OUT,
  actor,
  book,
  dev,
  pub,
  send,
  wallet,
  Erc20,
} from "../scenario-a/lib.ts";
import { strike } from "./strike.ts";

const Admin = parseAbi([
  "function setWindow(uint40)",
  "function setSolver(address,bool)",
  "function setAllowedBatch(address[] accounts, bool allowed)",
]);
const nid = book.nav.markets.TBILL as `0x${string}`;
const market = book.nav.market as Address;
const fund = book.tokens.tTBILL as Address;
const usdc = book.tokens.usdc as Address;
const WAD = 10n ** 18n;
const QTY = 100_000n * WAD;

const who = {
  nia: actor("nia"),
  omar: actor("omar"),
  solver: actor("solver"),
  keeper: actor("keeper"),
};
for (const a of Object.values(who)) {
  const h = await dev.sendTransaction({
    to: a.address,
    value: parseEther("1"),
  });
  await pub.waitForTransactionReceipt({ hash: h });
}
await send(dev, {
  abi: Admin,
  address: book.nav.settlement,
  functionName: "setWindow",
  args: [300],
});
await send(dev, {
  abi: Admin,
  address: book.shared.registry,
  functionName: "setAllowedBatch",
  args: [[who.nia.address, who.omar.address, who.solver.address], true],
});
await send(dev, {
  abi: Admin,
  address: book.nav.solverAuction,
  functionName: "setSolver",
  args: [who.solver.address, true],
});
await send(dev, {
  abi: Erc20,
  address: usdc,
  functionName: "mint",
  args: [who.solver.address, 1_000_000n * 10n ** 6n],
});

await strike({ price: "1" });

async function borrower(a: typeof who.nia, debt: bigint) {
  const w = wallet(a);
  await send(dev, {
    abi: Erc20,
    address: fund,
    functionName: "mint",
    args: [a.address, QTY],
  });
  await send(w, {
    abi: Erc20,
    address: fund,
    functionName: "approve",
    args: [market, QTY],
  });
  await send(w, {
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "addCollateral",
    args: [nid, a.address, QTY],
  });
  await send(w, {
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "borrow",
    args: [nid, debt, a.address],
  });
  const hf = (await pub.readContract({
    abi: ICredenceMarketAbi,
    address: market,
    functionName: "healthFactor",
    args: [nid, a.address],
  })) as bigint;
  console.log(
    `seeded ${a.address}: 100,000 tTBILL, debt ${Number(debt) / 1e6} USDC, HF ${Number(hf) / 1e18}`,
  );
}
await borrower(who.nia, 89_900n * 10n ** 6n);
await borrower(who.omar, 88_000n * 10n ** 6n);

const sql = postgres(process.env.DATABASE_URL!, { max: 1, onnotice: () => {} });
for (const [n, a] of [
  ["nia", who.nia],
  ["omar", who.omar],
] as const) {
  const addr = Buffer.from(a.address.slice(2).toLowerCase(), "hex");
  await sql`insert into app.account (address, email, email_verified_at, telegram_chat_id)
            values (${addr}, ${`${n}@example.com`}, now(), ${`nav-${n}`})
            on conflict (address) do update set email = excluded.email, email_verified_at = now(), telegram_chat_id = excluded.telegram_chat_id`;
}
await sql.end();
writeFileSync(
  resolve(OUT, "actors.json"),
  JSON.stringify(
    Object.fromEntries(Object.entries(who).map(([k, a]) => [k, a.address])),
    null,
    1,
  ),
);
console.log(`actors → ${resolve(OUT, "actors.json")}`);
