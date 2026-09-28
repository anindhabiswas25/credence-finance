// Data access. The API reads Ponder's views (read-only) and owns the `app` schema (§11.2).
// Repositories are interfaces so route tests run without a database.
import postgres from "postgres";
import type { Address, Hex } from "viem";

export interface ClockRow {
  assetId: Hex;
  state: number;
  closureId: bigint;
  closureType: number | null;
  venueEpoch: bigint | null;
  refPrice: bigint | null;
  closeAt: bigint | null;
  reopenAt: bigint | null;
  openPrint: bigint | null;
  openPrintAt: bigint | null;
  openPrintFallback: boolean | null;
  updatedBlock: bigint;
  updatedAt: bigint;
}

export interface TransitionRow {
  from: number;
  to: number;
  closureId: bigint;
  ts: bigint;
  block: bigint;
}

export interface PriceRow {
  feed: string;
  seq: bigint;
  kind: number;
  price: bigint;
  observedAt: bigint;
  block: bigint;
}

export interface ClockRepo {
  clock(assetId: Hex): Promise<ClockRow | undefined>;
  transitions(assetId: Hex, limit: number): Promise<TransitionRow[]>;
  /** Latest LIVE report per feed. */
  latestLive(assetId: Hex): Promise<PriceRow[]>;
  ping(): Promise<void>;
}

export interface MarketRow {
  marketId: Hex;
  stack: string;
  marketAddress: Address;
  assetId: Hex;
  kind: number;
  loanToken: Address;
  collateralToken: Address;
  params: Record<string, unknown>;
  maxLtv: bigint;
  lt: bigint;
  supplyCap: bigint;
  borrowCap: bigint;
  totalSupplyAssets: bigint;
  totalBorrowAssets: bigint;
  totalBorrowShares: bigint;
  poolFeeAccrued: bigint;
  treasuryFeeAccrued: bigint;
  totalCollateral: bigint;
  updatedBlock: bigint;
  updatedAt: bigint;
}

export interface PositionRow {
  marketId: Hex;
  owner: Address;
  collateral: bigint;
  borrowShares: bigint;
  debtSnapshot: bigint;
  coverClosureId: bigint;
  lastBellClosureId: bigint;
  auctionId: bigint;
  autoCoverOptOut: boolean;
  updatedBlock: bigint;
  updatedAt: bigint;
}

export interface VaultRow {
  stack: string;
  vault: Address;
  totalAssets: bigint;
  totalSupply: bigint;
  idle: bigint;
  queueLength: bigint;
  pendingRedeemShares: bigint;
  claimableAssets: bigint;
  updatedBlock: bigint;
  updatedAt: bigint;
}

export interface VaultRequestRow {
  requestId: bigint;
  owner: Address;
  shares: bigint;
  assets: bigint | null;
  status: string;
  requestedAt: bigint;
}

export interface CoreRepo {
  markets(): Promise<MarketRow[]>;
  market(id: Hex): Promise<MarketRow | undefined>;
  positionsOf(owner: Address): Promise<PositionRow[]>;
  vault(stack: string): Promise<VaultRow | undefined>;
  /** Open redeem requests (requested, not yet processed) in FIFO order. */
  openRequests(stack: string, limit: number): Promise<VaultRequestRow[]>;
}

export interface AuthRepo {
  putNonce(nonce: string, expiresAt: Date): Promise<void>;
  /** Delete and return whether an unexpired nonce existed (single use). */
  takeNonce(nonce: string, now: Date): Promise<boolean>;
  createSession(id: string, address: Address, nonce: string, expiresAt: Date): Promise<void>;
  getSession(id: string, now: Date): Promise<{ address: Address; expiresAt: Date } | undefined>;
  deleteSession(id: string): Promise<void>;
}

const hexToBuf = (h: string) => Buffer.from(h.slice(2), "hex");
const bufToHex = (b: Buffer | Uint8Array | string): Hex =>
  typeof b === "string" ? (b as Hex) : (`0x${Buffer.from(b).toString("hex")}` as Hex);
const big = (v: unknown): bigint | null => (v === null || v === undefined ? null : BigInt(v as string));

