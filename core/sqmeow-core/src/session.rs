//! Everything one editor session holds: its connections, its results, and the options the plugin
//! configured.
//!
//! Results outlive the query that produced them. A user can page through an earlier result while a
//! new query runs, and reopen one from the call log, so finished results stay until the history
//! cap pushes them out.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use sqmeow_adapters::Backend;
use sqmeow_db::{CatalogEntry, ResultSet};
use sqmeow_render::{GridOptions, GridStylePatch, Layout};
use tokio_util::sync::CancellationToken;

/// Engine-side settings, mirrored from the plugin's configuration.
#[derive(Debug, Clone)]
pub struct Options {
    pub max_rows: usize,
    pub history_size: usize,
    pub grid: GridOptions,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_rows: 100_000,
            history_size: 32,
            grid: GridOptions::default(),
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
        if let Some(value) = other.page_size {
            self.grid.page_size = value.max(1);
        }
        if let Some(value) = other.max_column_width {
            self.grid.max_column_width = value.max(sqmeow_render::grid::MIN_COLUMN_WIDTH);
        }
        if let Some(value) = other.null_text {
            self.grid.null_text = value;
        }
        self.grid.style.update(other.style);
    }
}

/// The settings one `configure` call carries. Absent fields are left unchanged.
#[derive(Debug, Default)]
pub struct OptionsPatch {
    pub max_rows: Option<usize>,
    pub history_size: Option<usize>,
    pub page_size: Option<usize>,
    pub max_column_width: Option<usize>,
    pub null_text: Option<String>,
    pub style: GridStylePatch,
}

/// One open connection.
#[derive(Debug)]
pub struct Connection {
    pub id: i64,
    pub name: String,
    pub backend: Backend,
    /// Every relation in every schema, once something has asked for it.
    ///
    /// The drawer reads one level at a time, but the relation picker searches the whole
    /// connection, and building that list costs one query per schema. Holding it here means the
    /// picker is instant every time after the first, and an explicit refresh is what re-reads it.
    catalog: Mutex<Option<Arc<Vec<CatalogEntry>>>>,
}

impl Connection {
    /// Record an open connection, with nothing introspected yet.
    pub fn new(id: i64, name: String, backend: Backend) -> Self {
        Self {
            id,
            name,
            backend,
            catalog: Mutex::new(None),
        }
    }

    /// The catalog, if it has already been read.
    pub fn cached_catalog(&self) -> Option<Arc<Vec<CatalogEntry>>> {
        self.catalog.lock().expect("catalog lock").clone()
    }

    /// Remember a catalog, replacing any earlier one.
    pub fn store_catalog(&self, entries: Vec<CatalogEntry>) -> Arc<Vec<CatalogEntry>> {
        let entries = Arc::new(entries);
        *self.catalog.lock().expect("catalog lock") = Some(Arc::clone(&entries));
        entries
    }

    /// Drop the cached catalog, so the next read goes back to the server.
    pub fn forget_catalog(&self) {
        *self.catalog.lock().expect("catalog lock") = None;
    }
}

/// A finished result, kept so it can be paged and reopened.
#[derive(Debug)]
pub struct Call {
    pub id: u64,
    pub conn_id: i64,
    pub result: ResultSet,
    pub layout: Layout,
    /// The row the current page starts at.
    pub offset: usize,
}

impl Call {
    /// Clamp an offset to a page boundary that exists.
    ///
    /// Paging past either end settles on the last or first page rather than emptying the view,
    /// which is what `L` at the end of a result should do.
    pub fn clamp_offset(&self, offset: usize, page_size: usize) -> usize {
        if page_size == 0 || self.result.row_count() == 0 {
            return 0;
        }
        let last_page = (self.result.page_count(page_size) - 1) * page_size;
        offset.min(last_page)
    }

    /// Which page the current offset is, counting from one.
    pub fn page_number(&self, page_size: usize) -> usize {
        if page_size == 0 {
            return 1;
        }
        self.offset / page_size + 1
    }
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
    calls: HashMap<u64, Call>,
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
    pub fn store_call(&self, call: Call) {
        let limit = self.options().history_size.max(1);
        let mut history = self.calls.lock().expect("calls poisoned");

        history.order.push_back(call.id);
        history.calls.insert(call.id, call);

        while history.order.len() > limit {
            if let Some(evicted) = history.order.pop_front() {
                history.calls.remove(&evicted);
            }
        }
    }

    /// Read a stored result.
    pub fn with_call<T>(&self, call_id: u64, read: impl FnOnce(&Call) -> T) -> Option<T> {
        let history = self.calls.lock().expect("calls poisoned");
        history.calls.get(&call_id).map(read)
    }

    /// Move a stored result's page, returning the offset it settled on.
    pub fn seek_call(&self, call_id: u64, offset: usize, page_size: usize) -> Option<usize> {
        let mut history = self.calls.lock().expect("calls poisoned");
        let call = history.calls.get_mut(&call_id)?;
        call.offset = call.clamp_offset(offset, page_size);
        Some(call.offset)
    }
}

