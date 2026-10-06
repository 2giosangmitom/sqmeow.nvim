//! Owned commands cross the async boundary; SQLite handles never do.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rusqlite::fallible_iterator::FallibleIterator;
use rusqlite::types::{Value as NativeValue, ValueRef};
use rusqlite::{Batch, Connection, InterruptHandle, OpenFlags, Statement};
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::{Source, TableBinder, TableName};
use sqmeow_db::error::{Error, Result};
use sqmeow_db::result::{Column, ResultSet};
use sqmeow_db::sql::parameters::Value;
use sqmeow_db::types::KeyKind;
use sqmeow_db::value::Cell;
use tokio::sync::{mpsc, oneshot, watch};
use tokio_util::sync::CancellationToken;

use crate::stream::{Keys, Origin, check_affected, rolled_back};

#[derive(Clone)]
pub(super) struct Options {
    uri: String,
    flags: OpenFlags,
    read_only: bool,
    pub(super) memory: bool,
}

impl Options {
    pub(super) fn parse(url: &str, read_only: bool) -> Result<Self> {
        let rest = url
            .strip_prefix("sqlite:")
            .ok_or_else(|| Error::driver("invalid SQLite URL"))?;
        let rest = rest.strip_prefix("//").unwrap_or(rest);
        let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
        // Decode before re-encoding as a SQLite URI, including relative paths and literal '?'.
        let path = percent_encoding::percent_decode_str(path)
            .decode_utf8()
            .map_err(Error::driver)?;
        let mut mode = if path == ":memory:" {
            "memory".to_owned()
        } else {
            "rw".to_owned()
        };
        let mut params = Vec::new();
        for (key, value) in url::form_urlencoded::parse(query.as_bytes()) {
            match key.as_ref() {
                "mode" if matches!(value.as_ref(), "rw" | "rwc" | "ro" | "memory") => {
                    mode = value.into_owned()
                }
                "cache" if matches!(value.as_ref(), "shared" | "private") => {
                    params.push((key.into_owned(), value.into_owned()))
                }
                "immutable" if matches!(value.as_ref(), "true" | "false" | "1" | "0") => params
                    .push((
                        key.into_owned(),
                        if matches!(value.as_ref(), "true" | "1") {
                            "1".into()
                        } else {
                            "0".into()
                        },
                    )),
                "vfs" if !value.is_empty() => params.push((key.into_owned(), value.into_owned())),
                _ => {
                    return Err(Error::driver(format!(
                        "unknown or invalid SQLite URL option: {key}={value}"
                    )));
                }
            }
        }
        let memory = mode == "memory" || path == ":memory:";
        if memory && path != ":memory:" && !params.iter().any(|(key, _)| key == "cache") {
            params.push(("cache".into(), "shared".into()));
        }
        let flags = OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | match mode.as_str() {
                "ro" => OpenFlags::SQLITE_OPEN_READ_ONLY,
                "rwc" | "memory" => {
                    OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE
                }
                _ => OpenFlags::SQLITE_OPEN_READ_WRITE,
            };
        let encoded =
            percent_encoding::utf8_percent_encode(&path, percent_encoding::NON_ALPHANUMERIC)
                .to_string();
        params.push(("mode".into(), mode));
        let query = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(params)
            .finish();
        Ok(Self {
            uri: format!("file:{encoded}?{query}"),
            flags,
            read_only,
            memory,
        })
    }

    fn open(&self) -> Result<Connection> {
        let conn = Connection::open_with_flags(&self.uri, self.flags).map_err(Error::driver)?;
        // Use prepare/Batch only (never prepare_cached), so DDL cannot leave stale columns.
        conn.execute_batch("pragma foreign_keys = ON")
            .map_err(Error::driver)?;
        if self.read_only {
            conn.execute_batch("pragma query_only = ON")
                .map_err(Error::driver)?;
        }
        // A thread-local cancellation-aware busy callback retains the normal five-second budget.
        conn.busy_handler(Some(busy)).map_err(Error::driver)?;
        Ok(conn)
    }
}

#[derive(Default)]
struct Active {
    generation: u64,
    interrupt: Option<InterruptHandle>,
    token: Option<CancellationToken>,
    cancellable: bool,
}

