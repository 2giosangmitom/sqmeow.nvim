// Cases every CQL server must pass.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, Error, KeyKind, RelationKind, ResultSet, Source, Table};
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
    run(backend, &format!("CREATE TABLE sqmeow.{name} ({definition})")).await;
}

fn names(result: &ResultSet) -> Vec<&str> {
    result.columns().iter().map(|c| c.name.as_str()).collect()
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
async fn reads_back_typed_values() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "typed",
        "id int PRIMARY KEY, name text, tags list<text>, seen timestamp, ratio decimal, uid uuid",
    )
    .await;
    run(
        &backend,
        "INSERT INTO sqmeow.typed (id, name, tags, seen, ratio, uid) VALUES
         (1, 'alice', ['a', 'b'], '2024-01-02 03:04:05.678+0000', 1.50,
          5b6962dd-3f90-4c93-8f61-eabfa4a803e2)",
    )
    .await;

    let result = run(&backend, "SELECT id, name, tags, seen, ratio, uid, ttl(name) FROM sqmeow.typed").await;
    assert_eq!(
        names(&result),
        vec!["id", "name", "tags", "seen", "ratio", "uid", "ttl(name)"]
    );
    assert_eq!(result.columns()[2].type_name, "list<text>");
    let row: Vec<&Cell> = (0..7).map(|c| result.cell(0, c).unwrap()).collect();
    assert_eq!(
        row,
        vec![
            &Cell::Int(1),
            &Cell::Text("alice".into()),
            &Cell::Json(r#"["a","b"]"#.into()),
            &Cell::Timestamp("2024-01-02 03:04:05.678+0000".into()),
            &Cell::Decimal("1.50".into()),
            &Cell::Uuid("5b6962dd-3f90-4c93-8f61-eabfa4a803e2".into()),
            &Cell::Null,
        ]
    );
}

#[tokio::test]
async fn a_write_returns_no_rows() {
    let backend = connect(&server!()).await;
    table(&backend, "writes", "id int PRIMARY KEY").await;
    let result = run(&backend, "INSERT INTO sqmeow.writes (id) VALUES (1)").await;
    assert!(result.columns().is_empty());
    assert_eq!(result.row_count(), 0);
}

#[tokio::test]
async fn stops_at_the_row_cap() {
    let backend = connect(&server!()).await;
    table(&backend, "capped", "id int PRIMARY KEY").await;
    for id in 0..3 {
        run(&backend, &format!("INSERT INTO sqmeow.capped (id) VALUES ({id})")).await;
    }
    let result = backend
        .execute("SELECT * FROM sqmeow.capped", 2, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.row_count(), 2);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn an_error_keeps_the_connection() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute("SELECT * FROM sqmeow.no_such_table", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
    run(&backend, "SELECT release_version FROM system.local").await;
}

#[tokio::test]
async fn use_sets_the_default_keyspace() {
    let backend = connect(&server!()).await;
    table(&backend, "unqualified", "id int PRIMARY KEY").await;
    run(&backend, "USE sqmeow").await;
    run(&backend, "SELECT * FROM unqualified").await;

    let schemas = backend.schemas().await.unwrap();
    let sqmeow = schemas.iter().find(|s| s.name == "sqmeow").unwrap();
    assert!(sqmeow.is_default);
    assert!(!schemas.iter().any(|s| s.name.starts_with("system")));
}

#[tokio::test]
async fn describes_tables_and_their_keys() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "described",
        "v text, ck int, pk int, s int STATIC, PRIMARY KEY (pk, ck)",
    )
    .await;

    let relations = backend.relations("sqmeow").await.unwrap();
    let described = relations.iter().find(|r| r.name == "described").unwrap();
    assert_eq!(described.kind, RelationKind::Table);

    let columns = backend.columns("sqmeow", "described").await.unwrap();
    let summary: Vec<(&str, bool)> = columns
        .iter()
        .map(|c| (c.name.as_str(), c.primary_key))
        .collect();
    assert_eq!(
        summary,
        vec![("pk", true), ("ck", true), ("s", false), ("v", false)]
    );
    assert_eq!(columns[3].type_name, "text");
}

