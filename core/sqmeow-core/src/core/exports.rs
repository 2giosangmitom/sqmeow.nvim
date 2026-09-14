//! Exporting results as CSV or JSON.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::export::{self, Format, Rows};

use super::{Core, Started, params};
use crate::args::Args;
use crate::session::CallId;
use crate::value::map;

/// The most rows an export preview renders: enough to see what the file will look like.
const PREVIEW_ROWS: usize = 100;

impl Core {
    pub(super) fn export(self: Arc<Self>, args: &Args) -> Started {
        let call_id = args.call_id()?;
        let format = params::format(args)?;
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

        let work = self.write_export(call_id, format, rows, columns, headers, path);
        Ok((Value::from(call_id), Box::pin(work)))
    }

    /// The start of an export, as the text it would write, for the export dialog to show.
    pub(super) fn export_preview(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let format = params::format(args)?;
        let start = args.opt_usize("offset").unwrap_or(0);
        let limit = args
            .opt_usize("limit")
            .unwrap_or(usize::MAX)
            .min(PREVIEW_ROWS);
        let headers = args.opt_bool("headers").unwrap_or(true);
        let columns = params::indices(args.get("columns"));

        self.session
            .with_call(call_id, |call| {
                let rows = Rows {
                    start,
                    end: start.saturating_add(limit),
                }
                .resolve(&call.result, call.view().as_deref().map(Vec::as_slice));
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

    /// Render part of a result and write it to a file, or hand the text back.
    async fn write_export(
        self: Arc<Self>,
        call_id: CallId,
        format: Format,
        rows: Rows,
        columns: Option<Vec<usize>>,
        headers: bool,
        path: Option<String>,
    ) {
        let Some((text, count)) = self.session.with_call(call_id, |call| {
            let rows = rows.resolve(&call.result, call.view().as_deref().map(Vec::as_slice));
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

    fn emit_export(&self, call_id: CallId, outcome: Result<Vec<(&str, Value)>, String>) {
        let mut payload = vec![("call_id", Value::from(call_id))];
        match outcome {
            Ok(fields) => payload.extend(fields),
            Err(error) => payload.push(("error", Value::from(error))),
        }
        self.emit("export:done", map(payload));
    }
}
