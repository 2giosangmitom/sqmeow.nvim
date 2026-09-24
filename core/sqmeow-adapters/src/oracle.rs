//! The Oracle Database adapter, through the pure-Rust `oracledb` driver.
//!
//! The driver is synchronous, so every database call runs on a blocking
//! thread, like the DuckDB adapter. One connection serves queries and edits;
//! a second serves the drawer, which a long query does not hold up.
//!
//! The driver cannot stop a running query from another connection, so a
//! cancel returns at once while the query runs on in the background. The next
//! query waits for it, since they share one session.

use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use percent_encoding::percent_decode_str;
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Details, Dialect, Error, ForeignKey, ForeignKeyNode,
    IndexNode, KeyKind, RelationKind, RelationNode, Result, ResultSet, RoleNode, RoutineNode,
    SchemaNode, Source, TableBinder, TableName,
};
use tokio_util::sync::CancellationToken;

/// The port an `oracle://` URL assumes.
const DEFAULT_PORT: u16 = 1521;

/// The port an `oracletcps://` URL assumes.
const DEFAULT_TCPS_PORT: u16 = 2484;

/// One session with an Oracle database, plus one for the drawer.
pub struct OracleAdapter {
    connection: Arc<Mutex<Session>>,
    meta: Arc<Mutex<Session>>,
    /// The user queries run as, in upper case, which unqualified names resolve to.
    default_schema: String,
}

/// Retain the login settings so a dead session can be replaced on the next
/// request. Failed operations are never replayed: a write may have committed
/// before the connection was lost.
struct Session {
    connection: Option<oracledb::Connection>,
    config: oracledb::Config,
    metadata: bool,
}

impl Session {
    fn open(config: oracledb::Config, metadata: bool) -> Result<Self> {
        let mut session = Self {
            connection: None,
            config,
            metadata,
        };
        session.reconnect()?;
        Ok(session)
    }

    fn reconnect(&mut self) -> Result<()> {
        let connection = oracledb::connect(self.config.clone()).map_err(Error::driver)?;
        if self.metadata {
            // Reapply these session-local transforms on every connection.
            connection.execute(
                "begin
                   dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'PRETTY', true);
                   dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SEGMENT_ATTRIBUTES', false);
                   dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'STORAGE', false);
                   dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'TABLESPACE', false);
                 end;",
                &[],
            ).map_err(Error::driver)?;
        }
        self.connection = Some(connection);
        Ok(())
    }

    fn run<T>(&mut self, work: impl FnOnce(&oracledb::Connection) -> Result<T>) -> Result<T> {
        if self.connection.is_none() {
            self.reconnect().map_err(|error| {
                Error::driver(format!(
                    "could not reconnect Oracle session: {error}; request was not executed"
                ))
            })?;
        }
        let connection = self.connection.as_ref().expect("connected session");
        let result = work(connection);
        // A syntax, constraint or permission error leaves the session usable.
        // Probe only on failure, avoiding a round trip on every successful call.
        if let Err(error) = &result
            && connection.ping().is_err()
        {
            self.connection = None;
            return Err(Error::driver(format!(
                "{error}; Oracle session lost; the next request will reconnect. \
                 Transaction and session state are lost; this operation was not replayed \
                 and its commit outcome may be unknown"
            )));
        }
        result
    }
}

impl std::fmt::Debug for OracleAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OracleAdapter")
            .field("default_schema", &self.default_schema)
            .finish_non_exhaustive()
    }
}

/// What an `oracle://` URL asks for.
#[derive(Debug, PartialEq)]
struct Target {
    host: String,
    port: u16,
    /// A service name, or a TNS alias when `tns_admin` is given.
    service: String,
    user: String,
    password: String,
    tls: bool,
    auth: Auth,
    wallet_dir: Option<String>,
    wallet_password: Option<String>,
    tns_admin: Option<String>,
    /// A full `(DESCRIPTION=...)` connect descriptor from `?tns=`.
    descriptor: Option<String>,
}

/// The privilege to connect with.
#[derive(Debug, PartialEq)]
enum Auth {
    Default,
    SysDba,
    SysOper,
}

impl OracleAdapter {
    /// Open a session on the host and service the URL names, on `database`
    /// when given and otherwise on the one the URL names. Switching names a
    /// service or alias; a `?tns=` descriptor stands alone.
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        let mut target = parse_url(url)?;
        if let Some(service) = database {
            if target.descriptor.is_some() {
                return Err(Error::driver(
                    "switching databases needs a service or alias url, not a `?tns=` descriptor",
                ));
            }
            target.service = service.to_owned();
        }
        let connect_string = connect_string(&target);
        let open = move || {
            let mut config =
                oracledb::Config::default().set_credentials(&target.user, &target.password);
            match target.auth {
                Auth::SysDba => config = config.set_auth_mode(oracledb::AUTH_MODE_SYSDBA),
                Auth::SysOper => config = config.set_auth_mode(oracledb::AUTH_MODE_SYSOPER),
                Auth::Default => {}
            }
            if let Some(dir) = &target.wallet_dir {
                config = config.set_wallet_location(dir);
                if let Some(password) = &target.wallet_password
                    && !password.is_empty()
                {
                    config = config.set_wallet_password(password);
                }
            }
            if let Some(dir) = &target.tns_admin {
                config = config.set_config_dir(dir);
            }
            let config = config
                .set_connect_string(&connect_string)
                .map_err(Error::driver)?;
            // Two sessions of their own: queries never hold up the drawer.
            let work = Session::open(config.clone(), false)?;
            let meta = Session::open(config, true)?;
            Ok::<_, Error>((work, meta))
        };
        let (connection, meta) =
            tokio::time::timeout(crate::CONNECT_TIMEOUT, tokio::task::spawn_blocking(open))
                .await
                .map_err(|_| Error::driver("timed out connecting to the server"))?
                .map_err(Error::driver)??;

        let adapter = Self {
            connection: Arc::new(Mutex::new(connection)),
            meta: Arc::new(Mutex::new(meta)),
            default_schema: String::new(),
        };
        let default_schema = adapter
            .scalar("select sys_context('USERENV', 'CURRENT_SCHEMA') from dual")
            .await?;
        Ok(Self {
            default_schema,
            ..adapter
        })
    }

    /// Run `work` against the session on a blocking thread, giving up when
    /// `cancel` trips. The work itself keeps running: the driver cannot stop
    /// it, so the next query waits for it.
    async fn run<T, F>(&self, cancel: &CancellationToken, work: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&oracledb::Connection) -> Result<T> + Send + 'static,
    {
        let connection = Arc::clone(&self.connection);
        let task = tokio::task::spawn_blocking(move || {
            let mut connection = connection.lock().map_err(Error::driver)?;
            connection.run(work)
        });
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(Error::Cancelled),
            outcome = task => outcome.map_err(Error::driver)?,
        }
    }

    /// Run `work` against the drawer's session on a blocking thread.
    async fn run_meta<T, F>(&self, work: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&oracledb::Connection) -> Result<T> + Send + 'static,
    {
        let meta = Arc::clone(&self.meta);
        tokio::task::spawn_blocking(move || {
            let mut meta = meta.lock().map_err(Error::driver)?;
            meta.run(work)
        })
        .await
        .map_err(Error::driver)?
    }

    /// The single text value a query answers with, or an empty string.
    async fn scalar(&self, sql: &str) -> Result<String> {
        let sql = sql.to_owned();
        self.run_meta(move |meta| {
            let row = meta.query_row(sql.as_str(), &[]).map_err(Error::driver)?;
            row.get::<Option<String>>(0)
                .map(|value| value.unwrap_or_default())
                .map_err(Error::driver)
        })
        .await
    }

    /// Run a metadata query with text binds, reading each row with `read`.
    fn query_bound<T>(
        meta: &oracledb::Connection,
        sql: &str,
        binds: &[String],
        mut read: impl FnMut(&oracledb::Row) -> Result<T>,
    ) -> Result<Vec<T>> {
        let params: Vec<&dyn oracledb::ToDbValue> = binds
            .iter()
            .map(|bind| bind as &dyn oracledb::ToDbValue)
            .collect();
        let cursor = meta.query(sql, &params).map_err(Error::driver)?;
        let mut rows = Vec::new();
        for row in cursor {
            rows.push(read(&row.map_err(Error::driver)?)?);
        }
        Ok(rows)
    }

    /// Run a metadata query that answers a `LONG` column, such as
    /// `data_default` or `search_condition`. The driver's cached statements
    /// misread those on re-execute and desynchronize the session with
    /// `unknown TTC message type` errors, so these queries skip the cache.
    fn query_long<T>(
        meta: &oracledb::Connection,
        sql: &str,
        binds: &[String],
        mut read: impl FnMut(&oracledb::Row) -> Result<T>,
    ) -> Result<Vec<T>> {
        let params: Vec<&dyn oracledb::ToDbValue> = binds
            .iter()
            .map(|bind| bind as &dyn oracledb::ToDbValue)
            .collect();
        let mut statement = meta.statement(sql).map_err(Error::driver)?;
        statement.exclude_from_cache();
        let cursor = statement.query(&params).map_err(Error::driver)?;
        let mut rows = Vec::new();
        for row in cursor {
            rows.push(read(&row.map_err(Error::driver)?)?);
        }
        Ok(rows)
    }

    /// Where a plain single-table result's rows are stored, with its key
    /// columns marked, or `None` when the statement is not one.
    fn source(
        meta: &oracledb::Connection,
        default_schema: &str,
        statement: &str,
        columns: &mut [Column],
    ) -> Option<Source> {
        if !sqmeow_db::sql::plain(Dialect::Oracle, statement) {
            return None;
        }
        let (schema, table) = single_table(statement)?;
        let schema = schema.as_deref().unwrap_or(default_schema);
        // The catalog's spelling, since unquoted names resolve to upper case
        // and planned statements quote what they are given.
        let (schema, table) =
            resolve_table(meta, schema, &table).unwrap_or((schema.to_owned(), table));
        let keys = table_keys(meta, &schema, &table).ok()?;
        let table_name = TableName::new(Some(&schema), &table);
        let mut binder = TableBinder::default()
            .every_column(true)
            .sides(sqmeow_db::sql::Sides::read(Dialect::Oracle, statement));
        for (index, column) in columns.iter_mut().enumerate() {
            // Bound by the catalog's spelling, which is what the keys name.
            let Some(known) = keys
                .columns
                .iter()
                .find(|known| known.eq_ignore_ascii_case(&column.name))
            else {
                continue;
            };
            binder.bind(index, table_name.clone(), known.clone());
            if keys.primary.iter().any(|key| key == known) {
                column.key = KeyKind::Primary;
            }
        }
        binder.build(|_| {
            std::iter::once(keys.primary.clone())
                .chain(keys.unique.clone())
                .collect()
        })
    }
}

