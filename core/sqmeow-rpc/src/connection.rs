use std::sync::Arc;

use tokio::sync::mpsc::UnboundedReceiver;

use crate::client::Client;
use crate::handler::{Handler, Reply};
use crate::message::Message;
use crate::transport::{self, Transport};

/// A live msgpack-rpc session with one peer.
pub struct Connection {
    client: Client,
    incoming: UnboundedReceiver<Message>,
}

impl Connection {
    /// Build a connection over an existing transport.
    pub fn new(transport: Transport) -> Self {
        let Transport { incoming, outgoing } = transport;
        Self {
            client: Client::new(outgoing),
            incoming,
        }
    }

    /// Build a connection over this process's stdin and stdout.
    pub fn stdio() -> Self {
        Self::new(transport::stdio())
    }

    /// A handle for calling the peer. Clone it as needed.
    pub fn client(&self) -> Client {
        self.client.clone()
    }

    /// Read frames until the peer hangs up, dispatching each one.
    ///
    /// Responses are matched against in-flight requests here rather than reaching the handler,
    /// so a handler only ever sees calls the peer originated.
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
