//! `VENDOR=redstone` (R-26: a public testnet publishes no Alpaca / Polygon price) against **recorded**
//! `redstone-primary-prod` packages (`tests/fixtures/redstone`, Mon 2026-09-28):
//!
//! * LIVE is the newest verified package median at or before now, and the node's LIVE filter takes it in REGULAR;
//! * no package in the lookback (a gateway outage, stale data) gives no LIVE observation, never an old price;
//! * STATUS follows the venue calendar;
//! * the R-26 guard: off dev chains the free vendors refuse to publish without a declared licence.

use std::{path::PathBuf, sync::Arc};

use credence_common::calendar::{Calendar, ClosureType, Session};
use credence_relayer::report::MarketStatus;
use credence_relayer::{
    asset::Asset,
    config::{check_r26, VendorKind},
    filter::{live_observation, FilterConfig, Rejection},
    vendor::{
        redstone::{
            aggregate, PackageSource, Recorded, RedStoneLive, PRIMARY_PROD_SIGNERS,
            PRIMARY_PROD_THRESHOLD,
        },
        MarketDataVendor, VendorMarket,
    },
};

const OPEN: u64 = 1_790_602_200; // Mon 2026-09-28 13:30:00Z
const CLOSE: u64 = 1_790_625_600; // 20:00:00Z

fn recorded() -> Arc<Recorded> {
    let d = PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/redstone"
    ));
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&d)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    paths.sort();
    let refs: Vec<&std::path::Path> = paths.iter().map(|p| p.as_path()).collect();
    Arc::new(Recorded::load(&refs, 0).unwrap())
}

fn calendar() -> Arc<Calendar> {
    Arc::new(
        Calendar::from_sessions(
            "XNAS",
            vec![Session {
                ext_open: OPEN - 19_800,
                open: OPEN,
                close: CLOSE,
                ext_close: CLOSE + 14_400,
                closure_type_after: ClosureType::Overnight,
            }],
        )
        .unwrap(),
    )
}

fn live_at(src: Arc<Recorded>, now: u64) -> RedStoneLive {
    let mut v = RedStoneLive::new(src, calendar(), None);
    v.now = Arc::new(move || now);
    v
}

fn nvda() -> Asset {
    Asset::parse("NVDA:XNAS").unwrap()
}

#[tokio::test]
async fn live_is_the_newest_verified_median_and_passes_the_regular_filter() {
    let src = recorded();
    // a recorded timestamp in the regular session, and "now" 7 s after it (between two 10-s slots)
    let ts = *src
        .timestamps()
        .iter()
        .find(|t| **t >= OPEN + 30 && **t < CLOSE)
        .expect("a recorded package in the session");
    let now = ts + 7;
    let want = aggregate(
        "NVDA",
        &src.at("NVDA", ts).await.unwrap().unwrap(),
        &PRIMARY_PROD_SIGNERS,
        PRIMARY_PROD_THRESHOLD,
    )
    .unwrap();
    let v = live_at(src, now);
    let input = v.live(&nvda(), 0).await.unwrap();
    assert_eq!(input.trades.len(), 1);
    assert_eq!(input.trades[0].price_wad, want.value_wad());
    assert_eq!(input.trades[0].ts_ns / 1_000_000_000, ts);
    let o = live_observation(MarketStatus::Regular, &input, now, &FilterConfig::default()).unwrap();
    assert_eq!(o.price_wad, want.value_wad());
    assert_eq!(o.observed_at, ts);
    assert_eq!(v.status(&nvda()).await.unwrap().market, VendorMarket::Open);
}

#[tokio::test]
async fn no_fresh_package_means_no_live_price() {
    let src = recorded();
    let last = *src.timestamps().iter().max().unwrap();
    // well past the recording: nothing in the lookback, so the node publishes nothing (fail closed)
    let now = last + 3_600;
    let v = live_at(src, now);
    let input = v.live(&nvda(), 0).await.unwrap();
    assert!(input.trades.is_empty() && input.nbbo.is_none());
    assert_eq!(
        live_observation(MarketStatus::Regular, &input, now, &FilterConfig::default()),
        Err(Rejection::NoEligibleTrade)
    );
    // a closed venue has no LIVE price even with fresh packages
    let closed = live_at(recorded(), CLOSE + 20_000);
    assert!(closed.live(&nvda(), 0).await.unwrap().trades.is_empty());
    // an unknown feed (an asset RedStone does not list, e.g. COIN) is the same
    let v = live_at(recorded(), OPEN + 60);
    assert!(v
        .live(&Asset::parse("COIN:XNAS").unwrap(), 0)
        .await
        .unwrap()
        .trades
        .is_empty());
}

#[tokio::test]
async fn status_follows_the_venue_calendar() {
    let at = |t: u64| live_at(recorded(), t);
    assert_eq!(
        at(OPEN - 3_600).status(&nvda()).await.unwrap().market,
        VendorMarket::Extended
    );
    assert_eq!(
        at(OPEN + 60).status(&nvda()).await.unwrap().market,
        VendorMarket::Open
    );
    assert_eq!(
        at(CLOSE + 20_000).status(&nvda()).await.unwrap().market,
        VendorMarket::Closed
    );
}

#[test]
fn r26_the_free_vendors_publish_on_dev_chains_or_with_a_licence_only() {
    for v in [VendorKind::Polygon, VendorKind::Alpaca] {
        assert!(check_r26(46_630, &v, false).is_err());
        assert!(check_r26(421_614, &v, false).is_err());
        assert!(check_r26(46_630, &v, true).is_ok());
        assert!(check_r26(412_346, &v, false).is_ok());
    }
    assert!(check_r26(46_630, &VendorKind::RedStone, false).is_ok());
    assert!(check_r26(46_630, &VendorKind::Replay, false).is_ok());
}
