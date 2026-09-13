//! The MongoDB adapter against a real server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_MONGODB_URL` these tests report that they were skipped rather than failing, so
//! `cargo test` still works on a machine with no Docker.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, RelationKind, ResultSet};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_MONGODB_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_MONGODB_URL, or run `just db-up`");
                return;
            }
        }
    };
}

// The tests share one database and run in parallel, so each one owns a collection of its own and
// empties it first.

async fn connect(url: &str) -> Backend {
    Backend::connect(url)
        .await
        .expect("the test server should accept a connection")
}

async fn run(backend: &Backend, command: &str) -> ResultSet {
    backend
        .execute(command, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{command} should run: {error}"))
}

async fn empty(backend: &Backend, collection: &str) {
    run(
        backend,
        &format!(r#"{{"delete": "{collection}", "deletes": [{{"q": {{}}, "limit": 0}}]}}"#),
    )
    .await;
}

fn names(result: &ResultSet) -> Vec<&str> {
    result.columns().iter().map(|c| c.name.as_str()).collect()
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect().name(), "mongodb");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("mongodb://127.0.0.1:1/x?serverSelectionTimeoutMS=500")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn reads_back_documents_it_inserted() {
    let backend = connect(&server!()).await;
    empty(&backend, "insert_find").await;

    let inserted = run(
        &backend,
        r#"{"insert": "insert_find", "documents": [
            {"_id": 1, "name": "alice", "tags": ["a"]},
            {"_id": 2, "name": "bob", "age": 30}
        ]}"#,
    )
    .await;
    assert_eq!(inserted.affected(), Some(2));

    let found = run(&backend, r#"{"find": "insert_find", "sort": {"_id": 1}}"#).await;
    assert_eq!(names(&found), vec!["_id", "name", "tags", "age"]);
    assert_eq!(found.cell(0, 1), Some(&Cell::Text("alice".into())));
    assert_eq!(found.cell(0, 2), Some(&Cell::Json(r#"["a"]"#.into())));
    assert_eq!(found.cell(1, 2), Some(&Cell::Null));
    assert_eq!(found.cell(1, 3), Some(&Cell::Int(30)));
}

#[tokio::test]
async fn aggregates() {
    let backend = connect(&server!()).await;
    empty(&backend, "aggregate").await;
    run(
        &backend,
        r#"{"insert": "aggregate", "documents": [{"s": "a"}, {"s": "a"}, {"s": "b"}]}"#,
    )
    .await;

    let result = run(
        &backend,
        r#"{"aggregate": "aggregate", "cursor": {}, "pipeline": [
            {"$group": {"_id": "$s", "n": {"$sum": 1}}},
            {"$sort": {"_id": 1}}
        ]}"#,
    )
    .await;
    assert_eq!(names(&result), vec!["_id", "n"]);
    assert_eq!(result.row_count(), 2);
    assert_eq!(result.cell(0, 1), Some(&Cell::Int(2)));
}

#[tokio::test]
async fn use_switches_database_and_db_does_not() {
    let backend = connect(&server!()).await;
    run(&backend, "use sqmeow_other").await;
    empty(&backend, "moved").await;
    run(&backend, r#"{"insert": "moved", "documents": [{"x": 1}]}"#).await;

    assert_eq!(run(&backend, r#"{"find": "moved"}"#).await.row_count(), 1);
    let elsewhere = run(&backend, r#"{"find": "moved", "$db": "sqmeow_empty"}"#).await;
    assert_eq!(elsewhere.row_count(), 0);

    // `$db` read another database without leaving this one.
    let schemas = backend.schemas().await.unwrap();
    let current = schemas.iter().find(|schema| schema.is_default).unwrap();
    assert_eq!(current.name, "sqmeow_other");
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = connect(&server!()).await;
    empty(&backend, "capped").await;
    let documents: Vec<String> = (1..=20).map(|n| format!(r#"{{"n": {n}}}"#)).collect();
    run(
        &backend,
        &format!(
            r#"{{"insert": "capped", "documents": [{}]}}"#,
            documents.join(",")
        ),
    )
    .await;

    let result = backend
        .execute(r#"{"find": "capped"}"#, 3, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.row_count(), 3);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute(r#"{"nope": 1}"#, NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(
        error.to_string().to_lowercase().contains("no such command"),
        "{error}"
    );

    let ping = run(&backend, r#"{"ping": 1}"#).await;
    assert_eq!(names(&ping), vec!["ok"]);
}

#[tokio::test]
async fn lists_databases_collections_and_fields() {
    let backend = connect(&server!()).await;
    empty(&backend, "drawer_fields").await;
    run(
        &backend,
        r#"{"insert": "drawer_fields", "documents": [{"_id": 1, "name": "a", "n": 1}, {"_id": 2, "name": null}]}"#,
    )
    .await;
    run(&backend, r#"{"drop": "drawer_view"}"#).await;
    run(
        &backend,
        r#"{"create": "drawer_view", "viewOn": "drawer_fields", "pipeline": []}"#,
    )
    .await;

    let schemas = backend.schemas().await.unwrap();
    assert!(
        schemas
            .iter()
            .any(|schema| schema.name == "sqmeow" && schema.is_default)
    );

    let relations = backend.relations("sqmeow").await.unwrap();
    let kind = |name: &str| relations.iter().find(|r| r.name == name).map(|r| r.kind);
    assert_eq!(kind("drawer_fields"), Some(RelationKind::Table));
    assert_eq!(kind("drawer_view"), Some(RelationKind::View));

    let columns = backend.columns("sqmeow", "drawer_fields").await.unwrap();
    let column = |name: &str| columns.iter().find(|c| c.name == name).unwrap();
    assert!(column("_id").primary_key);
    assert!(column("name").nullable);
    assert!(column("n").nullable);
    assert_eq!(column("name").type_name, "string");
}

#[tokio::test]
async fn a_url_without_a_database_lists_every_database() {
    let url = server!();
    let (root, _) = url.rsplit_once('/').expect("the test URL names a database");
    let root = format!("{root}/");

    // A database is only listed once it holds something.
    let one = Backend::connect_to(&root, Some("sqmeow_listed"))
        .await
        .expect("one database of the server should open");
    empty(&one, "listed").await;
    run(&one, r#"{"insert": "listed", "documents": [{"x": 1}]}"#).await;
    assert!(one.databases().await.is_none());
    let schemas = one.schemas().await.unwrap();
    assert_eq!(schemas.len(), 1);
    assert_eq!(schemas[0].name, "sqmeow_listed");

    let server = connect(&root).await;
    let databases = server
        .databases()
        .await
        .expect("a URL without a database lists them")
        .unwrap();
    assert!(
        databases.iter().any(|name| name == "sqmeow_listed"),
        "{databases:?}"
    );
}