#[cfg(test)]
mod tests {
    use sqmeow_db::{Cell, Column};

    use super::*;

    fn call(id: u64, rows: usize) -> Call {
        let mut result = ResultSet::new(
            "select n",
            vec![Column {
                name: "n".into(),
                type_name: "INTEGER".into(),
            }],
        );
        for n in 0..rows {
            result.push_row(vec![Cell::Int(n as i64)]);
        }
        let layout = Layout::measure(&result, &GridOptions::default());
        Call {
            id,
            conn_id: 1,
            result,
            layout,
            offset: 0,
        }
    }

    async fn connection() -> Connection {
        let backend = Backend::connect("sqlite::memory:")
            .await
            .expect("an in-memory database should open");
        Connection::new(1, "scratch".into(), backend)
    }

    fn entry(name: &str) -> CatalogEntry {
        CatalogEntry {
            schema: "main".into(),
            name: name.into(),
            kind: sqmeow_db::RelationKind::Table,
        }
    }

    #[tokio::test]
    async fn a_connection_starts_with_no_catalog() {
        assert!(connection().await.cached_catalog().is_none());
    }

    #[tokio::test]
    async fn a_catalog_is_remembered_once_it_has_been_read() {
        let connection = connection().await;
        connection.store_catalog(vec![entry("people")]);

        let cached = connection
            .cached_catalog()
            .expect("the catalog should be held");
        assert_eq!(cached.len(), 1);
        assert_eq!(cached[0].name, "people");
    }

    #[tokio::test]
    async fn storing_a_catalog_replaces_the_one_before_it() {
        let connection = connection().await;
        connection.store_catalog(vec![entry("people")]);
        connection.store_catalog(vec![entry("people"), entry("orders")]);

        assert_eq!(connection.cached_catalog().expect("held").len(), 2);
    }

    #[tokio::test]
    async fn forgetting_a_catalog_sends_the_next_read_back_to_the_server() {
        let connection = connection().await;
        connection.store_catalog(vec![entry("people")]);
        connection.forget_catalog();

        assert!(connection.cached_catalog().is_none());
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
        assert_eq!(options.grid.page_size, 100);
    }

    #[test]
    fn configure_changes_only_what_it_names() {
        let session = Session::default();
        let options = session.configure(OptionsPatch {
            page_size: Some(25),
            ..OptionsPatch::default()
        });

        assert_eq!(options.grid.page_size, 25);
        assert_eq!(options.max_rows, 100_000);
        assert_eq!(options.grid.null_text, "NULL");
    }

    #[test]
    fn configure_carries_the_grid_characters() {
        let session = Session::default();
        let options = session.configure(OptionsPatch {
            style: GridStylePatch {
                vertical: Some("!".to_owned()),
                // Three columns wide, so it is dropped and the default rule survives.
                cross: Some("-+-".to_owned()),
                ..GridStylePatch::default()
            },
            ..OptionsPatch::default()
        });

        assert_eq!(options.grid.style.vertical, "!");
        assert_eq!(options.grid.style.cross, "┼");
    }

    #[test]
    fn configure_refuses_nonsense_values() {
        let session = Session::default();
        let options = session.configure(OptionsPatch {
            page_size: Some(0),
            history_size: Some(0),
            max_column_width: Some(1),
            ..OptionsPatch::default()
        });

        assert_eq!(options.grid.page_size, 1);
        assert_eq!(options.history_size, 1);
        assert_eq!(
            options.grid.max_column_width,
            sqmeow_render::grid::MIN_COLUMN_WIDTH
        );
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
    fn paging_stops_at_the_last_page() {
        let session = Session::default();
        session.store_call(call(1, 250));

        assert_eq!(session.seek_call(1, 100, 100), Some(100));
        // Past the end settles on the last page rather than emptying the view.
        assert_eq!(session.seek_call(1, 9_000, 100), Some(200));
    }

    #[test]
    fn paging_an_empty_result_stays_at_the_start() {
        let session = Session::default();
        session.store_call(call(1, 0));
        assert_eq!(session.seek_call(1, 500, 100), Some(0));
    }

    #[test]
    fn paging_an_unknown_call_is_none() {
        assert_eq!(Session::default().seek_call(99, 0, 100), None);
    }

    #[test]
    fn page_numbers_count_from_one() {
        let mut record = call(1, 250);
        assert_eq!(record.page_number(100), 1);
        record.offset = 200;
        assert_eq!(record.page_number(100), 3);
    }

    #[test]
    fn an_empty_session_has_no_connections() {
        let session = Session::default();
        assert!(session.connection(1).is_none());
        assert!(session.describe_connections().is_empty());
        assert!(session.remove_connection(1).is_none());
    }
}
