//! The PostgreSQL adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::{
    Cell, Changes, Error, ForeignKey, KeyKind, RelationKind, ResultSet, RoutineKind, Source,
    TypeClass,
};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// Introspection reads the catalogue.
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

    // The row still arrives, and the column the adapter cannot decode keeps the server's own text.
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
    // A second signature under the same name.
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

    // `count(*)`, a literal and `id + 0` are not table columns.
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

#[tokio::test]
async fn an_explain_is_a_column_of_plan_lines() {
    let backend = connect(&server!()).await;
    fixture(&backend, "explained").await;

    // One row a line, which is what lets the result window show the plan as text.
    let plan = run(
        &backend,
        "explain select * from explained where label = 'a'",
    )
    .await;
    let names: Vec<&str> = plan.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["QUERY PLAN"]);
    assert!(plan.row_count() >= 2, "a scan and its filter");
    match plan.cell(0, 0) {
        Some(Cell::Text(line)) => assert!(line.contains("Scan"), "{line}"),
        other => panic!("expected the first plan line, got {other:?}"),
    }
    // A plan is nobody's table, so it cannot be edited.
    assert!(plan.source().is_none());

    // Asked for as JSON, the whole plan is one value.
    let json = run(&backend, "explain (format json) select * from explained").await;
    assert_eq!(json.columns().len(), 1);
    assert_eq!(json.row_count(), 1);
}

fn text(value: &str) -> Cell {
    Cell::Text(value.into())
}

#[tokio::test]
async fn a_write_returning_rows_shows_them_and_counts_them() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_returning").await;

    let inserted = run(
        &backend,
        "insert into pg_returning (id, label) values (1, 'a'), (2, 'b') returning id, label",
    )
    .await;
    assert_eq!(inserted.row_count(), 2);
    assert_eq!(inserted.affected(), Some(2));
    assert_eq!(inserted.cell(1, 1), Some(&text("b")));

    let updated = run(
        &backend,
        "update pg_returning set label = upper(label) returning label",
    )
    .await;
    assert_eq!(updated.affected(), Some(2));
    assert_eq!(updated.cell(0, 0), Some(&text("A")));

    let deleted = run(&backend, "delete from pg_returning where id = 1").await;
    assert_eq!(deleted.affected(), Some(1));
    assert_eq!(deleted.row_count(), 0);
}

#[tokio::test]
async fn a_transaction_spans_statements_run_one_at_a_time() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_tx").await;

    run(&backend, "begin").await;
    run(&backend, "insert into pg_tx (id, label) values (1, 'a')").await;
    assert_eq!(run(&backend, "select id from pg_tx").await.row_count(), 1);
    run(&backend, "rollback").await;
    assert_eq!(run(&backend, "select id from pg_tx").await.row_count(), 0);

    run(&backend, "begin").await;
    run(&backend, "insert into pg_tx (id, label) values (2, 'b')").await;
    run(&backend, "savepoint half").await;
    run(&backend, "insert into pg_tx (id, label) values (3, 'c')").await;
    run(&backend, "rollback to savepoint half").await;
    run(&backend, "commit").await;
    assert_eq!(run(&backend, "select id from pg_tx").await.row_count(), 1);
}

#[tokio::test]
async fn an_upsert_counts_the_row_it_touched() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_upsert").await;
    run(
        &backend,
        "insert into pg_upsert (id, label) values (1, 'a')",
    )
    .await;

    let updated = run(
        &backend,
        "insert into pg_upsert (id, label) values (1, 'b')
         on conflict (id) do update set label = excluded.label",
    )
    .await;
    assert_eq!(updated.affected(), Some(1));

    let skipped = run(
        &backend,
        "insert into pg_upsert (id, label) values (1, 'c') on conflict do nothing",
    )
    .await;
    assert_eq!(skipped.affected(), Some(0));

    let merged = run(
        &backend,
        "merge into pg_upsert t using (values (1, 'm'), (2, 'n')) as s(id, label) on t.id = s.id
         when matched then update set label = s.label
         when not matched then insert (id, label) values (s.id, s.label)",
    )
    .await;
    assert_eq!(merged.affected(), Some(2));
    let labels = run(&backend, "select label from pg_upsert order by id").await;
    assert_eq!(labels.cell(0, 0), Some(&text("m")));
    assert_eq!(labels.cell(1, 0), Some(&text("n")));
}

#[tokio::test]
async fn schema_changes_are_seen_by_the_drawer() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_ddl").await;
    run(
        &backend,
        "alter table pg_ddl add column extra int default 7",
    )
    .await;
    run(
        &backend,
        "alter table pg_ddl rename column optional to note",
    )
    .await;
    run(&backend, "create index pg_ddl_label on pg_ddl (label)").await;
    run(
        &backend,
        "comment on table pg_ddl is 'a note; with a semicolon'",
    )
    .await;
    run(&backend, "insert into pg_ddl (id, label) values (1, 'a')").await;
    assert_eq!(
        run(&backend, "select extra from pg_ddl").await.cell(0, 0),
        Some(&Cell::Int(7))
    );
    run(&backend, "truncate pg_ddl").await;
    run(&backend, "drop index pg_ddl_label").await;

    let columns = backend.columns(SCHEMA, "pg_ddl").await.unwrap();
    let names: Vec<&str> = columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "label", "note", "extra"]);
    assert_eq!(run(&backend, "select * from pg_ddl").await.row_count(), 0);
}