export function pgRepos(databaseUrl: string, indexerSchema: string) {
  const sql = postgres(databaseUrl, { max: 10, idle_timeout: 30, types: { bigint: postgres.BigInt } });
  const ix = (t: string) => sql(`${indexerSchema}.${t}`);

  const clock: ClockRepo = {
    async clock(assetId) {
      const [r] = await sql`select * from ${ix("clock_state")} where asset_id = ${assetId}`;
      if (!r) return undefined;
      return {
        assetId: bufToHex(r.asset_id),
        state: Number(r.state),
        closureId: BigInt(r.closure_id),
        closureType: r.closure_type === null ? null : Number(r.closure_type),
        venueEpoch: big(r.venue_epoch),
        refPrice: big(r.ref_price),
        closeAt: big(r.close_at),
        reopenAt: big(r.reopen_at),
        openPrint: big(r.open_print),
        openPrintAt: big(r.open_print_at),
        openPrintFallback: r.open_print_fallback ?? null,
        updatedBlock: BigInt(r.updated_block),
        updatedAt: BigInt(r.updated_at),
      };
    },
    async transitions(assetId, limit) {
      const rows = await sql`select "from", "to", closure_id, ts, block from ${ix("clock_transition")}
                             where asset_id = ${assetId} order by ts desc, block desc limit ${limit}`;
      return rows.map((r) => ({ from: Number(r.from), to: Number(r.to), closureId: BigInt(r.closure_id), ts: BigInt(r.ts), block: BigInt(r.block) }));
    },
    async latestLive(assetId) {
      const rows = await sql`select distinct on (feed) feed, seq, kind, price, observed_at, block from ${ix("price_point")}
                             where asset_id = ${assetId} and kind = 0 order by feed, observed_at desc, seq desc`;
      return rows.map((r) => ({
        feed: String(r.feed),
        seq: BigInt(r.seq),
        kind: Number(r.kind),
        price: BigInt(r.price),
        observedAt: BigInt(r.observed_at),
        block: BigInt(r.block),
      }));
    },
    async ping() {
      await sql`select 1`;
    },
  };

  const auth: AuthRepo = {
    async putNonce(nonce, expiresAt) {
      await sql`insert into app.siwe_nonce (nonce, expires_at) values (${nonce}, ${expiresAt})`;
    },
    async takeNonce(nonce, now) {
      const rows = await sql`delete from app.siwe_nonce where nonce = ${nonce} returning expires_at`;
      await sql`delete from app.siwe_nonce where expires_at < ${now}`;
      return rows.length === 1 && new Date(rows[0]!.expires_at) > now;
    },
    async createSession(id, address, nonce, expiresAt) {
      const a = hexToBuf(address);
      await sql.begin(async (tx) => {
        await tx`insert into app.account (address) values (${a}) on conflict (address) do nothing`;
        await tx`insert into app.siwe_session (id, address, nonce, expires_at) values (${id}, ${a}, ${nonce}, ${expiresAt})`;
      });
    },
    async getSession(id, now) {
      const [r] = await sql`select address, expires_at from app.siwe_session where id = ${id} and expires_at > ${now}`;
      return r ? { address: bufToHex(r.address) as Address, expiresAt: new Date(r.expires_at) } : undefined;
    },
    async deleteSession(id) {
      await sql`delete from app.siwe_session where id = ${id}`;
    },
  };

  const hx = (v: unknown) => bufToHex(v as Buffer) as Hex;
  const toMarket = (r: postgres.Row): MarketRow => ({
    marketId: hx(r.market_id),
    stack: String(r.stack),
    marketAddress: hx(r.market_address) as Address,
    assetId: hx(r.asset_id),
    kind: Number(r.kind),
    loanToken: hx(r.loan_token) as Address,
    collateralToken: hx(r.collateral_token) as Address,
    params: r.params as Record<string, unknown>,
    maxLtv: BigInt(r.max_ltv),
    lt: BigInt(r.lt),
    supplyCap: BigInt(r.supply_cap),
    borrowCap: BigInt(r.borrow_cap),
    totalSupplyAssets: BigInt(r.total_supply_assets),
    totalBorrowAssets: BigInt(r.total_borrow_assets),
    totalBorrowShares: BigInt(r.total_borrow_shares),
    poolFeeAccrued: BigInt(r.pool_fee_accrued),
    treasuryFeeAccrued: BigInt(r.treasury_fee_accrued),
    totalCollateral: BigInt(r.total_collateral),
    updatedBlock: BigInt(r.updated_block),
    updatedAt: BigInt(r.updated_at),
  });
  const core: CoreRepo = {
    async markets() {
      return (await sql`select * from ${ix("market")} order by created_block, market_id`).map(toMarket);
    },
    async market(id) {
      const [r] = await sql`select * from ${ix("market")} where market_id = ${id}`;
      return r ? toMarket(r) : undefined;
    },
    async positionsOf(owner) {
      const rows = await sql`select * from ${ix("position")} where owner = ${owner.toLowerCase()} order by market_id`;
      return rows.map((r) => ({
        marketId: hx(r.market_id),
        owner: hx(r.owner) as Address,
        collateral: BigInt(r.collateral),
        borrowShares: BigInt(r.borrow_shares),
        debtSnapshot: BigInt(r.debt_snapshot),
        coverClosureId: BigInt(r.cover_closure_id),
        lastBellClosureId: BigInt(r.last_bell_closure_id),
        auctionId: BigInt(r.auction_id),
        autoCoverOptOut: Boolean(r.auto_cover_opt_out),
        updatedBlock: BigInt(r.updated_block),
        updatedAt: BigInt(r.updated_at),
      }));
    },
    async vault(stack) {
      const [r] = await sql`select * from ${ix("vault_state")} where stack = ${stack}`;
      if (!r) return undefined;
      return {
        stack: String(r.stack),
        vault: hx(r.vault) as Address,
        totalAssets: BigInt(r.total_assets),
        totalSupply: BigInt(r.total_supply),
        idle: BigInt(r.idle),
        queueLength: BigInt(r.queue_length),
        pendingRedeemShares: BigInt(r.pending_redeem_shares),
        claimableAssets: BigInt(r.claimable_assets),
        updatedBlock: BigInt(r.updated_block),
        updatedAt: BigInt(r.updated_at),
      };
    },
    async openRequests(stack, limit) {
      const rows = await sql`select request_id, owner, shares, assets, status, requested_at from ${ix("vault_request")}
                             where stack = ${stack} and status = 'requested' order by request_id limit ${limit}`;
      return rows.map((r) => ({
        requestId: BigInt(r.request_id),
        owner: hx(r.owner) as Address,
        shares: BigInt(r.shares),
        assets: big(r.assets),
        status: String(r.status),
        requestedAt: BigInt(r.requested_at),
      }));
    },
  };

  return { clock, auth, core, sql, close: () => sql.end() };
}

