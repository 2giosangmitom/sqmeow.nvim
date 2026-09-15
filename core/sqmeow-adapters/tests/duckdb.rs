//! The DuckDB adapter against a real in-memory database.

use sqmeow_adapters::Backend;
use sqmeow_db::{
    Cell, Changes, Error, ForeignKey, KeyKind, RelationKind, Source, Table, TypeClass,
};
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

async fn people() -> Backend {
    let backend = database().await;
    run(
        &backend,
        "create table people (id integer primary key, name varchar, team integer)",
    )
    .await;
    run(
        &backend,
        "insert into people values (1, 'alice', 1), (2, 'bob', 2)",
    )
    .await;
    backend
}

#[tokio::test]
async fn a_plain_select_from_a_table_is_edited_by_its_key() {
    let backend = people().await;
    let result = run(
        &backend,
        "select id, name as who, id + 1 from people p order by id",
    )
    .await;

    assert_eq!(
        result.source(),
        Some(&Source::Tables(vec![Table {
            schema: Some("main".into()),
            name: "people".into(),
            key: vec![0],
            columns: vec![(0, "id".into()), (1, "name".into())],
        }]))
    );
    assert_eq!(result.columns()[0].key, KeyKind::Primary);

    let changes = Changes {
        updates: vec![(0, vec![(1, "ann".into())])],
        deletes: vec![1],
        inserts: vec![vec![(0, "3".into()), (1, sqmeow_db::edit::Value::Null)]],
    };
    let statements = backend.plan(&result, &changes).unwrap();
    backend.apply(&statements).await.unwrap();

    let after = run(&backend, "select id, name from people order by id").await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&Cell::Text("ann".into())));
    assert_eq!(after.cell(1, 0), Some(&Cell::Int(3)));
    assert_eq!(after.cell(1, 1), Some(&Cell::Null));
}

#[tokio::test]
async fn every_spelling_of_one_table_is_editable() {
    let backend = people().await;
    for sql in [
        "from people",
        "select * from main.people",
        "select p.* exclude (team) from people p",
        "select P.ID, Name from PEOPLE p",
    ] {
        let result = run(&backend, sql).await;
        assert!(
            matches!(result.source(), Some(Source::Tables(tables)) if tables[0].name == "people" && tables[0].key == [0]),
            "{sql}: {:?}",
            result.source()
        );
    }
}

#[tokio::test]
async fn a_result_that_is_not_one_row_per_table_row_is_read_only() {
    let backend = people().await;
    run(&backend, "create table loose (id integer, name varchar)").await;
    run(&backend, "create view named as select * from people").await;
    for sql in [
        "select name from people",
        "select distinct id, name from people",
        "select id, count(*) from people group by id",
        "with people as (select 1 as id) select id from people",
        "select id from people union all select id from people",
        "select a.id from people a join people b on a.id = b.id",
        "select id, id from people",
        "select * from loose",
        "select * from named",
        "select 1 as id",
    ] {
        assert_eq!(run(&backend, sql).await.source(), None, "{sql}");
    }
}

#[tokio::test]
async fn a_binary_key_finds_its_row() {
    let backend = database().await;
    run(
        &backend,
        "create table blobs (id blob primary key, note varchar)",
    )
    .await;
    run(
        &backend,
        "insert into blobs values ('\\xabcd'::blob, 'old')",
    )
    .await;

    let result = run(&backend, "select * from blobs").await;
    let changes = Changes {
        updates: vec![(0, vec![(1, "new".into())])],
        ..Changes::default()
    };
    backend
        .apply(&backend.plan(&result, &changes).unwrap())
        .await
        .unwrap();

    let after = run(&backend, "select note from blobs").await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("new".into())));
}

#[tokio::test]
async fn a_row_gone_since_it_was_read_is_not_written() {
    let backend = people().await;
    let result = run(&backend, "select * from people order by id").await;
    run(&backend, "delete from people where id = 1").await;

    let changes = Changes {
        updates: vec![(0, vec![(1, "ann".into())])],
        ..Changes::default()
    };
    let error = backend
        .apply(&backend.plan(&result, &changes).unwrap())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("no row had that key"), "{error}");
}

#[tokio::test]
async fn a_join_is_edited_through_each_table_key() {
    let backend = people().await;
    run(
        &backend,
        "create table teams (id integer primary key, name varchar)",
    )
    .await;
    run(&backend, "insert into teams values (1, 'red')").await;

    let result = run(
        &backend,
        "select p.*, t.name as team_name, t.id
         from people p left join teams t on t.id = p.team
         order by p.id",
    )
    .await;
    match result.source() {
        Some(Source::Tables(tables)) => {
            assert_eq!(tables.len(), 2);
            assert_eq!(tables[0].key, vec![0]);
            assert_eq!(tables[1].key, vec![4]);
            assert_eq!(tables[1].column(3), Some("name"));
        }
        other => panic!("expected tables, got {other:?}"),
    }
    assert_eq!(result.columns()[4].key, KeyKind::Primary);

    let changes = Changes {
        updates: vec![(0, vec![(1, "ann".into()), (3, "crimson".into())])],
        ..Changes::default()
    };
    backend
        .apply(&backend.plan(&result, &changes).unwrap())
        .await
        .unwrap();

    let after = run(
        &backend,
        "select p.name, t.name from people p join teams t on t.id = p.team",
    )
    .await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("ann".into())));
    assert_eq!(after.cell(0, 1), Some(&Cell::Text("crimson".into())));
}

#[tokio::test]
async fn a_filtered_result_stays_editable() {
    let backend = database().await;
    run(
        &backend,
        "create table filtered (id integer primary key, name varchar)",
    )
    .await;
    run(
        &backend,
        "insert into filtered values (1, 'ann'), (2, 'bob')",
    )
    .await;

    let origin = "select id, name from filtered order by id";
    let wrapped = sqmeow_db::sql::filtered(origin, "name = 'bob'", "").unwrap();
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
        .apply(&backend.plan(&result, &changes).unwrap())
        .await
        .expect("the plan should apply");
    let after = run(&backend, "select name from filtered where id = 2").await;
    assert_eq!(after.cell(0, 0), Some(&Cell::Text("rob".into())));
}

#[tokio::test]
async fn a_table_without_a_primary_key_is_edited_through_a_unique_one() {
    let backend = database().await;
    run(
        &backend,
        "create table tagged (code varchar unique, label varchar, n integer default 42)",
    )
    .await;
    run(&backend, "create index tagged_label on tagged (label)").await;
    run(
        &backend,
        "insert into tagged values ('a', 'one', 1), ('b', 'two', 2)",
    )
    .await;

    let result = run(&backend, "select code, label, n from tagged order by code").await;
    match result.source() {
        Some(Source::Tables(tables)) => assert_eq!(tables[0].key, vec![0]),
        other => panic!("expected a table source, got {other:?}"),
    }
    let changes = Changes {
        updates: vec![(0, vec![(2, sqmeow_db::edit::Value::Default)])],
        ..Changes::default()
    };
    let plan = backend.plan(&result, &changes).unwrap();
    backend.apply(&plan).await.expect("the plan should apply");
    let after = run(&backend, "select n from tagged order by code").await;
    assert_eq!(after.column_cells(0), &[Cell::Int(42), Cell::Int(2)]);

    assert_eq!(
        backend.indexes("main", "tagged").await.unwrap(),
        vec![
            sqmeow_db::IndexNode {
                name: "tagged_code_key".into(),
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
    let columns = backend.columns("main", "tagged").await.unwrap();
    assert_eq!(columns[2].default.as_deref(), Some("42"));
}
