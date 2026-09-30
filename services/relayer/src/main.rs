//! `credence-relayer` binary.
//!
//! ```text
//! credence-relayer run          # all-in-one: 3 in-process signer nodes + aggregator (dev)
//! credence-relayer node         # one signer node (production: one per host / cloud account)
//! credence-relayer aggregator   # the feed's aggregator, talking to RELAYER_NODE_URLS
//! credence-relayer smoke        # live vendor smoke test (needs vendor keys)
//! ```

use alloy::primitives::Address;
use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use credence_common::{
    env, is_dev_chain,
    ops::{serve, OpsState},
    signer::{CredenceSigner, SignerConfig},
    telemetry,
};
use credence_relayer::{
    aggregator::{Aggregator, AggregatorConfig, HttpNode, LocalNode, NodeClient},
    chain::{ChainClient, FeedChain},
    config::{build_vendor, Common, VendorKind},
    filter::FilterConfig,
    metrics::Metrics,
    node::{Node, NodeConfig},
    report::domain,
    store::{MemStore, PgStore, ReportStore},
    vendor::DynVendor,
};
use std::{net::SocketAddr, sync::Arc, time::Duration};

#[derive(Parser)]
#[command(
    name = "credence-relayer",
    version,
    about = "Credence price relayer (Build Guide §10.1)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// 3 in-process signer nodes + the aggregator (development and the local devnode).
    Run,
    /// One signer node serving /v1/observations and /v1/sign.
    Node {
        #[arg(long, env = "NODE_ID", default_value = "node-1")]
        id: String,
        /// Private by default (OFF-02); expose it on a private network interface explicitly.
        #[arg(long, env = "NODE_LISTEN", default_value = "127.0.0.1:8080")]
        listen: SocketAddr,
    },
    /// The aggregator of one feed.
    Aggregator,
    /// Write a synthetic replay session (clearly labelled synthetic) whose regular session opened
    /// `--minutes-in` minutes ago, for local runs without vendor keys.
    SampleReplay {
        #[arg(long)]
        out: std::path::PathBuf,
        #[arg(long, default_value_t = 10)]
        minutes_in: u64,
    },
    /// Record a real session window from Alpaca history (trades + quotes) into a replay file.
    Record {
        /// RFC 3339 start, e.g. 2026-09-25T15:50:00-04:00
        #[arg(long)]
        start: String,
        /// RFC 3339 end
        #[arg(long)]
        end: String,
        #[arg(long)]
        out: std::path::PathBuf,
        /// Max pages (10 000 rows each) per symbol and kind
        #[arg(long, default_value_t = 20)]
        max_pages: usize,
        /// Keep at most one quote per symbol per this many ms (0 = all). Trades are always kept.
        #[arg(long, default_value_t = 500)]
        quote_sample_ms: u64,
    },
    /// Record RedStone `redstone-primary-prod` packages from the gateway's history (about 24 h) into a
    /// `PRINT_SOURCE=redstone` recording (ADR-0009 D1), e.g. around an open or a close.
    RedstoneRecord {
        /// Unix seconds (inclusive; 10 s grid)
        #[arg(long)]
        from: u64,
        #[arg(long)]
        to: u64,
        /// Regular-session feed ids
        #[arg(long, value_delimiter = ',', default_value = "NVDA,AAPL,TSLA,MSFT")]
        feeds: Vec<String>,
        #[arg(long)]
        out: std::path::PathBuf,
    },
    /// Hit every vendor endpoint once for one asset and report what the key is entitled to.
    Smoke {
        /// Asset to test (defaults to the first in ASSETS).
        #[arg(long)]
        asset: Option<String>,
        /// Write the results as JSON to this file.
        #[arg(long)]
        out: Option<std::path::PathBuf>,
    },
}

// Well-known dev keys (public; accepted only on dev chains, see SignerConfig).
const ANVIL_KEYS: [&str; 4] = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];
const NITRO_DEV_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

fn signer_config(prefix: &str, dev_default: Option<&str>, chain_id: u64) -> Result<SignerConfig> {
    match SignerConfig::from_env(prefix) {
        Ok(c) => Ok(c),
        Err(e) => match dev_default {
            Some(k) if is_dev_chain(chain_id) => {
                tracing::warn!(
                    prefix,
                    "no signer configured: using a well-known dev key (dev chain only)"
                );
                Ok(SignerConfig::LocalHex { key: k.into() })
            }
            _ => Err(e),
        },
    }
}

