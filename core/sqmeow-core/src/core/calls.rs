//! Running statements, and reading the results they keep.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use rmpv::Value;
use sqmeow_db::{Cell, Dialect, Error as DbError, ResultSet, edit, guard, sql, view};

use super::summary::{cell_value, summarize};
use super::{Core, Started, params};
use crate::archive;
use crate::args::Args;
use crate::session::{Call, CallId, ConnId, Connection};
use crate::value::{map, optional, strings};

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
        let dialect = connection.backend.dialect();
        let statements = chosen(dialect, &source, args.opt_usize("line"))?;
        if connection.read_only
            && statements
                .iter()
                .any(|statement| guard::writes(dialect, &statement.sql))
        {
            return Err(format!(
                "`{}` is read-only, so it runs only statements that read",
                connection.name
            ));
        }
        let archive = args.opt_string("archive").map(PathBuf::from);

        let condition = args.opt_string("where").unwrap_or_default();
        let order = args.opt_string("order_by").unwrap_or_default();
        let wrapped = if condition.trim().is_empty() && order.trim().is_empty() {
            None
        } else {
            if matches!(dialect, Dialect::Redis | Dialect::MongoDb | Dialect::Scylla) {
                return Err("filtering with WHERE and ORDER BY needs a SQL database".to_owned());
            }
            let [statement] = statements.as_slice() else {
                return Err("only one statement can be filtered".to_owned());
            };
            Some(
                sql::filtered(&statement.sql, &condition, &order)
                    .ok_or("only a query that returns rows can be filtered")?,
            )
        };

        // After applying edits, rows the inserts returned are shown even where the query leaves them out.
        let inserted = args.opt_bool("inserted").unwrap_or(false);
        let call_id = self.session.next_call_id();
        let work = self.run(call_id, connection, statements, wrapped, archive, inserted);
        Ok((Value::from(call_id), Box::pin(work)))
    }

    /// What the statements a call would run destroy, for the editor to confirm first.
    pub(super) fn inspect(&self, args: &Args) -> Result<Value, String> {
        let connection = self.connection(args.conn_id("conn_id")?)?;
        let dialect = connection.backend.dialect();
        let statements = chosen(dialect, &args.string("sql")?, args.opt_usize("line"))?;
        Ok(strings(
            statements
                .iter()
                .filter_map(|statement| guard::danger(dialect, &statement.sql))
                .collect::<Vec<_>>(),
        ))
    }

    /// Run statements, or the one query `wrapped` filters.
    async fn run(
        self: Arc<Self>,
        call_id: CallId,
        connection: Arc<Connection>,
        statements: Vec<sql::Statement>,
        wrapped: Option<String>,
        archive: Option<PathBuf>,
        inserted: bool,
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
        // The rows of earlier statements, each kept as a result of its own.
        let mut earlier: Vec<Value> = Vec::new();
        for statement in &statements {
            let run = wrapped.as_deref().unwrap_or(&statement.sql);
            let outcome = connection
                .backend
                .execute_wrapped(run, &statement.sql, options.max_rows, running.token())
                .await;
            match outcome {
                Ok(result) => {
                    if let Some(previous) = last.replace(result)
                        && !previous.columns().is_empty()
                    {
                        earlier.push(self.keep(conn_id, previous));
                    }
                }
                Err(DbError::Cancelled) => {
                    return self.emit_call(call_id, conn_id, "cancelled", elapsed(started));
                }
                Err(error) => {
                    let mut error = error.to_string();
                    // MySQL refuses a subquery whose columns share a name.
                    if wrapped.is_some() && error.contains("Duplicate column name") {
                        error.push_str(
                            "\nname each column differently with AS to filter this result",
                        );
                    }
                    let mut payload = elapsed(started);
                    if !earlier.is_empty() {
                        earlier.push(map(vec![
                            ("call_id", Value::from(call_id)),
                            ("conn_id", Value::from(conn_id)),
                            ("state", Value::from("error")),
                            ("error", Value::from(error.as_str())),
                        ]));
                        payload.push(("results", Value::Array(earlier)));
                    }
                    payload.push(("error", Value::from(error)));
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
            }
        }

        // Only the last statement's rows are shown, timed over the whole call.
        let mut result = last.unwrap_or_default();
        result.set_elapsed(started.elapsed());
        let appended = if inserted {
            let rows = self.session.take_inserted(conn_id);
            edit::append_inserted(&mut result, connection.backend.dialect(), &rows)
        } else {
            0
        };

        let call = Call::new(call_id, conn_id, result);
        let mut payload = summarize(&call);
        payload.extend(elapsed(started));
        if appended > 0 {
            payload.push(("appended", Value::from(appended as u64)));
        }
        // After the statements, so a `use` among them is what the winbar shows.
        if let Some(database) = connection.backend.database() {
            payload.push(("current_database", Value::from(database)));
        }
        if !earlier.is_empty() {
            let mut current = payload.clone();
            current.push(("state", Value::from("done")));
            earlier.push(map(current));
            payload.push(("results", Value::Array(earlier)));
        }

        let call = self.session.store_call(call);
        drop(running);
        self.emit_call(call_id, conn_id, "done", payload);

        if let Some(path) = archive {
            save(path, call);
        }
    }

    /// Store an earlier statement's rows as a result of their own, and describe it.
    fn keep(&self, conn_id: ConnId, result: ResultSet) -> Value {
        let elapsed_ms = result.elapsed().as_millis() as u64;
        let call = Call::new(self.session.next_call_id(), conn_id, result);
        let mut summary = summarize(&call);
        summary.push(("state", Value::from("done")));
        summary.push(("elapsed_ms", Value::from(elapsed_ms)));
        self.session.store_call(call);
        map(summary)
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

    /// The condition matching one cell's value, for the filter bar.
    pub(super) fn condition(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let row = args.opt_usize("row").unwrap_or(0);
        let column = args.opt_usize("column").unwrap_or(0);
        let gone = || format!("result {call_id} is no longer held");

        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(gone)?;
        let dialect = self.connection(conn_id)?.backend.dialect();
        self.session
            .with_call(call_id, |call| {
                let result = &call.result;
                let name = &result.columns().get(column).ok_or("no such column")?.name;
                let cell = result.cell(row, column).ok_or("no such row")?;
                sqmeow_db::edit::condition(dialect, name, cell).map_err(|error| error.to_string())
            })
            .ok_or_else(gone)?
            .map(Value::from)
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

/// The statements a buffer holds, or only the one at `line`.
fn chosen(
    dialect: Dialect,
    source: &str,
    line: Option<usize>,
) -> Result<Vec<sql::Statement>, String> {
    // A Redis command ends with its line, a MongoDB command with its document, and a SQL
    // statement with a semicolon.
    let statements = match dialect {
        Dialect::Redis => sql::split_lines(source),
        Dialect::MongoDb => sql::split_documents(source),
        dialect => sql::split(source, dialect),
    };
    let none = || "there is no statement to run".to_owned();
    if statements.is_empty() {
        return Err(none());
    }
    // A line means "run only what the cursor is in".
    match line {
        Some(line) => sql::statement_at(&statements, line)
            .cloned()
            .map(|statement| vec![statement])
            .ok_or_else(none),
        None => Ok(statements),
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
