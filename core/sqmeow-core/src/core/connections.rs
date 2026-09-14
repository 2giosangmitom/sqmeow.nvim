//! Opening and closing connections.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_adapters::Backend;

use super::{Core, Started};
use crate::args::Args;
use crate::session::{ConnId, Connection};
use crate::value::map;

impl Core {
    /// An open connection, or the error for one that is not.
    pub(super) fn connection(&self, id: ConnId) -> Result<Arc<Connection>, String> {
        self.session
            .connection(id)
            .ok_or_else(|| format!("no connection with id {id}"))
    }

    pub(super) fn connect(self: Arc<Self>, args: &Args) -> Started {
        let id = args.conn_id("id")?;
        let url = args.string("url")?;
        let name = args
            .opt_string("name")
            .unwrap_or_else(|| format!("connection {id}"));
        // One database of a cluster the URL reaches as a whole, opened from the drawer.
        let database = args.opt_string("database");

        let work = self.open(id, name, url, database);
        Ok((Value::from(id), Box::pin(work)))
    }

    async fn open(
        self: Arc<Self>,
        id: ConnId,
        name: String,
        url: String,
        database: Option<String>,
    ) {
        self.emit_connection(id, "connecting", vec![("name", Value::from(name.as_str()))]);

        // The expanded URL holds the password and never leaves this function.
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
                let mut payload = vec![
                    ("name", Value::from(name.as_str())),
                    ("dialect", Value::from(backend.dialect().name())),
                ];
                // Which database a MongoDB connection starts on, for the winbar.
                if let Some(database) = backend.database() {
                    payload.push(("current_database", Value::from(database)));
                }
                self.session
                    .insert_connection(Connection { id, name, backend });
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

    pub(super) fn disconnect(self: Arc<Self>, args: &Args) -> Started {
        let id = args.conn_id("id")?;
        let connection = self.session.remove_connection(id);
        let answer = Value::from(connection.is_some());

        let work = async move {
            if let Some(connection) = connection {
                connection.backend.close().await;
                self.emit_connection(id, "closed", vec![]);
            }
        };
        Ok((answer, Box::pin(work)))
    }

    fn emit_connection(&self, id: ConnId, state: &str, extra: Vec<(&str, Value)>) {
        let mut pairs = vec![("id", Value::from(id)), ("state", Value::from(state))];
        pairs.extend(extra);
        self.emit("conn:state", map(pairs));
    }
}
