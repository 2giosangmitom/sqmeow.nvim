//! The PostgreSQL adapter against a real server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_POSTGRES_URL` these tests report that they were skipped rather than failing, so
//! `cargo test` still works on a machine with no Docker.

use sqmeow_adapters::Backend;
use sqmeow_db::{
    Cell, Error, ForeignKey, KeyKind, RelationKind, ResultSet, RoutineKind, TypeClass,
};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// Introspection reads the catalogue, which a temporary table does not appear in. Each test
// therefore owns a differently named real table, so the cases stay independent while running in
// parallel.
const SCHEMA: &str = "public";

async fn fixture(backend: &Backend, table: &str) {
    run(backend, &format!("drop table if exists {table} cascade")).await;
    run(
        backend,
        &format!(
            "create table {table} (id int primary key, label varchar(10) not null, optional text)"
        ),
    )
    .await;
}

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_POSTGRES_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_POSTGRES_URL, or run `just db-up`");
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

#[tokio::test]
async fn a_url_naming_no_database_lists_the_cluster() {
    let url = server!();
    let (cluster, database) = url.rsplit_once('/').expect("the test url names a database");

    let backend = connect(cluster).await;
    let databases = backend
        .databases()
        .await
        .expect("a url naming no database reaches the cluster")
        .expect("the databases should load");
    assert!(databases.iter().any(|name| name == database));
    assert!(
        !databases.iter().any(|name| name.starts_with("template")),
        "a template cannot be opened, so it is not listed"
    );

    // One database of it, opened the way the drawer opens it, is a single database again.
    let one = Backend::connect_to(cluster, Some(database))
        .await
        .expect("the database should open");
    assert!(one.databases().await.is_none());
    assert!(connect(&url).await.databases().await.is_none());
}

#[tokio::test]
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect().name(), "postgres");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("postgres://nobody@127.0.0.1:1/none")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "select 1 as id, 'alice' as name").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
}

#[tokio::test]
async fn decodes_the_types_a_real_schema_holds() {
    let backend = connect(&server!()).await;

    // A temporary table is private to this connection, so the tests do not have to coordinate.
    run(
        &backend,
        "create temporary table kinds (
            flag bool, small int2, medium int4, big int8,
            single float4, double float8, exact numeric,
            words text, tag varchar(10), ident uuid,
            doc json, docb jsonb,
            stamp timestamp, stamptz timestamptz, day date, clock time,
            span interval, blob bytea,
            numbers int4[], labels text[]
        )",
    )
    .await;

    run(
        &backend,
        "insert into kinds values (
            true, 1, 2, 3,
            1.5, 2.5, 1234567890123456789.123,
            'words', 'tag', '0b7c1e6a-1f4d-4c2a-9a3e-5f6d7c8b9a01',
            '{\"a\":1}', '{\"b\":2}',
            '2026-01-02 15:04:05', '2026-01-02 15:04:05+00', '2026-01-02', '15:04:05',
            '1 mon 2 days 03:00:00', '\\xdeadbeef',
            '{1,2,NULL}', '{x,y}'
        )",
    )
    .await;

    let result = run(&backend, "select * from kinds").await;

    let expected = [
        Cell::Bool(true),
        Cell::Int(1),
        Cell::Int(2),
        Cell::Int(3),
        Cell::Float(1.5),
        Cell::Float(2.5),
        Cell::Decimal("1234567890123456789.123".into()),
        Cell::Text("words".into()),
        Cell::Text("tag".into()),
        Cell::Uuid("0b7c1e6a-1f4d-4c2a-9a3e-5f6d7c8b9a01".into()),
        Cell::Json("{\"a\":1}".into()),
        Cell::Json("{\"b\":2}".into()),
        Cell::Timestamp("2026-01-02 15:04:05".into()),
        Cell::Timestamp("2026-01-02 15:04:05 UTC".into()),
        Cell::Date("2026-01-02".into()),
        Cell::Time("15:04:05".into()),
        Cell::Text("1 mon 2 days 03:00:00".into()),
        Cell::bytes(&[0xde, 0xad, 0xbe, 0xef]),
        Cell::Array(vec![Cell::Int(1), Cell::Int(2), Cell::Null]),
        Cell::Array(vec![Cell::Text("x".into()), Cell::Text("y".into())]),
    ];

    for (index, want) in expected.iter().enumerate() {
        let column = &result.columns()[index].name;
        assert_eq!(result.cell(0, index), Some(want), "column `{column}`");
    }
}

