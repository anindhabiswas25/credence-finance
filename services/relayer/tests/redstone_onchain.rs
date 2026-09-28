//! A4 on chain (make relayer-redstone-e2e): BE-chain's `RedStonePriceSource` accepts the payloads the relayer
//! builds (`vendor::redstone::payload`) from real RedStone packages.
//!
//! * `recorded_packages_on_anvil`: the recorded open (Mon 2026-09-28, tests/fixtures/redstone) on an anvil whose
//!   clock is set just after the packages; the accepted price of every asset equals the relayer's own 3-of-5
//!   median; a tampered payload, a stale one and a replay of an older timestamp revert.
//! * `live_gateway_packages_on_the_devnode`: the gateway's latest packages, submitted on the nitro devnode
//!   (needs internet and the devnode).

use std::{path::PathBuf, process::Stdio, time::Duration};

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{keccak256, Address, Bytes, B256, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::local::PrivateKeySigner,
    sol_types::{SolCall, SolValue},
};
use credence_bindings::RedStonePriceSource;
use credence_relayer::vendor::redstone::{
    aggregate, payload, GatewayPackage, PackageSource, Recorded, PRIMARY_PROD_SIGNERS,
};

const ANVIL0: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const NITRO_DEV_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";
const FEEDS: [&str; 4] = ["NVDA", "AAPL", "TSLA", "MSFT"];
const OPEN: u64 = 1_790_602_200;

fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

fn asset(t: &str) -> B256 {
    keccak256(format!("{t}:XNAS"))
}

fn feed_id(t: &str) -> B256 {
    let mut b = [0u8; 32];
    b[..t.len()].copy_from_slice(t.as_bytes());
    B256::from(b)
}

async fn provider(rpc: &str, key: &str) -> DynProvider {
    let s: PrivateKeySigner = key.parse().unwrap();
    ProviderBuilder::new()
        .with_simple_nonce_management()
        .wallet(EthereumWallet::from(s))
        .connect_http(rpc.parse().unwrap())
        .erased()
}

async fn send(p: &DynProvider, to: Address, data: Vec<u8>) -> Result<(), String> {
    let tx = TransactionRequest::default()
        .with_to(to)
        .with_input(Bytes::from(data));
    let pending = p.send_transaction(tx).await.map_err(|e| e.to_string())?;
    let r = tokio::time::timeout(Duration::from_secs(60), pending.get_receipt())
        .await
        .map_err(|_| "receipt timeout".to_string())?
        .map_err(|e| e.to_string())?;
    if r.status() {
        Ok(())
    } else {
        Err(format!("reverted in {}", r.transaction_hash))
    }
}

/// Deploy `RedStonePriceSource(timelock = sender, primary-prod signers, 3)` and map the four feeds.
async fn deploy(p: &DynProvider, sender: Address) -> Address {
    let art: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(
            repo().join("contracts/out/RedStonePriceSource.sol/RedStonePriceSource.json"),
        )
        .expect("run make contracts-build"),
    )
    .unwrap();
    let code = alloy::hex::decode(art["bytecode"]["object"].as_str().unwrap()).unwrap();
    let args = (sender, PRIMARY_PROD_SIGNERS.to_vec(), U256::from(3u8)).abi_encode_params();
    let tx = TransactionRequest::default().with_deploy_code(Bytes::from([code, args].concat()));
    let r = p
        .send_transaction(tx)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let addr = r.contract_address.expect("deployed");
    for t in FEEDS {
        send(
            p,
            addr,
            RedStonePriceSource::setFeedCall {
                assetId: asset(t),
                feedId: feed_id(t),
            }
            .abi_encode(),
        )
        .await
        .unwrap();
    }
    addr
}

fn submit(pkgs: &[GatewayPackage]) -> Vec<u8> {
    RedStonePriceSource::submitCall {
        payload: Bytes::from(payload(pkgs, b"credence").expect("payload")),
        assetIds: FEEDS.iter().map(|t| asset(t)).collect(),
    }
    .abi_encode()
}

