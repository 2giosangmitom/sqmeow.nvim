//! The Oracle Database adapter against a real server.

use sqmeow_adapters::Backend;
use sqmeow_db::{Cell, Changes, Error, RelationKind, ResultSet, Source};
use tokio_util::sync::CancellationToken;

const NO_CAP: usize = usize::MAX;

// Introspection reads the catalog. Unquoted Oracle names are upper case.
const SCHEMA: &str = "SQMEOW";

async fn fixture(backend: &Backend, table: &str) {
    drop_table(backend, table).await;
    run(
        backend,
        &format!(
            "create table {table} (id number(10) primary key, label varchar2(10) not null, optional varchar2(10))"
        ),
    )
    .await;
}

/// Drop a table, view, materialized view or sequence that may not be there.
async fn drop_table(backend: &Backend, table: &str) {
    for sql in [
        format!("drop table {table}"),
        format!("drop view {table}"),
        format!("drop materialized view {table}"),
        format!("drop sequence {table}"),
    ] {
        let error = backend
            .execute(&sql, NO_CAP, CancellationToken::new())
            .await
            .err();
        // Anything but "does not exist" is real: ORA-00942 for tables and
        // views, ORA-12003 for a missing materialized view, ORA-12083 for
        // dropping one with the wrong statement, ORA-02289 for sequences.
        if error.is_some_and(|error| {
            let message = error.to_string();
            !message.contains("ORA-00942")
                && !message.contains("ORA-12003")
                && !message.contains("ORA-12083")
                && !message.contains("ORA-02289")
        }) {
            panic!("{sql} should drop or already be gone");
        }
    }
}

/// The server URL, or a note explaining why the test did nothing.
macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_ORACLE_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_ORACLE_URL, or run `just db-up`");
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
    assert_eq!(backend.dialect().name(), "oracle");
}

#[tokio::test]
async fn refuses_a_server_that_is_not_there() {
    let error = Backend::connect("oracle://sqmeow:sqmeow@127.0.0.1:1/FREE")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Driver(_)), "{error}");
}

#[tokio::test]
async fn selects_rows_with_their_columns() {
    let backend = connect(&server!()).await;
    let result = run(&backend, "select 1 as id, 'alice' as name from dual").await;

    let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["ID", "NAME"]);
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text("alice".into())));
}

#[tokio::test]
async fn decodes_the_types_a_real_schema_holds() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_kinds").await;
    run(
        &backend,
        "create table ora_kinds (
            whole number(10), exact number(10, 2),
            single binary_float, double binary_double,
            words varchar2(20), blurb clob,
            stamp timestamp, day date,
            span interval day to second,
            blob blob, bin4 raw(4)
        )",
    )
    .await;
    run(
        &backend,
        "insert into ora_kinds values (
            42, 123.45,
            1.5, 2.5,
            'words', 'a longer story',
            timestamp '2026-01-02 15:04:05', date '2026-01-02',
            interval '1 02:03:04' day to second,
            hextoraw('DEADBEEF'), hextoraw('0102')
        )",
    )
    .await;

    let result = run(&backend, "select * from ora_kinds").await;

    assert_eq!(result.cell(0, 0), Some(&Cell::Int(42)));
    assert_eq!(
        result.cell(0, 1),
        Some(&Cell::Decimal("123.45".into())),
        "an exact numeric keeps its digits"
    );
    assert_eq!(result.cell(0, 2), Some(&Cell::Float(1.5)));
    assert_eq!(result.cell(0, 3), Some(&Cell::Float(2.5)));
    assert_eq!(result.cell(0, 4), Some(&Cell::Text("words".into())));
    assert_eq!(
        result.cell(0, 5),
        Some(&Cell::Text("a longer story".into()))
    );
    match result.cell(0, 6) {
        Some(Cell::Timestamp(stamp)) => assert!(stamp.contains("2026-01-02"), "{stamp}"),
        other => panic!("expected a timestamp, got {other:?}"),
    }
    match result.cell(0, 7) {
        Some(Cell::Timestamp(day)) => assert!(day.contains("2026-01-02"), "{day}"),
        other => panic!("expected a date, got {other:?}"),
    }
    match result.cell(0, 8) {
        Some(Cell::Text(span)) => assert!(span.contains('1'), "{span}"),
        other => panic!("expected an interval, got {other:?}"),
    }
    assert_eq!(
        result.cell(0, 9),
        Some(&Cell::bytes(&[0xde, 0xad, 0xbe, 0xef]))
    );
    assert_eq!(result.cell(0, 10), Some(&Cell::bytes(&[0x01, 0x02])));
    drop_table(&backend, "ora_kinds").await;
}

