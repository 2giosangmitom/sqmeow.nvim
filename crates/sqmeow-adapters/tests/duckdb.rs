//! The DuckDB adapter against a real in-memory database.

use sqmeow_adapters::Backend;
use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");

fn cancelled_write(mode: u8) {
    use std::{
        future::{Future, poll_fn},
        task::Poll,
        time::Duration,
    };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let backend = database().await;
        run(&backend, "SET threads=1").await;
        run(&backend, "CREATE TABLE cancelled_writes(id INTEGER)").await;
        for queued in [false, true] {
            let (release, wait) = std::sync::mpsc::channel();
            let (started, ready) = tokio::sync::oneshot::channel();
            let blocking = tokio::task::spawn_blocking(move || {
                started.send(()).unwrap();
                wait.recv().unwrap();
            });
            ready.await.unwrap();
            let cancel = CancellationToken::new();
            let mut work = Box::pin(async {
                match mode {
                    0 => backend
                        .execute(
                            "INSERT INTO cancelled_writes VALUES (1)",
                            NO_CAP,
                            cancel.clone(),
                        )
                        .await
                        .map(|_| ()),
                    1 => backend
                        .execute_bound(
                            "INSERT INTO cancelled_writes VALUES (?)",
                            &[Value::Int(1)],
                            NO_CAP,
                            cancel.clone(),
                        )
                        .await
                        .map(|_| ()),
                    _ => backend
                        .apply(
                            &["INSERT INTO cancelled_writes VALUES (1)".into()],
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
            let release_task = tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(1)).await;
                release.send(()).unwrap();
            });
            let outcome = tokio::time::timeout(Duration::from_secs(3), work)
                .await
                .unwrap();
            blocking.await.unwrap();
            release_task.await.unwrap();
            assert!(matches!(outcome, Err(Error::Cancelled)));
            let rows = backend
                .execute(
                    "SELECT * FROM cancelled_writes",
                    NO_CAP,
                    CancellationToken::new(),
                )
                .await
                .unwrap();
            assert_eq!(
                rows.row_count(),
                0,
                "cancelled queued work must never reach SQL"
            );
        }
        backend.close().await;
    });
}

#[test]
fn cancelled_execute_never_starts_a_queued_write() {
    cancelled_write(0);
}

#[test]
fn cancelled_bound_execute_never_starts_a_queued_write() {
    cancelled_write(1);
}

#[test]
fn cancelled_apply_never_starts_a_queued_transaction() {
    cancelled_write(2);
}