fn node_config(
    id: &str,
    assets: Vec<credence_relayer::asset::Asset>,
    vendor: VendorKind,
) -> Result<NodeConfig> {
    // free vendor tiers are slow: poll less often unless told otherwise
    let default_poll = if vendor == VendorKind::Replay {
        1000
    } else {
        2000
    };
    Ok(NodeConfig {
        id: id.into(),
        assets,
        poll_interval: Duration::from_millis(env::parse_or("RELAYER_POLL_MS", default_poll)?),
        print_poll_interval: Duration::from_millis(env::parse_or("RELAYER_PRINT_POLL_MS", 2000)?),
        filter: FilterConfig::default(),
        auth_token: env::optional("RELAYER_NODE_TOKEN"),
    })
}

/// OFF-02: off dev chains, a standalone node refuses to start without a `RELAYER_NODE_TOKEN` of ≥ 32 bytes.
fn check_node_token(chain_id: u64, token: Option<&str>) -> Result<()> {
    match token {
        Some(t) if t.len() >= 32 => Ok(()),
        _ if is_dev_chain(chain_id) => Ok(()),
        Some(_) => bail!("RELAYER_NODE_TOKEN must be at least 32 bytes"),
        None => bail!("RELAYER_NODE_TOKEN is required for a signer node off dev chains (OFF-02)"),
    }
}

fn feed_address() -> Result<Address> {
    env::required("FEED_ADDRESS")?
        .parse()
        .context("FEED_ADDRESS")
}

fn rpc_urls() -> Result<Vec<String>> {
    let mut v = vec![env::optional("RPC_URL")
        .or_else(|| env::optional("ARB_SEPOLIA_RPC_URL"))
        .context("RPC_URL")?];
    if let Some(f) =
        env::optional("RPC_URL_FALLBACK").or_else(|| env::optional("ARB_SEPOLIA_RPC_URL_FALLBACK"))
    {
        v.push(f);
    }
    Ok(v)
}

async fn store(chain_id: u64) -> Result<Arc<dyn ReportStore>> {
    match env::optional("DATABASE_URL") {
        Some(url) => Ok(Arc::new(PgStore::new(
            credence_common::db::connect_chain(&url, 4, chain_id).await?,
        ))),
        None => {
            tracing::warn!("DATABASE_URL not set: reports are kept in memory only");
            Ok(Arc::new(MemStore::default()))
        }
    }
}

