//! MySQL-protocol compatibility on an actual MariaDB server.

use sqmeow_db::value::Cell;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    let backend = connect(&server!("SQMEOW_TEST_MARIADB_URL")).await;
    let schema = backend
        .schemas()
        .await
        .unwrap()
        .into_iter()
        .find(|schema| schema.is_default)
        .unwrap();
    relationship_fixture(&backend, &schema.name).await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_MARIADB_URL")).await;
    run(&backend, "drop table if exists sqmeow_crud_smoke").await;
    crud_round_trip(
        &backend,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32)) engine = InnoDB",
    )
    .await;
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!("SQMEOW_TEST_MARIADB_URL")).await;
    assert_eq!(backend.dialect().name(), "mysql");
    let result = run(&backend, "select 1 as id, 'alice' as name").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
    backend.close().await;
}