/// A table's columns and keys, as the catalog spells them.
struct TableKeys {
    columns: Vec<String>,
    primary: Vec<String>,
    unique: Vec<Vec<String>>,
}

/// A table's columns, primary key and unique keys, trying the name as written
/// and then in upper case, since unquoted Oracle names are upper case.
fn table_keys(meta: &oracledb::Connection, schema: &str, table: &str) -> Result<TableKeys> {
    let attempt = |schema: &str, table: &str| -> Result<TableKeys> {
        let binds = [schema.to_owned(), table.to_owned()];
        let columns: Vec<String> = OracleAdapter::query_bound(
            meta,
            "select column_name from all_tab_columns
             where owner = :1 and table_name = :2
             order by column_id",
            &binds,
            |row| row.get::<String>(0).map_err(Error::driver),
        )?;
        if columns.is_empty() {
            return Err(Error::driver(format!("no such table: {schema}.{table}")));
        }
        let primary: Vec<String> = OracleAdapter::query_bound(
            meta,
            "select cc.column_name from all_constraints k
             join all_cons_columns cc
               on cc.owner = k.owner and cc.constraint_name = k.constraint_name
             where k.owner = :1 and k.table_name = :2 and k.constraint_type = 'P'
             order by cc.position",
            &binds,
            |row| row.get::<String>(0).map_err(Error::driver),
        )?;
        let lists: Vec<(String, String)> = OracleAdapter::query_bound(
            meta,
            "select k.constraint_name, cc.column_name from all_constraints k
             join all_cons_columns cc
               on cc.owner = k.owner and cc.constraint_name = k.constraint_name
             where k.owner = :1 and k.table_name = :2 and k.constraint_type = 'U'
             order by k.constraint_name, cc.position",
            &binds,
            |row| {
                Ok((
                    row.get::<String>(0).map_err(Error::driver)?,
                    row.get::<String>(1).map_err(Error::driver)?,
                ))
            },
        )?;
        let mut unique: Vec<Vec<String>> = Vec::new();
        for (name, column) in lists {
            if unique.is_empty() || unique_name(&unique) != name {
                unique.push(Vec::new());
                unique_name_set(&mut unique, name);
            }
            unique_columns(&mut unique).push(column);
        }
        let unique = unique
            .into_iter()
            .map(|mut list| {
                list.remove(0);
                list
            })
            .collect();
        Ok(TableKeys {
            columns,
            primary,
            unique,
        })
    };
    match attempt(schema, table) {
        Ok(keys) => Ok(keys),
        Err(first) => {
            let upper = (schema.to_ascii_uppercase(), table.to_ascii_uppercase());
            if upper.0 != schema || upper.1 != table {
                attempt(&upper.0, &upper.1)
            } else {
                Err(first)
            }
        }
    }
}

/// The constraint name stored at the head of the unique key under construction.
fn unique_name(unique: &[Vec<String>]) -> String {
    unique
        .last()
        .and_then(|list| list.first())
        .cloned()
        .unwrap_or_default()
}

fn unique_name_set(unique: &mut [Vec<String>], name: String) {
    if let Some(last) = unique.last_mut() {
        last.push(name);
    }
}

fn unique_columns(unique: &mut [Vec<String>]) -> &mut Vec<String> {
    unique.last_mut().expect("pushed above")
}

/// The single `[schema.]table` a `SELECT ... FROM` reads, or `None` for
/// anything else: no joins, no nesting past the top level.
fn single_table(statement: &str) -> Option<(Option<String>, String)> {
    if sqmeow_db::sql::first_word(statement) != "select" {
        return None;
    }
    let words = sqmeow_db::guard::words(Dialect::Oracle, statement);
    let mut froms = 0;
    for (word, depth) in &words {
        if *depth == 0 {
            match word.as_str() {
                "from" => froms += 1,
                "join" | "union" | "intersect" | "except" | "group" => return None,
                _ => {}
            }
        }
    }
    if froms != 1 {
        return None;
    }
    // The identifiers after the top-level FROM, keeping their case.
    single_table_from(&from_clause(statement)?)
}

/// One `[schema.]table` with an optional alias, or `None` for anything else.
fn single_table_from(from: &str) -> Option<(Option<String>, String)> {
    let mut tokens = Vec::new();
    let mut chars = from.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c == '"' {
            chars.next();
            let mut name = String::new();
            loop {
                match chars.next() {
                    None => break,
                    Some('"') if chars.peek() == Some(&'"') => {
                        chars.next();
                        name.push('"');
                    }
                    Some('"') => break,
                    Some(next) => name.push(next),
                }
            }
            tokens.push(Token::Name(name));
        } else if c == '.' {
            chars.next();
            tokens.push(Token::Dot);
        } else if c == ',' {
            // A second table, which is a join.
            return None;
        } else if c.is_alphabetic() || c == '_' {
            let mut name = String::new();
            while let Some(&next) = chars.peek() {
                if next.is_alphanumeric() || next == '_' || next == '$' {
                    name.push(next);
                    chars.next();
                } else {
                    break;
                }
            }
            tokens.push(Token::Name(name));
        } else if c.is_whitespace() {
            chars.next();
        } else {
            // Anything else ends the table reference.
            break;
        }
    }
    match tokens.as_slice() {
        [Token::Name(table)] | [Token::Name(table), Token::Name(_)] => Some((None, table.clone())),
        [Token::Name(schema), Token::Dot, Token::Name(table)]
        | [
            Token::Name(schema),
            Token::Dot,
            Token::Name(table),
            Token::Name(_),
        ] => {
            let (schema, table) = (schema.clone(), table.clone());
            (!table.is_empty()).then_some((Some(schema), table))
        }
        _ => None,
    }
}

/// One piece of a table reference.
#[derive(Debug, PartialEq)]
enum Token {
    Name(String),
    Dot,
}

