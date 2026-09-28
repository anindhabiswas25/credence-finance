//! `PRINT_SOURCE=redstone` (ADR-0009 D1) against **recorded** RedStone `redstone-primary-prod`
//! packages (`tests/fixtures/redstone`, gateway history of Mon 2026-09-28):
//!
//! * every recorded package verifies like the on-chain connector (authorised signer recovered from
//!   the documented byte layout; ≥ 3 of 5 per timestamp);
//! * the regular feed is frozen before the open, at Friday's close (checked against the recorded
//!   Alpaca IEX session of Fri 2026-09-25 in `fixtures/replay`);
//! * OPEN = the first package at or after open + 5 s that differs from the prior close, flagged
//!   `OracleFirstRegular`; CLOSE = the last package before close + 60 s;
//! * the same recording shifted onto another calendar (a devnode's synthetic session) gives the same
//!   prices at shifted times.

use std::{path::PathBuf, sync::Arc};

use async_trait::async_trait;
use credence_common::calendar::{ClosureType, Session};
use credence_relayer::{
    asset::Asset,
    vendor::{
        redstone::{
            aggregate, PackageSource, Recorded, RedStonePrints, PRIMARY_PROD_SIGNERS,
            PRIMARY_PROD_THRESHOLD,
        },
        LiveInput, MarketDataVendor, OfficialPrint, PrintSource, StatusInput, VendorResult,
    },
};

const OPEN: u64 = 1_790_602_200; // Mon 2026-09-28 13:30:00Z
const CLOSE: u64 = 1_790_625_600; // 20:00:00Z
const FEEDS: [&str; 4] = ["NVDA", "AAPL", "TSLA", "MSFT"];

fn fixtures() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures"))
}

fn recordings() -> Vec<PathBuf> {
    let d = fixtures().join("redstone");
    let mut v: Vec<PathBuf> = std::fs::read_dir(&d)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    v.sort();
    v
}

fn recorded(shift: i64) -> Recorded {
    let paths = recordings();
    let refs: Vec<&std::path::Path> = paths.iter().map(|p| p.as_path()).collect();
    Recorded::load(&refs, shift).unwrap()
}

fn has_close() -> bool {
    recorded(0).timestamps().iter().any(|t| *t >= CLOSE)
}

struct NoData;
#[async_trait]
impl MarketDataVendor for NoData {
    fn name(&self) -> &'static str {
        "none"
    }
    async fn live(&self, _: &Asset, _: u64) -> VendorResult<LiveInput> {
        Ok(LiveInput::default())
    }
    async fn official_open(&self, _: &Asset, _: &Session) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn official_close(&self, _: &Asset, _: &Session) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn status(&self, _: &Asset) -> VendorResult<StatusInput> {
        unimplemented!()
    }
}

fn session(shift: i64) -> Session {
    Session {
        ext_open: (OPEN as i64 + shift) as u64 - 19_800,
        open: (OPEN as i64 + shift) as u64,
        close: (CLOSE as i64 + shift) as u64,
        ext_close: (CLOSE as i64 + shift) as u64 + 14_400,
        closure_type_after: ClosureType::Overnight,
    }
}

fn prints(shift: i64, now: u64) -> RedStonePrints {
    let mut p = RedStonePrints::new(Arc::new(NoData), Arc::new(recorded(shift)));
    p.shift_s = shift;
    p.now = Arc::new(move || now);
    p
}

fn asset(sym: &str) -> Asset {
    Asset::parse(&format!("{sym}:XNAS")).unwrap()
}

#[tokio::test]
async fn every_recorded_package_verifies_like_the_connector() {
    let r = recorded(0);
    let ts = r.timestamps();
    assert!(ts.len() >= 19, "recorded snapshots: {}", ts.len());
    for t in &ts {
        for f in FEEDS {
            let pkgs = r.at(f, *t).await.unwrap().expect("packages");
            let a = aggregate(f, &pkgs, &PRIMARY_PROD_SIGNERS, PRIMARY_PROD_THRESHOLD)
                .unwrap_or_else(|| panic!("{f}@{t}: fewer than 3 authorised signers"));
            assert_eq!(a.signers.len(), 5, "{f}@{t}: all five nodes signed");
            assert_eq!(a.at(), *t);
            // a tampered value no longer recovers an authorised signer
            let mut bad = pkgs.clone();
            for p in &mut bad {
                p.data_points[0].value = serde_json::from_str("1.23").unwrap();
            }
            assert!(aggregate(f, &bad, &PRIMARY_PROD_SIGNERS, 1).is_none());
        }
    }
}

