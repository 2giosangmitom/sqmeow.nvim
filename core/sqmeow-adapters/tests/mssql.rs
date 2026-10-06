//! SQL Server integration tests; `just db-up` supplies the server.

use sqmeow_adapters::Backend;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::Changes;
use sqmeow_db::error::Error;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::types::KeyKind;
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

macro_rules! server {
    () => {
        match std::env::var("SQMEOW_TEST_MSSQL_URL") {
            Ok(url) => url,
            Err(_) => {
                eprintln!("skipped: set SQMEOW_TEST_MSSQL_URL, or run `just db-up`");
                return;
            }
        }
    };
}

async fn run(db: &Backend, sql: &str) -> ResultSet {
    db.execute(sql, usize::MAX, CancellationToken::new())
        .await
        .unwrap_or_else(|e| panic!("{sql}: {e}"))
}

include!("common/relationships.rs");

#[tokio::test]
async fn relationships_preserve_catalog_endpoints() {
    relationship_fixture(&Backend::connect(&server!()).await.unwrap(), "dbo").await;
}

#[tokio::test]
async fn bound_row_caps_apply_to_columns_that_resemble_internal_metadata() {
    let db = Backend::connect(&server!()).await.unwrap();
    run(&db, "CREATE TABLE #bound_alias (__sqmeow_bound_affected bigint); INSERT INTO #bound_alias VALUES (1), (2), (3)").await;
    for cap in [0, 1] {
        let results = db
            .execute_bound_results(
                "SELECT * FROM #bound_alias WHERE @P1=1",
                &[Value::Int(1)],
                cap,
                CancellationToken::new(),
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].row_count(), cap);
        assert!(results[0].is_truncated());
    }
}

#[tokio::test]
async fn bound_writes_report_inner_batch_affected_counts() {
    let db = Backend::connect(&server!()).await.unwrap();
    run(
        &db,
        "CREATE TABLE #bound_counts (id int PRIMARY KEY, name nvarchar(100))",
    )
    .await;
    for (sql, values, expected) in [
        (
            "INSERT INTO #bound_counts VALUES (@P1, @P2)",
            vec![Value::Int(1), Value::Text("first".into())],
            1,
        ),
        (
            "UPDATE #bound_counts SET name=@P1 WHERE id=@P2",
            vec![Value::Text("updated".into()), Value::Int(1)],
            1,
        ),
        (
            "DELETE FROM #bound_counts WHERE id=@P1",
            vec![Value::Int(99)],
            0,
        ),
    ] {
        let result = db
            .execute_bound(sql, &values, 10, CancellationToken::new())
            .await
            .unwrap();
        assert!(result.columns().is_empty());
        assert_eq!(result.affected(), Some(expected));
    }
}

#[tokio::test]
async fn bound_batches_keep_every_result_and_local_variables() {
    let db = Backend::connect(&server!()).await.unwrap();
    let results = db.execute_bound_results(
        "DECLARE @local int = 1; SELECT @P1 AS first; SELECT @P1 + @local AS second, @@ROWCOUNT AS affected",
        &[Value::Int(42)], 10, CancellationToken::new(),
    ).await.unwrap();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0].cell(0, 0), Some(&Cell::Int(42)));
    assert_eq!(results[1].cell(0, 0), Some(&Cell::Int(43)));
}