/// The text between the top-level `FROM` and the clause ending it.
fn from_clause(statement: &str) -> Option<String> {
    let chars: Vec<char> = statement.chars().collect();
    let mut depth = 0usize;
    let mut index = 0;
    let mut quote: Option<char> = None;
    while index < chars.len() {
        if quote.is_none() {
            if chars[index] == '-' && chars.get(index + 1) == Some(&'-') {
                while index < chars.len() && chars[index] != '\n' {
                    index += 1;
                }
                continue;
            }
            if chars[index] == '/' && chars.get(index + 1) == Some(&'*') {
                index += 2;
                while index + 1 < chars.len() && !(chars[index] == '*' && chars[index + 1] == '/') {
                    index += 1;
                }
                index += 2;
                continue;
            }
            if chars[index] == '\'' || chars[index] == '"' {
                quote = Some(chars[index]);
                index += 1;
                continue;
            }
            if chars[index] == '(' {
                depth += 1;
            } else if chars[index] == ')' {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && is_word_start(chars[index]) {
                let end = word_end(&chars, index);
                if chars[index..end]
                    .iter()
                    .collect::<String>()
                    .eq_ignore_ascii_case("from")
                {
                    index = end;
                    break;
                }
                index = end;
                continue;
            }
        } else if chars[index] == quote.unwrap_or('\'') {
            if chars.get(index + 1) == Some(&chars[index]) {
                index += 1;
            } else {
                quote = None;
            }
        }
        index += 1;
    }
    if index >= chars.len() {
        return None;
    }
    // To the next top-level clause or closing parenthesis. A comma stays
    // in the text: the tokenizer below ends the table reference at one.
    let start = index;
    let mut end = chars.len();
    depth = 0;
    quote = None;
    let mut i = start;
    while i < chars.len() {
        if quote.is_none() {
            if chars[i] == '\'' || chars[i] == '"' {
                quote = Some(chars[i]);
            } else if chars[i] == '(' {
                depth += 1;
            } else if chars[i] == ')' {
                if depth == 0 {
                    end = i;
                    break;
                }
                depth -= 1;
            } else if depth == 0 && is_word_start(chars[i]) {
                let stop = word_end(&chars, i);
                let word: String = chars[i..stop].iter().collect();
                if matches!(
                    word.to_ascii_lowercase().as_str(),
                    "where"
                        | "group"
                        | "order"
                        | "having"
                        | "fetch"
                        | "offset"
                        | "for"
                        | "union"
                        | "intersect"
                        | "except"
                        | "join"
                        | "left"
                        | "right"
                        | "full"
                        | "cross"
                        | "inner"
                ) {
                    end = i;
                    break;
                }
                i = stop;
                continue;
            }
        } else if chars[i] == quote.unwrap_or('\'') {
            if chars.get(i + 1) == Some(&chars[i]) {
                i += 1;
            } else {
                quote = None;
            }
        }
        i += 1;
    }
    Some(chars[start..end].iter().collect())
}

fn is_word_start(character: char) -> bool {
    character.is_alphabetic() || character == '_'
}

fn word_end(chars: &[char], index: usize) -> usize {
    let mut end = index;
    while end < chars.len()
        && (chars[end].is_alphanumeric() || chars[end] == '_' || chars[end] == '$')
    {
        end += 1;
    }
    end
}

impl Adapter for OracleAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Oracle
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.execute_wrapped(statement, statement, max_rows, cancel)
            .await
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(self
            .execute_results(statement, origin, max_rows, cancel)
            .await?
            .pop()
            .unwrap_or_else(|| ResultSet::new(statement, Vec::new())))
    }

    async fn execute_results(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        let (statement, origin, default_schema) = (
            statement.to_owned(),
            origin.to_owned(),
            self.default_schema.clone(),
        );
        self.run(&cancel, move |connection| {
            if matches!(
                sqmeow_db::sql::first_word(&statement).as_str(),
                "begin" | "declare" | "call"
            ) {
                run_plsql(connection, &default_schema, &statement, max_rows)
            } else {
                run_statement(connection, &default_schema, &statement, &origin, max_rows)
                    .map(|result| vec![result])
            }
        })
        .await
    }

    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        let statements = statements.to_vec();
        let stopped = cancel.clone();
        self.run(&stopped, move |connection| {
            for statement in &statements {
                if cancel.is_cancelled() {
                    let _ = connection.rollback();
                    return Err(Error::Cancelled);
                }
                let affected = connection
                    .execute(statement.as_str(), &[])
                    .map_err(|error| {
                        let _ = connection.rollback();
                        Error::driver(format!("nothing was applied: {error}\nin: {statement}"))
                    })?;
                let affected = affected.rows_affected();
                if let Err(error) = crate::stream::check_affected(statement, affected) {
                    let _ = connection.rollback();
                    return Err(crate::stream::rolled_back(error));
                }
            }
            connection.commit().map_err(Error::driver)?;
            Ok(Vec::new())
        })
        .await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let current = self.default_schema.clone();
        self.run_meta(move |meta| {
            // `oracle_maintained` needs 12.1+; fall back to every user where
            // the server is older than that.
            let filtered = meta.query(
                "select username from all_users
                 where oracle_maintained = 'N'
                    or username = sys_context('USERENV', 'CURRENT_SCHEMA')
                 order by 1",
                &[],
            );
            let cursor = match filtered {
                Ok(cursor) => cursor,
                Err(error) if error.to_string().contains("ORA-00904") => meta
                    .query("select username from all_users order by 1", &[])
                    .map_err(Error::driver)?,
                Err(error) => return Err(Error::driver(error)),
            };
            let mut schemas = Vec::new();
            for row in cursor {
                let row = row.map_err(Error::driver)?;
                let name: String = row.get(0).map_err(Error::driver)?;
                schemas.push(SchemaNode {
                    is_default: name == current,
                    name,
                });
            }
            Ok(schemas)
        })
        .await
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let binds = [
            schema.to_owned(),
            schema.to_owned(),
            schema.to_owned(),
            schema.to_owned(),
        ];
        self.run_meta(move |meta| {
            let rows: Vec<(String, String)> = Self::query_bound(
                meta,
                "select table_name, 'TABLE' from all_tables where owner = :1
                 union all select view_name, 'VIEW' from all_views where owner = :1
                 union all select mview_name, 'MATERIALIZED VIEW' from all_mviews where owner = :1
                 union all
                 select sequence_name, 'SEQUENCE' from all_sequences where sequence_owner = :1
                 order by 1",
                &binds,
                |row| {
                    Ok((
                        row.get::<String>(0).map_err(Error::driver)?,
                        row.get::<String>(1).map_err(Error::driver)?,
                    ))
                },
            )?;
            Ok(rows
                .into_iter()
                .map(|(name, kind)| RelationNode {
                    kind: match kind.as_str() {
                        "VIEW" => RelationKind::View,
                        "MATERIALIZED VIEW" => RelationKind::MaterializedView,
                        "SEQUENCE" => RelationKind::Sequence,
                        _ => RelationKind::Table,
                    },
                    name,
                })
                .collect())
        })
        .await
    }

    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        let binds = [schema.to_owned()];
        self.run_meta(move |meta| {
            let rows: Vec<(String, String)> = Self::query_bound(
                meta,
                "select object_name, object_type from all_objects
                 where owner = :1 and object_type in ('FUNCTION', 'PROCEDURE', 'PACKAGE')
                 order by 1",
                &binds,
                |row| {
                    Ok((
                        row.get::<String>(0).map_err(Error::driver)?,
                        row.get::<String>(1).map_err(Error::driver)?,
                    ))
                },
            )?;
            Ok(rows
                .into_iter()
                .map(|(name, kind)| crate::routine_node(name, kind.to_ascii_lowercase().as_str()))
                .collect())
        })
        .await
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let (schema, relation) = (schema.to_owned(), relation.to_owned());
        self.run_meta(move |meta| {
            let (schema, relation) = resolve_table(meta, &schema, &relation)?;
            let binds = [schema.clone(), relation.clone()];
            let rows: Vec<ColumnRow> = Self::query_long(
                meta,
                "select c.column_name, c.data_type, c.data_length, c.data_precision, c.data_scale,
                        c.nullable, c.data_default, c.char_used, c.char_length
                 from all_tab_columns c
                 where c.owner = :1 and c.table_name = :2
                 order by c.column_id",
                &binds,
                |row| {
                    Ok(ColumnRow {
                        name: row.get::<String>(0).map_err(Error::driver)?,
                        data_type: row.get::<String>(1).map_err(Error::driver)?,
                        length: row.get::<Option<u32>>(2).map_err(Error::driver)?,
                        precision: row.get::<Option<u8>>(3).map_err(Error::driver)?,
                        scale: row.get::<Option<i8>>(4).map_err(Error::driver)?,
                        nullable: row.get::<String>(5).map_err(Error::driver)?,
                        default: row.get::<Option<String>>(6).map_err(Error::driver)?,
                        char_used: row.get::<Option<String>>(7).map_err(Error::driver)?,
                        char_length: row.get::<Option<u32>>(8).map_err(Error::driver)?,
                    })
                },
            )?;
            if rows.is_empty() {
                return Ok(Vec::new());
            }
            let keys = table_keys(meta, &schema, &relation).unwrap_or(TableKeys {
                columns: Vec::new(),
                primary: Vec::new(),
                unique: Vec::new(),
            });
            let foreign = foreign_keys(meta, &schema, &relation).unwrap_or_default();
            Ok(rows
                .into_iter()
                .map(|row| {
                    let primary_key = keys.primary.iter().any(|key| key == &row.name);
                    ColumnNode {
                        type_name: format_type(&row),
                        nullable: row.nullable == "Y",
                        primary_key,
                        foreign_key: foreign
                            .iter()
                            .find(|key| key.columns.first().is_some_and(|c| c == &row.name))
                            .map(|key| ForeignKey {
                                table: key.target.clone(),
                                column: key.referenced.first().cloned().unwrap_or_default(),
                            }),
                        default: row.default.map(|default| default.trim().to_owned()),
                        name: row.name,
                    }
                })
                .collect())
        })
        .await
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        let (schema, relation) = (schema.to_owned(), relation.to_owned());
        self.run_meta(move |meta| {
            let (schema, relation) = resolve_table(meta, &schema, &relation)?;
            let binds = [schema, relation];
            let rows: Vec<IndexRow> = Self::query_long(
                meta,
                "select i.index_name, c.column_name, i.uniqueness,
                        case when p.constraint_name is null then 0 else 1 end,
                        c.descend, e.column_expression
                 from all_indexes i
                 join all_ind_columns c
                   on c.index_owner = i.owner and c.index_name = i.index_name
                 left join all_constraints p
                   on p.owner = i.owner and p.constraint_name = i.index_name
                  and p.constraint_type = 'P'
                 left join all_ind_expressions e
                   on e.index_owner = c.index_owner and e.index_name = c.index_name
                  and e.column_position = c.column_position
                 where i.table_owner = :1 and i.table_name = :2
                 order by i.index_name, c.column_position",
                &binds,
                |row| {
                    Ok(IndexRow {
                        name: row.get::<String>(0).map_err(Error::driver)?,
                        column: row.get::<String>(1).map_err(Error::driver)?,
                        uniqueness: row.get::<String>(2).map_err(Error::driver)?,
                        primary: row.get::<u8>(3).map_err(Error::driver)? != 0,
                        descend: row.get::<Option<String>>(4).map_err(Error::driver)?,
                        expression: row.get::<Option<String>>(5).map_err(Error::driver)?,
                    })
                },
            )?;
            let mut indexes: Vec<IndexNode> = Vec::new();
            for row in rows {
                // A descending or function-based key reads back as an
                // expression (`\"SALARY\"`, `UPPER(\"EMAIL\")`); plain
                // ascending columns stay bare names.
                let mut column = row.expression.unwrap_or(row.column);
                if row.descend.is_some_and(|descend| descend == "DESC") {
                    column.push_str(" DESC");
                }
                match indexes.last_mut() {
                    Some(index) if index.name == row.name => index.columns.push(column),
                    _ => indexes.push(IndexNode {
                        unique: row.uniqueness == "UNIQUE",
                        primary: row.primary,
                        columns: vec![column],
                        name: row.name,
                    }),
                }
            }
            Ok(indexes)
        })
        .await
    }

    async fn roles(&self) -> Result<Vec<RoleNode>> {
        self.run_meta(|meta| {
            let filtered = meta.query(
                "select username from all_users where oracle_maintained = 'N' order by 1",
                &[],
            );
            let cursor = match filtered {
                Ok(cursor) => cursor,
                Err(error) if error.to_string().contains("ORA-00904") => meta
                    .query("select username from all_users order by 1", &[])
                    .map_err(Error::driver)?,
                Err(error) => return Err(Error::driver(error)),
            };
            let mut roles = Vec::new();
            for row in cursor {
                let row = row.map_err(Error::driver)?;
                roles.push(RoleNode {
                    name: row.get::<String>(0).map_err(Error::driver)?,
                    attributes: Vec::new(),
                });
            }
            Ok(roles)
        })
        .await
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<Details> {
        let (schema, relation) = (schema.to_owned(), relation.to_owned());
        self.run_meta(move |meta| {
            let (schema, relation) = resolve_table(meta, &schema, &relation)?;
            let binds = [schema.clone(), relation.clone()];
            // Sequences read as relations but own no columns: describe the
            // sequence itself instead of an empty table.
            let sequence: Vec<SequenceRow> = Self::query_bound(
                meta,
                "select to_char(min_value), to_char(max_value),
                        to_char(increment_by), cycle_flag, order_flag,
                        to_char(cache_size), to_char(last_number)
                 from all_sequences
                 where sequence_owner = :1 and sequence_name = :2",
                &binds,
                |row| {
                    Ok(SequenceRow {
                        min: row.get::<String>(0).map_err(Error::driver)?,
                        max: row.get::<String>(1).map_err(Error::driver)?,
                        increment: row.get::<String>(2).map_err(Error::driver)?,
                        cycle: row.get::<String>(3).map_err(Error::driver)?,
                        order: row.get::<String>(4).map_err(Error::driver)?,
                        cache: row.get::<String>(5).map_err(Error::driver)?,
                        last: row.get::<String>(6).map_err(Error::driver)?,
                    })
                },
            )?;
            if let Some(sequence) = sequence.into_iter().next() {
                let yes_no = |flag: &str| {
                    if flag == "Y" {
                        "yes".to_owned()
                    } else {
                        "no".to_owned()
                    }
                };
                let ddl_binds = [relation.clone(), schema.clone()];
                let definition = Self::query_bound(
                    meta,
                    "select dbms_metadata.get_ddl('SEQUENCE', :1, :2) from dual",
                    &ddl_binds,
                    |row| row.get::<Option<String>>(0).map_err(Error::driver),
                )?
                .into_iter()
                .next()
                .flatten();
                return Ok(Details {
                    properties: vec![
                        ("increment by".to_owned(), sequence.increment),
                        ("min value".to_owned(), sequence.min),
                        ("max value".to_owned(), sequence.max),
                        ("cache size".to_owned(), sequence.cache),
                        ("cycle".to_owned(), yes_no(&sequence.cycle)),
                        ("order".to_owned(), yes_no(&sequence.order)),
                        ("last number".to_owned(), sequence.last),
                    ],
                    definition,
                    ..Details::default()
                });
            }
            let comment: Option<String> = Self::query_bound(
                meta,
                "select comments from all_tab_comments
                 where owner = :1 and table_name = :2 and comments is not null",
                &binds,
                |row| row.get::<Option<String>>(0).map_err(Error::driver),
            )?
            .into_iter()
            .next()
            .flatten();
            let column_comments: Vec<(String, String)> = Self::query_bound(
                meta,
                "select column_name, comments from all_col_comments
                 where owner = :1 and table_name = :2 and comments is not null
                 order by column_name",
                &binds,
                |row| {
                    Ok((
                        row.get::<String>(0).map_err(Error::driver)?,
                        row.get::<String>(1).map_err(Error::driver)?,
                    ))
                },
            )?;
            let checks: Vec<(String, String)> = Self::query_long(
                meta,
                "select constraint_name, search_condition from all_constraints
                 where owner = :1 and table_name = :2 and constraint_type = 'C'
                 order by constraint_name",
                &binds,
                |row| {
                    Ok((
                        row.get::<String>(0).map_err(Error::driver)?,
                        row.get::<Option<String>>(1)
                            .map_err(Error::driver)?
                            .unwrap_or_default(),
                    ))
                },
            )?;
            let triggers: Vec<(String, String)> = Self::query_long(
                meta,
                "select trigger_name, triggering_event || ' ' || trigger_type,
                        status, when_clause
                 from all_triggers
                 where table_owner = :1 and table_name = :2
                 order by trigger_name",
                &binds,
                |row| {
                    let event = row
                        .get::<Option<String>>(1)
                        .map_err(Error::driver)?
                        .unwrap_or_default();
                    let status: Option<String> = row.get(2).map_err(Error::driver)?;
                    let when: Option<String> = row.get(3).map_err(Error::driver)?;
                    let mut info = event;
                    if let Some(when) = when {
                        info = format!("{info} WHEN ({})", when.trim());
                    }
                    if status.is_some_and(|status| status != "ENABLED") {
                        info = format!("{info} DISABLED");
                    }
                    Ok((row.get::<String>(0).map_err(Error::driver)?, info))
                },
            )?;
            let foreign_keys = foreign_keys(meta, &schema, &relation).unwrap_or_default();
            // `DBMS_METADATA` needs no special rights for one's own objects.
            let ddl_binds = [relation.clone(), schema.clone()];
            let definition = ["TABLE", "VIEW", "MATERIALIZED_VIEW"]
                .into_iter()
                .find_map(|kind| {
                    let sql = format!("select dbms_metadata.get_ddl('{kind}', :1, :2) from dual");
                    Self::query_bound(meta, &sql, &ddl_binds, |row| {
                        row.get::<Option<String>>(0).map_err(Error::driver)
                    })
                    .ok()
                    .and_then(|mut rows| rows.pop().flatten())
                });
            Ok(Details {
                properties: comment
                    .map(|comment| ("comment".to_owned(), comment))
                    .into_iter()
                    .collect(),
                column_comments,
                foreign_keys,
                checks,
                triggers,
                definition,
            })
        })
        .await
    }

    async fn close(&self) {}
}

