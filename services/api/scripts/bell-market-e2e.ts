// Acceptance 4, market level (make api-bell-e2e, after DeployCoreLocal on the devnode): 100 positions on
// the devnode's equity markets, then for each one GET /v1/positions/:marketId/:owner/bell and compare, at
// the block the API reports:
//   status, cure repay, cure collateral == CredenceMarket.bellStatus(id, owner)
//   premium, E[L], ES                   == engine.quoteCover(asset, type, days, C, D_proj, uAfter)
// (the local stand-in pool quotes a fixed COVER_PREMIUM, so the premium's on-chain reference is the
// engine quote with the pool's uAfter, the formula the S3 pool uses).
//
// Env: API (default http://127.0.0.1:18798), RPC_URL, SETUP=1 to create the positions (idempotent per
// account/market), N (default 100).
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, http, keccak256, parseAbi, stringToHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ICredenceMarketAbi, IRiskEngineAbi, IUnderwriterPoolAbi, IAssetClockAbi } from "@credence/sdk";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8547";
const API = process.env.API ?? "http://127.0.0.1:18798";
const N = Number(process.env.N ?? 100);
const DEV = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659" as const; // public nitro dev key
const SIGNERS = ["0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"] as const;
const PRICES: Record<string, bigint> = { NVDA: 180n, AAPL: 340n, TSLA: 372n, COIN: 195n, MSFT: 516n, SPY: 771n };
const WAD = 10n ** 18n;

const root = resolve(import.meta.dirname, "../../..");
const book = JSON.parse(readFileSync(resolve(root, "deployments/412346.local.json"), "utf8"));
if (!book.equity?.market) throw new Error("no equity stack in deployments/412346.local.json: run BE-chain's DeployCoreLocal on the devnode first");
const market = book.equity.market as Address;
const tickers = Object.keys(book.equity.markets as Record<string, Hex>).filter((t) => PRICES[t]);
const pub = createPublicClient({ transport: http(RPC) });
const dev = createWalletClient({ account: privateKeyToAccount(DEV), transport: http(RPC) });
const ERC20 = parseAbi(["function mint(address,uint256)", "function approve(address,uint256) returns (bool)", "function decimals() view returns (uint8)"]);
const FEED = parseAbi([
  "struct Report { bytes32 assetId; uint8 kind; uint128 price; uint40 observedAt; uint40 sessionDate; uint8 marketStatus; uint64 seq; }",
  "function latestSeq(bytes32) view returns (uint64)",
  "function hashReports(Report[] reports) view returns (bytes32)",
  "function submit(Report[] reports, bytes[] signatures)",
]);
const chain = { id: await pub.getChainId(), name: "devnode", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } } as const;

type Call = { abi: readonly unknown[]; address: Address; functionName: string; args: readonly unknown[] };
async function tx(w: { writeContract: (a: never) => Promise<Hex> }, req: Call) {
  const h = await w.writeContract({ ...req, chain } as never);
  const r = await pub.waitForTransactionReceipt({ hash: h });
  if (r.status !== "success") throw new Error(`reverted: ${String(req.functionName)}`);
}

/** Fresh LIVE prices on both feeds (factor in basis points), then poke every clock. */
async function prices(factorBps: Record<string, bigint> = {}) {
  const block = await pub.getBlock();
  const now = Number(block.timestamp);
  for (const t of tickers) {
    const asset = keccak256(stringToHex(`${t}:${t === "SPY" ? "ARCX" : "XNAS"}`));
    const assetId = (book.assetIds?.[t] as Hex | undefined) ?? asset;
    const price = (PRICES[t]! * WAD * (factorBps[t] ?? 10_000n)) / 10_000n;
    for (const feed of [book.shared.feedA, book.shared.feedB] as Address[]) {
      const seq = (await pub.readContract({ abi: FEED, address: feed, functionName: "latestSeq", args: [assetId] })) + 1n;
      const reports = [{ assetId, kind: 0, price, observedAt: now, sessionDate: Math.floor(now / 86400), marketStatus: 2, seq }];
      const digest = await pub.readContract({ abi: FEED, address: feed, functionName: "hashReports", args: [reports] });
      const signed = await Promise.all(SIGNERS.map(async (k) => ({ a: privateKeyToAccount(k).address, s: await privateKeyToAccount(k).sign({ hash: digest }) })));
      signed.sort((x, y) => (BigInt(x.a) < BigInt(y.a) ? -1 : 1));
      await tx(dev, { abi: FEED, address: feed, functionName: "submit", args: [reports, signed.map((x) => x.s)] });
    }
    await tx(dev, { abi: IAssetClockAbi, address: book.shared.clock, functionName: "poke", args: [assetId] });
  }
}

const accounts = Array.from({ length: Math.ceil(N / tickers.length) }, (_, i) => privateKeyToAccount(keccak256(stringToHex(`credence-bell-e2e:${i}`))));
const pairs = Array.from({ length: N }, (_, i) => ({ acct: accounts[Math.floor(i / tickers.length)]!, ticker: tickers[i % tickers.length]!, i }));

