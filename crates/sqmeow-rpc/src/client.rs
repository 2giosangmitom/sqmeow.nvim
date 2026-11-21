use rmpv::Value;
use tokio::sync::mpsc::UnboundedSender;

use crate::error::{Error, Result};
use crate::message::Message;

/// Sends notifications and responses to the peer.
///
/// Holds the outbound channel. Cloning shares the same channel.
/// The engine never calls the peer and waits; it only notifies and responds.
#[derive(Clone)]
pub struct Client {
    outgoing: UnboundedSender<Message>,
}

impl Client {
    /// Creates a client from the outbound channel of a transport.
    pub fn new(outgoing: UnboundedSender<Message>) -> Self {
        Self { outgoing }
    }

    /// Notifies the peer without waiting for a response.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Closed`] if the outbound channel is gone.
    pub fn notify(&self, method: impl Into<String>, params: Vec<Value>) -> Result<()> {
        self.send(Message::Notification {
            method: method.into(),
            params,
        })
    }

    /// Responds to a request the peer made.
    ///
    /// Sends a msgpack-rpc response frame with the given `msgid`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Closed`] if the peer is gone.
    pub fn respond(&self, msgid: u32, outcome: std::result::Result<Value, String>) -> Result<()> {
        let (error, result) = match outcome {
            Ok(value) => (Value::Nil, value),
            Err(message) => (Value::from(message), Value::Nil),
        };
        self.send(Message::Response {
            msgid,
            error,
            result,
        })
    }

    fn send(&self, message: Message) -> Result<()> {
        self.outgoing.send(message).map_err(|_| Error::Closed)
    }
}
