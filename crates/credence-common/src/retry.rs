//! Exponential backoff with full jitter for vendor and RPC calls.

use std::{future::Future, time::Duration};

#[derive(Debug, Clone, Copy)]
pub struct Backoff {
    pub initial: Duration,
    pub max: Duration,
    pub attempts: u32,
}

impl Default for Backoff {
    fn default() -> Self {
        Self { initial: Duration::from_millis(200), max: Duration::from_secs(5), attempts: 5 }
    }
}

impl Backoff {
    /// Delay before retry number `n` (1-based), capped at `max`, with full jitter.
    pub fn delay(&self, n: u32) -> Duration {
        let exp = self.initial.saturating_mul(1u32 << n.saturating_sub(1).min(16));
        let cap = exp.min(self.max);
        let nanos = cap.as_nanos() as u64;
        if nanos == 0 {
            return cap;
        }
        Duration::from_nanos(jitter(nanos))
    }

    /// Run `op` until it succeeds or `attempts` is exhausted; returns the last error.
    pub async fn retry<T, E, F, Fut>(&self, what: &str, mut op: F) -> Result<T, E>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, E>>,
        E: std::fmt::Display,
    {
        let mut n = 0;
        loop {
            n += 1;
            match op().await {
                Ok(v) => return Ok(v),
                Err(e) if n >= self.attempts => return Err(e),
                Err(e) => {
                    let d = self.delay(n);
                    tracing::warn!(what, attempt = n, error = %e, delay_ms = d.as_millis() as u64, "retrying");
                    tokio::time::sleep(d).await;
                }
            }
        }
    }
}

fn jitter(upper: u64) -> u64 {
    // xorshift on the clock: good enough for spreading retries, not for anything secret.
    let mut x = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15)
        | 1;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    upper / 2 + x % (upper / 2 + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delay_is_capped_and_positive() {
        let b = Backoff { initial: Duration::from_millis(100), max: Duration::from_secs(1), attempts: 3 };
        for n in 1..20 {
            let d = b.delay(n);
            assert!(d <= Duration::from_secs(1), "{d:?}");
            assert!(d >= Duration::from_millis(50).min(b.max / 2));
        }
    }

    #[tokio::test]
    async fn retry_returns_first_success() {
        let b = Backoff { initial: Duration::from_millis(1), max: Duration::from_millis(2), attempts: 5 };
        let mut calls = 0;
        let r: Result<u32, String> = b
            .retry("t", || {
                calls += 1;
                let c = calls;
                async move { if c < 3 { Err("no".to_string()) } else { Ok(c) } }
            })
            .await;
        assert_eq!(r.unwrap(), 3);
    }
}
