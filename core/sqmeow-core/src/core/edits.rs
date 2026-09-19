//! Planning and applying edits to a result.

use std::sync::Arc;

use rmpv::Value;

use sqmeow_db::Error as DbError;

use super::calls::Deadline;
use super::{Core, Started, params};
use crate::args::Args;
use crate::value::{map, strings};

impl Core {
    /// Plan staged changes to a stored result into the statements that make them, for review.
    pub(super) fn plan(&self, args: &Args) -> Result<Value, String> {
        let call_id = args.call_id()?;
        let changes = params::changes(args.get("changes"))?;
        let gone = || format!("result {call_id} is no longer held");

        let conn_id = self
            .session
            .with_call(call_id, |call| call.conn_id)
            .ok_or_else(gone)?;
        let connection = self.session.connection(conn_id).ok_or_else(|| {
            "the connection this result came from is not open, so it cannot be edited".to_owned()
        })?;
        if connection.read_only {
            return Err(read_only(&connection.name));
        }
        let statements = self
            .session
            .with_call(call_id, |call| {
                connection.backend.plan(&call.result, &changes)
            })
            .ok_or_else(gone)?
            .map_err(|error| error.to_string())?;
        Ok(strings(statements))
    }

    /// Run the statements a review approved, together, and report through `apply:done`. A cancel
    /// of the result's call id, or `query.timeout_ms`, stops them.
    pub(super) fn apply(self: Arc<Self>, args: &Args) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        let call_id = args.call_id()?;
        let statements = args.opt_strings("statements")?.unwrap_or_default();
        if statements.is_empty() {
            return Err("there is nothing to apply".to_owned());
        }
        let connection = self.connection(conn_id)?;
        if connection.read_only {
            return Err(read_only(&connection.name));
        }

        let work = async move {
            let mut payload = vec![
                ("conn_id", Value::from(conn_id)),
                ("statements", Value::from(statements.len() as u64)),
            ];
            let running = self.session.begin_call(call_id);
            let timeout_ms = self.session.options().timeout_ms;
            let deadline = Deadline::start(running.token(), timeout_ms);
            let outcome = connection.backend.apply(&statements, running.token()).await;
            drop(running);
            match outcome {
                Ok(returned) => self.session.stash_inserted(conn_id, returned),
                Err(DbError::Cancelled) if deadline.passed() => payload.push((
                    "error",
                    Value::from(format!(
                        "nothing was applied: it ran past the {timeout_ms} ms timeout, so it was cancelled"
                    )),
                )),
                Err(DbError::Cancelled) => payload.push((
                    "error",
                    Value::from("nothing was applied: it was cancelled"),
                )),
                Err(error) => payload.push(("error", Value::from(error.to_string()))),
            }
            self.emit("apply:done", map(payload));
        };
        Ok((Value::from(conn_id), Box::pin(work)))
    }
}

fn read_only(name: &str) -> String {
    format!("`{name}` is read-only, so its results cannot be edited")
}