/** In-memory repos (tests, and `API_MEMORY=1` demos). */
export function memoryRepos(
  seed: {
    clocks?: ClockRow[];
    transitions?: Record<string, TransitionRow[]>;
    prices?: Record<string, PriceRow[]>;
    markets?: MarketRow[];
    positions?: PositionRow[];
    vaults?: VaultRow[];
    requests?: Record<string, VaultRequestRow[]>;
  } = {},
) {
  const nonces = new Map<string, Date>();
  const sessions = new Map<string, { address: Address; expiresAt: Date }>();
  const clock: ClockRepo = {
    async clock(id) {
      return seed.clocks?.find((c) => c.assetId.toLowerCase() === id.toLowerCase());
    },
    async transitions(id, limit) {
      return (seed.transitions?.[id.toLowerCase()] ?? []).slice(0, limit);
    },
    async latestLive(id) {
      return seed.prices?.[id.toLowerCase()] ?? [];
    },
    async ping() {},
  };
  const auth: AuthRepo = {
    async putNonce(n, e) {
      nonces.set(n, e);
    },
    async takeNonce(n, now) {
      const e = nonces.get(n);
      nonces.delete(n);
      return !!e && e > now;
    },
    async createSession(id, address, _n, expiresAt) {
      sessions.set(id, { address, expiresAt });
    },
    async getSession(id, now) {
      const s = sessions.get(id);
      return s && s.expiresAt > now ? s : undefined;
    },
    async deleteSession(id) {
      sessions.delete(id);
    },
  };
  const core: CoreRepo = {
    async markets() {
      return seed.markets ?? [];
    },
    async market(id) {
      return seed.markets?.find((m) => m.marketId.toLowerCase() === id.toLowerCase());
    },
    async positionsOf(owner) {
      return (seed.positions ?? []).filter((p) => p.owner.toLowerCase() === owner.toLowerCase());
    },
    async vault(stack) {
      return seed.vaults?.find((v) => v.stack === stack);
    },
    async openRequests(stack, limit) {
      return (seed.requests?.[stack] ?? []).filter((r) => r.status === "requested").slice(0, limit);
    },
  };
  return { clock, auth, core, close: async () => {} };
}
