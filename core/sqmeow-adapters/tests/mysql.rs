//! The MySQL adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::{
    Cell, Changes, Error, ForeignKey, KeyKind, RelationKind, ResultSet, RoutineKind, Source,
    TypeClass,
};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// Introspection reads the catalogue.
const SCHEMA: &str = "sqmeow";

async fn fixture(backend: &Backend, table: &str) {
    run(backend, &format!("drop table if exists {table}")).await;
    run(
        backend,
        &format!(
            "create table {table} (id int primary key, label varchar(10) not null, optional text)"
        ),
    )
    .await;
}

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
            day date, clock time, stamp datetime, moment timestamp, year_only year,
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
            '2026-01-02', '15:04:05', '2026-01-02 15:04:05', '2026-01-02 15:04:05', 2026,
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
        // A TIMESTAMP is stored as UTC, and the session is in UTC, so it reads back unchanged.
        Cell::Timestamp("2026-01-02 15:04:05 UTC".into()),
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
    // One past what an i64 holds.
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
    // Creating a function needs SUPER while binary logging is on.
    let backend = connect(&server!()).await;
    run(&backend, "drop function if exists listed_fn").await;
    run(&backend, "drop procedure if exists listed_proc").await;
    run(
        &backend,
        "create function listed_fn(x int) returns int deterministic return x",
    )
    .await;
    run(&backend, "create procedure listed_proc() select 1").await;

    let routines = backend
        .routines(SCHEMA)
        .await
        .expect("routines should load");
    let kind = |name: &str| {
        routines
            .iter()
            .find(|routine| routine.name == name)
            .map(|routine| routine.kind)
    };

    assert_eq!(kind("listed_fn"), Some(RoutineKind::Function));
    assert_eq!(kind("listed_proc"), Some(RoutineKind::Procedure));
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
    run(&backend, "drop table if exists keyed_child").await;
    run(&backend, "drop table if exists keyed_parent").await;
    run(
        &backend,
        "create table keyed_parent (id int primary key, name text)",
    )
    .await;
    run(
        &backend,
        "create table keyed_child (
            id int primary key,
            parent_id int,
            note text,
            foreign key (parent_id) references keyed_parent(id)
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
    run(&backend, "drop table if exists keyed_expr").await;
    run(&backend, "create table keyed_expr (id int primary key)").await;

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
async fn a_result_column_is_classified_by_its_type() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists classed").await;
    run(
        &backend,
        "create table classed (
            words text, counted int, at datetime, doc json, raw blob
        )",
    )
    .await;

    let result = run(&backend, "select words, counted, at, doc, raw from classed").await;

    let classes: Vec<TypeClass> = result.columns().iter().map(|column| column.class).collect();
    assert_eq!(
        classes,
        vec![
            TypeClass::Text,
            TypeClass::Number,
            TypeClass::Temporal,
            TypeClass::Json,
            TypeClass::Binary,
        ],
        "columns: {:?}",
        result.columns()
    );
}

#[tokio::test]
async fn a_drawer_column_names_what_it_references() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists fk_child").await;
    run(&backend, "drop table if exists fk_parent").await;
    run(&backend, "create table fk_parent (id int primary key)").await;
    run(
        &backend,
        "create table fk_child (
            id int primary key,
            parent_id int,
            foreign key (parent_id) references fk_parent(id)
        )",
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
            table: "sqmeow.fk_parent".into(),
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
async fn an_explain_tree_is_one_value_spanning_lines() {
    let backend = connect(&server!()).await;
    fixture(&backend, "explained").await;

    let tree = run(
        &backend,
        "explain format=tree select * from explained where label = 'a'",
    )
    .await;
    let names: Vec<&str> = tree.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["EXPLAIN"]);
    assert_eq!(tree.row_count(), 1);
    // The line breaks survive in the value, which the result window splits back into lines.
    match tree.cell(0, 0) {
        Some(Cell::Text(text)) => {
            assert!(text.starts_with("-> "), "{text}");
            assert!(
                text.contains('\n'),
                "a filter over a scan spans two lines: {text}"
            );
        }
        other => panic!("expected the plan as text, got {other:?}"),
    }
}

