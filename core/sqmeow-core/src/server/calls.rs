//! Running statements, and reading the results they keep.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use rmpv::Value;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit;
use sqmeow_db::error::Error as DbError;
use sqmeow_db::guard;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql;
use sqmeow_db::sql::parameters::{self as query_parameters, Bound};
use sqmeow_db::value::Cell;
use sqmeow_db::view;

use super::summary::{capabilities, cell_value, summarize};
use super::{Core, Started, params};
use crate::server::archive;
use crate::server::args::Args;
use crate::server::payload::{map, optional, strings};
use crate::server::session::{Call, CallId, ConnId, Connection, QueryParameters};
use tokio_util::sync::CancellationToken;

struct Run {
    statements: Vec<sql::Statement>,
    bound: Vec<Bound>,
    parameters: QueryParameters,
    wrapped: Option<String>,
    archive: Option<PathBuf>,
    inserted: bool,
}

/// Trips a call's token once `query.timeout_ms` passes, and stops when dropped.
pub(super) struct Deadline {
    timer: Option<tokio::task::JoinHandle<()>>,
    passed: Arc<AtomicBool>,
}

impl Deadline {
    /// No deadline when `timeout_ms` is 0.
    pub(super) fn start(token: CancellationToken, timeout_ms: u64) -> Self {
        let passed = Arc::new(AtomicBool::new(false));
        let timer = (timeout_ms > 0).then(|| {
            let passed = Arc::clone(&passed);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(timeout_ms)).await;
                passed.store(true, Ordering::Relaxed);
                token.cancel();
            })
        });
        Self { timer, passed }
    }

    /// Whether the deadline, rather than a cancel, tripped the token.
    pub(super) fn passed(&self) -> bool {
        self.passed.load(Ordering::Relaxed)
    }
}

impl Drop for Deadline {
    fn drop(&mut self) {
        if let Some(timer) = &self.timer {
            timer.abort();
        }
    }
}

impl Core {
    /// Only an explicit refresh executes a query. Views never depend on a live dialect.
    fn query_view(&self, call_id: CallId, refresh: bool) -> Result<bool, String> {
        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;
        if refresh && self.session.connection(conn_id).is_none() {
            return Err("the connection this result came from is not open".to_owned());
        }
        Ok(refresh)
    }

    /// Filter/sort retained rows with Polars. An explicit refresh runs the original query
    /// without local filters and returns a new call id; Lua reapplies its view afterward.
    pub(super) fn result_view(self: Arc<Self>, args: &Args) -> Started {
        let call_id = args.call_id()?;
        let query = self.query_view(call_id, args.opt_bool("refresh").unwrap_or(false))?;
        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;
        if query && args.conn_id("conn_id")? != conn_id {
            return Err("result_view: the connection does not belong to this result".to_owned());
        }
        let (answer, work) = if query {
            let retained = self
                .session
                .call(call_id)
                .ok_or_else(|| format!("result {call_id} is no longer held"))?;
            let sql = args.string("sql")?;
            let dialect = self.connection(conn_id)?.backend.dialect();
            if retained.parameters.definitions.is_empty()
                && !query_parameters::describe(dialect, &sql, &[&sql])?.is_empty()
            {
                return Err("parameter values are no longer held; rerun from the scratchpad to enter them again".into());
            }
            if !retained.parameters.definitions.is_empty() && sql != retained.result.statement() {
                return Err("rerun an edited parameterized query from the scratchpad".into());
            }
            let refresh = Args::from_params(&[map(vec![
                ("conn_id", Value::from(conn_id)),
                ("sql", Value::from(sql)),
                (
                    "inserted",
                    Value::from(args.opt_bool("inserted").unwrap_or(false)),
                ),
            ])])?;
            self.execute_with_parameters(&refresh, Some(retained.parameters.clone()))?
        } else {
            self.view(args)?
        };
        Ok((
            map(vec![
                ("call_id", answer),
                ("route", Value::from(if query { "query" } else { "memory" })),
            ]),
            work,
        ))
    }

