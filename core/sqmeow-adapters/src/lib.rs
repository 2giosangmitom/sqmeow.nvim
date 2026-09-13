//! Database adapters for sqmeow.nvim.
//!
//! Dispatch is an enum rather than `dyn Adapter`. That costs no allocation per call, and it means
//! adding a database makes the compiler point at every place that must handle it, instead of
//! leaving a gap to discover at runtime.

pub mod mysql;
pub mod postgres;
pub mod redis;
pub mod sqlite;
mod stream;

use sqmeow_db::{
    Adapter, ColumnNode, Dialect, Error, RelationNode, Result, ResultSet, RoutineKind, RoutineNode,
    SchemaNode,
};
use tokio_util::sync::CancellationToken;

/// How long to keep trying to open a connection before giving up.
pub const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

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
}

impl Backend {
    /// Open a connection, choosing the adapter from the URL's scheme.
    pub async fn connect(url: &str) -> Result<Self> {
        let dialect =
            Dialect::from_url(url).ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;

        match dialect {
            Dialect::Sqlite => Ok(Self::Sqlite(SqliteAdapter::connect(url).await?)),
            Dialect::Postgres => Ok(Self::Postgres(PostgresAdapter::connect(url).await?)),
            Dialect::MySql => Ok(Self::MySql(MySqlAdapter::connect(url).await?)),
            Dialect::Redis => Ok(Self::Redis(RedisAdapter::connect(url).await?)),
        }
    }

    /// Which dialect this connection speaks.
    pub fn dialect(&self) -> Dialect {
        match self {
            Self::Sqlite(adapter) => adapter.dialect(),
            Self::Postgres(adapter) => adapter.dialect(),
            Self::MySql(adapter) => adapter.dialect(),
            Self::Redis(adapter) => adapter.dialect(),
        }
    }

    /// Quote an identifier for this dialect.
    pub fn quote_ident(&self, name: &str) -> String {
        match self {
            Self::Sqlite(adapter) => adapter.quote_ident(name),
            Self::Postgres(adapter) => adapter.quote_ident(name),
            Self::MySql(adapter) => adapter.quote_ident(name),
            Self::Redis(adapter) => adapter.quote_ident(name),
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
        }
    }

    /// The schemas, or for MySQL and Redis the databases, this connection can see.
    pub async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.schemas().await,
            Self::Postgres(adapter) => adapter.schemas().await,
            Self::MySql(adapter) => adapter.schemas().await,
            Self::Redis(adapter) => adapter.schemas().await,
        }
    }

    /// The tables and views in one schema, or the keys in a Redis database.
    pub async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.relations(schema).await,
            Self::Postgres(adapter) => adapter.relations(schema).await,
            Self::MySql(adapter) => adapter.relations(schema).await,
            Self::Redis(adapter) => adapter.relations(schema).await,
        }
    }

    /// The stored functions and procedures in one schema.
    pub async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.routines(schema).await,
            Self::Postgres(adapter) => adapter.routines(schema).await,
            Self::MySql(adapter) => adapter.routines(schema).await,
            Self::Redis(adapter) => adapter.routines(schema).await,
        }
    }

    /// The columns of one relation.
    pub async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        match self {
            Self::Sqlite(adapter) => adapter.columns(schema, relation).await,
            Self::Postgres(adapter) => adapter.columns(schema, relation).await,
            Self::MySql(adapter) => adapter.columns(schema, relation).await,
            Self::Redis(adapter) => adapter.columns(schema, relation).await,
        }
    }

    /// Close the underlying pool.
    pub async fn close(&self) {
        match self {
            Self::Sqlite(adapter) => adapter.close().await,
            Self::Postgres(adapter) => adapter.close().await,
            Self::MySql(adapter) => adapter.close().await,
            Self::Redis(adapter) => adapter.close().await,
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
    ]
}
