/// Represents an error produced by the transport or the codec.
///
/// I/O and codec failures are logged where they happen instead of travelling
/// as errors.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A message did not have the shape msgpack-rpc requires.
    #[error("malformed rpc message: {0}")]
    Protocol(String),

    /// The peer hung up, or the writer task is gone.
    #[error("the rpc connection is closed")]
    Closed,
}

impl Error {
    /// Creates a [`Error::Protocol`] from any displayable message.
    pub fn protocol(msg: impl std::fmt::Display) -> Self {
        Self::Protocol(msg.to_string())
    }
}

/// Result alias used by the rpc module.
pub type Result<T> = std::result::Result<T, Error>;
