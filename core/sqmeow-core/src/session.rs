//! Everything one editor session holds.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use sqmeow_adapters::Backend;
use sqmeow_db::ResultSet;
use tokio_util::sync::CancellationToken;

/// Engine-side settings, mirrored from the plugin's configuration.
#[derive(Debug, Clone)]
pub struct Options {
    pub max_rows: usize,
    pub history_size: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_rows: 100_000,
            history_size: 32,
        }
    }
}

impl Options {
    /// Apply the subset of settings the plugin sent, leaving the rest alone.
    pub fn update(&mut self, other: OptionsPatch) {
        if let Some(value) = other.max_rows {
            self.max_rows = value;
        }
        if let Some(value) = other.history_size {
            self.history_size = value.max(1);
        }
    }
}

/// The settings one `configure` call carries. Absent fields are left unchanged.
#[derive(Debug, Default)]
pub struct OptionsPatch {
    pub max_rows: Option<usize>,
    pub history_size: Option<usize>,
}

/// One open connection.
#[derive(Debug)]
pub struct Connection {
    pub id: i64,
    pub name: String,
    pub backend: Backend,
}

impl Connection {
    /// Record an open connection, with nothing introspected yet.
    pub fn new(id: i64, name: String, backend: Backend) -> Self {
        Self { id, name, backend }
    }
}

/// A finished result, kept so its rows can be read and reopened.
#[derive(Debug)]
pub struct Call {
    pub id: u64,
    pub conn_id: i64,
    pub result: ResultSet,
    /// The rows the editor is paging through, when it filtered or sorted them.
    pub view: Mutex<Option<Arc<Vec<usize>>>>,
}

/// The state one editor session owns.
#[derive(Default)]
pub struct Session {
    connections: Mutex<HashMap<i64, Arc<Connection>>>,
    calls: Mutex<History>,
    running: Mutex<HashMap<u64, CancellationToken>>,
    options: Mutex<Options>,
    next_call_id: AtomicU64,
}

#[derive(Default)]
struct History {
    /// Shared, so a result can be saved to disk without holding the lock for as long as that takes.
    calls: HashMap<u64, Arc<Call>>,
    /// Call ids oldest first, which is the order they are evicted in.
    order: VecDeque<u64>,
}

impl Session {
    /// The current options.
    pub fn options(&self) -> Options {
        self.options.lock().expect("options poisoned").clone()
    }

    /// Apply a settings patch from the plugin.
    pub fn configure(&self, patch: OptionsPatch) -> Options {
        let mut options = self.options.lock().expect("options poisoned");
        options.update(patch);
        options.clone()
    }

    /// Register an open connection, replacing any connection with the same id.
    pub fn insert_connection(&self, connection: Connection) {
        self.connections
            .lock()
            .expect("connections poisoned")
            .insert(connection.id, Arc::new(connection));
    }

    /// Look up a connection.
    pub fn connection(&self, id: i64) -> Option<Arc<Connection>> {
        self.connections
            .lock()
            .expect("connections poisoned")
            .get(&id)
            .cloned()
    }

    /// Forget a connection, returning it so the caller can close its pool.
    pub fn remove_connection(&self, id: i64) -> Option<Arc<Connection>> {
        self.connections
            .lock()
            .expect("connections poisoned")
            .remove(&id)
    }

    /// Every open connection, by ascending id, as the editor sees them.
    pub fn describe_connections(&self) -> Vec<rmpv::Value> {
        let mut connections: Vec<Arc<Connection>> = self
            .connections
            .lock()
            .expect("connections poisoned")
            .values()
            .cloned()
            .collect();
        connections.sort_unstable_by_key(|connection| connection.id);

        connections
            .into_iter()
            .map(|connection| {
                crate::value::map(vec![
                    ("id", rmpv::Value::from(connection.id)),
                    ("name", rmpv::Value::from(connection.name.clone())),
                    (
                        "dialect",
                        rmpv::Value::from(connection.backend.dialect().name()),
                    ),
                ])
            })
            .collect()
    }

