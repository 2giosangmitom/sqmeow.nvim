//! Database adapters for sqmeow.nvim.
//!
//! Dispatch is an enum rather than `dyn Adapter`. That costs no allocation per call, and it means
//! adding a database makes the compiler point at every place that must handle it, instead of
//! leaving a gap to discover at runtime.

pub mod sqlite;

use sqmeow_db::{Adapter, Dialect, Error, Result, ResultSet};
use tokio_util::sync::CancellationToken;

pub use sqlite::SqliteAdapter;

/// One live connection, whichever database it is.
#[derive(Debug)]
pub enum Backend {
    Sqlite(SqliteAdapter),
}

impl Backend {
    /// Open a connection, choosing the adapter from the URL's scheme.
    pub async fn connect(url: &str) -> Result<Self> {
        let dialect =
            Dialect::from_url(url).ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;

        match dialect {
            Dialect::Sqlite => Ok(Self::Sqlite(SqliteAdapter::connect(url).await?)),
            other => Err(Error::UnsupportedUrl(format!(
                "{} connections are not supported yet",
                other.name()
            ))),
        }
    }

    /// Which dialect this connection speaks.
    pub fn dialect(&self) -> Dialect {
        match self {
            Self::Sqlite(adapter) => adapter.dialect(),
        }
    }

    /// Quote an identifier for this dialect.
    pub fn quote_ident(&self, name: &str) -> String {
        match self {
            Self::Sqlite(adapter) => adapter.quote_ident(name),
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
        }
    }

    /// Close the underlying pool.
    pub async fn close(&self) {
        match self {
            Self::Sqlite(adapter) => adapter.close().await,
        }
    }
}

/// Dialects this build can connect to.
pub fn supported() -> Vec<&'static str> {
    vec![Dialect::Sqlite.name()]
}