#[tokio::test]
async fn a_plain_explain_is_a_table() {
    let backend = connect(&server!()).await;
    fixture(&backend, "explained_table").await;

    // Laid out as columns already, so the result window keeps it a grid.
    let plan = run(&backend, "explain select * from explained_table").await;
    let names: Vec<&str> = plan.columns().iter().map(|c| c.name.as_str()).collect();
    assert!(names.contains(&"select_type"), "{names:?}");
    assert!(names.len() > 1);
}

fn text(value: &str) -> Cell {
    Cell::Text(value.into())
}

#[tokio::test]
async fn a_select_from_one_table_is_edited_through_its_primary_key() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_edited").await;
    run(
        &backend,
        "insert into my_edited values (1, 'a', null), (2, 'b', 'x')",
    )
    .await;

    let result = run(
        &backend,
        "select id, label as name, optional from my_edited order by id",
    )
    .await;
    match result.source() {
        Some(Source::Tables(tables)) => {
            assert_eq!(tables[0].name, "my_edited");
            assert_eq!(tables[0].key, vec![0]);
        }
        other => panic!("expected a table source, got {other:?}"),
    }

    let changes = Changes {
        updates: vec![(0, vec![(1, r"c:\x".into()), (2, "it's".into())])],
        deletes: vec![1],
        inserts: vec![vec![
            (0, "3".into()),
            (1, "new".into()),
            (2, sqmeow_db::edit::Value::Null),
        ]],
    };
    let plan = backend
        .plan(&result, &changes)
        .expect("the changes should plan");
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    let after = run(
        &backend,
        "select id, label, optional from my_edited order by id",
    )
    .await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&text(r"c:\x")));
    assert_eq!(after.cell(0, 2), Some(&text("it's")));
    assert_eq!(after.cell(1, 0), Some(&Cell::Int(3)));
    assert_eq!(after.cell(1, 2), Some(&Cell::Null));
}

