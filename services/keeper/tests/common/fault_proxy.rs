//! A JSON-RPC fault proxy for the S5 edge tests (RPC failover, K-05, K-06): forwards POSTs to an upstream node
//! and, on command, answers like a broken or lying RPC.
//!
//! * `Mode::Up` forwards everything;
//! * `Mode::Down` answers every request with HTTP 503 (an outage);
//! * `Mode::FrozenHead(n)` forwards everything but reports `eth_blockNumber = n` (a node stuck behind);
//! * `fail(method, n)` fails the next `n` calls of `method` with a JSON-RPC error, after forwarding nothing;
//! * `lose(method, skip)` lets `skip` calls of `method` through, then forwards the next one but answers it with
//!   HTTP 502: the node got it (a tx is broadcast) and the caller never hears so;
//! * `gate(method)` holds the next call of `method` until the test releases it, so the test can change the chain
//!   between the caller's pre-check and its tx (K-06).
//!
//! Shared by the keeper and relayer tests (`#[path]`); only axum, reqwest and tokio, which both crates have.
#![allow(dead_code)]

use axum::{
    body::Bytes, extract::State, http::StatusCode, response::IntoResponse, routing::post, Router,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::sync::{mpsc, oneshot};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mode {
    Up,
    Down,
    FrozenHead(u64),
}

struct Inner {
    mode: Mode,
    fail: HashMap<String, usize>,
    lose: HashMap<String, usize>,
    gate: Option<(String, mpsc::UnboundedSender<oneshot::Sender<()>>)>,
    calls: HashMap<String, usize>,
}

#[derive(Clone)]
pub struct FaultProxy {
    pub url: String,
    upstream: String,
    inner: Arc<Mutex<Inner>>,
    http: reqwest::Client,
}

impl FaultProxy {
    pub async fn start(upstream: &str) -> Self {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        let p = Self {
            url,
            upstream: upstream.to_string(),
            inner: Arc::new(Mutex::new(Inner {
                mode: Mode::Up,
                fail: HashMap::new(),
                lose: HashMap::new(),
                gate: None,
                calls: HashMap::new(),
            })),
            http: reqwest::Client::new(),
        };
        let app = Router::new().route("/", post(handle)).with_state(p.clone());
        tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
        p
    }

    pub fn set(&self, m: Mode) {
        self.inner.lock().unwrap().mode = m;
    }

    pub fn fail(&self, method: &str, n: usize) {
        self.inner.lock().unwrap().fail.insert(method.into(), n);
    }

    /// Forward the `skip + 1`-th next call of `method` and lose its response.
    pub fn lose(&self, method: &str, skip: usize) {
        self.inner
            .lock()
            .unwrap()
            .lose
            .insert(method.into(), skip + 1);
    }

    /// Hold the next call of `method`; the receiver yields one release handle per held call.
    pub fn gate(&self, method: &str) -> mpsc::UnboundedReceiver<oneshot::Sender<()>> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.inner.lock().unwrap().gate = Some((method.into(), tx));
        rx
    }

    pub fn calls(&self, method: &str) -> usize {
        *self.inner.lock().unwrap().calls.get(method).unwrap_or(&0)
    }
}

async fn handle(State(p): State<FaultProxy>, body: Bytes) -> axum::response::Response {
    let req: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    // alloy sends single requests; a batch is forwarded as is (only Down applies to it)
    let method = req["method"].as_str().unwrap_or("").to_string();
    let id = req["id"].clone();
    let (mode, fail, lose, gate) = {
        let mut g = p.inner.lock().unwrap();
        *g.calls.entry(method.clone()).or_default() += 1;
        let fail = match g.fail.get_mut(&method) {
            Some(n) if *n > 0 => {
                *n -= 1;
                true
            }
            _ => false,
        };
        let lose = match g.lose.get_mut(&method) {
            Some(n) if *n > 0 => {
                *n -= 1;
                *n == 0
            }
            _ => false,
        };
        let gate = match &g.gate {
            Some((m, _)) if *m == method => g.gate.take().map(|(_, tx)| tx),
            _ => None,
        };
        (g.mode.clone(), fail, lose, gate)
    };
    if mode == Mode::Down {
        return (StatusCode::SERVICE_UNAVAILABLE, "down").into_response();
    }
    if fail {
        return axum::Json(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32000, "message": format!("fault proxy: injected {method} failure") } }))
            .into_response();
    }
    if let Some(tx) = gate {
        let (release, wait) = oneshot::channel();
        let _ = tx.send(release);
        let _ = wait.await;
    }
    if let (Mode::FrozenHead(n), "eth_blockNumber") = (&mode, method.as_str()) {
        return axum::Json(json!({ "jsonrpc": "2.0", "id": id, "result": format!("{n:#x}") }))
            .into_response();
    }
    match p
        .http
        .post(&p.upstream)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
    {
        Ok(_) if lose => (StatusCode::BAD_GATEWAY, "fault proxy: response lost").into_response(),
        Ok(r) => {
            let status =
                StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
            (
                status,
                [("content-type", "application/json")],
                r.bytes().await.unwrap_or_default(),
            )
                .into_response()
        }
        Err(_) => StatusCode::BAD_GATEWAY.into_response(),
    }
}
