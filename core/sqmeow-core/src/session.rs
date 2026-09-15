//! Everything one editor session holds.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use rmpv::Value;
use sqmeow_adapters::Backend;
use sqmeow_db::ResultSet;
use tokio_util::sync::CancellationToken;

/// The id the plugin gave a connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ConnId(pub i64);

/// The id of one run of statements, and of the result it keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CallId(pub u64);

impl std::fmt::Display for ConnId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl std::fmt::Display for CallId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl From<ConnId> for Value {
    fn from(id: ConnId) -> Self {
        Value::from(id.0)
    }
}

impl From<CallId> for Value {
    fn from(id: CallId) -> Self {
        Value::from(id.0)
    }
}

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
    pub id: ConnId,
    pub name: String,
    pub backend: Backend,
    /// Runs only statements that read, and takes no edits.
    pub read_only: bool,
}

/// A finished result, kept so its rows can be read and reopened.
#[derive(Debug)]
pub struct Call {
    pub id: CallId,
    pub conn_id: ConnId,
    pub result: ResultSet,
    /// The rows the editor is paging through, when it filtered or sorted them.
    pub view: Mutex<Option<Arc<Vec<usize>>>>,
}

impl Call {
    pub fn new(id: CallId, conn_id: ConnId, result: ResultSet) -> Self {
        Self {
            id,
            conn_id,
            result,
            view: Mutex::default(),
        }
    }

    /// The rows the editor pages through: the view when there is one.
    pub fn view(&self) -> Option<Arc<Vec<usize>>> {
        self.view.lock().expect("view poisoned").clone()
    }
}

/// The state one editor session owns.
#[derive(Default)]
pub struct Session {
    connections: Mutex<HashMap<ConnId, Arc<Connection>>>,
    calls: Mutex<History>,
    running: Mutex<HashMap<CallId, CancellationToken>>,
    options: Mutex<Options>,
    next_call_id: AtomicU64,
    /// The rows the last applied inserts returned, by connection.
    inserted: Mutex<HashMap<ConnId, Vec<ResultSet>>>,
}

#[derive(Default)]
struct History {
    /// Shared, so a result can be saved to disk without holding the lock for as long as that takes.
    calls: HashMap<CallId, Arc<Call>>,
    /// Call ids oldest first, which is the order they are evicted in.
    order: VecDeque<CallId>,
}

/// A call registered as running, which stops being cancellable when dropped.
pub struct RunningCall<'a> {
    session: &'a Session,
    id: CallId,
    token: CancellationToken,
}

impl RunningCall<'_> {
    /// The token a cancel trips.
    pub fn token(&self) -> CancellationToken {
        self.token.clone()
    }
}

impl Drop for RunningCall<'_> {
    fn drop(&mut self) {
        if let Ok(mut running) = self.session.running.lock() {
            running.remove(&self.id);
        }
    }
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
    pub fn connection(&self, id: ConnId) -> Option<Arc<Connection>> {
        self.connections
            .lock()
            .expect("connections poisoned")
            .get(&id)
            .cloned()
    }

    /// Forget a connection, returning it so the caller can close its pool.
    pub fn remove_connection(&self, id: ConnId) -> Option<Arc<Connection>> {
        self.connections
            .lock()
            .expect("connections poisoned")
            .remove(&id)
    }

    /// Every open connection, by ascending id, as the editor sees them.
    pub fn describe_connections(&self) -> Vec<Value> {
        let mut connections: Vec<Arc<Connection>> = self
            .connections
            .lock()
            .expect("connections poisoned")
            .values()
            .cloned()
            .collect();
        connections.sort_unstable_by_key(|connection| connection.id);

        connections
            .iter()
            .map(|connection| {
                crate::value::map(vec![
                    ("id", Value::from(connection.id)),
                    ("name", Value::from(connection.name.as_str())),
                    ("dialect", Value::from(connection.backend.dialect().name())),
                    ("read_only", Value::from(connection.read_only)),
                ])
            })
            .collect()
    }

    /// Reserve the next call id.
    pub fn next_call_id(&self) -> CallId {
        CallId(self.next_call_id.fetch_add(1, Ordering::Relaxed) + 1)
    }

    /// Register a call that is about to run, until the returned guard drops.
    pub fn begin_call(&self, id: CallId) -> RunningCall<'_> {
        let token = CancellationToken::new();
        self.running
            .lock()
            .expect("running poisoned")
            .insert(id, token.clone());
        RunningCall {
            session: self,
            id,
            token,
        }
    }

    /// Cancel a running call. Returns whether there was one to cancel.
    pub fn cancel(&self, id: CallId) -> bool {
        match self.running.lock().expect("running poisoned").remove(&id) {
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

    /// Keep the rows applied inserts returned, for the connection's next run of its query.
    pub fn stash_inserted(&self, conn_id: ConnId, rows: Vec<ResultSet>) {
        self.inserted
            .lock()
            .expect("inserted poisoned")
            .insert(conn_id, rows);
    }

    /// Take the rows kept for a connection.
    pub fn take_inserted(&self, conn_id: ConnId) -> Vec<ResultSet> {
        self.inserted
            .lock()
            .expect("inserted poisoned")
            .remove(&conn_id)
            .unwrap_or_default()
    }

    /// Read a stored result.
    pub fn with_call<T>(&self, id: CallId, read: impl FnOnce(&Call) -> T) -> Option<T> {
        let history = self.calls.lock().expect("calls poisoned");
        history.calls.get(&id).map(|call| read(call))
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
        Call::new(CallId(id), ConnId(1), result)
    }

    #[test]
    fn call_ids_start_at_one_and_do_not_repeat() {
        let session = Session::default();
        assert_eq!(session.next_call_id(), CallId(1));
        assert_eq!(session.next_call_id(), CallId(2));
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
        assert!(!session.cancel(CallId(42)));
    }

    #[test]
    fn cancelling_a_running_call_trips_its_token() {
        let session = Session::default();
        let running = session.begin_call(CallId(1));
        assert!(session.cancel(CallId(1)));
        assert!(running.token().is_cancelled());
        // A call can only be cancelled once.
        assert!(!session.cancel(CallId(1)));
    }

    #[test]
    fn a_finished_call_can_no_longer_be_cancelled() {
        let session = Session::default();
        drop(session.begin_call(CallId(1)));
        assert!(!session.cancel(CallId(1)));
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

        assert!(session.with_call(CallId(1), |_| ()).is_none());
        assert!(session.with_call(CallId(2), |_| ()).is_some());
        assert!(session.with_call(CallId(3), |_| ()).is_some());
    }

    #[test]
    fn a_stored_result_keeps_every_row_for_the_editor_to_ask_for() {
        let session = Session::default();
        session.store_call(call(1, 250));

        assert_eq!(
            session.with_call(CallId(1), |call| call.result.row_count()),
            Some(250)
        );
    }

    #[test]
    fn an_empty_session_has_no_connections() {
        let session = Session::default();
        assert!(session.connection(ConnId(1)).is_none());
        assert!(session.describe_connections().is_empty());
        assert!(session.remove_connection(ConnId(1)).is_none());
    }
}