#[tokio::test]
async fn native_bound_scalars_nulls_and_repeated_parameters() {
    let db = Backend::connect(&server!()).await.unwrap();
    let text = "'; DROP TABLE dbo.sqmeow_bound; -- 日本🐱\n:ignored @P99";
    let result = db.execute_bound(
        "SELECT @P1 AS first, @P1 AS repeated, @P2 AS n, @P3 AS f, @P4 AS b, @P5 AS nt, @P6 AS ni, @P7 AS nf, @P8 AS nb",
        &[
            Value::Text(text.into()), Value::Int(i64::MAX), Value::Float(1.25), Value::Bool(true),
            Value::Null(Kind::Text), Value::Null(Kind::Int), Value::Null(Kind::Float), Value::Null(Kind::Bool),
        ],
        10, CancellationToken::new(),
    ).await.unwrap();
    assert_eq!(result.row_count(), 1);
    assert!(!result.elapsed().is_zero());
    assert_eq!(result.cell(0, 0), Some(&Cell::Text(text.into())));
    assert_eq!(result.cell(0, 1), Some(&Cell::Text(text.into())));
    assert_eq!(result.cell(0, 2), Some(&Cell::Int(i64::MAX)));
    assert_eq!(result.cell(0, 3), Some(&Cell::Float(1.25)));
    assert_eq!(result.cell(0, 4), Some(&Cell::Bool(true)));
    for column in 5..9 {
        assert_eq!(result.cell(0, column), Some(&Cell::Null));
    }
    for (column, expected) in [(5, "nvarchar"), (6, "bigint"), (7, "float"), (8, "bit")] {
        assert!(
            result.columns()[column].type_name.starts_with(expected),
            "{result:?}"
        );
    }
    assert_eq!(run(&db, "SELECT 42").await.cell(0, 0), Some(&Cell::Int(42)));
}

