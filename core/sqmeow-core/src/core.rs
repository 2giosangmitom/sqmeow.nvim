//! Routes RPC methods to their handlers.

mod calls;
mod connections;
mod edits;
mod exports;
mod params;
mod schema;
mod summary;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use rmpv::Value;
use sqmeow_rpc::{Handler, Nvim, Reply};
use tokio::sync::Notify;

use crate::args::Args;
use crate::session::{OptionsPatch, Session};
use crate::value::{map, strings};

/// Work a method leaves running after it has answered.
type Work = Pin<Box<dyn Future<Output = ()> + Send>>;

/// A method that answers at once and keeps working: its answer and the work, or why it refused.
type Started = Result<(Value, Work), String>;

/// Everything one editor session talks to.
pub struct Core {
    nvim: Nvim,
    session: Session,
    shutdown: Arc<Notify>,
}

impl Core {
    pub fn new(nvim: Nvim) -> Self {
        Self {
            nvim,
            session: Session::default(),
            shutdown: Arc::new(Notify::new()),
        }
    }

    /// Resolves once a `shutdown` call has been handled.
    pub fn shutdown_signal(&self) -> Arc<Notify> {
        Arc::clone(&self.shutdown)
    }

    /// Report what this binary is and what it can do.
    fn handshake(&self, args: &Args) -> Result<Value, String> {
        let plugin_version = args.opt_string("plugin_version").unwrap_or_default();
        tracing::info!(%plugin_version, "handshake");

        Ok(map(vec![
            ("core_version", Value::from(env!("CARGO_PKG_VERSION"))),
            ("pid", Value::from(std::process::id())),
            ("adapters", strings(sqmeow_adapters::supported())),
        ]))
    }

    /// Mirror the plugin's configuration into the engine.
    fn configure(&self, args: &Args) -> Result<Value, String> {
        let options = self.session.configure(OptionsPatch {
            max_rows: args.opt_usize("max_rows"),
            history_size: args.opt_usize("history_size"),
            timeout_ms: args.opt_usize("timeout_ms").map(|ms| ms as u64),
        });

        // Echo what was applied, since values are clamped rather than rejected.
        Ok(map(vec![
            ("max_rows", Value::from(options.max_rows as u64)),
            ("history_size", Value::from(options.history_size as u64)),
            ("timeout_ms", Value::from(options.timeout_ms)),
        ]))
    }

    /// Answer a method that only reads or changes session state.
    fn answer(&self, method: &str, args: &Args) -> Result<Value, String> {
        match method {
            "handshake" => self.handshake(args),
            "ping" => Ok(Value::from("pong")),
            "configure" => self.configure(args),
            "cancel" => self.cancel(args),
            "row" => self.row(args),
            "rows" => self.rows(args),
            "condition" => self.condition(args),
            "inspect" => self.inspect(args),
            "plan" => self.plan(args),
            "export_preview" => self.export_preview(args),
            "connections" => Ok(Value::Array(self.session.describe_connections())),
            "shutdown" => {
                self.shutdown.notify_waiters();
                Ok(Value::Nil)
            }
            other => Err(format!("unknown method `{other}`")),
        }
    }

    /// Send an event to the editor.
    fn emit(&self, event: &str, payload: Value) {
        if let Err(error) = self.nvim.emit(event, payload) {
            tracing::warn!(%error, event, "could not send an event");
        }
    }
}

impl Handler for Core {
    fn on_request(self: Arc<Self>, method: String, params: Vec<Value>, reply: Reply) {
        let args = match Args::from_params(&params) {
            Ok(args) => args,
            Err(error) => return reply.err(format!("{method}: {error}")),
        };

        let core = Arc::clone(&self);
        let started = match method.as_str() {
            "connect" => core.connect(&args),
            "disconnect" => core.disconnect(&args),
            "execute" => core.execute(&args),
            "restore" => core.restore(&args),
            "view" => core.view(&args),
            "apply" => core.apply(&args),
            "introspect" => core.introspect(&args),
            "structure" => core.structure(&args),
            "export" => core.export(&args),
            _ => {
                return match self.answer(&method, &args) {
                    Ok(value) => reply.ok(value),
                    Err(error) => {
                        let error = format!("{method}: {error}");
                        tracing::warn!(%error, "request failed");
                        reply.err(error);
                    }
                };
            }
        };

        match started {
            // The answer goes out before the work starts, so its events follow it.
            Ok((answer, work)) => {
                reply.ok(answer);
                tokio::spawn(work);
            }
            Err(error) => reply.err(error),
        }
    }
}