#[tokio::test]
async fn the_feed_is_frozen_before_the_open_at_fridays_close() {
    let r = recorded(0);
    // Friday's last regular trades in the recorded Alpaca IEX session (fixtures/replay)
    let iex_last = [("NVDA", 225.04_f64), ("AAPL", 341.02_f64)];
    for f in FEEDS {
        let mut vals = Vec::new();
        for t in (OPEN - 60..OPEN).step_by(10) {
            let p = r.at(f, t).await.unwrap().unwrap();
            vals.push(aggregate(f, &p, &PRIMARY_PROD_SIGNERS, 3).unwrap().value8);
        }
        assert!(vals.windows(2).all(|w| w[0] == w[1]), "{f}: {vals:?}");
        if let Some((_, px)) = iex_last.iter().find(|(s, _)| *s == f) {
            let v = vals[0] as f64 / 1e8;
            assert!(
                (v / px - 1.0).abs() < 5e-4,
                "{f}: frozen {v} vs Friday close {px}"
            );
        }
    }
}

/// Medians at open + 10 s (the first grid point at or after open + 5 s; every feed moved at 13:30:00).
const EXPECTED_OPEN: [(&str, u128); 4] = [
    ("NVDA", 23_001_587_739),
    ("AAPL", 34_129_000_404),
    ("TSLA", 36_836_958_829),
    ("MSFT", 50_477_976_531),
];

#[tokio::test]
async fn open_is_the_first_package_after_open_plus_5s_that_moved() {
    let p = prints(0, OPEN + 3600);
    for (f, want) in EXPECTED_OPEN {
        let o = p
            .official_open(&asset(f), &session(0))
            .await
            .unwrap()
            .expect("open print");
        assert_eq!(o.source, PrintSource::OracleFirstRegular);
        assert_eq!(o.at, OPEN + 10, "{f}");
        let prior = p.prior_close(f, OPEN).await.unwrap().unwrap();
        assert_ne!(
            o.price_wad,
            prior.value_wad(),
            "{f}: differs from the prior close"
        );
        assert_eq!(o.price_wad, want * 10u128.pow(10), "{f}");
    }
    // not before the data exists
    let early = prints(0, OPEN + 4);
    assert!(early
        .official_open(&asset("NVDA"), &session(0))
        .await
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn a_shifted_recording_prints_the_same_prices_on_another_calendar() {
    let shift = -86_400 * 30; // e.g. a synthetic devnode session a month earlier
    let p0 = prints(0, OPEN + 3600);
    let p1 = prints(shift, (OPEN as i64 + shift) as u64 + 3600);
    for f in FEEDS {
        let a = p0
            .official_open(&asset(f), &session(0))
            .await
            .unwrap()
            .unwrap();
        let b = p1
            .official_open(&asset(f), &session(shift))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(a.price_wad, b.price_wad);
        assert_eq!(b.at as i64, a.at as i64 + shift);
    }
}

#[tokio::test]
async fn close_is_the_last_package_before_close_plus_60s() {
    if !has_close() {
        eprintln!("no close recording yet: skipped");
        return;
    }
    let p = prints(0, CLOSE + 3600);
    let r = recorded(0);
    for f in FEEDS {
        let c = p
            .official_close(&asset(f), &session(0))
            .await
            .unwrap()
            .expect("close print");
        assert_eq!(c.source, PrintSource::OracleFirstRegular);
        assert_eq!(c.at, CLOSE + 50, "{f}");
        let pk = r.at(f, CLOSE + 50).await.unwrap().unwrap();
        let a = aggregate(f, &pk, &PRIMARY_PROD_SIGNERS, 3).unwrap();
        assert_eq!(c.price_wad, a.value_wad());
    }
    // not final until close + 60 s
    assert!(prints(0, CLOSE + 59)
        .official_close(&asset("NVDA"), &session(0))
        .await
        .unwrap()
        .is_none());
}
