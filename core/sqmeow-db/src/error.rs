/// What can go wrong talking to a database.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The driver rejected something.
    #[error("{0}")]
    Driver(String),

    /// No adapter recognises this URL's scheme.
    #[error("unsupported database url `{0}`")]
    UnsupportedUrl(String),

    /// The user cancelled while the statement was running.
    #[error("cancelled")]
    Cancelled,
}

impl Error {
    /// Wrap a driver's own error.
    pub fn driver(error: impl std::fmt::Display) -> Self {
        Self::Driver(error.to_string())
    }
}

/// Result alias used throughout this crate.
pub type Result<T> = std::result::Result<T, Error>;
