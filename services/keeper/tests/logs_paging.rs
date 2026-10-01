//! `Rpc::logs_paged` against mock JSON-RPC servers (01:20 PM REQUEST: Alchemy's free plan refuses `eth_getLogs` over
//! more than 10 blocks and the auction driver failed every minute):
//!
//! * a provider that refuses the range drops to the 10-block windows and covers the span;
//! * the call budget leaves the rest to the caller's cursor;
//! * a catch-up larger than the small provider's windows goes to a wide provider first; any other error fails over;
//! * nothing covered is an error.

use std::sync::{Arc, Mutex};

use alloy::rpc::types::Filter;
use axum::{routing::post, Json, Router};
use credence_keeper::rpc::Rpc;
use serde_json::{json, Value};

#[derive(Clone, Copy)]
enum Mode {
    /// Alchemy free: more than 10 blocks is refused.
    Max10,
    Wide,
    Down,
}

type Calls = Arc<Mutex<Vec<(u64, u64)>>>;

fn hex(v: &Value) -> u64 {
    u64::from_str_radix(v.as_str().unwrap().trim_start_matches("0x"), 16).unwrap()
}

async fn server(mode: Mode) -> (String, Calls) {
    let calls: Calls = Default::default();
    let c = calls.clone();
    let app = Router::new().route(
        "/",
        post(move |Json(req): Json<Value>| {
            let c = c.clone();
            async move {
                let id = req["id"].clone();
                let f = &req["params"][0];
                let (from, to) = (hex(&f["fromBlock"]), hex(&f["toBlock"]));
                c.lock().unwrap().push((from, to));
                Json(match mode {
                    Mode::Max10 if to - from + 1 > 10 => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32600,
                        "message":"Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range."}}),
                    Mode::Down => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":"internal error"}}),
                    _ => json!({"jsonrpc":"2.0","id":id,"result":[]}),
                })
            }
        }),
    );
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
    (url, calls)
}

#[tokio::test]
async fn a_refused_range_pages_in_10_block_windows_within_the_budget() {
    let (url, calls) = server(Mode::Max10).await;
    let rpc = Rpc::connect(&[url], None).unwrap();
    let (_, to) = rpc.logs_paged(&Filter::new(), 100, 135).await.unwrap();
    assert_eq!(to, 135);
    let c = calls.lock().unwrap().clone();
    // the wide ask is refused once, then 4 windows of ≤ 10 blocks
    assert_eq!(c[0], (100, 135));
    assert_eq!(&c[1..], &[(100, 109), (110, 119), (120, 129), (130, 135)]);

    // the budget: 2 calls cover 2 windows, the cursor keeps the rest
    let rpc = rpc.with_logs_paging(10_000, 10, 2);
    calls.lock().unwrap().clear();
    let (_, to) = rpc.logs_paged(&Filter::new(), 100, 135).await.unwrap();
    assert_eq!(to, 119); // a refusal is not a window (with_logs_paging reset the learned range)
    let (_, to) = rpc.logs_paged(&Filter::new(), 120, 135).await.unwrap();
    assert_eq!(to, 135);
}

#[tokio::test]
async fn a_catch_up_goes_wide_first_and_errors_fail_over() {
    let (small, small_calls) = server(Mode::Max10).await;
    let (wide, wide_calls) = server(Mode::Wide).await;
    let rpc = Rpc::connect(&[small, wide], None).unwrap();
    // steady state (36 blocks): the primary, in 10-block windows
    rpc.logs_paged(&Filter::new(), 100, 135).await.unwrap();
    assert!(wide_calls.lock().unwrap().is_empty());
    // a catch-up of 5,000 blocks (> 30 windows of 10): the wide provider first, in one call
    small_calls.lock().unwrap().clear();
    let (_, to) = rpc.logs_paged(&Filter::new(), 1_000, 5_999).await.unwrap();
    assert_eq!(to, 5_999);
    assert!(small_calls.lock().unwrap().is_empty());
    assert_eq!(wide_calls.lock().unwrap().as_slice(), &[(1_000, 5_999)]);

    // the primary down: the next provider answers
    let (down, _) = server(Mode::Down).await;
    let (wide, wide_calls) = server(Mode::Wide).await;
    let rpc = Rpc::connect(&[down, wide], None).unwrap();
    assert_eq!(rpc.logs_paged(&Filter::new(), 1, 20).await.unwrap().1, 20);
    assert_eq!(wide_calls.lock().unwrap().as_slice(), &[(1, 20)]);

    // a provider that failed is tried last for the cooldown (one failure, not one per window)
    let (down, down_calls) = server(Mode::Down).await;
    let (small, _) = server(Mode::Max10).await;
    let rpc = Rpc::connect(&[down, small], None).unwrap();
    assert_eq!(rpc.logs_paged(&Filter::new(), 1, 50).await.unwrap().1, 50);
    assert_eq!(down_calls.lock().unwrap().len(), 1);

    // every provider down and nothing covered: an error
    let (down, _) = server(Mode::Down).await;
    let rpc = Rpc::connect(&[down], None).unwrap();
    assert!(rpc.logs_paged(&Filter::new(), 1, 20).await.is_err());
}
