/**
 * Sample data for the app preview. Figures follow the worked examples in docs/Architecture.md and
 * "One week of money flow.md" (NVDA at $180, 7.33% borrow rate, 80% utilisation, a $100k pool,
 * a $20k reserve, a stressed weekend with a 71.3% safe LTV). Every page reads from here, so the
 * numbers agree across the app. Replace with API / SDK reads as the backend lands.
 */

export const wallet = { address: "0x7a3f…c21e", network: "Arbitrum Sepolia", name: "Preview wallet" };

export type MarketState = "Open" | "Extended" | "Closed" | "Reopen" | "Halted";

export type Market = {
  symbol: string;
  name: string;
  kind: "Stock" | "ETF" | "Treasury fund";
  price: number;
  state: MarketState;
  maxLtv: number;
  safeLtv: number; // for the next closure
  liqThreshold: number;
  borrowApr: number;
  utilisation: number;
  supplied: number;
  borrowed: number;
  premiumPer1k: number; // Gap Cover premium per $1,000 of debt for the next closure
  gap99: number; // 99th percentile weekend gap in the scenario set, as a fraction
};

export const nextClosure = {
  label: "Weekend",
  bellWindow: "Fri 2 Oct, 14:00 ET",
  bellDeadline: "Fri 2 Oct, 15:45 ET",
  close: "Fri 2 Oct, 16:00 ET",
  reopen: "Mon 5 Oct, 09:30 ET",
  closureId: 413,
};

export const markets: Market[] = [
  { symbol: "NVDA", name: "NVIDIA", kind: "Stock", price: 180.0, state: "Open", maxLtv: 0.75, safeLtv: 0.71258, liqThreshold: 0.8, borrowApr: 0.0733, utilisation: 0.8, supplied: 260_000, borrowed: 208_000, premiumPer1k: 0.4833, gap99: 0.118 },
  { symbol: "AAPL", name: "Apple", kind: "Stock", price: 255.4, state: "Open", maxLtv: 0.75, safeLtv: 0.724, liqThreshold: 0.8, borrowApr: 0.0689, utilisation: 0.76, supplied: 180_000, borrowed: 136_800, premiumPer1k: 0.31, gap99: 0.082 },
  { symbol: "TSLA", name: "Tesla", kind: "Stock", price: 364.0, state: "Open", maxLtv: 0.75, safeLtv: 0.692, liqThreshold: 0.8, borrowApr: 0.0752, utilisation: 0.82, supplied: 150_000, borrowed: 123_000, premiumPer1k: 0.72, gap99: 0.151 },
  { symbol: "COIN", name: "Coinbase", kind: "Stock", price: 300.0, state: "Open", maxLtv: 0.75, safeLtv: 0.681, liqThreshold: 0.8, borrowApr: 0.0771, utilisation: 0.83, supplied: 120_000, borrowed: 99_600, premiumPer1k: 0.97, gap99: 0.174 },
  { symbol: "MSFT", name: "Microsoft", kind: "Stock", price: 510.2, state: "Open", maxLtv: 0.75, safeLtv: 0.731, liqThreshold: 0.8, borrowApr: 0.0664, utilisation: 0.74, supplied: 140_000, borrowed: 103_600, premiumPer1k: 0.26, gap99: 0.071 },
  { symbol: "SPY", name: "S&P 500 ETF", kind: "ETF", price: 600.0, state: "Open", maxLtv: 0.8, safeLtv: 0.776, liqThreshold: 0.85, borrowApr: 0.0612, utilisation: 0.72, supplied: 110_000, borrowed: 79_200, premiumPer1k: 0.14, gap99: 0.043 },
  { symbol: "BENJI", name: "Franklin OnChain US Gov. Money Fund", kind: "Treasury fund", price: 1.0, state: "Open", maxLtv: 0.9, safeLtv: 0.9, liqThreshold: 0.93, borrowApr: 0.0541, utilisation: 0.61, supplied: 25_000, borrowed: 15_250, premiumPer1k: 0, gap99: 0.001 },
  { symbol: "USTBL", name: "Spiko US T-Bills Money Market Fund", kind: "Treasury fund", price: 1.0, state: "Open", maxLtv: 0.9, safeLtv: 0.9, liqThreshold: 0.93, borrowApr: 0.0538, utilisation: 0.58, supplied: 15_000, borrowed: 8_700, premiumPer1k: 0, gap99: 0.001 },
];

