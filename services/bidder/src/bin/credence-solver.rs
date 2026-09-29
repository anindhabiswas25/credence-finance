//! `credence-solver --config solvers.json`: the S4 test solver bot for NAV settlements (see
//! `credence_bidder::solver`). Dev chains only.

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
use credence_bidder::solver::{solver_bid, SolverConfig, SolverProfile, Window};
use credence_common::{env, is_dev_chain, telemetry};

sol! {
    #[sol(rpc)]
    interface ISolverAuctionV3 {
        struct SolverLot {
            address token;
            uint128 qty;
            uint128 floorPrice;
            uint40 endsAt;
            bool finalized;
            address best;
            uint128 bestPrice;
            uint128 escrow;
        }
        event SolverWindowOpened(uint64 indexed id, address token, uint256 qty, uint256 floorPrice, uint40 endsAt);
        function bid(uint64 settlementId, uint256 price) external;
        function lot(uint64 settlementId) external view returns (SolverLot memory);
        function minBid(uint64 settlementId) external view returns (uint256);
        function isSolver(address solver) external view returns (bool);
        function loanToken() external view returns (address);
    }

    #[sol(rpc)]
    interface IERC20 {
        function approve(address spender, uint256 value) external returns (bool);
        function allowance(address owner, address spender) external view returns (uint256);
    }

    #[sol(rpc)]
    interface IFundHold {
        function canHold(address a) external view returns (bool);
    }
}

#[derive(Parser)]
#[command(
    name = "credence-solver",
    about = "S4 test solver bot for NAV settlements (dev chains only)"
)]
struct Cli {
    #[arg(long, env = "SOLVER_CONFIG")]
    config: PathBuf,
    #[arg(long, env = "RPC_URL", default_value = "http://127.0.0.1:8547")]
    rpc: String,
    /// SolverAuction (default: the book's nav.solverAuction).
    #[arg(long, env = "SOLVER_AUCTION")]
    venue: Option<Address>,
    #[arg(long, env = "SOLVER_POLL_MS", default_value_t = 1000)]
    poll_ms: u64,
    /// Exit after this many seconds (0 = run forever).
    #[arg(long, default_value_t = 0)]
    exit_after_s: u64,
}

struct Solver {
    p: SolverProfile,
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
    telemetry::init("credence-solver");
    let cli = Cli::parse();
    let cfg: SolverConfig = serde_json::from_str(&std::fs::read_to_string(&cli.config)?)?;
    let read = ProviderBuilder::new()
        .connect_http(cli.rpc.parse()?)
        .erased();
    let chain_id = read.get_chain_id().await?;
    if !is_dev_chain(chain_id) {
        bail!("the test solver bot runs on dev chains only (chain {chain_id})");
    }
    let venue = match cli.venue {
        Some(v) => v,
        None => book_addr(chain_id, "/nav/solverAuction")?,
    };
    let va = ISolverAuctionV3::new(venue, &read);
    let loan = va.loanToken().call().await?;
    let mut solvers = Vec::new();
    for p in cfg.solvers {
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
        if p.bid {
            if !va.isSolver(addr).call().await? {
                tracing::warn!(solver = %p.name, %addr, "not allowlisted on the SolverAuction: it will not bid");
            }
            // the escrow is pulled at each bid: a dev bot approves once
            let erc = IERC20::new(loan, &w);
            if erc.allowance(addr, venue).call().await? < U256::MAX / U256::from(2u8) {
                erc.approve(venue, U256::MAX)
                    .send()
                    .await?
                    .get_receipt()
                    .await?;
            }
        }
        solvers.push(Solver { p, addr, w });
    }
    let mut known: BTreeSet<u64> = BTreeSet::new();
    let mut done: BTreeSet<u64> = BTreeSet::new();
    let mut scanned = 0u64;
    let started = std::time::Instant::now();
    tracing::info!(%venue, solvers = solvers.len(), "solver bot running");
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
                        .address(venue)
                        .event_signature(ISolverAuctionV3::SolverWindowOpened::SIGNATURE_HASH)
                        .from_block(scanned)
                        .to_block(head),
                )
                .await?
            {
                if let Ok(e) = ISolverAuctionV3::SolverWindowOpened::decode_log_data(l.data()) {
                    known.insert(e.id);
                }
            }
            scanned = head + 1;
        }
        for id in known.difference(&done.clone()).copied().collect::<Vec<_>>() {
            let lot = va.lot(id).call().await?;
            if lot.finalized || now >= lot.endsAt.to::<u64>() {
                done.insert(id);
                continue;
            }
            for s in solvers.iter().filter(|s| s.p.bid) {
                // re-read per solver: an earlier solver's bid this tick moves best and minBid
                let lot = va.lot(id).call().await?;
                let w = Window {
                    floor: U256::from(lot.floorPrice),
                    best: lot.best,
                    best_price: U256::from(lot.bestPrice),
                    ends_at: lot.endsAt.to::<u64>(),
                    finalized: lot.finalized,
                    min_bid: va.minBid(id).call().await?,
                };
                let Some(price) = solver_bid(&s.p, s.addr, &w, now) else {
                    continue;
                };
                if !IFundHold::new(lot.token, &read)
                    .canHold(s.addr)
                    .call()
                    .await
                    .unwrap_or(false)
                {
                    tracing::warn!(solver = %s.p.name, settlement = id, "the fund refuses this solver (canHold): no bid");
                    continue;
                }
                let v = ISolverAuctionV3::new(venue, &s.w);
                let call = v.bid(id, price);
                if let Err(e) = call.call().await {
                    tracing::warn!(solver = %s.p.name, settlement = id, %price, error = %e, "bid pre-check reverted: not sent");
                    continue;
                }
                match call.send().await {
                    Ok(pending) => match pending.get_receipt().await {
                        Ok(r) => {
                            tracing::info!(solver = %s.p.name, settlement = id, %price, ok = r.status(), "solver bid")
                        }
                        Err(e) => {
                            tracing::warn!(solver = %s.p.name, settlement = id, error = %e, "bid receipt")
                        }
                    },
                    Err(e) => {
                        tracing::warn!(solver = %s.p.name, settlement = id, error = %e, "bid send failed")
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(cli.poll_ms)).await;
    }
}
