//! Credence keeper (Build Guide §10.2).
//!
//! One binary, one scheduler. Triggers come from the venue calendars (every session boundary) plus a
//! 60 s heartbeat; every job has an idempotency key in `ops.keeper_job`, every transaction is written
//! ahead to `ops.keeper_tx` before broadcast, and only the Postgres-advisory-lock leader acts. A restart
//! or a failover resumes exactly where the previous leader stopped.
//!
//! Sprint 1 jobs: **J1** clock tick and **J12** housekeeping. J2–J11 arrive in later sprints.

pub mod bindings;
pub mod clock;
pub mod config;
pub mod core;
pub mod core_jobs;
pub mod jobs;
pub mod leader;
pub mod metrics;
pub mod rpc;
pub mod schedule;
pub mod sigma;
pub mod sigma_job;
pub mod tasks;
pub mod tx;
