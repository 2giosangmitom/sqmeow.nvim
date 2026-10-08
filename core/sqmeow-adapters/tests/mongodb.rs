//! The MongoDB adapter against a real server.

use sqmeow_db::edit::{Changes, Source};
use sqmeow_db::error::Error;
use sqmeow_db::value::Cell;

include!("common/harness.rs");

// The tests share one database and run in parallel.

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
async fn only_a_find_keeping_its_ids_can_be_edited() {
    let backend = connect(&server!("SQMEOW_TEST_MONGODB_URL")).await;
    empty(&backend, "projected").await;
    run(
        &backend,
        r#"{"insert": "projected", "documents": [{"_id": 1, "v": 1}]}"#,
    )
    .await;
    let kept = run(&backend, r#"{"find": "projected", "projection": {"v": 1}}"#).await;
    assert!(kept.source().is_some());
    let dropped = run(
        &backend,
        r#"{"find": "projected", "projection": {"_id": 0}}"#,
    )
    .await;
    assert!(dropped.source().is_none());
    let elsewhere = run(
        &backend,
        r#"{"find": "projected_nowhere", "$db": "sqmeow_empty"}"#,
    )
    .await;
    assert!(
        matches!(elsewhere.source(), Some(Source::Collection { db, .. }) if db == "sqmeow_empty")
    );
    let changes = Changes {
        updates: vec![(0, vec![(1, "2".into())])],
        ..Default::default()
    };
    backend
        .apply(
            &backend.plan(&kept, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let updated = run(&backend, r#"{"find": "projected"}"#).await;
    let value = names(&updated)
        .iter()
        .position(|name| *name == "v")
        .unwrap();
    assert_eq!(updated.cell(0, value).as_deref(), Some(&Cell::Int(2)));
    run(&backend, r#"{"drop": "projected"}"#).await;
    backend.close().await;
}

#[tokio::test]
async fn a_write_the_server_refuses_fails_the_apply() {
    let backend = connect(&server!("SQMEOW_TEST_MONGODB_URL")).await;
    empty(&backend, "refused").await;
    run(
        &backend,
        r#"{"insert": "refused", "documents": [{"_id": 1}]}"#,
    )
    .await;
    let found = run(&backend, r#"{"find": "refused"}"#).await;
    let changes = Changes {
        inserts: vec![vec![(0, "1".into())]],
        ..Default::default()
    };
    let error = backend
        .apply(
            &backend.plan(&found, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("E11000"), "{error}");
    run(&backend, r#"{"drop": "refused"}"#).await;
    backend.close().await;
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!("SQMEOW_TEST_MONGODB_URL")).await;
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
async fn commands_create_read_update_and_delete_rows() {
    let backend = connect(&server!("SQMEOW_TEST_MONGODB_URL")).await;
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
            .any(|relation| relation.name == "insert_find")
    );
    assert!(
        backend
            .columns(&schema.name, "insert_find")
            .await
            .unwrap()
            .iter()
            .any(|column| column.name == "_id" && column.primary_key)
    );

    let found = run(&backend, r#"{"find": "insert_find", "sort": {"_id": 1}}"#).await;
    assert_eq!(names(&found), vec!["_id", "name", "tags", "age"]);
    assert_eq!(
        found.cell(0, 1).as_deref(),
        Some(&Cell::Text("alice".into()))
    );
    assert_eq!(
        found.cell(0, 2).as_deref(),
        Some(&Cell::Json(r#"["a"]"#.into()))
    );
    assert_eq!(found.cell(1, 2).as_deref(), Some(&Cell::Null));
    assert_eq!(found.cell(1, 3).as_deref(), Some(&Cell::Int(30)));
    run(&backend, r#"{"update": "insert_find", "updates": [{"q": {"_id": 1}, "u": {"$set": {"name": "updated"}}}]}"#).await;
    let updated = run(&backend, r#"{"find": "insert_find", "filter": {"_id": 1}}"#).await;
    let name = names(&updated)
        .iter()
        .position(|name| *name == "name")
        .unwrap();
    assert_eq!(
        updated.cell(0, name).as_deref(),
        Some(&Cell::Text("updated".into()))
    );
    empty(&backend, "insert_find").await;
    assert_eq!(
        run(&backend, r#"{"find": "insert_find"}"#)
            .await
            .row_count(),
        0
    );
    run(&backend, r#"{"drop": "insert_find"}"#).await;
    backend.close().await;
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = connect(&server!("SQMEOW_TEST_MONGODB_URL")).await;
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