struct Shared {
    active: Mutex<Active>,
    stopping: AtomicBool,
    next: AtomicU64,
}

impl Shared {
    fn interrupt(&self, generation: u64) {
        let active = self.active.lock().unwrap_or_else(|p| p.into_inner());
        if active.generation == generation
            && active.cancellable
            && let Some(handle) = &active.interrupt
        {
            handle.interrupt();
        }
    }

    fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        let active = self.active.lock().unwrap_or_else(|p| p.into_inner());
        if active.cancellable {
            if let Some(token) = &active.token {
                token.cancel();
            }
            if let Some(handle) = &active.interrupt {
                handle.interrupt();
            }
        }
    }
}

type Work = Box<dyn FnOnce(&mut State) + Send>;
struct Command {
    generation: u64,
    token: CancellationToken,
    started: Arc<AtomicBool>,
    work: Work,
}

pub(super) struct Worker {
    sender: mpsc::Sender<Option<Command>>,
    shared: Arc<Shared>,
    finished: watch::Receiver<bool>,
}

impl std::fmt::Debug for Worker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteWorker").finish_non_exhaustive()
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.shared.stop();
        let _ = self.sender.try_send(None);
    }
}

struct RequestGuard {
    shared: Arc<Shared>,
    generation: u64,
    token: CancellationToken,
}

impl Drop for RequestGuard {
    fn drop(&mut self) {
        self.token.cancel();
        self.shared.interrupt(self.generation);
    }
}

// Always signalled on normal exit, failed startup and unwinding. A panic drops every reply sender.
struct Finished(watch::Sender<bool>);
impl Drop for Finished {
    fn drop(&mut self) {
        let _ = self.0.send(true);
    }
}

impl Worker {
    pub(super) async fn open(options: Options) -> Result<Self> {
        let (sender, mut receiver) = mpsc::channel::<Option<Command>>(32);
        let (ready, startup) = oneshot::channel();
        let (finished_tx, finished) = watch::channel(false);
        let shared = Arc::new(Shared {
            active: Mutex::new(Active::default()),
            stopping: AtomicBool::new(false),
            next: AtomicU64::new(1),
        });
        let thread_shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("sqmeow-sqlite".into())
            .spawn(move || {
                let _finished = Finished(finished_tx);
                let conn = match options.open() {
                    Ok(conn) => conn,
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                let mut state = State {
                    conn,
                    keys: HashMap::new(),
                    shared: thread_shared.clone(),
                    token: CancellationToken::new(),
                };
                let _ = ready.send(Ok(()));
                while let Some(Some(command)) = receiver.blocking_recv() {
                    if thread_shared.stopping.load(Ordering::Acquire) {
                        break;
                    }
                    state.token = command.token.clone();
                    {
                        let mut active = thread_shared
                            .active
                            .lock()
                            .unwrap_or_else(|p| p.into_inner());
                        // Pair publication with stop(): shutdown either prevents this
                        // command from starting or sees and cancels its active token.
                        if thread_shared.stopping.load(Ordering::Acquire) {
                            break;
                        }
                        active.generation = command.generation;
                        active.interrupt = Some(state.conn.get_interrupt_handle());
                        active.token = Some(command.token.clone());
                        active.cancellable = true;
                        command.started.store(true, Ordering::Release);
                    }
                    BUSY.with(|b| *b.borrow_mut() = Some((command.token.clone(), Instant::now())));
                    let token = command.token;
                    state
                        .conn
                        .progress_handler(1000, Some(move || token.is_cancelled()))
                        .expect("worker owns its SQLite connection");
                    (command.work)(&mut state);
                    state.disable_cancel();
                    BUSY.with(|b| *b.borrow_mut() = None);
                    let mut active = thread_shared
                        .active
                        .lock()
                        .unwrap_or_else(|p| p.into_inner());
                    active.interrupt = None;
                    active.token = None;
                }
                receiver.close();
                // Connection and unprocessed reply senders are dropped on this thread.
            })
            .map_err(Error::driver)?;
        startup
            .await
            .map_err(|_| Error::driver("SQLite worker failed during startup"))??;
        Ok(Self {
            sender,
            shared,
            finished,
        })
    }

    async fn call<T: Send + 'static>(
        &self,
        cancel: CancellationToken,
        work: impl FnOnce(&mut State) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.shared.stopping.load(Ordering::Acquire) {
            return Err(Error::driver("SQLite connection is closed"));
        }
        // Child cancellation lets dropping this future stop only its own request.
        let token = cancel.child_token();
        let generation = self.shared.next.fetch_add(1, Ordering::Relaxed);
        let guard = RequestGuard {
            shared: self.shared.clone(),
            generation,
            token: token.clone(),
        };
        let started = Arc::new(AtomicBool::new(false));
        let (reply, mut response) = oneshot::channel();
        let command = Command {
            generation,
            token,
            started: started.clone(),
            work: Box::new(move |state| {
                let result = if state.token.is_cancelled() {
                    Err(Error::Cancelled)
                } else {
                    work(state)
                };
                // Disarm before publishing: late cancellation cannot interrupt a later command.
                state.disable_cancel();
                let _ = reply.send(result);
            }),
        };
        tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(Error::Cancelled),
            sent = self.sender.send(Some(command)) => sent.map_err(|_| Error::driver("SQLite worker stopped"))?,
        }
        let result = tokio::select! {
            result = &mut response => result,
            () = cancel.cancelled() => {
                guard.token.cancel();
                // A cancelled queued command cannot run and need not wait behind unrelated work.
                if !started.load(Ordering::Acquire) { return Err(Error::Cancelled); }
                self.shared.interrupt(generation);
                // Wait for explicit rollback/cleanup, not merely the interrupt signal.
                response.await
            }
        }
        .map_err(|_| Error::driver("SQLite worker stopped before replying"))?;
        drop(guard);
        result
    }

    pub(super) async fn fetch(&self, sql: String, values: Vec<Value>) -> Result<Vec<OwnedRow>> {
        self.call(CancellationToken::new(), move |s| {
            fetch(&s.conn, &sql, &values)
        })
        .await
    }

    pub(super) async fn run(
        &self,
        sql: String,
        origin: String,
        values: Vec<Value>,
        cap: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.call(cancel, move |s| s.run(&sql, &origin, &values, cap, false))
            .await
    }

    pub(super) async fn apply(
        &self,
        sql: Vec<String>,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.call(cancel, move |s| s.apply(&sql)).await
    }

    pub(super) async fn close(&self) {
        self.shared.stop();
        let _ = self.sender.try_send(None);
        let mut finished = self.finished.clone();
        while !*finished.borrow_and_update() {
            if finished.changed().await.is_err() {
                break;
            }
        }
    }
}

