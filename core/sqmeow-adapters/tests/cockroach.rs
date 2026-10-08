//! The PostgreSQL adapter against a real CockroachDB server.

use sqmeow_db::adapter::Dialect;
use sqmeow_db::value::Cell;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    relationship_fixture(
        &connect(&server!("SQMEOW_TEST_COCKROACH_URL")).await,
        "public",
    )
    .await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_COCKROACH_URL")).await;
    run(&backend, "drop table if exists sqmeow_crud_smoke").await;
    crud_round_trip(
        &backend,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn the_server_really_is_cockroach() {
    let backend = connect(&server!("SQMEOW_TEST_COCKROACH_URL")).await;
    assert_eq!(backend.dialect(), Dialect::Postgres);
    let result = run(&backend, "select version()").await;
    let version = result.cell(0, 0).unwrap().text("").into_owned();
    assert!(version.starts_with("CockroachDB"), "{version}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!("SQMEOW_TEST_COCKROACH_URL")).await;
    let result = run(&backend, "select 1 as id, 'alice' as name").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
}
