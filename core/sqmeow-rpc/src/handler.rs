use std::sync::Arc;

use rmpv::Value;

use crate::client::Client;

/// Represents a pending reply to a peer request.
///
/// Dropping the reply without answering sends a generic error so
/// `rpcrequest` in Neovim does not block forever.
pub struct Reply {
    inner: Option<(Client, u32)>,
}

impl Reply {
    /// Creates a pending reply for `msgid`.
    pub fn new(client: Client, msgid: u32) -> Self {
        Self {
            inner: Some((client, msgid)),
        }
    }

    /// Answers with a success value.
    pub fn ok(mut self, value: Value) {
        self.finish(Ok(value));
    }

    /// Answers with an error message.
    pub fn err(mut self, message: impl std::fmt::Display) {
        self.finish(Err(message.to_string()));
    }

    fn finish(&mut self, outcome: std::result::Result<Value, String>) {
        let Some((client, msgid)) = self.inner.take() else {
            return;
        };
        if let Err(error) = client.respond(msgid, outcome) {
            tracing::warn!(%error, msgid, "could not send a response");
        }
    }
}

impl Drop for Reply {
    fn drop(&mut self) {
        // Neovim blocks the editor inside `rpcrequest` until it gets an answer.
        self.finish(Err(
            "the handler dropped this request without answering".into()
        ));
    }
}

/// Dispatches peer calls to handler implementations.
///
/// Implementors receive requests via [`Handler::on_request`] and
/// notifications via [`Handler::on_notification`].
pub trait Handler: Send + Sync + 'static {
    /// Handles a call that expects an answer.
    ///
    /// Returns promptly; answers through `reply`. Dropping `reply` without
    /// answering sends a generic error.
    fn on_request(self: Arc<Self>, method: String, params: Vec<Value>, reply: Reply);

    /// Handles a fire-and-forget notification.
    ///
    /// The default implementation ignores the notification and logs at
    /// `debug` level.
    fn on_notification(self: Arc<Self>, method: String, params: Vec<Value>) {
        tracing::debug!(%method, count = params.len(), "ignoring a notification");
    }
}
