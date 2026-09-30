//! S5 B keeper edge cases on `DeployCoreLocal` + anvil (make backend-edge-infra), each on its own chain and
//! scratch database, driven by a brand-new keeper per tick (tests/common):
//!
//! * **RPC failover**: the primary RPC down through the Bell (every read and tx on the fallback), back up (the
//!   primary again), then stuck 100 blocks behind (two RPCs disagreeing on the head: the stale one is skipped);
//! * **K-05** an RPC error mid-batch: batch 2's broadcast answer is lost (the tx is mined, the keeper never
//!   hears), and the next batch hits the nonce it used: every borrower enforced once, nothing mined twice;
//! * **K-06** a position fixed between J3's pre-check and its tx: the chain skips it, the keeper is done;
//! * **K-07** a Bell with 0 positions (nothing sent) and with 36 (4 batches, all mined before the PRECLOSE
//!   fixing), and a pre-close candidate that appears after the guard time: held and paged, never sent.

mod common;

use alloy::{
    primitives::{Address, U256},
    providers::Provider,
};
use common::{fault_proxy::*, *};
use credence_keeper::core::abi::ICredenceMarket;

const BELL_WINDOW: u64 = FRI_CLOSE - 7_200;
const BELL_AT: u64 = FRI_CLOSE - 900;

