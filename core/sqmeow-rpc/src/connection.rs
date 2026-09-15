use std::sync::Arc;

use tokio::sync::mpsc::UnboundedReceiver;

use crate::client::Client;
use crate::handler::{Handler, Reply};
use crate::message::Message;
use crate::transport::{self, Transport};

/// Represents a live msgpack-rpc session with one peer.
///
/// Owns the inbound frame queue and a [`Client`] for outbound calls. Call
/// [`Connection::serve`] to dispatch frames until the peer hangs up.
pub struct Connection {
    client: Client,
    incoming: UnboundedReceiver<Message>,
}

impl Connection {
    /// Creates a connection over an existing transport.
    pub fn new(transport: Transport) -> Self {
        let Transport { incoming, outgoing } = transport;
        Self {
            client: Client::new(outgoing),
            incoming,
        }
    }

    /// Creates a connection over this process's stdin and stdout.
    pub fn stdio() -> Self {
        Self::new(transport::stdio())
    }

    /// Returns a handle for calling the peer.
    ///
    /// The handle can be cloned and shares the underlying channel.
    pub fn client(&self) -> Client {
        self.client.clone()
    }

    /// Dispatches frames until the peer hangs up.
    ///
    /// Reads from the inbound queue and routes requests and notifications to
    /// `handler`, and responses to the waiting [`Client`] calls. Returns
    /// when the channel closes.
    pub async fn serve<H: Handler>(mut self, handler: Arc<H>) {
        while let Some(message) = self.incoming.recv().await {
            match message {
                Message::Response {
                    msgid,
                    error,
                    result,
                } => self.client.resolve(msgid, error, result),
                Message::Request {
                    msgid,
                    method,
                    params,
                } => {
                    let reply = Reply::new(self.client.clone(), msgid);
                    Arc::clone(&handler).on_request(method, params, reply);
                }
                Message::Notification { method, params } => {
                    Arc::clone(&handler).on_notification(method, params);
                }
            }
        }

        tracing::debug!("peer hung up");
        self.client.close();
    }
}