thread_local! {
    static BUSY: RefCell<Option<(CancellationToken, Instant)>> = const { RefCell::new(None) };
}

fn busy(attempt: i32) -> bool {
    let keep = BUSY.with(|b| {
        let mut b = b.borrow_mut();
        if let Some((token, started)) = b.as_mut() {
            if attempt == 0 {
                *started = Instant::now();
            }
            !token.is_cancelled() && started.elapsed() < Duration::from_secs(5)
        } else {
            attempt < 500
        }
    });
    if keep {
        std::thread::sleep(Duration::from_millis(10));
    }
    keep
}

pub(super) struct OwnedRow(HashMap<String, NativeValue>);
impl OwnedRow {
    pub(super) fn text(&self, name: &str) -> Option<String> {
        match self.0.get(name)? {
            NativeValue::Text(s) => Some(s.clone()),
            _ => None,
        }
    }
    pub(super) fn int(&self, name: &str) -> i64 {
        match self.0.get(name) {
            Some(NativeValue::Integer(v)) => *v,
            _ => 0,
        }
    }
    pub(super) fn required(&self, name: &str) -> Result<String> {
        self.text(name)
            .ok_or_else(|| Error::driver(format!("missing SQLite metadata column: {name}")))
    }
}

fn native(value: &Value) -> NativeValue {
    match value {
        Value::Null(_) => NativeValue::Null,
        Value::Text(v) => NativeValue::Text(v.clone()),
        Value::Int(v) => NativeValue::Integer(*v),
        Value::Float(v) => NativeValue::Real(*v),
        Value::Bool(v) => NativeValue::Integer(i64::from(*v)),
    }
}