#[tokio::test]
async fn a_null_decodes_in_every_column() {
    let backend = connect(&server!()).await;
    let result = run(
        &backend,
        "select cast(null as number), cast(null as varchar2(1)), cast(null as date) from dual",
    )
    .await;

    for column in 0..3 {
        assert_eq!(result.cell(0, column), Some(&Cell::Null), "column {column}");
    }
}

#[tokio::test]
async fn counts_rows_a_statement_changed() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_counted").await;
    run(&backend, "create table ora_counted (v number)").await;
    let result = run(&backend, "insert into ora_counted values (1)").await;
    assert_eq!(result.affected(), Some(1));
    run(&backend, "insert into ora_counted values (2)").await;
    run(&backend, "insert into ora_counted values (3)").await;
    assert_eq!(
        run(&backend, "update ora_counted set v = v + 1")
            .await
            .affected(),
        Some(3)
    );
    drop_table(&backend, "ora_counted").await;
}

#[tokio::test]
async fn reports_an_error_and_keeps_working() {
    let backend = connect(&server!()).await;
    let error = backend
        .execute("select nope from dual", NO_CAP, CancellationToken::new())
        .await
        .unwrap_err();

    assert!(
        error.to_string().to_ascii_lowercase().contains("nope"),
        "{error}"
    );
    assert_eq!(run(&backend, "select 1 from dual").await.row_count(), 1);
}

#[tokio::test]
async fn stops_at_the_row_cap_and_says_so() {
    let backend = connect(&server!()).await;
    let result = backend
        .execute(
            "select level from dual connect by level <= 1000",
            10,
            CancellationToken::new(),
        )
        .await
        .expect("the query should run");

    assert_eq!(result.row_count(), 10);
    assert!(result.is_truncated());
}

#[tokio::test]
async fn cancelling_returns_at_once() {
    let backend = connect(&server!()).await;
    let cancel = CancellationToken::new();

    let stopper = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        stopper.cancel();
    });

    // A loop with real work needs no rights and runs long enough to
    // cancel: an empty loop is optimized away. The abandoned loop keeps the
    // session busy; other tests use their own.
    let error = backend
        .execute(
            "declare s number := 0; begin for i in 1..500000000 loop s := s + i; end loop; end;",
            NO_CAP,
            cancel,
        )
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

    let current = schemas
        .iter()
        .find(|schema| schema.name == SCHEMA)
        .expect("the test user is listed");
    assert!(current.is_default);
}

#[tokio::test]
async fn lists_tables_views_and_sequences() {
    let backend = connect(&server!()).await;
    fixture(&backend, "ora_listed").await;
    run(
        &backend,
        "create or replace view ora_listed_view as select id from ora_listed",
    )
    .await;
    let sequence = "ora_listed_seq";
    drop_table(&backend, sequence).await;
    run(&backend, &format!("create sequence {sequence}")).await;

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

    assert_eq!(
        named("ORA_LISTED").map(|r| r.kind),
        Some(RelationKind::Table)
    );
    assert_eq!(
        named("ORA_LISTED_VIEW").map(|r| r.kind),
        Some(RelationKind::View)
    );
    assert_eq!(
        named("ORA_LISTED_SEQ").map(|r| r.kind),
        Some(RelationKind::Sequence)
    );
    drop_table(&backend, "ora_listed").await;
    drop_table(&backend, "ora_listed_view").await;
    drop_table(&backend, sequence).await;
}

