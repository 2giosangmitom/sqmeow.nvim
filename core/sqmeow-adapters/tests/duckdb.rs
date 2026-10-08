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
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(1, 1), Some(&Cell::Text("bob".into())));
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
