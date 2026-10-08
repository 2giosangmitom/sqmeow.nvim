//! The Oracle Database adapter against a real server.

use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    relationship_fixture(&connect(&server!("SQMEOW_TEST_ORACLE_URL")).await, "SQMEOW").await;
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    run(&backend, "drop table if exists sqmeow_rollback_smoke").await;
    failed_apply_rolls_back(
        &backend,
        "create table sqmeow_rollback_smoke (id int primary key, name varchar2(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let backend = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    let text = "Alice' ; DELETE FROM users -- 日本";
    bound_values_remain_data(
        &backend,
        "select :1 as first, :1 as repeated, :2 as missing from dual",
        &[Value::Text(text.into()), Value::Null(Kind::Int)],
        text,
    )
    .await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    run(&backend, "drop table if exists sqmeow_crud_smoke").await;
    crud_round_trip(
        &backend,
        "create table sqmeow_crud_smoke (id int primary key, name varchar2(32))",
    )
    .await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    assert_eq!(backend.dialect().name(), "oracle");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("oracle://sqmeow:sqmeow@127.0.0.1:1/FREE")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    let result = run(&backend, "select 1 as id, 'alice' as name from dual").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["ID", "NAME"]);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(
        result.cell(0, 1).as_deref(),
        Some(&Cell::Text("alice".into()))
    );
}