#[tokio::test]
async fn edits_a_row_by_its_whole_primary_key() {
    let backend = connect(&server!()).await;
    table(
        &backend,
        "edited",
        "pk int, ck int, n int, label text, PRIMARY KEY (pk, ck)",
    )
    .await;
    run(&backend, "INSERT INTO sqmeow.edited (pk, ck, n, label) VALUES (1, 1, 0, 'a')").await;
    run(&backend, "INSERT INTO sqmeow.edited (pk, ck, n, label) VALUES (1, 2, 0, 'b')").await;

    let result = run(&backend, "SELECT pk, ck, n, label FROM sqmeow.edited").await;
    assert_eq!(
        result.source(),
        Some(&Source::Tables(vec![Table {
            schema: Some("sqmeow".into()),
            name: "edited".into(),
            key: vec![0, 1],
            columns: vec![
                (0, "pk".into()),
                (1, "ck".into()),
                (2, "n".into()),
                (3, "label".into()),
            ],
        }]))
    );
    assert_eq!(result.columns()[1].key, KeyKind::Primary);

    let update = Changes {
        updates: vec![(0, vec![(2, "42".into()), (3, "it's".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &update).unwrap();
    assert_eq!(
        plan,
        vec![
            r#"UPDATE "sqmeow"."edited" SET "n" = 42, "label" = 'it''s' WHERE "pk" = 1 AND "ck" = 1 IF EXISTS"#
        ]
    );
    backend.apply(&plan).await.unwrap();

    // Adding a row with a stored key would replace it, so it is refused.
    let taken = Changes {
        inserts: vec![vec![(0, "1".into()), (1, "1".into()), (3, "new".into())]],
        ..Changes::default()
    };
    let error = backend
        .apply(&backend.plan(&result, &taken).unwrap())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("already exists"), "{error}");

    let delete = Changes {
        deletes: vec![1],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &delete).unwrap();
    backend.apply(&plan).await.unwrap();
    // The row is gone, so deleting it again changes nothing and says so.
    assert!(backend.apply(&plan).await.is_err());

    let after = run(&backend, "SELECT n, label FROM sqmeow.edited").await;
    assert_eq!(after.row_count(), 1);
    assert_eq!(after.cell(0, 0), Some(&Cell::Int(42)));
    assert_eq!(after.cell(0, 1), Some(&Cell::Text("it's".into())));
}

#[tokio::test]
async fn a_result_without_the_whole_key_is_not_editable() {
    let backend = connect(&server!()).await;
    table(&backend, "partial", "pk int, ck int, v text, PRIMARY KEY (pk, ck)").await;
    let result = run(&backend, "SELECT pk, v FROM sqmeow.partial").await;
    assert_eq!(result.source(), None);
}

#[tokio::test]
async fn lists_a_tables_secondary_indexes() {
    let backend = connect(&server!()).await;
    table(&backend, "indexed", "pk int PRIMARY KEY, v text, w int").await;
    run(&backend, "CREATE INDEX indexed_v ON sqmeow.indexed (v)").await;

    assert_eq!(
        backend.indexes("sqmeow", "indexed").await.unwrap(),
        vec![
            sqmeow_db::IndexNode {
                name: "PRIMARY KEY".into(),
                columns: vec!["pk".into()],
                unique: true,
                primary: true,
            },
            sqmeow_db::IndexNode {
                name: "indexed_v".into(),
                columns: vec!["v".into()],
                unique: false,
                primary: false,
            },
        ]
    );
    let definition = backend
        .details("sqmeow", "indexed")
        .await
        .unwrap()
        .definition
        .unwrap_or_default();
    assert!(definition.contains("CREATE TABLE sqmeow.indexed"), "{definition}");
}
