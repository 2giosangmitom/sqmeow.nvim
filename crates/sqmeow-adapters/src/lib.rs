//! Database adapters for sqmeow.nvim.
//!
//! Each adapter implements [`sqmeow_db::adapter::Adapter`] for one dialect. The
//! [`Backend`] box erases the concrete type so the engine can hold a
//! heterogenous set of connections.
//!
//! URL schemes select adapters; protocol-compatible databases share a family
//! (for example PostgreSQL/CockroachDB and Redis/Dragonfly). Driver-specific
//! configuration stays in each adapter. Secret expansion and SSH forwarding are
//! handled by the engine before an adapter receives the connection URL.

mod clickhouse;
mod duckdb;
mod mongodb;
mod mssql;
mod mysql;
mod oracle;
mod postgres;
mod redis;
mod scylla;
mod sqlite;
mod stream;
mod surrealdb;

use sqmeow_db::adapter::Adapter;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::error::Error;
use sqmeow_db::error::Result;
use sqmeow_db::node::{RelationshipNode, RoutineKind, RoutineNode};
use tokio_util::sync::CancellationToken;

/// How long to keep trying to open a connection before giving up.
pub const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long to spend telling a server to stop a cancelled query before leaving it be.
pub(crate) const STOP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// A cancel that stopped an apply without transactions, which keeps what ran before it.
pub(crate) fn cancelled_after(done: usize, total: usize) -> Error {
    if done == 0 {
        return Error::Cancelled;
    }
    Error::driver(format!(
        "{done} of {total} changes were applied before the rest were cancelled"
    ))
}

/// A sent nontransactional write cannot be rolled back by dropping its reply.
/// Cancellation stops the next write, not the observation of this one's outcome.
pub(crate) async fn await_sent<T>(
    cancel: &CancellationToken,
    work: impl std::future::Future<Output = T>,
) -> Result<T> {
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(work.await)
}

/// Retry transient connection-establishment failures, using the driver's error classification.
/// Never use this to replay queries or writes whose outcome might already be committed.
pub(crate) async fn connect_retrying_with<T, E, F, Fut>(
    mut open: F,
    retryable: impl Fn(&E) -> bool,
) -> std::result::Result<T, E>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<T, E>>,
{
    let deadline = tokio::time::Instant::now() + CONNECT_TIMEOUT;
    loop {
        match open().await {
            Err(error) if retryable(&error) && tokio::time::Instant::now() < deadline => {
                tracing::debug!("the server cut the connection off; trying again");
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            }
            outcome => return outcome,
        }
    }
}

// `self::`, because a bare `clickhouse`, `duckdb`, `mongodb`, `redis` or `surrealdb` would also
// name the driver crate.
use self::clickhouse::ClickHouseAdapter;
use self::duckdb::DuckDbAdapter;
use self::mongodb::MongoAdapter;
pub use self::mongodb::filtered as mongo_filtered;
pub use self::redis::MAX_KEYS as REDIS_MAX_KEYS;
use self::redis::RedisAdapter;
use self::scylla::ScyllaAdapter;
use self::surrealdb::SurrealAdapter;
use mssql::MsSqlAdapter;
use mysql::MySqlAdapter;
use oracle::OracleAdapter;
use postgres::PostgresAdapter;
use sqlite::SqliteAdapter;

/// Turn a routine's name and the database's own word for what it is into a node.
pub(crate) fn routine_node(name: String, kind: &str) -> RoutineNode {
    let kind = if kind.eq_ignore_ascii_case("procedure") {
        RoutineKind::Procedure
    } else if kind.eq_ignore_ascii_case("package") {
        RoutineKind::Package
    } else {
        RoutineKind::Function
    };
    RoutineNode { name, kind }
}

/// One live connection, whichever database it is.
///
/// Derefs to the [`Adapter`] it holds; [`Backend::routine_source`] adds a
/// check that the definitions are actually visible.
pub struct Backend(Box<dyn Adapter>);

impl std::fmt::Debug for Backend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Backend").field(&self.0.dialect()).finish()
    }
}

impl std::ops::Deref for Backend {
    type Target = dyn Adapter;

