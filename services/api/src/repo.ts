// Data access. The API reads Ponder's views (read-only) and owns the `app` schema (§11.2).
// Repositories are interfaces so route tests run without a database.
import postgres from "postgres";
import { getAddress, type Address, type Hex } from "viem";
import {
  allowlistStatus,
  type AccountView,
  type AllowlistResult,
  type MeRepo,
  type Pref,
  type PushSub,
} from "./me.ts";
import type { StreamSource } from "./stream.ts";
import { pgRiskTransferRepo } from "./rt.ts";
import { pgSettlementRepo } from "./settlement.ts";

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
  createSession(
    id: string,
    address: Address,
    nonce: string,
    expiresAt: Date,
  ): Promise<void>;
  getSession(
    id: string,
    now: Date,
  ): Promise<{ address: Address; expiresAt: Date } | undefined>;
  deleteSession(id: string): Promise<void>;
}

const hexToBuf = (h: string) => Buffer.from(h.slice(2), "hex");
const bufToHex = (b: Buffer | Uint8Array | string): Hex =>
  typeof b === "string"
    ? (b as Hex)
    : (`0x${Buffer.from(b).toString("hex")}` as Hex);
const big = (v: unknown): bigint | null =>
  v === null || v === undefined ? null : BigInt(v as string);

