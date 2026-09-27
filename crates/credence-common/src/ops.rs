//! Ops endpoints every service exposes (§10): `/healthz` (process alive), `/readyz` (dependencies
//! reachable and the service is doing its job) and Prometheus `/metrics`.

use axum::{extract::State, http::StatusCode, response::IntoResponse, routing::get, Router};
use prometheus::{Encoder, Registry, TextEncoder};
use std::{
    net::SocketAddr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

/// Shared readiness flag plus the metrics registry of one service.
#[derive(Clone)]
pub struct OpsState {
    pub registry: Registry,
    ready: Arc<AtomicBool>,
    service: &'static str,
}

impl OpsState {
    pub fn new(service: &'static str) -> Self {
        let registry = Registry::new_custom(Some("credence".into()), None).expect("registry prefix is valid");
        Self { registry, ready: Arc::new(AtomicBool::new(false)), service }
    }

    pub fn set_ready(&self, ready: bool) {
        if self.ready.swap(ready, Ordering::SeqCst) != ready {
            tracing::info!(service = self.service, ready, "readiness changed");
        }
    }

    pub fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    /// Router with the three ops routes; services may merge their own routes into it.
    pub fn router(&self) -> Router {
        Router::new()
            .route("/healthz", get(healthz))
            .route("/readyz", get(readyz))
            .route("/metrics", get(metrics))
            .with_state(self.clone())
    }
}

async fn healthz(State(s): State<OpsState>) -> impl IntoResponse {
    (StatusCode::OK, format!("{} ok\n", s.service))
}

async fn readyz(State(s): State<OpsState>) -> impl IntoResponse {
    if s.is_ready() {
        (StatusCode::OK, "ready\n")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready\n")
    }
}

async fn metrics(State(s): State<OpsState>) -> impl IntoResponse {
    let mut buf = Vec::new();
    let mut families = s.registry.gather();
    families.extend(prometheus::gather());
    match TextEncoder::new().encode(&families, &mut buf) {
        Ok(()) => (StatusCode::OK, [("content-type", "text/plain; version=0.0.4")], buf).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// Bind and serve `router` until the process exits. Returns the bound address (useful with port 0).
pub async fn serve(addr: SocketAddr, router: Router) -> anyhow::Result<SocketAddr> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let local = listener.local_addr()?;
    tracing::info!(%local, "ops server listening");
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, router).await {
            tracing::error!(error = %e, "ops server stopped");
        }
    });
    Ok(local)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn ready_flag_drives_readyz() {
        let s = OpsState::new("test");
        let c = prometheus::IntCounter::new("things_total", "things").unwrap();
        s.registry.register(Box::new(c.clone())).unwrap();
        c.inc();
        let addr = serve("127.0.0.1:0".parse().unwrap(), s.router()).await.unwrap();
        let get = |p: &'static str| async move {
            let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            stream
                .write_all(format!("GET {p} HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n").as_bytes())
                .await
                .unwrap();
            let mut out = String::new();
            stream.read_to_string(&mut out).await.unwrap();
            out
        };
        assert!(get("/healthz").await.starts_with("HTTP/1.1 200"));
        assert!(get("/readyz").await.starts_with("HTTP/1.1 503"));
        s.set_ready(true);
        assert!(get("/readyz").await.starts_with("HTTP/1.1 200"));
        assert!(get("/metrics").await.contains("credence_things_total 1"));
    }
}