#[tokio::test]
async fn a_null_decodes_in_every_column() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select null::int4, null::text, null::timestamptz, null::int4[]",
    )
    .await;

    for column in 0..4 {
        assert_eq!(result.cell(0, column), Some(&Cell::Null), "column {column}");
    }
}

#[tokio::test]
async fn a_type_nothing_understands_is_named_rather_than_failing() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "select 1 as ok, '10.0.0.1'::inet as address").await;

    // The row still arrives, and the column the adapter cannot decode keeps the server's own
    // text, so the user still sees the value rather than a placeholder.
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    match result.cell(0, 1) {
        Some(Cell::Unsupported { type_name, raw }) => {
            assert_eq!(type_name, "INET");
            assert_eq!(raw, "10.0.0.1");
        }
        other => panic!("expected an unsupported cell, got {other:?}"),
    }
}

#[tokio::test]
async fn an_empty_result_still_knows_its_columns() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "select 1 as id, 'x'::text as name where false").await;

    assert_eq!(result.row_count(), 0);
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
}

#[tokio::test]
async fn counts_rows_a_statement_changed() {
    let backend = connect(&server!()).await;
    run(&backend, "create temporary table counted (v int)").await;
    let result = run(&backend, "insert into counted values (1), (2), (3)").await;

    assert_eq!(result.affected(), Some(3));
}

#[tokio::test]
async fn statements_share_one_session() {
    let backend = connect(&server!()).await;
    run(&backend, "create temporary table scratch (v int)").await;
    run(&backend, "insert into scratch values (1)").await;

    assert_eq!(run(&backend, "select v from scratch").await.row_count(), 1);
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute("select nope", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();

    assert!(error.to_string().contains("nope"), "{error}");
    assert_eq!(run(&backend, "select 1").await.row_count(), 1);
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = connect(&server!()).await;
    let result = backend
        .execute(
            "select generate_series(1, 1000)",
            10,
            CancellationToken::new(),
        )
        .await
        .expect("the query should run");

    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn cancelling_mid_query_stops_it() {
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
}

#[tokio::test]
async fn quotes_identifiers_for_the_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.quote_ident("plain"), "\"plain\"");
    assert_eq!(backend.quote_ident("od\"d"), "\"od\"\"d\"");
}

#[tokio::test]
async fn lists_its_schemas() {
    let backend = connect(&server!()).await;
    let schemas = backend.schemas().await.expect("schemas should load");

    assert!(
        !schemas.is_empty(),
        "a server always has at least one schema"
    );
    assert!(
        schemas.iter().any(|schema| schema.is_default),
        "one schema is the one unqualified names resolve to"
    );
    // The catalogue is hidden; it is the same everywhere and nobody opened the drawer for it.
    assert!(
        !schemas
            .iter()
            .any(|schema| schema.name == "information_schema"),
        "the catalogue should be hidden"
    );
}

#[tokio::test]
async fn lists_tables_and_views() {
    let backend = connect(&server!()).await;
    fixture(&backend, "listed").await;
    run(
        &backend,
        "create or replace view listed_view as select id from listed",
    )
    .await;

    let relations = backend
        .relations(SCHEMA)
        .await
        .expect("relations should load");
    let named = |name: &str| {
        relations
            .iter()
            .find(|relation| relation.name == name)
            .cloned()
    };

    assert_eq!(named("listed").map(|r| r.kind), Some(RelationKind::Table));
    assert_eq!(
        named("listed_view").map(|r| r.kind),
        Some(RelationKind::View)
    );
}