/// A drawer's schema and relation as the catalog spells them: as written, or
/// in upper case, since unquoted Oracle names are upper case.
fn resolve_table(
    meta: &oracledb::Connection,
    schema: &str,
    relation: &str,
) -> Result<(String, String)> {
    let binds = [
        schema.to_owned(),
        relation.to_owned(),
        schema.to_owned(),
        relation.to_owned(),
        schema.to_owned(),
        relation.to_owned(),
    ];
    let found: Vec<(String, String)> = OracleAdapter::query_bound(
        meta,
        "select owner, table_name from all_tables where owner = :1 and table_name = :2
         union all select owner, view_name from all_views where owner = :1 and view_name = :2
         union all
         select owner, mview_name from all_mviews where owner = :1 and mview_name = :2",
        &binds,
        |row| {
            Ok((
                row.get::<String>(0).map_err(Error::driver)?,
                row.get::<String>(1).map_err(Error::driver)?,
            ))
        },
    )?;
    if let Some(found) = found.into_iter().next() {
        return Ok(found);
    }
    let upper = (schema.to_ascii_uppercase(), relation.to_ascii_uppercase());
    if upper.0 != schema || upper.1 != relation {
        return resolve_table(meta, &upper.0, &upper.1);
    }
    Ok((schema.to_owned(), relation.to_owned()))
}

/// One row of `all_sequences`, numbers as text: ranges reach 10^27.
struct SequenceRow {
    min: String,
    max: String,
    increment: String,
    cycle: String,
    order: String,
    cache: String,
    last: String,
}

/// One key of `all_ind_columns`, with its sort direction and, for a
/// function-based key, the expression from `all_ind_expressions`.
struct IndexRow {
    name: String,
    column: String,
    uniqueness: String,
    primary: bool,
    descend: Option<String>,
    expression: Option<String>,
}

/// One column of `all_tab_columns`, as selected above.
struct ColumnRow {
    name: String,
    data_type: String,
    length: Option<u32>,
    precision: Option<u8>,
    scale: Option<i8>,
    nullable: String,
    default: Option<String>,
    /// `C` for char semantics, `B` for byte semantics, and `None` where the
    /// type has no length in characters.
    char_used: Option<String>,
    char_length: Option<u32>,
}

/// A column's declared type, with its width or precision where it has one.
fn format_type(row: &ColumnRow) -> String {
    match row.data_type.as_str() {
        name @ ("VARCHAR2" | "NVARCHAR2" | "CHAR" | "NCHAR") => {
            // `DATA_LENGTH` counts bytes; `CHAR_LENGTH` counts characters.
            let length = if row.char_used.as_deref() == Some("C") {
                row.char_length.or(row.length)
            } else {
                row.length
            };
            match length {
                Some(length) => format!("{name}({length})"),
                None => name.to_owned(),
            }
        }
        "RAW" => format!("RAW({})", row.length.unwrap_or(0)),
        "NUMBER" => match (row.precision, row.scale) {
            (Some(precision), Some(scale)) if scale != 0 => {
                format!("NUMBER({precision},{scale})")
            }
            (Some(precision), _) => format!("NUMBER({precision})"),
            _ => "NUMBER".to_owned(),
        },
        _ => row.data_type.clone(),
    }
}

/// Every foreign key on one table, grouped by constraint.
fn foreign_keys(
    meta: &oracledb::Connection,
    schema: &str,
    relation: &str,
) -> Result<Vec<ForeignKeyNode>> {
    let binds = [schema.to_owned(), relation.to_owned()];
    let rows: Vec<(String, String, String, String)> = OracleAdapter::query_bound(
        meta,
        "select k.constraint_name, cc.column_name,
                rc.owner || '.' || rc.table_name, rcc.column_name
         from all_constraints k
         join all_cons_columns cc
           on cc.owner = k.owner and cc.constraint_name = k.constraint_name
         join all_constraints rc
           on rc.owner = k.r_owner and rc.constraint_name = k.r_constraint_name
         join all_cons_columns rcc
           on rcc.owner = rc.owner and rcc.constraint_name = rc.constraint_name
          and rcc.position = cc.position
         where k.owner = :1 and k.table_name = :2 and k.constraint_type = 'R'
         order by k.constraint_name, cc.position",
        &binds,
        |row| {
            Ok((
                row.get::<String>(0).map_err(Error::driver)?,
                row.get::<String>(1).map_err(Error::driver)?,
                row.get::<String>(2).map_err(Error::driver)?,
                row.get::<Option<String>>(3)
                    .map_err(Error::driver)?
                    .unwrap_or_default(),
            ))
        },
    )?;
    let mut keys: Vec<ForeignKeyNode> = Vec::new();
    for (name, column, target, referenced) in rows {
        match keys.last_mut() {
            Some(key) if key.name == name => {
                key.columns.push(column);
                key.referenced.push(referenced);
            }
            _ => keys.push(ForeignKeyNode {
                name,
                columns: vec![column],
                target,
                referenced: vec![referenced],
            }),
        }
    }
    Ok(keys)
}

/// Past whitespace and comments, the way `first_word` reads them.
fn skip_trivia(text: &str) -> &str {
    let mut rest = text.trim_start();
    loop {
        if let Some(after) = rest.strip_prefix("--") {
            rest = after
                .split_once('\n')
                .map_or("", |(_, tail)| tail)
                .trim_start();
        } else if let Some(after) = rest.strip_prefix("/*") {
            rest = after
                .split_once("*/")
                .map_or("", |(_, tail)| tail)
                .trim_start();
        } else {
            break;
        }
    }
    rest
}

