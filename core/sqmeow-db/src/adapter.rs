//! The contract every database adapter meets.
//!
//! The engine submits dialect-native statements through [`Adapter`] and receives
//! driver-independent [`ResultSet`] values. Drivers own network/pool behavior,
//! row decoding, schema discovery, and cancellation. The engine owns statement
//! selection, session history, and editor notifications.

use std::future::Future;

use tokio_util::sync::CancellationToken;

use crate::edit::Changes;
use crate::error::Result;
use crate::node::{
    ColumnNode, Details, IndexNode, RelationNode, RoleNode, RoutineNode, SchemaNode,
};
use crate::result::ResultSet;

/// Query language and database family a connection speaks, including non-SQL backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    Sqlite,
    DuckDb,
    Postgres,
    MySql,
    /// Not SQL at all: one command per line, and keys where the others have tables.
    Redis,
    /// Database commands written as Extended JSON documents, and collections where others have
    /// tables.
    MongoDb,
    /// CQL, spoken by ScyllaDB and Apache Cassandra.
    Scylla,
    /// SurrealQL, with namespaces and databases where others have schemas.
    SurrealDb,
    ClickHouse,
    Oracle,
    MsSql,
}

impl Dialect {
    /// Returns the canonical name shown in the drawer and statusline.
    pub fn name(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::DuckDb => "duckdb",
            Self::Postgres => "postgres",
            Self::MySql => "mysql",
            Self::Redis => "redis",
            Self::MongoDb => "mongodb",
            Self::Scylla => "scylla",
            Self::SurrealDb => "surrealdb",
            Self::ClickHouse => "clickhouse",
            Self::Oracle => "oracle",
            Self::MsSql => "mssql",
        }
    }

    /// Quote one identifier, escaping embedded delimiter characters.
    ///
    /// This does not split qualified names: quote schema and table separately
    /// before joining them with a dot. Do not use identifier quoting for values.
    pub fn quote_ident(self, name: &str) -> String {
        match self {
            Self::MsSql => format!("[{}]", name.replace(']', "]]")),
            Self::MySql => format!("`{}`", name.replace('`', "``")),
            Self::SurrealDb => format!("`{}`", name.replace('\\', "\\\\").replace('`', "\\`")),
            _ => format!("\"{}\"", name.replace('"', "\"\"")),
        }
    }

    /// Infers the dialect from a connection URL's scheme.
    ///
    /// Returns `None` if the scheme is unknown.
    pub fn from_url(url: &str) -> Option<Self> {
        let scheme = url.split_once("://").map_or_else(
            || url.split_once(':').map(|(scheme, _)| scheme),
            |(scheme, _)| Some(scheme),
        )?;

        match scheme.to_ascii_lowercase().as_str() {
            "sqlite" | "sqlite3" | "file" => Some(Self::Sqlite),
            "duckdb" => Some(Self::DuckDb),
            "postgres" | "postgresql" => Some(Self::Postgres),
            "mysql" | "mariadb" => Some(Self::MySql),
            // The trailing `s` is TLS, which is the driver's business and not a different dialect.
            "redis" | "rediss" | "valkey" | "valkeys" => Some(Self::Redis),
            // Every node of a cluster, or the Sentinels that know where its master is.
            "redis+cluster" | "rediss+cluster" | "redis+sentinel" | "rediss+sentinel" => {
                Some(Self::Redis)
            }
            // `+srv` finds the hosts through DNS, which is the driver's business too.
            "mongodb" | "mongodb+srv" => Some(Self::MongoDb),
            "scylla" | "cassandra" => Some(Self::Scylla),
            "surrealdb" | "surrealdbs" => Some(Self::SurrealDb),
            "clickhouse" | "clickhouses" => Some(Self::ClickHouse),
            "oracle" | "oracledb" | "oracletcps" => Some(Self::Oracle),
            "mssql" | "sqlserver" => Some(Self::MsSql),
            _ => None,
        }
    }
}

/// Defines the contract every database adapter implements.
///
/// Each adapter owns its connection pool and translates `sqmeow-db` types
/// to and from the underlying driver.
/// Methods receive unquoted schema/relation names; implementations are responsible
/// for binding values or quoting identifiers in generated statements. Default
/// metadata methods return empty results where a feature is unsupported.
pub trait Adapter: Send + Sync {
    /// Returns the dialect this connection speaks.
    fn dialect(&self) -> Dialect;

    /// Quotes an identifier for this dialect.
    fn quote_ident(&self, name: &str) -> String {
        self.dialect().quote_ident(name)
    }

    /// Execute one statement and retain at most `max_rows` rows in its result.
    ///
    /// Mark a capped result as truncated rather than treating the cap as failure.
    /// `cancel` is cooperative: adapters must stop or drain driver work safely
    /// before the connection can be reused. A cancelled statement need not undo
    /// side effects already committed by the database.
    fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<ResultSet>> + Send;

