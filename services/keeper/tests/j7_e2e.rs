//! J7 on real contracts, before `DeployCoreLocal` (make keeper-j7-e2e):
//!
//! * `sigma_oracle_accepts_the_keeper_committee` (anvil): BE-chain's `SigmaOracle` (contracts/out) wired
//!   to `MockRiskEngine`. The keeper plans from the calibration snapshot, the 2-of-3 committee signs, and
//!   `submit` lands σ in the engine; 1 signature, unsorted signatures and a replayed `asOfDay` revert.
//! * `stylus_engine_accepts_planned_sigma_and_rejects_a_fast_drop` (nitro devnode): the Risk Engine from
//!   the address book; its σ writer is `shared.sigmaOracle` (the committee submits) or, on an S2-era
//!   book, the deployer. The σ the keeper plans against the
//!   engine's own state (current σ, last update time) is accepted; a drop below 0.9 × current is
//!   rejected with `SigmaDropTooFast`.

use std::{path::PathBuf, process::Stdio, time::Duration};

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{keccak256, Address, Bytes, B256, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::local::PrivateKeySigner,
    sol_types::{SolCall, SolValue},
};
use credence_keeper::{
    core::abi::{IRiskEngine, ISigmaOracle},
    sigma::Snapshot,
    sigma_job::{domain, plan, sign_committee, OnChainSigma},
    sigma_runner::chain_state,
};

const ANVIL: [&str; 4] = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

const NITRO_DEV_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

fn artifact(name: &str) -> serde_json::Value {
    let p = repo().join(format!("contracts/out/{name}.sol/{name}.json"));
    serde_json::from_str(
        &std::fs::read_to_string(&p)
            .unwrap_or_else(|_| panic!("{} (run make contracts-build)", p.display())),
    )
    .unwrap()
}

fn bytecode(a: &serde_json::Value) -> Vec<u8> {
    alloy::hex::decode(a["bytecode"]["object"].as_str().unwrap()).unwrap()
}

fn snapshot() -> Snapshot {
    Snapshot::load(&repo().join("calibration/out/sigma/sigma-ea391d6a1d0303cd.json")).unwrap()
}

async fn provider(rpc: &str, key: &str) -> DynProvider {
    let signer: PrivateKeySigner = key.parse().unwrap();
    // fetch the nonce per tx: a send that reverts at estimation must not leave a gap
    ProviderBuilder::new()
        .with_simple_nonce_management()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc.parse().unwrap())
        .erased()
}

async fn deploy(p: &DynProvider, code: Vec<u8>) -> Address {
    let tx = TransactionRequest::default().with_deploy_code(Bytes::from(code));
    p.send_transaction(tx)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap()
        .contract_address
        .unwrap()
}

/// Send and return whether it succeeded (a revert at estimation counts as failure).
async fn try_send(p: &DynProvider, to: Address, data: Vec<u8>) -> Result<(), String> {
    let tx = TransactionRequest::default()
        .with_to(to)
        .with_input(Bytes::from(data));
    match p.send_transaction(tx).await {
        Ok(pending) => {
            let r = tokio::time::timeout(Duration::from_secs(30), pending.get_receipt())
                .await
                .map_err(|_| "receipt timeout".to_string())?
                .map_err(|e| e.to_string())?;
            if r.status() {
                Ok(())
            } else {
                Err("reverted".into())
            }
        }
        Err(e) => Err(e.to_string()),
    }
}

struct Anvil(std::process::Child, String);
impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.0.kill();
    }
}