    /// Reserve the next call id.
    pub fn next_call_id(&self) -> u64 {
        self.next_call_id.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// Register a cancellation token for a call that is about to run.
    pub fn begin_call(&self, call_id: u64) -> CancellationToken {
        let token = CancellationToken::new();
        self.running
            .lock()
            .expect("running poisoned")
            .insert(call_id, token.clone());
        token
    }

    /// Drop a call's cancellation token, once it is no longer running.
    pub fn end_call(&self, call_id: u64) {
        self.running
            .lock()
            .expect("running poisoned")
            .remove(&call_id);
    }

    /// Cancel a running call. Returns whether there was one to cancel.
    pub fn cancel(&self, call_id: u64) -> bool {
        match self
            .running
            .lock()
            .expect("running poisoned")
            .remove(&call_id)
        {
            Some(token) => {
                token.cancel();
                true
            }
            None => false,
        }
    }

    /// Store a finished result, evicting the oldest once the history is full.
    pub fn store_call(&self, call: Call) -> Arc<Call> {
        let limit = self.options().history_size.max(1);
        let mut history = self.calls.lock().expect("calls poisoned");

        let call = Arc::new(call);
        history.order.push_back(call.id);
        history.calls.insert(call.id, Arc::clone(&call));

        while history.order.len() > limit {
            if let Some(evicted) = history.order.pop_front() {
                history.calls.remove(&evicted);
            }
        }
        call
    }

    /// Read a stored result.
    pub fn with_call<T>(&self, call_id: u64, read: impl FnOnce(&Call) -> T) -> Option<T> {
        let history = self.calls.lock().expect("calls poisoned");
        history.calls.get(&call_id).map(|call| read(call))
    }
}

#[cfg(test)]
mod tests {
    use sqmeow_db::{Cell, Column};

    use super::*;

    fn call(id: u64, rows: usize) -> Call {
        let mut result = ResultSet::new("select n", vec![Column::new("n", "INTEGER")]);
        for n in 0..rows {
            result.push_row(vec![Cell::Int(n as i64)]);
        }
        Call {
            id,
            conn_id: 1,
            result,
            view: Default::default(),
        }
    }

    #[test]
    fn call_ids_start_at_one_and_do_not_repeat() {
        let session = Session::default();
        assert_eq!(session.next_call_id(), 1);
        assert_eq!(session.next_call_id(), 2);
    }

    #[test]
    fn options_start_at_the_documented_defaults() {
        let options = Session::default().options();
        assert_eq!(options.max_rows, 100_000);
        assert_eq!(options.history_size, 32);
    }

    #[test]
    fn configure_changes_only_what_it_names() {
        let session = Session::default();
        let options = session.configure(OptionsPatch {
            history_size: Some(8),
            ..OptionsPatch::default()
        });

        assert_eq!(options.history_size, 8);
        // Untouched by a patch that did not name it.
        assert_eq!(options.max_rows, 100_000);
    }

    #[test]
    fn configure_refuses_nonsense_values() {
        let session = Session::default();
        let options = session.configure(OptionsPatch {
            history_size: Some(0),
            ..OptionsPatch::default()
        });

        // Clamped rather than rejected, which is why `configure` echoes what it applied.
        assert_eq!(options.history_size, 1);
    }

    #[test]
    fn cancelling_an_unknown_call_says_so() {
        let session = Session::default();
        assert!(!session.cancel(42));
    }

    #[test]
    fn cancelling_a_running_call_trips_its_token() {
        let session = Session::default();
        let token = session.begin_call(1);
        assert!(session.cancel(1));
        assert!(token.is_cancelled());
        // A call can only be cancelled once.
        assert!(!session.cancel(1));
    }

    #[test]
    fn the_history_evicts_the_oldest_call() {
        let session = Session::default();
        session.configure(OptionsPatch {
            history_size: Some(2),
            ..OptionsPatch::default()
        });

        session.store_call(call(1, 1));
        session.store_call(call(2, 1));
        session.store_call(call(3, 1));

        assert!(session.with_call(1, |_| ()).is_none());
        assert!(session.with_call(2, |_| ()).is_some());
        assert!(session.with_call(3, |_| ()).is_some());
    }

    #[test]
    fn a_stored_result_keeps_every_row_for_the_editor_to_ask_for() {
        // Where the editor has got to is not recorded here any more.
        let session = Session::default();
        session.store_call(call(1, 250));

        assert_eq!(
            session.with_call(1, |call| call.result.row_count()),
            Some(250)
        );
    }

    #[test]
    fn an_empty_session_has_no_connections() {
        let session = Session::default();
        assert!(session.connection(1).is_none());
        assert!(session.describe_connections().is_empty());
        assert!(session.remove_connection(1).is_none());
    }
}
