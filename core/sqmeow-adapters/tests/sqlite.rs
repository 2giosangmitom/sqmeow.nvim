//! The SQLite adapter against a real database.
//!
//! Every test uses an in-memory database, so the suite needs no server, no fixture file, and no
//! cleanup, and still exercises the real driver rather than a stand-in.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, RelationKind};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

async fn database() -> Backend {
    Backend::connect("sqlite::memory:")
        .await
        .expect("an in-memory database should open")
}

async fn run(backend: &Backend, sql: &str) -> sqmeow_db::ResultSet {
    backend
        .execute(sql, NO_CAP, CancellationToken::new())
        .await
        .unwrap_or_else(|error| panic!("{sql} should run: {error}"))
}

async fn seeded() -> Backend {
    let backend = database().await;
    run(
        &backend,
        "create table people (id integer primary key, name text, score real, avatar blob)",
    )
    .await;
    run(
        &backend,
        "insert into people (id, name, score, avatar) values
            (1, 'alice', 9.5, x'deadbeef'),
            (2, 'bob', 7.0, null),
            (3, null, null, null)",
    )
    .await;
    backend
}

#[tokio::test]
async fn opens_an_in_memory_database() {
    let backend = database().await;
    assert_eq!(backend.dialect().name(), "sqlite");
}

#[tokio::test]
async fn refuses_an_unknown_scheme() {
    let error = Backend::connect("mongodb://localhost/x").await.unwrap_err();
    assert!(matches!(error, Error::UnsupportedUrl(_)), "{error}");
}

#[tokio::test]
async fn reports_a_database_that_is_not_there() {
    // Without `mode=rwc` a missing file is an error rather than a new empty database.
    let error = Backend::connect("sqlite:///nonexistent/dir/app.db")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = seeded().await;
    let result = run(&backend, "select id, name from people order by id").await;

    assert_eq!(result.row_count(), 3);
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
}

#[tokio::test]
async fn decodes_each_storage_class() {
    let backend = seeded().await;
    let result = run(
        &backend,
        "select id, name, score, avatar from people where id = 1",
    )
    .await;

    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
    assert_eq!(result.cell(0, 2), Some(&Cell::Float(9.5)));
    assert_eq!(
        result.cell(0, 3),
        Some(&Cell::bytes(&[0xde, 0xad, 0xbe, 0xef]))
    );
}

#[tokio::test]
async fn decodes_null_in_every_column_type() {
    let backend = seeded().await;
    let result = run(
        &backend,
        "select name, score, avatar from people where id = 3",
    )
    .await;

    for column in 0..3 {
        assert_eq!(result.cell(0, column), Some(&Cell::Null), "column {column}");
    }
}

#[tokio::test]
async fn honours_sqlite_dynamic_typing() {
    // SQLite stores what it is given, so an integer column can hold text. The value decides the
    // cell type, not the declared column type.
    let backend = database().await;
    run(&backend, "create table loose (v integer)").await;
    run(
        &backend,
        "insert into loose (v) values ('not a number'), (42)",
    )
    .await;

    let result = run(&backend, "select v from loose order by rowid").await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Text("not a number".into())));
    assert_eq!(result.cell(1, 0), Some(&Cell::Int(42)));
}

#[tokio::test]
async fn an_empty_result_still_knows_its_columns() {
    let backend = seeded().await;
    let result = run(&backend, "select id, name from people where 0").await;

    assert_eq!(result.row_count(), 0);
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
}

#[tokio::test]
async fn counts_rows_a_statement_changed() {
    let backend = seeded().await;
    let result = run(&backend, "update people set score = 0 where id in (1, 2)").await;

    assert_eq!(result.affected(), Some(2));
    assert_eq!(result.row_count(), 0);
}

