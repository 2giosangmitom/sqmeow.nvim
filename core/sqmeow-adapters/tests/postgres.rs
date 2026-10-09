//! The PostgreSQL adapter against a real server.

use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn cancellation_after_insert_preserves_success_and_reuse() {
    let db = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    run(&db, "drop table if exists audit_late_cancel").await;
    run(&db, "create table audit_late_cancel (id int)").await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(
        db.execute(
            "do $$ begin insert into audit_late_cancel values (1); perform pg_sleep(0.3); end $$",
            NO_CAP,
            cancel
        ),
        timer
    );
    outcome.expect("a completed write must retain its successful outcome");
    assert_eq!(
        run(&db, "select * from audit_late_cancel")
            .await
            .row_count(),
        1
    );
    run(&db, "drop table audit_late_cancel").await;
    db.close().await;
}

#[tokio::test]
async fn read_cancellation_keeps_the_connection_usable() {
    let db = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(db.execute("select pg_sleep(2)", NO_CAP, cancel), timer);
    assert!(matches!(outcome, Err(Error::Cancelled)));
    run(&db, "select 1").await;
    db.close().await;
}

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    relationship_fixture(
        &connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await,
        "public",
    )
    .await;
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    failed_apply_rolls_back(
        &backend,
        "create temporary table sqmeow_rollback_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let backend = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    let text = "it's \\ data; ' OR true -- $1 ?";
    bound_values_remain_data(
        &backend,
        "select $1::text, $1::text, $2::int",
        &[Value::Text(text.into()), Value::Null(Kind::Int)],
        text,
    )
    .await;
}

#[tokio::test]
async fn a_read_only_connection_stays_read_only_after_set_config() {
    let backend = Backend::connect_to(&server!("SQMEOW_TEST_POSTGRES_URL"), None, true)
        .await
        .unwrap();
    run(
        &backend,
        "select set_config('default_transaction_read_only', 'off', false)",
    )
    .await;
    let error = backend
        .execute(
            "create table read_only_probe (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("read-only"), "{error}");
    backend.close().await;
}

#[tokio::test]
async fn aborted_apply_cannot_be_committed_by_a_later_apply() {
    let url = server!("SQMEOW_TEST_POSTGRES_URL");
    let backend = std::sync::Arc::new(connect(&url).await);
    let observer = connect(&url).await;
    run(&observer, "drop table if exists native_aborted_apply").await;
    run(&observer, "create table native_aborted_apply (v int)").await;
    run(&observer, "insert into native_aborted_apply values (10)").await;
    let worker = backend.clone();
    let apply = tokio::spawn(async move {
        worker
            .apply(
                &[
                    "update native_aborted_apply set v = 11".into(),
                    "select pg_sleep(2) /* native_aborted_apply */".into(),
                ],
                CancellationToken::new(),
            )
            .await
    });
    let mut active = false;
    for _ in 0..100 {
        let result = run(&observer, "select count(*)::int8 from pg_stat_activity where state = 'active' and query = 'select pg_sleep(2) /* native_aborted_apply */'").await;
        if result.cell(0, 0).as_deref() == Some(&Cell::Int(1)) {
            active = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        active,
        "first update must have run before aborting the apply"
    );
    apply.abort();
    assert!(apply.await.unwrap_err().is_cancelled());
    let reuse = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        backend.apply(&["select 1".into()], CancellationToken::new()),
    )
    .await
    .expect("retired session must reject reuse without waiting indefinitely");
    assert_eq!(
        run(&observer, "select v from native_aborted_apply")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&Cell::Int(10)),
        "later apply must not commit abandoned edits (reuse outcome: {reuse:?})"
    );
    run(&observer, "drop table native_aborted_apply").await;
    backend.close().await;
    observer.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    crud_round_trip(
        &backend,
        "create temporary table sqmeow_crud_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    assert_eq!(backend.dialect().name(), "postgres");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("postgres://nobody@127.0.0.1:1/none")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!("SQMEOW_TEST_POSTGRES_URL")).await;
    let result = run(&backend, "select 1 as id, 'alice' as name").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(
        result.cell(0, 1).as_deref(),
        Some(&Cell::Text("alice".into()))
    );
}
