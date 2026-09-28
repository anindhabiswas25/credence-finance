//! `credence-keeper run`: one keeper instance. Run two (different regions); the advisory-lock leader
//! acts, the follower heartbeats and takes over within 15 s (§10.2).

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use credence_common::{
    env, is_dev_chain,
    ops::{serve, OpsState},
    signer::{CredenceSigner, SignerConfig},
    telemetry,
};
use credence_keeper::{
    clock::SystemClock, config::Config, leader::Leader, metrics::Metrics, rpc::Rpc, tasks::Keeper,
    tx::TxManager,
};
use std::{net::SocketAddr, sync::Arc, time::Duration};

#[derive(Parser)]
#[command(
    name = "credence-keeper",
    version,
    about = "Credence keeper (Build Guide §10.2)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the scheduler (default).
    Run,
    /// Print the J1 boundaries due in the next N hours and exit.
    Schedule {
        #[arg(long, default_value_t = 24)]
        hours: u64,
    },
}

const NITRO_DEV_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";
const ANVIL_KEY0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

#[tokio::main]
async fn main() -> Result<()> {
    env::load_dotenv();
    telemetry::init("credence-keeper");
    let cli = Cli::parse();
    let cfg = Config::from_env()?;

    if let Some(Cmd::Schedule { hours }) = cli.cmd {
        let now = credence_keeper::clock::Clock::now(&SystemClock);
        for a in &cfg.assets {
            for b in credence_keeper::schedule::boundaries(&a.calendar, now, now + hours * 3600) {
                let t = chrono::DateTime::from_timestamp(b as i64, 0)
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default();
                println!("{:<14} {t}", a.label);
            }
        }
        return Ok(());
    }

    let ops = OpsState::new("credence-keeper");
    let metrics = Metrics::new(&ops.registry)?;
    let metrics_addr: SocketAddr = env::parse_or("METRICS_ADDR", "0.0.0.0:9102".parse()?)?;
    serve(metrics_addr, ops.router()).await?;

    let signer_cfg = match SignerConfig::from_env("KEEPER") {
        Ok(c) => c,
        Err(e) if is_dev_chain(cfg.chain_id) => {
            tracing::warn!(error = %e, "no keeper key configured: using the well-known dev key (dev chain only)");
            SignerConfig::LocalHex {
                key: if cfg.chain_id == 31_337 {
                    ANVIL_KEY0
                } else {
                    NITRO_DEV_KEY
                }
                .into(),
            }
        }
        Err(e) => return Err(e),
    };
    let signer = CredenceSigner::load(&signer_cfg, cfg.chain_id).await?;
    let rpc = Arc::new(Rpc::connect(
        &cfg.rpc_urls,
        Some(metrics.rpc_failovers.clone()),
    )?);
    let actual = rpc.chain_id().await?;
    if actual != cfg.chain_id {
        bail!("RPC chain id {actual} != CHAIN_ID {}", cfg.chain_id);
    }
    let pool = credence_common::db::connect(&cfg.database_url, 4).await?;
    let tx = TxManager::new(
        rpc.clone(),
        signer.wallet(),
        signer.address(),
        cfg.chain_id,
        metrics.clone(),
    );
    let mut keeper = Keeper::new(
        cfg.instance.clone(),
        rpc.clone(),
        tx,
        cfg.clock,
        cfg.assets.clone(),
        Arc::new(SystemClock),
        metrics.clone(),
        cfg.lookback_s,
    );
    keeper.alert_webhook = cfg.alert_webhook.clone();
    keeper.watch_wallets = cfg.watch_wallets.clone();
    keeper.min_balance_wei = cfg.min_balance_wei;
    keeper.core = credence_keeper::config::core_jobs(cfg.chain_id)?.map(std::sync::Arc::new);
    keeper.sigma = credence_keeper::config::sigma_runner(
        cfg.chain_id,
        &credence_keeper::config::load_calendars()?,
    )?
    .map(std::sync::Arc::new);
    if let Some(c) = &keeper.core {
        tracing::info!(
            markets = c.markets.len(),
            vaults = c.vaults.len(),
            sets = c.sets.len(),
            j3_live = c.j3_live,
            j4_live = c.j4_live,
            "core jobs enabled"
        );
    }
    keeper.stylus_programs = cfg
        .risk_engine
        .map(|a| vec![("riskEngine".to_owned(), a)])
        .unwrap_or_default();
    let mut leader = Leader::new(&cfg.database_url, pool.clone(), &cfg.instance, cfg.chain_id);
    tracing::info!(instance = %cfg.instance, sender = %signer.address(), clock = %cfg.clock, assets = cfg.assets.len(), "keeper starting");

    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut was_leader = false;
    loop {
        tick.tick().await;
        let is_leader = match leader.tick().await {
            Ok(l) => l,
            Err(e) => {
                tracing::error!(error = %e, "leader election failed");
                ops.set_ready(false);
                false
            }
        };
        metrics.is_leader.set(is_leader as i64);
        if is_leader && !was_leader {
            keeper.tx.reset_nonce().await;
        }
        was_leader = is_leader;
        if !is_leader {
            ops.set_ready(true); // a healthy follower is ready
            continue;
        }
        let Some(conn) = leader.conn() else { continue };
        match keeper.tick(conn).await {
            Ok(r) => {
                ops.set_ready(true);
                if !r.pokes.is_empty() || r.failed > 0 {
                    tracing::info!(
                        pokes = r.pokes.len(),
                        covered = r.covered,
                        failed = r.failed,
                        "tick"
                    );
                }
            }
            Err(e) => {
                ops.set_ready(false);
                tracing::error!(error = %e, "keeper tick failed");
            }
        }
    }
}