/// The text after `keyword` where it opens the text (case-insensitively),
/// or `None`. A word boundary follows the keyword.
fn strip_keyword<'a>(text: &'a str, keyword: &str) -> Option<&'a str> {
    if text.len() >= keyword.len()
        && text[..keyword.len()].eq_ignore_ascii_case(keyword)
        && text[keyword.len()..]
            .chars()
            .next()
            .is_none_or(|next| !next.is_ascii_alphanumeric() && !matches!(next, '_' | '$' | '#'))
    {
        Some(&text[keyword.len()..])
    } else {
        None
    }
}

/// `Some(true)` for a bare `COMMIT`, `Some(false)` for a bare `ROLLBACK`,
/// and `None` for anything else.
fn bare_transaction(statement: &str) -> Option<bool> {
    let rest = skip_trivia(statement);
    let end = rest
        .char_indices()
        .find(|(_, c)| !c.is_alphabetic())
        .map_or(rest.len(), |(i, _)| i);
    let (keyword, after) = rest.split_at(end);
    let commit = match keyword.to_ascii_lowercase().as_str() {
        "commit" => true,
        "rollback" => false,
        _ => return None,
    };
    // Nothing after the keyword but whitespace, a terminator, or comments.
    let mut tail = after.trim_start();
    if let Some(stripped) = tail.strip_prefix(';') {
        tail = stripped.trim_start();
    }
    tail = skip_trivia(tail);
    tail.is_empty().then_some(commit)
}

/// Run one statement: `COMMIT` and `ROLLBACK` through the API, a query
/// through `query`, and anything else through `execute`.
fn run_statement(
    connection: &oracledb::Connection,
    default_schema: &str,
    statement: &str,
    origin: &str,
    max_rows: usize,
) -> Result<ResultSet> {
    let started = Instant::now();
    match bare_transaction(statement) {
        Some(true) => {
            connection.commit().map_err(Error::driver)?;
            let mut result = ResultSet::new(statement, Vec::new());
            result.set_elapsed(started.elapsed());
            return Ok(result);
        }
        Some(false) => {
            connection.rollback().map_err(Error::driver)?;
            let mut result = ResultSet::new(statement, Vec::new());
            result.set_elapsed(started.elapsed());
            return Ok(result);
        }
        // Anything else, including `ROLLBACK TO SAVEPOINT x`, keeps its SQL
        // meaning through `execute`.
        None => {}
    }
    // A plan reads back through `DBMS_XPLAN`: Oracle stores it in a table
    // and answers no rows itself.
    if let Some(inner) = explain_inner(statement) {
        return explain_plan(
            connection,
            default_schema,
            inner,
            statement,
            origin,
            max_rows,
            started,
        );
    }
    if is_query(statement) {
        match connection.query(statement, &[]) {
            Ok(cursor) => {
                return read_cursor(
                    connection,
                    default_schema,
                    cursor,
                    statement,
                    origin,
                    max_rows,
                    started,
                );
            }
            // Anything the query refused may still execute.
            Err(query_error) => match execute_update(connection, statement) {
                Ok(affected) => {
                    connection.commit().map_err(Error::driver)?;
                    let mut result = ResultSet::new(statement, Vec::new());
                    result.set_affected(affected);
                    result.set_elapsed(started.elapsed());
                    return Ok(result);
                }
                Err(_) => return Err(Error::driver(query_error)),
            },
        }
    }
    let affected = execute_update(connection, statement)?;
    // Like the other adapters, one statement commits what it changed: only
    // `apply` holds a transaction open across statements.
    connection.commit().map_err(Error::driver)?;
    let mut result = ResultSet::new(statement, Vec::new());
    result.set_affected(affected);
    result.set_elapsed(started.elapsed());
    Ok(result)
}

/// The driver exposes OUT cursors but not implicit results. Oracle's
/// DBMS_SQL client cursor lets us receive RETURN_RESULT without rewriting
/// user SQL or exposing any special bind names to the user.
struct PlsqlResults<'a> {
    connection: &'a oracledb::Connection,
    id: Option<i64>,
}

impl PlsqlResults<'_> {
    fn close(&mut self) -> Result<()> {
        if let Some(id) = self.id.take() {
            self.connection
                .execute(
                    "declare c integer := :1; begin dbms_sql.close_cursor(c); end;",
                    &[&id],
                )
                .map_err(Error::driver)?;
        }
        Ok(())
    }
}

impl Drop for PlsqlResults<'_> {
    fn drop(&mut self) {
        // Also closes implicit results not yet retrieved, including after a
        // decode/fetch error. Retrieved cursors are owned by the driver.
        let _ = self.close();
    }
}

fn run_plsql(
    connection: &oracledb::Connection,
    default_schema: &str,
    statement: &str,
    max_rows: usize,
) -> Result<Vec<ResultSet>> {
    let started = Instant::now();
    let mut sql = statement.trim_end().to_owned();
    if sqmeow_db::sql::first_word(statement) == "call" {
        sql = sql.trim_end_matches(';').to_owned();
    } else if !sql.ends_with(';') {
        sql.push_str("\n;");
    }
    // Cached OUT-cursor statements can leave this driver stuck after a
    // returned result followed by a PL/SQL exception. Keep these uncached.
    let mut opened = connection
        .statement(
            "declare
           c integer;
           n integer;
         begin
           c := dbms_sql.open_cursor(treat_as_client_for_results => true);
           dbms_sql.parse(c, :source, dbms_sql.native);
           n := dbms_sql.execute(c);
           :parent := c;
         exception when others then
           if dbms_sql.is_open(c) then dbms_sql.close_cursor(c); end if;
           raise;
         end;",
        )
        .map_err(Error::driver)?
        .exclude_from_cache()
        .execute_named(&[("source", &sql), ("parent", &&oracledb::DB_TYPE_NUMBER)])
        .map_err(Error::driver)?;
    let id: i64 = opened.out_bind_data().get(0).map_err(Error::driver)?;
    let mut parent = PlsqlResults {
        connection,
        id: Some(id),
    };
    let mut results = Vec::new();
    loop {
        let next = connection
            .statement("begin dbms_sql.get_next_result(:parent, :result); end;")
            .map_err(Error::driver)?
            .exclude_from_cache()
            .execute_named(&[("parent", &id), ("result", &&oracledb::DB_TYPE_CURSOR)]);
        let mut next = match next {
            Ok(next) => next,
            // This API raises NO_DATA_FOUND when all results are retrieved.
            Err(error) if error.to_string().contains("ORA-01403:") => break,
            Err(error) => return Err(Error::driver(error)),
        };
        let cursor = next
            .out_bind_data()
            .take::<oracledb::Cursor>(0)
            .map_err(Error::driver)?;
        results.push(read_cursor(
            connection,
            default_schema,
            cursor,
            statement,
            "",
            max_rows,
            started,
        )?);
    }
    parent.close()?;
    connection.commit().map_err(Error::driver)?;
    if results.is_empty() {
        results.push(ResultSet::new(statement, Vec::new()));
    }
    for result in &mut results {
        result.set_elapsed(started.elapsed());
    }
    Ok(results)
}

/// The inner statement of a plain `EXPLAIN PLAN FOR <statement>`, or `None`
/// for anything else — including `SET STATEMENT_ID` and `INTO` variants,
/// which execute as written without reading the plan back.
fn explain_inner(statement: &str) -> Option<&str> {
    let rest = skip_trivia(statement);
    let rest = strip_keyword(rest, "explain")?;
    let rest = skip_trivia(rest);
    let rest = strip_keyword(rest, "plan")?;
    let rest = skip_trivia(rest);
    let rest = strip_keyword(rest, "for")?;
    Some(skip_trivia(rest))
}

/// The conventional plan table, as `rdbms/admin/utlxplan.sql` shapes it,
/// without `sharing=none`, which older servers reject.
const CREATE_PLAN_TABLE: &str = "create table plan_table (
    statement_id varchar2(30), plan_id number, timestamp date,
    remarks varchar2(4000), operation varchar2(30), options varchar2(255),
    object_node varchar2(128), object_owner varchar2(128),
    object_name varchar2(128), object_alias varchar2(261),
    object_instance numeric, object_type varchar2(30), optimizer varchar2(255),
    search_columns number, id numeric, parent_id numeric, depth numeric,
    position numeric, cost numeric, cardinality numeric, bytes numeric,
    other_tag varchar2(255), partition_start varchar2(255),
    partition_stop varchar2(255), partition_id numeric, other long,
    distribution varchar2(30), cpu_cost numeric, io_cost numeric,
    temp_space numeric, access_predicates varchar2(4000),
    filter_predicates varchar2(4000), projection varchar2(4000),
    time numeric, qblock_name varchar2(128), other_xml clob
) nocompress";

/// The guidance when no plan table can be had.
fn plan_table_guidance(error: impl std::fmt::Display) -> Error {
    Error::driver(format!(
        "explain plan needs a PLAN_TABLE, which is missing and could not be created ({error}); \
         ask your DBA to create it from rdbms/admin/utlxplan.sql or grant CREATE TABLE"
    ))
}

/// A plan table the session can see, creating the conventional one when
/// none is visible.
fn ensure_plan_table(connection: &oracledb::Connection) -> Result<()> {
    let visible: Vec<String> = OracleAdapter::query_bound(
        connection,
        "select table_name from all_tables
         where table_name = 'PLAN_TABLE' and rownum = 1",
        &[],
        |row| row.get::<String>(0).map_err(Error::driver),
    )?;
    if !visible.is_empty() {
        return Ok(());
    }
    match connection.execute(CREATE_PLAN_TABLE, &[]) {
        Ok(_) => {
            connection.commit().map_err(Error::driver)?;
            Ok(())
        }
        // Already there: a DBA-managed one, or a racing session made it.
        Err(error) if error.to_string().contains("ORA-00955") => Ok(()),
        Err(error) => Err(plan_table_guidance(error)),
    }
}

