//! The SurrealDB adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, RelationKind, ResultSet, Source, edit};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

/// The server URL, naming a namespace and no database, or a note explaining why the test did nothing.
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

fn names(result: &ResultSet) -> Vec<&str> {
    result.columns().iter().map(|c| c.name.as_str()).collect()
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
async fn reads_records_with_id_first_and_edits_them_by_it() {
    let backend = fresh(&server!(), "edits").await;
    run(
        &backend,
        "CREATE person:alice SET name = 'Alice', age = 3; CREATE person:bob SET name = 'Bob'",
    )
    .await;

    let result = run(&backend, "SELECT * FROM person ORDER BY name").await;
    assert_eq!(names(&result), ["id", "age", "name"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Text("person:alice".into())));
    assert_eq!(result.cell(1, 1), Some(&Cell::Null));
    assert!(matches!(
        result.source(),
        Some(Source::Collection { name, key, .. }) if name == "person" && key == "id"
    ));

    let changes = Changes {
        updates: vec![(0, vec![(1, edit::Value::Text("4".into()))])],
        deletes: vec![1],
        inserts: vec![vec![
            (0, edit::Value::Text("carol".into())),
            (2, edit::Value::Text("Carol".into())),
        ]],
    };
    let statements = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&statements, CancellationToken::new())
        .await
        .unwrap();

    let after = run(&backend, "SELECT id, age, name FROM person ORDER BY name").await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&Cell::Int(4)));
    assert_eq!(after.cell(1, 0), Some(&Cell::Text("person:carol".into())));

    // A record gone since it was read fails the whole apply.
    let gone = Changes {
        updates: vec![(0, vec![(1, edit::Value::Text("5".into()))])],
        deletes: vec![1],
        ..Changes::default()
    };
    run(&backend, "DELETE person:carol").await;
    let statements = backend.plan(&after, &gone).unwrap();
    let error = backend
        .apply(&statements, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("no record had that id"),
        "{error}"
    );
    let kept = run(&backend, "SELECT age FROM person:alice").await;
    assert_eq!(kept.cell(0, 0), Some(&Cell::Int(4)));
}

#[tokio::test]
async fn anything_but_a_tables_records_cannot_be_edited() {
    let backend = fresh(&server!(), "readonly").await;
    run(&backend, "CREATE person:1 SET name = 'x'").await;
    for statement in [
        "RETURN 1",
        "SELECT name FROM person",
        "SELECT count() FROM person GROUP ALL",
    ] {
        assert!(
            run(&backend, statement).await.source().is_none(),
            "{statement}"
        );
    }
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

#[tokio::test]
async fn describes_tables_views_functions_fields_and_indexes() {
    let backend = fresh(&server!(), "described").await;
    run(
        &backend,
        "DEFINE TABLE person SCHEMAFULL COMMENT 'people';
         DEFINE FIELD name ON person TYPE string;
         DEFINE FIELD age ON person TYPE option<int>;
         DEFINE INDEX by_name ON person FIELDS name UNIQUE;
         DEFINE EVENT audit ON person WHEN $event = 'CREATE' THEN (CREATE log SET at = time::now());
         DEFINE TABLE adults AS SELECT name FROM person WHERE age > 17;
         DEFINE FUNCTION fn::greet($n: string) { RETURN 'hi ' + $n; };
         CREATE loose SET a = 1, b = 'x'",
    )
    .await;
    let schema = backend.database().unwrap();

    let relations = backend.relations(&schema).await.unwrap();
    let kind = |name: &str| relations.iter().find(|r| r.name == name).map(|r| r.kind);
    assert_eq!(kind("person"), Some(RelationKind::Table));
    assert_eq!(kind("adults"), Some(RelationKind::View));

    let routines = backend.routines(&schema).await.unwrap();
    assert_eq!(routines[0].name, "fn::greet");

    let columns = backend.columns(&schema, "person").await.unwrap();
    let fields: Vec<(&str, bool)> = columns
        .iter()
        .map(|c| (c.name.as_str(), c.nullable))
        .collect();
    assert_eq!(fields, [("id", false), ("age", true), ("name", false)]);

    // A schemaless table's fields come from its records.
    let loose = backend.columns(&schema, "loose").await.unwrap();
    let loose: Vec<&str> = loose.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(loose, ["id", "a", "b"]);

    let indexes = backend.indexes(&schema, "person").await.unwrap();
    assert!(indexes[0].primary);
    assert_eq!(indexes[1].name, "by_name");
    assert_eq!(indexes[1].columns, ["name"]);
    assert!(indexes[1].unique);

    let details = backend.details(&schema, "person").await.unwrap();
    assert!(
        details
            .definition
            .as_deref()
            .is_some_and(|definition| definition.starts_with("DEFINE TABLE person")),
        "{details:?}"
    );
    assert_eq!(
        details.properties,
        [("comment".to_owned(), "people".to_owned())]
    );
    assert_eq!(details.triggers[0].0, "audit");
}

#[tokio::test]
async fn use_moves_the_database_queries_run_on() {
    let url = server!();
    fresh(&url, "moved_to").await;
    let backend = fresh(&url, "moved_from").await;
    run(&backend, "USE DB moved_to").await;
    assert_eq!(backend.database().as_deref(), Some("moved_to"));
}