if (process.env.SETUP === "1") {
  await prices();
  for (const a of accounts) {
    const bal = await pub.getBalance({ address: a.address });
    if (bal < WAD / 100n) await pub.waitForTransactionReceipt({ hash: await dev.sendTransaction({ to: a.address, value: WAD / 10n, chain } as never) });
  }
  for (const { acct, ticker, i } of pairs) {
    const id = book.equity.markets[ticker] as Hex;
    const pos = await pub.readContract({ abi: ICredenceMarketAbi, address: market, functionName: "position", args: [id, acct.address] });
    if (pos.borrowShares > 0n) continue;
    const token = book.tokens[`t${ticker}`] as Address;
    const qty = BigInt(20 + ((i * 37) % 400)) * WAD; // 20 … 419 tokens
    const value = (qty * PRICES[ticker]!) / WAD; // USD
    const ltvBps = 5_000n + BigInt((i * 131) % 2_400); // 50.00% … 73.99%
    const borrow = (value * ltvBps * 1_000_000n) / 10_000n; // USDC base units
    const w = createWalletClient({ account: acct, transport: http(RPC) });
    await tx(dev, { abi: ERC20, address: token, functionName: "mint", args: [acct.address, qty] });
    await tx(w, { abi: ERC20, address: token, functionName: "approve", args: [market, qty] });
    await tx(w, { abi: ICredenceMarketAbi, address: market, functionName: "addCollateral", args: [id, acct.address, qty] });
    await tx(w, { abi: ICredenceMarketAbi, address: market, functionName: "borrow", args: [id, borrow, acct.address] });
    if (i % 10 === 9) await prices(); // keep the feeds fresh on a real-time chain
  }
  console.log(`setup: ${pairs.length} positions over ${tickers.length} markets and ${accounts.length} accounts`);
}

// Half the assets fall 10%: their positions above the safe LTV need action at the Bell.
await prices(Object.fromEntries(tickers.filter((_, k) => k % 2 === 0).map((t) => [t, 9_000n])));

const engine = book.shared.riskEngine as Address;
let checked = 0;
let needs = 0;
const fail: string[] = [];
for (const { acct, ticker } of pairs) {
  const id = book.equity.markets[ticker] as Hex;
  const res = await fetch(`${API}/v1/positions/${id}/${acct.address}/bell`);
  if (!res.ok) {
    fail.push(`${ticker} ${acct.address}: API ${res.status} ${await res.text()}`);
    continue;
  }
  const b = (await res.json()) as { block: string; status: { code: number }; cure: { repay: { raw: string }; addCollateral: string }; premium: { raw: string } | null; expectedLoss: { raw: string } | null; expectedShortfall: { raw: string } | null; collateralValue: { raw: string }; debtProjected: { raw: string }; closure: { closureType: { code: number }; days: number; closureId: string } };
  const blockNumber = BigInt(b.block);
  const [st, repay, coll, prem] = await pub.readContract({ abi: ICredenceMarketAbi, address: market, functionName: "bellStatus", args: [id, acct.address], blockNumber });
  let ok = Number(st) === b.status.code && repay.toString() === b.cure.repay.raw && coll.toString() === b.cure.addCollateral;
  if (b.status.code === 1) {
    needs++;
    const params = await pub.readContract({ abi: ICredenceMarketAbi, address: market, functionName: "marketParams", args: [id], blockNumber });
    const w = await pub.readContract({ abi: ICredenceMarketAbi, address: market, functionName: "wiring", blockNumber });
    const [, uAfter] = await pub.readContract({
      abi: IUnderwriterPoolAbi,
      address: w.pool,
      functionName: "previewCover",
      blockNumber,
      args: [{ marketId: id, assetId: params.assetId, borrower: acct.address, closureType: b.closure.closureType.code, closureDays: b.closure.days, closureId: BigInt(b.closure.closureId), epochId: 0n, collateralValue: BigInt(b.collateralValue.raw), debtProjected: BigInt(b.debtProjected.raw) }],
    });
    const [p, el, es] = await pub.readContract({ abi: IRiskEngineAbi, address: engine, functionName: "quoteCover", blockNumber, args: [params.assetId, b.closure.closureType.code, b.closure.days, BigInt(b.collateralValue.raw), BigInt(b.debtProjected.raw), uAfter] });
    ok &&= b.premium?.raw === p.toString() && b.expectedLoss?.raw === el.toString() && b.expectedShortfall?.raw === es.toString();
    void prem; // the stand-in pool's fixed quote
  }
  if (!ok) fail.push(JSON.stringify({ ticker, owner: acct.address, block: b.block, api: { status: b.status.code, repay: b.cure.repay.raw, coll: b.cure.addCollateral, premium: b.premium?.raw }, chain: { status: Number(st), repay: String(repay), coll: String(coll) } }));
  checked++;
}
console.log(`/bell vs chain: ${checked} positions checked (NEEDS_ACTION ${needs}), mismatches ${fail.length}`);
if (fail.length) {
  for (const f of fail.slice(0, 5)) console.error(f);
  process.exit(1);
}
console.log("OK: /bell == CredenceMarket.bellStatus (status, cures) and engine.quoteCover (premium, E[L], ES) for every position");