#[tokio::test]
async fn lists_functions_and_procedures_apart() {
    let backend = connect(&server!()).await;
    run(
        &backend,
        "create or replace function ora_fn(x number) return number as begin return x; end;",
    )
    .await;
    run(
        &backend,
        "create or replace procedure ora_proc as begin null; end;",
    )
    .await;
    run(
        &backend,
        "create or replace package ora_pack as procedure p; function f(x number) return number; end;",
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

    assert_eq!(kinds("ORA_FN"), vec![sqmeow_db::RoutineKind::Function]);
    assert_eq!(kinds("ORA_PROC"), vec![sqmeow_db::RoutineKind::Procedure]);
    assert_eq!(kinds("ORA_PACK"), vec![sqmeow_db::RoutineKind::Package]);
    run(&backend, "drop function ora_fn").await;
    run(&backend, "drop procedure ora_proc").await;
    run(&backend, "drop package ora_pack").await;
}

#[tokio::test]
async fn creates_a_trigger_naming_new_and_old() {
    let backend = connect(&server!()).await;
    // Start clean: an earlier aborted run may have left objects behind.
    for sql in [
        "drop trigger ora_audit_probe_trg",
        "drop table ora_audit_log",
        "drop table ora_audit_probe",
    ] {
        let _ = backend.execute(sql, NO_CAP, CancellationToken::new()).await;
    }
    run(
        &backend,
        "create table ora_audit_probe (id number(10) primary key, n number(10))",
    )
    .await;
    run(
        &backend,
        "create table ora_audit_log (id number(10), action varchar2(10))",
    )
    .await;
    // `:NEW` and `:OLD` are part of the stored source, never evaluated: the
    // driver is handed NULLs instead of erroring on missing binds.
    run(
        &backend,
        "create or replace trigger ora_audit_probe_trg
         after insert or update or delete on ora_audit_probe
         for each row
         begin
           if inserting then
             insert into ora_audit_log values (:new.id, 'INSERT');
           elsif updating then
             insert into ora_audit_log values (:new.id, 'UPDATE');
           else
             insert into ora_audit_log values (:old.id, 'DELETE');
           end if;
         end;",
    )
    .await;
    run(&backend, "insert into ora_audit_probe values (1, 10)").await;
    run(&backend, "update ora_audit_probe set n = 11 where id = 1").await;
    run(&backend, "delete from ora_audit_probe where id = 1").await;
    let logged = run(&backend, "select action from ora_audit_log order by 1").await;
    let actions: Vec<&str> = (0..logged.row_count())
        .filter_map(|row| match logged.cell(row, 0) {
            Some(Cell::Text(action)) => Some(action.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(actions, vec!["DELETE", "INSERT", "UPDATE"]);
    // A placeholder in a real query still errors honestly, not as NULL.
    let error = backend
        .execute(
            "select * from ora_audit_probe where id = :1",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .expect_err("a bound query without binds should fail");
    assert!(error.to_string().contains("bind"), "{error}");
    run(&backend, "drop trigger ora_audit_probe_trg").await;
    run(&backend, "drop table ora_audit_log").await;
    run(&backend, "drop table ora_audit_probe").await;
}

#[tokio::test]
async fn lists_columns_in_their_declared_order() {
    let backend = connect(&server!()).await;
    fixture(&backend, "ora_described").await;

    let columns = backend
        .columns(SCHEMA, "ORA_DESCRIBED")
        .await
        .expect("columns should load");

    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, vec!["ID", "LABEL", "OPTIONAL"]);

    assert!(columns[0].primary_key, "id is the primary key");
    assert!(!columns[1].primary_key);
    assert!(!columns[1].nullable, "label is declared not null");
    assert!(columns[2].nullable, "optional is nullable");
    assert!(
        columns[1].type_name.contains("10"),
        "{}",
        columns[1].type_name
    );
    drop_table(&backend, "ora_described").await;
}

#[tokio::test]
async fn char_semantics_columns_show_character_lengths() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_chars").await;
    run(
        &backend,
        "create table ora_chars (code char(4), name varchar2(10 char), rawbin raw(16))",
    )
    .await;

    let columns = backend
        .columns(SCHEMA, "ORA_CHARS")
        .await
        .expect("columns should load");
    let types: Vec<&str> = columns
        .iter()
        .map(|column| column.type_name.as_str())
        .collect();
    // `NAME` is 10 characters, which is 40 bytes in AL32UTF8: the length
    // shown is characters, not bytes.
    assert_eq!(types, vec!["CHAR(4)", "VARCHAR2(10)", "RAW(16)"]);
    drop_table(&backend, "ora_chars").await;
}

#[tokio::test]
async fn a_select_from_one_table_is_edited_through_its_primary_key() {
    let backend = connect(&server!()).await;
    fixture(&backend, "ora_edited").await;
    run(&backend, "insert into ora_edited values (1, 'a', null)").await;
    run(&backend, "insert into ora_edited values (2, 'b', 'x')").await;

    let result = run(
        &backend,
        "select id, label, optional from ora_edited order by id",
    )
    .await;
    match result.source() {
        Some(Source::Tables(tables)) => {
            assert_eq!(tables[0].schema.as_deref(), Some(SCHEMA));
            assert_eq!(tables[0].name, "ORA_EDITED");
            assert_eq!(tables[0].key, vec![0]);
        }
        other => panic!("expected a table source, got {other:?}"),
    }

    let text = |value: &str| Cell::Text(value.into());
    let changes = Changes {
        updates: vec![(0, vec![(1, "z".into())])],
        deletes: vec![1],
        inserts: vec![vec![(0, "3".into()), (1, "new".into())]],
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
        "select id, label, optional from ora_edited order by id",
    )
    .await;
    assert_eq!(after.row_count(), 2);
    assert_eq!(after.cell(0, 1), Some(&text("z")));
    assert_eq!(after.cell(1, 0), Some(&Cell::Int(3)));
    drop_table(&backend, "ora_edited").await;
}

#[tokio::test]
async fn a_rollback_to_a_missing_savepoint_errors_from_the_server() {
    let backend = connect(&server!()).await;
    // A full API rollback would succeed silently; the statement must reach
    // Oracle to keep its meaning.
    let error = backend
        .execute(
            "rollback to savepoint nowhere",
            NO_CAP,
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("ORA-01086"), "{error}");
}

#[tokio::test]
async fn a_failing_statement_rolls_back_the_ones_before_it() {
    let backend = connect(&server!()).await;
    fixture(&backend, "ora_rollback").await;
    run(
        &backend,
        "insert into ora_rollback (id, label) values (1, 'a')",
    )
    .await;

    let error = backend
        .apply(
            &[
                "UPDATE ora_rollback SET label = 'z' WHERE id = 1".into(),
                "INSERT INTO ora_rollback_nowhere VALUES (1)".into(),
            ],
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(
        error.to_string().contains("ORA_ROLLBACK_NOWHERE"),
        "{error}"
    );
    assert_eq!(
        run(&backend, "select label from ora_rollback")
            .await
            .cell(0, 0),
        Some(&Cell::Text("a".into()))
    );
    drop_table(&backend, "ora_rollback").await;
}

#[tokio::test]
async fn a_table_describes_its_triggers_when_clauses_and_status() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_trg").await;
    run(
        &backend,
        "create table ora_trg (id number primary key, n number)",
    )
    .await;
    run(
        &backend,
        "create or replace trigger ora_trg_when before update on ora_trg
         for each row when (new.n > 0) begin :new.n := :new.n; end;",
    )
    .await;
    run(
        &backend,
        // No closing `;`: the adapter supplies it, since Oracle only
        // compiles stored PL/SQL with one.
        "create or replace trigger ora_trg_off after delete on ora_trg
         begin null; end",
    )
    .await;
    run(&backend, "alter trigger ora_trg_off disable").await;

    let details = backend.details(SCHEMA, "ORA_TRG").await.unwrap();
    let info = |name: &str| {
        details
            .triggers
            .iter()
            .find(|trigger| trigger.0 == name)
            .unwrap_or_else(|| panic!("{name} should be listed: {details:?}"))
            .1
            .clone()
    };
    assert_eq!(
        info("ORA_TRG_WHEN"),
        "UPDATE BEFORE EACH ROW WHEN (new.n > 0)"
    );
    assert_eq!(info("ORA_TRG_OFF"), "DELETE AFTER STATEMENT DISABLED");

    run(&backend, "drop trigger ora_trg_when").await;
    run(&backend, "drop trigger ora_trg_off").await;
    drop_table(&backend, "ora_trg").await;
}

#[tokio::test]
async fn a_sequence_describes_itself() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_seq").await;
    run(
        &backend,
        "create sequence ora_seq start with 5 increment by 5
         maxvalue 1000 nocycle cache 10 order",
    )
    .await;

    let details = backend.details(SCHEMA, "ORA_SEQ").await.unwrap();
    for property in [
        ("increment by", "5"),
        ("min value", "1"),
        ("max value", "1000"),
        ("cache size", "10"),
        ("cycle", "no"),
        ("order", "yes"),
    ] {
        assert!(
            details
                .properties
                .contains(&(property.0.into(), property.1.into())),
            "{property:?} should be listed: {details:?}"
        );
    }
    let definition = details.definition.expect("a sequence has a definition");
    assert!(definition.contains("ORA_SEQ"), "{definition}");

    drop_table(&backend, "ora_seq").await;
}

#[tokio::test]
async fn explain_plan_reads_the_plan_back() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_exp").await;
    run(
        &backend,
        "create table ora_exp (id number primary key, n number)",
    )
    .await;

    let plan = run(
        &backend,
        "explain plan for select * from ora_exp where id = 1",
    )
    .await;
    assert!(plan.row_count() > 0, "{plan:?}");
    assert_eq!(plan.columns()[0].name, "PLAN_TABLE_OUTPUT");
    let text: String = (0..plan.row_count())
        .filter_map(|row| match plan.cell(row, 0) {
            Some(Cell::Text(line)) => Some(line.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(text.contains("SELECT STATEMENT"), "{text}");
    drop_table(&backend, "ora_exp").await;
}

#[tokio::test]
async fn a_table_describes_its_comments_keys_checks_triggers_and_definition() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_det_child").await;
    drop_table(&backend, "ora_det_parent").await;
    run(
        &backend,
        "create table ora_det_parent (id number primary key)",
    )
    .await;
    run(
        &backend,
        "create table ora_det_child (
            id number primary key,
            parent_id number references ora_det_parent(id),
            n number default 1 check (n > 0)
        )",
    )
    .await;
    run(&backend, "comment on table ora_det_child is 'children'").await;
    run(&backend, "comment on column ora_det_child.n is 'how many'").await;
    run(&backend, "create index ora_det_n on ora_det_child (n)").await;
    run(
        &backend,
        "create or replace trigger ora_touch
         before insert on ora_det_child for each row begin null; end;",
    )
    .await;

    let details = backend.details(SCHEMA, "ORA_DET_CHILD").await.unwrap();
    assert_eq!(
        details.properties,
        vec![("comment".into(), "children".into())]
    );
    assert_eq!(
        details.column_comments,
        vec![("N".into(), "how many".into())]
    );
    assert_eq!(details.foreign_keys[0].target, "SQMEOW.ORA_DET_PARENT");
    assert_eq!(
        details.foreign_keys[0].columns,
        vec!["PARENT_ID".to_owned()]
    );
    assert_eq!(details.foreign_keys[0].referenced, vec!["ID".to_owned()]);
    assert!(details.checks[0].1.contains("n > 0"), "{details:?}");
    assert_eq!(details.triggers[0].0, "ORA_TOUCH");
    let definition = details.definition.unwrap();
    assert!(definition.contains("ORA_DET_CHILD"), "{definition}");
    run(&backend, "drop trigger ora_touch").await;
    drop_table(&backend, "ora_det_child").await;
    drop_table(&backend, "ora_det_parent").await;
}

#[tokio::test]
async fn indexes_name_their_direction_and_expressions() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_idx").await;
    run(
        &backend,
        "create table ora_idx (
            id number primary key, email varchar2(80), salary number(10, 2)
        )",
    )
    .await;
    run(
        &backend,
        "create index ora_idx_desc on ora_idx (salary desc)",
    )
    .await;
    run(
        &backend,
        "create index ora_idx_expr on ora_idx (upper(email))",
    )
    .await;

    let indexes = backend.indexes(SCHEMA, "ORA_IDX").await.unwrap();
    let columns = |name: &str| {
        indexes
            .iter()
            .find(|index| index.name == name)
            .unwrap_or_else(|| panic!("{name} should be listed: {indexes:?}"))
            .columns
            .clone()
    };
    assert_eq!(columns("ORA_IDX_DESC"), vec!["\"SALARY\" DESC".to_owned()]);
    assert_eq!(columns("ORA_IDX_EXPR"), vec!["UPPER(\"EMAIL\")".to_owned()]);

    run(&backend, "drop index ora_idx_desc").await;
    run(&backend, "drop index ora_idx_expr").await;
    drop_table(&backend, "ora_idx").await;
}

