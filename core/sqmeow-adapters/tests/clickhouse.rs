//! The ClickHouse adapter against a real server.

use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};

include!("common/harness.rs");
include!("common/native_bind.rs");

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    let text = "x'; SELECT 99; -- \\ 雪\n";
    bound_values_remain_data(
        &backend,
        "select {sqmeow_p1:String}, {sqmeow_p1:String}, {sqmeow_p2:Nullable(Int64)}",
        &[Value::Text(text.into()), Value::Null(Kind::Int)],
        text,
    )
    .await;
}

#[tokio::test]
async fn a_read_only_connection_refuses_writes() {
    let backend = Backend::connect_to(&server!("SQMEOW_TEST_CLICKHOUSE_URL"), None, true)
        .await
        .unwrap();
    run(&backend, "select 1").await;
    let error = backend
        .execute(
            "create table ro_refused (a Int8) engine = Memory",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("readonly"), "{error}");
    backend.close().await;
}

#[tokio::test]
async fn results_are_read_only() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    assert!(run(&backend, "select 1 as a").await.source().is_none());
    assert!(
        backend
            .apply(&["select 1".into()], CancellationToken::new())
            .await
            .is_err()
    );
    backend.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    run(&backend, "DROP TABLE IF EXISTS sqmeow_crud_smoke").await;
    run(
        &backend,
        "CREATE TABLE sqmeow_crud_smoke (id Int32, name String) ENGINE = MergeTree ORDER BY id",
    )
    .await;
    run(
        &backend,
        "INSERT INTO sqmeow_crud_smoke VALUES (1, 'alice')",
    )
    .await;
    let selected = run(&backend, "SELECT name FROM sqmeow_crud_smoke WHERE id = 1").await;
    let schema = backend
        .schemas()
        .await
        .unwrap()
        .into_iter()
        .find(|schema| schema.is_default)
        .unwrap();
    assert!(
        backend
            .relations(&schema.name)
            .await
            .unwrap()
            .iter()
            .any(|relation| relation.name == "sqmeow_crud_smoke")
    );
    assert_eq!(
        backend
            .columns(&schema.name, "sqmeow_crud_smoke")
            .await
            .unwrap()
            .len(),
        2
    );
    assert_eq!(selected.row_count(), 1);
    assert_eq!(
        selected.cell(0, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Text("alice".into()))
    );
    run(&backend, "ALTER TABLE sqmeow_crud_smoke UPDATE name = 'bob' WHERE id = 1 SETTINGS mutations_sync = 1").await;
    assert_eq!(
        run(&backend, "SELECT name FROM sqmeow_crud_smoke WHERE id = 1")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&sqmeow_db::value::Cell::Text("bob".into()))
    );
    run(
        &backend,
        "ALTER TABLE sqmeow_crud_smoke DELETE WHERE id = 1 SETTINGS mutations_sync = 1",
    )
    .await;
    assert_eq!(
        run(&backend, "SELECT * FROM sqmeow_crud_smoke")
            .await
            .row_count(),
        0
    );
    run(&backend, "DROP TABLE sqmeow_crud_smoke").await;
    backend.close().await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    assert_eq!(backend.dialect().name(), "clickhouse");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("clickhouse://127.0.0.1:1")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn stops_at_the_row_cap() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    let result = backend
        .execute(
            "select number from numbers(100)",
            10,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn reports_a_server_error() {
    let backend = connect(&server!("SQMEOW_TEST_CLICKHOUSE_URL")).await;
    let error = backend
        .execute("select nope from nowhere", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("nowhere"), "{error}");
    assert_eq!(run(&backend, "select 1").await.row_count(), 1);
}