#[tokio::test]
#[ignore = "needs anvil and contracts/out (make relayer-redstone-e2e)"]
async fn recorded_packages_on_anvil() {
    let ts = OPEN + 10; // the recorded open's first moved package
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let mut child = std::process::Command::new("anvil")
        .args([
            "--port",
            &port.to_string(),
            "--timestamp",
            &(ts + 5).to_string(),
            "--silent",
            "--code-size-limit",
            "100000",
        ])
        .stdout(Stdio::null())
        .spawn()
        .expect("anvil");
    let rpc = format!("http://127.0.0.1:{port}");
    let p = provider(&rpc, ANVIL0).await;
    for _ in 0..100 {
        if p.get_chain_id().await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let me = ANVIL0.parse::<PrivateKeySigner>().unwrap().address();
    let src = deploy(&p, me).await;

    let paths =
        [repo().join("services/relayer/tests/fixtures/redstone/primary-prod-20260928-open.json")];
    let refs: Vec<&std::path::Path> = paths.iter().map(|x| x.as_path()).collect();
    let rec = Recorded::load(&refs, 0).unwrap();
    let mut all = Vec::new();
    for t in FEEDS {
        all.extend(rec.at(t, ts).await.unwrap().unwrap());
    }
    send(&p, src, submit(&all))
        .await
        .expect("the recorded packages are accepted");
    let rs = RedStonePriceSource::new(src, &p);
    for t in FEEDS {
        let want = aggregate(
            t,
            &rec.at(t, ts).await.unwrap().unwrap(),
            &PRIMARY_PROD_SIGNERS,
            3,
        )
        .unwrap();
        let got = rs.latest(asset(t)).call().await.unwrap();
        assert_eq!(
            got._0,
            U256::from(want.value_wad()),
            "{t}: on-chain median == the relayer's"
        );
        assert_eq!(got._1.to::<u64>(), ts, "{t}: observed at the package time");
        println!("{t}: accepted {} at {}", got._0, got._1);
    }

    // a tampered value no longer recovers the signers
    let mut bad = all.clone();
    for pk in bad
        .iter_mut()
        .filter(|x| x.data_points[0].data_feed_id == "NVDA")
    {
        pk.data_points[0].value = serde_json::from_str("1.5").unwrap();
    }
    assert!(
        send(&p, src, submit(&bad)).await.is_err(),
        "tampered payload must revert"
    );
    // an older timestamp is refused (NotNewer), and so is stale data (> 180 s)
    let mut older = Vec::new();
    for t in FEEDS {
        older.extend(rec.at(t, ts - 10).await.unwrap().unwrap());
    }
    assert!(
        send(&p, src, submit(&older)).await.is_err(),
        "an older package must not replace a newer one"
    );
    let _: serde_json::Value = p
        .raw_request("evm_setNextBlockTimestamp".into(), (ts + 400,))
        .await
        .unwrap();
    let mut newer = Vec::new();
    for t in FEEDS {
        newer.extend(rec.at(t, ts + 10).await.unwrap().unwrap());
    }
    assert!(
        send(&p, src, submit(&newer)).await.is_err(),
        "data older than 180 s must revert"
    );
    let _ = child.kill();
}

#[tokio::test]
#[ignore = "needs internet and the nitro devnode (make relayer-redstone-e2e)"]
async fn live_gateway_packages_on_the_devnode() {
    let rpc = std::env::var("DEVNODE_RPC").unwrap_or_else(|_| "http://127.0.0.1:8547".into());
    let p = provider(&rpc, NITRO_DEV_KEY).await;
    let me = NITRO_DEV_KEY.parse::<PrivateKeySigner>().unwrap().address();
    let src = deploy(&p, me).await;
    let body: std::collections::HashMap<String, Vec<GatewayPackage>> = reqwest::get(
        "https://oracle-gateway-1.a.redstone.finance/data-packages/latest/redstone-primary-prod",
    )
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    let mut all = Vec::new();
    for t in FEEDS {
        all.extend(body.get(t).cloned().unwrap_or_default());
    }
    send(&p, src, submit(&all))
        .await
        .expect("live packages accepted on the devnode");
    let rs = RedStonePriceSource::new(src, &p);
    for t in FEEDS {
        let want = aggregate(t, &body[t], &PRIMARY_PROD_SIGNERS, 3).unwrap();
        let got = rs.latest(asset(t)).call().await.unwrap();
        assert_eq!(got._0, U256::from(want.value_wad()), "{t}");
        println!(
            "devnode {src}: {t} accepted {} (package {})",
            got._0, got._1
        );
    }
}
