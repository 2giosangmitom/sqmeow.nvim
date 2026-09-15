use rmpv::Value;

/// Represents an error produced by the transport, the codec, or the peer.
///
/// Covers malformed frames, I/O failures, and remote error payloads.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A message did not have the shape msgpack-rpc requires.
    #[error("malformed rpc message: {0}")]
    Protocol(String),

    /// The underlying stream failed.
    #[error("rpc io error: {0}")]
    Io(#[from] std::io::Error),

    /// A value could not be decoded from the stream.
    #[error("rpc decode error: {0}")]
    Decode(#[from] rmpv::decode::Error),

    /// A value could not be encoded onto the stream.
    #[error("rpc encode error: {0}")]
    Encode(#[from] rmpv::encode::Error),

    /// The peer answered a request with an error payload.
    #[error("peer returned an error: {0}")]
    Remote(String),

    /// The peer hung up, or the writer task is gone.
    #[error("the rpc connection is closed")]
    Closed,
}

impl Error {
    /// Creates a [`Error::Protocol`] from any displayable message.
    pub fn protocol(msg: impl std::fmt::Display) -> Self {
        Self::Protocol(msg.to_string())
    }

    /// Creates a [`Error::Remote`] from a peer error payload.
    ///
    /// Neovim encodes remote errors as `[code, message]`; other payloads are
    /// stringified verbatim.
    pub fn remote(value: &Value) -> Self {
        // Neovim answers with [code, message]; anything else is echoed verbatim.
        let text = match value {
            Value::Array(parts) => parts
                .iter()
                .filter_map(|p| p.as_str())
                .collect::<Vec<_>>()
                .join(": "),
            other => other.to_string(),
        };
        Self::Remote(if text.is_empty() {
            value.to_string()
        } else {
            text
        })
    }
}

/// Result alias used throughout this crate.
pub type Result<T> = std::result::Result<T, Error>;
