//! Provides database adapters for sqmeow.nvim.
//!
//! Each adapter implements [`sqmeow_db::Adapter`] for one dialect. The
//! [`Backend`] enum erases the concrete type so the engine can hold a
//! heterogenous set of connections.

pub mod clickhouse;
pub mod duckdb;
pub mod mongodb;
pub mod mysql;
pub mod postgres;
pub mod redis;
pub mod scylla;
pub mod sqlite;
mod stream;
pub mod surrealdb;

use sqmeow_db::{
    Adapter, Changes, ColumnNode, Details, Dialect, Error, IndexNode, RelationNode, Result,
    ResultSet, RoleNode, RoutineKind, RoutineNode, SchemaNode,
};
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

/// Open a pool, trying again while the server resets connections, until `CONNECT_TIMEOUT`.
pub(crate) async fn connect_retrying<T, F, Fut>(mut open: F) -> sqlx::Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = sqlx::Result<T>>,
{
    use std::io::ErrorKind;

    let deadline = tokio::time::Instant::now() + CONNECT_TIMEOUT;
    loop {
        match open().await {
            Err(sqlx::Error::Io(error))
                if matches!(
                    error.kind(),
                    ErrorKind::ConnectionReset
                        | ErrorKind::ConnectionAborted
                        | ErrorKind::UnexpectedEof
                        | ErrorKind::BrokenPipe
                ) && tokio::time::Instant::now() < deadline =>
            {
                tracing::debug!(%error, "the server cut the connection off; trying again");
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            }
            outcome => return outcome,
        }
    }
}

// `self::`, because a bare `clickhouse`, `duckdb` or `mongodb` would also name the driver crate.
pub use self::clickhouse::ClickHouseAdapter;
pub use self::duckdb::DuckDbAdapter;
pub use self::mongodb::MongoAdapter;
pub use mysql::MySqlAdapter;
pub use postgres::PostgresAdapter;
// `self::`, because a bare `redis` here would also name the driver crate.
pub use self::redis::RedisAdapter;
pub use self::scylla::ScyllaAdapter;
pub use sqlite::SqliteAdapter;
// `self::`, because a bare `surrealdb` would also name the driver crate.
pub use self::surrealdb::SurrealAdapter;

/// Turn a routine's name and the database's own word for what it is into a node.
pub(crate) fn routine_node(name: String, kind: &str) -> RoutineNode {
    let kind = if kind.eq_ignore_ascii_case("procedure") {
        RoutineKind::Procedure
    } else {
        RoutineKind::Function
    };
    RoutineNode { name, kind }
}

/// Run the same expression against whichever adapter a backend holds.
macro_rules! dispatch {
    ($backend:expr, $adapter:ident => $body:expr) => {
        match $backend {
            Backend::Sqlite($adapter) => $body,
            Backend::DuckDb($adapter) => $body,
            Backend::Postgres($adapter) => $body,
            Backend::MySql($adapter) => $body,
            Backend::Redis($adapter) => $body,
            Backend::MongoDb($adapter) => $body,
            Backend::Scylla($adapter) => $body,
            Backend::SurrealDb($adapter) => $body,
            Backend::ClickHouse($adapter) => $body,
        }
    };
}

/// One live connection, whichever database it is.
#[derive(Debug)]
pub enum Backend {
    Sqlite(SqliteAdapter),
    DuckDb(DuckDbAdapter),
    Postgres(PostgresAdapter),
    MySql(MySqlAdapter),
    Redis(RedisAdapter),
    MongoDb(MongoAdapter),
    Scylla(ScyllaAdapter),
    SurrealDb(SurrealAdapter),
    ClickHouse(ClickHouseAdapter),
}

impl Backend {
    /// Open a connection, choosing the adapter from the URL's scheme.
    pub async fn connect(url: &str) -> Result<Self> {
        Self::connect_to(url, None, false).await
    }

    /// Open a connection to one database of the server the URL points at, which refuses writes
    /// when `read_only` and the database can be told to.
    pub async fn connect_to(url: &str, database: Option<&str>, read_only: bool) -> Result<Self> {
        // More than one crypto backend is linked in, so rustls cannot pick one by itself.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let dialect =
            Dialect::from_url(url).ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;

        match dialect {
            Dialect::Sqlite => Ok(Self::Sqlite(SqliteAdapter::connect(url, read_only).await?)),
            Dialect::DuckDb => Ok(Self::DuckDb(DuckDbAdapter::connect(url, read_only).await?)),
            Dialect::Postgres => Ok(Self::Postgres(
                PostgresAdapter::connect(url, database, read_only).await?,
            )),
            Dialect::MySql => Ok(Self::MySql(MySqlAdapter::connect(url, read_only).await?)),
            Dialect::Redis => Ok(Self::Redis(RedisAdapter::connect(url).await?)),
            Dialect::MongoDb => Ok(Self::MongoDb(MongoAdapter::connect(url, database).await?)),
            Dialect::Scylla => Ok(Self::Scylla(ScyllaAdapter::connect(url).await?)),
            Dialect::SurrealDb => Ok(Self::SurrealDb(
                SurrealAdapter::connect(url, database).await?,
            )),
            Dialect::ClickHouse => Ok(Self::ClickHouse(
                ClickHouseAdapter::connect(url, read_only).await?,
            )),
        }
    }

