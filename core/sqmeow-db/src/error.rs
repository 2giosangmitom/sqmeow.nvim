/// Represents an error returned when talking to a database.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The driver rejected something.
    #[error("{0}")]
    Driver(String),

    /// No adapter recognises this URL's scheme.
    #[error("unsupported database URL (unknown or invalid scheme)")]
    UnsupportedUrl(String),

    /// The user cancelled while the statement was running.
    #[error("cancelled")]
    Cancelled,
}

impl Error {
    /// Wraps a driver error into [`Error::Driver`].
    pub fn driver(error: impl std::fmt::Display) -> Self {
        Self::Driver(error.to_string())
    }
}

/// Result alias used throughout this crate.
pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_urls_do_not_disclose_credentials() {
        let error = Error::UnsupportedUrl("unknown://user:secret@host/db?token=private".into());
        assert!(!error.to_string().contains("secret"));
        assert!(!error.to_string().contains("private"));
    }
}
