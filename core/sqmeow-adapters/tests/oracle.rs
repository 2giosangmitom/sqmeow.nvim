//! The Oracle Database adapter against a real server.

use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;

include!("common/harness.rs");
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");
include!("common/relationships.rs");

#[test]
fn cancelled_writes_never_start_before_or_after_blocking_queue() {
    use std::{
        future::{Future, poll_fn},
        task::Poll,
    };
    let url = server!("SQMEOW_TEST_ORACLE_URL");
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let db = connect(&url).await;
        run(&db, "drop table if exists audit_cancel_regression").await;
        run(&db, "create table audit_cancel_regression (id number)").await;
        for mode in 0..3 {
            for queued in [false, true] {
                let (release, wait) = std::sync::mpsc::channel();
                let (started, ready) = tokio::sync::oneshot::channel();
                let blocker = tokio::task::spawn_blocking(move || {
                    started.send(()).unwrap();
                    wait.recv().unwrap();
                });
                ready.await.unwrap();
                let cancel = CancellationToken::new();
                let mut work = Box::pin(async {
                    match mode {
                        0 => db
                            .execute(
                                "insert into audit_cancel_regression values (1)",
                                NO_CAP,
                                cancel.clone(),
                            )
                            .await
                            .map(|_| ()),
                        1 => db
                            .execute_bound(
                                "insert into audit_cancel_regression values (:1)",
                                &[Value::Int(1)],
                                NO_CAP,
                                cancel.clone(),
                            )
                            .await
                            .map(|_| ()),
                        _ => db
                            .apply(
                                &["insert into audit_cancel_regression values (1)".into()],
                                cancel.clone(),
                            )
                            .await
                            .map(|_| ()),
                    }
                });
                if queued {
                    poll_fn(|cx| {
                        assert!(work.as_mut().poll(cx).is_pending());
                        Poll::Ready(())
                    })
                    .await;
                }
                cancel.cancel();
                release.send(()).unwrap();
                assert!(matches!(work.await, Err(Error::Cancelled)));
                blocker.await.unwrap();
                assert_eq!(
                    run(&db, "select id from audit_cancel_regression")
                        .await
                        .row_count(),
                    0
                );
            }
        }
        run(&db, "drop table audit_cancel_regression").await;
        db.close().await;
    });
}

#[tokio::test(flavor = "current_thread")]
async fn cancelling_apply_rolls_back_before_commit_and_reuse() {
    let db = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    run(&db, "drop table if exists audit_cancel_apply").await;
    run(&db, "create table audit_cancel_apply (id number)").await;
    run(&db, "insert into audit_cancel_apply values (1)").await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let statements = [
        "update audit_cancel_apply set id=2".into(),
        "begin dbms_session.sleep(0.3); end;".into(),
    ];
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(db.apply(&statements, cancel), timer);
    assert!(matches!(outcome, Err(Error::Cancelled)));
    assert_eq!(
        run(&db, "select id from audit_cancel_apply")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&Cell::Int(1))
    );
    run(&db, "drop table audit_cancel_apply").await;
    db.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn abandoning_apply_rolls_back_before_the_next_request() {
    let db = connect(&server!("SQMEOW_TEST_ORACLE_URL")).await;
    run(&db, "drop table if exists audit_abandoned_apply").await;
    run(&db, "create table audit_abandoned_apply (id number)").await;
    run(&db, "insert into audit_abandoned_apply values (1)").await;
    let statements = [
        "update audit_abandoned_apply set id=2".into(),
        "begin dbms_session.sleep(0.3); end;".into(),
    ];
    assert!(
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            db.apply(&statements, CancellationToken::new())
        )
        .await
        .is_err()
    );
    assert_eq!(
        run(&db, "select id from audit_abandoned_apply")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&Cell::Int(1))
    );
    run(&db, "drop table audit_abandoned_apply").await;
    db.close().await;
}

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
