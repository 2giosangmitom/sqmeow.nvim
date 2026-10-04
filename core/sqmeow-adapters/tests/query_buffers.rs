//! Shared buffer boundary regressions through every backend and protocol variant.
use sqmeow_adapters::Backend;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::sql;
use tokio_util::sync::CancellationToken;

async fn check(url: &str) {
    let db = Backend::connect(url).await.unwrap();
    let dialect = db.dialect();
    if matches!(
        dialect,
        Dialect::Redis
            | Dialect::MongoDb
            | Dialect::Scylla
            | Dialect::SurrealDb
            | Dialect::Oracle
            | Dialect::MsSql
    ) {
        assert!(
            db.read_only_unenforced(),
            "{dialect:?} must disclose lexical-only protection"
        );
    }
    let (source, expected) = match dialect {
        Dialect::MsSql => (
            "DECLARE @n int=7;\nSELECT @n AS n;\nGO -- next\nSELECT N'a;b' AS note;",
            2,
        ),
        Dialect::Oracle => (
            "SELECT 'a;b' AS note FROM dual;\nSELECT 2 AS n FROM dual;",
            2,
        ),
        Dialect::Redis => ("# note\nECHO \"a;b\"\nECHO \"日本🐱\"", 2),
        Dialect::MongoDb => ("// note\n{\"ping\":1}\n{\"ping\":1}", 2),
        Dialect::Scylla => (
            "SELECT cluster_name FROM system.local;\n/* ; */ SELECT cluster_name FROM system.local;",
            2,
        ),
        Dialect::SurrealDb => ("RETURN 'a;b';\nRETURN '日本🐱';", 2),
        _ => ("SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;", 2),
    };
    let statements = match dialect {
        Dialect::Redis => sql::split_lines(source),
        Dialect::MongoDb => sql::split_documents(source),
        _ => sql::split(source, dialect),
    };
    assert_eq!(statements.len(), expected, "{dialect:?}");
    for statement in &statements {
        let results = db
            .execute_results(&statement.sql, &statement.sql, 10, CancellationToken::new())
            .await
            .unwrap();
        assert!(!results.is_empty(), "{dialect:?}: {}", statement.sql);
        assert!(
            results.iter().any(|r| r.row_count() > 0),
            "{dialect:?}: {}",
            statement.sql
        );
        assert_eq!(
            sql::statement_at(&statements, statement.start_line),
            Some(statement)
        );
    }
    // A prior request must not replace the next request's text.
    let cap_query = if dialect == Dialect::MongoDb {
        // Command-status replies (such as ping) are not cursor rows.
        r#"{"aggregate":1,"pipeline":[{"$documents":[{"note":"a;b"}]}],"cursor":{}}"#
    } else {
        &statements[0].sql
    };
    let result = db
        .execute(cap_query, 0, CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(result.row_count(), 0, "{dialect:?}");
    assert!(result.is_truncated(), "{dialect:?}");
    db.close().await;
}

macro_rules! server_case {
    ($name:ident, $env:literal) => {
        #[tokio::test]
        async fn $name() {
            let Ok(url) = std::env::var($env) else {
                eprintln!("skipped: set {}", $env);
                return;
            };
            check(&url).await;
        }
    };
}

#[tokio::test]
async fn sqlite() {
    check("sqlite::memory:").await;
}
#[tokio::test]
async fn duckdb() {
    check("duckdb::memory:").await;
}
server_case!(postgres, "SQMEOW_TEST_POSTGRES_URL");
server_case!(mysql, "SQMEOW_TEST_MYSQL_URL");
server_case!(mssql, "SQMEOW_TEST_MSSQL_URL");
server_case!(oracle, "SQMEOW_TEST_ORACLE_URL");
server_case!(clickhouse, "SQMEOW_TEST_CLICKHOUSE_URL");
server_case!(redis, "SQMEOW_TEST_REDIS_URL");
server_case!(redis_cluster, "SQMEOW_TEST_REDIS_CLUSTER_URL");
server_case!(redis_sentinel, "SQMEOW_TEST_REDIS_SENTINEL_URL");
server_case!(dragonfly, "SQMEOW_TEST_DRAGONFLY_URL");
server_case!(mongodb, "SQMEOW_TEST_MONGODB_URL");
server_case!(scylla, "SQMEOW_TEST_SCYLLA_URL");
server_case!(cassandra, "SQMEOW_TEST_CASSANDRA_URL");
server_case!(surrealdb, "SQMEOW_TEST_SURREALDB_URL");
server_case!(cockroach, "SQMEOW_TEST_COCKROACH_URL");
server_case!(questdb, "SQMEOW_TEST_QUESTDB_URL");