#[tokio::test(flavor = "current_thread")]
async fn cancelling_queued_work_does_not_interrupt_the_active_query() {
    use std::{
        future::{Future, poll_fn},
        task::Poll,
        time::Duration,
    };
    let backend = database().await;
    run(&backend, "SET threads=1").await;
    let active = backend.execute(
        "SELECT sum(i) FROM range(100000000) AS t(i)",
        NO_CAP,
        CancellationToken::new(),
    );
    tokio::pin!(active);
    poll_fn(|cx| {
        assert!(active.as_mut().poll(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    tokio::time::sleep(Duration::from_millis(10)).await;
    let cancel = CancellationToken::new();
    let queued = backend.execute("SELECT 2", NO_CAP, cancel.clone());
    tokio::pin!(queued);
    poll_fn(|cx| {
        assert!(queued.as_mut().poll(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    cancel.cancel();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(3), queued)
            .await
            .unwrap(),
        Err(Error::Cancelled)
    ));
    let rows = tokio::time::timeout(Duration::from_secs(5), active)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(rows.row_count(), 1);
    backend.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn cancelling_active_work_keeps_the_connection_usable() {
    use std::time::Duration;
    let backend = database().await;
    run(&backend, "SET threads=1").await;
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let query = backend.execute(
        "SELECT sum(a.i * b.i) FROM range(1000000) AS a(i), range(1000000) AS b(i)",
        NO_CAP,
        cancel,
    );
    let timer = async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        stop.cancel();
    };
    let (outcome, ()) =
        tokio::time::timeout(Duration::from_secs(5), async { tokio::join!(query, timer) })
            .await
            .unwrap();
    assert!(matches!(outcome, Err(Error::Cancelled)));
    run(&backend, "SELECT 1").await;
    backend.close().await;
}

#[tokio::test(flavor = "current_thread")]
async fn abandoning_apply_rolls_back_before_the_next_request() {
    use std::time::Duration;
    let backend = database().await;
    run(&backend, "SET threads=1").await;
    run(
        &backend,
        "CREATE TABLE abandoned(id INTEGER); INSERT INTO abandoned VALUES (1)",
    )
    .await;
    let statements = [
        "UPDATE abandoned SET id=2".into(),
        "SELECT sum(a.i * b.i) FROM range(1000000) AS a(i), range(1000000) AS b(i)".into(),
    ];
    assert!(
        tokio::time::timeout(
            Duration::from_millis(50),
            backend.apply(&statements, CancellationToken::new())
        )
        .await
        .is_err()
    );
    let rows = tokio::time::timeout(
        Duration::from_secs(5),
        backend.execute("SELECT id FROM abandoned", NO_CAP, CancellationToken::new()),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(rows.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    backend.close().await;
}

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    let backend = database().await;
    run(&backend, "create schema \"schema.with.dot\"").await;
    run(&backend, "create table \"schema.with.dot\".\"parent.\"\"table\" (a integer, b integer, primary key (b, a))").await;
    run(&backend, "create table \"schema.with.dot\".\"child.\"\"table\" (c integer, d integer, e integer, f integer, foreign key (d, c) references \"schema.with.dot\".\"parent.\"\"table\" (b, a), foreign key (e, f) references \"schema.with.dot\".\"parent.\"\"table\" (b, a))").await;
    let outgoing = backend
        .relationships("schema.with.dot", "child.\"table")
        .await
        .unwrap();
    let incoming = backend
        .relationships("schema.with.dot", "parent.\"table")
        .await
        .unwrap();
    assert_eq!(outgoing, incoming);
    assert_eq!(outgoing.len(), 2);
    let key = outgoing
        .iter()
        .find(|key| key.columns == ["d", "c"])
        .unwrap();
    assert_eq!(key.source_schema, "schema.with.dot");
    assert_eq!(key.source_relation, "child.\"table");
    assert_eq!(key.target_schema, "schema.with.dot");
    assert_eq!(key.target_relation, "parent.\"table");
    assert_eq!(key.referenced, ["b", "a"]);
    backend.close().await;
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    failed_apply_rolls_back(
        &database().await,
        "create table sqmeow_rollback_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let text = "alice' OR true; DROP TABLE people; -- :name ?";
    bound_values_remain_data(
        &database().await,
        "select cast(? as varchar), cast(? as varchar), cast(? as integer)",
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
async fn a_read_only_file_is_refused_writes_by_duckdb() {
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join("opencode");
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join(format!("sqmeow-ro-{}-{suffix}.duckdb", std::process::id()));
    let url = format!("duckdb:{}", path.display());
    let writer = Backend::connect(&url).await.unwrap();
    run(&writer, "create table t (id integer)").await;
    writer.close().await;
    let backend = Backend::connect_to(&url, None, true).await.unwrap();
    run(&backend, "select * from t").await;
    let error = backend
        .execute("insert into t values (1)", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("read-only"), "{error}");
    backend.close().await;
    std::fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn grouped_rows_have_no_editable_source() {
    let backend = database().await;
    run(
        &backend,
        "create table grouped_people (id integer primary key, name varchar)",
    )
    .await;
    run(
        &backend,
        "insert into grouped_people values (1, 'alice'), (2, 'alice')",
    )
    .await;
    assert!(
        run(
            &backend,
            "select name, count(*) from grouped_people group by name"
        )
        .await
        .source()
        .is_none()
    );
    backend.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    crud_round_trip(
        &database().await,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

async fn database() -> Backend {
    Backend::connect("duckdb::memory:")
        .await
        .expect("an in-memory database should open")
}

async fn run(backend: &Backend, sql: &str) -> sqmeow_db::result::ResultSet {
    backend
        .execute(sql, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{sql} should run: {error}"))
}

#[tokio::test]
async fn opens_an_in_memory_database() {
    assert_eq!(database().await.dialect().name(), "duckdb");
}

#[tokio::test]
async fn reads_back_rows_it_wrote() {
    let backend = database().await;
    run(
        &backend,
        "create table people (id integer primary key, name varchar)",
    )
    .await;
    run(
        &backend,
        "insert into people values (1, 'alice'), (2, 'bob')",
    )
    .await;

    let result = run(&backend, "select id, name from people order by id").await;
    assert_eq!(result.row_count(), 2);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(
        result.cell(1, 1).as_deref(),
        Some(&Cell::Text("bob".into()))
    );
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = database().await;
    let result = backend
        .execute("select * from range(1000)", 10, CancellationToken::new())
        .await
        .expect("the query should run");
    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = database().await;
    let error = backend
        .execute("select from where", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
    assert_eq!(run(&backend, "select 1").await.row_count(), 1);
}
