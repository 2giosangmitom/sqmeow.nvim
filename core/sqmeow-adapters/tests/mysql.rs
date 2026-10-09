//! The MySQL adapter against a real server.

use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;
use std::time::Duration;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");
include!("common/relationships.rs");

#[tokio::test]
async fn procedure_results_keep_each_schema_and_value() {
    let db = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    run(&db, "drop procedure if exists audit_multi_results").await;
    run(
        &db,
        "create procedure audit_multi_results() begin select 1 as a; select 2 as b, 3 as c; end",
    )
    .await;
    let results = db
        .execute_results(
            "call audit_multi_results()",
            "call audit_multi_results()",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let tabular: Vec<_> = results
        .iter()
        .filter(|result| !result.columns().is_empty())
        .collect();
    assert_eq!(tabular.len(), 2);
    assert_eq!(tabular[0].columns()[0].name, "a");
    assert_eq!(tabular[1].columns()[0].name, "b");
    assert_eq!(tabular[1].columns()[1].name, "c");
    assert_eq!(tabular[1].cell(0, 1).as_deref(), Some(&Cell::Int(3)));
    run(&db, "drop procedure audit_multi_results").await;
    db.close().await;
}

#[tokio::test]
async fn cancellation_after_insert_preserves_success_and_reuse() {
    let db = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    run(&db, "drop table if exists audit_late_cancel").await;
    run(&db, "create table audit_late_cancel (id int)").await;
    run(&db, "drop procedure if exists audit_late_write").await;
    run(&db, "create procedure audit_late_write() begin insert into audit_late_cancel values (1); do sleep(0.3); end").await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(db.execute("call audit_late_write()", NO_CAP, cancel), timer);
    outcome.expect("a completed write must retain its successful outcome");
    assert_eq!(
        run(&db, "select * from audit_late_cancel")
            .await
            .row_count(),
        1
    );
    run(&db, "drop procedure audit_late_write").await;
    run(&db, "drop table audit_late_cancel").await;
    db.close().await;
}

#[tokio::test]
async fn read_cancellation_keeps_the_connection_usable() {
    let db = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(db.execute("select sleep(2), 1", NO_CAP, cancel), timer);
    match outcome {
        Err(Error::Cancelled) => {}
        // MySQL may return SLEEP's documented interrupted value as a successful
        // result instead of ER_QUERY_INTERRUPTED. Retain that actual response.
        Ok(result) => {
            assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
            assert!(result.elapsed() < std::time::Duration::from_secs(1));
        }
        Err(error) => panic!("unexpected cancellation outcome: {error}"),
    }
    run(&db, "select 1").await;
    db.close().await;
}

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
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
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    failed_apply_rolls_back(
        &backend,
        "create temporary table sqmeow_rollback_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    let text = "it's \\ data; ' OR true -- $1 ?";
    bound_values_remain_data(
        &backend,
        "select cast(? as char), cast(? as char), cast(? as signed)",
        &[
            Value::Text(text.into()),
            Value::Text(text.into()),
            Value::Null(Kind::Int),
        ],
        text,
    )
    .await;
}

#[tokio::test]
async fn atomic_edits_reject_a_hidden_commit_before_changing_rows() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    run(
        &backend,
        "create temporary table guarded_apply (id int primary key, value int)",
    )
    .await;
    run(&backend, "insert into guarded_apply values (1, 10)").await;
    assert!(
        backend
            .apply(
                &["update guarded_apply set value = 20 where id = 1; commit".into()],
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    assert_eq!(
        run(&backend, "select value from guarded_apply")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&Cell::Int(10))
    );
    backend.close().await;
}

#[tokio::test]
async fn abandoning_an_edit_batch_does_not_commit_it_on_reuse() {
    let url = server!("SQMEOW_TEST_MYSQL_URL");
    let backend = std::sync::Arc::new(connect(&url).await);
    let observer = connect(&url).await;
    run(&observer, "drop table if exists abandoned_apply").await;
    run(
        &observer,
        "create table abandoned_apply (id int primary key, value int) engine = InnoDB",
    )
    .await;
    run(&observer, "insert into abandoned_apply values (1, 10)").await;
    let connection = run(&backend, "select cast(connection_id() as signed)").await;
    let id = connection
        .cell(0, 0)
        .unwrap()
        .text("")
        .parse::<u64>()
        .unwrap();
    let worker = backend.clone();
    let apply = tokio::spawn(async move {
        worker
            .apply(
                &[
                    "update abandoned_apply set value = 20 where id = 1".into(),
                    "select sleep(2) /* sqmeow_abandoned_apply */".into(),
                ],
                CancellationToken::new(),
            )
            .await
    });
    let active = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let result = run(&observer, &format!("select count(*) from information_schema.processlist where id = {id} and info = 'select sleep(2) /* sqmeow_abandoned_apply */'")).await;
            if result.cell(0, 0).as_deref() == Some(&Cell::Int(1)) { break; }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await;
    apply.abort();
    let aborted = apply.await;
    assert!(
        active.is_ok(),
        "the update must reach the server before abandoning the apply"
    );
    assert!(aborted.unwrap_err().is_cancelled());
    assert!(
        backend
            .apply(
                &["update abandoned_apply set value = 30 where id = 1".into()],
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    tokio::time::timeout(Duration::from_secs(3), backend.close())
        .await
        .expect("abandoned session must close without hanging");
    // Locking read waits for the abandoned transaction to release its row lock.
    let rows = tokio::time::timeout(
        Duration::from_secs(3),
        observer.execute(
            "select value from abandoned_apply where id = 1 for update",
            NO_CAP,
            CancellationToken::new(),
        ),
    )
    .await
    .expect("closing must release the abandoned row lock")
    .unwrap();
    assert_eq!(
        rows.cell(0, 0).as_deref(),
        Some(&Cell::Int(10)),
        "abandoned edits must remain uncommitted"
    );
    run(&observer, "drop table abandoned_apply").await;
    observer.close().await;
}

#[tokio::test]
async fn a_read_only_connection_is_refused_writes_by_the_server() {
    let backend = Backend::connect_to(&server!("SQMEOW_TEST_MYSQL_URL"), None, true)
        .await
        .unwrap();
    run(&backend, "select 1").await;
    let error = backend
        .execute(
            "create table read_only_probe (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("READ ONLY"), "{error}");
    backend.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    run(&backend, "drop table if exists sqmeow_crud_smoke").await;
    crud_round_trip(
        &backend,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32)) engine = InnoDB",
    )
    .await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    assert_eq!(backend.dialect().name(), "mysql");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("mysql://nobody@127.0.0.1:1/none")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!("SQMEOW_TEST_MYSQL_URL")).await;
    let result = run(&backend, "select 1 as id, 'alice' as name").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(
        result.cell(0, 1).as_deref(),
        Some(&Cell::Text("alice".into()))
    );
}