export function pgRepos(databaseUrl: string, indexerSchema: string) {
  const sql = postgres(databaseUrl, {
    max: 10,
    idle_timeout: 30,
    types: { bigint: postgres.BigInt },
  });
  const ix = (t: string) => sql(`${indexerSchema}.${t}`);

  const clock: ClockRepo = {
    async clock(assetId) {
      const [r] =
        await sql`select * from ${ix("clock_state")} where asset_id = ${assetId}`;
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
      const rows =
        await sql`select "from", "to", closure_id, ts, block from ${ix("clock_transition")}
                             where asset_id = ${assetId} order by ts desc, block desc limit ${limit}`;
      return rows.map((r) => ({
        from: Number(r.from),
        to: Number(r.to),
        closureId: BigInt(r.closure_id),
        ts: BigInt(r.ts),
        block: BigInt(r.block),
      }));
    },
    async latestLive(assetId) {
      const rows =
        await sql`select distinct on (feed) feed, seq, kind, price, observed_at, block from ${ix("price_point")}
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
      const rows =
        await sql`delete from app.siwe_nonce where nonce = ${nonce} returning expires_at`;
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
      const [r] =
        await sql`select address, expires_at from app.siwe_session where id = ${id} and expires_at > ${now}`;
      return r
        ? {
            address: getAddress(bufToHex(r.address)),
            expiresAt: new Date(r.expires_at),
          }
        : undefined;
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
      return (
        await sql`select * from ${ix("market")} order by created_block, market_id`
      ).map(toMarket);
    },
    async market(id) {
      const [r] =
        await sql`select * from ${ix("market")} where market_id = ${id}`;
      return r ? toMarket(r) : undefined;
    },
    async positionsOf(owner) {
      const rows =
        await sql`select * from ${ix("position")} where owner = ${owner.toLowerCase()} order by market_id`;
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
      const [r] =
        await sql`select * from ${ix("vault_state")} where stack = ${stack}`;
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
      const rows =
        await sql`select request_id, owner, shares, assets, status, requested_at from ${ix("vault_request")}
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

  const addr = (a: Address) => hexToBuf(a.toLowerCase());
  const ensure = (tx: postgres.Sql | postgres.TransactionSql, a: Address) =>
    tx`insert into app.account (address) values (${addr(a)}) on conflict (address) do nothing`;
  const me: MeRepo = {
    async account(a) {
      const [acct] =
        await sql`select email, email_verified_at, telegram_chat_id, testnet_attested_at from app.account where address = ${addr(a)}`;
      const push =
        await sql`select endpoint from app.push_subscription where address = ${addr(a)} order by id`;
      const prefs =
        await sql`select event, channel, enabled from app.notification_pref where address = ${addr(a)}`;
      const al =
        await sql`select chain_id, status, tx_hash from app.allowlist_request where address = ${addr(a)} order by chain_id`;
      const chains = al.map((r) => ({
        chainId: Number(r.chain_id),
        status: String(r.status),
        txHash: r.tx_hash ? bufToHex(r.tx_hash) : null,
      }));
      return {
        email: acct?.email ?? null,
        emailVerified: !!acct?.email_verified_at,
        telegramChatId: acct?.telegram_chat_id ?? null,
        push: push.map((r) => ({ endpoint: String(r.endpoint) })),
        prefs: prefs.map(
          (r) =>
            ({
              event: r.event,
              channel: r.channel,
              enabled: Boolean(r.enabled),
            }) as Pref,
        ),
        testnetAttestedAt: acct?.testnet_attested_at
          ? new Date(acct.testnet_attested_at)
          : null,
        allowlist: chains.length
          ? {
              status: allowlistStatus(chains.map((x) => x.status)),
              txHash: chains.length === 1 ? chains[0]!.txHash : null,
            }
          : null,
        allowlistChains: chains,
      } satisfies AccountView;
    },
    async setEmail(a, email, tokenHash, expiresAt) {
      return sql.begin(async (tx) => {
        await ensure(tx, a);
        const [cur] =
          await tx`select email from app.account where address = ${addr(a)} for update`;
        if ((cur?.email ?? null) === email) return false;
        await tx`update app.account set email = ${email}, email_verified_at = null where address = ${addr(a)}`;
        await tx`delete from app.email_verification where address = ${addr(a)}`;
        if (email && tokenHash) {
          await tx`insert into app.email_verification (token_hash, address, email, expires_at) values (${tokenHash}, ${addr(a)}, ${email}, ${expiresAt})`;
        }
        return true;
      });
    },
    async verifyEmail(tokenHash, now) {
      return sql.begin(async (tx) => {
        const [v] =
          await tx`delete from app.email_verification where token_hash = ${tokenHash} returning address, email, expires_at`;
        if (!v || new Date(v.expires_at) <= now) return null;
        const r =
          await tx`update app.account set email_verified_at = ${now} where address = ${v.address} and email = ${v.email} returning address`;
        return r[0] ? getAddress(bufToHex(r[0].address)) : null;
      });
    },
    async setTelegram(a, chatId) {
      await ensure(sql, a);
      await sql`update app.account set telegram_chat_id = ${chatId} where address = ${addr(a)}`;
    },
    async addPush(a, s: PushSub) {
      await ensure(sql, a);
      await sql`insert into app.push_subscription (address, endpoint, p256dh, auth) values (${addr(a)}, ${s.endpoint}, ${s.p256dh}, ${s.auth})
                on conflict (endpoint) do update set address = excluded.address, p256dh = excluded.p256dh, auth = excluded.auth`;
    },
    async removePush(a, endpoint) {
      await sql`delete from app.push_subscription where address = ${addr(a)} and endpoint = ${endpoint}`;
    },
    async setPrefs(a, prefs) {
      await ensure(sql, a);
      for (const p of prefs) {
        await sql`insert into app.notification_pref (address, event, channel, enabled) values (${addr(a)}, ${p.event}, ${p.channel}, ${p.enabled})
                  on conflict (address, event, channel) do update set enabled = excluded.enabled`;
      }
    },
    async enqueue(j) {
      await sql`insert into app.notification_job (chain_id, dedupe_key, address, event, payload) values (${j.chainId}, ${j.dedupeKey}, ${addr(j.address)}, ${j.event}, ${sql.json(j.payload as postgres.JSONValue)})
                on conflict (chain_id, dedupe_key) do nothing`;
    },
    async requestAllowlist(a, now, chainIds) {
      return sql.begin(async (tx) => {
        await ensure(tx, a);
        await tx`update app.account set testnet_attested_at = coalesce(testnet_attested_at, ${now}) where address = ${addr(a)}`;
        const chains: AllowlistResult["chains"] = [];
        for (const id of chainIds) {
          const ins =
            await tx`insert into app.allowlist_request (chain_id, address, requested_at) values (${id}, ${addr(a)}, ${now})
                     on conflict (chain_id, address) do nothing returning status`;
          if (ins[0]) {
            chains.push({
              chainId: id,
              status: String(ins[0].status),
              created: true,
            });
            continue;
          }
          const [r] =
            await tx`select status from app.allowlist_request where chain_id = ${id} and address = ${addr(a)}`;
          chains.push({
            chainId: id,
            status: String(r!.status),
            created: false,
          });
        }
        return {
          status: allowlistStatus(chains.map((x) => x.status)),
          created: chains.some((x) => x.created),
          chains,
        };
      });
    },
  };

  const stream: StreamSource = {
    auctionsSince: async () => [],
    ownerEventsSince: async () => [],
    async head() {
      const [r] =
        await sql`select greatest((select coalesce(max(block), 0) from ${ix("clock_transition")}),
                                            (select coalesce(max(block), 0) from ${ix("price_point")})) as b`;
      return BigInt(r!.b);
    },
    async clockSince(block, limit) {
      const rows =
        await sql`select asset_id, "from", "to", closure_id, block, ts from ${ix("clock_transition")}
                             where block > ${block.toString()} order by block, id limit ${limit}`;
      return rows.map((r) => ({
        assetId: hx(r.asset_id),
        from: Number(r.from),
        to: Number(r.to),
        closureId: BigInt(r.closure_id),
        block: BigInt(r.block),
        ts: BigInt(r.ts),
      }));
    },
    async pricesSince(block, limit) {
      const rows =
        await sql`select asset_id, feed, seq, kind, price, observed_at, status, block from ${ix("price_point")}
                             where block > ${block.toString()} order by block, feed, seq limit ${limit}`;
      return rows.map((r) => ({
        assetId: hx(r.asset_id),
        feed: String(r.feed),
        seq: BigInt(r.seq),
        kind: Number(r.kind),
        price: BigInt(r.price),
        observedAt: BigInt(r.observed_at),
        status: r.status === null ? null : Number(r.status),
        block: BigInt(r.block),
      }));
    },
  };

  stream.auctionsSince = async (block, limit) => {
    const rows =
      await sql`select * from ${ix("auction")} where updated_block > ${block.toString()} order by updated_block, auction_id limit ${limit}`;
    return rows.map((r) => ({
      auctionId: BigInt(r.auction_id),
      kind: Number(r.kind),
      assetId: hx(r.asset_id),
      marketId: hx(r.market_id),
      closureId: BigInt(r.closure_id),
      tranche: Number(r.tranche),
      status: String(r.status),
      deadlines: (r.deadlines as (string | number)[]).map(Number),
      lot: big(r.lot),
      reserve: big(r.reserve),
      bids: Number(r.bids),
      pStar: big(r.p_star),
      qPool: big(r.q_pool),
      proceeds: big(r.proceeds),
      block: BigInt(r.updated_block),
    }));
  };
  stream.ownerEventsSince = async (block, limit) => {
    const rows =
      await sql`select owner, market_id, kind, amounts, clock_state, block, ts, tx_hash from ${ix("position_event")}
                           where block > ${block.toString()} order by block, id limit ${limit}`;
    return rows.map((r) => ({
      owner: hx(r.owner),
      marketId: r.market_id ? hx(r.market_id) : null,
      kind: String(r.kind),
      amounts: r.amounts,
      clockState: r.clock_state === null ? null : Number(r.clock_state),
      block: BigInt(r.block),
      ts: BigInt(r.ts),
      txHash: hx(r.tx_hash),
    }));
  };
  const rt = pgRiskTransferRepo(sql, ix);
  const settlement = pgSettlementRepo(sql, ix);
  return {
    clock,
    auth,
    core,
    me,
    rt,
    settlement,
    stream,
    sql,
    close: () => sql.end(),
  };
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
      return seed.clocks?.find(
        (c) => c.assetId.toLowerCase() === id.toLowerCase(),
      );
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
      return seed.markets?.find(
        (m) => m.marketId.toLowerCase() === id.toLowerCase(),
      );
    },
    async positionsOf(owner) {
      return (seed.positions ?? []).filter(
        (p) => p.owner.toLowerCase() === owner.toLowerCase(),
      );
    },
    async vault(stack) {
      return seed.vaults?.find((v) => v.stack === stack);
    },
    async openRequests(stack, limit) {
      return (seed.requests?.[stack] ?? [])
        .filter((r) => r.status === "requested")
        .slice(0, limit);
    },
  };
  const accounts = new Map<
    string,
    {
      email: string | null;
      verified: boolean;
      telegram: string | null;
      push: Map<string, PushSub>;
      prefs: Pref[];
      attested: Date | null;
      allowlist: Map<number, string>;
    }
  >();
  const acct = (a: Address) => {
    const k = a.toLowerCase();
    let x = accounts.get(k);
    if (!x)
      accounts.set(
        k,
        (x = {
          email: null,
          verified: false,
          telegram: null,
          push: new Map(),
          prefs: [],
          attested: null,
          allowlist: new Map(),
        }),
      );
    return x;
  };
  const tokens = new Map<
    string,
    { address: Address; email: string; expiresAt: Date }
  >();
  const jobs: {
    chainId: number;
    dedupeKey: string;
    address: Address;
    event: string;
    payload: object;
  }[] = [];
  const me: MeRepo = {
    async account(a) {
      const x = acct(a);
      return {
        email: x.email,
        emailVerified: x.verified,
        telegramChatId: x.telegram,
        push: [...x.push.keys()].map((endpoint) => ({ endpoint })),
        prefs: x.prefs,
        testnetAttestedAt: x.attested,
        allowlist: x.allowlist.size
          ? { status: allowlistStatus([...x.allowlist.values()]), txHash: null }
          : null,
        allowlistChains: [...x.allowlist].map(([chainId, status]) => ({
          chainId,
          status,
          txHash: null,
        })),
      };
    },
    async setEmail(a, email, tokenHash, expiresAt) {
      const x = acct(a);
      if (x.email === email) return false;
      x.email = email;
      x.verified = false;
      for (const [k, v] of tokens)
        if (v.address.toLowerCase() === a.toLowerCase()) tokens.delete(k);
      if (email && tokenHash)
        tokens.set(tokenHash.toString("hex"), { address: a, email, expiresAt });
      return true;
    },
    async verifyEmail(tokenHash, now) {
      const v = tokens.get(tokenHash.toString("hex"));
      tokens.delete(tokenHash.toString("hex"));
      if (!v || v.expiresAt <= now) return null;
      const x = acct(v.address);
      if (x.email !== v.email) return null;
      x.verified = true;
      return v.address;
    },
    async setTelegram(a, chatId) {
      acct(a).telegram = chatId;
    },
    async addPush(a, s) {
      acct(a).push.set(s.endpoint, s);
    },
    async removePush(a, endpoint) {
      acct(a).push.delete(endpoint);
    },
    async setPrefs(a, prefs) {
      const x = acct(a);
      for (const p of prefs)
        x.prefs = [
          ...x.prefs.filter(
            (q) => !(q.event === p.event && q.channel === p.channel),
          ),
          p,
        ];
    },
    async enqueue(j) {
      if (
        !jobs.some(
          (x) => x.chainId === j.chainId && x.dedupeKey === j.dedupeKey,
        )
      )
        jobs.push(j);
    },
    async requestAllowlist(a, now, chainIds) {
      const x = acct(a);
      x.attested ??= now;
      const chains = chainIds.map((chainId) => {
        const had = x.allowlist.get(chainId);
        if (!had) x.allowlist.set(chainId, "pending");
        return { chainId, status: had ?? "pending", created: !had };
      });
      return {
        status: allowlistStatus(chains.map((c) => c.status)),
        created: chains.some((c) => c.created),
        chains,
      };
    },
  };
  return { clock, auth, core, me, jobs, close: async () => {} };
}