#[tokio::test]
async fn columns_survive_a_default_ending_in_a_newline() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_nl").await;
    drop_table(&backend, "ora_next").await;
    // A `CURRENT_TIMESTAMP` default followed by a newline lands in
    // DATA_DEFAULT, a LONG column the driver's cached statements misread,
    // desynchronizing the session with `unknown TTC message type` errors on
    // the *next* table read. Both tables must read here: the failure
    // surfaces on the second one.
    run(
        &backend,
        "CREATE TABLE ora_nl (
            id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            full_name VARCHAR2(100) NOT NULL,
            email VARCHAR2(100) UNIQUE NOT NULL,
            phone VARCHAR2(20),
            ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)",
    )
    .await;
    run(
        &backend,
        "CREATE TABLE ora_next (
            id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            user_id NUMBER NOT NULL,
            status VARCHAR2(20) DEFAULT 'pending',
            total NUMBER(12, 2) DEFAULT 0,
            odate TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)",
    )
    .await;

    let columns = backend.columns(SCHEMA, "ORA_NL").await.unwrap();
    assert_eq!(columns.len(), 5);
    let columns = backend.columns(SCHEMA, "ORA_NEXT").await.unwrap();
    assert_eq!(columns.len(), 5);

    drop_table(&backend, "ora_nl").await;
    drop_table(&backend, "ora_next").await;
}

#[tokio::test]
async fn a_materialized_view_describes_its_definition() {
    let backend = connect(&server!()).await;
    drop_table(&backend, "ora_mv").await;
    run(
        &backend,
        "create materialized view ora_mv as select 1 as x from dual",
    )
    .await;

    let details = backend.details(SCHEMA, "ORA_MV").await.unwrap();
    let definition = details.definition.expect("an mview has a definition");
    assert!(definition.contains("ORA_MV"), "{definition}");
    drop_table(&backend, "ora_mv").await;
}

#[tokio::test]
async fn roles_are_read() {
    let backend = connect(&server!()).await;
    let roles = backend.roles().await.unwrap();
    assert!(
        roles.iter().any(|role| role.name == SCHEMA),
        "the test user is a role"
    );
}

#[tokio::test]
async fn a_read_only_connection_is_only_checked_by_the_engine() {
    let backend = Backend::connect_to(&server!(), None, true).await.unwrap();
    assert!(backend.read_only_unenforced());
    run(&backend, "select 1 from dual").await;
}
