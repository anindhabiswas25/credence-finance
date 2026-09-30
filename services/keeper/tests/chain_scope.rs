//! ADR-0014: one keeper per chain on one Postgres. Each keeper's job store sees its own chain's rows only
//! (`credence.chain_id` on every connection, `ops.chain()` in every query). Needs `TEST_DATABASE_URL`
//! (`make infra-up db-migrate`); run by `make backend-edge-infra`.

use credence_keeper::jobs::{self, Claim};
use serde_json::json;
use sqlx::{Connection, PgConnection};

const EQUITY: u64 = 46_630;
const NAV: u64 = 421_614;

async fn conn(url: &str, chain: u64) -> PgConnection {
    PgConnection::connect_with(&credence_common::db::chain_options(url, chain).unwrap())
        .await
        .unwrap()
}

#[tokio::test]
#[ignore = "needs TEST_DATABASE_URL (make backend-edge-infra)"]
async fn edge_x_two_keepers_on_one_db_never_see_each_others_jobs() {
    let admin = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
    let url = credence_common::db::scratch_database(&admin, "credence_keeper_chain_scope")
        .await
        .unwrap();
    let (mut eq, mut nav) = (conn(&url, EQUITY).await, conn(&url, NAV).await);
    let p = json!({});

    // The same idempotency key on both chains is two jobs.
    let key = "J1:TBILL:1790000000";
    assert_eq!(
        jobs::claim(&mut eq, key, "J1", &p, "eq-1").await.unwrap(),
        Claim::Run { attempts: 1 }
    );
    assert_eq!(
        jobs::claim(&mut nav, key, "J1", &p, "nav-1").await.unwrap(),
        Claim::Run { attempts: 1 }
    );
    jobs::mark(&mut eq, key, "done", None).await.unwrap();
    assert_eq!(
        jobs::status(&mut eq, key).await.unwrap().as_deref(),
        Some("done")
    );
    assert_eq!(
        jobs::status(&mut nav, key).await.unwrap().as_deref(),
        Some("running")
    );
    assert!(jobs::exists(&mut eq, key).await.unwrap());
    assert!(!jobs::exists(&mut nav, key).await.unwrap());

    // A restarting equity keeper releases only its own orphans: the NAV keeper's running job stays claimed.
    jobs::claim(&mut eq, "J3:NVDA:1", "J3", &p, "eq-1")
        .await
        .unwrap();
    assert_eq!(jobs::release_orphans(&mut eq).await.unwrap(), 1);
    assert_eq!(
        jobs::status(&mut nav, key).await.unwrap().as_deref(),
        Some("running")
    );

    // A job left `submitted` on one chain is never reconciled (and so never failed or re-sent) by the other.
    sqlx::query(
        "update ops.keeper_job set status = 'submitted' where chain_id = ops.chain() and key = $1",
    )
    .bind(key)
    .execute(&mut nav)
    .await
    .unwrap();
    let eq_submitted: Vec<String> = sqlx::query_scalar(
        "select key from ops.keeper_job where chain_id = ops.chain() and status = 'submitted'",
    )
    .fetch_all(&mut eq)
    .await
    .unwrap();
    assert!(eq_submitted.is_empty());
    assert_eq!(
        jobs::claim(&mut nav, key, "J1", &p, "nav-2").await.unwrap(),
        Claim::Reconcile
    );
    assert_eq!(
        jobs::claim(&mut eq, key, "J1", &p, "eq-2").await.unwrap(),
        Claim::Skip
    );

    // A connection without a chain fails closed instead of writing an unscoped row.
    let mut bare = PgConnection::connect(&url).await.unwrap();
    let err = jobs::claim(&mut bare, "J1:X:1", "J1", &p, "x")
        .await
        .unwrap_err();
    assert!(
        format!("{err:#}").contains("credence.chain_id"),
        "unexpected error: {err:#}"
    );
}