/// Run `EXPLAIN PLAN FOR <inner>` and read the plan back through
/// `DBMS_XPLAN`.
fn explain_plan(
    connection: &oracledb::Connection,
    default_schema: &str,
    inner: &str,
    statement: &str,
    origin: &str,
    max_rows: usize,
    started: Instant,
) -> Result<ResultSet> {
    ensure_plan_table(connection)?;
    // A shared PLAN_TABLE serves every session: tag this plan so the
    // read-back cannot catch another session's.
    static PLAN_SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| time.as_millis() % 10_000_000_000_000);
    let id = format!(
        "SQM{millis:013}_{:04}",
        PLAN_SEQUENCE.fetch_add(1, Ordering::Relaxed) % 10_000
    );
    let inner = inner.trim_end().trim_end_matches(';').trim_end();
    let planned = format!("explain plan set statement_id = '{id}' for {inner}");
    if let Err(error) = connection.execute(planned.as_str(), &[]) {
        if error.to_string().contains("ORA-02404") {
            return Err(plan_table_guidance(error));
        }
        return Err(Error::driver(error));
    }
    connection.commit().map_err(Error::driver)?;
    let display = format!("select * from table(dbms_xplan.display('PLAN_TABLE', '{id}'))");
    let outcome = match connection.query(display.as_str(), &[]) {
        Ok(cursor) => read_cursor(
            connection,
            default_schema,
            cursor,
            statement,
            origin,
            max_rows,
            started,
        ),
        Err(error) => Err(Error::driver(error)),
    };
    // Best effort: leave no rows behind in a table others share.
    let cleanup = format!("delete from plan_table where statement_id = '{id}'");
    let _ = connection.execute(cleanup.as_str(), &[]);
    let _ = connection.commit();
    outcome
}

/// Whether the statement stores PL/SQL without running it: `CREATE TRIGGER`,
/// `PROCEDURE`, `FUNCTION` or `PACKAGE`. Its `:NEW`-style placeholders are
/// part of the stored source and never evaluated.
fn stores_plsql(statement: &str) -> bool {
    let words = sqmeow_db::guard::words(Dialect::Oracle, statement);
    let mut top = words
        .iter()
        .filter(|(_, depth)| *depth == 0)
        .map(|(word, _)| word.as_str());
    if top.next() != Some("create") {
        return false;
    }
    let mut top =
        top.skip_while(|word| matches!(*word, "or" | "replace" | "editionable" | "noneditionable"));
    matches!(
        top.next(),
        Some("trigger" | "procedure" | "function" | "package")
    )
}

/// Run stored PL/SQL as dynamic SQL, so its placeholders stay inside the
/// string literal and the driver sees no binds at all. Handing the driver
/// NULLs does not work: the server reads `:NEW` as a correlation name with
/// no bind slot, and extra binds fail the execute.
fn immediate_block(statement: &str) -> String {
    format!(
        "BEGIN EXECUTE IMMEDIATE '{}'; END;",
        statement.replace('\'', "''")
    )
}

/// Run a statement that answers no rows: plain `execute`, except stored
/// PL/SQL, which runs as dynamic SQL (see `immediate_block`).
fn execute_update(connection: &oracledb::Connection, statement: &str) -> Result<u64> {
    if !stores_plsql(statement) {
        return Ok(connection
            .execute(statement, &[])
            .map_err(Error::driver)?
            .rows_affected());
    }
    // Oracle only compiles the stored source with its closing `;`.
    let mut body = statement.trim_end().to_owned();
    if !body.ends_with(';') {
        body.push(';');
    }
    Ok(connection
        .execute(immediate_block(body.as_str()).as_str(), &[])
        .map_err(Error::driver)?
        .rows_affected())
}

/// Whether the statement answers with rows.
fn is_query(statement: &str) -> bool {
    matches!(
        sqmeow_db::sql::first_word(statement).as_str(),
        "select" | "with" | "values" | "table" | "describe" | "desc"
    )
}

/// Read a cursor into a result set, tracing a plain single-table query to its
/// table for editing.
fn read_cursor(
    connection: &oracledb::Connection,
    default_schema: &str,
    cursor: oracledb::Cursor,
    statement: &str,
    origin: &str,
    max_rows: usize,
    started: Instant,
) -> Result<ResultSet> {
    let metas: Vec<oracledb::Metadata> = cursor.columns().to_vec();
    let mut columns: Vec<Column> = metas
        .iter()
        .map(|meta| Column::new(meta.name(), meta.db_type().name()))
        .collect();
    let mut rows: Vec<Vec<Cell>> = Vec::new();
    let mut truncated = false;
    for row in cursor {
        let row = row.map_err(Error::driver)?;
        if rows.len() >= max_rows {
            truncated = true;
            break;
        }
        rows.push(decode_row(&row, &metas));
    }
    let source = OracleAdapter::source(connection, default_schema, origin, &mut columns);
    let mut result = ResultSet::new(statement, columns);
    result.set_source(source);
    for row in rows {
        result.push_row(row);
    }
    if truncated {
        result.mark_truncated();
    }
    result.set_elapsed(started.elapsed());
    Ok(result)
}

/// One row as cells, typed by the cursor's metadata.
fn decode_row(row: &oracledb::Row, metas: &[oracledb::Metadata]) -> Vec<Cell> {
    metas
        .iter()
        .enumerate()
        .map(|(index, meta)| decode_cell(row, index, meta))
        .collect()
}

