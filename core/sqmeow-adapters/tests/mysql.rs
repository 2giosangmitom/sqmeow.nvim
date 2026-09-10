//! The MySQL adapter against a real server.
//!
//! Needs a server. `just db-up` starts one and `just test-rust` passes its URL in. Without
//! `SQMEOW_TEST_MYSQL_URL` these tests report that they were skipped rather than failing.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Error, ResultSet};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_MYSQL_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_MYSQL_URL, or run `just db-up`");
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
    assert_eq!(backend.dialect().name(), "mysql");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("mysql://nobody@127.0.0.1:1/none")
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

    run(
        &backend,
        "create temporary table kinds (
            tiny tinyint, small smallint, medium mediumint, whole int, big bigint,
            single float, wide double, exact decimal(30, 3),
            tag varchar(10), words text, choice enum('a', 'b'),
            doc json,
            day date, clock time, stamp datetime, year_only year,
            blob_value blob
        )",
    )
    .await;

    run(
        &backend,
        "insert into kinds values (
            1, 2, 3, 4, 5,
            1.5, 2.5, 1234567890123456789.123,
            'tag', 'words', 'b',
            '{\"a\": 1}',
            '2026-01-02', '15:04:05', '2026-01-02 15:04:05', 2026,
            x'deadbeef'
        )",
    )
    .await;

    let result = run(&backend, "select * from kinds").await;

    let expected = [
        Cell::Int(1),
        Cell::Int(2),
        Cell::Int(3),
        Cell::Int(4),
        Cell::Int(5),
        Cell::Float(1.5),
        Cell::Float(2.5),
        Cell::Decimal("1234567890123456789.123".into()),
        Cell::Text("tag".into()),
        Cell::Text("words".into()),
        Cell::Text("b".into()),
        Cell::Json("{\"a\":1}".into()),
        Cell::Date("2026-01-02".into()),
        Cell::Time("15:04:05".into()),
        Cell::Timestamp("2026-01-02 15:04:05".into()),
        Cell::Int(2026),
        Cell::bytes(&[0xde, 0xad, 0xbe, 0xef]),
    ];

    for (index, want) in expected.iter().enumerate() {
        let column = &result.columns()[index].name;
        assert_eq!(result.cell(0, index), Some(want), "column `{column}`");
    }
}

#[tokio::test]
async fn an_unsigned_bigint_stays_exact() {
    let backend = connect(&server!()).await;
    run(&backend, "create temporary table big (v bigint unsigned)").await;
    // One past what an i64 holds. Wrapping it would show a negative number, which is worse than
    // showing it as an exact decimal.
    run(&backend, "insert into big values (18446744073709551615)").await;

    let result = run(&backend, "select v from big").await;
    assert_eq!(
        result.cell(0, 0),
        Some(&Cell::Decimal("18446744073709551615".into()))
    );
}

#[tokio::test]
async fn a_small_unsigned_value_stays_an_integer() {
    let backend = connect(&server!()).await;
    run(&backend, "create temporary table small (v bigint unsigned)").await;
    run(&backend, "insert into small values (42)").await;

    let result = run(&backend, "select v from small").await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(42)));
}

#[tokio::test]
async fn a_null_decodes_in_every_column() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select null as a, cast(null as char) as b, cast(null as date) as c",
    )
    .await;

    for column in 0..3 {
        assert_eq!(result.cell(0, column), Some(&Cell::Null), "column {column}");
    }
}

#[tokio::test]
async fn an_empty_result_still_knows_its_columns() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select 1 as id, 'x' as name from dual where false",
    )
    .await;

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
async fn cancelling_mid_query_stops_it() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        stopper.cancel();
    });

    let error = backend
        .execute("select sleep(30)", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");
}

#[tokio::test]
async fn quotes_identifiers_for_the_dialect() {
    let backend = connect(&server!()).await;
    assert_eq!(backend.quote_ident("plain"), "`plain`");
    assert_eq!(backend.quote_ident("od`d"), "`od``d`");
}
