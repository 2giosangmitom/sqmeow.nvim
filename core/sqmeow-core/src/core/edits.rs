//! Planning and applying edits to a result.

use std::sync::Arc;

use rmpv::Value;

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

    /// Run the statements a review approved, together, and report through `apply:done`.
    pub(super) fn apply(self: Arc<Self>, args: &Args) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        let statements = args.opt_strings("statements").unwrap_or_default();
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
            if let Err(error) = connection.backend.apply(&statements).await {
                payload.push(("error", Value::from(error.to_string())));
            }
            self.emit("apply:done", map(payload));
        };
        Ok((Value::from(conn_id), Box::pin(work)))
    }
}

fn read_only(name: &str) -> String {
    format!("`{name}` is read-only, so its results cannot be edited")
}