#[tokio::test]
async fn reports_a_syntax_error() {
    let backend = database().await;
    let error = backend
        .execute("select from where", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();

    assert!(matches!(error, Error::Driver(_)), "{error}");
    // The driver's own wording survives, because it is the part that says what is wrong.
    assert!(error.to_string().contains("syntax"), "{error}");
}

#[tokio::test]
async fn survives_an_error_and_keeps_working() {
    let backend = seeded().await;
    let _ = backend
        .execute("select nope from people", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();

    assert_eq!(
        run(&backend, "select count(*) from people")
            .await
            .row_count(),
        1
    );
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = database().await;
    let result = backend
        .execute(
            "with recursive n(x) as (select 1 union all select x + 1 from n where x < 1000)
             select x from n",
            10,
            CancellationToken::new(),
        )
        .await
        .expect("the query should run");

    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn an_uncapped_result_is_not_marked_truncated() {
    let backend = seeded().await;
    let result = run(&backend, "select id from people").await;
    assert!(!result.is_truncated());
}

#[tokio::test]
async fn a_cancelled_token_stops_the_query() {
    let backend = seeded().await;
    let cancel = CancellationToken::new();
    cancel.cancel();

    let error = backend
        .execute("select id from people", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
}

#[tokio::test]
async fn cancelling_mid_query_stops_it() {
    let backend = database().await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        stopper.cancel();
    });

    let error = backend
        .execute(
            "with recursive n(x) as (select 1 union all select x + 1 from n where x < 20000000)
             select x from n",
            NO_CAP,
            cancel,
        )
        .await
        .unwrap_err();

    assert!(matches!(error, Error::Cancelled), "{error}");
}

#[tokio::test]
async fn statements_share_one_session() {
    // A single pooled connection is what makes a transaction, a temporary table, or a pragma
    // outlive the statement that created it.
    let backend = database().await;
    run(&backend, "create temporary table scratch (v int)").await;
    run(&backend, "insert into scratch values (1)").await;

    assert_eq!(run(&backend, "select v from scratch").await.row_count(), 1);
}

#[tokio::test]
async fn records_how_long_a_statement_took() {
    let backend = seeded().await;
    let result = run(&backend, "select count(*) from people").await;
    assert!(result.elapsed() > std::time::Duration::ZERO);
}

#[tokio::test]
async fn quotes_identifiers_for_the_dialect() {
    let backend = database().await;
    assert_eq!(backend.quote_ident("plain"), "\"plain\"");
    assert_eq!(backend.quote_ident("od\"d"), "\"od\"\"d\"");
}

#[tokio::test]
async fn lists_its_schemas() {
    let backend = database().await;
    let schemas = backend.schemas().await.expect("schemas should load");

    let main = schemas
        .iter()
        .find(|schema| schema.name == "main")
        .expect("every SQLite database has a main schema");
    assert!(main.is_default);
}

#[tokio::test]
async fn lists_tables_and_views_but_not_its_own_bookkeeping() {
    let backend = seeded().await;
    run(
        &backend,
        "create view adults as select * from people where score > 8",
    )
    .await;

    let relations = backend
        .relations("main")
        .await
        .expect("relations should load");
    let named = |name: &str| {
        relations
            .iter()
            .find(|relation| relation.name == name)
            .cloned()
    };

    assert_eq!(named("people").map(|r| r.kind), Some(RelationKind::Table));
    assert_eq!(named("adults").map(|r| r.kind), Some(RelationKind::View));
    // sqlite_sequence and friends are the database's own bookkeeping, not the user's schema.
    assert!(
        relations
            .iter()
            .all(|relation| !relation.name.starts_with("sqlite_")),
        "internal tables should be hidden"
    );
}

#[tokio::test]
async fn has_no_routines_to_list() {
    let backend = database().await;
    // SQLite has no stored functions or procedures, and saying so with an empty list is what lets
    // the drawer draw the groups as empty rather than as broken.
    assert_eq!(backend.routines("main").await.expect("no error"), vec![]);
}

#[tokio::test]
async fn lists_columns_in_their_declared_order() {
    let backend = seeded().await;
    let columns = backend
        .columns("main", "people")
        .await
        .expect("columns should load");

    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name", "score", "avatar"]);

    assert!(columns[0].primary_key);
    assert!(!columns[1].primary_key);
    assert_eq!(columns[1].type_name, "TEXT");
    assert!(columns[1].nullable);
}

#[tokio::test]
async fn a_column_with_no_declared_type_says_so() {
    // SQLite allows a column with no type at all, and its values can be anything.
    let backend = database().await;
    run(&backend, "create table loose (v)").await;

    let columns = backend.columns("main", "loose").await.unwrap();
    assert_eq!(columns[0].type_name, "any");
}

#[tokio::test]
async fn a_relation_that_is_not_there_has_no_columns() {
    let backend = database().await;
    assert!(backend.columns("main", "absent").await.unwrap().is_empty());
}
