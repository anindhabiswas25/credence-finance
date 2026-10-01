//! `credence-solver --config solvers.json`: the S4 test solver bot for NAV settlements (see
//! `credence_bidder::solver`). Plain keys on dev chains only; on a testnet each solver's key is an encrypted
//! keystore (or KMS) per chain and role (`solver-<name>`, ADR-0014).

use std::{collections::BTreeSet, path::PathBuf, time::Duration};

use alloy::{
    eips::BlockNumberOrTag,
    primitives::{Address, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::Filter,
    sol,
    sol_types::SolEvent,
};
use anyhow::{Context, Result};
use clap::Parser;
use credence_bidder::solver::{solver_bid, SolverConfig, SolverProfile, Window};
use credence_bindings::ISolverAuction as ISolverAuctionV3;
use credence_common::{
    env,
    signer::{CredenceSigner, SignerConfig},
    telemetry,
};

sol! {
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
    about = "S4 test solver bot for NAV settlements (plain keys on dev chains only)"
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
    // /healthz + /readyz (Railway-ready, Amendment 2); ready once the solvers are set up. Private by default.
    let ops = credence_common::ops::OpsState::new("credence-solver");
    credence_common::ops::serve(
        env::parse_or("SOLVER_OPS_ADDR", "127.0.0.1:9105".parse()?)?,
        ops.router(),
    )
    .await?;
    let cfg: SolverConfig = serde_json::from_str(&std::fs::read_to_string(&cli.config)?)?;
    let read = ProviderBuilder::new()
        .connect_http(cli.rpc.parse()?)
        .erased();
    let chain_id = read.get_chain_id().await?;
    let venue = match cli.venue {
        Some(v) => v,
        None => book_addr(chain_id, "/nav/solverAuction")?,
    };
    let va = ISolverAuctionV3::new(venue, &read);
    let loan = va.loanToken().call().await?;
    let mut solvers = Vec::new();
    for p in cfg.solvers {
        let role = format!("solver-{}", p.name.to_lowercase());
        let signer_cfg = if p.key.is_empty() {
            SignerConfig::resolve(
                &format!("SOLVER_{}", p.name.to_uppercase().replace('-', "_")),
                chain_id,
                &role,
            )?
        } else {
            SignerConfig::LocalHex { key: p.key.clone() }
        };
        // a plain key refuses to load off dev chains
        let s = CredenceSigner::load(&signer_cfg, chain_id)
            .await
            .with_context(|| format!("key of {}", p.name))?;
        let addr = s.address();
        let w = ProviderBuilder::new()
            .with_simple_nonce_management()
            .wallet(s.wallet())
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
    ops.set_ready(true);
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