export const marketBySymbol = Object.fromEntries(markets.map((m) => [m.symbol, m])) as Record<string, Market>;

export type Position = {
  symbol: string;
  tokens: number;
  debt: number;
  cover: "Covered" | "Not covered";
};

/** The preview wallet's loans. */
export const positions: Position[] = [
  { symbol: "NVDA", tokens: 100, debt: 13_511.58, cover: "Not covered" },
  { symbol: "COIN", tokens: 100, debt: 15_000, cover: "Not covered" },
];

export function positionStats(p: Position) {
  const m = marketBySymbol[p.symbol]!;
  const value = p.tokens * m.price;
  const ltv = p.debt / value;
  const hf = (value * m.liqThreshold) / p.debt;
  const needsBell = ltv > m.safeLtv;
  const repayToSafe = Math.max(0, p.debt - value * m.safeLtv);
  const addToSafe = Math.max(0, p.debt / m.safeLtv / m.price - p.tokens);
  const coverPremium = (p.debt / 1000) * m.premiumPer1k;
  return { market: m, value, ltv, hf, needsBell, repayToSafe, addToSafe, coverPremium };
}

export const seniorVault = {
  tvl: 1_000_000,
  borrowed: 800_000,
  idle: 200_000,
  sharePrice: 1.0284,
  apy: 0.0733 * 0.8 * 0.8, // borrow rate x utilisation x senior share
  userShares: 24_310.4,
  pool: 100_000,
  reserve: 20_000,
  sharePriceWeek: [1.0271, 1.0273, 1.0275, 1.0277, 1.0279, 1.0282, 1.0284],
};

export const underwriterPool = {
  tvl: 100_000,
  sharePrice: 1.0021,
  userShares: 20_000,
  epoch: 413,
  epochState: "Open until Fri 2 Oct, 14:00 ET (Bell window)",
  coveredPositions: 23,
  premiumsThisEpoch: 297.42,
  worstReplayedLoss: 41_300,
  capacityCap: 0.5,
  apr: 0.112,
  withdrawal: null as null | { shares: number; payableAfter: string },
  /** Share price after each epoch, #407..#412, compounded from the epoch results below. */
  sharePriceByEpoch: [1.0052, 1.007, 1.011, 0.997, 0.9991, 1.0021],
  epochs: [
    { id: 412, closure: "Weekend 25–28 Sep", premiums: 297.42, losses: 0, result: "+0.30%" },
    { id: 411, closure: "Weekend 18–21 Sep", premiums: 211.9, losses: 0, result: "+0.21%" },
    { id: 410, closure: "Weekend 11–14 Sep", premiums: 356.1, losses: 1_742.5, result: "−1.39%" },
    { id: 409, closure: "Labor Day 4–8 Sep", premiums: 402.8, losses: 0, result: "+0.40%" },
  ],
};

export type AuctionLot = {
  symbol: string;
  kind: "Reopen" | "Intraday";
  quantity: number;
  openPrint: number;
  reserve: number;
  clearing?: number;
  phase: "Queue" | "Commit" | "Reveal" | "Settled";
  when: string;
};

export const auctions: AuctionLot[] = [
  { symbol: "COIN", kind: "Reopen", quantity: 61.2, openPrint: 258.0, reserve: 250.26, clearing: 256.4, phase: "Settled", when: "Mon 28 Sep, 09:37 ET" },
  { symbol: "NVDA", kind: "Reopen", quantity: 18.4, openPrint: 171.2, reserve: 166.06, clearing: 170.35, phase: "Settled", when: "Mon 28 Sep, 09:37 ET" },
  { symbol: "TSLA", kind: "Intraday", quantity: 20.23, openPrint: 364.0, reserve: 353.08, clearing: 362.18, phase: "Settled", when: "Thu 24 Sep, 13:01 ET" },
  { symbol: "MSFT", kind: "Intraday", quantity: 4.1, openPrint: 508.9, reserve: 493.63, clearing: 507.2, phase: "Settled", when: "Wed 23 Sep, 11:14 ET" },
];

