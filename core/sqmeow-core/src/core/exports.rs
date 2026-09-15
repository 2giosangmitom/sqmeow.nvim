//! Exporting results as CSV, JSON or SQL.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::Dialect;
use sqmeow_db::export::{self, Format, Rows};

use super::{Core, Started, params};
use crate::args::Args;
use crate::session::{Call, CallId};
use crate::value::map;

/// The most rows an export preview renders: enough to see what the file will look like.
const PREVIEW_ROWS: usize = 100;

impl Core {
    pub(super) fn export(self: Arc<Self>, args: &Args) -> Started {
        let call_id = args.call_id()?;
        let format = self.format(args, call_id)?;
        let every = args.opt_bool("all").unwrap_or(false);
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
        let columns = params::indices(args.get("columns"));
        self.held(call_id)?;

        let work = self.write_export(call_id, format, (rows, every), columns, headers, path);
        Ok((Value::from(call_id), Box::pin(work)))
    }

    /// The start of an export, as the text it would write, for the export dialog to show.
    pub(super) fn export_preview(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let format = self.format(args, call_id)?;
        let start = args.opt_usize("offset").unwrap_or(0);
        let limit = args
            .opt_usize("limit")
            .unwrap_or(usize::MAX)
            .min(PREVIEW_ROWS);
        let headers = args.opt_bool("headers").unwrap_or(true);
        let every = args.opt_bool("all").unwrap_or(false);
        let columns = params::indices(args.get("columns"));

        self.session
            .with_call(call_id, |call| {
                let rows = Rows {
                    start,
                    end: start.saturating_add(limit),
                }
                .resolve(
                    &call.result,
                    shown(call, every).as_deref().map(Vec::as_slice),
                );
                Value::from(export::write(
                    &call.result,
                    &format,
                    &rows,
                    columns.as_deref(),
                    headers,
                ))
            })
            .ok_or_else(|| format!("result {call_id} is no longer held"))
    }

    /// Render part of a result and write it to a file, or hand the text back.
    async fn write_export(
        self: Arc<Self>,
        call_id: CallId,
        format: Format,
        (rows, every): (Rows, bool),
        columns: Option<Vec<usize>>,
        headers: bool,
        path: Option<String>,
    ) {
        let Some((text, count)) = self.session.with_call(call_id, |call| {
            let rows = rows.resolve(
                &call.result,
                shown(call, every).as_deref().map(Vec::as_slice),
            );
            let text = export::write(&call.result, &format, &rows, columns.as_deref(), headers);
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

    /// The format asked for, with SQL written in the dialect of the connection the rows came from.
    fn format(&self, args: &Args, call_id: CallId) -> Result<Format, String> {
        let mut format = params::format(args)?;
        if let Format::Sql(sql) = &mut format {
            // A result from the log names its dialect, since its connection may not be open.
            let open = self
                .session
                .with_call(call_id, |call| call.conn_id)
                .and_then(|conn_id| self.session.connection(conn_id))
                .map(|connection| connection.backend.dialect());
            sql.dialect = open
                .or_else(|| Dialect::from_url(&format!("{}:", args.opt_string("dialect")?)))
                .unwrap_or(Dialect::Postgres);
            if matches!(sql.dialect, Dialect::Redis | Dialect::MongoDb) {
                return Err(format!(
                    "{} results cannot be exported as SQL",
                    sql.dialect.name()
                ));
            }
            sql.table = args
                .opt_string("table")
                .filter(|table| !table.trim().is_empty());
            sql.batch = args.opt_bool("batch").unwrap_or(false);
            sql.create = args.opt_bool("create").unwrap_or(false);
        }
        Ok(format)
    }

    fn emit_export(&self, call_id: CallId, outcome: Result<Vec<(&str, Value)>, String>) {
        let mut payload = vec![("call_id", Value::from(call_id))];
        match outcome {
            Ok(fields) => payload.extend(fields),
            Err(error) => payload.push(("error", Value::from(error))),
        }
        self.emit("export:done", map(payload));
    }
}

/// The rows positions count through: the view, unless every row is wanted.
fn shown(call: &Call, every: bool) -> Option<Arc<Vec<usize>>> {
    if every { None } else { call.view() }
}
