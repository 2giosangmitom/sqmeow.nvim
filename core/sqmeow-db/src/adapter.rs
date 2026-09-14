//! The contract every database adapter meets.

use std::future::Future;

use tokio_util::sync::CancellationToken;

use crate::edit::Changes;
use crate::error::Result;
use crate::node::{ColumnNode, RelationNode, RoutineNode, SchemaNode};
use crate::result::ResultSet;

/// Which SQL dialect a connection speaks.
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
}

impl Dialect {
    /// The name shown in the drawer and the statusline.
    pub fn name(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::DuckDb => "duckdb",
            Self::Postgres => "postgres",
            Self::MySql => "mysql",
            Self::Redis => "redis",
            Self::MongoDb => "mongodb",
        }
    }

    /// Work out the dialect from a connection URL's scheme.
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
            // `+srv` finds the hosts through DNS, which is the driver's business too.
            "mongodb" | "mongodb+srv" => Some(Self::MongoDb),
            _ => None,
        }
    }
}

/// One live connection to a database.
pub trait Adapter: Send + Sync {
    /// Which dialect this connection speaks.
    fn dialect(&self) -> Dialect;

    /// Quote an identifier for this dialect.
    fn quote_ident(&self, name: &str) -> String;

    /// Run one statement, streaming rows until the cap is reached or the token is cancelled.
    fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<ResultSet>> + Send;

    /// Plan staged changes to a result into the statements that make them.
    fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        crate::edit::sql_plan(
            self.dialect(),
            |name| self.quote_ident(name),
            result,
            changes,
        )
    }

    /// Run planned statements together: all of them or, as far as the database allows, none.
    fn apply(&self, statements: &[String]) -> impl Future<Output = Result<()>> + Send;

    /// The schemas, or for MySQL the databases, this connection can see.
    fn schemas(&self) -> impl Future<Output = Result<Vec<SchemaNode>>> + Send;

    /// The tables and views in one schema.
    fn relations(&self, schema: &str) -> impl Future<Output = Result<Vec<RelationNode>>> + Send;

    /// The stored functions and procedures in one schema.
    fn routines(&self, schema: &str) -> impl Future<Output = Result<Vec<RoutineNode>>> + Send;

    /// The columns of one relation.
    fn columns(
        &self,
        schema: &str,
        relation: &str,
    ) -> impl Future<Output = Result<Vec<ColumnNode>>> + Send;

    /// Close the connection pool.
    fn close(&self) -> impl Future<Output = ()> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_the_schemes_people_type() {
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
        for url in ["redis://h/0", "rediss://h/0", "valkey://h", "valkeys://h"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::Redis), "{url}");
        }
        for url in ["mongodb://h/app", "mongodb+srv://cluster.example.net/app"] {
            assert_eq!(Dialect::from_url(url), Some(Dialect::MongoDb), "{url}");
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
        assert_eq!(Dialect::from_url("cassandra://localhost"), None);
        assert_eq!(Dialect::from_url("not a url"), None);
        assert_eq!(Dialect::from_url(""), None);
    }
}
