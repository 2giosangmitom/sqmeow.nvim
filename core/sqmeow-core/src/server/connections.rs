//! Opening and closing connections.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_adapters::Backend;

use super::{Core, Started};
use crate::server::args::Args;
use crate::server::payload::map;
use crate::server::session::{ConnId, Connection};

/// Driver messages that mean the server or the link to it is gone.
const LOST: &[&str] = &[
    "connection closed",
    "connection refused",
    "connection reset",
    "broken pipe",
    "server closed the connection",
    "unexpected eof",
    "server has gone away",
    "lost connection",
    "pool closed",
];

/// The connection an event's error says is gone, with that error.
pub(super) fn lost_connection(event: &str, payload: &Value) -> Option<(ConnId, String)> {
    if event == "conn:state" {
        return None;
    }
    let Value::Map(pairs) = payload else {
        return None;
    };
    let field = |key: &str| {
        pairs
            .iter()
            .find(|(name, _)| name.as_str() == Some(key))
            .map(|(_, value)| value)
    };
    let error = field("error")?.as_str()?;
    let id = field("conn_id")?.as_i64()?;
    let lower = error.to_lowercase();
    LOST.iter()
        .any(|text| lower.contains(text))
        .then(|| (ConnId(id), error.to_owned()))
}

struct OpenOptions {
    database: Option<String>,
    read_only: bool,
    ssh: Option<String>,
    env_file: Option<std::path::PathBuf>,
}

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
        let read_only = args.opt_bool("read_only").unwrap_or(false);
        // `user@host[:port]` to reach the database through an SSH tunnel.
        let ssh = args.opt_string("ssh").filter(|via| !via.trim().is_empty());
        let env_file = match args.get("env_file") {
            None | Some(Value::Nil) => None,
            Some(_) => Some(std::path::PathBuf::from(args.string("env_file")?)),
        };

        let work = self.open(
            id,
            name,
            url,
            OpenOptions {
                database,
                read_only,
                ssh,
                env_file,
            },
        );
        Ok((Value::from(id), Box::pin(work)))
    }

    async fn open(self: Arc<Self>, id: ConnId, name: String, url: String, options: OpenOptions) {
        let OpenOptions {
            database,
            read_only,
            ssh,
            env_file,
        } = options;
        self.emit_connection(id, "connecting", vec![("name", Value::from(name.as_str()))]);

        // The expanded URL holds the password and never leaves this function.
        let templated = url.contains("{{");
        let expanded = match env_file.as_deref() {
            Some(path) => crate::server::template::expand_with_env_file(&url, Some(path)).await,
            None => crate::server::template::expand(&url).await,
        };
        let url = match expanded {
            Ok(url) => url,
            Err(error) => {
                return self.emit_connection(
                    id,
                    "error",
                    vec![("name", Value::from(name)), ("error", Value::from(error))],
                );
            }
        };

        let (url, tunnel) = match ssh {
            Some(via) => match crate::server::tunnel::open("ssh", &url, via.trim()).await {
                Ok((url, tunnel)) => (url, Some(tunnel)),
                Err(error) => {
                    return self.emit_connection(
                        id,
                        "error",
                        vec![("name", Value::from(name)), ("error", Value::from(error))],
                    );
                }
            },
            None => (url, None),
        };

        match Backend::connect_to(&url, database.as_deref(), read_only).await {
            Ok(backend) => {
                let mut payload = vec![
                    ("name", Value::from(name.as_str())),
                    ("dialect", Value::from(backend.dialect().name())),
                ];
                // Which database a MongoDB connection starts on, for the winbar.
                if let Some(database) = backend.database() {
                    payload.push(("current_database", Value::from(database)));
                }
                if read_only && backend.read_only_unenforced() {
                    payload.push((
                        "notice",
                        Value::from(
                            "this server has no read-only sessions, so only statements are checked",
                        ),
                    ));
                }
                self.session.insert_connection(Connection {
                    id,
                    name,
                    backend,
                    read_only,
                    _tunnel: tunnel,
                });
                self.emit_connection(id, "connected", payload);
            }
            Err(error) => self.emit_connection(
                id,
                "error",
                vec![
                    ("name", Value::from(name)),
                    (
                        "error",
                        Value::from(if templated {
                            error.to_string().replace(&url, "[resolved URL]")
                        } else {
                            error.to_string()
                        }),
                    ),
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

    /// Forget a connection whose server went away, so the editor can reconnect it.
    pub(super) fn drop_lost(&self, id: ConnId, error: String) {
        let Some(connection) = self.session.remove_connection(id) else {
            return;
        };
        tracing::info!(id = id.0, %error, "connection lost");
        self.emit_connection(
            id,
            "closed",
            vec![("lost", Value::from(true)), ("error", Value::from(error))],
        );
        tokio::spawn(async move { connection.backend.close().await });
    }

    fn emit_connection(&self, id: ConnId, state: &str, extra: Vec<(&str, Value)>) {
        let mut pairs = vec![("id", Value::from(id)), ("state", Value::from(state))];
        pairs.extend(extra);
        self.emit("conn:state", map(pairs));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(error: &str) -> Value {
        map(vec![
            ("conn_id", Value::from(3)),
            ("error", Value::from(error)),
        ])
    }

    #[test]
    fn lost_connection_errors_name_the_connection() {
        let (id, error) = lost_connection("schema:nodes", &event("connection closed")).unwrap();
        assert_eq!(id, ConnId(3));
        assert_eq!(error, "connection closed");
        assert!(lost_connection("call:state", &event("Broken pipe (os error 32)")).is_some());
    }

    #[test]
    fn other_errors_keep_the_connection() {
        assert!(lost_connection("call:state", &event("syntax error at or near")).is_none());
        assert!(lost_connection("conn:state", &event("connection refused")).is_none());
    }
}
