// Simple cases every CQL server must pass.

use sqmeow_adapters::Backend;
use sqmeow_db::edit::Changes;
use sqmeow_db::error::Error;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// The tests share one keyspace and run in parallel, so each one owns its table.

async fn connect(url: &str) -> Backend {
    let backend = Backend::connect(url)
        .await
        .expect("the test server should accept a connection");
    run(
        &backend,
        "CREATE KEYSPACE IF NOT EXISTS sqmeow
         WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}",
    )
    .await;
    backend
}

async fn run(backend: &Backend, statement: &str) -> ResultSet {
    backend
        .execute(statement, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{statement} should run: {error}"))
}

async fn table(backend: &Backend, name: &str, definition: &str) {
    run(backend, &format!("DROP TABLE IF EXISTS sqmeow.{name}")).await;
    run(
        backend,
        &format!("CREATE TABLE sqmeow.{name} ({definition})"),
    )
    .await;
}

#[tokio::test]
async fn native_binds_preserve_text_nulls_and_complete_edit_keys() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "bound_smoke",
        "pk int, ck int, first text, repeated text, missing int, PRIMARY KEY (pk, ck)",
    )
    .await;
    let text = "it's \\ data; ' OR true -- :name ?";
    backend.execute_bound("INSERT INTO sqmeow.bound_smoke (pk, ck, first, repeated, missing) VALUES (?, ?, ?, ?, ?)", &[Value::Int(1), Value::Int(2), Value::Text(text.into()), Value::Text(text.into()), Value::Null(Kind::Int)], NO_CAP, CancellationToken::new()).await.unwrap();
    let result = backend.execute_bound("SELECT pk, ck, first, repeated, missing FROM sqmeow.bound_smoke WHERE pk = ? AND ck = ?", &[Value::Int(1), Value::Int(2)], NO_CAP, CancellationToken::new()).await.unwrap();
    assert_eq!(result.cell(0, 2).as_deref(), Some(&Cell::Text(text.into())));
    assert_eq!(result.cell(0, 3).as_deref(), Some(&Cell::Text(text.into())));
    assert_eq!(result.cell(0, 4).as_deref(), Some(&Cell::Null));
    assert!(result.source().is_some());
    assert!(
        run(&backend, "SELECT pk, first FROM sqmeow.bound_smoke")
            .await
            .source()
            .is_none()
    );
    let columns = backend.columns("sqmeow", "bound_smoke").await.unwrap();
    assert_eq!(
        columns.iter().filter(|column| column.primary_key).count(),
        2
    );
    let update = Changes {
        updates: vec![(0, vec![(2, "updated".into())])],
        ..Default::default()
    };
    backend
        .apply(
            &backend.plan(&result, &update).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(
        run(
            &backend,
            "SELECT first FROM sqmeow.bound_smoke WHERE pk = 1 AND ck = 2"
        )
        .await
        .cell(0, 0).as_deref(),
        Some(&Cell::Text("updated".into()))
    );
    let duplicate = Changes {
        inserts: vec![vec![(0, "1".into()), (1, "2".into())]],
        ..Default::default()
    };
    assert!(
        backend
            .apply(
                &backend.plan(&result, &duplicate).unwrap(),
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    run(&backend, "DROP TABLE sqmeow.bound_smoke").await;
    backend.close().await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect().name(), "scylla");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("scylla://127.0.0.1:1/").await.unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "typed",
        "id int PRIMARY KEY, name text, seen timestamp",
    )
    .await;
    run(
        &backend,
        "INSERT INTO sqmeow.typed (id, name, seen) VALUES
         (1, 'alice', '2024-01-02 03:04:05.678+0000')",
    )
    .await;

    let result = run(&backend, "SELECT id, name, seen FROM sqmeow.typed").await;
    assert_eq!(result.row_count(), 1);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1).as_deref(), Some(&Cell::Text("alice".into())));
    assert_eq!(
        result.cell(0, 2).as_deref(),
        Some(&Cell::Timestamp("2024-01-02 03:04:05.678+0000".into()))
    );
    run(
        &backend,
        "UPDATE sqmeow.typed SET name = 'bob' WHERE id = 1",
    )
    .await;
    assert_eq!(
        run(&backend, "SELECT name FROM sqmeow.typed WHERE id = 1")
            .await
            .cell(0, 0).as_deref(),
        Some(&Cell::Text("bob".into()))
    );
    run(&backend, "DELETE FROM sqmeow.typed WHERE id = 1").await;
    assert_eq!(
        run(&backend, "SELECT * FROM sqmeow.typed")
            .await
            .row_count(),
        0
    );
    run(&backend, "DROP TABLE sqmeow.typed").await;
    backend.close().await;
}

#[tokio::test]
async fn an_error_keeps_the_connection() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute(
            "SELECT * FROM sqmeow.no_such_table",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
    run(&backend, "SELECT release_version FROM system.local").await;
}

#[tokio::test(flavor = "current_thread")]
async fn cancel_after_server_write_reports_partial_progress() {
    use std::{future::{Future, poll_fn}, task::Poll, time::Duration};
    let url = server!();
    let backend = connect(&url).await;
    let observer = connect(&url).await;
    table(&backend, "audit_cancel_reply", "id int PRIMARY KEY").await;
    let cancel = CancellationToken::new();
    let statements = [
        "INSERT INTO sqmeow.audit_cancel_reply (id) VALUES (1)".into(),
        "INSERT INTO sqmeow.audit_cancel_reply (id) VALUES (2)".into(),
    ];
    let work = backend.apply(&statements, cancel.clone());
    tokio::pin!(work);
    poll_fn(|cx| { assert!(work.as_mut().poll(cx).is_pending()); Poll::Ready(()) }).await;
    tokio::time::timeout(Duration::from_secs(3), async {
        while run(&observer, "SELECT id FROM sqmeow.audit_cancel_reply WHERE id=1").await.row_count() == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("first write must reach the server before cancellation");
    cancel.cancel();
    let error = work.await.unwrap_err();
    assert!(!matches!(error, Error::Cancelled));
    assert!(error.to_string().contains("1 of 2"), "{error}");
    assert_eq!(run(&observer, "SELECT id FROM sqmeow.audit_cancel_reply WHERE id=2").await.row_count(), 0);
    run(&backend, "DROP TABLE sqmeow.audit_cancel_reply").await;
    backend.close().await;
    observer.close().await;
}
