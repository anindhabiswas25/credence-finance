//! `credence-bidder --config bidders.json`: the S3 test bidder bot (see the crate docs). Dev chains only.

use std::{collections::BTreeSet, path::PathBuf, time::Duration};

use alloy::{
    eips::BlockNumberOrTag,
    network::EthereumWallet,
    primitives::{Address, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::Filter,
    signers::local::PrivateKeySigner,
    sol,
    sol_types::SolEvent,
};
use anyhow::{bail, Context, Result};
use clap::Parser;
use credence_bidder::{
    commitment, decide, kind_name, notional, size, Action, BidState, Book, Config, Profile,
};
use credence_bindings::{CredenceMarket, IAuctionHouse};
use credence_common::{env, is_dev_chain, telemetry};

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function approve(address spender, uint256 value) external returns (bool);
        function allowance(address owner, address spender) external view returns (uint256);
        function decimals() external view returns (uint8);
    }
    #[sol(rpc)]
    interface ICompliance {
        function canHold(address account) external view returns (bool);
    }
}

#[derive(Parser)]
#[command(
    name = "credence-bidder",
    about = "S3 test bidder bot (dev chains only)"
)]
struct Cli {
    #[arg(long, env = "BIDDER_CONFIG")]
    config: PathBuf,
    /// Persisted salts and progress.
    #[arg(long, env = "BIDDER_STATE", default_value = "target/bidder-state.json")]
    state: PathBuf,
    #[arg(long, env = "RPC_URL", default_value = "http://127.0.0.1:8547")]
    rpc: String,
    /// Auction house (default: the book's equity.auctionHouse).
    #[arg(long, env = "AUCTION_HOUSE")]
    house: Option<Address>,
    /// Market (default: the book's equity.market).
    #[arg(long, env = "MARKET_ADDRESS")]
    market: Option<Address>,
    #[arg(long, env = "BIDDER_POLL_MS", default_value_t = 1000)]
    poll_ms: u64,
    /// Exit after this many seconds (0 = run forever).
    #[arg(long, default_value_t = 0)]
    exit_after_s: u64,
}

struct Bidder {
    p: Profile,
    addr: Address,
    w: DynProvider,
}

fn book_addr(chain_id: u64, pointer: &str) -> Result<Address> {
    let path = env::optional("DEPLOYMENTS_FILE")
        .unwrap_or_else(|| format!("deployments/{chain_id}.local.json"));
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).with_context(|| path.clone())?)?;
    v.pointer(pointer)
        .and_then(|x| x.as_str())
        .with_context(|| format!("{pointer} in {path}"))?
        .parse()
        .context(pointer.to_owned())
}

#[tokio::main]
async fn main() -> Result<()> {
    env::load_dotenv();
    telemetry::init("credence-bidder");
    let cli = Cli::parse();
    let cfg: Config = serde_json::from_str(&std::fs::read_to_string(&cli.config)?)?;
    let read = ProviderBuilder::new()
        .connect_http(cli.rpc.parse()?)
        .erased();
    let chain_id = read.get_chain_id().await?;
    if !is_dev_chain(chain_id) {
        bail!("the test bidder bot runs on dev chains only (chain {chain_id})");
    }
    let house = match cli.house {
        Some(h) => h,
        None => book_addr(chain_id, "/equity/auctionHouse")?,
    };
    let market = match cli.market {
        Some(m) => m,
        None => book_addr(chain_id, "/equity/market")?,
    };
    let mut bidders = Vec::new();
    for p in cfg.bidders {
        let s: PrivateKeySigner = p
            .key
            .parse()
            .with_context(|| format!("key of {}", p.name))?;
        let addr = s.address();
        let w = ProviderBuilder::new()
            .with_simple_nonce_management()
            .wallet(EthereumWallet::from(s))
            .connect_http(cli.rpc.parse()?)
            .erased();
        bidders.push(Bidder { p, addr, w });
    }
    let mut book: Book = std::fs::read_to_string(&cli.state)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let ah = IAuctionHouse::new(house, &read);
    let mk = CredenceMarket::new(market, &read);
    let mut known: BTreeSet<u64> = BTreeSet::new();
    let mut done: BTreeSet<u64> = BTreeSet::new();
    let mut scanned = 0u64;
    let started = std::time::Instant::now();
    tracing::info!(%house, %market, bidders = bidders.len(), "bidder bot running");
    loop {
        if cli.exit_after_s > 0 && started.elapsed() > Duration::from_secs(cli.exit_after_s) {
            return Ok(());
        }
        let blk = read
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await?
            .context("latest block")?;
        let (head, now) = (blk.header.number, blk.header.timestamp);
        if head >= scanned {
            for l in read
                .get_logs(
                    &Filter::new()
                        .address(house)
                        .event_signature(IAuctionHouse::AuctionCreated::SIGNATURE_HASH)
                        .from_block(scanned)
                        .to_block(head),
                )
                .await?
            {
                if let Ok(e) = IAuctionHouse::AuctionCreated::decode_log_data(l.data()) {
                    known.insert(e.id);
                }
            }
            scanned = head + 1;
        }
        for id in known.difference(&done.clone()).copied().collect::<Vec<_>>() {
            let a = ah.auction(id).call().await?;
            let deadlines = a.deadlines.map(|d| d.to::<u64>());
            let fixed = a.lot > 0 && a.reserve > 0;
            let params = mk.marketParams(a.marketId).call().await?;
            let loan = IERC20::new(params.loanToken, &read);
            let (coll_dec, loan_dec) = (
                IERC20::new(params.collateralToken, &read)
                    .decimals()
                    .call()
                    .await?,
                loan.decimals().call().await?,
            );
            let mut all_claimed = a.phase == credence_bidder::CLEARED;
            for b in &bidders {
                let k = Book::key(b.addr, house, id);
                let st = book.bids.get(&k).cloned().unwrap_or_default();
                let Some(action) = decide(&b.p, a.kind, a.phase, fixed, deadlines, now, &st) else {
                    continue;
                };
                all_claimed = false;
                let r = act(
                    b,
                    &b.w,
                    house,
                    chain_id,
                    id,
                    &a,
                    params.loanToken,
                    params.collateralToken,
                    coll_dec,
                    loan_dec,
                    action,
                    st.clone(),
                )
                .await;
                match r {
                    Ok(Some(next)) => {
                        tracing::info!(bidder = %b.p.name, auction = id, kind = kind_name(a.kind), ?action, qty = next.qty, price = next.price, "bid step");
                        book.bids.insert(k, next);
                        std::fs::write(&cli.state, serde_json::to_string_pretty(&book)?)?;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        tracing::warn!(bidder = %b.p.name, auction = id, ?action, error = %format!("{e:#}"), "bid step failed")
                    }
                }
            }
            if all_claimed {
                done.insert(id);
            }
        }
        tokio::time::sleep(Duration::from_millis(cli.poll_ms)).await;
    }
}

