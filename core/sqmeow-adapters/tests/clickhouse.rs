//! The ClickHouse adapter against a real server.

use std::time::Duration;

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, KeyKind, RelationKind, ResultSet, TypeClass};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_CLICKHOUSE_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_CLICKHOUSE_URL, or run `just db-up`");
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
async fn connects_and_reports_its_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.dialect().name(), "clickhouse");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("clickhouse://127.0.0.1:1")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn refuses_a_wrong_password() {
    let url = server!().replace("sqmeow:sqmeow@", "sqmeow:wrong@");
    assert!(Backend::connect(&url).await.is_err());
}

#[tokio::test]
async fn decodes_the_types_it_returns() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select toUInt8(7) as small, 18446744073709551615 as wide, 1.5 as float,
                toDecimal64(1.10, 2) as money, true as flag, toDate('2024-01-02') as day,
                toDateTime64('2024-01-02 03:04:05', 3) as at,
                toUUID('00000000-0000-0000-0000-000000000001') as id,
                'hi' as label, [1, 2] as list, cast(NULL, 'Nullable(String)') as nothing",
    )
    .await;

    let row: Vec<&Cell> = (0..11).map(|c| result.cell(0, c).unwrap()).collect();
    assert_eq!(row[0], &Cell::Int(7));
    assert_eq!(row[1], &Cell::Decimal("18446744073709551615".into()));
    assert_eq!(row[2], &Cell::Float(1.5));
    assert_eq!(row[3], &Cell::Decimal("1.1".into()));
    assert_eq!(row[4], &Cell::Bool(true));
    assert_eq!(row[5], &Cell::Date("2024-01-02".into()));
    assert_eq!(row[6], &Cell::Timestamp("2024-01-02 03:04:05.000".into()));
    assert_eq!(
        row[7],
        &Cell::Uuid("00000000-0000-0000-0000-000000000001".into())
    );
    assert_eq!(row[8], &Cell::Text("hi".into()));
    assert_eq!(row[9], &Cell::Text("[1,2]".into()));
    assert_eq!(row[10], &Cell::Null);

    let columns = result.columns();
    assert_eq!(columns[0].class, TypeClass::Number);
    assert_eq!(columns[10].type_name, "String");
}

#[tokio::test]
async fn stops_at_the_row_cap() {
    let backend = connect(&server!()).await;
    let result = backend
        .execute(
            "select number from numbers(100)",
            10,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn reports_a_server_error() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute("select nope from nowhere", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("nowhere"), "{error}");
}

#[tokio::test]
async fn a_cancel_stops_a_slow_query() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stop.cancel();
    });
    let error = tokio::time::timeout(
        Duration::from_secs(5),
        backend.execute("select sleepEachRow(1) from numbers(3)", NO_CAP, cancel),
    )
    .await
    .expect("the cancel should end the query")
    .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
}

#[tokio::test]
async fn a_read_only_connection_refuses_writes() {
    let url = server!();
    let backend = Backend::connect_to(&url, None, true).await.unwrap();
    run(&backend, "select 1").await;
    let error = backend
        .execute(
            "create table ro_refused (a Int8) engine = Memory",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("readonly"), "{error}");
}

#[tokio::test]
async fn results_are_read_only() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "select 1 as a").await;
    assert!(result.source().is_none());
    assert!(
        backend
            .apply(&["select 1".into()], CancellationToken::new())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn lists_what_the_drawer_shows() {
    let backend = connect(&server!()).await;
    run(&backend, "create database if not exists drawer").await;
    run(&backend, "drop table if exists drawer.events").await;
    run(&backend, "drop view if exists drawer.recent").await;
    run(
        &backend,
        "create table drawer.events (
            id UInt64, at DateTime, note Nullable(String) comment 'free text',
            index note_idx note type bloom_filter granularity 1
         ) engine = MergeTree order by (id, at) comment 'what happened'",
    )
    .await;
    run(
        &backend,
        "create view drawer.recent as select * from drawer.events",
    )
    .await;
    run(
        &backend,
        "create function if not exists sqmeow_double as (x) -> x * 2",
    )
    .await;

    let schemas = backend.schemas().await.unwrap();
    assert!(schemas.iter().any(|s| s.name == "drawer"));
    assert!(schemas.iter().any(|s| s.name == "default" && s.is_default));
    assert!(!schemas.iter().any(|s| s.name == "system"));

    let relations = backend.relations("drawer").await.unwrap();
    let kinds: Vec<(&str, RelationKind)> = relations
        .iter()
        .map(|r| (r.name.as_str(), r.kind))
        .collect();
    assert_eq!(
        kinds,
        vec![
            ("events", RelationKind::Table),
            ("recent", RelationKind::View)
        ]
    );

    let columns = backend.columns("drawer", "events").await.unwrap();
    assert_eq!(columns.len(), 3);
    assert_eq!(columns[0].key(), KeyKind::Primary);
    assert_eq!(columns[2].key(), KeyKind::None);
    assert!(columns[2].nullable);
    assert_eq!(columns[2].type_name, "String");

    let indexes = backend.indexes("drawer", "events").await.unwrap();
    assert_eq!(indexes[0].columns, vec!["id, at".to_owned()]);
    assert!(indexes[0].primary);
    assert_eq!(indexes[1].name, "note_idx");

    let details = backend.details("drawer", "events").await.unwrap();
    assert!(
        details
            .properties
            .contains(&("comment".into(), "what happened".into()))
    );
    assert_eq!(
        details.column_comments,
        vec![("note".into(), "free text".into())]
    );
    assert!(
        details
            .definition
            .unwrap()
            .starts_with("CREATE TABLE drawer.events")
    );

    let routines = backend.routines("drawer").await.unwrap();
    assert!(routines.iter().any(|r| r.name == "sqmeow_double"));

    let roles = backend.roles().await.unwrap();
    assert!(roles.iter().any(|r| r.name == "sqmeow"));
}
