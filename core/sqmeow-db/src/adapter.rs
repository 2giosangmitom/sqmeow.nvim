//! The contract every database adapter meets.
//!
//! The engine submits dialect-native statements through [`Adapter`] and receives
//! driver-independent [`ResultSet`] values. Drivers own network/pool behavior,
//! row decoding, schema discovery, and cancellation. The engine owns statement
//! selection, session history, and editor notifications.

use async_trait::async_trait;

use tokio_util::sync::CancellationToken;

use crate::edit::Changes;
use crate::error::Result;
use crate::node::{
    ColumnNode, Details, IndexNode, RelationNode, RelationshipNode, RoleNode, RoutineNode,
    SchemaNode,
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

/// Database execution, editing, and metadata discovery.
///
/// Each adapter owns its connection pool and translates `sqmeow-db` types
/// to and from the underlying driver.
/// Methods receive unquoted schema/relation names; implementations are responsible
/// for binding values or quoting identifiers in generated statements. Default
/// metadata methods return empty results where a feature is unsupported, except
/// relationship discovery, which reports unsupported explicitly.
#[async_trait]
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
    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet>;

    /// Execute one statement using native bound values, never SQL interpolation.
    async fn execute_bound(
        &self,
        statement: &str,
        values: &[crate::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        if values.is_empty() {
            self.execute(statement, max_rows, cancel).await
        } else {
            Err(crate::error::Error::driver(
                "this adapter does not support query parameters",
            ))
        }
    }

    /// Execute a bound batch and return its result sets.
    async fn execute_bound_results(
        &self,
        statement: &str,
        values: &[crate::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.execute_bound(statement, values, max_rows, cancel)
            .await
            .map(|result| vec![result])
    }

    /// Executes `statement` as a wrapper around `origin`.
    ///
    /// Tracing of columns to their source tables uses `origin`, the unwrapped
    /// query. This preserves edit provenance when filtering/sorting adds an outer
    /// SELECT. The default implementation ignores provenance and calls `execute`.
    async fn execute_wrapped(
        &self,
        statement: &str,
        _origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.execute(statement, max_rows, cancel).await
    }

    /// Executes one statement, keeping every result set it returns in order.
    ///
    /// Drivers with multiple row sets (such as SQL Server batches) override this.
    /// The default wraps `execute_wrapped` in a one-element vector.
    async fn execute_results(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.execute_wrapped(statement, origin, max_rows, cancel)
            .await
            .map(|result| vec![result])
    }

    /// Generate statements for staged result edits.
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
    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>>;

    /// Lists schemas visible to this connection.
    async fn schemas(&self) -> Result<Vec<SchemaNode>>;

    /// Lists relations in a schema.
    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>>;

    /// Lists routines in a schema.
    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>>;

    /// Lists columns of a relation.
    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>>;

    /// Lists indexes and unique constraints on a table.
    async fn indexes(&self, _schema: &str, _relation: &str) -> Result<Vec<IndexNode>> {
        Ok(Vec::new())
    }

    /// Lists foreign keys where this table is the source or target, with self references once.
    /// Unsupported adapters return an error, not an empty set of relationships.
    async fn relationships(&self, _schema: &str, _relation: &str) -> Result<Vec<RelationshipNode>> {
        Err(crate::error::Error::driver(
            "this adapter does not support relationship metadata",
        ))
    }

    /// Lists roles or users known to the server.
    async fn roles(&self) -> Result<Vec<RoleNode>> {
        Ok(Vec::new())
    }

    /// Returns details for a relation, including comments and constraints.
    async fn details(&self, _schema: &str, _relation: &str) -> Result<Details> {
        Ok(Details::default())
    }

    /// Closes the underlying database sessions and their background workers.
    async fn close(&self);
}

#[cfg(test)]
mod tests {
    use rstest::rstest;

    use super::*;

    struct Unsupported;

    #[async_trait]
    impl Adapter for Unsupported {
        fn dialect(&self) -> Dialect {
            Dialect::Redis
        }
        async fn execute(&self, _: &str, _: usize, _: CancellationToken) -> Result<ResultSet> {
            Err(crate::error::Error::driver("not used"))
        }
        async fn apply(&self, _: &[String], _: CancellationToken) -> Result<Vec<ResultSet>> {
            Ok(Vec::new())
        }
        async fn schemas(&self) -> Result<Vec<SchemaNode>> {
            Ok(Vec::new())
        }
        async fn relations(&self, _: &str) -> Result<Vec<RelationNode>> {
            Ok(Vec::new())
        }
        async fn routines(&self, _: &str) -> Result<Vec<RoutineNode>> {
            Ok(Vec::new())
        }
        async fn columns(&self, _: &str, _: &str) -> Result<Vec<ColumnNode>> {
            Ok(Vec::new())
        }
        async fn close(&self) {}
    }

    #[test]
    fn unsupported_relationship_metadata_is_not_an_empty_list() {
        fn assert_send<T: Send>(value: T) -> T {
            value
        }

        let adapter: &dyn Adapter = &Unsupported;
        let mut future = assert_send(adapter.relationships("main", "table"));
        let mut context = std::task::Context::from_waker(std::task::Waker::noop());
        let std::task::Poll::Ready(Err(error)) = future.as_mut().poll(&mut context) else {
            panic!("unsupported metadata must immediately return an error");
        };
        assert!(
            error
                .to_string()
                .contains("does not support relationship metadata")
        );
    }

    #[rstest]
    #[case::mssql("mssql://sa@host/app", Some(Dialect::MsSql))]
    #[case::sqlserver("SQLSERVER://sa@host/app", Some(Dialect::MsSql))]
    #[case::sqlite_file("sqlite://app.db", Some(Dialect::Sqlite))]
    #[case::sqlite_memory("sqlite::memory:", Some(Dialect::Sqlite))]
    #[case::duckdb("duckdb:app.duckdb", Some(Dialect::DuckDb))]
    #[case::postgres("postgres://localhost/x", Some(Dialect::Postgres))]
    #[case::postgresql("postgresql://localhost/x", Some(Dialect::Postgres))]
    #[case::mixed_case("PostgreSQL://localhost/x", Some(Dialect::Postgres))]
    #[case::mysql("mysql://localhost/x", Some(Dialect::MySql))]
    #[case::mariadb("mariadb://localhost/x", Some(Dialect::MySql))]
    #[case::redis("redis://h/0", Some(Dialect::Redis))]
    #[case::redis_tls("rediss://h/0", Some(Dialect::Redis))]
    #[case::valkey("valkey://h", Some(Dialect::Redis))]
    #[case::valkey_tls("valkeys://h", Some(Dialect::Redis))]
    #[case::cluster("redis+cluster://a:7000,b:7001", Some(Dialect::Redis))]
    #[case::sentinel("redis+sentinel://s:26379/mymaster/0", Some(Dialect::Redis))]
    #[case::mongodb("mongodb://h/app", Some(Dialect::MongoDb))]
    #[case::mongodb_srv("mongodb+srv://cluster.example.net/app", Some(Dialect::MongoDb))]
    #[case::scylla("scylla://h/ks", Some(Dialect::Scylla))]
    #[case::cassandra("cassandra://h", Some(Dialect::Scylla))]
    #[case::surrealdb("surrealdb://h/ns/db", Some(Dialect::SurrealDb))]
    #[case::surrealdb_tls("surrealdbs://h", Some(Dialect::SurrealDb))]
    #[case::clickhouse("clickhouse://h/db", Some(Dialect::ClickHouse))]
    #[case::clickhouse_tls("clickhouses://h:8443", Some(Dialect::ClickHouse))]
    #[case::oracle("oracle://h/XEPDB1", Some(Dialect::Oracle))]
    #[case::oracledb("oracledb://h/XEPDB1", Some(Dialect::Oracle))]
    #[case::oracle_tls("oracletcps://h:2484/XEPDB1", Some(Dialect::Oracle))]
    #[case::unknown("unknown://localhost", None)]
    #[case::missing_scheme("not a url", None)]
    #[case::empty("", None)]
    fn recognises_url_schemes(#[case] url: &str, #[case] expected: Option<Dialect>) {
        assert_eq!(Dialect::from_url(url), expected);
    }

    #[test]
    fn identifiers_are_quoted_and_delimiters_are_escaped_without_a_connection() {
        for dialect in [
            Dialect::Sqlite,
            Dialect::DuckDb,
            Dialect::Postgres,
            Dialect::Oracle,
        ] {
            assert_eq!(dialect.quote_ident("plain"), "\"plain\"");
            assert_eq!(dialect.quote_ident("od\"d"), "\"od\"\"d\"");
        }
        assert_eq!(Dialect::MySql.quote_ident("plain"), "`plain`");
        assert_eq!(Dialect::MySql.quote_ident("od`d"), "`od``d`");
        assert_eq!(Dialect::MsSql.quote_ident("plain"), "[plain]");
        assert_eq!(Dialect::MsSql.quote_ident("a]b"), "[a]]b]");
    }
}
