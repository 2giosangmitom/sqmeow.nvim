//! Routes RPC methods to their handlers.
//!
//! Requests carry one keyword-argument map decoded by [`Args`]. Short operations
//! return a value directly. Long operations validate/register their work, return
//! an acknowledgement or id, then run in a spawned task and emit completion
//! events through [`Nvim`]. The reply is queued before the task starts so Lua can
//! record the accepted id before handling its events.
//!
//! [`Session`] owns connection/result membership; the handler modules implement
//! individual operations. Protocol failures become RPC errors, while failures
//! after acceptance are reported by the operation's event stream.
//!
//! `result_view` accepts an originating `call_id`, structured filters/sort,
//! free-form where/order fragments and the base query. Filtering and sorting use
//! retained rows; only an explicit refresh reruns the query. Its reply names
//! `route` and `call_id`: memory emits
//! `call:view` for the same id; query emits `call:state` for a new id.
//! `rows` returns original retained-row `indices` for either result.
//! `result_capabilities` reads the current ability to re-query or filter held
//! rows; summaries carry a snapshot of the same map.

pub mod archive;
pub mod args;
pub mod calls;
pub mod connections;
pub mod edits;
pub mod exports;
pub mod nvim;
pub mod params;
pub mod payload;
pub mod project;
pub mod relationships;
pub mod schema;
pub mod session;
pub mod summary;
pub mod template;
pub mod tunnel;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use crate::server::nvim::Nvim;
use rmpv::Value;
use sqmeow_rpc::handler::{Handler, Reply};
use tokio::sync::Notify;

use crate::server::args::Args;
use crate::server::payload::{map, strings};
use crate::server::session::{OptionsPatch, Session};

/// Work a method leaves running after it has answered.
type Work = Pin<Box<dyn Future<Output = ()> + Send>>;

/// A method that answers at once and keeps working: its answer and the work, or why it refused.
type Started = Result<(Value, Work), String>;

/// RPC endpoint and database session for one editor process.
///
/// Shared by request tasks through `Arc`. It does not own editor buffers; all UI
/// updates are notifications sent to `nvim`. A new engine creates a fresh session
/// and fresh call ids, so ids from an earlier process must not be reused.
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

    /// Answer a short request without scheduling a separate completion task.
    ///
    /// Includes local parsing and result inspection as well as session access.
    /// Unknown method names return an RPC error rather than being ignored.
    fn answer(&self, method: &str, args: &Args) -> Result<Value, String> {
        match method {
            "handshake" => self.handshake(args),
            "ping" => Ok(Value::from("pong")),
            "configure" => self.configure(args),
            "project_connections" => project::parse(&args.string("contents")?),
            "cancel" => self.cancel(args),
            "row" => self.row(args),
            "rows" => self.rows(args),
            "result_capabilities" => self.result_capabilities(args),
            "result_view_route" => self.result_view_route(args),
            "condition" => self.condition(args),
            "inspect" => self.inspect(args),
            "query_parameters" => self.query_parameters(args),
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
            "result_view" => match args.opt_string("mode").as_deref() {
                None => core.result_view(&args),
                Some("memory") => core.view(&args),
                Some("query") => core.execute(&args),
                Some(other) => Err(format!("result_view: unknown mode `{other}`")),
            },
            "apply" => core.apply(&args),
            "introspect" => core.introspect(&args),
            "structure" => core.structure(&args),
            "relationships" => core.relationships(&args),
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
