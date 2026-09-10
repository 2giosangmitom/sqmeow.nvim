//! The method table, and what each method does.
//!
//! Every handler returns to the editor immediately. Methods that only read session state answer
//! from the dispatch call itself; methods that touch a database answer with an acknowledgement or
//! a call id and report the rest through events. Neovim blocks inside `rpcrequest`, so a handler
//! that waited on a socket would freeze the editor for as long as the query took.

use std::sync::Arc;
use std::time::Instant;

use rmpv::Value;
use sqmeow_adapters::Backend;
use sqmeow_db::{Error as DbError, ResultSet, sql};
use sqmeow_render::Layout;
use sqmeow_rpc::{ApiCall, Handler, Nvim, Reply};
use tokio::sync::Notify;

use crate::args::Args;
use crate::session::{Call, Connection, OptionsPatch, Session};
use crate::value::{map, optional, strings};

/// The protocol revision the editor is checked against.
///
/// Bumped only when a message changes shape in a way an older plugin cannot read. The plugin
/// compares this at handshake and tells the user to update, which beats a decode failure three
/// calls later with no explanation.
pub const PROTOCOL_VERSION: u64 = 1;

/// Everything one editor session talks to.
pub struct Core {
    nvim: Nvim,
    session: Session,
    shutdown: Arc<Notify>,
}

impl Core {
    /// Build a core bound to one editor.
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

    // -- methods that answer straight away -----------------------------------------------------

    /// Report what this binary is and what it can do.
    fn handshake(&self, args: &Args) -> Result<Value, String> {
        let plugin_version = args.opt_string("plugin_version").unwrap_or_default();
        tracing::info!(%plugin_version, "handshake");

        Ok(map(vec![
            ("core_version", Value::from(env!("CARGO_PKG_VERSION"))),
            ("protocol_version", Value::from(PROTOCOL_VERSION)),
            ("pid", Value::from(std::process::id())),
            // Read from the build rather than hardcoded, so the drawer and the connect prompt
            // cannot offer a database this binary was not compiled with.
            ("adapters", strings(sqmeow_adapters::supported())),
        ]))
    }

    /// Mirror the plugin's configuration into the engine.
    fn configure(&self, args: &Args) -> Result<Value, String> {
        let options = self.session.configure(OptionsPatch {
            max_rows: args.opt_usize("max_rows"),
            history_size: args.opt_usize("history_size"),
            page_size: args.opt_usize("page_size"),
            max_column_width: args.opt_usize("max_column_width"),
            null_text: args.opt_string("null_text"),
            ascii: args.opt_bool("ascii"),
        });

        // Echo what was actually applied, since values are clamped rather than rejected.
        Ok(map(vec![
            ("max_rows", Value::from(options.max_rows as u64)),
            ("history_size", Value::from(options.history_size as u64)),
            ("page_size", Value::from(options.grid.page_size as u64)),
            (
                "max_column_width",
                Value::from(options.grid.max_column_width as u64),
            ),
            ("null_text", Value::from(options.grid.null_text)),
        ]))
    }

    /// Stop a running query.
    fn cancel(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.integer("call_id")? as u64;
        Ok(Value::from(self.session.cancel(call_id)))
    }

    // -- methods that keep working after they answer -------------------------------------------

    fn spawn_connect(self: Arc<Self>, args: &Args, reply: Reply) {
        let id = match args.integer("id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        let url = match args.string("url") {
            Ok(url) => url,
            Err(error) => return reply.err(error),
        };
        let name = args
            .opt_string("name")
            .unwrap_or_else(|| format!("connection {id}"));

        reply.ok(Value::from(id));
        tokio::spawn(async move { self.run_connect(id, name, url).await });
    }

    async fn run_connect(self: Arc<Self>, id: i64, name: String, url: String) {
        self.emit_connection(id, "connecting", vec![("name", Value::from(name.clone()))]);

        match Backend::connect(&url).await {
            Ok(backend) => {
                let dialect = backend.dialect().name();
                self.session.insert_connection(Connection {
                    id,
                    name: name.clone(),
                    backend,
                });
                self.emit_connection(
                    id,
                    "connected",
                    vec![
                        ("name", Value::from(name)),
                        ("dialect", Value::from(dialect)),
                    ],
                );
            }
            Err(error) => self.emit_connection(
                id,
                "error",
                vec![
                    ("name", Value::from(name)),
                    ("error", Value::from(error.to_string())),
                ],
            ),
        }
    }

