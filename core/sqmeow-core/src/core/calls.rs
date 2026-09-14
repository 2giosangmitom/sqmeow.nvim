//! Running statements, and reading the results they keep.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use rmpv::Value;
use sqmeow_db::{Cell, Dialect, Error as DbError, ResultSet, sql, view};

use super::summary::{cell_value, summarize};
use super::{Core, Started, params};
use crate::archive;
use crate::args::Args;
use crate::session::{Call, CallId, ConnId, Connection};
use crate::value::{map, optional};

impl Core {
    /// The error for a result the history no longer holds.
    pub(super) fn held(&self, id: CallId) -> Result<(), String> {
        self.session
            .with_call(id, |_| ())
            .ok_or_else(|| format!("result {id} is no longer held"))
    }

    /// Stop a running query.
    pub(super) fn cancel(&self, args: &Args) -> Result<Value, String> {
        Ok(Value::from(self.session.cancel(args.call_id()?)))
    }

    /// Run a buffer's statements, answering with the call id before they start.
    pub(super) fn execute(self: Arc<Self>, args: &Args) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        let source = args.string("sql")?;
        let connection = self.connection(conn_id)?;

        // A Redis command ends with its line, a MongoDB command with its document, and a SQL
        // statement with a semicolon.
        let mut statements = match connection.backend.dialect() {
            Dialect::Redis => sql::split_lines(&source),
            Dialect::MongoDb => sql::split_documents(&source),
            dialect => sql::split(&source, dialect),
        };
        let none = || "there is no statement to run".to_owned();
        if statements.is_empty() {
            return Err(none());
        }
        // A line means "run only what the cursor is in".
        if let Some(line) = args.opt_usize("line") {
            let chosen = sql::statement_at(&statements, line)
                .cloned()
                .ok_or_else(none)?;
            statements = vec![chosen];
        }
        let archive = args.opt_string("archive").map(PathBuf::from);

