//! The SurrealDB adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::edit::Changes;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_SURREALDB_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_SURREALDB_URL, or run `just db-up`");
                return;
            }
        }
    };
}

#[tokio::test(flavor = "current_thread")]
async fn running_transaction_reports_actual_commit_after_cancel() {
    let db = fresh(&server!(), "cancel_outcome").await;
    run(&db, "DEFINE TABLE probe SCHEMALESS").await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(
        db.execute(
            "BEGIN TRANSACTION; CREATE probe:one SET n=1; SLEEP 300ms; COMMIT TRANSACTION;",
            NO_CAP,
            cancel
        ),
        timer
    );
    outcome.expect("a committed transaction must not be reported as cancelled");
    assert_eq!(run(&db, "SELECT * FROM probe").await.row_count(), 1);
    db.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn cancelling_apply_reports_the_actual_commit() {
    let db = fresh(&server!(), "cancel_apply").await;
    run(&db, "DEFINE TABLE probe SCHEMALESS").await;
    let cancel = CancellationToken::new();
    let stopped = cancel.clone();
    let statements = ["CREATE probe:one SET n = { SLEEP 300ms; RETURN 1; }".into()];
    let timer = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopped.cancel();
    };
    let (outcome, ()) = tokio::join!(db.apply(&statements, cancel), timer);
    outcome.expect("a committed apply must not be reported as cancelled");
    assert_eq!(run(&db, "SELECT * FROM probe").await.row_count(), 1);
    db.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn abandoned_transaction_finishes_before_connection_reuse() {
    let db = fresh(&server!(), "abandoned_transaction").await;
    run(&db, "DEFINE TABLE probe SCHEMALESS").await;
    assert!(
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            db.execute(
                "BEGIN TRANSACTION; CREATE probe:one SET n=1; SLEEP 300ms; COMMIT TRANSACTION;",
                NO_CAP,
                CancellationToken::new()
            )
        )
        .await
        .is_err()
    );
    assert_eq!(run(&db, "SELECT * FROM probe").await.row_count(), 1);
    db.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn queued_cancel_never_writes_or_interrupts_the_active_query() {
    use std::{
        future::{Future, poll_fn},
        task::Poll,
    };
    let db = fresh(&server!(), "cancel_queue").await;
    run(&db, "DEFINE TABLE probe SCHEMALESS").await;
    let active = db.execute("SLEEP 300ms; RETURN 1", NO_CAP, CancellationToken::new());
    tokio::pin!(active);
    poll_fn(|cx| {
        assert!(active.as_mut().poll(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    for mode in 0..3 {
        let cancel = CancellationToken::new();
        let mut queued = Box::pin(async {
            match mode {
                0 => db
                    .execute("CREATE probe SET n=1", NO_CAP, cancel.clone())
                    .await
                    .map(|_| ()),
                1 => db
                    .execute_bound(
                        "CREATE probe SET n=$sqmeow_p1",
                        &[Value::Int(1)],
                        NO_CAP,
                        cancel.clone(),
                    )
                    .await
                    .map(|_| ()),
                _ => db
                    .apply(&["CREATE probe SET n=1".into()], cancel.clone())
                    .await
                    .map(|_| ()),
            }
        });
        poll_fn(|cx| {
            assert!(queued.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        cancel.cancel();
        assert!(matches!(
            queued.await,
            Err(sqmeow_db::error::Error::Cancelled)
        ));
    }
    active.await.unwrap();
    assert_eq!(run(&db, "SELECT * FROM probe").await.row_count(), 0);
    db.close().await;
}

// The tests share one namespace and run in parallel, so each works in a database of its own.

/// Held while setting up, since a new server makes the namespace on first use and parallel first
/// uses conflict.
static SETUP: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A connection to a fresh database called `name`.
async fn fresh(url: &str, name: &str) -> Backend {
    let _setup = SETUP.lock().await;
    let setup = Backend::connect(url)
        .await
        .expect("the test server should accept a connection");
    run(
        &setup,
        &format!("REMOVE DATABASE IF EXISTS {name}; DEFINE DATABASE {name}"),
    )
    .await;
    Backend::connect_to(url, Some(name), false)
        .await
        .expect("the test database should open")
}

async fn run(backend: &Backend, statement: &str) -> ResultSet {
    backend
        .execute(statement, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{statement} should run: {error}"))
}

#[tokio::test]
async fn native_parameters_repeat_without_interpolating_text() {
    let backend = fresh(&server!(), "bound_text").await;
    run(&backend, "CREATE person:alice SET name = 'Alice'").await;
    let text = "'; DELETE person; RETURN 'injected'; -- :name $other";
    let result = backend
        .execute_bound(
            "RETURN [$sqmeow_p1, $sqmeow_p1, $sqmeow_p2]",
            &[Value::Text(text.into()), Value::Null(Kind::Int)],
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.row_count(), 3);
    assert_eq!(
        result.cell(0, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Text(text.into()))
    );
    assert_eq!(
        result.cell(1, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Text(text.into()))
    );
    assert_eq!(
        result.cell(2, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Null)
    );
    assert_eq!(run(&backend, "SELECT * FROM person").await.row_count(), 1);
    run(&backend, "REMOVE DATABASE bound_text").await;
    backend.close().await;
}

#[tokio::test]
async fn stale_edits_roll_back_and_computed_results_are_not_editable() {
    let backend = fresh(&server!(), "edit_safety").await;
    run(
        &backend,
        "CREATE person:alice SET age = 3; CREATE person:bob SET age = 4",
    )
    .await;
    for statement in [
        "RETURN 1",
        "SELECT age FROM person",
        "SELECT count() FROM person GROUP ALL",
    ] {
        assert!(
            run(&backend, statement).await.source().is_none(),
            "{statement}"
        );
    }
    let result = run(&backend, "SELECT * FROM person ORDER BY id").await;
    assert!(result.source().is_some());
    let age = result
        .columns()
        .iter()
        .position(|column| column.name == "age")
        .unwrap();
    let changes = Changes {
        updates: vec![(0, vec![(age, "5".into())])],
        deletes: vec![1],
        ..Default::default()
    };
    run(&backend, "DELETE person:bob").await;
    let error = backend
        .apply(
            &backend.plan(&result, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("no record had that id"),
        "{error}"
    );
    assert_eq!(
        run(&backend, "SELECT age FROM person:alice")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&sqmeow_db::value::Cell::Int(3))
    );
    run(&backend, "REMOVE DATABASE edit_safety").await;
    backend.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    let backend = fresh(&server!(), "crud_smoke").await;
    run(&backend, "CREATE person:alice SET name = 'alice'").await;
    let selected = run(&backend, "SELECT name FROM person:alice").await;
    assert_eq!(selected.row_count(), 1);
    assert_eq!(
        selected.cell(0, 0).as_deref(),
        Some(&sqmeow_db::value::Cell::Text("alice".into()))
    );
    run(&backend, "UPDATE person:alice SET name = 'bob'").await;
    assert_eq!(
        run(&backend, "SELECT name FROM person:alice")
            .await
            .cell(0, 0)
            .as_deref(),
        Some(&sqmeow_db::value::Cell::Text("bob".into()))
    );
    run(&backend, "DELETE person:alice").await;
    assert_eq!(run(&backend, "SELECT * FROM person").await.row_count(), 0);
    run(&backend, "REMOVE DATABASE crud_smoke").await;
    backend.close().await;
}

#[tokio::test]
async fn connects_and_lists_the_databases_of_its_namespace() {
    let url = server!();
    fresh(&url, "listed").await;
    let backend = Backend::connect(&url).await.unwrap();
    assert_eq!(backend.dialect().name(), "surrealdb");
    let databases = backend
        .databases()
        .await
        .expect("no database was named")
        .unwrap();
    assert!(databases.contains(&"listed".to_owned()), "{databases:?}");

    let one = Backend::connect_to(&url, Some("listed"), false)
        .await
        .unwrap();
    assert!(one.databases().await.is_none());
    assert_eq!(one.database().as_deref(), Some("listed"));
}

#[tokio::test]
async fn a_transaction_block_answers_with_its_last_statement() {
    let backend = fresh(&server!(), "blocks").await;
    let result = run(
        &backend,
        "BEGIN TRANSACTION; CREATE thing:1 SET n = 1; SELECT * FROM thing; COMMIT TRANSACTION",
    )
    .await;
    assert_eq!(result.row_count(), 1);
    let error = backend
        .execute("SELECT * FROM", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(!error.to_string().is_empty());
}