    fn spawn_disconnect(self: Arc<Self>, args: &Args, reply: Reply) {
        let id = match args.integer("id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };

        let connection = self.session.remove_connection(id);
        reply.ok(Value::from(connection.is_some()));

        if let Some(connection) = connection {
            tokio::spawn(async move {
                connection.backend.close().await;
                self.emit_connection(id, "closed", vec![]);
            });
        }
    }

    fn spawn_execute(self: Arc<Self>, args: &Args, reply: Reply) {
        let conn_id = match args.integer("conn_id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        let source = match args.string("sql") {
            Ok(sql) => sql,
            Err(error) => return reply.err(error),
        };
        let buf = match args.integer("buf") {
            Ok(buf) => buf,
            Err(error) => return reply.err(error),
        };

        let Some(connection) = self.session.connection(conn_id) else {
            return reply.err(format!("no connection with id {conn_id}"));
        };

        let statements = sql::split(&source);
        if statements.is_empty() {
            return reply.err("there is no statement to run");
        }

        // The id goes back before the query starts, so the editor can show a running state and
        // offer to cancel it from the moment the call is made.
        let call_id = self.session.next_call_id();
        reply.ok(Value::from(call_id));

        tokio::spawn(async move { self.run_call(call_id, connection, statements, buf).await });
    }

    async fn run_call(
        self: Arc<Self>,
        call_id: u64,
        connection: Arc<Connection>,
        statements: Vec<sql::Statement>,
        buf: i64,
    ) {
        let conn_id = connection.id;
        let options = self.session.options();
        let cancel = self.session.begin_call(call_id);
        let started = Instant::now();

        self.emit_call(
            call_id,
            conn_id,
            "executing",
            vec![("statements", Value::from(statements.len() as u64))],
        );

        let mut last: Option<ResultSet> = None;

        for statement in &statements {
            let outcome = connection
                .backend
                .execute(&statement.sql, options.max_rows, cancel.clone())
                .await;

            match outcome {
                Ok(result) => last = Some(result),
                Err(DbError::Cancelled) => {
                    self.session.end_call(call_id);
                    self.emit_call(call_id, conn_id, "cancelled", elapsed(started));
                    return;
                }
                Err(error) => {
                    self.session.end_call(call_id);
                    // The failing statement's line range travels with the error so the plugin can
                    // put a diagnostic where the SQL is, rather than in a message that scrolls by.
                    let mut payload = elapsed(started);
                    payload.extend(vec![
                        ("error", Value::from(error.to_string())),
                        ("start_line", Value::from(statement.start_line as u64)),
                        ("end_line", Value::from(statement.end_line as u64)),
                    ]);
                    self.emit_call(call_id, conn_id, "error", payload);
                    return;
                }
            }
        }

        // Only the last statement's rows are shown. A script ends with the query worth looking at.
        let result = last.unwrap_or_default();
        let layout = Layout::measure(&result, &options.grid);
        let lines = layout.page(&result, &options.grid, 0);

        let call = Call {
            id: call_id,
            conn_id,
            result,
            layout,
            offset: 0,
        };
        let mut payload = summarize(&call, options.grid.page_size);
        payload.extend(elapsed(started));

        self.paint(buf, lines).await;
        self.session.store_call(call);
        self.session.end_call(call_id);
        self.emit_call(call_id, conn_id, "done", payload);
    }

    fn spawn_page(self: Arc<Self>, args: &Args, reply: Reply) {
        let call_id = match args.integer("call_id") {
            Ok(id) => id as u64,
            Err(error) => return reply.err(error),
        };
        let buf = match args.integer("buf") {
            Ok(buf) => buf,
            Err(error) => return reply.err(error),
        };
        let offset = args.opt_usize("offset");
        let delta = args.opt_integer("delta").unwrap_or(0);

        if self.session.with_call(call_id, |_| ()).is_none() {
            return reply.err(format!("result {call_id} is no longer held"));
        }

        reply.ok(Value::from(call_id));
        tokio::spawn(async move { self.run_page(call_id, buf, offset, delta).await });
    }

    async fn run_page(self: Arc<Self>, call_id: u64, buf: i64, offset: Option<usize>, delta: i64) {
        let options = self.session.options();
        let page_size = options.grid.page_size;

        let current = self
            .session
            .with_call(call_id, |call| call.offset)
            .unwrap_or(0);
        let target = match offset {
            Some(offset) => offset,
            // A delta is counted in pages, so the plugin never does row arithmetic of its own.
            None => current.saturating_add_signed(delta.saturating_mul(page_size as i64) as isize),
        };

        let Some(settled) = self.session.seek_call(call_id, target, page_size) else {
            return;
        };

        let rendered = self.session.with_call(call_id, |call| {
            let mut lines = call.layout.header(&call.result, &options.grid);
            lines.extend(call.layout.rows(&call.result, &options.grid, settled));
            (lines, summarize(call, page_size))
        });

        let Some((lines, payload)) = rendered else {
            return;
        };

        self.paint(buf, lines).await;
        if let Err(error) = self.nvim.emit("page:painted", map(payload)) {
            tracing::warn!(%error, "could not report a painted page");
        }
    }

    // -- talking to the editor -------------------------------------------------------------------

    /// Write lines into a buffer in one round trip.
    ///
    /// The buffer is left unmodifiable, so the option is lifted and restored around the write.
    /// All three calls travel together: a separate message per call would let the user land in a
    /// briefly editable buffer.
    async fn paint(&self, buf: i64, lines: Vec<String>) {
        let calls = vec![
            ApiCall::buf_set_option(buf, "modifiable", Value::Boolean(true)),
            ApiCall::buf_set_lines(buf, 0, -1, lines),
            ApiCall::buf_set_option(buf, "modifiable", Value::Boolean(false)),
        ];

        if let Err(error) = self.nvim.call_atomic(calls).await {
            tracing::warn!(%error, buf, "could not paint a result buffer");
        }
    }

    fn emit_call(&self, call_id: u64, conn_id: i64, state: &str, extra: Vec<(&str, Value)>) {
        let mut pairs = vec![
            ("call_id", Value::from(call_id)),
            ("conn_id", Value::from(conn_id)),
            ("state", Value::from(state)),
        ];
        pairs.extend(extra);

        if let Err(error) = self.nvim.emit("call:state", map(pairs)) {
            tracing::warn!(%error, state, "could not report a call state");
        }
    }

    fn emit_connection(&self, id: i64, state: &str, extra: Vec<(&str, Value)>) {
        let mut pairs = vec![("id", Value::from(id)), ("state", Value::from(state))];
        pairs.extend(extra);

        if let Err(error) = self.nvim.emit("conn:state", map(pairs)) {
            tracing::warn!(%error, state, "could not report a connection state");
        }
    }
}

/// What the editor needs to describe a result: its size, its position, and whether it is whole.
fn summarize(call: &Call, page_size: usize) -> Vec<(&'static str, Value)> {
    let result = &call.result;
    vec![
        ("call_id", Value::from(call.id)),
        ("conn_id", Value::from(call.conn_id)),
        ("rows", Value::from(result.row_count() as u64)),
        ("columns", Value::from(result.columns().len() as u64)),
        ("truncated", Value::from(result.is_truncated())),
        ("affected", optional(result.affected().map(Value::from))),
        ("offset", Value::from(call.offset as u64)),
        ("page", Value::from(call.page_number(page_size) as u64)),
        ("pages", Value::from(result.page_count(page_size) as u64)),
        ("page_size", Value::from(page_size as u64)),
    ]
}

fn elapsed(started: Instant) -> Vec<(&'static str, Value)> {
    vec![(
        "elapsed_ms",
        Value::from(started.elapsed().as_millis() as u64),
    )]
}

impl Handler for Core {
    fn on_request(self: Arc<Self>, method: String, params: Vec<Value>, reply: Reply) {
        let args = match Args::from_params(&params) {
            Ok(args) => args,
            Err(error) => return reply.err(format!("{method}: {error}")),
        };

        // Anything that only reads session state answers here. Anything that touches a database
        // hands `reply` to a task, which answers as soon as it has an id to give back.
        let immediate = match method.as_str() {
            "handshake" => self.handshake(&args),
            "ping" => Ok(Value::from("pong")),
            "configure" => self.configure(&args),
            "cancel" => self.cancel(&args),
            "connections" => Ok(Value::Array(self.session.describe_connections())),
            "shutdown" => {
                self.shutdown.notify_waiters();
                Ok(Value::Nil)
            }

            "connect" => return self.spawn_connect(&args, reply),
            "disconnect" => return self.spawn_disconnect(&args, reply),
            "execute" => return self.spawn_execute(&args, reply),
            "page" => return self.spawn_page(&args, reply),

            other => Err(format!("unknown method `{other}`")),
        };

        match immediate {
            Ok(value) => reply.ok(value),
            Err(error) => {
                let error = format!("{method}: {error}");
                tracing::warn!(%error, "request failed");
                reply.err(error);
            }
        }
    }
}
