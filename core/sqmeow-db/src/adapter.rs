//! The contract every database adapter meets.
//!
//! The trait uses `impl Future` returns rather than boxed futures, so it is not object safe. That
//! is deliberate: dispatch happens through an enum in the adapters crate, which costs no
//! allocation per call and makes the compiler point at every place a new database must be handled.

use std::future::Future;

use tokio_util::sync::CancellationToken;

use crate::error::Result;
use crate::result::ResultSet;

/// Which SQL dialect a connection speaks.
///
/// Adapters differ in more than their wire protocol: quoting, introspection queries, and
/// pagination syntax all vary, and code that must branch on those branches on this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    Sqlite,
    Postgres,
    MySql,
}

impl Dialect {
    /// The name shown in the drawer and the statusline.
    pub fn name(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::Postgres => "postgres",
            Self::MySql => "mysql",
        }
    }

    /// Work out the dialect from a connection URL's scheme.
    ///
    /// Every alias a user might reasonably type is accepted, because being told "unsupported url"
    /// for `postgresql://` when `postgres://` works is a bad first experience.
    pub fn from_url(url: &str) -> Option<Self> {
        let scheme = url.split_once("://").map_or_else(
            || url.split_once(':').map(|(scheme, _)| scheme),
            |(scheme, _)| Some(scheme),
        )?;

        match scheme.to_ascii_lowercase().as_str() {
            "sqlite" | "sqlite3" | "file" => Some(Self::Sqlite),
            "postgres" | "postgresql" => Some(Self::Postgres),
            "mysql" | "mariadb" => Some(Self::MySql),
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
    ///
    /// `max_rows` caps what is kept, not what the database computes. Reaching it marks the result
    /// truncated rather than failing it, so a stray `select * from events` shows something useful
    /// instead of an error.
    fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> impl Future<Output = Result<ResultSet>> + Send;

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
        assert_eq!(Dialect::from_url("mongodb://localhost"), None);
        assert_eq!(Dialect::from_url("not a url"), None);
        assert_eq!(Dialect::from_url(""), None);
    }
}