        let call_id = self.session.next_call_id();
        let work = self.run(call_id, connection, statements, archive);
        Ok((Value::from(call_id), Box::pin(work)))
    }

    async fn run(
        self: Arc<Self>,
        call_id: CallId,
        connection: Arc<Connection>,
        statements: Vec<sql::Statement>,
        archive: Option<PathBuf>,
    ) {
        let conn_id = connection.id;
        let options = self.session.options();
        let running = self.session.begin_call(call_id);
        let started = Instant::now();

        // The line range lets the editor show which statement is running.
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
                .execute(&statement.sql, options.max_rows, running.token())
                .await;
            match outcome {
                Ok(result) => last = Some(result),
                Err(DbError::Cancelled) => {
                    return self.emit_call(call_id, conn_id, "cancelled", elapsed(started));
                }
                Err(error) => {
                    let mut payload = elapsed(started);
                    payload.push(("error", Value::from(error.to_string())));
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
            }
        }

        // Only the last statement's rows are shown, timed over the whole call.
        let mut result = last.unwrap_or_default();
        result.set_elapsed(started.elapsed());

        let call = Call::new(call_id, conn_id, result);
        let mut payload = summarize(&call);
        payload.extend(elapsed(started));
        // After the statements, so a `use` among them is what the winbar shows.
        if let Some(database) = connection.backend.database() {
            payload.push(("current_database", Value::from(database)));
        }

        let call = self.session.store_call(call);
        drop(running);
        self.emit_call(call_id, conn_id, "done", payload);

        if let Some(path) = archive {
            save(path, call);
        }
    }

    /// Read a result saved by an earlier `execute` back into the session.
    pub(super) fn restore(self: Arc<Self>, args: &Args) -> Started {
        let path = PathBuf::from(args.string("path")?);
        // The connection it ran on, when that is open.
        let conn_id = ConnId(args.opt_integer("conn_id").unwrap_or(0));
        let call_id = self.session.next_call_id();

        let work = async move {
            let read = tokio::task::spawn_blocking(move || archive::read(&path)).await;
            let result = match read {
                Ok(Ok(result)) => result,
                Ok(Err(error)) => {
                    let payload = vec![("error", Value::from(error))];
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
                Err(error) => {
                    let error = format!("the saved result could not be read: {error}");
                    let payload = vec![("error", Value::from(error))];
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
            };

            let elapsed_ms = result.elapsed().as_millis() as u64;
            let call = Call::new(call_id, conn_id, result);
            let mut payload = summarize(&call);
            payload.push(("elapsed_ms", Value::from(elapsed_ms)));

            self.session.store_call(call);
            self.emit_call(call_id, conn_id, "done", payload);
        };
        Ok((Value::from(call_id), Box::pin(work)))
    }

    /// One row of a stored result, for the detail view.
    pub(super) fn row(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let index = args.opt_usize("row").unwrap_or(0);

        let row = self
            .session
            .with_call(call_id, |call| {
                let result = &call.result;
                (index < result.row_count()).then(|| {
                    Value::Array(
                        result
                            .columns()
                            .iter()
                            .enumerate()
                            .map(|(column, meta)| {
                                let cell = result.cell(index, column).unwrap_or(&Cell::Null);
                                map(vec![
                                    ("name", Value::from(meta.name.as_str())),
                                    ("type_name", Value::from(cell.type_name())),
                                    ("declared_type", Value::from(meta.type_name.as_str())),
                                    ("is_null", Value::from(cell.is_null())),
                                    ("value", Value::from(cell.text("").into_owned())),
                                ])
                            })
                            .collect(),
                    )
                })
            })
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;

        row.ok_or_else(|| format!("row {index} is past the end of the result"))
    }

    /// Hand the editor a slice of a result's rows.
    pub(super) fn rows(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let offset = args.opt_usize("offset").unwrap_or(0);
        let limit = args.opt_usize("limit").unwrap_or(0);

        let rows = self.session.with_call(call_id, |call| {
            let result = &call.result;
            let view = call.view();
            let total = view.as_ref().map_or(result.row_count(), |view| view.len());
            let end = offset.saturating_add(limit).min(total);
            // An out-of-range offset yields no rows rather than an error.
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

            map(vec![
                // Which row of the result each one is.
                (
                    "indices",
                    Value::Array(chosen.iter().map(|row| Value::from(*row as u64)).collect()),
                ),
                ("rows", Value::Array(rows)),
                // How many rows the view holds.
                ("total", Value::from(total as u64)),
            ])
        });

        rows.ok_or_else(|| format!("result {call_id} is no longer held"))
    }

    /// Narrow and order the rows of a stored result, for the grid to page through.
    pub(super) fn view(self: Arc<Self>, args: &Args) -> Started {
        let call_id = args.call_id()?;
        let filters = params::filters(args.get("filters"))?;
        let sort = params::sort(args.get("sort"));
        let scope = params::indices(args.get("rows"));
        self.held(call_id)?;

        let work = async move {
            let core = Arc::clone(&self);
            let built = tokio::task::spawn_blocking(move || {
                core.session.with_call(call_id, |call| {
                    let narrowed = !filters.is_empty() || !sort.is_empty() || scope.is_some();
                    let view = narrowed.then(|| {
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
            self.emit("call:view", map(payload));
        };
        Ok((Value::from(call_id), Box::pin(work)))
    }

    fn emit_call(&self, call_id: CallId, conn_id: ConnId, state: &str, extra: Vec<(&str, Value)>) {
        let mut pairs = vec![
            ("call_id", Value::from(call_id)),
            ("conn_id", Value::from(conn_id)),
            ("state", Value::from(state)),
        ];
        pairs.extend(extra);
        self.emit("call:state", map(pairs));
    }
}

/// Save a finished result where the plugin asked, for its query log to show again later.
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