#[tokio::test]
async fn lists_functions_and_procedures_apart() {
    let backend = connect(&server!()).await;
    run(&backend, "drop function if exists listed_fn(int)").await;
    run(&backend, "drop function if exists listed_fn(text)").await;
    run(&backend, "drop procedure if exists listed_proc()").await;
    run(
        &backend,
        "create function listed_fn(x int) returns int language sql as $$ select x $$",
    )
    .await;
    // A second signature under the same name, which the catalogue holds as its own row. The tree
    // shows one line for it either way.
    run(
        &backend,
        "create function listed_fn(x text) returns text language sql as $$ select x $$",
    )
    .await;
    run(
        &backend,
        "create procedure listed_proc() language sql as $$ select 1 $$",
    )
    .await;

    let routines = backend
        .routines(SCHEMA)
        .await
        .expect("routines should load");
    let kinds = |name: &str| {
        routines
            .iter()
            .filter(|routine| routine.name == name)
            .map(|routine| routine.kind)
            .collect::<Vec<_>>()
    };

    assert_eq!(kinds("listed_fn"), vec![RoutineKind::Function]);
    assert_eq!(kinds("listed_proc"), vec![RoutineKind::Procedure]);
}

#[tokio::test]
async fn lists_columns_in_their_declared_order() {
    let backend = connect(&server!()).await;
    fixture(&backend, "described").await;

    let columns = backend
        .columns(SCHEMA, "described")
        .await
        .expect("columns should load");

    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, vec!["id", "label", "optional"]);

    assert!(columns[0].primary_key, "id is the primary key");
    assert!(!columns[1].primary_key);
    assert!(!columns[1].nullable, "label is declared not null");
    assert!(columns[2].nullable, "optional is nullable");
    // The declared width survives, rather than collapsing to a base type name.
    assert!(
        columns[1].type_name.contains("10"),
        "{}",
        columns[1].type_name
    );
}

#[tokio::test]
async fn marks_the_result_columns_that_are_keys() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists keyed_child cascade").await;
    run(&backend, "drop table if exists keyed_parent cascade").await;
    run(
        &backend,
        "create table keyed_parent (id int primary key, name text)",
    )
    .await;
    run(
        &backend,
        "create table keyed_child (
            id int primary key,
            parent_id int references keyed_parent(id),
            note text
        )",
    )
    .await;

    let result = run(
        &backend,
        "select id, parent_id, note from keyed_child order by id",
    )
    .await;

    let keys: Vec<KeyKind> = result.columns().iter().map(|column| column.key).collect();
    assert_eq!(
        keys,
        vec![KeyKind::Primary, KeyKind::Foreign, KeyKind::None],
        "columns: {:?}",
        result.columns()
    );
}

#[tokio::test]
async fn a_result_column_that_is_an_expression_is_not_a_key() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists keyed_expr cascade").await;
    run(&backend, "create table keyed_expr (id int primary key)").await;

    // `count(*)` and a literal come from no table at all, and `id + 0` comes from one but is not
    // the column: Postgres reports no source for any of the three.
    let result = run(
        &backend,
        "select count(*) as total, 1 as literal, max(id) + 0 as bumped from keyed_expr",
    )
    .await;

    for column in result.columns() {
        assert_eq!(column.key, KeyKind::None, "{}", column.name);
    }
}

#[tokio::test]
async fn a_result_column_is_classified_by_its_type() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select 'x'::text as words, 1::int4 as count, now() as at,
                '{}'::jsonb as doc, gen_random_uuid() as ident, true as flag",
    )
    .await;

    let classes: Vec<TypeClass> = result.columns().iter().map(|column| column.class).collect();
    assert_eq!(
        classes,
        vec![
            TypeClass::Text,
            TypeClass::Number,
            TypeClass::Temporal,
            TypeClass::Json,
            TypeClass::Uuid,
            TypeClass::Boolean,
        ]
    );
}

#[tokio::test]
async fn a_drawer_column_names_what_it_references() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists fk_child cascade").await;
    run(&backend, "drop table if exists fk_parent cascade").await;
    run(&backend, "create table fk_parent (id int primary key)").await;
    run(
        &backend,
        "create table fk_child (id int primary key, parent_id int references fk_parent(id))",
    )
    .await;

    let columns = backend
        .columns(SCHEMA, "fk_child")
        .await
        .expect("columns should load");

    assert_eq!(columns[0].foreign_key, None);
    assert_eq!(
        columns[1].foreign_key,
        Some(ForeignKey {
            table: "fk_parent".into(),
            column: "id".into(),
        })
    );
}

#[tokio::test]
async fn a_relation_that_is_not_there_has_no_columns() {
    let backend = connect(&server!()).await;
    assert!(backend.columns(SCHEMA, "absent").await.unwrap().is_empty());
}