fn fetch(conn: &Connection, sql: &str, values: &[Value]) -> Result<Vec<OwnedRow>> {
    let mut stmt = conn.prepare(sql).map_err(Error::driver)?;
    let names: Vec<String> = stmt
        .column_names()
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    let values: Vec<_> = values.iter().map(native).collect();
    let mut rows = stmt
        .query(rusqlite::params_from_iter(values))
        .map_err(Error::driver)?;
    let mut out = Vec::new();
    while let Some(row) = rows.next().map_err(Error::driver)? {
        let mut cells = HashMap::new();
        for (i, name) in names.iter().enumerate() {
            cells.insert(
                name.clone(),
                row.get::<_, NativeValue>(i).map_err(Error::driver)?,
            );
        }
        out.push(OwnedRow(cells));
    }
    Ok(out)
}

struct State {
    conn: Connection,
    keys: HashMap<TableName, Keys>,
    shared: Arc<Shared>,
    token: CancellationToken,
}

impl State {
    fn enable_cancel(&self) {
        let token = self.token.clone();
        self.conn
            .progress_handler(1000, Some(move || token.is_cancelled()))
            .expect("worker owns its SQLite connection");
        BUSY.with(|b| *b.borrow_mut() = Some((self.token.clone(), Instant::now())));
        let mut active = self.shared.active.lock().unwrap_or_else(|p| p.into_inner());
        // Shutdown during the commit fence must stop any following statement.
        if self.shared.stopping.load(Ordering::Acquire) {
            self.token.cancel();
        }
        active.cancellable = true;
    }

    fn disable_cancel(&self) {
        // Lock is shared with interrupters: after this fence there can be no late interrupt.
        self.shared
            .active
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .cancellable = false;
        self.conn
            .progress_handler(0, None::<fn() -> bool>)
            .expect("worker owns its SQLite connection");
        BUSY.with(|b| *b.borrow_mut() = None);
    }

    fn error(&self, error: impl std::fmt::Display) -> Error {
        if self.token.is_cancelled() {
            Error::Cancelled
        } else {
            Error::driver(error)
        }
    }

