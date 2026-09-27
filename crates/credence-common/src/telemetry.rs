//! JSON logs through `tracing` (§10). `LOG_FORMAT=pretty` for humans; `RUST_LOG` filters.

use tracing_subscriber::{fmt, EnvFilter};

/// Install the global subscriber. Safe to call more than once (later calls are no-ops).
pub fn init(service: &'static str) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let pretty = std::env::var("LOG_FORMAT")
        .map(|v| v == "pretty")
        .unwrap_or(false);
    let result = if pretty {
        fmt().with_env_filter(filter).with_target(false).try_init()
    } else {
        fmt()
            .json()
            .with_env_filter(filter)
            .with_current_span(false)
            .flatten_event(true)
            .try_init()
    };
    if result.is_ok() {
        tracing::info!(
            service,
            version = env!("CARGO_PKG_VERSION"),
            "telemetry initialised"
        );
    }
}