    /// The same routing policy used for the edit confirmation before a new result replaces one.
    pub(super) fn result_view_route(&self, args: &Args) -> Result<Value, String> {
        Ok(Value::from(
            if self.query_view(args.call_id()?, args.opt_bool("refresh").unwrap_or(false))? {
                "query"
            } else {
                "memory"
            },
        ))
    }

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
        self.execute_with_parameters(args, None)
    }

    /// Discover only inputs used by the selected statements; buffer headers supply defaults.
    pub(super) fn query_parameters(&self, args: &Args) -> Result<Value, String> {
        let connection = self.connection(args.conn_id("conn_id")?)?;
        let source = args.string("sql")?;
        let statements = chosen(
            connection.backend.dialect(),
            &source,
            args.opt_usize("line"),
        )?;
        let selected: Vec<&str> = statements
            .iter()
            .map(|statement| statement.sql.as_str())
            .collect();
        let parameter_source = args
            .opt_string("parameter_source")
            .unwrap_or_else(|| source.clone());
        let parameters =
            query_parameters::describe(connection.backend.dialect(), &parameter_source, &selected)?;
        Ok(Value::Array(
            parameters
                .into_iter()
                .map(|parameter| {
                    let mut fields = vec![
                        ("name", Value::from(parameter.name)),
                        ("kind", Value::from(parameter.kind.name())),
                    ];
                    if let Some(default) = parameter.default {
                        fields.push(("default", Value::from(default)));
                    }
                    map(fields)
                })
                .collect(),
        ))
    }

    fn execute_with_parameters(
        self: Arc<Self>,
        args: &Args,
        replay: Option<QueryParameters>,
    ) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        let source = args.string("sql")?;
        let connection = self.connection(conn_id)?;
        let dialect = connection.backend.dialect();
        let statements = chosen(dialect, &source, args.opt_usize("line"))?;
        let parameters = match replay {
            Some(parameters) if !parameters.definitions.is_empty() => parameters,
            _ => {
                let selected: Vec<&str> = statements
                    .iter()
                    .map(|statement| statement.sql.as_str())
                    .collect();
                QueryParameters {
                    definitions: query_parameters::describe(
                        dialect,
                        &args
                            .opt_string("parameter_source")
                            .unwrap_or_else(|| source.clone()),
                        &selected,
                    )?,
                    values: params::query_values(args.get("parameters"))?,
                }
            }
        };
        for name in parameters.values.keys() {
            if !parameters
                .definitions
                .iter()
                .any(|parameter| &parameter.name == name)
            {
                return Err(format!("query does not use parameter `{name}`"));
            }
        }
        // Validate every statement before accepting any work, including later inputs in a batch.
        let bound = if parameters.definitions.is_empty() {
            Vec::new()
        } else {
            statements
                .iter()
                .map(|statement| {
                    query_parameters::compile(
                        dialect,
                        &statement.sql,
                        &parameters.definitions,
                        &parameters.values,
                    )
                })
                .collect::<Result<Vec<_>, _>>()?
        };
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
        // The names the rows have, which a filter tells apart where two are the same.
        let columns = args.opt_strings("columns")?.unwrap_or_default();
        let wrapped = if condition.trim().is_empty() && order.trim().is_empty() {
            None
        } else {
            if matches!(
                dialect,
                Dialect::Redis | Dialect::Scylla | Dialect::SurrealDb
            ) {
                return Err("filtering in the query needs a SQL or MongoDB database".to_owned());
            }
            let [statement] = statements.as_slice() else {
                return Err("only one statement can be filtered".to_owned());
            };
            Some(if dialect == Dialect::MongoDb {
                sqmeow_adapters::mongodb::filtered(&statement.sql, &condition, &order)
                    .map_err(|error| error.to_string())?
            } else {
                sql::filtered(dialect, &statement.sql, &condition, &order, &columns)
                    .ok_or("only a query that returns rows can be filtered")?
            })
        };
        if wrapped.is_some() && !bound.is_empty() {
            return Err(
                "parameterized queries use retained-result filters, not query wrappers".into(),
            );
        }
        // Filter/order fragments are editable SQL too. Check the actual request,
        // not just the original query, before sending it to an unenforced backend.
        if connection.read_only
            && wrapped
                .as_deref()
                .is_some_and(|sql| guard::writes(dialect, sql))
        {
            return Err(format!(
                "`{}` is read-only, so it runs only statements that read",
                connection.name
            ));
        }

        // After applying edits, rows the inserts returned are shown even where the query leaves them out.
        let inserted = args.opt_bool("inserted").unwrap_or(false);
        let call_id = self.session.next_call_id();
        let work = self.run(
            call_id,
            connection,
            Run {
                statements,
                bound,
                parameters,
                wrapped,
                archive,
                inserted,
            },
        );
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
    async fn run(self: Arc<Self>, call_id: CallId, connection: Arc<Connection>, run: Run) {
        let Run {
            statements,
            bound,
            parameters,
            wrapped,
            archive,
            inserted,
        } = run;
        let conn_id = connection.id;
        let options = self.session.options();
        let running = self.session.begin_call(call_id);
        let started = Instant::now();
        let deadline = Deadline::start(running.token(), options.timeout_ms);

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
        // Each earlier statement's result, kept as a call of its own, how the editor sees it, and
        // where the ones with rows are saved.
        let mut kept: Vec<Call> = Vec::new();
        let mut earlier: Vec<Value> = Vec::new();
        let mut saves: Vec<(usize, PathBuf)> = Vec::new();
        for (index, statement) in statements.iter().enumerate() {
            let run = wrapped.as_deref().unwrap_or(&statement.sql);
            let outcome =
                if let Some(bound) = bound.get(index).filter(|bound| !bound.values.is_empty()) {
                    connection
                        .backend
                        .execute_bound(&bound.sql, &bound.values, options.max_rows, running.token())
                        .await
                        .map(|mut result| {
                            result.set_statement(&statement.sql);
                            vec![result]
                        })
                } else {
                    connection
                        .backend
                        .execute_results(run, &statement.sql, options.max_rows, running.token())
                        .await
                };
            match outcome {
                Ok(results) => {
                    for result in results {
                        if let Some(previous) = last.replace(result) {
                            let (call, mut summary) = self.keep(conn_id, previous, None);
                            let call = call.with_parameters(parameters.clone());
                            if let Some(path) = archive
                                .as_deref()
                                .filter(|_| !call.result.columns().is_empty())
                            {
                                let path = sibling(path, kept.len());
                                summary.push(("archive", Value::from(path.display().to_string())));
                                saves.push((kept.len(), path));
                            }
                            kept.push(call);
                            earlier.push(map(summary));
                        }
                    }
                }
                Err(DbError::Cancelled) if deadline.passed() => {
                    let mut payload = elapsed(started);
                    payload.push((
                        "error",
                        Value::from(format!(
                            "the query ran past the {} ms timeout, so it was cancelled",
                            options.timeout_ms
                        )),
                    ));
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
                Err(DbError::Cancelled) => {
                    return self.emit_call(call_id, conn_id, "cancelled", elapsed(started));
                }
                Err(error) => {
                    let error = error.to_string();
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
                    self.session.store_run(kept);
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

        let call = Call::new(call_id, conn_id, result)
            .with_dialect(Some(connection.backend.dialect()))
            .with_parameters(parameters);
        let mut payload = summarize(&call, true);
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

        let mut stored = self
            .session
            .store_run(kept.into_iter().chain(std::iter::once(call)).collect());
        let call = stored.pop().expect("the run's last call was stored");
        drop(running);
        self.emit_call(call_id, conn_id, "done", payload);

        for (index, path) in saves {
            save(path, Arc::clone(&stored[index]));
        }
        if let Some(path) = archive {
            save(path, call);
        }
    }

    /// An earlier statement's result as a call of its own, and how the editor sees it.
    fn keep(
        &self,
        conn_id: ConnId,
        result: ResultSet,
        saved_dialect: Option<Dialect>,
    ) -> (Call, Vec<(&'static str, Value)>) {
        let elapsed_ms = result.elapsed().as_millis() as u64;
        let call = Call::new(self.session.next_call_id(), conn_id, result);
        let dialect = self
            .session
            .connection(conn_id)
            .map(|connection| connection.backend.dialect());
        let call = call.with_dialect(dialect.or(saved_dialect));
        let mut summary = summarize(&call, dialect.is_some());
        summary.push(("state", Value::from("done")));
        summary.push(("elapsed_ms", Value::from(elapsed_ms)));
        (call, summary)
    }

    /// Read a result saved by an earlier `execute` back into the session.
    pub(super) fn restore(self: Arc<Self>, args: &Args) -> Started {
        let path = PathBuf::from(args.string("path")?);
        // The results of the run's earlier statements, saved beside its own.
        let others: Vec<PathBuf> = args
            .opt_strings("others")?
            .unwrap_or_default()
            .into_iter()
            .map(PathBuf::from)
            .collect();
        // The connection it ran on, when that is open.
        let conn_id = ConnId(args.opt_integer("conn_id").unwrap_or(0));
        let saved_dialect = args
            .opt_string("dialect")
            .and_then(|name| Dialect::from_url(&format!("{name}:")));
        let call_id = self.session.next_call_id();

        let work = async move {
            let read = tokio::task::spawn_blocking(move || {
                let others: Vec<(PathBuf, Result<ResultSet, String>)> = others
                    .into_iter()
                    .map(|other| {
                        let read = archive::read(&other);
                        (other, read)
                    })
                    .collect();
                (archive::read(&path), others)
            })
            .await;
            let (result, others) = match read {
                Ok((Ok(result), others)) => (result, others),
                Ok((Err(error), _)) => {
                    let payload = vec![("error", Value::from(error))];
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
                Err(error) => {
                    let error = format!("the saved result could not be read: {error}");
                    let payload = vec![("error", Value::from(error))];
                    return self.emit_call(call_id, conn_id, "error", payload);
                }
            };

            let mut kept = Vec::new();
            let mut earlier = Vec::new();
            // An earlier result whose file has gone is left out.
            for (other, read) in others {
                if let Ok(result) = read {
                    let (call, mut summary) = self.keep(conn_id, result, saved_dialect);
                    summary.push(("archive", Value::from(other.display().to_string())));
                    kept.push(call);
                    earlier.push(map(summary));
                }
            }

            let elapsed_ms = result.elapsed().as_millis() as u64;
            let open = self
                .session
                .connection(conn_id)
                .map(|connection| connection.backend.dialect());
            let call = Call::new(call_id, conn_id, result).with_dialect(open.or(saved_dialect));
            let mut payload = summarize(&call, open.is_some());
            payload.push(("elapsed_ms", Value::from(elapsed_ms)));
            if !earlier.is_empty() {
                let mut current = payload.clone();
                current.push(("state", Value::from("done")));
                earlier.push(map(current));
                payload.push(("results", Value::Array(earlier)));
            }

            self.session
                .store_run(kept.into_iter().chain(std::iter::once(call)).collect());
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

        self.session
            .with_call(call_id, |call| view::condition(&call.result, row, column))
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

    /// Capabilities are live: a saved result may lose its connection after its summary was sent.
    pub(super) fn result_capabilities(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;
        Ok(capabilities(self.session.connection(conn_id).is_some()))
    }

    /// Narrow and order the rows of a stored result, for the grid to page through.
    pub(super) fn view(self: Arc<Self>, args: &Args) -> Started {
        let call_id = args.call_id()?;
        let filters = params::filters(args.get("filters"))?;
        let sort = params::sort(args.get("sort"));
        let scope = params::indices(args.get("rows"));
        let condition = args.opt_string("where").unwrap_or_default();
        let order = args.opt_string("order_by").unwrap_or_default();
        // Compiled first, so a mistake in the filter is answered before any work starts.
        let call = self
            .session
            .call(call_id)
            .ok_or_else(|| format!("result {call_id} is no longer held"))?;
        let query = view::Query::parse(&condition, &order, &view::names(call.result.columns()))?;
        // Reserve ordering before returning the RPC reply, not when a worker starts.
        let generation = call.begin_view();

        let work = async move {
            // Clone the result handle under the history lock, then release it before Polars work.
            let retained = Arc::clone(&call);
            let built = tokio::task::spawn_blocking(move || {
                let call = retained;
                let narrowed =
                    !filters.is_empty() || !sort.is_empty() || scope.is_some() || query.is_some();
                let view = if narrowed {
                    Some(Arc::new(view::select_with(
                        &call.result,
                        &filters,
                        &sort,
                        scope.as_deref(),
                        query.as_ref(),
                    )?))
                } else {
                    None
                };
                Ok::<_, String>(view)
            })
            .await;

            call.finish_view(generation, || {
                let mut payload = vec![("call_id", Value::from(call_id))];
                match built {
                    Ok(Ok(view)) => {
                        let rows = view
                            .as_ref()
                            .map_or(call.result.row_count(), |view| view.len());
                        *call.view.lock().expect("view poisoned") = view;
                        payload.push(("rows", Value::from(rows as u64)));
                    }
                    Ok(Err(error)) => payload.push(("error", Value::from(error))),
                    Err(error) => payload.push(("error", Value::from(error.to_string()))),
                }
                self.emit("call:view", map(payload));
            });
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

/// Where a run's `index`th earlier result is saved, beside the run's own.
fn sibling(path: &Path, index: usize) -> PathBuf {
    let stem = path
        .file_stem()
        .map_or_else(String::new, |stem| stem.to_string_lossy().into_owned());
    let extension = path.extension().map_or_else(String::new, |extension| {
        format!(".{}", extension.to_string_lossy())
    });
    path.with_file_name(format!("{stem}-{index}{extension}"))
}

fn elapsed(started: Instant) -> Vec<(&'static str, Value)> {
    vec![(
        "elapsed_ms",
        Value::from(started.elapsed().as_millis() as u64),
    )]
}
