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
use sqmeow_db::{
    CatalogEntry, Cell, ColumnNode, Error as DbError, RelationNode, ResultSet, SchemaNode, sql,
};
use sqmeow_render::export::{Format, Rows};
use sqmeow_render::{Layout, export};
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

        // The expanded URL holds the password and never leaves this function: it is not logged,
        // not echoed back to the editor, and not put in an error message.
        let url = match crate::template::expand(&url).await {
            Ok(url) => url,
            Err(error) => {
                return self.emit_connection(
                    id,
                    "error",
                    vec![("name", Value::from(name)), ("error", Value::from(error))],
                );
            }
        };

        match Backend::connect(&url).await {
            Ok(backend) => {
                let dialect = backend.dialect().name();
                self.session
                    .insert_connection(Connection::new(id, name.clone(), backend));
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

        let mut statements = sql::split(&source);
        if statements.is_empty() {
            return reply.err("there is no statement to run");
        }

        // A line means "run only what the cursor is in". Choosing here rather than in the plugin
        // keeps one implementation of what a statement is, the same one that split the buffer.
        if let Some(line) = args.opt_usize("line") {
            match sql::statement_at(&statements, line) {
                Some(chosen) => statements = vec![chosen.clone()],
                None => return reply.err("there is no statement to run"),
            }
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

        // The line range travels with the "executing" event so the editor can show which
        // statement is running, which matters most when only one of several was chosen.
        let span = statements.first().zip(statements.last());
        self.emit_call(
            call_id,
            conn_id,
            "executing",
            vec![
                ("statements", Value::from(statements.len() as u64)),
                (
                    "start_line",
                    optional(span.map(|(first, _)| Value::from(first.start_line as u64))),
                ),
                (
                    "end_line",
                    optional(span.map(|(_, last)| Value::from(last.end_line as u64))),
                ),
            ],
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
        let header = layout.header(&result, &options.grid);
        let rows = layout.rows(&result, &options.grid, 0);

        let call = Call {
            id: call_id,
            conn_id,
            result,
            layout,
            offset: 0,
        };
        let mut payload = summarize(&call, options.grid.page_size);
        payload.extend(elapsed(started));

        self.paint(buf, header, rows).await;
        self.session.store_call(call);
        self.session.end_call(call_id);
        self.emit_call(call_id, conn_id, "done", payload);
    }

    fn spawn_introspect(self: Arc<Self>, args: &Args, reply: Reply) {
        let conn_id = match args.integer("conn_id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        // An empty path means the connection itself, whose children are its schemas.
        let path = args.opt_strings("path").unwrap_or_default();
        if path.len() > 2 {
            return reply.err("a schema path is at most [schema, relation]");
        }

        let Some(connection) = self.session.connection(conn_id) else {
            return reply.err(format!("no connection with id {conn_id}"));
        };

        reply.ok(Value::Boolean(true));
        tokio::spawn(async move { self.run_introspect(connection, path).await });
    }

    /// Read one level of the schema tree.
    ///
    /// One level at a time, on demand. Reading a whole schema up front would stall the drawer on
    /// a database with ten thousand tables, to fetch information almost none of which is about to
    /// be looked at.
    async fn run_introspect(self: Arc<Self>, connection: Arc<Connection>, path: Vec<String>) {
        let nodes = match path.as_slice() {
            [] => connection.backend.schemas().await.map(schema_nodes),
            [schema] => connection
                .backend
                .relations(schema)
                .await
                .map(relation_nodes),
            [schema, relation] => connection
                .backend
                .columns(schema, relation)
                .await
                .map(column_nodes),
            _ => return,
        };

        let mut payload = vec![
            ("conn_id", Value::from(connection.id)),
            ("path", strings(path)),
        ];

        match nodes {
            Ok(nodes) => payload.push(("nodes", Value::Array(nodes))),
            Err(error) => {
                payload.push(("nodes", Value::Array(vec![])));
                payload.push(("error", Value::from(error.to_string())));
            }
        }

        if let Err(error) = self.nvim.emit("schema:nodes", map(payload)) {
            tracing::warn!(%error, "could not report schema nodes");
        }
    }

    fn spawn_catalog(self: Arc<Self>, args: &Args, reply: Reply) {
        let conn_id = match args.integer("conn_id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        let refresh = args.opt_bool("refresh").unwrap_or(false);

        let Some(connection) = self.session.connection(conn_id) else {
            return reply.err(format!("no connection with id {conn_id}"));
        };
        if refresh {
            connection.forget_catalog();
        }

        reply.ok(Value::Boolean(true));
        tokio::spawn(async move { self.run_catalog(connection).await });
    }

    /// Read every relation in every schema.
    ///
    /// This is what the relation picker searches, so it is one flat list rather than a tree, and
    /// it is cached on the connection: the cost is one query per schema, which is worth paying
    /// once and not again on every keystroke.
    async fn run_catalog(self: Arc<Self>, connection: Arc<Connection>) {
        let entries = match connection.cached_catalog() {
            Some(cached) => cached,
            None => match self.read_catalog(&connection).await {
                Ok(entries) => connection.store_catalog(entries),
                Err(error) => {
                    return self.emit_catalog(connection.id, Err(error.to_string()));
                }
            },
        };

        self.emit_catalog(connection.id, Ok(&entries));
    }

    async fn read_catalog(&self, connection: &Connection) -> sqmeow_db::Result<Vec<CatalogEntry>> {
        let mut entries = Vec::new();

        for schema in connection.backend.schemas().await? {
            // One unreadable schema, which permissions alone can cause, must not empty the whole
            // catalog: skip it and keep the ones that did answer.
            let Ok(relations) = connection.backend.relations(&schema.name).await else {
                continue;
            };
            entries.extend(relations.into_iter().map(|relation| CatalogEntry {
                schema: schema.name.clone(),
                name: relation.name,
                kind: relation.kind,
            }));
        }

        Ok(entries)
    }

    fn emit_catalog(&self, conn_id: i64, entries: Result<&[CatalogEntry], String>) {
        let mut payload = vec![("conn_id", Value::from(conn_id))];

        match entries {
            Ok(entries) => payload.push(("relations", Value::Array(catalog_entries(entries)))),
            Err(error) => {
                payload.push(("relations", Value::Array(vec![])));
                payload.push(("error", Value::from(error)));
            }
        }

        if let Err(error) = self.nvim.emit("schema:catalog", map(payload)) {
            tracing::warn!(%error, "could not report the catalog");
        }
    }

    /// One row of a stored result, for the detail view.
    ///
    /// Answered from the dispatch call rather than a task: a row is bounded by the column count,
    /// so formatting it is not the kind of work the editor should wait on a task for.
    fn row(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.integer("call_id")? as u64;
        let index = args.opt_usize("row").unwrap_or(0);
        let null_text = self.session.options().grid.null_text;

        let row = self
            .session
            .with_call(call_id, |call| {
                if index >= call.result.row_count() {
                    return None;
                }

                Some(Value::Array(
                    call.result
                        .columns()
                        .iter()
                        .enumerate()
                        .map(|(column, meta)| {
                            let cell = call.result.cell(index, column).unwrap_or(&Cell::Null);
                            map(vec![
                                ("name", Value::from(meta.name.clone())),
                                ("type_name", Value::from(cell.type_name())),
                                ("declared_type", Value::from(meta.type_name.clone())),
                                ("is_null", Value::from(cell.is_null())),
                                // The unescaped text: a detail view has room for the line breaks
                                // a grid cell has to flatten away.
                                ("value", Value::from(cell.text(&null_text).into_owned())),
                            ])
                        })
                        .collect(),
                ))
            })
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;

        row.ok_or_else(|| format!("row {index} is past the end of the result"))
    }

    fn spawn_export(self: Arc<Self>, args: &Args, reply: Reply) {
        let call_id = match args.integer("call_id") {
            Ok(id) => id as u64,
            Err(error) => return reply.err(error),
        };
        let format = match args.opt_string("format").as_deref().map(Format::parse) {
            Some(Some(format)) => format,
            Some(None) => return reply.err("format must be `csv` or `json`"),
            None => Format::Csv,
        };

        let scope = args.opt_string("scope").unwrap_or_else(|| "all".to_owned());
        let row = args.opt_usize("row");
        let column = args.opt_usize("column");
        let register = args.opt_string("register");
        let path = args.opt_string("path");

        if self.session.with_call(call_id, |_| ()).is_none() {
            return reply.err(format!("result {call_id} is no longer held"));
        }

        reply.ok(Value::from(call_id));
        tokio::spawn(async move {
            self.run_export(call_id, format, scope, row, column, register, path)
                .await;
        });
    }

    /// Render part of a result and put it somewhere the user can use it.
    ///
    /// The text never travels back as a reply. A hundred thousand rows of CSV would be a very
    /// large message for the editor to decode only to hand straight to `setreg`, so the engine
    /// writes it into the register, or into the file, itself.
    #[expect(clippy::too_many_arguments, reason = "one argument per protocol field")]
    async fn run_export(
        self: Arc<Self>,
        call_id: u64,
        format: Format,
        scope: String,
        row: Option<usize>,
        column: Option<usize>,
        register: Option<String>,
        path: Option<String>,
    ) {
        let options = self.session.options();
        let page_size = options.grid.page_size;

        let rendered = self
            .session
            .with_call(call_id, |call| match scope.as_str() {
                "cell" => {
                    let cell = call
                        .result
                        .cell(row.unwrap_or(0), column.unwrap_or(0))
                        .unwrap_or(&Cell::Null);
                    Ok(cell.text(&options.grid.null_text).into_owned())
                }
                "row" => Ok(export::write(
                    &call.result,
                    format,
                    Rows::one(row.unwrap_or(0)),
                )),
                "page" => Ok(export::write(
                    &call.result,
                    format,
                    Rows {
                        start: call.offset,
                        end: call.offset + page_size,
                    },
                )),
                "all" => Ok(export::write(&call.result, format, Rows::all(&call.result))),
                other => Err(format!(
                    "unknown export scope `{other}`; expected cell, row, page or all"
                )),
            });

        let text = match rendered {
            Some(Ok(text)) => text,
            Some(Err(error)) => return self.emit_export(call_id, Err(error)),
            None => return self.emit_export(call_id, Err("the result is no longer held".into())),
        };

        let bytes = text.len();

        match path {
            Some(path) => match tokio::fs::write(&path, text).await {
                Ok(()) => self.emit_export(
                    call_id,
                    Ok(vec![
                        ("target", Value::from("file")),
                        ("path", Value::from(path)),
                        ("bytes", Value::from(bytes as u64)),
                    ]),
                ),
                Err(error) => {
                    self.emit_export(call_id, Err(format!("could not write {path}: {error}")));
                }
            },
            None => {
                let register = register.unwrap_or_else(|| "\"".to_owned());
                let call = self.nvim.client().request(
                    "nvim_call_function",
                    vec![
                        Value::from("setreg"),
                        Value::Array(vec![Value::from(register.clone()), Value::from(text)]),
                    ],
                );

                match call.await {
                    Ok(_) => self.emit_export(
                        call_id,
                        Ok(vec![
                            ("target", Value::from("register")),
                            ("register", Value::from(register)),
                            ("bytes", Value::from(bytes as u64)),
                        ]),
                    ),
                    Err(error) => self.emit_export(call_id, Err(error.to_string())),
                }
            }
        }
    }

    fn emit_export(&self, call_id: u64, outcome: Result<Vec<(&str, Value)>, String>) {
        let mut payload = vec![("call_id", Value::from(call_id))];
        match outcome {
            Ok(fields) => payload.extend(fields),
            Err(error) => payload.push(("error", Value::from(error))),
        }

        if let Err(error) = self.nvim.emit("export:done", map(payload)) {
            tracing::warn!(%error, "could not report an export");
        }
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
            (
                call.layout.header(&call.result, &options.grid),
                call.layout.rows(&call.result, &options.grid, settled),
                summarize(call, page_size),
            )
        });

        let Some((header, rows, payload)) = rendered else {
            return;
        };

        self.paint(buf, header, rows).await;
        if let Err(error) = self.nvim.emit("page:painted", map(payload)) {
            tracing::warn!(%error, "could not report a painted page");
        }
    }

    // -- talking to the editor -------------------------------------------------------------------

    /// Write a page into the editor in one round trip.
    ///
    /// The column names, the rule under them, and the rows are one block in one buffer. The
    /// editor knows how many lines come before the first row, from `header_lines` in the summary,
    /// which is all it needs to turn a cursor position into a row of the result.
    ///
    /// The buffer is left unmodifiable, so the option is lifted and restored around the write.
    /// Every call travels together, because a separate message per call would leave the user with
    /// a briefly editable buffer to fall into.
    async fn paint(&self, buf: i64, header: Vec<String>, rows: Vec<String>) {
        let mut lines = header;
        lines.extend(rows);

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

/// The drawer draws every level the same way, so every level answers with the same fields:
/// a name, what kind of thing it is, and whether it has children worth expanding.
fn schema_nodes(schemas: Vec<SchemaNode>) -> Vec<Value> {
    schemas
        .into_iter()
        .map(|schema| {
            map(vec![
                ("name", Value::from(schema.name)),
                ("kind", Value::from("schema")),
                ("expandable", Value::from(true)),
                ("is_default", Value::from(schema.is_default)),
            ])
        })
        .collect()
}

fn relation_nodes(relations: Vec<RelationNode>) -> Vec<Value> {
    relations
        .into_iter()
        .map(|relation| {
            map(vec![
                ("name", Value::from(relation.name)),
                ("kind", Value::from(relation.kind.name())),
                ("expandable", Value::from(true)),
            ])
        })
        .collect()
}

fn column_nodes(columns: Vec<ColumnNode>) -> Vec<Value> {
    columns
        .into_iter()
        .map(|column| {
            map(vec![
                ("name", Value::from(column.name)),
                ("kind", Value::from("column")),
                // A column is a leaf; the tree stops here.
                ("expandable", Value::from(false)),
                ("type_name", Value::from(column.type_name)),
                ("nullable", Value::from(column.nullable)),
                ("primary_key", Value::from(column.primary_key)),
            ])
        })
        .collect()
}

/// The flat catalog the relation picker searches, one entry per relation.
fn catalog_entries(entries: &[CatalogEntry]) -> Vec<Value> {
    entries
        .iter()
        .map(|entry| {
            map(vec![
                ("schema", Value::from(entry.schema.clone())),
                ("name", Value::from(entry.name.clone())),
                ("kind", Value::from(entry.kind.name())),
            ])
        })
        .collect()
}

/// What the editor needs to describe a result: its size, its position, and whether it is whole.
fn summarize(call: &Call, page_size: usize) -> Vec<(&'static str, Value)> {
    let result = &call.result;
    let spans = call.layout.spans();

    let columns: Vec<Value> = result
        .columns()
        .iter()
        .zip(spans)
        .map(|(column, (start, width))| {
            map(vec![
                ("name", Value::from(column.name.clone())),
                ("type_name", Value::from(column.type_name.clone())),
                // Where the column sits, in display columns, so the editor can tell which cell a
                // cursor is on without knowing anything about how the grid was laid out.
                ("start", Value::from(start as u64)),
                ("width", Value::from(width as u64)),
            ])
        })
        .collect();

    vec![
        ("column_spans", Value::Array(columns)),
        // What the editor has to skip to reach the first row of data.
        ("header_lines", Value::from(Layout::HEADER_LINES as u64)),
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
            "row" => self.row(&args),
            "connections" => Ok(Value::Array(self.session.describe_connections())),
            "shutdown" => {
                self.shutdown.notify_waiters();
                Ok(Value::Nil)
            }

            "connect" => return self.spawn_connect(&args, reply),
            "disconnect" => return self.spawn_disconnect(&args, reply),
            "execute" => return self.spawn_execute(&args, reply),
            "page" => return self.spawn_page(&args, reply),
            "introspect" => return self.spawn_introspect(&args, reply),
            "catalog" => return self.spawn_catalog(&args, reply),
            "export" => return self.spawn_export(&args, reply),

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