#[tokio::test]
async fn a_do_block_and_a_procedure_call_run() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_called").await;
    run(
        &backend,
        "do $$ begin insert into pg_called (id, label) values (1, 'do'); end $$",
    )
    .await;
    run(
        &backend,
        "create or replace procedure pg_called_add(n int) language plpgsql as $$
         begin insert into pg_called (id, label) values (n, 'call'); end $$",
    )
    .await;
    run(&backend, "call pg_called_add(2)").await;

    let rows = run(&backend, "select label from pg_called order by id").await;
    assert_eq!(rows.cell(0, 0), Some(&text("do")));
    assert_eq!(rows.cell(1, 0), Some(&text("call")));
}

#[tokio::test]
async fn a_setting_changed_with_set_is_read_back_with_show() {
    let backend = connect(&server!()).await;
    run(&backend, "set application_name = 'sqmeow test'").await;

    let shown = run(&backend, "show application_name").await;
    assert_eq!(shown.columns()[0].name, "application_name");
    assert_eq!(shown.cell(0, 0), Some(&text("sqmeow test")));
}

#[tokio::test]
async fn common_table_expressions_and_window_functions() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "with recursive n(x) as (select 1 union all select x + 1 from n where x < 3)
         select x, sum(x) over (order by x) as running, lag(x) over (order by x) as previous
         from n",
    )
    .await;

    assert_eq!(result.row_count(), 3);
    assert_eq!(result.cell(2, 1), Some(&Cell::Int(6)));
    assert_eq!(result.cell(0, 2), Some(&Cell::Null));
    assert_eq!(result.cell(2, 2), Some(&Cell::Int(2)));
}

#[tokio::test]
async fn arrays_and_special_values_decode() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select array[true, false] as flags, array[1.5::float8] as floats,
                array['0b7c1e6a-1f4d-4c2a-9a3e-5f6d7c8b9a01'::uuid] as idents,
                '{}'::int4[] as empty, '-0.5'::numeric as negative,
                'infinity'::timestamp as forever, 'NaN'::numeric as nan",
    )
    .await;

    assert_eq!(
        result.cell(0, 0),
        Some(&Cell::Array(vec![Cell::Bool(true), Cell::Bool(false)]))
    );
    assert_eq!(
        result.cell(0, 1),
        Some(&Cell::Array(vec![Cell::Float(1.5)]))
    );
    assert_eq!(
        result.cell(0, 2),
        Some(&Cell::Array(vec![Cell::Uuid(
            "0b7c1e6a-1f4d-4c2a-9a3e-5f6d7c8b9a01".into()
        )]))
    );
    assert_eq!(result.cell(0, 3), Some(&Cell::Array(Vec::new())));
    assert_eq!(result.cell(0, 4), Some(&Cell::Decimal("-0.5".into())));
    // Values nothing decodes still show the server's own text.
    for (column, want) in [(5, "infinity"), (6, "NaN")] {
        match result.cell(0, column) {
            Some(
                Cell::Unsupported { raw: value, .. }
                | Cell::Text(value)
                | Cell::Timestamp(value)
                | Cell::Decimal(value),
            ) => assert_eq!(value, want),
            other => panic!("expected {want}, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn lists_materialized_views_and_partitioned_tables() {
    let backend = connect(&server!()).await;
    run(&backend, "drop materialized view if exists pg_mv").await;
    run(&backend, "drop table if exists pg_parted cascade").await;
    run(&backend, "create materialized view pg_mv as select 1 as x").await;
    run(&backend, "refresh materialized view pg_mv").await;
    run(
        &backend,
        "create table pg_parted (id int, made date) partition by range (made)",
    )
    .await;

    let relations = backend.relations(SCHEMA).await.unwrap();
    let kind = |name: &str| relations.iter().find(|r| r.name == name).map(|r| r.kind);
    assert_eq!(kind("pg_mv"), Some(RelationKind::MaterializedView));
    assert_eq!(kind("pg_parted"), Some(RelationKind::Table));
}

#[tokio::test]
async fn a_select_from_one_table_is_edited_through_its_primary_key() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_edited").await;
    run(
        &backend,
        "insert into pg_edited values (1, 'a', null), (2, 'b', 'x')",
    )
    .await;

    let result = run(
        &backend,
        "select id, label as name, optional from pg_edited order by id",
    )
    .await;
    match result.source() {
        Some(Source::Table { schema, name, key }) => {
            assert_eq!(schema.as_deref(), Some(SCHEMA));
            assert_eq!(name, "pg_edited");
            assert_eq!(key, &vec![0]);
        }
        other => panic!("expected a table source, got {other:?}"),
    }

    let changes = Changes {
        updates: vec![(0, vec![(1, Some(r"c:\x".into())), (2, Some("it's".into()))])],
        deletes: vec![1],
        inserts: vec![vec![
            (0, Some("3".into())),
            (1, Some("new".into())),
            (2, None),
        ]],
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the changes should plan");
    backend.apply(&plan).await.expect("the plan should apply");

    let after = run(
        &backend,
        "select id, label, optional from pg_edited order by id",
    )
    .await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&text(r"c:\x")));
    assert_eq!(after.cell(0, 2), Some(&text("it's")));
    assert_eq!(after.cell(1, 0), Some(&Cell::Int(3)));
    assert_eq!(after.cell(1, 2), Some(&Cell::Null));
}