#[tokio::test]
async fn native_bound_empty_editable_provenance_and_row_caps() {
    let db = Backend::connect(&server!()).await.unwrap();
    run(&db, "DROP TABLE IF EXISTS dbo.sqmeow_mssql_bound; CREATE TABLE dbo.sqmeow_mssql_bound(id int IDENTITY PRIMARY KEY, label nvarchar(50), n int, doubled AS n*2)").await;
    run(
        &db,
        "INSERT INTO dbo.sqmeow_mssql_bound(label,n) VALUES(N'one',1),(N'two',2),(N'three',3)",
    )
    .await;
    let sql = "SELECT id, label, n, doubled FROM dbo.sqmeow_mssql_bound WHERE n >= @P1 ORDER BY id";
    let empty = db
        .execute_bound(sql, &[Value::Int(99)], 10, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(empty.row_count(), 0);
    assert_eq!(empty.columns().len(), 4);
    assert!(!empty.is_truncated());
    assert!(empty.source().is_some(), "{empty:?}");
    assert_eq!(empty.columns()[0].key, KeyKind::Primary);
    assert!(empty.columns()[0].generated);
    assert!(empty.columns()[3].generated);
    let changes = Changes {
        inserts: vec![vec![(1, "new".into()), (2, "4".into())]],
        ..Default::default()
    };
    assert!(db.plan(&empty, &changes).is_ok());
    for cap in [0, 1, 3] {
        let result = db
            .execute_bound(sql, &[Value::Int(1)], cap, CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(result.row_count(), cap);
        assert_eq!(result.is_truncated(), cap < 3);
        assert!(result.source().is_some(), "{result:?}");
        assert_eq!(result.columns()[0].key, KeyKind::Primary);
        assert_eq!(run(&db, "SELECT 42").await.cell(0, 0), Some(&Cell::Int(42)));
    }
    run(&db, "DROP TABLE dbo.sqmeow_mssql_bound").await;
}

#[tokio::test]
async fn types_empty_results_batches_and_caps() {
    let db = Backend::connect(&server!()).await.unwrap();
    assert_eq!(db.dialect(), Dialect::MsSql);
    let sql = "SELECT CAST(9223372036854775807 AS bigint) AS n, CAST(123456789012345678901234567890.12345678 AS decimal(38,8)) AS d, CAST(1 AS bit) AS b, N'日本🐱' AS s, 0x00ff AS bytes, CAST(NULL AS int) AS nil, CAST('2026-09-29' AS date) AS day, CAST('12:34:56.1234567' AS time) AS clock, CAST('2026-09-29T12:34:56.1234567+07:00' AS datetimeoffset) AS stamp, CAST('01234567-89ab-cdef-0123-456789abcdef' AS uniqueidentifier) AS id";
    let result = run(&db, sql).await;
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(i64::MAX)));
    assert_eq!(
        result.cell(0, 1),
        Some(&Cell::Decimal(
            "123456789012345678901234567890.12345678".into()
        ))
    );
    assert_eq!(result.cell(0, 2), Some(&Cell::Bool(true)));
    assert_eq!(result.cell(0, 3), Some(&Cell::Text("日本🐱".into())));
    assert_eq!(result.cell(0, 4), Some(&Cell::bytes(&[0, 255])));
    assert_eq!(result.cell(0, 5), Some(&Cell::Null));
    assert_eq!(result.cell(0, 6), Some(&Cell::Date("2026-09-29".into())));
    assert!(matches!(result.cell(0, 7), Some(Cell::Time(_))));
    assert!(matches!(result.cell(0, 8), Some(Cell::Timestamp(v)) if v.ends_with("+07:00")));
    assert!(matches!(result.cell(0, 9), Some(Cell::Uuid(_))));
    let empty = run(&db, "SELECT CAST(1 AS int) AS n WHERE 1=0").await;
    assert_eq!(empty.columns()[0].name, "n");
    assert_eq!(empty.row_count(), 0);
    let sql = "DECLARE @n int=7; SELECT @n AS n; SELECT 2 AS m";
    let results = db
        .execute_results(sql, sql, 10, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(results.len(), 2);
    assert_eq!(results[0].cell(0, 0), Some(&Cell::Int(7)));
    for cap in [0, 1] {
        let result = db
            .execute(
                "SELECT v FROM (VALUES(1),(2),(3)) t(v)",
                cap,
                CancellationToken::new(),
            )
            .await
            .unwrap();
        assert_eq!(result.row_count(), cap);
        assert!(result.is_truncated());
        assert_eq!(run(&db, "SELECT 42").await.cell(0, 0), Some(&Cell::Int(42)));
    }
    run(
        &db,
        "CREATE TABLE #session_test(id int); INSERT INTO #session_test VALUES(1)",
    )
    .await;
    assert_eq!(
        run(&db, "SELECT * FROM #session_test").await.cell(0, 0),
        Some(&Cell::Int(1))
    );
}

#[tokio::test]
async fn catalog_edits_and_transaction_rollback() {
    let db = Backend::connect(&server!()).await.unwrap();
    run(&db, "DROP TABLE IF EXISTS dbo.sqmeow_mssql_edits; CREATE TABLE dbo.sqmeow_mssql_edits(id int IDENTITY PRIMARY KEY, label nvarchar(50) NOT NULL, n int CHECK(n>0), doubled AS n*2)").await;
    assert_eq!(
        run(
            &db,
            "INSERT INTO dbo.sqmeow_mssql_edits(label,n) VALUES(N'one',1),(N'two',2)"
        )
        .await
        .affected(),
        Some(2)
    );
    assert!(db.schemas().await.unwrap().iter().any(|s| s.name == "dbo"));
    assert!(
        db.relations("dbo")
            .await
            .unwrap()
            .iter()
            .any(|r| r.name == "sqmeow_mssql_edits")
    );
    assert!(db.columns("dbo", "sqmeow_mssql_edits").await.unwrap()[0].primary_key);
    assert!(db.indexes("dbo", "sqmeow_mssql_edits").await.unwrap()[0].primary);
    assert_eq!(
        db.details("dbo", "sqmeow_mssql_edits")
            .await
            .unwrap()
            .checks
            .len(),
        1
    );
    assert!(!db.roles().await.unwrap().is_empty());
    let sql = "SELECT id, label, n, doubled FROM dbo.sqmeow_mssql_edits ORDER BY id";
    let result = run(&db, sql).await;
    assert!(result.source().is_some(), "{result:?}");
    assert_eq!(result.columns()[0].key, KeyKind::Primary);
    assert!(result.columns()[0].generated);
    assert!(result.columns()[3].generated);
    let changes = Changes {
        updates: vec![(0, vec![(1, "日本🐱".into())])],
        ..Default::default()
    };
    let statements = db.plan(&result, &changes).unwrap();
    db.apply(&statements, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(
        run(&db, sql).await.cell(0, 1),
        Some(&Cell::Text("日本🐱".into()))
    );
    let error = db
        .apply(
            &[
                "UPDATE dbo.sqmeow_mssql_edits SET n=8 WHERE id=1".into(),
                "UPDATE dbo.sqmeow_mssql_edits SET n=-1 WHERE id=2".into(),
            ],
            CancellationToken::new(),
        )
        .await;
    assert!(error.is_err());
    assert_eq!(run(&db, sql).await.cell(0, 2), Some(&Cell::Int(1)));
    let error = db
        .apply(
            &["UPDATE dbo.sqmeow_mssql_edits SET n=8".into()],
            CancellationToken::new(),
        )
        .await;
    assert!(error.is_err());
    assert_eq!(run(&db, sql).await.cell(0, 2), Some(&Cell::Int(1)));
    let changes = Changes {
        inserts: vec![vec![(1, "new".into()), (2, "3".into())]],
        ..Default::default()
    };
    let inserted = db
        .apply(
            &db.plan(&result, &changes).unwrap(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(inserted[0].row_count(), 1);
    assert_eq!(inserted[0].cell(0, 0), Some(&Cell::Int(3)));
    run(&db, "DROP TABLE dbo.sqmeow_mssql_edits").await;
}

#[tokio::test]
async fn filters_ctes_and_ordered_queries() {
    let db = Backend::connect(&server!()).await.unwrap();
    for sql in [
        "SELECT n FROM (VALUES(1),(2),(3)) t(n) ORDER BY n",
        "WITH data AS (SELECT n FROM (VALUES(1),(2),(3)) t(n)) SELECT n FROM data ORDER BY n",
        "SELECT TOP (2) n FROM (VALUES(1),(2),(3)) t(n) ORDER BY n",
    ] {
        let filtered = sqmeow_db::sql::filtered(Dialect::MsSql, sql, "n=2", "n DESC", &[]).unwrap();
        assert_eq!(run(&db, &filtered).await.cell(0, 0), Some(&Cell::Int(2)));
    }
}

#[tokio::test]
async fn cancels_and_reconnects_without_replaying() {
    let db = Backend::connect(&server!()).await.unwrap();
    let token = CancellationToken::new();
    let trigger = token.clone();
    let cancel = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        trigger.cancel();
    };
    let query = db.execute("WAITFOR DELAY '00:00:20'; SELECT 99", 10, token);
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(6), async {
        tokio::join!(query, cancel)
    })
    .await
    .unwrap();
    assert!(matches!(result, Err(Error::Cancelled)), "{result:?}");
    assert_eq!(run(&db, "SELECT 42").await.cell(0, 0), Some(&Cell::Int(42)));
}

#[tokio::test]
async fn bound_cancels_and_reconnects_without_replaying() {
    let db = Backend::connect(&server!()).await.unwrap();
    let token = CancellationToken::new();
    let trigger = token.clone();
    let cancel = async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        trigger.cancel();
    };
    let values = [Value::Int(99)];
    let query = db.execute_bound("WAITFOR DELAY '00:00:20'; SELECT @P1", &values, 10, token);
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(6), async {
        tokio::join!(query, cancel)
    })
    .await
    .unwrap();
    assert!(matches!(result, Err(Error::Cancelled)), "{result:?}");
    let result = db
        .execute_bound(
            "SELECT @P1",
            &[Value::Int(42)],
            10,
            CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(result.cell(0, 0), Some(&Cell::Int(42)));
}

#[tokio::test]
async fn lists_databases_and_rejects_untrusted_tls() {
    let url = server!();
    let mut parsed = url::Url::parse(&url).unwrap();
    parsed.set_path("");
    let db = Backend::connect(parsed.as_str()).await.unwrap();
    assert!(
        db.databases()
            .await
            .unwrap()
            .unwrap()
            .contains(&"master".into())
    );
    let selected = Backend::connect_to(parsed.as_str(), Some("tempdb"), false)
        .await
        .unwrap();
    assert_eq!(
        run(&selected, "SELECT DB_NAME()").await.cell(0, 0),
        Some(&Cell::Text("tempdb".into()))
    );
    parsed.set_query(None);
    assert!(Backend::connect(parsed.as_str()).await.is_err());
}