    fn deref(&self) -> &Self::Target {
        &*self.0
    }
}

impl Backend {
    /// Open a connection, choosing the adapter from the URL's scheme.
    pub async fn connect(url: &str) -> Result<Self> {
        Self::connect_to(url, None, false).await
    }

    /// Open the URL, optionally selecting a child database on supported adapters.
    ///
    /// `database` overrides database selection for PostgreSQL, MongoDB, SurrealDB,
    /// Oracle, and SQL Server. Other adapters use the URL's database. `read_only`
    /// is forwarded where session-level enforcement exists; the engine also
    /// enforces its read-only policy before execution and edits.
    ///
    /// # Errors
    ///
    /// Returns `Error::UnsupportedUrl` for an unknown scheme, or the adapter's
    /// connection error for invalid options, authentication, or network failure.
    /// The URL must already have templates expanded and tunnel addresses applied.
    pub async fn connect_to(url: &str, database: Option<&str>, read_only: bool) -> Result<Self> {
        // More than one crypto backend is linked in, so rustls cannot pick one by itself.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let dialect =
            Dialect::from_url(url).ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;

        let adapter: Box<dyn Adapter> = match dialect {
            Dialect::Sqlite => Box::new(SqliteAdapter::connect(url, read_only).await?),
            Dialect::DuckDb => Box::new(DuckDbAdapter::connect(url, read_only).await?),
            Dialect::Postgres => {
                Box::new(PostgresAdapter::connect(url, database, read_only).await?)
            }
            Dialect::MySql => Box::new(MySqlAdapter::connect(url, read_only).await?),
            Dialect::Redis => Box::new(RedisAdapter::connect(url).await?),
            Dialect::MongoDb => Box::new(MongoAdapter::connect(url, database).await?),
            Dialect::Scylla => Box::new(ScyllaAdapter::connect(url).await?),
            Dialect::SurrealDb => Box::new(SurrealAdapter::connect(url, database).await?),
            Dialect::ClickHouse => Box::new(ClickHouseAdapter::connect(url, read_only).await?),
            Dialect::Oracle => Box::new(OracleAdapter::connect(url, database).await?),
            Dialect::MsSql => Box::new(MsSqlAdapter::connect(url, database).await?),
        };
        Ok(Self(adapter))
    }

    /// Read complete definitions, keeping overloaded routines together.
    ///
    /// # Errors
    ///
    /// Fails when any definition is missing or blank, rather than returning it.
    pub async fn routine_source(
        &self,
        schema: &str,
        name: &str,
        kind: RoutineKind,
    ) -> Result<Vec<String>> {
        let definitions = self.0.routine_source(schema, name, kind).await?;
        if definitions.is_empty() || definitions.iter().any(|source| source.trim().is_empty()) {
            return Err(Error::driver(
                "routine source is missing or not visible to this connection",
            ));
        }
        Ok(definitions)
    }
}

/// Group catalog rows ordered by source, constraint identity, and column position.
pub(crate) fn relationship_nodes(
    rows: impl IntoIterator<Item = (String, String, String, String, String, String, String)>,
) -> Vec<RelationshipNode> {
    let mut nodes: Vec<RelationshipNode> = Vec::new();
    for (
        name,
        source_schema,
        source_relation,
        column,
        target_schema,
        target_relation,
        referenced,
    ) in rows
    {
        if let Some(node) = nodes.last_mut()
            && node.name == name
            && node.source_schema == source_schema
            && node.source_relation == source_relation
            && node.target_schema == target_schema
            && node.target_relation == target_relation
        {
            node.columns.push(column);
            node.referenced.push(referenced);
        } else {
            nodes.push(RelationshipNode {
                name,
                source_schema,
                source_relation,
                columns: vec![column],
                target_schema,
                target_relation,
                referenced: vec![referenced],
            });
        }
    }
    nodes
}

