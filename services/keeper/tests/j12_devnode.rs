//! J12 Stylus activation check on the nitro devnode (anvil has no Stylus), run with `make keeper-j12-e2e`:
//! `shared.riskEngine` is the Solidity RiskEngineRouter (ADR-0108), so J12 checks its two Stylus programs
//! (`pricing()`, `auction()`): both gauges are set with no alert (S4 A: the router itself used to raise a
//! false "programTimeLeft 0 days"), and an address that is not an activated program raises the
//! `stylus-activation` alert. Needs `make infra-up db-migrate` and an engine on the devnode
//! (`make devnode-deploy-engine`).

use alloy::{network::EthereumWallet, primitives::Address, signers::local::PrivateKeySigner};
use credence_keeper::{
    bindings::{IArbWasm, ARB_WASM},
    clock::ManualClock,
    config::book_address,
    metrics::Metrics,
    rpc::Rpc,
    tasks::Keeper,
    tx::TxManager,
};
use std::{path::PathBuf, sync::Arc};

const NITRO_DEV_KEY: &str = "0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659";

fn keeper(rpc_url: &str, programs: Vec<(String, Address)>, metrics: &Metrics) -> Keeper {
    let rpc = Arc::new(Rpc::connect(&[rpc_url.to_string()], None).unwrap());
    let signer: PrivateKeySigner = NITRO_DEV_KEY.parse().unwrap();
    let tx = TxManager::new(
        rpc.clone(),
        EthereumWallet::from(signer.clone()),
        signer.address(),
        412_346,
        metrics.clone(),
    );
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut k = Keeper::new(
        "j12-e2e".into(),
        rpc,
        tx,
        Address::ZERO,
        vec![],
        Arc::new(ManualClock::new(now)),
        metrics.clone(),
        900,
    );
    k.stylus_programs = programs;
    k
}

#[tokio::test]
#[ignore = "needs the nitro devnode with the Risk Engine and TEST_DATABASE_URL (make keeper-j12-e2e)"]
async fn j12_reads_program_time_left_from_the_address_book() {
    std::env::set_current_dir(PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../..")))
        .unwrap();
    let rpc_url = std::env::var("DEVNODE_RPC").unwrap_or_else(|_| "http://127.0.0.1:8547".into());
    let engine = book_address(412_346, "RISK_ENGINE_ADDRESS", "/shared/riskEngine")
        .unwrap()
        .expect("shared.riskEngine in deployments/412346.local.json (make devnode-deploy-engine)");

    let admin = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
    let url = credence_common::db::scratch_database(&admin, "credence_keeper_j12")
        .await
        .unwrap();
    let pool = credence_common::db::connect(&url, 2).await.unwrap();

    // the precompile directly, for the expected values: the router is not a program, its two targets are
    let p = alloy::providers::ProviderBuilder::new().connect_http(rpc_url.parse().unwrap());
    assert!(
        IArbWasm::new(ARB_WASM, &p)
            .programTimeLeft(engine)
            .call()
            .await
            .is_err(),
        "shared.riskEngine should be the Solidity router (ADR-0108), not a program"
    );
    let router = credence_keeper::bindings::IRiskEngineRouter::new(engine, &p);
    let programs = [
        ("riskEngine.pricing", router.pricing().call().await.unwrap()),
        (
            "riskEngine.auctionMath",
            router.auction().call().await.unwrap(),
        ),
    ];
    let metrics = Metrics::detached();
    let k = keeper(&rpc_url, vec![("riskEngine".into(), engine)], &metrics);
    let mut conn = pool.acquire().await.unwrap();
    let rep = k.tick(&mut conn).await.unwrap();
    for (label, program) in programs {
        let direct = IArbWasm::new(ARB_WASM, &p)
            .programTimeLeft(program)
            .call()
            .await
            .unwrap();
        assert!(
            direct > 30 * 86_400,
            "{label} should be freshly activated, got {direct} s"
        );
        let got = metrics.program_time_left.with_label_values(&[label]).get() as u64;
        assert!(
            got <= direct && direct - got < 3_600,
            "{label}: gauge {got} vs precompile {direct}"
        );
        println!(
            "{label} {program}: programTimeLeft {got} s ({} days)",
            got / 86_400
        );
    }
    assert!(
        rep.alerts.iter().all(|a| !a.contains("stylus")),
        "{:?}",
        rep.alerts
    );

    // 2. an address that is not an activated program: time left 0 and a P2 alert (fresh DB, so J12 runs again)
    let url2 = credence_common::db::scratch_database(&admin, "credence_keeper_j12b")
        .await
        .unwrap();
    let pool2 = credence_common::db::connect(&url2, 2).await.unwrap();
    let metrics2 = Metrics::detached();
    let k2 = keeper(
        &rpc_url,
        vec![("bogus".into(), Address::with_last_byte(1))],
        &metrics2,
    );
    let rep = k2.tick(&mut pool2.acquire().await.unwrap()).await.unwrap();
    assert_eq!(
        metrics2
            .program_time_left
            .with_label_values(&["bogus"])
            .get(),
        0
    );
    assert!(
        rep.alerts.iter().any(|a| a.contains("stylus-activation")),
        "{:?}",
        rep.alerts
    );
}