    /// Which dialect this connection speaks.
    pub fn dialect(&self) -> Dialect {
        dispatch!(self, adapter => adapter.dialect())
    }

    /// Quote an identifier for this dialect.
    pub fn quote_ident(&self, name: &str) -> String {
        dispatch!(self, adapter => adapter.quote_ident(name))
    }

    /// Run one statement.
    pub async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        dispatch!(self, adapter => adapter.execute(statement, max_rows, cancel).await)
    }

    /// Run a query wrapping `origin`, tracing its columns to tables through `origin`.
    pub async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        dispatch!(self, adapter => adapter.execute_wrapped(statement, origin, max_rows, cancel).await)
    }

    /// Plan staged changes to a result into the statements that make them.
    pub fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        dispatch!(self, adapter => adapter.plan(result, changes))
    }

    /// Run planned statements together.
    pub async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        dispatch!(self, adapter => adapter.apply(statements, cancel).await)
    }

    /// The databases of a PostgreSQL cluster, a MongoDB server or a SurrealDB namespace, when the
    /// URL named none, and
    /// `None` otherwise.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        match self {
            Self::Postgres(adapter) => adapter.databases().await,
            Self::MongoDb(adapter) => adapter.databases().await,
            Self::SurrealDb(adapter) => adapter.databases().await,
            _ => None,
        }
    }

    /// The database MongoDB commands or SurrealDB queries run on.
    pub fn database(&self) -> Option<String> {
        match self {
            Self::MongoDb(adapter) => Some(adapter.database()),
            Self::SurrealDb(adapter) => Some(adapter.database()),
            _ => None,
        }
    }

    /// Whether a read-only connection has only the engine's statement check: a PostgreSQL-protocol
    /// server ignored the read-only session, or the server has none.
    pub fn read_only_unenforced(&self) -> bool {
        match self {
            Self::Postgres(adapter) => !adapter.read_only_session(),
            // SurrealDB has no read-only session at all.
            Self::SurrealDb(_) => true,
            _ => false,
        }
    }

    /// The schemas, or for MySQL, Redis and MongoDB the databases, this connection can see.
    pub async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        dispatch!(self, adapter => adapter.schemas().await)
    }

    /// The tables and views in one schema, the keys in a Redis database, or a MongoDB database's
    /// collections.
    pub async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        dispatch!(self, adapter => adapter.relations(schema).await)
    }

    /// The stored functions and procedures in one schema.
    pub async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        dispatch!(self, adapter => adapter.routines(schema).await)
    }

    /// The columns of one relation.
    pub async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        dispatch!(self, adapter => adapter.columns(schema, relation).await)
    }

    /// The roles or users the server knows.
    pub async fn roles(&self) -> Result<Vec<RoleNode>> {
        dispatch!(self, adapter => adapter.roles().await)
    }

    /// The keys of a Redis database matching a glob.
    pub async fn keys(&self, pattern: &str) -> Result<Vec<RelationNode>> {
        match self {
            Self::Redis(adapter) => adapter.keys(pattern).await,
            _ => Err(Error::driver("only Redis lists keys by a pattern")),
        }
    }

    /// Comments, foreign keys, checks, triggers and the definition of one relation.
    pub async fn details(&self, schema: &str, relation: &str) -> Result<Details> {
        dispatch!(self, adapter => adapter.details(schema, relation).await)
    }

    /// The indexes and unique constraints on one table.
    pub async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        dispatch!(self, adapter => adapter.indexes(schema, relation).await)
    }

    /// Close the underlying pool.
    pub async fn close(&self) {
        dispatch!(self, adapter => adapter.close().await)
    }
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
    ]
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;

    use super::connect_retrying;

    #[tokio::test]
    async fn a_reset_connection_is_tried_again() {
        let mut attempts = 0;
        let opened = connect_retrying(|| {
            attempts += 1;
            let attempt = attempts;
            async move {
                if attempt < 3 {
                    Err(sqlx::Error::Io(ErrorKind::ConnectionReset.into()))
                } else {
                    Ok(attempt)
                }
            }
        })
        .await;

        assert_eq!(opened.expect("the third attempt should open"), 3);
    }

    #[tokio::test]
    async fn any_other_failure_is_reported_at_once() {
        let mut attempts = 0;
        let opened: sqlx::Result<()> = connect_retrying(|| {
            attempts += 1;
            async { Err(sqlx::Error::PoolTimedOut) }
        })
        .await;

        assert!(opened.is_err());
        assert_eq!(attempts, 1);
    }
}