async fn aggregator(
    common: &Common,
    nodes: Vec<Arc<dyn NodeClient>>,
    ops: &OpsState,
    metrics: Metrics,
) -> Result<Aggregator> {
    let submitter_default = match common.chain_id {
        31_337 => Some(ANVIL_KEYS[0]),
        412_346 => Some(NITRO_DEV_KEY),
        _ => None,
    };
    let submitter = CredenceSigner::load(
        &signer_config("RELAYER_SUBMITTER", submitter_default, common.chain_id)?,
        common.chain_id,
    )
    .await?;
    let other = env::optional("OTHER_FEED_ADDRESS")
        .map(|a| a.parse())
        .transpose()
        .context("OTHER_FEED_ADDRESS")?;
    let chain = ChainClient::connect(&rpc_urls()?, submitter.wallet(), feed_address()?, other)?;
    let actual = chain.chain_id().await?;
    if actual != common.chain_id {
        bail!("RPC chain id {actual} != CHAIN_ID {}", common.chain_id);
    }
    tracing::info!(submitter = %submitter.address(), feed = %chain.feed, "aggregator connected");
    let committee = env::optional("RELAYER_COMMITTEE")
        .map(|s| {
            s.split(',')
                .map(|a| a.trim().parse::<Address>())
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()
        .context("RELAYER_COMMITTEE")?;
    let cfg = AggregatorConfig {
        feed: common.feed_id.clone(),
        threshold: env::parse_or("RELAYER_THRESHOLD", 2usize)?,
        // 250 ms: an idle tick only collects snapshots; a streamed ≥ 0.10% move is submitted within a tick
        tick: Duration::from_millis(env::parse_or("RELAYER_TICK_MS", 250)?),
        committee,
        assets: common
            .assets
            .iter()
            .map(|a| (a.id, a.symbol.clone()))
            .collect(),
    };
    let _ = ops;
    let chain: Arc<dyn FeedChain> = Arc::new(chain);
    let mut agg = Aggregator::new(cfg, nodes, chain, store(common.chain_id).await?, metrics);
    agg.sync_seqs().await?;
    Ok(agg)
}

async fn node(
    common: &Common,
    id: &str,
    key_prefix: &str,
    dev_key: Option<&str>,
    vendor: DynVendor,
    calendar: Arc<credence_common::calendar::Calendar>,
    metrics: Metrics,
) -> Result<Arc<Node>> {
    let signer = CredenceSigner::load(
        &signer_config(key_prefix, dev_key, common.chain_id)?,
        common.chain_id,
    )
    .await?;
    let d = domain(common.chain_id, feed_address()?);
    tracing::info!(node = id, signer = %signer.address(), vendor = vendor.name(), "signer node ready");
    Ok(Arc::new(Node::new(
        node_config(id, common.assets.clone(), common.vendor_kind.clone())?,
        vendor,
        calendar,
        signer,
        d,
        metrics,
    )))
}

/// Record `[start, end)` for every asset from Alpaca history into the replay format
/// (`vendor::replay`): a header with the calendar sessions touching the window, market events at every
/// calendar window change, then all trades and quotes.
async fn record(
    common: &Common,
    start: &str,
    end: &str,
    out: &std::path::Path,
    max_pages: usize,
    quote_sample_ms: u64,
) -> Result<()> {
    use credence_common::calendar::Window;
    use credence_relayer::vendor::{
        alpaca::{Alpaca, Recorded},
        replay::{Event, RawSession},
    };
    let parse = |s: &str| -> Result<u64> {
        Ok(chrono::DateTime::parse_from_rfc3339(s)
            .context("RFC 3339 time")?
            .timestamp() as u64)
    };
    let (from, to) = (parse(start)?, parse(end)?);
    if to <= from {
        bail!("--end must be after --start");
    }
    let halts = credence_relayer::config::halt_feed();
    let alpaca = Alpaca::new(credence_relayer::config::alpaca_config()?, halts);
    let cal = credence_relayer::config::load_calendar()?;
    let sessions: Vec<RawSession> = cal
        .sessions
        .iter()
        .filter(|s| s.ext_close > from && s.ext_open < to)
        .map(|s| RawSession {
            ext_open: s.ext_open,
            open: s.open,
            close: s.close,
            ext_close: s.ext_close,
            closure_type_after: s.closure_type_after as u8,
        })
        .collect();
    if sessions.is_empty() {
        bail!("no calendar session touches {start} .. {end} (set CALENDAR_FILES)");
    }
    let market = |w: Window| match w {
        Window::Regular => "open",
        Window::Closed => "closed",
        _ => "extended",
    };
    let mut events: Vec<(u64, Event)> = vec![(
        0,
        Event::Header {
            venue: cal.venue.clone(),
            sessions,
        },
    )];
    let mut marks = vec![from];
    marks.extend(cal.boundaries_between(from, to));
    for m in marks {
        events.push((
            m * 1_000_000_000,
            Event::Market {
                t: m * 1_000_000_000,
                m: market(cal.window_at(m)).into(),
            },
        ));
    }
    for asset in &common.assets {
        let rows = alpaca
            .history(asset, from * 1_000_000_000, to * 1_000_000_000, max_pages)
            .await?;
        let total = rows.len();
        let mut kept = 0usize;
        let mut last_quote = 0u64;
        for (t, r) in rows {
            if let Recorded::Quote { .. } = r {
                if quote_sample_ms > 0
                    && last_quote != 0
                    && t < last_quote + quote_sample_ms * 1_000_000
                {
                    continue;
                }
                last_quote = t;
            }
            kept += 1;
            let e = match r {
                Recorded::Trade { t, p, s, x, c, z } => Event::Trade {
                    t,
                    sym: asset.symbol.clone(),
                    p,
                    s,
                    x,
                    c,
                    z,
                },
                Recorded::Quote { t, bp, ap } => Event::Quote {
                    t,
                    sym: asset.symbol.clone(),
                    bp,
                    ap,
                },
            };
            events.push((t, e));
        }
        println!("{}: {total} rows, {kept} kept", asset.symbol);
    }
    events.sort_by_key(|(t, _)| *t);
    let mut body = String::new();
    for (_, e) in events {
        body.push_str(&serde_json::to_string(&e)?);
        body.push('\n');
    }
    std::fs::write(out, body)?;
    println!(
        "wrote {} (vendor alpaca, feed {})",
        out.display(),
        credence_relayer::config::alpaca_config()?.feed
    );
    Ok(())
}

use credence_relayer::price::fmt_wad;

async fn smoke(
    common: &Common,
    asset: Option<String>,
    out: Option<std::path::PathBuf>,
) -> Result<()> {
    use credence_relayer::{asset::Asset, vendor::VendorError};
    let asset = match asset {
        Some(a) => Asset::parse(&a)?,
        None => common.assets[0].clone(),
    };
    let (vendor, cal) = build_vendor(common, None).await?;
    let now = credence_relayer::node::now_s();
    let session = cal
        .current_or_last_session(now)
        .copied()
        .context("no session in the calendar before now")?;
    let mut results = serde_json::Map::new();
    let mut fatal = false;
    let mut record = |name: &str, r: std::result::Result<serde_json::Value, VendorError>| {
        let (status, detail) = match r {
            Ok(v) => ("OK", v),
            Err(e @ VendorError::NotEntitled { .. }) => {
                ("NOT_ENTITLED", serde_json::Value::String(e.to_string()))
            }
            Err(e) => {
                fatal = true;
                ("ERROR", serde_json::Value::String(e.to_string()))
            }
        };
        println!("{:<16} {:<13} {}", name, status, detail);
        results.insert(
            name.into(),
            serde_json::json!({ "status": status, "detail": detail }),
        );
    };
    println!(
        "vendor={} asset={} session.open={}",
        vendor.name(),
        asset.symbol,
        session.open
    );
    record(
        "status",
        vendor
            .status(&asset)
            .await
            .map(|s| serde_json::to_value(s).unwrap_or_default()),
    );
    // u128 WAD prices do not fit serde_json numbers: report them as decimal strings
    let print = |p: Option<credence_relayer::vendor::OfficialPrint>| match p {
        None => serde_json::Value::Null,
        Some(p) => {
            serde_json::json!({ "price": fmt_wad(p.price_wad), "at": p.at, "source": format!("{:?}", p.source) })
        }
    };
    // the last 10 minutes of the most recent regular session
    let since = (session.close.saturating_sub(600)) * 1_000_000_000;
    record(
        "live",
        vendor.live(&asset, since).await.map(|l| {
            serde_json::json!({
                "trades": l.trades.len(),
                "newest": l.trades.first().map(|t| serde_json::json!({
                    "price": fmt_wad(t.price_wad), "ts_ns": t.ts_ns, "exchange": t.exchange,
                    "conditions": t.conditions, "plan": format!("{:?}", t.plan),
                })),
                "nbbo": l.nbbo.map(|q| serde_json::json!({ "bid": fmt_wad(q.bid_wad), "ask": fmt_wad(q.ask_wad), "ts_ns": q.ts_ns })),
            })
        }),
    );
    record(
        "official_open",
        vendor.official_open(&asset, &session).await.map(print),
    );
    record(
        "official_close",
        vendor.official_close(&asset, &session).await.map(print),
    );
    if let Some(path) = out {
        let doc = serde_json::json!({ "vendor": vendor.name(), "asset": asset.symbol, "at": now, "results": results });
        std::fs::write(&path, serde_json::to_string_pretty(&doc)?)?;
        println!("wrote {}", path.display());
    }
    if fatal {
        bail!("smoke test failed");
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env::load_dotenv();
    telemetry::init("credence-relayer");
    let cli = Cli::parse();
    if let Cmd::SampleReplay { out, minutes_in } = &cli.cmd {
        let open = credence_relayer::node::now_s() - minutes_in * 60;
        let symbols: Vec<(String, String, f64)> = env::list("ASSETS")
            .iter()
            .filter_map(|a| a.split_once(':').map(|(t, m)| (t.to_owned(), m.to_owned())))
            .enumerate()
            .map(|(i, (t, m))| (t, m, 100.0 + 25.0 * i as f64))
            .collect();
        let refs: Vec<(&str, &str, f64)> = symbols
            .iter()
            .map(|(t, m, p)| (t.as_str(), m.as_str(), *p))
            .collect();
        let events = credence_relayer::vendor::replay::synthetic_session(&refs, open);
        let mut body = String::from("");
        for e in events {
            body.push_str(&serde_json::to_string(&e)?);
            body.push('\n');
        }
        std::fs::write(out, body)?;
        println!(
            "wrote a SYNTHETIC replay session ({} symbols) to {}; replay it {minutes_in} min into the regular session with REPLAY_START_OFFSET_S={}",
            refs.len(),
            out.display(),
            3600 + minutes_in * 60
        );
        return Ok(());
    }
    if let Cmd::RedstoneRecord {
        from,
        to,
        feeds,
        out,
    } = &cli.cmd
    {
        use credence_relayer::vendor::redstone::{Gateway, HISTORY_GATEWAYS};
        let g = Gateway::new(HISTORY_GATEWAYS.iter().map(|s| s.to_string()).collect());
        let doc = g.record(feeds, *from, *to).await;
        let n = doc["snapshots"].as_object().map_or(0, |m| {
            m.values().filter(|v| v.get("error").is_none()).count()
        });
        std::fs::write(out, serde_json::to_string(&doc)?)?;
        println!(
            "wrote {n} RedStone snapshots ({}) to {}",
            feeds.join(","),
            out.display()
        );
        return Ok(());
    }
    let common = Common::from_env()?;
    let ops = OpsState::new("credence-relayer");
    let metrics = Metrics::new(&ops.registry)?;
    let metrics_addr: SocketAddr = env::parse_or("METRICS_ADDR", "0.0.0.0:9101".parse()?)?;

    match cli.cmd {
        Cmd::SampleReplay { .. } | Cmd::RedstoneRecord { .. } => unreachable!("handled above"),
        Cmd::Smoke { asset, out } => smoke(&common, asset, out).await,
        Cmd::Record {
            start,
            end,
            out,
            max_pages,
            quote_sample_ms,
        } => record(&common, &start, &end, &out, max_pages, quote_sample_ms).await,
        Cmd::Run => {
            if !is_dev_chain(common.chain_id) {
                bail!("`run` (all nodes in one process) is for dev chains; use `node` + `aggregator` on {}", common.chain_id);
            }
            let (vendor, cal) = build_vendor(&common, Some(metrics.clone())).await?;
            let mut nodes: Vec<Arc<dyn NodeClient>> = Vec::new();
            for (i, dev_key) in ANVIL_KEYS.iter().enumerate().skip(1) {
                let n = node(
                    &common,
                    &format!("node-{i}"),
                    &format!("RELAYER_NODE{i}"),
                    Some(*dev_key),
                    vendor.clone(),
                    cal.clone(),
                    metrics.clone(),
                )
                .await?;
                tokio::spawn(n.clone().run());
                nodes.push(Arc::new(LocalNode(n)));
            }
            let agg = aggregator(&common, nodes, &ops, metrics).await?;
            serve(metrics_addr, ops.router()).await?;
            agg.run(ops).await;
            Ok(())
        }
        Cmd::Node { id, listen } => {
            // OFF-02 (QA-sec): a node's /v1/sign is a signing oracle; off dev chains it needs a bearer token
            check_node_token(
                common.chain_id,
                env::optional("RELAYER_NODE_TOKEN").as_deref(),
            )?;
            let (vendor, cal) = build_vendor(&common, Some(metrics.clone())).await?;
            let n = node(&common, &id, "RELAYER_NODE", None, vendor, cal, metrics).await?;
            tokio::spawn(n.clone().run());
            ops.set_ready(true);
            serve(metrics_addr, ops.router()).await?;
            let listener = tokio::net::TcpListener::bind(listen).await?;
            tracing::info!(%listen, "node API listening");
            axum::serve(listener, n.router()).await?;
            Ok(())
        }
        Cmd::Aggregator => {
            let token = env::optional("RELAYER_NODE_TOKEN");
            let urls = env::list("RELAYER_NODE_URLS");
            if urls.len() < 3 {
                bail!("RELAYER_NODE_URLS must list the 3 signer nodes");
            }
            let nodes: Vec<Arc<dyn NodeClient>> = urls
                .into_iter()
                .map(|u| Arc::new(HttpNode::new(u, token.clone())) as Arc<dyn NodeClient>)
                .collect();
            let agg = aggregator(&common, nodes, &ops, metrics).await?;
            serve(metrics_addr, ops.router()).await?;
            agg.run(ops).await;
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::check_node_token;

    #[test]
    fn off02_node_token_required_off_dev_chains() {
        assert!(check_node_token(412_346, None).is_ok());
        assert!(check_node_token(421_614, None).is_err());
        assert!(check_node_token(421_614, Some("short")).is_err());
        assert!(check_node_token(42_161, Some(&"x".repeat(32))).is_ok());
    }
}