/// The common stack with a $1 premium: these tests use small loans ($1,340), and the stand-in engine's fixed
/// $35.95 would push them past the coverable LTV (the Bell would then sell instead of covering).
async fn setup(db: &str) -> Stack {
    let s = deploy(db).await;
    IMockEngine::new(s.addr("/shared/riskEngine"), &s.d)
        .setQuote(
            U256::from(1_000_000u64),
            U256::from(500_000u64),
            U256::from(1_000_000u64),
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    s
}

/// A borrower at 74.4 % LTV at $180 (above the weekend safe LTV; auto-cover on).
async fn at_744(s: &Stack) -> (Address, String) {
    let key = funded_key(s).await;
    (borrow(s, &key, 10 * WAD, 1_340_000_000).await, key)
}

async fn pos(s: &Stack, who: Address) -> ICredenceMarket::Position {
    ICredenceMarket::new(s.addr("/equity/market"), &s.d)
        .position(s.id, who)
        .call()
        .await
        .unwrap()
}

async fn count(s: &Stack, q: &'static str) -> i64 {
    sqlx::query_scalar(q).fetch_one(&s.db).await.unwrap()
}

/// No keeper tx reverted and no job key mined twice.
async fn nothing_twice(s: &Stack) {
    assert_eq!(
        count(
            s,
            "select count(*) from ops.keeper_tx where status = 'reverted'"
        )
        .await,
        0,
        "a keeper tx reverted"
    );
    let dups: Vec<(String, i64)> = sqlx::query_as(
        "select job_key, count(*) from ops.keeper_tx where status = 'mined' and job_key not like 'J1:%'
          group by job_key having count(*) > 1",
    )
    .fetch_all(&s.db)
    .await
    .unwrap();
    assert!(dups.is_empty(), "a step mined twice: {dups:?}");
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_rpc_failover_primary_down_back_up_and_stale_head() {
    let mut s = setup("credence_keeper_edge_rpc").await;
    let proxy = FaultProxy::start(&s.rpc).await;
    s.rpcs = vec![proxy.url.clone(), s.rpc.clone()];
    let t = friday_reopen(&mut s).await;
    s.at(t, 180 * WAD, FRI_OPEN).await;
    let (priya, _) = at_744(&s).await;

    // the primary is down for the whole Bell: J9, J2 and J3 run on the fallback
    proxy.set(Mode::Down);
    for t in [BELL_WINDOW + 2, BELL_AT + 2, BELL_AT + 20] {
        s.at(t, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    assert!(
        (pos(&s, priya).await.coverClosureId != 0),
        "auto-covered through the fallback"
    );
    assert_eq!(s.keys("J3:%").await.len(), 1);

    // back up: the next tick reads through the primary again
    proxy.set(Mode::Up);
    let c = proxy.calls("eth_call");
    s.at(BELL_AT + 60, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    assert!(
        proxy.calls("eth_call") > c,
        "the primary is used again once healthy"
    );

    // the primary answers but is stuck 40 blocks behind the fallback (> the 32-block lag): skipped
    let head = s.d.get_block_number().await.unwrap();
    assert!(head > 40, "deploy mined enough blocks for a stale head");
    proxy.set(Mode::FrozenHead(head - 40));
    let c = proxy.calls("eth_call");
    s.at(BELL_AT + 120, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    assert_eq!(proxy.calls("eth_call"), c, "no read from the stale primary");
    // and within the lag it's fine again
    proxy.set(Mode::FrozenHead(s.d.get_block_number().await.unwrap() - 10));
    let c = proxy.calls("eth_call");
    s.at(BELL_AT + 180, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    assert!(
        proxy.calls("eth_call") > c,
        "10 blocks behind is within the lag"
    );
    nothing_twice(&s).await;
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_k05_rpc_error_mid_batch_is_retried_nothing_twice() {
    let mut s = setup("credence_keeper_edge_k05").await;
    let proxy = FaultProxy::start(&s.rpc).await;
    s.rpcs = vec![proxy.url.clone()]; // no fallback: the fault is not masked
    s.j3_batch = Some(2);
    let t = friday_reopen(&mut s).await;
    s.at(t, 180 * WAD, FRI_OPEN).await;
    let mut who = Vec::new();
    for _ in 0..5 {
        who.push(at_744(&s).await.0);
    }
    s.at(BELL_WINDOW + 2, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;

    // 3 batches; the answer to batch 2's broadcast is lost (mined, unknown to the keeper)
    let sends = proxy.calls("eth_sendRawTransaction");
    proxy.lose("eth_sendRawTransaction", 1);
    s.at(BELL_AT + 2, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    assert!(proxy.calls("eth_sendRawTransaction") >= sends + 2);
    // then receipts fail for a while: the keeper can't confirm anything, and must not resend
    proxy.fail("eth_getTransactionReceipt", 3);
    s.at(BELL_AT + 20, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    // retries run on the jobs' back-off (wall clock: 10 s after a first failure)
    for i in 0..4 {
        tokio::time::sleep(std::time::Duration::from_secs(11)).await;
        s.at(BELL_AT + 60 + 30 * i, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    for w in &who {
        assert!(pos(&s, *w).await.coverClosureId != 0, "{w} auto-covered");
    }
    let j3 = count(
        &s,
        "select count(*) from ops.keeper_tx where job_key like 'J3:%' and status = 'mined'",
    )
    .await;
    println!(
        "K-05: {j3} J3 txs mined for 5 borrowers in batches of 2; keys {:?}",
        s.keys("J3:%").await
    );
    assert!(j3 <= 3, "no borrower enforced twice (at most 3 batches)");
    nothing_twice(&s).await;
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_k06_position_closed_between_precheck_and_tx() {
    let mut s = setup("credence_keeper_edge_k06").await;
    let proxy = FaultProxy::start(&s.rpc).await;
    s.rpcs = vec![proxy.url.clone()];
    let t = friday_reopen(&mut s).await;
    s.at(t, 180 * WAD, FRI_OPEN).await;
    let (a, a_key) = at_744(&s).await;
    let (b, _) = at_744(&s).await;
    s.at(BELL_WINDOW + 2, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;

    // J3 has planned [a, b]; while its tx waits at the RPC, `a` repays in full
    let mut gate = proxy.gate("eth_sendRawTransaction");
    let (rpc, market, usdc, id) = (
        s.rpc.clone(),
        s.addr("/equity/market"),
        s.addr("/tokens/usdc"),
        s.id,
    );
    let closer = tokio::spawn(async move {
        let release = gate.recv().await.unwrap();
        // from a's own wallet: the deployer is the keeper's account, and its tx holds the next nonce
        let w = provider(&rpc, &a_key).await;
        IMintable::new(usdc, &w)
            .mint(a, U256::from(1_000_000_000u64))
            .send()
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        IMintable::new(usdc, &w)
            .approve(market, U256::MAX)
            .send()
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        let m = ICredenceMarket::new(market, &w);
        let shares = m.position(id, a).call().await.unwrap().borrowShares;
        let r = m
            .repay(id, a, U256::ZERO, U256::from(shares))
            .send()
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        assert!(r.status(), "repay");
        release.send(()).unwrap();
    });
    s.at(BELL_AT + 2, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    closer.await.unwrap();

    let pa = pos(&s, a).await;
    assert_eq!(pa.borrowShares, 0, "a closed its loan");
    assert_eq!(pa.coverClosureId, 0, "no premium on a closed position");
    assert!(
        pos(&s, b).await.coverClosureId != 0,
        "b auto-covered in the same batch"
    );
    // later ticks: nothing left to do, nothing re-sent
    for dt in [30, 90, 200] {
        s.at(BELL_AT + dt, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    let j3 = count(
        &s,
        "select count(*) from ops.keeper_tx where job_key like 'J3:%'",
    )
    .await;
    assert_eq!(j3, 1, "one J3 tx, no retry loop");
    nothing_twice(&s).await;
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_k07_bell_with_0_positions_sends_nothing() {
    let mut s = setup("credence_keeper_edge_k07_zero").await;
    let t = friday_reopen(&mut s).await;
    s.at(t, 180 * WAD, FRI_OPEN).await;
    for t in [BELL_WINDOW + 2, BELL_AT + 2, BELL_AT + 60, FRI_CLOSE - 100] {
        s.at(t, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    assert_eq!(
        count(
            &s,
            "select count(*) from ops.keeper_tx where job_key like 'J3:%'"
        )
        .await,
        0
    );
    assert!(s.keys("J3:%").await.is_empty());
}

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_k07_bell_with_36_positions_and_a_late_preclose_candidate() {
    let mut s = setup("credence_keeper_edge_k07").await;
    let t = friday_reopen(&mut s).await;
    s.at(t, 180 * WAD, FRI_OPEN).await;

    // 36 NEEDS_ACTION positions: 4 batches (10 + 10 + 10 + 6), all mined before the PRECLOSE fixing; and one at
    // 70 % with auto-cover off, SAFE until the price drops at close − 5:30
    let mut who = Vec::new();
    for _ in 0..36 {
        who.push(at_744(&s).await.0);
    }
    let late_key = funded_key(&s).await;
    let w = provider(&s.rpc, &late_key).await;
    ICredenceMarket::new(s.addr("/equity/market"), &w)
        .setAutoCover(s.id, false)
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let late = borrow(&s, &late_key, 10 * WAD, 1_260_000_000).await;
    s.at(BELL_WINDOW + 2, 180 * WAD, FRI_OPEN).await;
    s.restart_and_tick().await;
    for dt in [30, 60] {
        s.at(BELL_AT + dt, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }
    for w in &who {
        assert!(pos(&s, *w).await.coverClosureId != 0, "{w} auto-covered");
    }
    let blocks: Vec<i64> = sqlx::query_scalar(
        "select mined_block from ops.keeper_tx where job_key like 'J3:%' and status = 'mined'",
    )
    .fetch_all(&s.db)
    .await
    .unwrap();
    assert_eq!(blocks.len(), 4, "36 borrowers in batches of 10");
    for b in blocks {
        let ts =
            s.d.get_block_by_number((b as u64).into())
                .await
                .unwrap()
                .unwrap()
                .header
                .timestamp;
        assert!(
            ts < FRI_CLOSE - 300,
            "J3 batch mined at {ts}, after the fixing"
        );
    }

    // $180 → $170 at close − 5:30: `late` (70 % → 74.1 %, auto-cover off) now needs a pre-close sale, but it is
    // past the guard: held and paged once, never sent
    let mut pages = Vec::new();
    for dt in [330, 320, 310, 250, 100] {
        s.at(FRI_CLOSE - dt, 170 * WAD, FRI_OPEN).await;
        pages.extend(s.restart_and_tick().await.alerts);
    }
    let held: Vec<_> = pages
        .iter()
        .filter(|a| a.contains("held out of J3"))
        .collect();
    assert_eq!(held.len(), 1, "paged once: {pages:?}");
    let p = pos(&s, late).await;
    assert_eq!(p.lastBellClosureId, 0, "never sent to enforceBell");
    assert_eq!(p.auctionId, 0, "not in a pre-close lot");
    assert_eq!(
        count(
            &s,
            "select count(*) from ops.keeper_tx where job_key like 'J3:%'"
        )
        .await,
        4
    );
    nothing_twice(&s).await;
}
