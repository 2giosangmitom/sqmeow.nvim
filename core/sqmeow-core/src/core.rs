//! The method table, and what each method does.
//!
//! Every handler returns to the editor immediately. Methods that only read session state answer
//! from the dispatch call itself; methods that touch a database answer with an acknowledgement or
//! a call id and report the rest through events. Neovim blocks inside `rpcrequest`, so a handler
//! that waited on a socket would freeze the editor for as long as the query took.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use rmpv::Value;
use sqmeow_adapters::Backend;
use sqmeow_db::export::{self, Format, Rows};
use sqmeow_db::view::{self, Filter, Op, Sort};
use sqmeow_db::{
    CatalogEntry, Cell, Changes, ColumnNode, Dialect, Error as DbError, KeyType, RelationKind,
    RelationNode, ResultSet, RoutineKind, RoutineNode, SchemaNode, sql,
};
use sqmeow_rpc::{Handler, Nvim, Reply};
use tokio::sync::Notify;

use crate::archive;
use crate::args::Args;
use crate::session::{Call, Connection, OptionsPatch, Session};
use crate::value::{map, optional, strings};

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
            ("pid", Value::from(std::process::id())),
            // Read from the build rather than hardcoded, so the drawer and the connect prompt
            // cannot offer a database this binary was not compiled with.
            ("adapters", strings(sqmeow_adapters::supported())),
        ]))
    }

    /// Mirror the plugin's configuration into the engine.
    ///
    /// Only two settings are left here. Everything else that used to travel — the page size, the
    /// column width cap, what `NULL` reads as, the grid's characters, the column icons — described
    /// how a result should look, and the engine no longer draws one.
    fn configure(&self, args: &Args) -> Result<Value, String> {
        let options = self.session.configure(OptionsPatch {
            max_rows: args.opt_usize("max_rows"),
            history_size: args.opt_usize("history_size"),
        });

        // Echo what was actually applied, since values are clamped rather than rejected.
        Ok(map(vec![
            ("max_rows", Value::from(options.max_rows as u64)),
            ("history_size", Value::from(options.history_size as u64)),
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
        // One database of a cluster the URL reaches as a whole, opened from the drawer.
        let database = args.opt_string("database");

        reply.ok(Value::from(id));
        tokio::spawn(async move { self.run_connect(id, name, url, database).await });
    }

    async fn run_connect(
        self: Arc<Self>,
        id: i64,
        name: String,
        url: String,
        database: Option<String>,
    ) {
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

        match Backend::connect_to(&url, database.as_deref()).await {
            Ok(backend) => {
                let dialect = backend.dialect().name();
                let mut payload = vec![
                    ("name", Value::from(name.clone())),
                    ("dialect", Value::from(dialect)),
                ];
                // Which database a MongoDB connection starts on, for the winbar: a URL naming none
                // runs on `test`, and nothing else on screen would say so.
                if let Some(database) = backend.database() {
                    payload.push(("current_database", Value::from(database)));
                }
                self.session
                    .insert_connection(Connection::new(id, name, backend));
                self.emit_connection(id, "connected", payload);
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
        let Some(connection) = self.session.connection(conn_id) else {
            return reply.err(format!("no connection with id {conn_id}"));
        };

        // A Redis command ends with its line, a MongoDB command with its document, and a SQL
        // statement with a semicolon.
        let mut statements = match connection.backend.dialect() {
            Dialect::Redis => sql::split_lines(&source),
            Dialect::MongoDb => sql::split_documents(&source),
            dialect => sql::split(&source, dialect),
        };
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

        // Where to save the rows once the query is done, when the plugin wants them for its log.
        let archive = args.opt_string("archive").map(PathBuf::from);

        // The id goes back before the query starts, so the editor can show a running state and
        // offer to cancel it from the moment the call is made.
        let call_id = self.session.next_call_id();
        reply.ok(Value::from(call_id));

        tokio::spawn(async move {
            self.run_call(call_id, connection, statements, archive)
                .await
        });
    }

    async fn run_call(
        self: Arc<Self>,
        call_id: u64,
        connection: Arc<Connection>,
        statements: Vec<sql::Statement>,
        archive: Option<PathBuf>,
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
        let mut result = last.unwrap_or_default();
        // The whole call's time rather than the last statement's, since that is what a saved copy
        // should say the query took.
        result.set_elapsed(started.elapsed());

        let call = Call {
            id: call_id,
            conn_id,
            result,
            view: Default::default(),
        };
        let mut payload = summarize(&call);
        payload.extend(elapsed(started));
        // After the statements rather than before, so a `use` among them is what the winbar shows.
        if let Some(database) = connection.backend.database() {
            payload.push(("current_database", Value::from(database)));
        }

        let call = self.session.store_call(call);
        self.session.end_call(call_id);
        self.emit_call(call_id, conn_id, "done", payload);

        if let Some(path) = archive {
            save(path, call);
        }
    }

    /// Read a result saved by an earlier `execute` back into the session.
    ///
    /// Answers with a call id straight away and reads the file on a blocking thread, because a
    /// large result takes a while to decode and Neovim is waiting inside `rpcrequest`. What was
    /// read arrives as `call:state`, exactly as a query's result does.
    fn spawn_restore(self: Arc<Self>, args: &Args, reply: Reply) {
        let path = match args.string("path") {
            Ok(path) => PathBuf::from(path),
            Err(error) => return reply.err(error),
        };
        // The connection it ran on, when that is open. Nothing is asked of it: the id only says
        // which database the rows came from.
        let conn_id = args.opt_integer("conn_id").unwrap_or(0);

        let call_id = self.session.next_call_id();
        reply.ok(Value::from(call_id));

        tokio::spawn(async move {
            let read = tokio::task::spawn_blocking(move || archive::read(&path)).await;
            let result = match read {
                Ok(Ok(result)) => result,
                Ok(Err(error)) => {
                    return self.emit_call(
                        call_id,
                        conn_id,
                        "error",
                        vec![("error", Value::from(error))],
                    );
                }
                Err(error) => {
                    let error = format!("the saved result could not be read: {error}");
                    return self.emit_call(
                        call_id,
                        conn_id,
                        "error",
                        vec![("error", Value::from(error))],
                    );
                }
            };

            let elapsed_ms = result.elapsed().as_millis() as u64;
            let call = Call {
                id: call_id,
                conn_id,
                result,
                view: Default::default(),
            };
            let mut payload = summarize(&call);
            payload.push(("elapsed_ms", Value::from(elapsed_ms)));

            self.session.store_call(call);
            self.emit_call(call_id, conn_id, "done", payload);
        });
    }

    fn spawn_introspect(self: Arc<Self>, args: &Args, reply: Reply) {
        let conn_id = match args.integer("conn_id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        // An empty path means the connection itself, whose children are its schemas.
        let path = args.opt_strings("path").unwrap_or_default();
        if path.len() > 3 {
            return reply.err("a schema path is at most [schema, group, relation]");
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
            // A cluster's databases are each opened as a connection of their own, so the tree
            // below one of them belongs to that connection rather than continuing this path.
            [] => match connection.backend.databases().await {
                Some(databases) => databases.map(database_nodes),
                None => connection.backend.schemas().await.map(schema_nodes),
            },
            [schema] => group_nodes(&connection, schema).await,
            [schema, group] => members(&connection, schema, group).await,
            // The group a relation sits under says nothing about its columns, so it is skipped.
            [schema, _group, relation] => connection
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
                                // a grid cell has to flatten away. Empty for `NULL`, which the
                                // editor recognises from `is_null` and shows in its own words.
                                ("value", Value::from(cell.text("").into_owned())),
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
        let format = match format(args) {
            Ok(format) => format,
            Err(error) => return reply.err(error),
        };

        // The selected rows, which only the editor knows, so it sends the range rather than the
        // engine guessing. Without an `offset` the whole result is written.
        let rows = match args.opt_usize("offset") {
            Some(start) => Rows {
                start,
                end: args
                    .opt_usize("limit")
                    .map_or(usize::MAX, |limit| start.saturating_add(limit)),
            },
            None => Rows::all(),
        };
        let headers = args.opt_bool("headers").unwrap_or(true);
        // Without a path the text comes back in `export:done`, for the clipboard.
        let path = args.opt_string("path");
        let columns = indices(args.get("columns"));

        if self.session.with_call(call_id, |_| ()).is_none() {
            return reply.err(format!("result {call_id} is no longer held"));
        }

        reply.ok(Value::from(call_id));
        tokio::spawn(async move {
            self.run_export(call_id, format, rows, columns, headers, path)
                .await;
        });
    }

    /// The start of an export, as the text it would write, for the export dialog to show.
    ///
    /// Answered from the dispatch call rather than a task: it is capped at [`PREVIEW_ROWS`] rows, so
    /// it is a page's worth of work, and the dialog redraws it as each answer changes.
    fn export_preview(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.integer("call_id")? as u64;
        let format = format(args)?;
        let start = args.opt_usize("offset").unwrap_or(0);
        let limit = args
            .opt_usize("limit")
            .unwrap_or(usize::MAX)
            .min(PREVIEW_ROWS);
        let headers = args.opt_bool("headers").unwrap_or(true);
        let columns = indices(args.get("columns"));

        self.session
            .with_call(call_id, |call| {
                let view = call.view.lock().expect("view poisoned").clone();
                let rows = Rows {
                    start,
                    end: start.saturating_add(limit),
                }
                .resolve(&call.result, view.as_deref().map(Vec::as_slice));
                Value::from(export::write(
                    &call.result,
                    format,
                    &rows,
                    columns.as_deref(),
                    headers,
                ))
            })
            .ok_or_else(|| format!("result {call_id} is no longer held"))
    }

    /// Render part of a result and write it to a file.
    ///
    /// The text never travels back as a reply. A hundred thousand rows of CSV would be a very
    /// large message for the editor to decode only to write straight back out, so the engine
    /// writes the file itself.
    async fn run_export(
        self: Arc<Self>,
        call_id: u64,
        format: Format,
        rows: Rows,
        columns: Option<Vec<usize>>,
        headers: bool,
        path: Option<String>,
    ) {
        let Some((text, count)) = self.session.with_call(call_id, |call| {
            let view = call.view.lock().expect("view poisoned").clone();
            let rows = rows.resolve(&call.result, view.as_deref().map(Vec::as_slice));
            let text = export::write(&call.result, format, &rows, columns.as_deref(), headers);
            (text, rows.len())
        }) else {
            return self.emit_export(call_id, Err("the result is no longer held".into()));
        };

        let bytes = text.len();
        let Some(path) = path else {
            return self.emit_export(
                call_id,
                Ok(vec![
                    ("text", Value::from(text)),
                    ("rows", Value::from(count as u64)),
                    ("bytes", Value::from(bytes as u64)),
                ]),
            );
        };
        match tokio::fs::write(&path, text).await {
            Ok(()) => self.emit_export(
                call_id,
                Ok(vec![
                    ("path", Value::from(path)),
                    ("rows", Value::from(count as u64)),
                    ("bytes", Value::from(bytes as u64)),
                ]),
            ),
            Err(error) => {
                self.emit_export(call_id, Err(format!("could not write {path}: {error}")));
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

    /// Narrow and order the rows of a stored result, for the grid to page through.
    ///
    /// Answers straight away and builds the view on a blocking thread: sorting a hundred thousand
    /// rows is quick, but not quick enough to hold the editor inside `rpcrequest` for. The row count
    /// arrives as `call:view`. Empty filters, sort and scope put every row back in its first order.
    fn spawn_view(self: Arc<Self>, args: &Args, reply: Reply) {
        let call_id = match args.integer("call_id") {
            Ok(id) => id as u64,
            Err(error) => return reply.err(error),
        };
        let filters = match filters(args.get("filters")) {
            Ok(filters) => filters,
            Err(error) => return reply.err(error),
        };
        let sort: Vec<Sort> = items(args.get("sort"))
            .into_iter()
            .filter_map(|item| {
                Some(Sort {
                    column: usize::try_from(field(item, "column")?.as_u64()?).ok()?,
                    descending: field(item, "descending")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                })
            })
            .collect();
        let scope = indices(args.get("rows"));
        if self.session.with_call(call_id, |_| ()).is_none() {
            return reply.err(format!("result {call_id} is no longer held"));
        }

        reply.ok(Value::from(call_id));
        tokio::spawn(async move {
            let core = Arc::clone(&self);
            let built = tokio::task::spawn_blocking(move || {
                core.session.with_call(call_id, |call| {
                    let view =
                        (!filters.is_empty() || !sort.is_empty() || scope.is_some()).then(|| {
                            Arc::new(view::select(
                                &call.result,
                                &filters,
                                &sort,
                                scope.as_deref(),
                            ))
                        });
                    let rows = view
                        .as_ref()
                        .map_or(call.result.row_count(), |view| view.len());
                    *call.view.lock().expect("view poisoned") = view;
                    rows
                })
            })
            .await;

            let mut payload = vec![("call_id", Value::from(call_id))];
            match built {
                Ok(Some(rows)) => payload.push(("rows", Value::from(rows as u64))),
                Ok(None) => payload.push(("error", Value::from("the result is no longer held"))),
                Err(error) => payload.push(("error", Value::from(error.to_string()))),
            }
            if let Err(error) = self.nvim.emit("call:view", map(payload)) {
                tracing::warn!(%error, "could not report a view");
            }
        });
    }

    /// Plan staged changes to a stored result into the statements that make them, for review.
    ///
    /// Answered from the dispatch call: planning reads only the cells being changed, and touches no
    /// database.
    fn plan(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.integer("call_id")? as u64;
        let changes = changes(args.get("changes"))?;
        let gone = || format!("result {call_id} is no longer held");

        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(gone)?;
        let connection = self.session.connection(conn_id).ok_or_else(|| {
            "the connection this result came from is not open, so it cannot be edited".to_owned()
        })?;
        let statements = self
            .session
            .with_call(call_id, |call| {
                connection.backend.plan(&call.result, &changes)
            })
            .ok_or_else(gone)?
            .map_err(|error| error.to_string())?;
        Ok(strings(statements))
    }

    /// Run the statements a review approved, together, and report through `apply:done`.
    fn spawn_apply(self: Arc<Self>, args: &Args, reply: Reply) {
        let conn_id = match args.integer("conn_id") {
            Ok(id) => id,
            Err(error) => return reply.err(error),
        };
        let statements = args.opt_strings("statements").unwrap_or_default();
        if statements.is_empty() {
            return reply.err("there is nothing to apply");
        }
        let Some(connection) = self.session.connection(conn_id) else {
            return reply.err(format!("no connection with id {conn_id}"));
        };

        reply.ok(Value::from(conn_id));
        tokio::spawn(async move {
            let mut payload = vec![
                ("conn_id", Value::from(conn_id)),
                ("statements", Value::from(statements.len() as u64)),
            ];
            if let Err(error) = connection.backend.apply(&statements).await {
                payload.push(("error", Value::from(error.to_string())));
            }
            if let Err(error) = self.nvim.emit("apply:done", map(payload)) {
                tracing::warn!(%error, "could not report applied changes");
            }
        });
    }

    /// Hand the editor a slice of a result's rows.
    ///
    /// Answered from the dispatch call rather than a task. A page is bounded by what fits on a
    /// screen, so building it is not work the editor should wait on a task for, and paging that
    /// takes a round trip through the scheduler feels slower than paging that does not.
    ///
    /// Each row is an array of values in column order, in whatever msgpack type the value really
    /// is: a number stays a number so the editor can align it, and `NULL` is nil. Text arrives
    /// already flattened to one line, since a grid row is one line and only this side knows the
    /// original.
    fn rows(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.integer("call_id")? as u64;
        let offset = args.opt_usize("offset").unwrap_or(0);
        let limit = args.opt_usize("limit").unwrap_or(0);

        let rows = self.session.with_call(call_id, |call| {
            let result = &call.result;
            let view = call.view.lock().expect("view poisoned").clone();
            let total = view.as_ref().map_or(result.row_count(), |view| view.len());
            let end = offset.saturating_add(limit).min(total);
            // An out-of-range offset yields no rows rather than an error: a page request can race a
            // result being replaced, and an empty page is the honest answer.
            let chosen: Vec<usize> = match (&view, offset < end) {
                (_, false) => Vec::new(),
                (Some(view), true) => view[offset..end].to_vec(),
                (None, true) => (offset..end).collect(),
            };

            let width = result.columns().len();
            let rows: Vec<Value> = chosen
                .iter()
                .map(|&row| {
                    Value::Array(
                        (0..width)
                            .map(|column| {
                                cell_value(result.cell(row, column).unwrap_or(&Cell::Null))
                            })
                            .collect(),
                    )
                })
                .collect();

            // Which row of the result each one is, since a filtered or sorted page is not a run of
            // consecutive rows, and editing one or showing its detail needs to know which it was.
            map(vec![
                (
                    "indices",
                    Value::Array(chosen.iter().map(|row| Value::from(*row as u64)).collect()),
                ),
                ("rows", Value::Array(rows)),
                // How many rows the view holds, so the editor pages through a filter without
                // keeping a count of its own that could fall behind.
                ("total", Value::from(total as u64)),
            ])
        });

        rows.ok_or_else(|| format!("result {call_id} is no longer held"))
    }

    // -- talking to the editor -------------------------------------------------------------------

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

/// The databases of a cluster, which the plugin opens one connection each for.
fn database_nodes(databases: Vec<String>) -> Vec<Value> {
    databases
        .into_iter()
        .map(|name| {
            map(vec![
                ("name", Value::from(name)),
                ("kind", Value::from("database")),
                ("expandable", Value::from(true)),
            ])
        })
        .collect()
}

/// The four groups a schema is drawn as, each with how many things it holds.
///
/// The counts are what makes the groups worth having: `Functions (0)` answers the question without
/// being opened, and a schema of three hundred tables says so before it is expanded into them.
/// Reading them costs the two queries that expanding a group would have cost anyway.
async fn group_nodes(connection: &Connection, schema: &str) -> Result<Vec<Value>, DbError> {
    let relations = connection.backend.relations(schema).await?;

    // Redis holds keys and nothing else, and what a key holds decides how it is read back, so its
    // groups are the types rather than tables and views.
    if connection.backend.dialect() == Dialect::Redis {
        return Ok(KeyType::ALL
            .into_iter()
            .map(|wanted| {
                let (key, name) = wanted.group();
                let count = relations
                    .iter()
                    .filter(|r| r.kind == RelationKind::Key(wanted))
                    .count();
                group_node(key, name, "keys", count)
            })
            .collect());
    }

    let tables = relations.iter().filter(|r| is_table(r.kind)).count();
    let views = relations.len() - tables;

    // MongoDB calls its tables collections, and has no stored routines to group.
    if connection.backend.dialect() == Dialect::MongoDb {
        return Ok(vec![
            group_node("tables", "Collections", "tables", tables),
            group_node("views", "Views", "views", views),
        ]);
    }

    let routines = connection.backend.routines(schema).await?;
    let procedures = routines
        .iter()
        .filter(|r| r.kind == RoutineKind::Procedure)
        .count();
    let functions = routines.len() - procedures;

    Ok(vec![
        group_node("tables", "Tables", "tables", tables),
        group_node("views", "Views", "views", views),
        group_node("functions", "Functions", "functions", functions),
        group_node("procedures", "Procedures", "procedures", procedures),
    ])
}

/// Whether a relation belongs under Tables rather than under Views.
///
/// Anything the server reports that is neither a table nor a view, such as a foreign table, goes
/// with the tables: it is queried the same way, and a group of its own for one row would be noise.
fn is_table(kind: RelationKind) -> bool {
    !matches!(kind, RelationKind::View | RelationKind::MaterializedView)
}

/// What one group holds.
async fn members(
    connection: &Connection,
    schema: &str,
    group: &str,
) -> Result<Vec<Value>, DbError> {
    match group {
        "tables" | "views" => {
            let want_tables = group == "tables";
            let relations = connection.backend.relations(schema).await?;
            Ok(relation_nodes(
                relations
                    .into_iter()
                    .filter(|relation| is_table(relation.kind) == want_tables)
                    .collect(),
            ))
        }
        "functions" | "procedures" => {
            let want = if group == "procedures" {
                RoutineKind::Procedure
            } else {
                RoutineKind::Function
            };
            let routines = connection.backend.routines(schema).await?;
            Ok(routine_nodes(
                routines
                    .into_iter()
                    .filter(|routine| routine.kind == want)
                    .collect(),
            ))
        }
        other => {
            // Anything else is a Redis type's group, or a path the plugin invented: every group it
            // can ask for came from a node this engine emitted, and an error line beats a group
            // that opens onto nothing.
            let Some(wanted) = KeyType::ALL
                .into_iter()
                .find(|kind| kind.group().0 == other)
            else {
                return Err(DbError::driver(format!("no `{other}` group in a schema")));
            };
            let relations = connection.backend.relations(schema).await?;
            Ok(relation_nodes(
                relations
                    .into_iter()
                    .filter(|relation| relation.kind == RelationKind::Key(wanted))
                    .collect(),
            ))
        }
    }
}

/// One group heading.
///
/// `key` is what the path is built from and `name` is what is drawn, so the engine matches on a
/// stable word rather than on whatever the drawer happens to print. `kind` picks the icon, which
/// the six Redis groups share. An empty group is not expandable: opening it would show nothing,
/// and the count already says why.
fn group_node(key: &str, name: &str, kind: &str, count: usize) -> Value {
    map(vec![
        ("key", Value::from(key)),
        ("name", Value::from(name)),
        ("kind", Value::from(kind)),
        ("expandable", Value::from(count > 0)),
        ("count", Value::from(count as u64)),
    ])
}

fn routine_nodes(routines: Vec<RoutineNode>) -> Vec<Value> {
    routines
        .into_iter()
        .map(|routine| {
            map(vec![
                ("name", Value::from(routine.name)),
                ("kind", Value::from(routine.kind.name())),
                // A routine is a leaf. Its body and its arguments are not something the drawer
                // shows, and pretending otherwise would open onto nothing.
                ("expandable", Value::from(false)),
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
                // A Redis key has no columns to open onto.
                (
                    "expandable",
                    Value::from(!matches!(relation.kind, RelationKind::Key(_))),
                ),
            ])
        })
        .collect()
}

fn column_nodes(columns: Vec<ColumnNode>) -> Vec<Value> {
    columns
        .into_iter()
        .map(|column| {
            // Read before the name is moved out, since it is derived from the type name.
            let class = column.class().name();
            let mut pairs = vec![
                ("name", Value::from(column.name)),
                ("kind", Value::from("column")),
                // A column is a leaf; the tree stops here.
                ("expandable", Value::from(false)),
                ("class", Value::from(class)),
                ("type_name", Value::from(column.type_name)),
                ("nullable", Value::from(column.nullable)),
                ("primary_key", Value::from(column.primary_key)),
            ];

            // What the column points at, as the drawer shows it: `authors.id`. One string rather
            // than two fields, because the drawer has nothing to do with the halves separately and
            // a qualified name is what a reader is looking for.
            //
            // Left out entirely rather than sent as nil: a msgpack nil arrives in Lua as `vim.NIL`,
            // which is a userdata that tests as true, so a nil here would make every column look
            // like it references something.
            if let Some(key) = column.foreign_key {
                pairs.push((
                    "references",
                    Value::from(format!("{}.{}", key.table, key.column)),
                ));
            }

            map(pairs)
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

/// The most rows an export preview renders: enough to see what the file will look like.
const PREVIEW_ROWS: usize = 100;

/// The export format an argument names, CSV when it names none.
fn format(args: &Args) -> Result<Format, String> {
    match args.opt_string("format").as_deref().map(Format::parse) {
        Some(Some(format)) => Ok(format),
        Some(None) => Err("format must be `csv` or `json`".to_owned()),
        None => Ok(Format::Csv),
    }
}

/// The elements of an array argument. Lua sends an empty table as an empty map, and a missing one
/// as nothing, and both are no elements.
fn items(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().collect(),
        _ => Vec::new(),
    }
}

/// One field of a map argument.
fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value
        .as_map()?
        .iter()
        .find(|(name, _)| name.as_str() == Some(key))
        .map(|(_, value)| value)
}

/// An array of zero-based indices, or `None` when there is none or it is empty.
fn indices(value: Option<&Value>) -> Option<Vec<usize>> {
    let indices: Vec<usize> = items(value)
        .into_iter()
        .filter_map(|item| usize::try_from(item.as_u64()?).ok())
        .collect();
    (!indices.is_empty()).then_some(indices)
}

/// The filters a `view` call carries. A filter without a column searches every column.
fn filters(value: Option<&Value>) -> Result<Vec<Filter>, String> {
    items(value)
        .into_iter()
        .map(|item| {
            let op = field(item, "op")
                .and_then(Value::as_str)
                .unwrap_or_default();
            Ok(Filter {
                column: field(item, "column")
                    .and_then(Value::as_u64)
                    .and_then(|column| usize::try_from(column).ok()),
                op: Op::parse(op).ok_or_else(|| format!("`{op}` is not a filter"))?,
                value: field(item, "value")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            })
        })
        .collect()
}

/// The staged changes a `plan` call carries: `updates` of `{ row, cells }`, `deletes` of rows, and
/// `inserts` of cell lists, where a cell is `{ column, value }` and a missing value is `NULL`.
fn changes(value: Option<&Value>) -> Result<Changes, String> {
    let Some(value) = value else {
        return Ok(Changes::default());
    };
    let index = |item: &Value, key: &str| -> Result<usize, String> {
        field(item, key)
            .and_then(Value::as_u64)
            .and_then(|index| usize::try_from(index).ok())
            .ok_or_else(|| format!("a change needs a `{key}`"))
    };
    let cells = |list: Option<&Value>| -> Result<Vec<(usize, Option<String>)>, String> {
        items(list)
            .into_iter()
            .map(|cell| {
                let text = field(cell, "value")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                Ok((index(cell, "column")?, text))
            })
            .collect()
    };

    Ok(Changes {
        updates: items(field(value, "updates"))
            .into_iter()
            .map(|update| Ok((index(update, "row")?, cells(field(update, "cells"))?)))
            .collect::<Result<_, String>>()?,
        deletes: indices(field(value, "deletes")).unwrap_or_default(),
        inserts: items(field(value, "inserts"))
            .into_iter()
            .map(|insert| cells(Some(insert)))
            .collect::<Result<_, String>>()?,
    })
}

/// One cell, as the value it really is rather than as text.
///
/// This is what "structured" means on the wire: a number reaches Lua as a number, so the editor can
/// align it without parsing it back; a boolean as a boolean; `NULL` as nil, which Neovim decodes to
/// `vim.NIL` and so survives being an element of an array.
///
/// Everything else arrives as a string, already flattened to a single line. A grid row is one line,
/// and the escaping has to happen on the side that still has the original: a value holding a line
/// break would otherwise arrive as two rows, and the width this column was measured to would be
/// wrong. Exports do not come through here, so nothing they carry is flattened.
fn cell_value(cell: &Cell) -> Value {
    match cell {
        Cell::Null => Value::Nil,
        Cell::Bool(value) => Value::from(*value),
        Cell::Int(value) => Value::from(*value),
        Cell::Float(value) => Value::from(*value),
        // Exact numerics stay text: they do not fit a float without losing digits, which is the
        // whole reason the database has the type.
        other => Value::from(other.display("").into_owned()),
    }
}

/// What the editor needs to describe a result and lay its columns out.
///
/// Each column carries what it is and how wide its widest value is, measured over every row. That
/// measurement is the one thing the editor cannot work out for itself: it is sent one page at a
/// time, and a column sized from one page would change width when the user turned to the next.
fn summarize(call: &Call) -> Vec<(&'static str, Value)> {
    let result = &call.result;

    let columns: Vec<Value> = result
        .columns()
        .iter()
        .enumerate()
        .map(|(index, column)| {
            let stats = result.column_stats(index);
            let mut pairs = vec![
                ("name", Value::from(column.name.clone())),
                ("type_name", Value::from(column.type_name.clone())),
                ("class", Value::from(column.class.name())),
                // Display columns taken by the widest value, `NULL`s excluded, since what one
                // reads as is the editor's choice and so only the editor can measure it.
                ("widest", Value::from(stats.widest as u64)),
                ("nulls", Value::from(stats.nulls)),
                ("numeric", Value::from(stats.numeric)),
            ];
            // Left out rather than sent as nil for a column that is no kind of key: a msgpack nil
            // reaches Lua as `vim.NIL`, which is a userdata and tests as true.
            if let Some(key) = column.key.name() {
                pairs.push(("key", Value::from(key)));
            }
            // Left out rather than false, for the same reason.
            if result
                .source()
                .is_some_and(|source| source.editable(result, index))
            {
                pairs.push(("editable", Value::from(true)));
            }
            map(pairs)
        })
        .collect();

    let mut pairs = vec![
        ("columns", Value::Array(columns)),
        ("call_id", Value::from(call.id)),
        ("conn_id", Value::from(call.conn_id)),
        ("rows", Value::from(result.row_count() as u64)),
        // The statement that produced these rows, which is what running them again means: the
        // editor sent a whole buffer, and only this one of its statements is on screen.
        ("sql", Value::from(result.statement())),
        ("truncated", Value::from(result.is_truncated())),
    ];
    // Left out rather than sent as nil when nothing was written, for the reason `key` is above: a
    // MongoDB `find` that matches nothing has neither rows nor a count, and a nil here would reach
    // the winbar as a number to print.
    if let Some(source) = result.source() {
        pairs.push((
            "source",
            map(vec![
                ("kind", Value::from(source.kind())),
                ("name", Value::from(source.name())),
            ]),
        ));
    }
    if let Some(affected) = result.affected() {
        pairs.push(("affected", Value::from(affected)));
    }
    pairs
}

/// Save a finished result where the plugin asked, for its query log to show again later.
///
/// Started after `done` has gone out rather than before it: writing a hundred thousand rows takes
/// time the user should spend looking at them. A statement that returned no columns has nothing to
/// save, and the plugin knows not to point at a file for one.
fn save(path: PathBuf, call: Arc<Call>) {
    if call.result.columns().is_empty() {
        return;
    }
    tokio::task::spawn_blocking(move || {
        if let Err(error) = archive::write(&path, &call.result) {
            tracing::warn!(%error, path = %path.display(), "could not save a result");
        }
    });
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
            "restore" => return self.spawn_restore(&args, reply),
            "rows" => self.rows(&args),
            "plan" => self.plan(&args),
            "export_preview" => self.export_preview(&args),
            "view" => return self.spawn_view(&args, reply),
            "apply" => return self.spawn_apply(&args, reply),
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
