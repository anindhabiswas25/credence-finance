//! S4 H edge case R-10 (make backend-edge): a signer node's market status and session date on the odd days of
//! the real XNYS calendar (Thanksgiving, the day-after early close, the DST switch). The vendor below claims the
//! market is open at every instant, as a stale or wrong vendor might: the calendar must still decide.

use alloy::primitives::Address;
use async_trait::async_trait;
use credence_common::{
    calendar::{Calendar, Session},
    signer::CredenceSigner,
};
use credence_relayer::{
    asset::Asset,
    filter::FilterConfig,
    metrics::Metrics,
    node::{Node, NodeConfig},
    report::{domain, MarketStatus},
    vendor::{
        HaltInfo, LiveInput, MarketDataVendor, OfficialPrint, StatusInput, VendorError,
        VendorMarket, VendorResult,
    },
};
use std::{sync::Arc, time::Duration};

struct AlwaysOpen;

#[async_trait]
impl MarketDataVendor for AlwaysOpen {
    fn name(&self) -> &'static str {
        "always-open"
    }
    async fn live(&self, _a: &Asset, _s: u64) -> VendorResult<LiveInput> {
        Err(VendorError::Other("no trades in this test".into()))
    }
    async fn official_open(&self, _a: &Asset, _s: &Session) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn official_close(
        &self,
        _a: &Asset,
        _s: &Session,
    ) -> VendorResult<Option<OfficialPrint>> {
        Ok(None)
    }
    async fn status(&self, _a: &Asset) -> VendorResult<StatusInput> {
        Ok(StatusInput {
            market: VendorMarket::Open,
            halt: Some(HaltInfo {
                halted: false,
                reason: None,
            }),
        })
    }
}

fn xnys() -> Arc<Calendar> {
    Arc::new(
        Calendar::load(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../calibration/out/calendars/XNYS-20261001-20271031.json"
        ))
        .unwrap(),
    )
}

/// The node's (status, session date) at the fixed time `clock()`.
async fn observe(clock: fn() -> u64) -> (MarketStatus, u64) {
    let asset = Asset::parse("NVDA:XNAS").unwrap();
    let n = Node::new(
        NodeConfig {
            id: "n".into(),
            assets: vec![asset],
            poll_interval: Duration::from_secs(60),
            print_poll_interval: Duration::from_secs(60),
            filter: FilterConfig::default(),
            auth_token: None,
        },
        Arc::new(AlwaysOpen),
        xnys(),
        CredenceSigner::Local(
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
                .parse()
                .unwrap(),
        ),
        domain(412_346, Address::repeat_byte(0xfe)),
        Metrics::detached(),
    )
    .with_clock(clock);
    n.poll_once().await;
    let snap = n.snapshot().await;
    let st = snap.assets[0]
        .status
        .as_ref()
        .expect("a status observation");
    (st.status, st.session_date)
}

// session dates = floor(regular open UTC / 86 400)
const FRI_1030: u64 = 1_793_367_000 / 86_400;
const MON_1102: u64 = 1_793_629_800 / 86_400;
const FRI_1127: u64 = 1_795_789_800 / 86_400;

#[tokio::test]
async fn edge_r10_dst_switch_same_utc_time_regular_before_pre_market_after() {
    // 14:00Z = 10:00 EDT on Fri 2026-10-30 (regular) but 09:00 EST on Mon 2026-11-02 (pre-market)
    assert_eq!(
        observe(|| 1_793_368_800).await,
        (MarketStatus::Regular, FRI_1030)
    );
    let (st, sd) = observe(|| 1_793_628_000).await;
    assert!(st.is_extended() && st != MarketStatus::Regular, "{st:?}");
    assert_eq!(sd, MON_1102);
}

#[tokio::test]
async fn edge_r10_thanksgiving_is_not_regular_whatever_the_vendor_says() {
    // Thu 2026-11-26 17:00Z (noon ET): no regular session; the vendor's "open" is overruled
    let (st, _) = observe(|| 1_795_712_400).await;
    assert_ne!(st, MarketStatus::Regular, "Thanksgiving noon: {st:?}");
}

#[tokio::test]
async fn edge_r10_early_close_ends_regular_at_13_00_et() {
    // Fri 2026-11-27: regular at 17:30Z (12:30 ET), no longer regular at 18:30Z (13:30 ET, after the early close)
    assert_eq!(
        observe(|| 1_795_800_600).await,
        (MarketStatus::Regular, FRI_1127)
    );
    let (st, sd) = observe(|| 1_795_804_200).await;
    assert_ne!(
        st,
        MarketStatus::Regular,
        "after the 13:00 ET early close: {st:?}"
    );
    assert_eq!(sd, FRI_1127);
}