/// Dialects this build can connect to.
pub fn supported() -> Vec<&'static str> {
    vec![
        Dialect::Sqlite.name(),
        Dialect::DuckDb.name(),
        Dialect::Postgres.name(),
        Dialect::MySql.name(),
        Dialect::Redis.name(),
        Dialect::MongoDb.name(),
        Dialect::Scylla.name(),
        Dialect::SurrealDb.name(),
        Dialect::ClickHouse.name(),
        Dialect::Oracle.name(),
        Dialect::MsSql.name(),
    ]
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn sent_write_keeps_its_success_after_cancel() {
        let cancel = tokio_util::sync::CancellationToken::new();
        let stopped = cancel.clone();
        let outcome = super::await_sent(&cancel, async move {
            stopped.cancel();
            Ok::<_, super::Error>(7)
        })
        .await
        .unwrap()
        .unwrap();
        assert_eq!(outcome, 7);
    }

    #[tokio::test]
    async fn pre_cancelled_write_never_polls_the_operation() {
        let cancel = tokio_util::sync::CancellationToken::new();
        cancel.cancel();
        let outcome = super::await_sent(&cancel, async {
            panic!("cancelled work was polled");
        })
        .await;
        assert!(matches!(outcome, Err(super::Error::Cancelled)));
    }
    use std::io::ErrorKind;

    use super::connect_retrying_with;
    use tokio_util::sync::CancellationToken;

    #[test]
    fn relationship_rows_group_by_constraint_and_source_not_target() {
        let row = |name: &str, source: &str, column: &str, referenced: &str| {
            (
                name.to_owned(),
                "s.with.dot".to_owned(),
                source.to_owned(),
                column.to_owned(),
                "target.schema".to_owned(),
                "target.table".to_owned(),
                referenced.to_owned(),
            )
        };
        let nodes = super::relationship_nodes([
            row("first", "child", "b", "y"),
            row("first", "child", "a", "x"),
            row("second", "child", "c", "x"),
            row("second", "other", "d", "x"),
        ]);
        assert_eq!(nodes.len(), 3);
        assert_eq!(nodes[0].columns, ["b", "a"]);
        assert_eq!(nodes[0].referenced, ["y", "x"]);
        assert_eq!(nodes[2].source_relation, "other");
    }

    #[tokio::test]
    async fn a_reset_connection_is_tried_again() {
        let mut attempts = 0;
        let opened = connect_retrying_with(
            || {
                attempts += 1;
                let attempt = attempts;
                async move {
                    if attempt < 3 {
                        Err(std::io::Error::from(ErrorKind::ConnectionReset))
                    } else {
                        Ok(attempt)
                    }
                }
            },
            |error| error.kind() == ErrorKind::ConnectionReset,
        )
        .await;

        assert_eq!(opened.expect("the third attempt should open"), 3);
    }

    #[tokio::test]
    async fn any_other_failure_is_reported_at_once() {
        let mut attempts = 0;
        let opened: std::io::Result<()> = connect_retrying_with(
            || {
                attempts += 1;
                async { Err(ErrorKind::PermissionDenied.into()) }
            },
            |error: &std::io::Error| error.kind() == ErrorKind::ConnectionReset,
        )
        .await;

        assert!(opened.is_err());
        assert_eq!(attempts, 1);
    }

    /// Statement splitting, per-statement results, and the row cap hold for
    /// the embedded backends.
    #[rstest::rstest]
    #[case::sqlite("sqlite::memory:")]
    #[case::duckdb("duckdb::memory:")]
    #[tokio::test]
    async fn statement_buffers_keep_their_boundaries(#[case] url: &str) {
        use sqmeow_db::sql;
        let db = super::Backend::connect(url).await.unwrap();
        let dialect = db.dialect();
        let source = "SELECT 'a;b' AS note;\n/* ; */ SELECT 2 AS n;";
        let statements = sql::split(source, dialect);
        assert_eq!(statements.len(), 2, "{dialect:?}");
        for statement in &statements {
            let results = db
                .execute_results(&statement.sql, &statement.sql, 10, CancellationToken::new())
                .await
                .unwrap();
            assert!(
                results.iter().any(|r| r.row_count() > 0),
                "{}",
                statement.sql
            );
            assert_eq!(
                sql::statement_at(&statements, statement.start_line),
                Some(statement)
            );
        }
        let result = db
            .execute(&statements[0].sql, 0, CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(result.row_count(), 0);
        assert!(result.is_truncated());
        db.close().await;
    }
}