#[tokio::test]
#[ignore = "needs anvil and contracts/out (make keeper-j7-e2e)"]
async fn sigma_oracle_accepts_the_keeper_committee() {
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let child = std::process::Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent"])
        .stdout(Stdio::null())
        .spawn()
        .expect("anvil");
    let anvil = Anvil(child, format!("http://127.0.0.1:{port}"));
    let p = provider(&anvil.1, ANVIL[0]).await;
    for _ in 0..100 {
        if p.get_chain_id().await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let deployer: Address = ANVIL[0].parse::<PrivateKeySigner>().unwrap().address();
    let committee: Vec<PrivateKeySigner> = ANVIL[1..].iter().map(|k| k.parse().unwrap()).collect();
    let mut signers: Vec<Address> = committee.iter().map(|s| s.address()).collect();
    signers.sort();

    // Wire oracle ↔ engine for either SigmaOracle constructor (engine in the constructor, or wired later).
    let so = artifact("SigmaOracle");
    let arity = so["abi"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["type"] == "constructor")
        .unwrap()["inputs"]
        .as_array()
        .unwrap()
        .len();
    let nonce = p.get_transaction_count(deployer).await.unwrap();
    let (oracle, engine) = if arity == 3 {
        let oracle = deploy(
            &p,
            [
                bytecode(&so),
                (deployer, signers.clone(), U256::from(2u8)).abi_encode_params(),
            ]
            .concat(),
        )
        .await;
        let engine = deploy(
            &p,
            [
                bytecode(&artifact("MockRiskEngine")),
                (deployer, oracle).abi_encode_params(),
            ]
            .concat(),
        )
        .await;
        try_send(
            &p,
            oracle,
            ISigmaOracle::initializeWiringCall { engine_: engine }.abi_encode(),
        )
        .await
        .unwrap();
        (oracle, engine)
    } else {
        let oracle_at = deployer.create(nonce + 1);
        let engine = deploy(
            &p,
            [
                bytecode(&artifact("MockRiskEngine")),
                (deployer, oracle_at).abi_encode_params(),
            ]
            .concat(),
        )
        .await;
        let oracle = deploy(
            &p,
            [
                bytecode(&so),
                (deployer, engine, signers.clone(), U256::from(2u8)).abi_encode_params(),
            ]
            .concat(),
        )
        .await;
        assert_eq!(oracle, oracle_at);
        (oracle, engine)
    };

    let snap = snapshot();
    let mut nvda = snap
        .assets
        .iter()
        .find(|a| a.symbol == "NVDA")
        .unwrap()
        .clone();
    let asset: B256 = nvda.asset_id.parse().unwrap();
    let day: chrono::NaiveDate = "2026-09-28".parse().unwrap();
    let chain = chain_state(&p, engine, oracle, asset).await.unwrap();
    assert!(chain
        .iter()
        .all(|c| c.current.is_zero() && c.sigma_at.is_none() && c.last_as_of_day == 0));
    let now = p
        .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    let planned = plan(&mut nvda, &[], &chain, day, now, 1).unwrap();
    assert_eq!(planned.len(), 3);
    let dom = domain(31_337, oracle);
    // the digest the keeper signs equals the contract's hashUpdate
    let o = ISigmaOracle::new(oracle, &p);
    for pl in &planned {
        let u = &pl.update;
        let abi_u = ISigmaOracle::SigmaUpdate {
            assetId: u.assetId,
            closureType: u.closureType,
            sigma: u.sigma,
            asOfDay: u.asOfDay,
            nonce: u.nonce,
        };
        assert_eq!(
            o.hashUpdate(abi_u).call().await.unwrap(),
            credence_keeper::sigma_job::digest(u, &dom)
        );
    }
    let abi = |u: &credence_keeper::sigma_job::SigmaUpdate| ISigmaOracle::SigmaUpdate {
        assetId: u.assetId,
        closureType: u.closureType,
        sigma: u.sigma,
        asOfDay: u.asOfDay,
        nonce: u.nonce,
    };

    // negative: one signature, and two signatures in descending signer order
    let u0 = &planned[0].update;
    let sigs = sign_committee(u0, &dom, &committee, 2).await.unwrap();
    let one = ISigmaOracle::submitCall {
        u: abi(u0),
        signatures: vec![sigs[0].clone()],
    }
    .abi_encode();
    assert!(
        try_send(&p, oracle, one).await.is_err(),
        "1-of-3 must revert"
    );
    let rev = ISigmaOracle::submitCall {
        u: abi(u0),
        signatures: vec![sigs[1].clone(), sigs[0].clone()],
    }
    .abi_encode();
    assert!(
        try_send(&p, oracle, rev).await.is_err(),
        "unsorted signatures must revert"
    );

    // the keeper's submissions land
    for pl in &planned {
        let sigs = sign_committee(&pl.update, &dom, &committee, 2)
            .await
            .unwrap();
        try_send(
            &p,
            oracle,
            ISigmaOracle::submitCall {
                u: abi(&pl.update),
                signatures: sigs,
            }
            .abi_encode(),
        )
        .await
        .unwrap();
        let t = pl.update.closureType;
        assert_eq!(
            IRiskEngine::new(engine, &p)
                .sigma(asset, t)
                .call()
                .await
                .unwrap(),
            pl.update.sigma
        );
        assert_eq!(
            pl.update.sigma,
            nvda.seed_wad[t as usize - 1],
            "a fresh engine gets the snapshot σ"
        );
    }
    // replaying the same asOfDay is refused (single-use updates)
    let sigs = sign_committee(u0, &dom, &committee, 2).await.unwrap();
    assert!(try_send(
        &p,
        oracle,
        ISigmaOracle::submitCall {
            u: abi(u0),
            signatures: sigs
        }
        .abi_encode()
    )
    .await
    .is_err());
    // and a re-plan for the same day plans nothing
    let chain = chain_state(&p, engine, oracle, asset).await.unwrap();
    // the oracle now records today's asOfDay for all three types
    let today = credence_keeper::sigma_job::as_of_day(day);
    assert!(chain.iter().all(|c| c.last_as_of_day == today), "{chain:?}");
    let mut again = snap
        .assets
        .iter()
        .find(|a| a.symbol == "NVDA")
        .unwrap()
        .clone();
    assert!(plan(&mut again, &[], &chain, day, now, 2)
        .unwrap()
        .is_empty());
}

#[tokio::test]
#[ignore = "needs the nitro devnode with the Risk Engine (make keeper-j7-e2e)"]
async fn stylus_engine_accepts_planned_sigma_and_rejects_a_fast_drop() {
    std::env::set_current_dir(repo()).unwrap();
    let rpc = std::env::var("DEVNODE_RPC").unwrap_or_else(|_| "http://127.0.0.1:8547".into());
    let engine =
        credence_keeper::config::book_address(412_346, "RISK_ENGINE_ADDRESS", "/shared/riskEngine")
            .unwrap()
            .expect("shared.riskEngine");
    let p = provider(&rpc, NITRO_DEV_KEY).await;
    let e = IRiskEngine::new(engine, &p);
    let writer = e.sigmaOracle().call().await.unwrap();
    let deployer = NITRO_DEV_KEY.parse::<PrivateKeySigner>().unwrap().address();
    // S2 devnode: the deployer writes σ directly. Since DeployCoreLocal the writer is `shared.sigmaOracle`,
    // whose local committee is anvil keys 1..3 (RELAYER_A_SIGNERS), so updates go through `submit`.
    let committee: Vec<PrivateKeySigner> = ANVIL[1..].iter().map(|k| k.parse().unwrap()).collect();
    let via_oracle = writer != deployer;
    let (dom, threshold) = if via_oracle {
        let o = ISigmaOracle::new(writer, &p);
        (
            domain(412_346, writer),
            o.threshold().call().await.unwrap() as usize,
        )
    } else {
        (domain(412_346, Address::ZERO), 0)
    };

    // a fresh asset key per run (the devnode keeps state), with NVDA's calibrated state
    let mut a = snapshot()
        .assets
        .iter()
        .find(|a| a.symbol == "NVDA")
        .unwrap()
        .clone();
    let salt = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let asset = keccak256(format!("J7-E2E:{salt}"));
    a.asset_id = asset.to_string();
    let t = 2u8;
    let day0 = credence_keeper::sigma_job::as_of_day("2026-09-28".parse().unwrap());
    let seq = std::sync::atomic::AtomicU32::new(0);
    let update = |s: U256| {
        let (dom, committee, seq) = (&dom, &committee, &seq);
        async move {
            if !via_oracle {
                return (
                    engine,
                    IRiskEngine::updateSigmaCall {
                        assetId: asset,
                        closureType: t,
                        sigma: s,
                    }
                    .abi_encode(),
                );
            }
            // asOfDay must increase per (asset, type): one day per write
            let u = credence_keeper::sigma_job::SigmaUpdate {
                assetId: asset,
                closureType: t,
                sigma: s,
                asOfDay: day0 + seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst),
                nonce: 0,
            };
            let sigs = sign_committee(&u, dom, committee, threshold).await.unwrap();
            (
                writer,
                ISigmaOracle::submitCall {
                    u: ISigmaOracle::SigmaUpdate {
                        assetId: u.assetId,
                        closureType: u.closureType,
                        sigma: u.sigma,
                        asOfDay: u.asOfDay,
                        nonce: u.nonce,
                    },
                    signatures: sigs,
                }
                .abi_encode(),
            )
        }
    };
    let send = |s: U256| {
        let p = &p;
        let update = &update;
        async move {
            let (to, data) = update(s).await;
            try_send(p, to, data).await
        }
    };

    // the engine currently holds a much higher σ (a volatile week): raising is always allowed
    let high = a.seed_wad[1] * U256::from(3u64);
    send(high).await.unwrap();
    let chain = chain_state(&p, engine, Address::ZERO, asset).await.unwrap();
    assert_eq!(chain[1].current, high);
    assert!(chain[1].sigma_at.is_some());

    // the keeper's plan never goes below what the engine allows: here (same day) that is `high` itself
    let now = p
        .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    let chain_only_t: [OnChainSigma; 3] = [
        OnChainSigma {
            last_as_of_day: u32::MAX,
            ..Default::default()
        },
        chain[1],
        OnChainSigma {
            last_as_of_day: u32::MAX,
            ..Default::default()
        },
    ];
    let planned = plan(
        &mut a,
        &[],
        &chain_only_t,
        "2026-09-28".parse().unwrap(),
        now,
        1,
    )
    .unwrap();
    assert_eq!(planned.len(), 1);
    let s = planned[0].update.sigma;
    assert!(
        planned[0].model < high,
        "the model σ is below the current one"
    );
    assert_eq!(s, high, "same day: min allowed = current");
    send(s).await.unwrap();

    // a drop faster than 10 %/day is rejected by the engine
    let err = send(high * U256::from(8u64) / U256::from(10u64))
        .await
        .unwrap_err();
    let sel = alloy::hex::encode(&keccak256("SigmaDropTooFast(uint256,uint256,uint256)")[..4]);
    assert!(
        err.contains(&sel),
        "expected SigmaDropTooFast (0x{sel}), got {err}"
    );
    assert_eq!(e.sigma(asset, t).call().await.unwrap(), high);
    println!(
        "engine {engine}: σ {high} accepted, planned {s} accepted, 0.8× rejected ({})",
        err.lines().next().unwrap_or("")
    );
}
