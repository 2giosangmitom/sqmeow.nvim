//! SQL Server integration tests; `just db-up` supplies the server.

use sqmeow_adapters::Backend;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;
const NO_CAP: usize = usize::MAX;
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");
include!("common/relationships.rs");

macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_MSSQL_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_MSSQL_URL, or run `just db-up`");
                return;
            }
        }
    };
}

async fn run(db: &Backend, sql: &str) -> ResultSet {
    db.execute(sql, usize::MAX, CancellationToken::new())
        .await
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    relationship_fixture(&Backend::connect(&server!()).await.unwrap(), "dbo").await;
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = Backend::connect(&server!()).await.unwrap();
    run(&backend, "drop table if exists sqmeow_rollback_smoke").await;
    failed_apply_rolls_back(
        &backend,
        "create table sqmeow_rollback_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let backend = Backend::connect(&server!()).await.unwrap();
    let text = "'; DROP TABLE dbo.sqmeow_bound; -- 日本🐱 @P99";
    bound_values_remain_data(
        &backend,
        "SELECT @P1 AS first, @P1 AS repeated, @P2 AS missing",
        &[Value::Text(text.into()), Value::Null(Kind::Int)],
        text,
    )
    .await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = Backend::connect(&server!()).await.unwrap();
    run(&backend, "drop table if exists sqmeow_crud_smoke").await;
    crud_round_trip(
        &backend,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let db = Backend::connect(&server!()).await.unwrap();
    assert_eq!(db.dialect().name(), "mssql");
    db.close().await;
}

#[tokio::test]
async fn selects_a_literal_row() {
    let db = Backend::connect(&server!()).await.unwrap();
    let result = run(&db, "SELECT 1 AS id").await;
    assert_eq!(result.row_count(), 1);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    db.close().await;
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let db = Backend::connect(&server!()).await.unwrap();
    let error = db
        .execute(
            "SELECT nope FROM nowhere",
            usize::MAX,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("nowhere"), "{error}");
    assert_eq!(run(&db, "SELECT 1 AS id").await.row_count(), 1);
    db.close().await;
}
