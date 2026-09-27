//! Time source. Production uses the system clock; tests drive a manual clock in step with
//! `anvil_setTime`, so calendar boundaries can be crossed in seconds.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

pub trait Clock: Send + Sync {
    fn now(&self) -> u64;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

#[derive(Debug, Clone)]
pub struct ManualClock(pub Arc<AtomicU64>);

impl ManualClock {
    pub fn new(t: u64) -> Self {
        Self(Arc::new(AtomicU64::new(t)))
    }
    pub fn set(&self, t: u64) {
        self.0.store(t, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}
