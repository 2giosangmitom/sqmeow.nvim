use std::sync::Arc;

use rmpv::Value;

use crate::client::Client;

/// A request that still owes the peer an answer.
///
/// Handlers are synchronous by design: they take a `Reply`, spawn whatever work they need, and
/// return immediately. That is what keeps the editor from blocking on a database round trip.
/// The `Reply` can travel into a spawned task and answer from there.
pub struct Reply {
    inner: Option<(Client, u32)>,
}

impl Reply {
    /// Create a pending answer for `msgid`.
    pub fn new(client: Client, msgid: u32) -> Self {
        Self {
            inner: Some((client, msgid)),
        }
    }

    /// Answer with a value.
    pub fn ok(mut self, value: Value) {
        self.finish(Ok(value));
    }

    /// Answer with an error message.
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
        // Neovim blocks the editor inside `rpcrequest` until it gets an answer. Losing a `Reply`
        // would hang the UI, so a dropped one still answers, with an error.
        self.finish(Err(
            "the handler dropped this request without answering".into()
        ));
    }
}

/// What a peer's calls get dispatched to.
pub trait Handler: Send + Sync + 'static {
    /// Handle a call that expects an answer. Return promptly; answer through `reply`.
    fn on_request(self: Arc<Self>, method: String, params: Vec<Value>, reply: Reply);

    /// Handle a call that expects no answer. Ignored by default.
    fn on_notification(self: Arc<Self>, method: String, params: Vec<Value>) {
        tracing::debug!(%method, count = params.len(), "ignoring a notification");
    }
}
