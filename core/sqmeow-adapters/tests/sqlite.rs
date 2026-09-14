//! The SQLite adapter against a real database.
//!
//! Every test uses an in-memory database, so the suite needs no server, no fixture file, and no
//! cleanup, and still exercises the real driver rather than a stand-in.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, Error, ForeignKey, KeyKind, RelationKind, Source, TypeClass};
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
    let error = Backend::connect("cassandra://localhost/x")
        .await
        .unwrap_err();
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
async fn marks_the_result_columns_that_are_keys() {
    let backend = database().await;
    run(
        &backend,
        "create table keyed_parent (id integer primary key)",
    )
    .await;
    run(
        &backend,
        "create table keyed_child (
            id integer primary key,
            parent_id integer references keyed_parent(id),
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
    let backend = database().await;
    run(&backend, "create table keyed_expr (id integer primary key)").await;

    let result = run(
        &backend,
        "select count(*) as total, 1 as literal from keyed_expr",
    )
    .await;

    for column in result.columns() {
        assert_eq!(column.key, KeyKind::None, "{}", column.name);
    }
}

#[tokio::test]
async fn a_result_column_is_classified_by_its_declared_type() {
    let backend = database().await;
    run(
        &backend,
        "create table classed (words text, counted integer, at datetime, raw blob, loose)",
    )
    .await;

    let result = run(
        &backend,
        "select words, counted, at, raw, loose from classed",
    )
    .await;

    let classes: Vec<TypeClass> = result.columns().iter().map(|column| column.class).collect();
    assert_eq!(
        classes,
        vec![
            TypeClass::Text,
            TypeClass::Number,
            TypeClass::Temporal,
            TypeClass::Binary,
            // A column declared with no type at all, which is legal here and classifies as nothing.
            TypeClass::Unknown,
        ],
        "columns: {:?}",
        result.columns()
    );
}

#[tokio::test]
async fn a_drawer_column_names_what_it_references() {
    let backend = database().await;
    run(&backend, "create table fk_parent (id integer primary key)").await;
    run(
        &backend,
        "create table fk_child (id integer primary key, parent_id integer references fk_parent(id))",
    )
    .await;

    let columns = backend.columns("main", "fk_child").await.unwrap();
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
async fn a_reference_with_no_named_column_points_at_the_rowid() {
    let backend = database().await;
    run(&backend, "create table rf_parent (id integer primary key)").await;
    // SQLite lets a reference leave the column out, which means the other table's primary key.
    run(
        &backend,
        "create table rf_child (id integer primary key, parent_id integer references rf_parent)",
    )
    .await;

    let columns = backend.columns("main", "rf_child").await.unwrap();
    assert_eq!(
        columns[1].foreign_key,
        Some(ForeignKey {
            table: "rf_parent".into(),
            column: "rowid".into(),
        })
    );
}

#[tokio::test]
async fn a_relation_that_is_not_there_has_no_columns() {
    let backend = database().await;
    assert!(backend.columns("main", "absent").await.unwrap().is_empty());
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
        Some(Source::Table { name, key, .. }) => {
            assert_eq!(name, "people");
            assert_eq!(key, &vec![0]);
        }
        other => panic!("expected a table source, got {other:?}"),
    }
    // The alias is written back to the column it names, and the expression cannot be written.
    assert_eq!(result.columns()[1].origin.as_deref(), Some("name"));
    assert_eq!(result.columns()[2].origin, None);

    let changes = Changes {
        updates: vec![(0, vec![(1, Some("o'ally".into()))])],
        deletes: vec![1],
        inserts: vec![vec![(0, Some("9".into())), (1, Some("zed".into()))]],
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the changes should plan");
    backend.apply(&plan).await.expect("the plan should apply");

    let after = run(&backend, "select id, name from people order by id").await;
    assert_eq!(
        after.column_cells(0),
        &[Cell::Int(1), Cell::Int(3), Cell::Int(9)]
    );
    assert_eq!(after.cell(0, 1), Some(&Cell::Text("o'ally".into())));
    assert_eq!(after.cell(2, 1), Some(&Cell::Text("zed".into())));
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = seeded().await;
    let error = backend
        .apply(&[
            "update people set name = 'changed' where id = 1".into(),
            "insert into nowhere values (1)".into(),
        ])
        .await
        .unwrap_err();
    assert!(error.to_string().contains("nowhere"), "{error}");

    let after = run(&backend, "select name from people where id = 1").await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("alice".into())));
}

#[tokio::test]
async fn rows_that_cannot_be_found_again_have_no_source() {
    let backend = seeded().await;
    run(&backend, "create table loose (v text)").await;

    for sql in [
        "select * from loose",
        "select count(*) from people",
        "select name from people",
        "select p.id, q.id from people p join people q on p.id = q.id",
    ] {
        assert!(run(&backend, sql).await.source().is_none(), "{sql}");
    }
}

#[tokio::test]
async fn an_explain_query_plan_names_the_row_each_step_sits_under() {
    let backend = seeded().await;
    let plan = run(
        &backend,
        "explain query plan select * from people where name = 'x'",
    )
    .await;

    let names: Vec<&str> = plan.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "parent", "notused", "detail"]);
    match plan.cell(0, 3) {
        Some(Cell::Text(detail)) => assert!(detail.starts_with("SCAN"), "{detail}"),
        other => panic!("expected a step, got {other:?}"),
    }
}
