//! The DuckDB adapter against a real in-memory database.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, ForeignKey, RelationKind, TypeClass};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

async fn database() -> Backend {
    Backend::connect("duckdb::memory:")
        .await
        .expect("an in-memory database should open")
}

async fn run(backend: &Backend, sql: &str) -> sqmeow_db::ResultSet {
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
async fn decodes_each_type() {
    let backend = database().await;
    let result = run(
        &backend,
        "select 1::integer, 'a'::varchar, 2.5::double, 12.34::decimal(10, 2), true,
                null::integer, '\\xde\\xad'::blob, date '2024-01-02',
                timestamp '2024-01-02 03:04:05', time '03:04:05',
                '00000000-0000-0000-0000-000000000001'::uuid,
                [1, 2], {'a': 1}, 18446744073709551615::ubigint",
    )
    .await;

    let cells: Vec<&Cell> = (0..14).map(|i| result.cell(0, i).unwrap()).collect();
    assert_eq!(
        cells,
        vec![
            &Cell::Int(1),
            &Cell::Text("a".into()),
            &Cell::Float(2.5),
            &Cell::Decimal("12.34".into()),
            &Cell::Bool(true),
            &Cell::Null,
            &Cell::bytes(&[0xde, 0xad]),
            &Cell::Date("2024-01-02".into()),
            &Cell::Timestamp("2024-01-02 03:04:05".into()),
            &Cell::Time("03:04:05".into()),
            &Cell::Uuid("00000000-0000-0000-0000-000000000001".into()),
            &Cell::Json("[1,2]".into()),
            &Cell::Json("{\"a\":1}".into()),
            &Cell::Decimal("18446744073709551615".into()),
        ]
    );
    assert_eq!(result.columns()[0].class, TypeClass::Number);
    assert_eq!(result.columns()[1].class, TypeClass::Text);
    assert_eq!(result.columns()[8].class, TypeClass::Temporal);
}

#[tokio::test]
async fn an_empty_result_still_knows_its_columns() {
    let backend = database().await;
    let result = run(&backend, "select 1 as id, 'x' as name where false").await;
    assert_eq!(result.row_count(), 0);
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
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

#[tokio::test]
async fn cancelling_interrupts_a_long_query() {
    let backend = database().await;
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stop.cancel();
    });

    let error = backend
        .execute("select count(*) from range(1000000000000)", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
    // The interrupted query lets go of the connection.
    assert_eq!(run(&backend, "select 1").await.row_count(), 1);
}

#[tokio::test]
async fn describes_the_schema_for_the_drawer() {
    let backend = database().await;
    run(
        &backend,
        "create table teams (id integer primary key, name varchar not null)",
    )
    .await;
    run(
        &backend,
        "create table people (id integer primary key, team integer references teams (id), nick varchar)",
    )
    .await;
    run(&backend, "create view names as select name from teams").await;
    run(&backend, "create macro twice(x) as x * 2").await;

    let schemas = backend.schemas().await.unwrap();
    let main = schemas
        .iter()
        .find(|s| s.name == "main")
        .expect("a main schema");
    assert!(main.is_default);

    let relations = backend.relations("main").await.unwrap();
    let kinds: Vec<(&str, RelationKind)> = relations
        .iter()
        .map(|r| (r.name.as_str(), r.kind))
        .collect();
    assert_eq!(
        kinds,
        vec![
            ("names", RelationKind::View),
            ("people", RelationKind::Table),
            ("teams", RelationKind::Table),
        ]
    );

    let routines = backend.routines("main").await.unwrap();
    assert_eq!(
        routines.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
        vec!["twice"]
    );

    let columns = backend.columns("main", "people").await.unwrap();
    assert_eq!(columns.len(), 3);
    assert!(columns[0].primary_key && !columns[0].nullable);
    assert_eq!(
        columns[1].foreign_key,
        Some(ForeignKey {
            table: "teams".into(),
            column: "id".into()
        })
    );
    assert!(!columns[2].primary_key && columns[2].nullable);
    assert_eq!(columns[2].type_name, "VARCHAR");

    assert_eq!(backend.columns("main", "names").await.unwrap().len(), 1);
}
