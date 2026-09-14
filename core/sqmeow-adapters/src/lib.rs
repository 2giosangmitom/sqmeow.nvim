//! Database adapters for sqmeow.nvim.
//!
//! Dispatch is an enum rather than `dyn Adapter`. That costs no allocation per call, and it means
//! adding a database makes the compiler point at every place that must handle it, instead of
//! leaving a gap to discover at runtime.

pub mod mongodb;
pub mod mysql;
pub mod postgres;
pub mod redis;
pub mod sqlite;
mod stream;

use sqmeow_db::{
    Adapter, Changes, ColumnNode, Dialect, Error, RelationNode, Result, ResultSet, RoutineKind,
    RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

/// How long to keep trying to open a connection before giving up.
pub const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Open a pool, trying again while the server resets connections, until `CONNECT_TIMEOUT`.
///
/// sqlx retries a refused connection itself, but not one reset or cut off mid-handshake, which is
/// what a server that has just restarted does: a container's port accepts before the database
/// behind it is ready, so the first attempt after a restart fails when a second would not.
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

// `self::` for the same reason as `redis` below.
pub use self::mongodb::MongoAdapter;
pub use mysql::MySqlAdapter;
pub use postgres::PostgresAdapter;
// `self::`, because a bare `redis` here would also name the driver crate.
pub use self::redis::RedisAdapter;
pub use sqlite::SqliteAdapter;

/// Turn a routine's name and the database's own word for what it is into a node.
///
/// Every dialect that has stored routines at all says "procedure" or "function" somewhere in its
/// catalog, so the mapping is the same one three times and lives here rather than in each adapter.
pub(crate) fn routine_node(name: String, kind: &str) -> RoutineNode {
    let kind = if kind.eq_ignore_ascii_case("procedure") {
        RoutineKind::Procedure
    } else {
        RoutineKind::Function
    };
    RoutineNode { name, kind }
}

/// One live connection, whichever database it is.
#[derive(Debug)]
pub enum Backend {
    Sqlite(SqliteAdapter),
    Postgres(PostgresAdapter),
    MySql(MySqlAdapter),
    Redis(RedisAdapter),
    MongoDb(MongoAdapter),
}

impl Backend {
    /// Open a connection, choosing the adapter from the URL's scheme.
    pub async fn connect(url: &str) -> Result<Self> {
        Self::connect_to(url, None).await
    }

    /// Open a connection to one database of the server the URL points at.
    ///
    /// PostgreSQL and MongoDB use `database`: a URL that names none reaches a whole server, whose
    /// databases are each read through a connection of their own.
    pub async fn connect_to(url: &str, database: Option<&str>) -> Result<Self> {
        let dialect =
            Dialect::from_url(url).ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;

        match dialect {
            Dialect::Sqlite => Ok(Self::Sqlite(SqliteAdapter::connect(url).await?)),
            Dialect::Postgres => Ok(Self::Postgres(
                PostgresAdapter::connect(url, database).await?,
            )),
            Dialect::MySql => Ok(Self::MySql(MySqlAdapter::connect(url).await?)),
            Dialect::Redis => Ok(Self::Redis(RedisAdapter::connect(url).await?)),
            Dialect::MongoDb => Ok(Self::MongoDb(MongoAdapter::connect(url, database).await?)),
        }
    }

    /// Which dialect this connection speaks.
    pub fn dialect(&self) -> Dialect {
        match self {
            Self::Sqlite(adapter) => adapter.dialect(),
            Self::Postgres(adapter) => adapter.dialect(),
            Self::MySql(adapter) => adapter.dialect(),
            Self::Redis(adapter) => adapter.dialect(),
            Self::MongoDb(adapter) => adapter.dialect(),
        }
    }

    /// Quote an identifier for this dialect.
    pub fn quote_ident(&self, name: &str) -> String {
        match self {
            Self::Sqlite(adapter) => adapter.quote_ident(name),
            Self::Postgres(adapter) => adapter.quote_ident(name),
            Self::MySql(adapter) => adapter.quote_ident(name),
            Self::Redis(adapter) => adapter.quote_ident(name),
            Self::MongoDb(adapter) => adapter.quote_ident(name),
        }
    }

    /// Run one statement.
    pub async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        match self {
            Self::Sqlite(adapter) => adapter.execute(statement, max_rows, cancel).await,
            Self::Postgres(adapter) => adapter.execute(statement, max_rows, cancel).await,
            Self::MySql(adapter) => adapter.execute(statement, max_rows, cancel).await,
            Self::Redis(adapter) => adapter.execute(statement, max_rows, cancel).await,
            Self::MongoDb(adapter) => adapter.execute(statement, max_rows, cancel).await,
        }
    }

    /// Plan staged changes to a result into the statements that make them.
    pub fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        match self {
            Self::Sqlite(adapter) => adapter.plan(result, changes),
            Self::Postgres(adapter) => adapter.plan(result, changes),
            Self::MySql(adapter) => adapter.plan(result, changes),
            Self::Redis(adapter) => adapter.plan(result, changes),
            Self::MongoDb(adapter) => adapter.plan(result, changes),
        }
    }

    /// Run planned statements together.
    pub async fn apply(&self, statements: &[String]) -> Result<()> {
        match self {
            Self::Sqlite(adapter) => adapter.apply(statements).await,
            Self::Postgres(adapter) => adapter.apply(statements).await,
            Self::MySql(adapter) => adapter.apply(statements).await,
            Self::Redis(adapter) => adapter.apply(statements).await,
            Self::MongoDb(adapter) => adapter.apply(statements).await,
        }
    }

    /// The databases of a PostgreSQL cluster or a MongoDB server, when the URL named none, and
    /// `None` otherwise.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        match self {
            Self::Postgres(adapter) => adapter.databases().await,
            Self::MongoDb(adapter) => adapter.databases().await,
            _ => None,
        }
    }

    /// The database commands run on, for the one dialect where that changes under a connection's
    /// name: MongoDB, through `use`. `None` for the others, whose connection names its database.
    pub fn database(&self) -> Option<String> {
        match self {
            Self::MongoDb(adapter) => Some(adapter.database()),
            _ => None,
        }
    }

    /// The schemas, or for MySQL, Redis and MongoDB the databases, this connection can see.
    pub async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.schemas().await,
            Self::Postgres(adapter) => adapter.schemas().await,
            Self::MySql(adapter) => adapter.schemas().await,
            Self::Redis(adapter) => adapter.schemas().await,
            Self::MongoDb(adapter) => adapter.schemas().await,
        }
    }

    /// The tables and views in one schema, the keys in a Redis database, or a MongoDB database's
    /// collections.
    pub async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.relations(schema).await,
            Self::Postgres(adapter) => adapter.relations(schema).await,
            Self::MySql(adapter) => adapter.relations(schema).await,
            Self::Redis(adapter) => adapter.relations(schema).await,
            Self::MongoDb(adapter) => adapter.relations(schema).await,
        }
    }

    /// The stored functions and procedures in one schema.
    pub async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.routines(schema).await,
            Self::Postgres(adapter) => adapter.routines(schema).await,
            Self::MySql(adapter) => adapter.routines(schema).await,
            Self::Redis(adapter) => adapter.routines(schema).await,
            Self::MongoDb(adapter) => adapter.routines(schema).await,
        }
    }

    /// The columns of one relation.
    pub async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.columns(schema, relation).await,
            Self::Postgres(adapter) => adapter.columns(schema, relation).await,
            Self::MySql(adapter) => adapter.columns(schema, relation).await,
            Self::Redis(adapter) => adapter.columns(schema, relation).await,
            Self::MongoDb(adapter) => adapter.columns(schema, relation).await,
        }
    }

    /// Close the underlying pool.
    pub async fn close(&self) {
        match self {
            Self::Sqlite(adapter) => adapter.close().await,
            Self::Postgres(adapter) => adapter.close().await,
            Self::MySql(adapter) => adapter.close().await,
            Self::Redis(adapter) => adapter.close().await,
            Self::MongoDb(adapter) => adapter.close().await,
        }
    }
}

/// Dialects this build can connect to.
pub fn supported() -> Vec<&'static str> {
    vec![
        Dialect::Sqlite.name(),
        Dialect::Postgres.name(),
        Dialect::MySql.name(),
        Dialect::Redis.name(),
        Dialect::MongoDb.name(),
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
