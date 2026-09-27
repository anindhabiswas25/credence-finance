//! A real recorded session (Alpaca IEX history, Fri 2026-09-25 15:45–16:05 ET, NVDA + AAPL; recorded with
//! `credence-relayer record`) through the replay vendor and the LIVE filter.

use credence_relayer::{
    asset::Asset,
    filter::{live_observation, FilterConfig, ObsSource},
    price::{deviation_ppm, WAD},
    report::MarketStatus,
    vendor::{
        replay::{Event, Replay},
        MarketDataVendor,
    },
};

const FILE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/replay/XNYS-20260925-close-NVDA-AAPL-iex.jsonl"
);
/// 2026-09-25 15:55:00 ET (EDT) = 19:55:00Z
const T_1555: u64 = 1_790_366_100;

fn at_1555() -> u64 {
    T_1555 * 1_000_000_000
}

fn load() -> Replay {
    let events: Vec<Event> = std::fs::read_to_string(FILE)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let first = events
        .iter()
        .filter_map(|e| match e {
            Event::Market { t, .. }
            | Event::Trade { t, .. }
            | Event::Quote { t, .. }
            | Event::Halt { t, .. } => Some(*t),
            Event::Header { .. } => None,
        })
        .min()
        .unwrap();
    // identity warp: recording time == "wall" time, pinned at 15:55 ET
    Replay::from_events(events, 1.0, 31_337, first)
        .unwrap()
        .with_clock(at_1555)
}

#[tokio::test]
async fn recorded_session_yields_filtered_live_prices() {
    let r = load();
    let s = r.calendar().sessions[0];
    assert_eq!(s.close, 1_790_366_400, "16:00 ET close");
    assert_eq!(
        r.calendar().window_at(T_1555),
        credence_common::calendar::Window::Regular
    );
    for (spec, lo, hi) in [("NVDA:XNAS", 200u128, 260u128), ("AAPL:XNAS", 150, 400)] {
        let a = Asset::parse(spec).unwrap();
        let input = r.live(&a, (T_1555 - 60) * 1_000_000_000).await.unwrap();
        assert!(
            !input.trades.is_empty(),
            "{spec}: trades in the last minute"
        );
        let q = input.nbbo.clone().expect("NBBO");
        let o = live_observation(
            MarketStatus::Regular,
            &input,
            T_1555,
            &FilterConfig::default(),
        )
        .unwrap();
        assert_eq!(o.source, ObsSource::Trade);
        assert!(
            o.price_wad > lo * WAD && o.price_wad < hi * WAD,
            "{spec}: {}",
            o.price_wad
        );
        assert!(
            deviation_ppm(o.price_wad, q.mid().unwrap()) <= 5_000,
            "{spec}: within 0.5% of the NBBO mid"
        );
        assert!(T_1555 - o.observed_at <= 60);
        let st = r.status(&a).await.unwrap();
        assert_eq!(st.market, credence_relayer::vendor::VendorMarket::Open);
    }
}