export const userBids = [
  { symbol: "COIN", quantity: 12.4, price: 256.9, filled: 12.4, paid: 12.4 * 256.4, status: "Filled at $256.40" },
  { symbol: "NVDA", quantity: 5, price: 164.0, filled: 0, paid: 0, status: "Below reserve, refunded" },
];

export type Activity = { icon: string; title: string; when: string; amount: string };

export const activity: Activity[] = [
  { icon: "shield", title: "Gap Cover bought", when: "25 Sep 2026, 14:12", amount: "$6.53" },
  { icon: "cash", title: "Borrowed USDC", when: "21 Sep 2026, 10:00", amount: "$13,500" },
  { icon: "deposit", title: "Deposited NVDA", when: "21 Sep 2026, 09:58", amount: "100 NVDA" },
  { icon: "percent", title: "Interest accrued", when: "20 Sep 2026, 00:00", amount: "$2.71" },
  { icon: "repay", title: "Repaid", when: "15 Sep 2026, 16:20", amount: "$500.00" },
];

export const lendActivity: Activity[] = [
  { icon: "percent", title: "Senior interest", when: "28 Sep 2026, 00:00", amount: "+$3.21" },
  { icon: "percent", title: "Senior interest", when: "27 Sep 2026, 00:00", amount: "+$3.20" },
  { icon: "deposit", title: "Deposited USDC", when: "14 Sep 2026, 11:05", amount: "$15,000" },
  { icon: "deposit", title: "Deposited USDC", when: "2 Sep 2026, 09:41", amount: "$10,000" },
];

export const underwriteActivity: Activity[] = [
  { icon: "shield", title: "Epoch 412 settled", when: "28 Sep 2026, 09:37", amount: "+$59.48" },
  { icon: "percent", title: "Risk fee accrued", when: "27 Sep 2026, 00:00", amount: "+$0.32" },
  { icon: "shield", title: "Epoch 411 settled", when: "21 Sep 2026, 09:36", amount: "+$42.38" },
  { icon: "deposit", title: "Deposited USDC", when: "9 Sep 2026, 15:20", amount: "$20,000" },
];

export type Alert = { id: number; icon: string; title: string; body: string; when: string; unread?: boolean };

export const alerts: Alert[] = [
  { id: 1, icon: "bell", title: "Bell check coming for NVDA", body: "Your NVDA loan is at 75.1% LTV; the weekend-safe LTV is 71.3%. Repay $685, add 5.3 NVDA, or buy Gap Cover for $6.53 before Fri 15:45 ET. If you do nothing, auto-cover buys it for you.", when: "Today, 09:31", unread: true },
  { id: 2, icon: "clock", title: "Weekend closure scheduled", body: "Markets close Fri 2 Oct at 16:00 ET and reopen Mon 5 Oct at 09:30 ET. The Bell window opens Fri at 14:00 ET.", when: "Today, 09:30", unread: true },
  { id: 3, icon: "gavel", title: "Reopen auction settled", body: "Your COIN bid filled: 12.4 COIN at $256.40, the uniform clearing price.", when: "Mon 28 Sep, 09:37" },
  { id: 4, icon: "shield", title: "Epoch 412 settled", body: "Premiums, risk fees and penalties were credited. Pool share price is now $1.0021.", when: "Mon 28 Sep, 09:37" },
  { id: 5, icon: "alert", title: "Stress flag on COIN", body: "COIN's weekend DEX price fell 14%, so new borrowing against COIN was paused until the reopen. Repay and add collateral stayed open.", when: "Sat 26 Sep, 11:02" },
];

/** A week of health-factor readings for the NVDA loan (Sun..Sat). */
export const hfWeek = [1.26, 1.18, 1.33, 1.13, 1.2, 1.11, 1.07];
export const weekDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
