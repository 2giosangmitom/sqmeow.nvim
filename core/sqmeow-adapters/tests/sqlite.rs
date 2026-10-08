//! The SQLite adapter against a real database.

use sqmeow_adapters::Backend;
use sqmeow_db::edit::Changes;
use sqmeow_db::edit::Source;
use sqmeow_db::error::Error;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;
include!("common/sql_crud.rs");
include!("common/sql_safety.rs");
include!("common/native_bind.rs");

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    let backend = database().await;
    run(&backend, "create table \"parent.\"\"table\" (\"second.key\" integer, \"first key\" integer, primary key (\"first key\", \"second.key\"))").await;
    run(&backend, "create table \"child.\"\"table\" (a integer, b integer, c integer, d integer, foreign key (b, a) references \"parent.\"\"table\", foreign key (c, d) references \"parent.\"\"table\" (\"second.key\", \"first key\"))").await;
    let outgoing = backend
        .relationships("main", "child.\"table")
        .await
        .unwrap();
    let incoming = backend
        .relationships("main", "parent.\"table")
        .await
        .unwrap();
    assert_eq!(outgoing, incoming);
    assert_eq!(outgoing.len(), 2);
    assert_ne!(outgoing[0].name, outgoing[1].name);
    for key in &outgoing {
        assert_eq!(key.source_schema, "main");
        assert_eq!(key.source_relation, "child.\"table");
        assert_eq!(key.target_schema, "main");
        assert_eq!(key.target_relation, "parent.\"table");
    }
    let implicit = outgoing
        .iter()
        .find(|key| key.columns == ["b", "a"])
        .unwrap();
    assert_eq!(implicit.referenced, ["first key", "second.key"]);
    let explicit = outgoing
        .iter()
        .find(|key| key.columns == ["c", "d"])
        .unwrap();
    assert_eq!(explicit.referenced, ["second.key", "first key"]);
    assert!(
        backend
            .relationships("main", "unrelated")
            .await
            .unwrap()
            .is_empty()
    );
    backend.close().await;
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    failed_apply_rolls_back(
        &database().await,
        "create table sqmeow_rollback_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

#[tokio::test]
async fn bound_text_repeats_and_typed_null_stays_null() {
    let text = "it's \\ data; ' OR true -- ?1";
    bound_values_remain_data(
        &database().await,
        "select ?1, ?1, ?2",
        &[Value::Text(text.into()), Value::Null(Kind::Int)],
        text,
    )
    .await;
}

#[tokio::test]
async fn a_read_only_connection_is_refused_writes_by_sqlite() {
    let backend = Backend::connect_to("sqlite::memory:", None, true)
        .await
        .unwrap();
    run(&backend, "select 1").await;
    let error = backend
        .execute(
            "create table t (id integer)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("readonly"), "{error}");
    backend.close().await;
}

#[tokio::test]
async fn grouped_or_combined_rows_are_read_only() {
    let backend = seeded().await;
    for sql in [
        "select id, name from people union all select id, name from people",
        "select name, count(*) from people group by name",
        "select a.*, b.* from people a join people b on b.id = a.id",
    ] {
        assert!(run(&backend, sql).await.source().is_none(), "{sql}");
    }
    backend.close().await;
}

#[tokio::test]
async fn commands_create_read_update_and_delete_rows() {
    crud_round_trip(
        &database().await,
        "create table sqmeow_crud_smoke (id int primary key, name varchar(32))",
    )
    .await;
}

async fn database() -> Backend {
    Backend::connect("sqlite::memory:")
        .await
        .expect("an in-memory database should open")
}

async fn run(backend: &Backend, sql: &str) -> sqmeow_db::result::ResultSet {
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
async fn opens_an_in_memory_database_with_each_sqlite_scheme() {
    for url in [
        "sqlite::memory:",
        "sqlite3::memory:",
        "SQLite::memory:",
        "FILE::memory:",
    ] {
        let backend = Backend::connect(url)
            .await
            .unwrap_or_else(|error| panic!("{url}: {error}"));
        assert_eq!(
            run(&backend, "select 42").await.cell(0, 0).as_deref(),
            Some(&Cell::Int(42))
        );
        backend.close().await;
    }
}

#[tokio::test]
async fn refuses_an_unknown_scheme() {
    let error = Backend::connect("unknown://localhost/x").await.unwrap_err();
    assert!(matches!(error, Error::UnsupportedUrl(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = seeded().await;
    let result = run(&backend, "select id, name from people order by id").await;

    assert_eq!(result.row_count(), 3);
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
    assert_eq!(result.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
    assert_eq!(
        result.cell(0, 1).as_deref(),
        Some(&Cell::Text("alice".into()))
    );
}

#[tokio::test]
async fn survives_an_error_and_keeps_working() {
    let backend = seeded().await;
    for (sql, message) in [
        ("select from where", "syntax"),
        ("select nope from people", "nope"),
    ] {
        let error = backend
            .execute(sql, NO_CAP, CancellationToken::new())
            .await
            .unwrap_err();
        assert!(matches!(error, Error::Driver(_)), "{error}");
        assert!(error.to_string().contains(message), "{error}");
        assert_eq!(
            run(&backend, "select count(*) from people")
                .await
                .row_count(),
            1
        );
    }
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
async fn a_select_from_one_table_is_edited_through_its_primary_key() {
    let backend = seeded().await;
    let result = run(
        &backend,
        "select id, name as who, upper(name) as shout from people order by id",
    )
    .await;

    match result.source() {
        Some(Source::Tables(tables)) => {
            assert_eq!(tables[0].name, "people");
            assert_eq!(tables[0].key, vec![0]);
            // The alias is written back to the column it names, and the expression cannot be written.
            assert_eq!(tables[0].column(1), Some("name"));
            assert_eq!(tables[0].column(2), None);
        }
        other => panic!("expected a table source, got {other:?}"),
    }

    let changes = Changes {
        updates: vec![(0, vec![(1, "o'ally".into())])],
        deletes: vec![1],
        inserts: vec![vec![(0, "9".into()), (1, "zed".into())]],
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the changes should plan");
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    let after = run(&backend, "select id, name from people order by id").await;
    assert_eq!(
        after
            .column_cells(0)
            .map(std::borrow::Cow::into_owned)
            .collect::<Vec<_>>(),
        vec![Cell::Int(1), Cell::Int(3), Cell::Int(9)]
    );
    assert_eq!(
        after.cell(0, 1).as_deref(),
        Some(&Cell::Text("o'ally".into()))
    );
    assert_eq!(after.cell(2, 1).as_deref(), Some(&Cell::Text("zed".into())));
}