#[allow(clippy::too_many_arguments)]
async fn act(
    b: &Bidder,
    w: &DynProvider,
    house: Address,
    chain_id: u64,
    id: u64,
    a: &IAuctionHouse::Auction,
    loan_token: Address,
    coll_token: Address,
    coll_dec: u8,
    loan_dec: u8,
    action: Action,
    mut st: BidState,
) -> Result<Option<BidState>> {
    let ah = IAuctionHouse::new(house, w);
    let send = |r: alloy::rpc::types::TransactionReceipt| -> Result<()> {
        if !r.status() {
            bail!("reverted in {}", r.transaction_hash);
        }
        Ok(())
    };
    // R-02: a bidder the collateral token would not let hold it is never sent
    if matches!(action, Action::Commit | Action::Place) {
        if let Ok(false) = ICompliance::new(coll_token, w).canHold(b.addr).call().await {
            tracing::warn!(bidder = %b.p.name, "not allowed to hold the collateral (canHold = false): skipping");
            return Ok(None);
        }
    }
    let approve = |amount: U256| async move {
        let t = IERC20::new(loan_token, w);
        if t.allowance(b.addr, house).call().await? < amount {
            send(
                t.approve(house, U256::MAX)
                    .send()
                    .await?
                    .get_receipt()
                    .await?,
            )?;
        }
        anyhow::Ok(())
    };
    match action {
        Action::Commit | Action::Place => {
            let Some((qty, price)) = size(&b.p, a.lot, a.reserve) else {
                return Ok(None);
            };
            let value = notional(qty, price, coll_dec, loan_dec);
            st.qty = qty;
            st.price = price;
            if action == Action::Commit {
                let max = value * U256::from(b.p.max_notional_bps) / U256::from(10_000u64);
                let max: u128 = max.try_into().context("maxNotional")?;
                // dev tool: unpredictable enough, and persisted for the reveal
                let nanos = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)?
                    .as_nanos();
                st.salt = alloy::primitives::keccak256(format!("{}:{id}:{nanos}", b.p.key));
                let c = commitment(chain_id, house, id, b.addr, qty, price, st.salt);
                approve(U256::from(max)).await?;
                send(ah.commitBid(id, c, max).send().await?.get_receipt().await?)?;
                st.committed = true;
            } else {
                approve(value).await?;
                send(
                    ah.placeBid(id, qty, price)
                        .send()
                        .await?
                        .get_receipt()
                        .await?,
                )?;
                st.placed = true;
            }
        }
        Action::Reveal => {
            approve(notional(st.qty, st.price, coll_dec, loan_dec)).await?;
            send(
                ah.revealBid(id, st.qty, st.price, st.salt)
                    .send()
                    .await?
                    .get_receipt()
                    .await?,
            )?;
            st.revealed = true;
        }
        Action::Claim => {
            send(ah.claim(id).send().await?.get_receipt().await?)?;
            st.claimed = true;
        }
    }
    Ok(Some(st))
}