    /// Execute one statement using native bound values, never SQL interpolation.
    fn execute_bound(
        &self,
        statement: &str,
        values: &[crate::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<ResultSet>> + Send {
        async move {
            if values.is_empty() {
                self.execute(statement, max_rows, cancel).await
            } else {
                Err(crate::error::Error::driver(
                    "this adapter does not support query parameters",
                ))
            }
        }
    }

    /// Executes `statement` as a wrapper around `origin`.
    ///
    /// Tracing of columns to their source tables uses `origin`, the unwrapped
    /// query. This preserves edit provenance when filtering/sorting adds an outer
    /// SELECT. The default implementation ignores provenance and calls `execute`.
    fn execute_wrapped(
        &self,
        statement: &str,
        _origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<ResultSet>> + Send {
        self.execute(statement, max_rows, cancel)
    }

    /// Executes one statement, keeping every result set it returns in order.
    ///
    /// Drivers with multiple row sets (such as SQL Server batches) override this.
    /// The default wraps `execute_wrapped` in a one-element vector.
    fn execute_results(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<Vec<ResultSet>>> + Send {
        async move {
            self.execute_wrapped(statement, origin, max_rows, cancel)
                .await
                .map(|result| vec![result])
        }
    }

    /// Plans staged changes to a result into the SQL statements that make them.
    ///
    /// Does not write to the database. The default planner validates source/key
    /// metadata and generates dialect-quoted SQL; non-SQL adapters can override it.
    fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        crate::edit::sql_plan(self.dialect(), result, changes)
    }

    /// Applies planned statements transactionally where the dialect allows.
    ///
    /// Returns rows produced by statements that return them. Cancellation must
    /// not interrupt a commit: `Error::Cancelled` means no changes were committed.
    /// Adapters without transactions report partial application as a driver error
    /// instead, so callers do not mistake partial writes for a complete rollback.
    fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<Vec<ResultSet>>> + Send;

    /// Lists schemas visible to this connection.
    fn schemas(&self) -> impl Future<Output = Result<Vec<SchemaNode>>> + Send;

    /// Lists relations in a schema.
    fn relations(&self, schema: &str) -> impl Future<Output = Result<Vec<RelationNode>>> + Send;

    /// Lists routines in a schema.
    fn routines(&self, schema: &str) -> impl Future<Output = Result<Vec<RoutineNode>>> + Send;

    /// Lists columns of a relation.
    fn columns(
        &self,
        schema: &str,
        relation: &str,
    ) -> impl Future<Output = Result<Vec<ColumnNode>>> + Send;

    /// Lists indexes and unique constraints on a table.
    fn indexes(
        &self,
        _schema: &str,
        _relation: &str,
    ) -> impl Future<Output = Result<Vec<IndexNode>>> + Send {
        async { Ok(Vec::new()) }
    }

    /// Lists roles or users known to the server.
    fn roles(&self) -> impl Future<Output = Result<Vec<RoleNode>>> + Send {
        async { Ok(Vec::new()) }
    }

    /// Returns details for a relation, including comments and constraints.
    fn details(
        &self,
        _schema: &str,
        _relation: &str,
    ) -> impl Future<Output = Result<Details>> + Send {
        async { Ok(Details::default()) }
    }

    /// Closes the underlying connection pool.
    fn close(&self) -> impl Future<Output = ()> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_the_schemes_people_type() {
        assert_eq!(
            Dialect::from_url("mssql://sa@host/app"),
            Some(Dialect::MsSql)
        );
        assert_eq!(
            Dialect::from_url("SQLSERVER://sa@host/app"),
            Some(Dialect::MsSql)
        );
        assert_eq!(Dialect::MsSql.quote_ident("a]b"), "[a]]b]");
        assert_eq!(Dialect::from_url("sqlite://app.db"), Some(Dialect::Sqlite));
        assert_eq!(Dialect::from_url("sqlite::memory:"), Some(Dialect::Sqlite));
        assert_eq!(
            Dialect::from_url("duckdb:app.duckdb"),
            Some(Dialect::DuckDb)
        );
        assert_eq!(
            Dialect::from_url("postgres://localhost/x"),
            Some(Dialect::Postgres)
        );
        assert_eq!(
            Dialect::from_url("postgresql://localhost/x"),
            Some(Dialect::Postgres)
        );
        assert_eq!(
            Dialect::from_url("mysql://localhost/x"),
            Some(Dialect::MySql)
        );
        assert_eq!(
            Dialect::from_url("mariadb://localhost/x"),
            Some(Dialect::MySql)
        );
        for url in [
            "redis://h/0",
            "rediss://h/0",
            "valkey://h",
            "valkeys://h",
            "redis+cluster://a:7000,b:7001",
            "redis+sentinel://s:26379/mymaster/0",
        ] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::Redis), "{url}");
        }
        for url in ["mongodb://h/app", "mongodb+srv://cluster.example.net/app"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::MongoDb), "{url}");
        }
        for url in ["scylla://h/ks", "cassandra://h"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::Scylla), "{url}");
        }
        for url in ["surrealdb://h/ns/db", "surrealdbs://h"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::SurrealDb), "{url}");
        }
        for url in ["clickhouse://h/db", "clickhouses://h:8443"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::ClickHouse), "{url}");
        }
        for url in [
            "oracle://h/XEPDB1",
            "oracledb://h/XEPDB1",
            "oracletcps://h:2484/XEPDB1",
        ] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::Oracle), "{url}");
        }
    }

    #[test]
    fn the_scheme_is_case_insensitive() {
        assert_eq!(
            Dialect::from_url("PostgreSQL://localhost/x"),
            Some(Dialect::Postgres)
        );
    }

    #[test]
    fn an_unknown_scheme_is_rejected() {
        assert_eq!(Dialect::from_url("unknown://localhost"), None);
        assert_eq!(Dialect::from_url("not a url"), None);
        assert_eq!(Dialect::from_url(""), None);
    }
}
