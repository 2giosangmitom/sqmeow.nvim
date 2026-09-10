//! The request handler: one method table, and the shutdown signal.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_rpc::{Handler, Nvim, Reply};
use tokio::sync::Notify;

use crate::args::Args;

/// The protocol revision the editor is checked against.
///
/// Bumped only when a message changes shape in a way an older plugin cannot read. The plugin
/// compares this at handshake and tells the user to update, which beats a decode failure three
/// calls later with no explanation.
pub const PROTOCOL_VERSION: u64 = 1;

/// Everything one editor session talks to.
pub struct Core {
    #[expect(
        dead_code,
        reason = "events start flowing when the first adapter lands"
    )]
    nvim: Nvim,
    shutdown: Arc<Notify>,
}

impl Core {
    /// Build a core bound to one editor.
    pub fn new(nvim: Nvim) -> Self {
        Self {
            nvim,
            shutdown: Arc::new(Notify::new()),
        }
    }

    /// Resolves once a `shutdown` call has been handled.
    pub fn shutdown_signal(&self) -> Arc<Notify> {
        Arc::clone(&self.shutdown)
    }

    fn dispatch(&self, method: &str, args: Args) -> Result<Value, String> {
        match method {
            "handshake" => self.handshake(args),
            "ping" => Ok(Value::from("pong")),
            "shutdown" => {
                self.shutdown.notify_waiters();
                Ok(Value::Nil)
            }
            other => Err(format!("unknown method `{other}`")),
        }
    }

    /// Report what this binary is and what it can do.
    fn handshake(&self, args: Args) -> Result<Value, String> {
        let plugin_version = args.opt_string("plugin_version").unwrap_or_default();
        tracing::info!(%plugin_version, "handshake");

        Ok(Value::Map(vec![
            (
                Value::from("core_version"),
                Value::from(env!("CARGO_PKG_VERSION")),
            ),
            (
                Value::from("protocol_version"),
                Value::from(PROTOCOL_VERSION),
            ),
            (Value::from("pid"), Value::from(std::process::id())),
            // Grows as adapters land. The drawer and the connect prompt read it rather than
            // hardcoding a list that would drift from the build.
            (Value::from("adapters"), Value::Array(vec![])),
        ]))
    }
}

impl Handler for Core {
    fn on_request(self: Arc<Self>, method: String, params: Vec<Value>, reply: Reply) {
        let outcome = Args::from_params(&params)
            .and_then(|args| self.dispatch(&method, args))
            .map_err(|error| format!("{method}: {error}"));

        match outcome {
            Ok(value) => reply.ok(value),
            Err(error) => {
                tracing::warn!(%error, "request failed");
                reply.err(error);
            }
        }
    }
}
