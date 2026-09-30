//! Postgres access (`ops` schema, §11.3). Services connect with a retrying pool. The DDL is owned by
//! dbmate (`infra/db/migrations`, ADR-0001); tests apply the same files to a scratch database.

use anyhow::{Context, Result};
use sqlx::{
    postgres::{PgConnectOptions, PgPoolOptions},
    PgPool,
};
use std::{path::Path, str::FromStr, time::Duration};

pub async fn connect(url: &str, max_connections: u32) -> Result<PgPool> {
    let backoff = crate::retry::Backoff {
        attempts: 10,
        ..Default::default()
    };
    backoff
        .retry("postgres connect", || {
            PgPoolOptions::new()
                .max_connections(max_connections)
                .acquire_timeout(Duration::from_secs(5))
                .connect(url)
        })
        .await
        .context("connecting to postgres")
}

/// Connection options for a chain-bound service (ADR-0014): every connection carries `credence.chain_id`, which
/// `ops.chain()` reads, so the service's ops rows (keeper jobs and txs, relayer reports) are its chain's only.
pub fn chain_options(url: &str, chain_id: u64) -> Result<PgConnectOptions> {
    Ok(PgConnectOptions::from_str(url)
        .context("DATABASE_URL")?
        .options([("credence.chain_id", chain_id.to_string())]))
}

/// A retrying pool whose connections are scoped to `chain_id` (see `chain_options`).
pub async fn connect_chain(url: &str, max_connections: u32, chain_id: u64) -> Result<PgPool> {
    let opts = chain_options(url, chain_id)?;
    let backoff = crate::retry::Backoff {
        attempts: 10,
        ..Default::default()
    };
    backoff
        .retry("postgres connect", || {
            PgPoolOptions::new()
                .max_connections(max_connections)
                .acquire_timeout(Duration::from_secs(5))
                .connect_with(opts.clone())
        })
        .await
        .context("connecting to postgres")
}

/// The `-- migrate:up` sections of the dbmate files in `dir`, in filename order.
pub fn dbmate_up_sections(dir: &Path) -> Result<Vec<(String, String)>> {
    let mut files: Vec<_> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "sql"))
        .collect();
    files.sort();
    files
        .into_iter()
        .map(|p| {
            let sql = std::fs::read_to_string(&p)?;
            let up = sql
                .split("-- migrate:down")
                .next()
                .unwrap_or_default()
                .replace("-- migrate:up", "");
            Ok((
                p.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned(),
                up,
            ))
        })
        .collect()
}

/// Test helper: create a fresh database named `name` on the server of `admin_url` and apply every
/// migration to it. Returns the new database URL.
pub async fn scratch_database(admin_url: &str, name: &str) -> Result<String> {
    anyhow::ensure!(
        !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
        "scratch database name must be [a-z0-9_]+"
    );
    let admin = connect(admin_url, 1).await?;
    // `name` is validated above; identifiers cannot be bound as parameters.
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "drop database if exists \"{name}\" with (force)"
    )))
    .execute(&admin)
    .await?;
    sqlx::query(sqlx::AssertSqlSafe(format!("create database \"{name}\"")))
        .execute(&admin)
        .await?;
    let url = replace_db_name(admin_url, name);
    let pool = connect(&url, 1).await?;
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../infra/db/migrations");
    for (file, up) in dbmate_up_sections(&dir)? {
        // trusted: the repo's own migration files
        sqlx::raw_sql(sqlx::AssertSqlSafe(up))
            .execute(&pool)
            .await
            .with_context(|| format!("applying {file}"))?;
    }
    pool.close().await;
    Ok(url)
}

fn replace_db_name(url: &str, name: &str) -> String {
    let (base, query) = url
        .split_once('?')
        .map(|(b, q)| (b, Some(q)))
        .unwrap_or((url, None));
    let base = base.rsplit_once('/').map(|(b, _)| b).unwrap_or(base);
    match query {
        Some(q) => format!("{base}/{name}?{q}"),
        None => format!("{base}/{name}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn up_sections_exclude_down() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../infra/db/migrations");
        let ups = dbmate_up_sections(&dir).unwrap();
        assert!(ups.len() >= 2);
        assert!(ups.iter().all(|(_, s)| !s.contains("drop schema")));
        assert!(ups[0].1.contains("create table ops.keeper_job"));
    }

    #[test]
    fn db_name_is_replaced() {
        assert_eq!(
            replace_db_name("postgres://u:p@h:5433/credence", "t1"),
            "postgres://u:p@h:5433/t1"
        );
        assert_eq!(
            replace_db_name("postgres://u:p@h/credence?sslmode=disable", "t1"),
            "postgres://u:p@h/t1?sslmode=disable"
        );
    }
}