#[tokio::test]
async fn setting_a_value_to_what_it_already_is_applies() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_same").await;
    run(&backend, "insert into my_same (id, label) values (1, 'a')").await;
    let result = run(&backend, "select id, label from my_same").await;

    // MySQL counts the rows it changed rather than the rows it found, and this changes none.
    let changes = Changes {
        updates: vec![(0, vec![(1, "a".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("an update that changes nothing is not a missing row");
}

#[tokio::test]
async fn a_composite_key_finds_its_row_by_every_part() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists my_pair").await;
    run(
        &backend,
        "create table my_pair (a int, b varchar(5), v text, primary key (a, b))",
    )
    .await;
    run(
        &backend,
        "insert into my_pair values (1, 'x', 'one'), (1, 'y', 'two')",
    )
    .await;

    let result = run(&backend, "select v, b, a from my_pair order by b").await;
    assert!(result.source().is_some(), "{:?}", result.columns());
    let changes = Changes {
        updates: vec![(1, vec![(0, "changed".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .unwrap();

    let after = run(&backend, "select v from my_pair order by b").await;
    assert_eq!(after.cell(0, 0), Some(&text("one")));
    assert_eq!(after.cell(1, 0), Some(&text("changed")));
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_rollback").await;
    run(
        &backend,
        "insert into my_rollback (id, label) values (1, 'a')",
    )
    .await;

    let error = backend
        .apply(
            &[
                "update my_rollback set label = 'z' where id = 1".into(),
                "insert into my_rollback_nowhere values (1)".into(),
            ],
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("my_rollback_nowhere"), "{error}");
    assert_eq!(
        run(&backend, "select label from my_rollback")
            .await
            .cell(0, 0),
        Some(&text("a"))
    );
}

#[tokio::test]
async fn an_edit_to_a_row_deleted_since_is_reported_and_rolled_back() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_vanished").await;
    run(
        &backend,
        "insert into my_vanished (id, label) values (1, 'a'), (2, 'b')",
    )
    .await;
    let result = run(&backend, "select id, label from my_vanished order by id").await;
    run(&backend, "delete from my_vanished where id = 2").await;

    let changes = Changes {
        updates: vec![
            (0, vec![(1, "first".into())]),
            (1, vec![(1, "gone".into())]),
        ],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    let error = backend
        .apply(&plan, CancellationToken::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("no row"), "{error}");
    assert_eq!(
        run(&backend, "select label from my_vanished")
            .await
            .cell(0, 0),
        Some(&text("a"))
    );
}

#[tokio::test]
async fn a_transaction_spans_statements_run_one_at_a_time() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_tx").await;

    run(&backend, "start transaction").await;
    run(&backend, "insert into my_tx (id, label) values (1, 'a')").await;
    run(&backend, "rollback").await;
    assert_eq!(run(&backend, "select id from my_tx").await.row_count(), 0);

    run(&backend, "begin").await;
    run(&backend, "insert into my_tx (id, label) values (2, 'b')").await;
    run(&backend, "commit").await;
    assert_eq!(run(&backend, "select id from my_tx").await.row_count(), 1);
}

#[tokio::test]
async fn upserts_count_the_way_mysql_does() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_upsert").await;
    run(
        &backend,
        "insert into my_upsert (id, label) values (1, 'a')",
    )
    .await;

    // MySQL counts a row updated through a duplicate key twice: once found, once changed.
    let updated = run(
        &backend,
        "insert into my_upsert (id, label) values (1, 'b') as new
         on duplicate key update label = new.label",
    )
    .await;
    assert_eq!(updated.affected(), Some(2));

    let replaced = run(
        &backend,
        "replace into my_upsert (id, label) values (1, 'c')",
    )
    .await;
    assert_eq!(replaced.affected(), Some(2));

    let ignored = run(
        &backend,
        "insert ignore into my_upsert (id, label) values (1, 'd')",
    )
    .await;
    assert_eq!(ignored.affected(), Some(0));
    assert_eq!(
        run(&backend, "select label from my_upsert")
            .await
            .cell(0, 0),
        Some(&text("c"))
    );
}

#[tokio::test]
async fn show_and_describe_read_as_text() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_show").await;

    let tables = run(&backend, "show tables like 'my_show'").await;
    assert_eq!(tables.cell(0, 0), Some(&text("my_show")));

    let described = run(&backend, "describe my_show").await;
    let names: Vec<&str> = described
        .columns()
        .iter()
        .map(|c| c.name.as_str())
        .collect();
    assert_eq!(
        names,
        vec!["Field", "Type", "Null", "Key", "Default", "Extra"]
    );
    assert_eq!(described.cell(0, 0), Some(&text("id")));
    assert_eq!(described.cell(0, 1), Some(&text("int")));
    assert_eq!(described.cell(0, 3), Some(&text("PRI")));

    let created = run(&backend, "show create table my_show").await;
    match created.cell(0, 1) {
        Some(Cell::Text(sql)) => assert!(sql.starts_with("CREATE TABLE"), "{sql}"),
        other => panic!("expected the statement as text, got {other:?}"),
    }

    let variables = run(&backend, "show variables like 'max_connections'").await;
    assert_eq!(variables.cell(0, 0), Some(&text("max_connections")));
    assert!(matches!(variables.cell(0, 1), Some(Cell::Text(_))));

    let indexes = run(&backend, "show index from my_show").await;
    assert_eq!(indexes.row_count(), 1);
}

#[tokio::test]
async fn a_procedure_call_shows_the_rows_it_selects() {
    let backend = connect(&server!()).await;
    run(&backend, "drop procedure if exists my_rows").await;
    run(
        &backend,
        "create procedure my_rows(in n int)
         begin
             if n > 0 then
                 select n as given, n * 2 as doubled;
             end if;
         end",
    )
    .await;

    let result = run(&backend, "call my_rows(21)").await;
    assert_eq!(result.row_count(), 1, "{:?}", result.columns());
    assert_eq!(result.cell(0, 1), Some(&Cell::Int(42)));

    // A call that selects nothing still runs.
    assert_eq!(run(&backend, "call my_rows(0)").await.row_count(), 0);
}

#[tokio::test]
async fn a_user_variable_lasts_the_session() {
    let backend = connect(&server!()).await;
    run(&backend, "set @answer = 42").await;
    assert_eq!(
        run(&backend, "select @answer as answer").await.cell(0, 0),
        Some(&Cell::Int(42))
    );
}

#[tokio::test]
async fn decodes_unsigned_bit_set_and_binary_columns() {
    let backend = connect(&server!()).await;
    run(
        &backend,
        "create temporary table more_kinds (
            tiny tinyint unsigned, small smallint unsigned, medium mediumint unsigned,
            whole int unsigned, bits bit(8), choices set('a', 'b', 'c'), fixed char(3),
            raw varbinary(4), negative decimal(5, 2)
        )",
    )
    .await;
    run(
        &backend,
        "insert into more_kinds values
            (255, 65535, 16777215, 4294967295, b'101', 'a,c', 'ab', x'00ff', -1.50)",
    )
    .await;

    let result = run(&backend, "select * from more_kinds").await;
    let expected = [
        Cell::Int(255),
        Cell::Int(65535),
        Cell::Int(16_777_215),
        Cell::Int(4_294_967_295),
        Cell::Int(5),
        text("a,c"),
        text("ab"),
        Cell::bytes(&[0x00, 0xff]),
        Cell::Decimal("-1.50".into()),
    ];
    for (index, want) in expected.iter().enumerate() {
        let column = &result.columns()[index].name;
        assert_eq!(result.cell(0, index), Some(want), "column `{column}`");
    }
}

#[tokio::test]
async fn json_functions_answer_json() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        r#"select json_object('a', 1) as doc, json_extract('{"a": [1, 2]}', '$.a') as list"#,
    )
    .await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Json(r#"{"a":1}"#.into())));
    assert_eq!(result.cell(0, 1), Some(&Cell::Json("[1,2]".into())));
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
    assert!(
        matches!(
            result.cell(2, 1),
            Some(Cell::Int(6)) | Some(Cell::Decimal(_))
        ),
        "{:?}",
        result.cell(2, 1)
    );
    assert_eq!(result.cell(0, 2), Some(&Cell::Null));
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
        .execute("select sleep(8)", NO_CAP, cancel)
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
async fn a_query_run_again_after_its_table_changed_shows_the_change() {
    let backend = connect(&server!()).await;
    fixture(&backend, "my_altered").await;
    run(
        &backend,
        "insert into my_altered (id, label) values (1, 'a')",
    )
    .await;
    run(&backend, "select * from my_altered").await;
    run(
        &backend,
        "alter table my_altered rename column optional to note",
    )
    .await;
    run(
        &backend,
        "alter table my_altered add column added int default 7",
    )
    .await;

    let result = run(&backend, "select * from my_altered").await;
    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "label", "note", "added"]);
    assert_eq!(result.cell(0, 3), Some(&Cell::Int(7)));

    let changes = Changes {
        updates: vec![(0, vec![(2, "n".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the renamed column should be written");
}

#[tokio::test]
async fn each_side_of_a_self_join_is_written_through_its_own_key() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists my_nodes").await;
    run(
        &backend,
        "create table my_nodes (id int primary key, name text, parent int)",
    )
    .await;
    run(
        &backend,
        "insert into my_nodes values (1, 'root', null), (2, 'child', 1)",
    )
    .await;

    let result = run(
        &backend,
        "select c.id, c.name, p.id as parent_id, p.name as parent
         from my_nodes c join my_nodes p on p.id = c.parent",
    )
    .await;
    let changes = Changes {
        updates: vec![(0, vec![(1, "leaf".into()), (3, "top".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");
    let names = run(&backend, "select name from my_nodes order by id").await;
    assert_eq!(names.column_cells(0), &[text("top"), text("leaf")]);
}

#[tokio::test]
async fn a_join_is_edited_through_each_table_key() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists my_members, my_teams").await;
    run(
        &backend,
        "create table my_teams (id int primary key, name text)",
    )
    .await;
    run(
        &backend,
        "create table my_members (id int primary key, name text, team int)",
    )
    .await;
    run(&backend, "insert into my_teams values (1, 'red')").await;
    run(
        &backend,
        "insert into my_members values (1, 'ann', 1), (2, 'bob', null)",
    )
    .await;

    let result = run(
        &backend,
        "select m.id, m.name, t.id, t.name
         from my_members m left join my_teams t on t.id = m.team
         order by m.id",
    )
    .await;
    let Some(source @ Source::Tables(tables)) = result.source() else {
        panic!("expected tables, got {:?}", result.source());
    };
    let names: Vec<&str> = tables.iter().map(|table| table.name.as_str()).collect();
    assert_eq!(names, ["my_members", "my_teams"]);
    assert!(!source.insertable());

    let changes = Changes {
        updates: vec![(0, vec![(1, "amy".into()), (3, "blue".into())])],
        deletes: vec![1],
        ..Changes::default()
    };
    backend
        .apply(
            &backend.plan(&result, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .expect("the plan should apply");

    let after = run(
        &backend,
        "select m.name, t.name from my_members m join my_teams t on t.id = m.team",
    )
    .await;
    assert_eq!(after.row_count(), 1);
    assert_eq!(after.cell(0, 0), Some(&text("amy")));
    assert_eq!(after.cell(0, 1), Some(&text("blue")));

    for sql in [
        "select a.*, b.* from my_members a join my_members b on b.id = a.id",
        "select id, name from my_members union all select id, name from my_teams",
        "select team, count(*) from my_members group by team",
    ] {
        assert!(run(&backend, sql).await.source().is_none(), "{sql}");
    }
}

#[tokio::test]
async fn a_filtered_result_stays_editable() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists my_filtered").await;
    run(
        &backend,
        "create table my_filtered (id int primary key, name text)",
    )
    .await;
    run(
        &backend,
        "insert into my_filtered values (1, 'ann'), (2, 'bob')",
    )
    .await;

    let origin = "select id, name from my_filtered order by id";
    let wrapped =
        sqmeow_db::sql::filtered(sqmeow_db::Dialect::MySql, origin, "name = 'bob'", "", &[])
            .unwrap();
    let result = backend
        .execute_wrapped(&wrapped, origin, NO_CAP, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.row_count(), 1);

    let changes = Changes {
        updates: vec![(0, vec![(1, "rob".into())])],
        ..Changes::default()
    };
    backend
        .apply(
            &backend.plan(&result, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .expect("the plan should apply");
    let after = run(&backend, "select name from my_filtered where id = 2").await;
    assert_eq!(after.cell(0, 0), Some(&text("rob")));

    // A derived table cannot hold two columns of one name.
    let joined = "select a.id, b.id from my_filtered a join my_filtered b on b.id = a.id";
    // Both sides are `id`, which a subquery cannot hold, so the filter names them apart.
    let names: Vec<String> = run(&backend, joined)
        .await
        .columns()
        .iter()
        .map(|column| column.name.clone())
        .collect();
    let wrapped = sqmeow_db::sql::filtered(
        sqmeow_db::Dialect::MySql,
        joined,
        "id_2 is not null",
        "",
        &names,
    )
    .unwrap();
    let filtered = backend
        .execute_wrapped(&wrapped, joined, NO_CAP, CancellationToken::new())
        .await
        .expect("the renamed columns should filter");
    assert_eq!(filtered.row_count(), 2);
}

#[tokio::test]
async fn a_table_without_a_primary_key_is_edited_through_a_unique_one() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists tagged_unique").await;
    run(
        &backend,
        "create table tagged_unique (code varchar(10) not null, label varchar(10), n int default 42,
             unique key tagged_code (code), key tagged_label (label))",
    )
    .await;
    run(&backend, "insert into tagged_unique values ('a', 'one', 1)").await;

    let result = run(&backend, "select code, label, n from tagged_unique").await;
    match result.source() {
        Some(Source::Tables(tables)) => assert_eq!(tables[0].key, vec![0]),
        other => panic!("expected a table source, got {other:?}"),
    }
    let changes = Changes {
        updates: vec![(0, vec![(1, "uno".into()), (2, "42".into())])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");
    let after = run(&backend, "select label, n from tagged_unique").await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("uno".into())));
    assert_eq!(after.cell(0, 1), Some(&Cell::Int(42)));

    assert_eq!(
        backend.indexes(SCHEMA, "tagged_unique").await.unwrap(),
        vec![
            sqmeow_db::IndexNode {
                name: "tagged_code".into(),
                columns: vec!["code".into()],
                unique: true,
                primary: false,
            },
            sqmeow_db::IndexNode {
                name: "tagged_label".into(),
                columns: vec!["label".into()],
                unique: false,
                primary: false,
            },
        ]
    );
    let columns = backend.columns(SCHEMA, "tagged_unique").await.unwrap();
    assert_eq!(columns[2].default.as_deref(), Some("42"));
    run(&backend, "drop table tagged_unique").await;
}

#[tokio::test]
async fn a_read_only_connection_is_refused_writes_by_the_server() {
    let backend = Backend::connect_to(&server!(), None, true).await.unwrap();
    run(&backend, "select 1").await;
    let error = backend
        .execute(
            "create table read_only_probe (id int)",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("READ ONLY"), "{error}");
}

#[tokio::test]
async fn a_new_row_with_an_auto_increment_key_is_read_back() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists auto_rows").await;
    run(
        &backend,
        "create table auto_rows (id int auto_increment primary key, name varchar(10))",
    )
    .await;
    run(&backend, "insert into auto_rows (name) values ('first')").await;

    let result = run(&backend, "select id, name from auto_rows").await;
    assert!(result.columns()[0].generated);
    let changes = Changes {
        inserts: vec![vec![(1, "second".into())]],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    let returned = backend
        .apply(&plan, CancellationToken::new())
        .await
        .expect("the plan should apply");

    assert_eq!(returned.len(), 1);
    assert_eq!(returned[0].cell(0, 0), Some(&Cell::Int(2)));
    assert_eq!(returned[0].cell(0, 1), Some(&text("second")));
    run(&backend, "drop table auto_rows").await;
}

#[tokio::test]
async fn a_table_without_a_key_is_edited_by_every_column() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists keyless_rows").await;
    run(
        &backend,
        "create table keyless_rows (label varchar(10), n int)",
    )
    .await;
    run(
        &backend,
        "insert into keyless_rows values ('a', 1), ('a', 1), ('b', null)",
    )
    .await;

    let result = run(
        &backend,
        "select label, n from keyless_rows order by label, n",
    )
    .await;
    let changes = Changes {
        updates: vec![(2, vec![(0, "bee".into())])],
        ..Changes::default()
    };
    backend
        .apply(
            &backend.plan(&result, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .expect("the plan should apply");

    let twins = Changes {
        deletes: vec![0],
        ..Changes::default()
    };
    let error = backend
        .apply(
            &backend.plan(&result, &twins).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("2 rows matched"), "{error}");
    run(&backend, "drop table keyless_rows").await;
}

#[tokio::test]
async fn the_drawer_is_not_held_up_by_a_long_query() {
    let backend = std::sync::Arc::new(connect(&server!()).await);
    let running = std::sync::Arc::clone(&backend);
    let query = tokio::spawn(async move {
        running
            .execute("select sleep(3)", NO_CAP, CancellationToken::new())
            .await
    });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let started = std::time::Instant::now();
    backend.schemas().await.unwrap();
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
    query.await.unwrap().unwrap();
}

#[tokio::test]
async fn a_table_describes_its_comments_keys_checks_triggers_and_definition() {
    let backend = connect(&server!()).await;
    run(&backend, "drop table if exists det_child, det_parent").await;
    run(&backend, "create table det_parent (id int primary key)").await;
    run(
        &backend,
        "create table det_child (id int primary key, parent_id int,
             n int check (n > 0) comment 'how many',
             constraint det_fk foreign key (parent_id) references det_parent (id)) comment 'children'",
    )
    .await;
    run(
        &backend,
        "create trigger det_touch before insert on det_child for each row set new.n = new.n",
    )
    .await;

    let details = backend.details(SCHEMA, "det_child").await.unwrap();
    assert_eq!(
        details.properties,
        vec![("comment".into(), "children".into())]
    );
    assert_eq!(
        details.column_comments,
        vec![("n".into(), "how many".into())]
    );
    assert_eq!(details.foreign_keys[0].name, "det_fk");
    assert_eq!(details.foreign_keys[0].target, "sqmeow.det_parent");
    assert_eq!(details.checks.len(), 1, "{details:?}");
    assert_eq!(
        details.triggers,
        vec![("det_touch".to_owned(), "BEFORE INSERT".to_owned())]
    );
    let definition = details.definition.unwrap();
    assert!(
        definition.contains("CREATE TABLE `det_child`"),
        "{definition}"
    );
    run(&backend, "drop table det_child, det_parent").await;
}

#[tokio::test]
async fn the_users_are_read() {
    let backend = connect(&server!()).await;
    let roles = backend.roles().await.unwrap();
    assert!(
        roles.iter().any(|role| role.name.starts_with("root@")),
        "{roles:?}"
    );
}
