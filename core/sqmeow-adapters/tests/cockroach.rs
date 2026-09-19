//! The PostgreSQL adapter against a real CockroachDB server.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, Dialect, Error, RelationKind, ResultSet, Source};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

const SCHEMA: &str = "public";

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_COCKROACH_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_COCKROACH_URL, or run `just db-up`");
                return;
            }
        }
    };
}

async fn connect(url: &str) -> Backend {
    Backend::connect(url)
        .await
        .expect("the test server should accept a connection")
}

async fn run(backend: &Backend, sql: &str) -> ResultSet {
    backend
        .execute(sql, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{sql} should run: {error}"))
}

async fn fixture(backend: &Backend, table: &str) {
    run(backend, &format!("drop table if exists {table} cascade")).await;
    run(
        backend,
        &format!("create table {table} (id int primary key, label text not null, optional text)"),
    )
    .await;
}

fn text(value: &str) -> Cell {
    Cell::Text(value.into())
}

#[tokio::test]
async fn the_server_really_is_cockroach() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect(), Dialect::Postgres);
    let result = run(&backend, "select version()").await;
    let version = result.cell(0, 0).unwrap().text("").into_owned();
    assert!(version.starts_with("CockroachDB"), "{version}");
}

#[tokio::test]
async fn lists_schemas_tables_and_columns() {
    let backend = connect(&server!()).await;
    fixture(&backend, "crdb_listed").await;

    let schemas = backend.schemas().await.expect("schemas should load");
    assert!(schemas.iter().any(|schema| schema.name == SCHEMA));

    let relations = backend
        .relations(SCHEMA)
        .await
        .expect("relations should load");
    let listed = relations
        .iter()
        .find(|relation| relation.name == "crdb_listed");
    assert_eq!(
        listed.map(|relation| relation.kind),
        Some(RelationKind::Table)
    );

    let columns = backend.columns(SCHEMA, "crdb_listed").await.unwrap();
    let names: Vec<_> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "label", "optional"]);
}

#[tokio::test]
async fn a_select_from_one_table_is_edited_through_its_primary_key() {
    let backend = connect(&server!()).await;
    fixture(&backend, "crdb_edited").await;
    run(
        &backend,
        "insert into crdb_edited values (1, 'a', null), (2, 'b', 'x')",
    )
    .await;

    let result = run(
        &backend,
        "select id, label, optional from crdb_edited order by id",
    )
    .await;
    match result.source() {
        Some(Source::Tables(tables)) => assert_eq!(tables[0].key, vec![0]),
        other => panic!("expected a table source, got {other:?}"),
    }

    let changes = Changes {
        updates: vec![(0, vec![(1, "changed".into())])],
        deletes: vec![1],
        inserts: vec![vec![
            (0, "3".into()),
            (1, "new".into()),
            (2, sqmeow_db::edit::Value::Null),
        ]],
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the changes should plan");
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    let after = run(
        &backend,
        "select id, label, optional from crdb_edited order by id",
    )
    .await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&text("changed")));
    assert_eq!(after.cell(1, 0), Some(&Cell::Int(3)));
    assert_eq!(after.cell(1, 2), Some(&Cell::Null));
}

#[tokio::test]
async fn cancelling_mid_query_stops_it_and_keeps_the_connection() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();
    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        stopper.cancel();
    });

    let error = backend
        .execute("select pg_sleep(30)", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
    run(&backend, "select 1").await;
}

#[tokio::test]
async fn a_read_only_connection_is_refused_writes_by_the_server() {
    let backend = Backend::connect_to(&server!(), None, true).await.unwrap();
    assert!(!backend.read_only_unenforced());
    run(
        &backend,
        "select set_config('default_transaction_read_only', 'off', false)",
    )
    .await;
    let error = backend
        .execute(
            "create table crdb_read_only_probe (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("read-only"), "{error}");
}