#[tokio::test]
async fn a_composite_key_finds_its_row_by_every_part() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists pg_pair").await;
    run(
        &backend,
        "create table pg_pair (a int, b text, v text, primary key (a, b))",
    )
    .await;
    run(
        &backend,
        "insert into pg_pair values (1, 'x', 'one'), (1, 'y', 'two')",
    )
    .await;

    let result = run(&backend, "select v, b, a from pg_pair order by b").await;
    assert!(result.source().is_some(), "{:?}", result.columns());
    let changes = Changes {
        updates: vec![(1, vec![(0, Some("changed".into()))])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend.apply(&plan).await.unwrap();

    let after = run(&backend, "select v from pg_pair order by b").await;
    assert_eq!(after.cell(0, 0), Some(&text("one")));
    assert_eq!(after.cell(1, 0), Some(&text("changed")));
}

#[tokio::test]
async fn a_column_added_after_its_table_was_read_can_be_edited() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_altered").await;
    run(
        &backend,
        "insert into pg_altered (id, label) values (1, 'a')",
    )
    .await;
    // Reading the table once is what fills the adapter's picture of it.
    run(&backend, "select * from pg_altered").await;
    run(
        &backend,
        "alter table pg_altered rename column optional to note",
    )
    .await;
    run(&backend, "alter table pg_altered add column added text").await;

    let result = run(&backend, "select * from pg_altered").await;
    let origins: Vec<Option<&str>> = result
        .columns()
        .iter()
        .map(|column| column.origin.as_deref())
        .collect();
    assert_eq!(
        origins,
        vec![Some("id"), Some("label"), Some("note"), Some("added")]
    );

    let changes = Changes {
        updates: vec![(0, vec![(2, Some("n".into())), (3, Some("new".into()))])],
        ..Changes::default()
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the new column should be editable");
    backend.apply(&plan).await.expect("the plan should apply");
    let after = run(&backend, "select note, added from pg_altered").await;
    assert_eq!(after.cell(0, 1), Some(&text("new")));
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_rollback").await;
    run(
        &backend,
        "insert into pg_rollback (id, label) values (1, 'a')",
    )
    .await;

    let error = backend
        .apply(&[
            "update pg_rollback set label = 'z' where id = 1".into(),
            "insert into pg_rollback_nowhere values (1)".into(),
        ])
        .await
        .unwrap_err();
    assert!(error.to_string().contains("pg_rollback_nowhere"), "{error}");
    assert_eq!(
        run(&backend, "select label from pg_rollback")
            .await
            .cell(0, 0),
        Some(&text("a"))
    );
}

#[tokio::test]
async fn an_edit_to_a_row_deleted_since_is_reported_and_rolled_back() {
    let backend = connect(&server!()).await;
    fixture(&backend, "pg_vanished").await;
    run(
        &backend,
        "insert into pg_vanished (id, label) values (1, 'a'), (2, 'b')",
    )
    .await;
    let result = run(&backend, "select id, label from pg_vanished order by id").await;
    run(&backend, "delete from pg_vanished where id = 2").await;

    let changes = Changes {
        updates: vec![
            (0, vec![(1, Some("first".into()))]),
            (1, vec![(1, Some("gone".into()))]),
        ],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    let error = backend.apply(&plan).await.unwrap_err();
    assert!(error.to_string().contains("no row"), "{error}");
    assert_eq!(
        run(&backend, "select label from pg_vanished")
            .await
            .cell(0, 0),
        Some(&text("a"))
    );
}

#[tokio::test]
async fn a_cancelled_query_leaves_the_connection_ready_for_the_next() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        stopper.cancel();
    });
    let error = backend
        .execute("select pg_sleep(8)", NO_CAP, cancel)
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled), "{error}");

    let started = std::time::Instant::now();
    let next = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        backend.execute("select 1", NO_CAP, CancellationToken::new()),
    )
    .await;
    assert!(
        matches!(next, Ok(Ok(_))),
        "the next query should not wait out the cancelled one: {:?}",
        started.elapsed()
    );
}

#[tokio::test]
async fn a_copy_to_stdout_answers_rather_than_hanging() {
    let backend = connect(&server!()).await;
    let outcome = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        backend.execute(
            "copy (select 1) to stdout",
            NO_CAP,
            CancellationToken::new(),
        ),
    )
    .await;
    assert!(outcome.is_ok(), "copy should answer, with rows or an error");
    assert_eq!(run(&backend, "select 1").await.row_count(), 1);
}
