//! The MongoDB adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, Error, RelationKind, ResultSet, Source};
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

// The tests share one database and run in parallel.

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
    let one = Backend::connect_to(&root, Some("sqmeow_listed"), false)
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

/// Empty a collection and insert these documents, given as a JSON array.
async fn seed(backend: &Backend, collection: &str, documents: &str) {
    empty(backend, collection).await;
    run(
        backend,
        &format!(r#"{{"insert": "{collection}", "documents": {documents}}}"#),
    )
    .await;
}

fn column(result: &ResultSet, name: &str) -> usize {
    result
        .columns()
        .iter()
        .position(|column| column.name == name)
        .unwrap_or_else(|| panic!("no column {name} in {:?}", names(result)))
}

#[tokio::test]
async fn count_and_distinct_answer_in_one_document() {
    let backend = connect(&server!()).await;
    seed(
        &backend,
        "counted",
        r#"[{"k": "a"}, {"k": "a"}, {"k": "b"}]"#,
    )
    .await;

    let counted = run(&backend, r#"{"count": "counted", "query": {"k": "a"}}"#).await;
    assert_eq!(counted.row_count(), 1);
    assert_eq!(counted.cell(0, column(&counted, "n")), Some(&Cell::Int(2)));
    // Reading is not writing, so nothing claims to have been changed.
    assert_eq!(counted.affected(), None);

    let distinct = run(&backend, r#"{"distinct": "counted", "key": "k"}"#).await;
    match distinct.cell(0, column(&distinct, "values")) {
        Some(Cell::Json(values)) => {
            assert!(
                values.contains(r#""a""#) && values.contains(r#""b""#),
                "{values}"
            );
        }
        other => panic!("expected the values as JSON, got {other:?}"),
    }
}

#[tokio::test]
async fn updates_upserts_and_deletes_count_what_they_changed() {
    let backend = connect(&server!()).await;
    seed(
        &backend,
        "written",
        r#"[{"k": "a"}, {"k": "a"}, {"k": "b"}]"#,
    )
    .await;

    let updated = run(
        &backend,
        r#"{"update": "written", "updates": [
            {"q": {"k": "a"}, "u": {"$set": {"seen": true}}, "multi": true}
        ]}"#,
    )
    .await;
    assert_eq!(updated.affected(), Some(2));

    let upserted = run(
        &backend,
        r#"{"update": "written", "updates": [
            {"q": {"k": "z"}, "u": {"$set": {"k": "z"}}, "upsert": true}
        ]}"#,
    )
    .await;
    assert_eq!(upserted.affected(), Some(1));

    let deleted = run(
        &backend,
        r#"{"delete": "written", "deletes": [{"q": {"k": "b"}, "limit": 0}]}"#,
    )
    .await;
    assert_eq!(deleted.affected(), Some(1));

    let seen = run(&backend, r#"{"count": "written", "query": {"seen": true}}"#).await;
    assert_eq!(seen.cell(0, column(&seen, "n")), Some(&Cell::Int(2)));
}

#[tokio::test]
async fn find_and_modify_answers_with_the_document() {
    let backend = connect(&server!()).await;
    seed(&backend, "modified", r#"[{"_id": 1, "n": 1}]"#).await;

    let result = run(
        &backend,
        r#"{"findAndModify": "modified", "query": {"_id": 1}, "update": {"$inc": {"n": 1}}, "new": true}"#,
    )
    .await;
    assert_eq!(
        result.cell(0, column(&result, "value")),
        Some(&Cell::Json(r#"{"_id":1,"n":2}"#.into()))
    );
}

#[tokio::test]
async fn a_cursor_is_read_past_its_first_batch() {
    let backend = connect(&server!()).await;
    let documents: Vec<String> = (0..250).map(|n| format!(r#"{{"n": {n}}}"#)).collect();
    seed(&backend, "batched", &format!("[{}]", documents.join(","))).await;

    for command in [
        r#"{"find": "batched"}"#,
        r#"{"find": "batched", "batchSize": 7}"#,
        r#"{"aggregate": "batched", "pipeline": [], "cursor": {"batchSize": 7}}"#,
    ] {
        let result = run(&backend, command).await;
        assert_eq!(result.row_count(), 250, "{command}");
        assert!(!result.is_truncated(), "{command}");
    }
}

#[tokio::test]
async fn an_aggregate_joins_unwinds_and_projects() {
    let backend = connect(&server!()).await;
    seed(
        &backend,
        "join_authors",
        r#"[{"_id": 1, "name": "ann"}, {"_id": 2, "name": "bo"}]"#,
    )
    .await;
    seed(
        &backend,
        "join_books",
        r#"[{"_id": 10, "author": 1, "title": "x"}, {"_id": 11, "author": 1, "title": "y"}, {"_id": 12, "author": 2, "title": "z"}]"#,
    )
    .await;

    let result = run(
        &backend,
        r#"{"aggregate": "join_books", "cursor": {}, "pipeline": [
            {"$lookup": {"from": "join_authors", "localField": "author", "foreignField": "_id", "as": "by"}},
            {"$unwind": "$by"},
            {"$match": {"by.name": "ann"}},
            {"$project": {"_id": 0, "title": 1, "writer": "$by.name"}},
            {"$sort": {"title": 1}}
        ]}"#,
    )
    .await;

    assert_eq!(result.row_count(), 2);
    let (title, writer) = (column(&result, "title"), column(&result, "writer"));
    assert_eq!(result.cell(1, title), Some(&Cell::Text("y".into())));
    assert_eq!(result.cell(1, writer), Some(&Cell::Text("ann".into())));
    // Rows an aggregate made are nobody's documents, so they cannot be edited.
    assert!(result.source().is_none());
}

#[tokio::test]
async fn creates_and_lists_indexes_and_collections() {
    let backend = connect(&server!()).await;
    seed(&backend, "indexed", r#"[{"email": "a@x"}]"#).await;
    run(&backend, r#"{"dropIndexes": "indexed", "index": "*"}"#).await;
    run(
        &backend,
        r#"{"createIndexes": "indexed", "indexes": [{"key": {"email": 1}, "name": "email_1", "unique": true}]}"#,
    )
    .await;

    let indexes = run(&backend, r#"{"listIndexes": "indexed"}"#).await;
    let name = column(&indexes, "name");
    let listed: Vec<Option<&Cell>> = (0..indexes.row_count())
        .map(|row| indexes.cell(row, name))
        .collect();
    assert!(
        listed.contains(&Some(&Cell::Text("_id_".into()))),
        "{listed:?}"
    );
    assert!(
        listed.contains(&Some(&Cell::Text("email_1".into()))),
        "{listed:?}"
    );

    let collections = run(
        &backend,
        r#"{"listCollections": 1, "filter": {"name": "indexed"}}"#,
    )
    .await;
    assert_eq!(collections.row_count(), 1);
    assert_eq!(
        collections.cell(0, column(&collections, "name")),
        Some(&Cell::Text("indexed".into()))
    );
}

#[tokio::test]
async fn creates_renames_and_drops_a_collection() {
    let backend = connect(&server!()).await;
    run(&backend, r#"{"drop": "made"}"#).await;
    run(&backend, r#"{"drop": "renamed"}"#).await;
    run(&backend, r#"{"create": "made"}"#).await;
    run(
        &backend,
        r#"{"renameCollection": "sqmeow.made", "to": "sqmeow.renamed", "$db": "admin"}"#,
    )
    .await;

    let relations = backend.relations("sqmeow").await.unwrap();
    assert!(
        relations.iter().any(|r| r.name == "renamed"),
        "{relations:?}"
    );
    assert!(!relations.iter().any(|r| r.name == "made"), "{relations:?}");

    run(&backend, r#"{"drop": "renamed"}"#).await;
    let relations = backend.relations("sqmeow").await.unwrap();
    assert!(
        !relations.iter().any(|r| r.name == "renamed"),
        "{relations:?}"
    );
}

#[tokio::test]
async fn documents_found_by_object_id_are_edited_added_and_removed() {
    let backend = connect(&server!()).await;
    // No `_id` is given, so the server makes each an ObjectId.
    seed(
        &backend,
        "edited",
        r#"[{"name": "al", "n": 1}, {"name": "bo", "n": 2}]"#,
    )
    .await;

    let found = run(&backend, r#"{"find": "edited", "sort": {"n": 1}}"#).await;
    assert_eq!(names(&found), vec!["_id", "name", "n"]);
    assert_eq!(found.columns()[0].type_name, "objectId");
    assert!(
        matches!(found.source(), Some(Source::Collection { db, name }) if db == "sqmeow" && name == "edited"),
        "{:?}",
        found.source()
    );

    let changes = Changes {
        updates: vec![(0, vec![(1, "alice".into()), (2, "10".into())])],
        deletes: vec![1],
        // A quoted number stays text.
        inserts: vec![vec![(1, r#""007""#.into()), (2, "3".into())]],
    };
    let plan = backend
        .plan(&found, &changes)
        .expect("the changes should plan");
    assert_eq!(plan.len(), 3);
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    let after = run(&backend, r#"{"find": "edited", "sort": {"n": 1}}"#).await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&Cell::Text("007".into())));
    assert_eq!(after.cell(0, 2), Some(&Cell::Int(3)));
    assert_eq!(after.cell(1, 1), Some(&Cell::Text("alice".into())));
    assert_eq!(after.cell(1, 2), Some(&Cell::Int(10)));
}

#[tokio::test]
async fn only_a_find_keeping_its_ids_can_be_edited() {
    let backend = connect(&server!()).await;
    seed(&backend, "projected", r#"[{"_id": 1, "v": 1}]"#).await;

    let kept = run(&backend, r#"{"find": "projected", "projection": {"v": 1}}"#).await;
    assert!(kept.source().is_some());
    let dropped = run(
        &backend,
        r#"{"find": "projected", "projection": {"_id": 0}}"#,
    )
    .await;
    assert!(dropped.source().is_none());

    // Edits go to the database the find read, not the one the connection is on.
    let elsewhere = run(
        &backend,
        r#"{"find": "projected_nowhere", "$db": "sqmeow_empty"}"#,
    )
    .await;
    assert!(
        matches!(elsewhere.source(), Some(Source::Collection { db, .. }) if db == "sqmeow_empty"),
        "{:?}",
        elsewhere.source()
    );
}

#[tokio::test]
async fn a_write_the_server_refuses_fails_the_apply() {
    let backend = connect(&server!()).await;
    seed(&backend, "refused", r#"[{"_id": 1}]"#).await;
    let found = run(&backend, r#"{"find": "refused"}"#).await;

    let changes = Changes {
        inserts: vec![vec![(0, "1".into())]],
        ..Changes::default()
    };
    let plan = backend.plan(&found, &changes).unwrap();
    let error = backend
        .apply(&plan, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("E11000"), "{error}");
}

#[tokio::test]
async fn an_edit_to_a_document_deleted_since_is_reported() {
    let backend = connect(&server!()).await;
    seed(&backend, "vanished", r#"[{"_id": "gone", "v": 1}]"#).await;
    let found = run(&backend, r#"{"find": "vanished"}"#).await;
    empty(&backend, "vanished").await;

    let changes = Changes {
        updates: vec![(0, vec![(1, "2".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&found, &changes).unwrap();
    let error = backend
        .apply(&plan, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("no document had that _id"),
        "{error}"
    );
}

#[tokio::test]
async fn cancelling_a_slow_command_stops_it_and_keeps_working() {
    let backend = connect(&server!()).await;
    seed(&backend, "slow", r#"[{"x": 1}]"#).await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopper.cancel();
    });

    let error = backend
        .execute(
            r#"{"find": "slow", "filter": {"$where": "sleep(3000) || true"}}"#,
            NO_CAP,
            cancel,
        )
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");

    let ping = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        backend.execute(r#"{"ping": 1}"#, NO_CAP, CancellationToken::new()),
    )
    .await;
    assert!(
        matches!(ping, Ok(Ok(_))),
        "the connection should answer at once"
    );
}

#[tokio::test]
async fn extended_json_values_are_stored_and_read_back_as_their_types() {
    let backend = connect(&server!()).await;
    seed(
        &backend,
        "typed",
        r#"[{
            "_id": 1,
            "at": {"$date": "2026-01-02T03:04:05Z"},
            "price": {"$numberDecimal": "1.50"},
            "big": {"$numberLong": "9007199254740993"},
            "ratio": 0.25,
            "ident": {"$binary": {"base64": "AAAAAAAAQACAAAAAAAAAAA==", "subType": "04"}},
            "flag": true,
            "nested": {"a": [1, 2]},
            "nothing": null,
            "pattern": {"$regularExpression": {"pattern": "^a", "options": "i"}}
        }]"#,
    )
    .await;

    let found = run(&backend, r#"{"find": "typed"}"#).await;
    let at = |name: &str| found.cell(0, column(&found, name)).cloned();
    assert_eq!(
        at("at"),
        Some(Cell::Timestamp("2026-01-02T03:04:05Z".into()))
    );
    assert_eq!(found.columns()[column(&found, "at")].type_name, "date");
    assert_eq!(at("price"), Some(Cell::Decimal("1.50".into())));
    assert_eq!(at("big"), Some(Cell::Int(9_007_199_254_740_993)));
    assert_eq!(at("ratio"), Some(Cell::Float(0.25)));
    assert_eq!(
        at("ident"),
        Some(Cell::Uuid("00000000-0000-4000-8000-000000000000".into()))
    );
    assert_eq!(at("flag"), Some(Cell::Bool(true)));
    assert_eq!(at("nested"), Some(Cell::Json(r#"{"a":[1,2]}"#.into())));
    assert_eq!(at("nothing"), Some(Cell::Null));
    match at("pattern") {
        Some(Cell::Unsupported { type_name, raw }) => {
            assert_eq!(type_name, "regex");
            assert!(raw.contains("^a"), "{raw}");
        }
        other => panic!("expected the regex kept as its JSON, got {other:?}"),
    }

    // A typed value in a filter matches the stored one.
    let dated = run(
        &backend,
        r#"{"find": "typed", "filter": {"at": {"$gte": {"$date": "2026-01-01T00:00:00Z"}}, "price": {"$numberDecimal": "1.50"}}}"#,
    )
    .await;
    assert_eq!(dated.row_count(), 1);
}

#[tokio::test]
async fn server_and_database_commands_answer_one_row() {
    let backend = connect(&server!()).await;

    let info = run(&backend, r#"{"buildInfo": 1}"#).await;
    assert!(
        matches!(info.cell(0, column(&info, "version")), Some(Cell::Text(version)) if !version.is_empty())
    );

    let stats = run(&backend, r#"{"dbStats": 1}"#).await;
    assert_eq!(
        stats.cell(0, column(&stats, "db")),
        Some(&Cell::Text("sqmeow".into()))
    );

    let databases = run(
        &backend,
        r#"{"listDatabases": 1, "nameOnly": true, "$db": "admin"}"#,
    )
    .await;
    assert!(matches!(
        databases.cell(0, column(&databases, "databases")),
        Some(Cell::Json(_))
    ));

    seed(&backend, "explained", r#"[{"x": 1}]"#).await;
    let plan = run(
        &backend,
        r#"{"explain": {"find": "explained", "filter": {"x": 1}}, "verbosity": "queryPlanner"}"#,
    )
    .await;
    assert!(matches!(
        plan.cell(0, column(&plan, "queryPlanner")),
        Some(Cell::Json(_))
    ));
    assert!(plan.source().is_none());
}

#[tokio::test]
async fn lists_a_collections_indexes() {
    let backend = connect(&server!()).await;
    run(&backend, r#"{"drop": "indexed_docs"}"#).await;
    run(
        &backend,
        r#"{"createIndexes": "indexed_docs", "indexes": [
            {"key": {"email": 1}, "name": "email_1", "unique": true},
            {"key": {"n": -1, "tag": 1}, "name": "mixed"}
        ]}"#,
    )
    .await;

    let indexes = backend.indexes("sqmeow", "indexed_docs").await.unwrap();
    let listed: Vec<(&str, Vec<&str>, bool, bool)> = indexes
        .iter()
        .map(|index| {
            let columns = index.columns.iter().map(String::as_str).collect();
            (index.name.as_str(), columns, index.unique, index.primary)
        })
        .collect();
    assert_eq!(
        listed,
        vec![
            ("_id_", vec!["_id"], true, true),
            ("email_1", vec!["email"], true, false),
            ("mixed", vec!["n -1", "tag"], false, false),
        ]
    );
}

#[tokio::test]
async fn cancelling_a_command_stops_it_on_the_server() {
    let backend = std::sync::Arc::new(connect(&server!()).await);
    run(&backend, r#"{"drop": "slow_docs"}"#).await;
    run(
        &backend,
        r#"{"insert": "slow_docs", "documents": [{"_id": 1}]}"#,
    )
    .await;

    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let running = std::sync::Arc::clone(&backend);
    let query = tokio::spawn(async move {
        running
            .execute(
                r#"{"find": "slow_docs", "filter": {"$where": "sleep(10000) || true"}, "comment": "sqmeow-slow-probe"}"#,
                NO_CAP,
                stop,
            )
            .await
    });
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    cancel.cancel();
    assert!(matches!(query.await.unwrap(), Err(Error::Cancelled)));

    // Its comment was the user's own, which a cancel finds it by all the same.
    let mut running_on_server = true;
    for _ in 0..20 {
        let ops = run(
            &backend,
            r#"{"currentOp": true, "command.comment": "sqmeow-slow-probe", "$db": "admin"}"#,
        )
        .await;
        let inprog = ops
            .columns()
            .iter()
            .position(|column| column.name == "inprog")
            .and_then(|at| ops.cell(0, at).cloned());
        if matches!(inprog, Some(Cell::Json(ref text)) if text == "[]") {
            running_on_server = false;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(
        !running_on_server,
        "the find is still running on the server"
    );
}

#[tokio::test]
async fn a_collection_describes_its_validator_and_its_fields_follow_it() {
    let backend = connect(&server!()).await;
    run(&backend, r#"{"drop": "validated_docs"}"#).await;
    run(
        &backend,
        r#"{"create": "validated_docs", "validator": {"$jsonSchema": {"bsonType": "object",
            "required": ["email"],
            "properties": {"email": {"bsonType": "string"}, "age": {"bsonType": "int"}}}}}"#,
    )
    .await;
    run(
        &backend,
        r#"{"insert": "validated_docs", "documents": [{"_id": 1, "email": "a@b"}]}"#,
    )
    .await;

    let columns = backend.columns("sqmeow", "validated_docs").await.unwrap();
    let column = |name: &str| columns.iter().find(|c| c.name == name).unwrap();
    // `age` is in no document, but the validator names it.
    assert_eq!(column("age").type_name, "int");
    assert!(column("age").nullable);
    assert!(!column("email").nullable);

    let details = backend.details("sqmeow", "validated_docs").await.unwrap();
    assert_eq!(details.properties, vec![("documents".into(), "1".into())]);
    assert!(details.definition.unwrap().contains("$jsonSchema"));
}

/// The `n` a `count` answers.
async fn count_of(backend: &Backend, collection: &str) -> Option<Cell> {
    let result = run(backend, &format!(r#"{{"count": "{collection}"}}"#)).await;
    let at = result
        .columns()
        .iter()
        .position(|column| column.name == "n")?;
    result.cell(0, at).cloned()
}

const DUPLICATE_INSERTS: [&str; 2] = [
    r#"{"insert": "COLLECTION", "documents": [{"_id": 1}]}"#,
    r#"{"insert": "COLLECTION", "documents": [{"_id": 1}]}"#,
];

#[tokio::test]
async fn an_aggregate_that_only_filters_is_editable() {
    let backend = connect(&server!()).await;
    run(&backend, r#"{"drop": "aggregated_docs"}"#).await;
    run(
        &backend,
        r#"{"insert": "aggregated_docs", "documents": [{"_id": 1, "n": 1}, {"_id": 2, "n": 5}]}"#,
    )
    .await;

    let filtered = run(
        &backend,
        r#"{"aggregate": "aggregated_docs", "pipeline": [{"$match": {"n": {"$gt": 2}}}, {"$sort": {"n": 1}}], "cursor": {}}"#,
    )
    .await;
    assert!(filtered.source().is_some());
    let grouped = run(
        &backend,
        r#"{"aggregate": "aggregated_docs", "pipeline": [{"$group": {"_id": "$n"}}], "cursor": {}}"#,
    )
    .await;
    assert!(grouped.source().is_none());
}

#[tokio::test]
async fn a_standalone_server_applies_commands_in_turn() {
    let backend = connect(&server!()).await;
    run(&backend, r#"{"drop": "in_turn_docs"}"#).await;
    run(&backend, r#"{"create": "in_turn_docs"}"#).await;

    let commands: Vec<String> = DUPLICATE_INSERTS
        .iter()
        .map(|command| command.replace("COLLECTION", "in_turn_docs"))
        .collect();
    let error = backend
        .apply(&commands, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("1 of 2"), "{error}");
    assert_eq!(count_of(&backend, "in_turn_docs").await, Some(Cell::Int(1)));
}

#[tokio::test]
async fn a_replica_set_applies_every_command_or_none() {
    let Ok(url) = std::env::var("SQMEOW_TEST_MONGODB_RS_URL") else {
        eprintln!("skipped: set SQMEOW_TEST_MONGODB_RS_URL to a replica set");
        return;
    };
    let backend = connect(&url).await;
    run(&backend, r#"{"drop": "atomic_docs"}"#).await;
    run(&backend, r#"{"create": "atomic_docs"}"#).await;

    let commands: Vec<String> = DUPLICATE_INSERTS
        .iter()
        .map(|command| command.replace("COLLECTION", "atomic_docs"))
        .collect();
    let error = backend
        .apply(&commands, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("nothing was applied"), "{error}");
    assert_eq!(count_of(&backend, "atomic_docs").await, Some(Cell::Int(0)));
}