fn decode_cell(row: &oracledb::Row, index: usize, meta: &oracledb::Metadata) -> Cell {
    let db_type = meta.db_type();
    let name = db_type.name();
    // Every branch below reads an `Option`, so `NULL` never errors.
    if db_type == &oracledb::DB_TYPE_NUMBER {
        return match row.get::<Option<oracledb::OracleNumber>>(index) {
            Ok(Some(number)) => number_text(&number.to_string()),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_BINARY_FLOAT {
        return match row.get::<Option<f32>>(index) {
            Ok(Some(value)) => Cell::Float(f64::from(value)),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_BINARY_DOUBLE {
        return match row.get::<Option<f64>>(index) {
            Ok(Some(value)) => Cell::Float(value),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_BOOLEAN {
        return match row.get::<Option<bool>>(index) {
            Ok(Some(value)) => Cell::Bool(value),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type.is_string_type() {
        return match row.get::<Option<String>>(index) {
            Ok(Some(value)) => Cell::Text(value),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type.is_binary_type() {
        return match row.get::<Option<Vec<u8>>>(index) {
            Ok(Some(value)) => Cell::bytes(&value),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type.is_date_type() {
        return match row.get::<Option<oracledb::OracleTimestamp>>(index) {
            Ok(Some(value)) => Cell::Timestamp(value.to_string()),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_INTERVAL_DS {
        return match row.get::<Option<oracledb::OracleIntervalDS>>(index) {
            Ok(Some(value)) => Cell::Text(value.to_string()),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_INTERVAL_YM {
        return match row.get::<Option<oracledb::OracleIntervalYM>>(index) {
            Ok(Some(value)) => Cell::Text(value.to_string()),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_JSON {
        return match row.get::<Option<oracledb::JsonValue>>(index) {
            Ok(Some(value)) => Cell::Json(json_text(&value)),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    if db_type == &oracledb::DB_TYPE_VECTOR {
        return match row.get::<Option<oracledb::Vector>>(index) {
            Ok(Some(value)) => Cell::Text(format!("{value:?}")),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        };
    }
    // `XMLTYPE`, `BFILE` and anything new: text when it reads as text.
    match row.get::<Option<String>>(index) {
        Ok(Some(value)) => Cell::Text(value),
        Ok(None) => Cell::Null,
        Err(_) => match row.get::<Option<Vec<u8>>>(index) {
            Ok(Some(value)) => Cell::bytes(&value),
            Ok(None) => Cell::Null,
            Err(_) => unsupported(name, row, index),
        },
    }
}

/// An exact numeric as an integer where it fits, and a decimal otherwise.
fn number_text(text: &str) -> Cell {
    if !text.contains(['.', 'e', 'E'])
        && let Ok(value) = text.parse::<i64>()
    {
        return Cell::Int(value);
    }
    Cell::Decimal(text.to_owned())
}

/// A JSON value as a JSON document.
fn json_text(value: &oracledb::JsonValue) -> String {
    json_value(value).to_string()
}

fn json_value(value: &oracledb::JsonValue) -> serde_json::Value {
    use oracledb::JsonValue as Json;
    use serde_json::Value as Out;

    match value {
        Json::Null => Out::Null,
        Json::Boolean(flag) => Out::Bool(*flag),
        Json::Number(number) => {
            let text = number.to_string();
            text.parse::<i64>().map_or_else(
                |_| {
                    text.parse::<f64>().map_or_else(
                        |_| Out::String(text.clone()),
                        |float| {
                            serde_json::Number::from_f64(float)
                                .map_or_else(|| Out::String(text.clone()), Out::Number)
                        },
                    )
                },
                |int| Out::Number(int.into()),
            )
        }
        Json::String(text) => Out::String(text.clone()),
        Json::Timestamp(stamp) => Out::String(stamp.to_string()),
        Json::IntervalDS(span) => Out::String(span.to_string()),
        Json::IntervalYM(span) => Out::String(span.to_string()),
        Json::Raw(bytes) | Json::JsonId(bytes) => bytes
            .iter()
            .map(|byte| serde_json::Value::from(*byte))
            .collect(),
        Json::BinaryFloat(value) => serde_json::Number::from_f64(f64::from(*value))
            .map_or_else(|| Out::String(value.to_string()), Out::Number),
        Json::BinaryDouble(value) => serde_json::Number::from_f64(*value)
            .map_or_else(|| Out::String(value.to_string()), Out::Number),
        Json::Vector(vector) => Out::String(format!("{vector:?}")),
        Json::JsonArray(items) => items.iter().map(json_value).collect(),
        Json::JsonObject(fields) => fields
            .iter()
            .map(|(key, value)| (key.clone(), json_value(value)))
            .collect(),
    }
}

/// A value no branch decodes, kept as the driver's text rather than dropped.
fn unsupported(name: &str, row: &oracledb::Row, index: usize) -> Cell {
    let raw = row
        .get::<Option<String>>(index)
        .ok()
        .flatten()
        .unwrap_or_default();
    Cell::Unsupported {
        type_name: name.to_owned(),
        raw,
    }
}

/// The Easy Connect string a target names, a TNS alias, or a full
/// descriptor: whatever the listener should be told.
fn connect_string(target: &Target) -> String {
    if let Some(descriptor) = &target.descriptor {
        return descriptor.clone();
    }
    if target.tns_admin.is_some() {
        return target.service.clone();
    }
    if target.tls {
        format!("tcps://{}:{}/{}", target.host, target.port, target.service)
    } else {
        format!("{}:{}/{}", target.host, target.port, target.service)
    }
}

/// Read the host, port, service, login and TLS flag from
/// `oracle://user:password@host:1521/service`, or `oracletcps://` for TLS.
///
/// Options after `?`, joined by `&`: `as=sysdba|sysoper` to connect with a
/// privilege, `wallet=DIR` (and `wallet_password=...`) for a client wallet,
/// `tns_admin=DIR` to read the path as a TNS alias, and `tns=(DESCRIPTION=…​)`
/// for a full descriptor, which carries its own address.
fn parse_url(url: &str) -> Result<Target> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let tls = match scheme.to_ascii_lowercase().as_str() {
        "oracle" | "oracledb" => false,
        "oracletcps" => true,
        _ => return Err(Error::UnsupportedUrl(url.to_owned())),
    };
    let (rest, options) = rest.split_once('?').unwrap_or((rest, ""));
    let decode = |text: &str| {
        percent_decode_str(text)
            .decode_utf8()
            .map(|text| text.into_owned())
            .map_err(Error::driver)
    };
    let mut auth = Auth::Default;
    let mut wallet_dir = None;
    let mut wallet_password = None;
    let mut tns_admin = None;
    let mut descriptor = None;
    if !options.is_empty() {
        for option in options.split('&') {
            let (key, value) = option.split_once('=').unwrap_or((option, ""));
            match key.to_ascii_lowercase().as_str() {
                "as" => match value.to_ascii_lowercase().as_str() {
                    "sysdba" => auth = Auth::SysDba,
                    "sysoper" => auth = Auth::SysOper,
                    _ => {
                        return Err(Error::driver("`as` takes sysdba or sysoper"));
                    }
                },
                "wallet" => {
                    let dir = decode(value)?;
                    if dir.is_empty() {
                        return Err(Error::driver(
                            "`wallet` needs a directory, as in ?wallet=/opt/oracle/wallet",
                        ));
                    }
                    wallet_dir = Some(dir);
                }
                "wallet_password" => wallet_password = Some(decode(value)?),
                "tns_admin" => {
                    let dir = decode(value)?;
                    if dir.is_empty() {
                        return Err(Error::driver(
                            "`tns_admin` needs a directory holding a tnsnames.ora",
                        ));
                    }
                    tns_admin = Some(dir);
                }
                "tns" => {
                    let descriptor_text = decode(value)?;
                    if descriptor_text.is_empty() {
                        return Err(Error::driver(
                            "`tns` needs a descriptor, as in ?tns=(DESCRIPTION=…)",
                        ));
                    }
                    descriptor = Some(descriptor_text);
                }
                _ => {
                    return Err(Error::driver(
                        "unknown OracleDB option; supported: as, wallet, wallet_password, tns_admin, tns",
                    ));
                }
            }
        }
    }
    if wallet_password.is_some() && wallet_dir.is_none() {
        return Err(Error::driver("`wallet_password` needs `wallet`"));
    }
    if wallet_dir.is_some() && !tls && descriptor.is_none() && tns_admin.is_none() {
        return Err(Error::driver(
            "`wallet` needs oracletcps:// or a TCPS TNS descriptor/alias",
        ));
    }
    if descriptor.is_some() && tns_admin.is_some() {
        return Err(Error::driver("`tns` and `tns_admin` exclude each other"));
    }
    let (authority, service) = rest.split_once('/').unwrap_or((rest, ""));
    let (login, host) = match authority.rsplit_once('@') {
        Some((login, host)) => (Some(login), host),
        None => (None, authority),
    };

    let (user, password) = match login {
        Some(login) => {
            let (user, password) = login.split_once(':').unwrap_or((login, ""));
            (decode(user)?, decode(password)?)
        }
        None => (String::new(), String::new()),
    };
    if user.is_empty() {
        return Err(Error::driver(
            "an OracleDB url needs a user, as in oracle://user:password@host:1521/XEPDB1",
        ));
    }
    let service = decode(service)?;
    // A second slash starts a path no Easy Connect string holds.
    if service.contains('/') {
        return Err(Error::driver(
            "an OracleDB url names one service name after the host",
        ));
    }

    let default_port = if tls { DEFAULT_TCPS_PORT } else { DEFAULT_PORT };
    let (given_host, given_port): (String, Option<u16>) = if host.is_empty() {
        (String::new(), None)
    } else if host.ends_with(']') || !host.contains(':') {
        (host.to_owned(), None)
    } else {
        let (host, port) = host.rsplit_once(':').unwrap_or((host, ""));
        let port: u16 = port
            .parse()
            .map_err(|_| Error::driver(format!("`{port}` is not a port for host `{host}`")))?;
        (host.to_owned(), Some(port))
    };
    // A descriptor carries its own address; an alias carries everything but
    // credentials. Either way the authority stays empty.
    if descriptor.is_some() {
        if !given_host.is_empty() || given_port.is_some() {
            return Err(Error::driver(
                "a `tns` descriptor carries its own address: oracle://user:password@/?tns=(DESCRIPTION=…)",
            ));
        }
        if !service.is_empty() {
            return Err(Error::driver("a `tns` descriptor takes no service path"));
        }
    } else if tns_admin.is_some() {
        if !given_host.is_empty() || given_port.is_some() {
            return Err(Error::driver(
                "a `tns_admin` alias takes no host: oracle://user:password@/MYDB?tns_admin=/dir",
            ));
        }
        if service.is_empty() {
            return Err(Error::driver(
                "a `tns_admin` url names a TNS alias as its path",
            ));
        }
    } else if service.is_empty() {
        return Err(Error::driver(
            "an OracleDB url needs a service name, as in oracle://user:password@host:1521/XEPDB1",
        ));
    }
    let host = if given_host.is_empty() {
        "localhost".to_owned()
    } else {
        given_host
    };

    Ok(Target {
        host,
        port: given_port.unwrap_or(default_port),
        service,
        user,
        password,
        tls,
        auth,
        wallet_dir,
        wallet_password,
        tns_admin,
        descriptor,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn killed_sessions_recover_independently_without_replaying_work() {
        let (Ok(url), Ok(admin_url)) = (
            std::env::var("SQMEOW_TEST_ORACLE_URL"),
            std::env::var("SQMEOW_TEST_ORACLE_ADMIN_URL"),
        ) else {
            eprintln!("skipped: set SQMEOW_TEST_ORACLE_URL and SQMEOW_TEST_ORACLE_ADMIN_URL");
            return;
        };
        let adapter = OracleAdapter::connect(&url, None).await.unwrap();
        let admin = OracleAdapter::connect(&admin_url, None).await.unwrap();
        fn sid(connection: &oracledb::Connection) -> Result<String> {
            connection
                .query_row("select sys_context('USERENV', 'SID') from dual", &[])
                .and_then(|row| row.get(0))
                .map_err(Error::driver)
        }
        let cancel = CancellationToken::new();
        adapter
            .run(&cancel, |connection| {
                connection
                    .execute("create table ora_recovery (id number)", &[])
                    .map_err(Error::driver)?;
                connection
                    .execute("savepoint before_disconnect", &[])
                    .map_err(Error::driver)?;
                Ok(())
            })
            .await
            .unwrap();
        for metadata in [false, true] {
            let work_sid = adapter.run(&cancel, sid).await.unwrap();
            let meta_sid = adapter.run_meta(sid).await.unwrap();
            let killed_sid = if metadata {
                meta_sid.clone()
            } else {
                work_sid.clone()
            };
            admin
                .run(&cancel, move |connection| {
                    let serial: String = connection
                        .query_row(
                            "select to_char(serial#) from v$session where sid = to_number(:1)",
                            &[&killed_sid],
                        )
                        .and_then(|row| row.get(0))
                        .map_err(Error::driver)?;
                    connection
                        .execute(
                            &format!("alter system kill session '{killed_sid},{serial}' immediate"),
                            &[],
                        )
                        .map_err(Error::driver)?;
                    Ok(())
                })
                .await
                .unwrap();
            let attempts = Arc::new(AtomicU64::new(0));
            let count = Arc::clone(&attempts);
            let failed = move |connection: &oracledb::Connection| {
                count.fetch_add(1, Ordering::Relaxed);
                sid(connection)
            };
            let result = if metadata {
                adapter.run_meta(failed).await
            } else {
                adapter.run(&cancel, failed).await
            };
            assert!(
                result
                    .unwrap_err()
                    .to_string()
                    .contains("Oracle session lost")
            );
            assert_eq!(attempts.load(Ordering::Relaxed), 1, "never replay work");
            // A failed reconnect must keep the session eligible for another
            // attempt, and must not execute the queued operation.
            let session = if metadata {
                &adapter.meta
            } else {
                &adapter.connection
            };
            let config = {
                let mut session = session.lock().unwrap();
                let config = session.config.clone();
                session.config = config
                    .clone()
                    .set_connect_string("127.0.0.1:1/missing")
                    .unwrap();
                config
            };
            let count = Arc::clone(&attempts);
            let request = move |connection: &oracledb::Connection| {
                count.fetch_add(1, Ordering::Relaxed);
                sid(connection)
            };
            let reconnect = if metadata {
                adapter.run_meta(request).await
            } else {
                adapter.run(&cancel, request).await
            };
            assert!(
                reconnect
                    .unwrap_err()
                    .to_string()
                    .contains("request was not executed")
            );
            assert_eq!(attempts.load(Ordering::Relaxed), 1);
            session.lock().unwrap().config = config;
            let new_work = adapter
                .run(&cancel, sid)
                .await
                .expect("work session recovers");
            let new_meta = adapter
                .run_meta(sid)
                .await
                .expect("metadata session recovers");
            if metadata {
                assert_eq!(new_work, work_sid, "work session stays open");
            } else {
                assert_eq!(new_meta, meta_sid, "metadata session stays open");
                let rollback = adapter
                    .run(&cancel, |connection| {
                        connection
                            .execute("rollback to before_disconnect", &[])
                            .map_err(Error::driver)?;
                        Ok(())
                    })
                    .await;
                assert!(
                    rollback.unwrap_err().to_string().contains("ORA-01086"),
                    "the old transaction is not recreated"
                );
            }
        }
        let ddl = adapter
            .run_meta(|connection| {
                connection
                    .query_row(
                        "select dbms_metadata.get_ddl('TABLE', 'ORA_RECOVERY') from dual",
                        &[],
                    )
                    .and_then(|row| row.get::<String>(0))
                    .map_err(Error::driver)
            })
            .await
            .unwrap();
        assert!(
            !ddl.contains("TABLESPACE"),
            "metadata transforms restored: {ddl}"
        );
        adapter
            .run(&cancel, |connection| {
                connection
                    .execute("drop table ora_recovery purge", &[])
                    .map_err(Error::driver)?;
                Ok(())
            })
            .await
            .unwrap();
        let before = adapter.run(&cancel, sid).await.unwrap();
        assert!(
            adapter
                .run(&cancel, |connection| {
                    connection
                        .execute("select from", &[])
                        .map_err(Error::driver)?;
                    Ok(())
                })
                .await
                .is_err()
        );
        assert_eq!(
            adapter.run(&cancel, sid).await.unwrap(),
            before,
            "ordinary SQL errors preserve the session"
        );
    }

    #[test]
    fn reads_the_host_port_service_and_login_from_the_url() {
        assert_eq!(
            parse_url("oracle://u%40x:p%3Ass@db.example.com:1522/orclpdb").unwrap(),
            Target {
                host: "db.example.com".into(),
                port: 1522,
                service: "orclpdb".into(),
                user: "u@x".into(),
                password: "p:ss".into(),
                tls: false,
                auth: Auth::Default,
                wallet_dir: None,
                wallet_password: None,
                tns_admin: None,
                descriptor: None,
            }
        );
        assert_eq!(
            parse_url("oracledb://scott:tiger@localhost/XE").unwrap(),
            Target {
                host: "localhost".into(),
                port: DEFAULT_PORT,
                service: "XE".into(),
                user: "scott".into(),
                password: "tiger".into(),
                tls: false,
                auth: Auth::Default,
                wallet_dir: None,
                wallet_password: None,
                tns_admin: None,
                descriptor: None,
            }
        );
    }

    #[test]
    fn options_name_a_privilege_a_wallet_or_tns() {
        let target = parse_url("oracle://scott:tiger@db.example.com:1521/ORCL?as=sysdba").unwrap();
        assert_eq!(target.auth, Auth::SysDba);
        assert_eq!(connect_string(&target), "db.example.com:1521/ORCL");
        let target = parse_url("oracle://scott:tiger@db.example.com/ORCL?as=sysoper").unwrap();
        assert_eq!(target.auth, Auth::SysOper);
        assert_eq!(target.port, DEFAULT_PORT);
        let target = parse_url(
            "oracletcps://scott:tiger@db.example.com/ORCL?wallet=/opt/oracle/wallet&wallet_password=s3cret",
        )
        .unwrap();
        assert_eq!(target.wallet_dir.as_deref(), Some("/opt/oracle/wallet"));
        assert_eq!(target.wallet_password.as_deref(), Some("s3cret"));
        let target =
            parse_url("oracle://scott:tiger@/FINPROD?tns_admin=/opt/oracle/network").unwrap();
        assert_eq!(target.service, "FINPROD");
        assert_eq!(target.tns_admin.as_deref(), Some("/opt/oracle/network"));
        assert_eq!(connect_string(&target), "FINPROD");
        let target = parse_url(
            "oracle://scott:tiger@/?tns=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db)(PORT=1521))(CONNECT_DATA=(SID=ORCL)))",
        )
        .unwrap();
        assert_eq!(
            target.descriptor.as_deref(),
            Some(
                "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db)(PORT=1521))(CONNECT_DATA=(SID=ORCL)))"
            )
        );
        assert_eq!(
            connect_string(&target),
            "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db)(PORT=1521))(CONNECT_DATA=(SID=ORCL)))"
        );
    }

    #[test]
    fn bad_options_and_shapes_are_refused() {
        assert!(parse_url("oracle://u:p@h/s?as=root").is_err());
        assert!(parse_url("oracle://u:p@h/s?bogus=1").is_err());
        assert!(parse_url("oracle://u:p@h/s?wallet=").is_err());
        assert!(parse_url("oracle://u:p@h/s?wallet_password=x").is_err());
        assert!(parse_url("oracle://u:p@h/s?tns=").is_err());
        assert!(parse_url("oracle://u:p@h/s?tns=x&tns_admin=y").is_err());
        assert!(parse_url("oracle://u:p@h/s?tns_admin=d").is_err());
        assert!(parse_url("oracle://u:p@h:1521/s?tns_admin=d").is_err());
        assert!(parse_url("oracle://u:p@h/?tns=(DESCRIPTION=x)").is_err());
        assert!(parse_url("oracle://u:p@h/s?tns=(DESCRIPTION=x)").is_err());
    }

    #[test]
    fn a_tcps_url_turns_tls_on_with_its_own_port() {
        let target = parse_url("oracletcps://scott:tiger@db.example.com/XE").unwrap();
        assert!(target.tls);
        assert_eq!(target.port, DEFAULT_TCPS_PORT);
        assert_eq!(connect_string(&target), "tcps://db.example.com:2484/XE");
        assert_eq!(
            connect_string(&parse_url("oracle://u:p@h:1521/s").unwrap()),
            "h:1521/s"
        );
    }

    #[test]
    fn a_url_without_a_user_or_service_is_refused() {
        assert!(parse_url("oracle://h/s").is_err());
        assert!(parse_url("oracle://u@h/").is_err());
        assert!(parse_url("oracle://u@h/a/b").is_err());
        assert!(parse_url("oracle://u@h/s?ssl=true").is_err());
        assert!(parse_url("postgres://u@h/s").is_err());
    }

    #[test]
    fn only_a_plain_explain_plan_reads_its_plan_back() {
        assert_eq!(
            explain_inner("explain plan for select 1 from dual"),
            Some("select 1 from dual")
        );
        assert_eq!(
            explain_inner("-- look\nEXPLAIN PLAN FOR select 1 from dual"),
            Some("select 1 from dual")
        );
        assert_eq!(explain_inner("explain plan for"), Some(""));
        assert_eq!(explain_inner("select 1 from dual"), None);
        assert_eq!(explain_inner("explain"), None);
        assert_eq!(explain_inner("explain plan"), None);
        assert_eq!(
            explain_inner("explain plan set statement_id = 'x' for select 1 from dual"),
            None
        );
        assert_eq!(
            explain_inner("explain plan into other for select 1 from dual"),
            None
        );
        assert_eq!(explain_inner("explain plans for select 1 from dual"), None);
    }

    #[test]
    fn only_a_bare_commit_or_rollback_takes_the_api_path() {
        assert_eq!(bare_transaction("commit"), Some(true));
        assert_eq!(bare_transaction("  COMMIT;  "), Some(true));
        assert_eq!(bare_transaction("-- done\ncommit"), Some(true));
        assert_eq!(bare_transaction("rollback"), Some(false));
        assert_eq!(bare_transaction("ROLLBACK -- undo"), Some(false));
        assert_eq!(bare_transaction("commit work"), None);
        assert_eq!(bare_transaction("rollback to savepoint sp"), None);
        assert_eq!(bare_transaction("committed"), None);
        assert_eq!(bare_transaction("select 1 from dual"), None);
    }

    #[test]
    fn only_stored_plsql_takes_the_dynamic_sql_path() {
        assert!(stores_plsql(
            "create or replace trigger t before insert on e begin null; end;"
        ));
        assert!(stores_plsql("CREATE PROCEDURE p AS BEGIN NULL; END;"));
        assert!(stores_plsql(
            "-- a comment\ncreate or replace editionable package p as procedure q; end;"
        ));
        assert!(!stores_plsql(
            "create table t as select * from e where id = :1"
        ));
        assert!(!stores_plsql("select * from e where id = :1"));
        assert!(!stores_plsql("begin null; end;"));
    }

    #[test]
    fn dynamic_sql_hides_placeholders_and_doubles_quotes() {
        assert_eq!(
            immediate_block("create trigger t begin null; end;"),
            "BEGIN EXECUTE IMMEDIATE 'create trigger t begin null; end;'; END;"
        );
        assert_eq!(
            immediate_block("insert into t values ('it''s :x')"),
            "BEGIN EXECUTE IMMEDIATE 'insert into t values (''it''''s :x'')'; END;"
        );
    }

    #[test]
    fn an_exact_numeric_fits_an_integer() {
        assert_eq!(number_text("42"), Cell::Int(42));
        assert_eq!(number_text("-7"), Cell::Int(-7));
        assert_eq!(
            number_text("99999999999999999999"),
            Cell::Decimal("99999999999999999999".into())
        );
        assert_eq!(number_text("1.50"), Cell::Decimal("1.50".into()));
    }

    #[test]
    fn finds_the_one_table_a_plain_select_reads() {
        assert_eq!(
            single_table("select id, name from hr.people order by id"),
            Some((Some("hr".into()), "people".into()))
        );
        assert_eq!(
            single_table("SELECT * FROM \"my table\" t"),
            Some((None, "my table".into()))
        );
        assert_eq!(single_table("select a, b from t1, t2"), None);
        assert_eq!(single_table("select * from a join b on a.id = b.id"), None);
        assert_eq!(single_table("update t set a = 1"), None);
        assert_eq!(
            single_table("select 1 from dual"),
            Some((None, "dual".into()))
        );
    }
}
