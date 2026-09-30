//! S4 H edge case K-02 (make backend-edge, infra half): the keeper restarted between **every** pair of steps of a
//! whole closure cycle, on BE-chain's `DeployCoreLocal` on anvil (the real market, pool and auction house; the
//! Solidity stand-in engine with an injected weekend safe LTV, premium and a zero joint column) and the real
//! XNYS calendar, with anvil time warp:
//!
//!   Fri 09:31 ET  deploy; the post-deploy REOPEN ends (J5 completeReopen); Priya (74.4 %, auto-cover) and Dev
//!                 (70 %) borrow against tNVDA at $180
//!   Fri 14:00 ET  J9 openEpoch; J2 heads-ups
//!   Fri 15:45 ET  J9 snapshotEpoch; J3 enforceBell (Priya auto-covered)
//!   Mon 09:30 ET  the open print at $144 (−20 %): J5 flags both, fixLots at +2:00, clear at +7:00 with no bids
//!                 (the pool takes the whole lot, K-09), settlePositions, completeReopen; J9 settleEpoch; J11 resale
//!
//! Every tick runs on a **brand-new** `Keeper` (new `TxManager`, new in-memory state): only Postgres survives, as
//! after a crash between two steps. At the end every step's key is done, each mined exactly once, and no keeper
//! tx reverted. Needs anvil, forge, `contracts/out` and `TEST_DATABASE_URL`.

mod common;

use common::*;
use credence_keeper::core::abi::ICredenceMarket;

#[tokio::test]
#[ignore = "needs anvil, forge, contracts/out and TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_k02_restart_between_every_step_of_a_closure_cycle() {
    let mut s = deploy("credence_keeper_edge_restart").await;
    let t0 = friday_reopen(&mut s).await - 150;
    let (d, id) = (s.d.clone(), s.id);

    // ── seeding: Priya above the weekend safe LTV (auto-cover on), Dev below it ──
    let t = t0 + 150;
    s.at(t, 180 * WAD, FRI_OPEN).await;
    let priya = borrow(&s, PRIYA, 500 * WAD, 67_000_000_000).await; // 74.4 %
    let dev = borrow(&s, DEV, 100 * WAD, 12_600_000_000).await; // 70 %

    // ── Friday afternoon: Bell window, bellAt, close; a restart before every tick ──
    for t in [
        FRI_CLOSE - 7_200 + 2,
        FRI_CLOSE - 7_200 + 30,
        FRI_CLOSE - 900 + 2,
        FRI_CLOSE - 900 + 20,
        FRI_CLOSE - 900 + 60,
        FRI_CLOSE - 900 + 120,
        FRI_CLOSE + 5,
    ] {
        s.at(t, 180 * WAD, FRI_OPEN).await;
        s.restart_and_tick().await;
    }

    // ── Monday: the open print at −20 %, then the REOPEN auction driven by restarted keepers ──
    s.at(MON_OPEN, 144 * WAD, MON_OPEN).await;
    for f in s.feeds {
        push(
            &d,
            f,
            s.nvda,
            credence_relayer::report::Kind::Open,
            MON_OPEN + 1,
            144 * WAD,
            MON_OPEN,
        )
        .await;
    }
    for dt in [
        3, 10, 30, 60, 100, 121, 125, 130, 200, 300, 421, 425, 430, 440, 460, 500, 600, 700, 900,
        1_200, 1_500, 1_800,
    ] {
        s.at(MON_OPEN + dt, 144 * WAD, MON_OPEN).await;
        s.restart_and_tick().await;
    }

    // ── every step happened, once ──
    let done = |v: Vec<(String, String)>| v.iter().filter(|(_, st)| st == "done").count();
    for (like, what) in [
        // (the pool snapshots the epoch itself at the Bell deadline, and the auction house ends a REOPEN whose
        // tranches all cleared, so neither J9 snapshot nor J5 completeReopen needs a keeper tx on this path)
        ("J9:%:open", "J9 openEpoch"),
        ("J3:%", "J3 enforceBell"),
        ("J5:NVDA:%:flag:%", "J5 flag"),
        ("J5:NVDA:%:fixLots:%", "J5 fixLots"),
        ("J5:NVDA:%:clear:%", "J5 clear"),
        ("J5:NVDA:%:settle:%", "J5 settlePositions"),
        ("J9:%:settle", "J9 settleEpoch"),
        ("J11:%", "J11 resale"),
    ] {
        let keys = s.keys(like).await;
        println!("{what}: {keys:?}");
        assert!(
            done(keys) >= 1,
            "{what} never completed across the restarts"
        );
    }
    let reverted: i64 =
        sqlx::query_scalar("select count(*) from ops.keeper_tx where status = 'reverted'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    assert_eq!(reverted, 0, "no keeper tx reverted");
    let dups: Vec<(String, i64)> = sqlx::query_as(
        "select job_key, count(*) from ops.keeper_tx where status = 'mined' and job_key not like 'J1:%'
          group by job_key having count(*) > 1",
    )
    .fetch_all(&s.db)
    .await
    .unwrap();
    assert!(dups.is_empty(), "a step mined twice: {dups:?}");
    let pos = ICredenceMarket::new(s.addr("/equity/market"), &d);
    for who in [priya, dev] {
        assert_eq!(
            pos.position(id, who).call().await.unwrap().auctionId,
            0,
            "{who} settled and out of the lot"
        );
    }
    assert_eq!(s.state().await, 0, "NVDA back in REGULAR after the REOPEN");
    println!("K-02: {} ticks, each on a new keeper", s.ticks);
}