    fn run(
        &mut self,
        sql: &str,
        origin: &str,
        values: &[Value],
        cap: usize,
        applying: bool,
    ) -> Result<ResultSet> {
        let started = Instant::now();
        let (description, source) = self.describe(origin, values);
        let mut result = ResultSet::new(sql, description);
        result.set_source(source);
        let mut batch = Batch::new(&self.conn, sql);
        let mut offset = 0;
        let mut restore_cancel = false;
        while let Some(mut stmt) = batch.next().map_err(|e| self.error(e))? {
            if restore_cancel {
                self.enable_cancel();
            }
            if self.token.is_cancelled() {
                return Err(Error::Cancelled);
            }
            let word = stmt
                .expanded_sql()
                .map(|s| sqmeow_db::sql::first_word(&s))
                .unwrap_or_default();
            if applying
                && matches!(
                    word.as_str(),
                    "begin" | "commit" | "end" | "rollback" | "savepoint" | "release"
                )
            {
                return Err(Error::driver(
                    "transaction control is not allowed inside an edit transaction",
                ));
            }
            let committing = matches!(word.as_str(), "commit" | "end");
            if committing {
                self.disable_cancel();
            }
            let count = stmt.parameter_count();
            if offset + count > values.len() {
                return Err(Error::driver("not enough SQLite bind values"));
            }
            for (i, value) in values[offset..offset + count].iter().enumerate() {
                stmt.raw_bind_parameter(i + 1, native(value))
                    .map_err(|e| self.error(e))?;
            }
            offset += count;
            let declared = columns(&stmt);
            result.adopt_columns(declared);
            let readonly = stmt.readonly();
            let before = self.conn.total_changes();
            let mut rows = stmt.raw_query();
            while let Some(row) = rows.next().map_err(|e| self.error(e))? {
                if !committing && self.token.is_cancelled() {
                    return Err(Error::Cancelled);
                }
                for (i, column) in result.columns_mut().iter_mut().enumerate() {
                    if column.type_name == "NULL" {
                        let raw = row.get_ref(i).map_err(|e| self.error(e))?;
                        column.type_name = storage_name(raw).to_owned();
                        column.class =
                            sqmeow_db::types::TypeClass::from_type_name(&column.type_name);
                    }
                }
                if result.row_count() >= cap {
                    result.mark_truncated();
                    result.set_elapsed(started.elapsed());
                    return Ok(result);
                }
                let cells = (0..row.as_ref().column_count())
                    .map(|i| row.get_ref(i).map(decode).map_err(|e| self.error(e)))
                    .collect::<Result<_>>()?;
                result.push_row(cells);
            }
            drop(rows);
            if !readonly {
                let affected = if self.conn.total_changes() != before {
                    self.conn.changes()
                } else {
                    0
                };
                result.set_affected(affected);
            }
            drop(stmt);
            // Leave a final COMMIT fenced through its successful reply. Only a
            // following statement makes this request cancellable again.
            restore_cancel = committing;
        }
        if offset != values.len() {
            return Err(Error::driver("too many SQLite bind values"));
        }
        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    fn apply(&mut self, statements: &[String]) -> Result<Vec<ResultSet>> {
        if self.token.is_cancelled() {
            return Err(Error::Cancelled);
        }
        self.conn
            .execute_batch("BEGIN")
            .map_err(|e| self.error(e))?;
        let outcome = (|| {
            let mut returned = Vec::new();
            for sql in statements {
                let result = self.run(sql, sql, &[], usize::MAX, true)?;
                check_affected(sql, result.affected().unwrap_or(0))?;
                if result.row_count() > 0 {
                    returned.push(result);
                }
            }
            if self.token.is_cancelled() {
                return Err(Error::Cancelled);
            }
            Ok(returned)
        })();
        match outcome {
            Ok(returned) => {
                // Cancellation may race with this fence, but cannot affect COMMIT or its reply.
                self.disable_cancel();
                if self.token.is_cancelled() {
                    self.conn.execute_batch("ROLLBACK").map_err(Error::driver)?;
                    return Err(Error::Cancelled);
                }
                if let Err(error) = self.conn.execute_batch("COMMIT") {
                    self.conn.execute_batch("ROLLBACK").map_err(Error::driver)?;
                    return Err(rolled_back(error));
                }
                Ok(returned)
            }
            Err(error) => {
                self.disable_cancel();
                // SQLite may itself roll back an interrupted write.
                if !self.conn.is_autocommit() {
                    self.conn.execute_batch("ROLLBACK").map_err(Error::driver)?;
                }
                if matches!(error, Error::Cancelled) {
                    Err(error)
                } else {
                    Err(rolled_back(error))
                }
            }
        }
    }

    fn describe(&mut self, sql: &str, values: &[Value]) -> (Vec<Column>, Option<Source>) {
        let Ok(stmt) = self.conn.prepare(sql) else {
            return (Vec::new(), None);
        };
        let mut columns = columns(&stmt);
        let origins: Vec<Origin> = stmt
            .columns_with_metadata()
            .iter()
            .map(|c| {
                Some((
                    TableName {
                        schema: c
                            .database_name()
                            .filter(|s| *s != "main")
                            .map(str::to_owned),
                        name: c.table_name()?.to_owned(),
                    },
                    c.origin_name()?.to_owned(),
                ))
            })
            .collect();
        drop(stmt);
        // Re-read each request, including external schema changes and rolled-back DDL.
        self.keys.clear();
        for (table, _) in origins.iter().flatten() {
            if !self.keys.contains_key(table) {
                self.keys
                    .insert(table.clone(), read_keys(&self.conn, table));
            }
        }
        for (column, origin) in columns.iter_mut().zip(&origins) {
            if let Some(kind) = origin
                .as_ref()
                .and_then(|(table, name)| self.keys.get(table)?.kinds.get(name))
            {
                column.key = *kind;
            }
        }
        let mut sides = sqmeow_db::sql::Sides::read(Dialect::Sqlite, sql);
        let views = fetch(&self.conn, "select name, sql from sqlite_master where type = 'view' union all select name, sql from sqlite_temp_master where type = 'view'", &[]).unwrap_or_default().iter().filter_map(|r| Some((r.text("name")?, r.text("sql")?))).collect::<Vec<_>>();
        sides.expand_views(Dialect::Sqlite, &views);
        let compound =
            fetch(&self.conn, &format!("explain query plan {sql}"), values).map_or(true, |rows| {
                rows.iter().any(|r| {
                    r.text("detail")
                        .is_some_and(|d| d == "COMPOUND QUERY" || d.starts_with("MERGE ("))
                })
            });
        if compound {
            return (columns, None);
        }
        let mut binder = TableBinder::default()
            .every_column(sqmeow_db::sql::plain(Dialect::Sqlite, sql))
            .sides(sides);
        for (i, origin) in origins.into_iter().enumerate() {
            if let Some((table, name)) = origin {
                binder.bind(i, table, name);
            }
        }
        let source = binder.build(|table| {
            self.keys.get(table).map_or_else(Vec::new, |keys| {
                let primary = keys
                    .kinds
                    .iter()
                    .filter(|(_, k)| **k == KeyKind::Primary)
                    .map(|(n, _)| n.clone())
                    .collect();
                std::iter::once(primary)
                    .chain(keys.unique.iter().cloned())
                    .collect()
            })
        });
        (columns, source)
    }
}

fn quote(name: &str) -> String {
    Dialect::Sqlite.quote_ident(name)
}

fn pragma(table: &TableName, name: &str) -> String {
    format!(
        "pragma {}.{name}({})",
        quote(table.schema.as_deref().unwrap_or("main")),
        quote(&table.name)
    )
}

fn read_keys(conn: &Connection, table: &TableName) -> Keys {
    let mut keys = Keys::default();
    for row in fetch(conn, &pragma(table, "foreign_key_list"), &[]).unwrap_or_default() {
        if let Some(name) = row.text("from") {
            keys.kinds.insert(name, KeyKind::Foreign);
        }
    }
    for row in fetch(conn, &pragma(table, "table_info"), &[]).unwrap_or_default() {
        if row.int("pk") > 0
            && let Some(name) = row.text("name")
        {
            keys.kinds.insert(name, KeyKind::Primary);
        }
    }
    for index in fetch(conn, &pragma(table, "index_list"), &[]).unwrap_or_default() {
        if index.int("unique") != 1
            || index.int("partial") != 0
            || index.text("origin").is_some_and(|v| v == "pk")
        {
            continue;
        }
        let Some(name) = index.text("name") else {
            continue;
        };
        let sql = format!(
            "pragma {}.index_info({})",
            quote(table.schema.as_deref().unwrap_or("main")),
            quote(&name)
        );
        if let Ok(rows) = fetch(conn, &sql, &[])
            && let Some(names) = rows
                .iter()
                .map(|r| r.text("name"))
                .collect::<Option<Vec<_>>>()
        {
            keys.unique.push(names);
        }
    }
    keys
}

fn normalized(declared: Option<&str>) -> &'static str {
    let s = declared.unwrap_or("").to_ascii_lowercase();
    match s.as_str() {
        "boolean" | "bool" => "BOOLEAN",
        "date" => "DATE",
        "time" => "TIME",
        "datetime" | "timestamp" => "DATETIME",
        _ if s.contains("int") => "INTEGER",
        _ if s.contains("char") || s.contains("clob") || s.contains("text") => "TEXT",
        _ if s.contains("blob") => "BLOB",
        _ if s.contains("real") || s.contains("floa") || s.contains("doub") => "REAL",
        _ => "NULL",
    }
}

fn columns(stmt: &Statement<'_>) -> Vec<Column> {
    stmt.columns()
        .iter()
        .map(|c| Column::new(c.name(), normalized(c.decl_type())))
        .collect()
}

fn storage_name(value: ValueRef<'_>) -> &'static str {
    match value {
        ValueRef::Null => "NULL",
        ValueRef::Integer(_) => "INTEGER",
        ValueRef::Real(_) => "REAL",
        ValueRef::Text(_) => "TEXT",
        ValueRef::Blob(_) => "BLOB",
    }
}

fn decode(value: ValueRef<'_>) -> Cell {
    match value {
        ValueRef::Null => Cell::Null,
        ValueRef::Integer(v) => Cell::Int(v),
        ValueRef::Real(v) => Cell::Float(v),
        ValueRef::Text(v) => {
            String::from_utf8(v.to_vec()).map_or_else(|e| Cell::bytes(e.as_bytes()), Cell::Text)
        }
        ValueRef::Blob(v) => Cell::bytes(v),
    }
}
