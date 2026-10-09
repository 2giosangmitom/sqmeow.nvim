//! The MySQL and MariaDB adapter.

mod native;

#[cfg(test)]
mod cancellation_tests {
    use super::*;
    use std::{
        future::{Future, poll_fn},
        task::Poll,
        time::Duration,
    };

    #[tokio::test(flavor = "current_thread")]
    async fn late_cancel_keeps_a_commit_confirmed_by_another_session() {
        let Ok(url) = std::env::var("SQMEOW_TEST_MYSQL_URL") else {
            eprintln!("skipped: set SQMEOW_TEST_MYSQL_URL");
            return;
        };
        let _ = rustls::crypto::ring::default_provider().install_default();
        let adapter = MySqlAdapter::connect(&url, false).await.unwrap();
        let observer = MySqlAdapter::connect(&url, false).await.unwrap();
        adapter
            .execute(
                "drop table if exists audit_commit_reply",
                usize::MAX,
                CancellationToken::new(),
            )
            .await
            .unwrap();
        adapter
            .execute(
                "create table audit_commit_reply (id int)",
                usize::MAX,
                CancellationToken::new(),
            )
            .await
            .unwrap();
        let mut session = adapter.pool.lock().await;
        let connection = session.as_mut().unwrap();
        connection.query_drop("start transaction").await.unwrap();
        connection
            .query_drop("insert into audit_commit_reply values (1)")
            .await
            .unwrap();
        let cancel = CancellationToken::new();
        let work = adapter.run_owned(connection, "commit", None, usize::MAX, &cancel);
        tokio::pin!(work);
        poll_fn(|cx| {
            assert!(work.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let rows = observer
                    .execute(
                        "select * from audit_commit_reply",
                        usize::MAX,
                        CancellationToken::new(),
                    )
                    .await
                    .unwrap();
                if rows.row_count() == 1 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("server must commit before the reply is consumed");
        cancel.cancel();
        work.await
            .expect("a confirmed COMMIT cannot become Cancelled");
    }
}
use mysql_async::{Conn, Opts, prelude::Queryable};
use native::{Session, foreign_key, query, query_as, query_scalar};
use sqmeow_db::adapter::Adapter;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::TableName;
use sqmeow_db::error::Error;
use sqmeow_db::error::Result;
use sqmeow_db::node::ColumnNode;
use sqmeow_db::node::RelationKind;
use sqmeow_db::node::RelationNode;
use sqmeow_db::node::RoutineNode;
use sqmeow_db::node::SchemaNode;
use sqmeow_db::result::ResultSet;
use sqmeow_db::types::KeyKind;
use sqmeow_db::value::Cell;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::stream::{self, Keys, TableKeys};

/// Persistent sessions against one MySQL or MariaDB database.
#[derive(Debug)]
pub struct MySqlAdapter {
    pool: Session,
    /// A session of its own for the drawer, which a long query on `pool` does not hold up.
    meta: Session,
    /// Which columns of a table are keys, read from `information_schema` a whole table at a time.
    keys: TableKeys,
    /// Connection options for the independent cancellation session.
    options: Opts,
    preferred_tls: bool,
    /// Configured label is valid only until user SQL may modify the session timezone.
    timezone: String,
    timezone_known: AtomicBool,
    /// A timed-out KILL must never be allowed to hit a subsequent request.
    unusable: AtomicBool,
    /// The persistent execution session's server id, which `KILL QUERY` names.
    connection_id: u32,
}

/// A dropped protocol/transaction future must never expose its unfinished session for reuse.
struct Unfinished<'a> {
    unusable: &'a AtomicBool,
    armed: bool,
}

impl Drop for Unfinished<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.unusable.store(true, Ordering::Release);
        }
    }
}

impl MySqlAdapter {
    async fn run_owned(
        &self,
        connection: &mut Conn,
        statement: &str,
        values: Option<&[sqmeow_db::sql::parameters::Value]>,
        max_rows: usize,
        cancel: &CancellationToken,
    ) -> Result<native::Results> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.unusable.load(Ordering::Acquire) {
            return Err(Error::driver(
                "cancellation connection failed; execution session cannot safely be reused",
            ));
        }
        let mut unfinished = Unfinished {
            unusable: &self.unusable,
            armed: true,
        };
        if sqmeow_db::sql::split(statement, Dialect::MySql)
            .iter()
            .any(|part| {
                matches!(
                    sqmeow_db::sql::first_word(&part.sql).as_str(),
                    "set" | "call" | "do"
                )
            })
        {
            self.timezone_known.store(false, Ordering::Release);
        }
        let timezone = if self.timezone_known.load(Ordering::Acquire) {
            self.timezone.as_str()
        } else {
            ""
        };
        let work = native::execute(connection, statement, values, max_rows, cancel, timezone);
        tokio::pin!(work);
        let outcome = tokio::select! {
            biased;
            () = cancel.cancelled() => {
                if !stream::interruptible(Dialect::MySql, statement) {
                    work.await
                } else {
                // Keep the original protocol future alive. KILL finishes before we release
                // execution ownership, so it cannot target the next request.
                if !self.stop_query().await { self.unusable.store(true, Ordering::Release); }
                match tokio::time::timeout(crate::STOP_TIMEOUT, &mut work).await {
                    Ok(outcome) => outcome,
                    Err(_) => {
                        self.unusable.store(true, Ordering::Release);
                        Err(Error::driver("cancel cleanup timed out; query/write outcome may be unknown, verify before retrying"))
                    }
                }
                }
            }
            result = &mut work => result,
        };
        unfinished.armed = false;
        outcome
    }

    async fn run(
        &self,
        statement: &str,
        origin: &str,
        values: Option<&[sqmeow_db::sql::parameters::Value]>,
        max_rows: usize,
        cancel: &CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        let started = std::time::Instant::now();
        let results = {
            let mut session = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(Error::Cancelled),
                session = self.pool.lock() => session,
            };
            let connection = session
                .as_mut()
                .ok_or_else(|| Error::driver("connection is closed"))?;
            let outcome = self
                .run_owned(connection, statement, values, max_rows, cancel)
                .await;
            if self.unusable.load(Ordering::Acquire) {
                session.take();
                if outcome.is_err() {
                    return Err(Error::driver(
                        "cancel cleanup failed; execution session was closed",
                    ));
                }
            }
            if stream::may_change_schema(statement) {
                self.keys.forget();
            }
            outcome?
        };
        let mut retained = Vec::with_capacity(results.len());
        for (mut result, origins) in results {
            self.keys
                .mark(&origins, result.columns_mut(), |table| {
                    self.read_keys(table)
                })
                .await;
            result.set_source(self.keys.source(
                &origins,
                sqmeow_db::sql::plain(Dialect::MySql, origin),
                sqmeow_db::sql::Sides::read(Dialect::MySql, origin),
            ));
            result.set_elapsed(started.elapsed());
            retained.push(result);
        }
        Ok(retained)
    }

    /// Open a connection.
    pub async fn connect(url: &str, read_only: bool) -> Result<Self> {
        let (options, preferred_tls, timezone) = native::options(url)?;
        let mut connection = crate::connect_retrying_with(
            || native::connect(options.clone(), preferred_tls),
            native::retryable,
        )
        .await
        .map_err(Error::driver)?;
        let connection_id = connection.id();
        if read_only {
            connection
                .query_drop("set session transaction read only")
                .await
                .map_err(Error::driver)?;
        }
        let pool = Mutex::new(Some(connection));
        let meta = Mutex::new(Some(
            native::connect(options.clone(), preferred_tls)
                .await
                .map_err(Error::driver)?,
        ));

        Ok(Self {
            pool,
            meta,
            keys: TableKeys::default(),
            options,
            preferred_tls,
            timezone,
            timezone_known: AtomicBool::new(true),
            unusable: AtomicBool::new(false),
            connection_id,
        })
    }

    /// Stop the query the session is running, from a connection of its own.
    async fn stop_query(&self) -> bool {
        let id = self.connection_id;
        let stop = async {
            let mut connection = native::connect(self.options.clone(), self.preferred_tls).await?;
            // `KILL` cannot be prepared, and the id is a number this adapter read itself.
            connection.query_drop(format!("kill query {id}")).await?;
            connection.disconnect().await
        };
        match tokio::time::timeout(crate::STOP_TIMEOUT, stop).await {
            Ok(Ok(())) => true,
            Ok(Err(error)) => {
                tracing::debug!(%error, "could not stop a cancelled query");
                false
            }
            Err(_) => {
                tracing::debug!("stopping a cancelled query took too long");
                false
            }
        }
    }

    /// Ask `information_schema` which columns of one table are keys.
    async fn read_keys(&self, origin: TableName) -> Keys {
        let (schema, table) = (origin.schema.as_deref(), origin.name.as_str());

        let rows = query(
            "select c.column_name as column_name,
                    c.column_key = 'PRI' as primary_key,
                    exists (
                        select 1 from information_schema.key_column_usage k
                        where k.table_schema = c.table_schema
                          and k.table_name = c.table_name
                          and k.column_name = c.column_name
                          and k.referenced_table_name is not null
                    ) as foreign_key,
                    c.extra like '%auto_increment%' as is_generated
             from information_schema.columns c
             -- An unqualified table is one in the connection's own database, which is the server's
             -- to name rather than something this side has to go and ask for.
             where c.table_schema = coalesce(?, database()) and c.table_name = ?",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.meta)
        .await;

        let rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                tracing::debug!(%error, ?origin, "could not read which result columns are keys");
                return Keys::default();
            }
        };

        Keys {
            kinds: rows
                .iter()
                .filter_map(|row| {
                    let column = row.try_get::<String, _>("column_name").ok()?;
                    Some((column, key_kind(row)))
                })
                .collect(),
            unique: self.unique_keys(schema, table).await,
            generated: rows
                .iter()
                .filter(|row| row.try_get::<i64, _>("is_generated").unwrap_or(0) != 0)
                .filter_map(|row| row.try_get::<String, _>("column_name").ok())
                .collect(),
        }
    }

    /// The columns of each unique index on a table other than its primary key.
    async fn unique_keys(&self, schema: Option<&str>, table: &str) -> Vec<Vec<String>> {
        let rows = query(
            "select s.index_name as index_name, s.column_name as column_name
             from information_schema.statistics s
             where s.table_schema = coalesce(?, database()) and s.table_name = ?
               and s.non_unique = 0 and s.index_name <> 'PRIMARY'
             order by s.index_name, s.seq_in_index",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.meta)
        .await
        .unwrap_or_default();

        let mut indexes: Vec<(String, Option<Vec<String>>)> = Vec::new();
        for row in &rows {
            let Ok(index) = row.try_get::<String, _>("index_name") else {
                continue;
            };
            // A functional index part has no column.
            let column = row
                .try_get::<Option<String>, _>("column_name")
                .ok()
                .flatten();
            match indexes.last_mut() {
                Some((name, columns)) if *name == index => match (columns.as_mut(), column) {
                    (Some(columns), Some(column)) => columns.push(column),
                    _ => *columns = None,
                },
                _ => indexes.push((index, column.map(|column| vec![column]))),
            }
        }
        indexes
            .into_iter()
            .filter_map(|(_, columns)| columns)
            .collect()
    }
}

/// Single-result callers see the last tabular answer, not CALL's trailing OK.
fn last(mut results: Vec<ResultSet>, statement: &str) -> ResultSet {
    let index = results
        .iter()
        .rposition(|result| !result.columns().is_empty());
    match index {
        Some(index) => results.swap_remove(index),
        None => results
            .pop()
            .unwrap_or_else(|| ResultSet::new(statement, Vec::new())),
    }
}

/// Which key an `information_schema` row says a column is.
fn key_kind(row: &native::Row) -> KeyKind {
    // Both come back as integers: MySQL has no boolean, and a comparison yields 1 or 0.
    let flag = |name| row.try_get::<i64, _>(name).unwrap_or(0) != 0;

    if flag("primary_key") {
        KeyKind::Primary
    } else if flag("foreign_key") {
        KeyKind::Foreign
    } else {
        KeyKind::None
    }
}

#[async_trait::async_trait]
impl Adapter for MySqlAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::MySql
    }

    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        // MySQL DDL and transaction controls can implicitly commit. They cannot be
        // part of an atomic edit batch whose cancellation promises rollback.
        for statement in statements {
            if sqmeow_db::sql::split(statement, Dialect::MySql).len() != 1
                || !matches!(
                    sqmeow_db::sql::first_word(statement).as_str(),
                    "insert" | "update" | "delete" | "replace" | "select" | "with"
                )
            {
                return Err(Error::driver(
                    "atomic MySQL edits cannot contain statements that may implicitly commit",
                ));
            }
        }
        let mut session = self.pool.lock().await;
        let connection = session
            .as_mut()
            .ok_or_else(|| Error::driver("connection is closed"))?;
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        if self.unusable.load(Ordering::Acquire) {
            return Err(Error::driver("execution session cannot safely be reused"));
        }
        let mut unfinished = Unfinished {
            unusable: &self.unusable,
            armed: true,
        };
        connection
            .query_drop("start transaction")
            .await
            .map_err(Error::driver)?;
        let mut returned = Vec::new();
        for statement in statements {
            let outcome = self
                .run_owned(connection, statement, None, usize::MAX, &cancel)
                .await;
            let outcome = outcome.and_then(|results| {
                for (result, _) in &results {
                    stream::check_affected(statement, result.affected().unwrap_or(0))?;
                }
                Ok(results)
            });
            match outcome {
                Ok(results) => {
                    for (result, _) in results {
                        if result.row_count() > 0 {
                            returned.push(result);
                        }
                    }
                }
                Err(error) => {
                    if self.unusable.load(Ordering::Acquire) {
                        session.take();
                        return Err(Error::driver(
                            "cancel cleanup failed; transaction session was closed",
                        ));
                    }
                    connection
                        .query_drop("rollback")
                        .await
                        .map_err(Error::driver)?;
                    unfinished.armed = false;
                    return Err(if matches!(error, Error::Cancelled) {
                        error
                    } else {
                        stream::rolled_back(error)
                    });
                }
            }
        }
        if cancel.is_cancelled() {
            connection
                .query_drop("rollback")
                .await
                .map_err(Error::driver)?;
            unfinished.armed = false;
            return Err(Error::Cancelled);
        }
        // Once COMMIT is sent, cancellation must not claim that no changes were committed.
        connection.query_drop("commit").await.map_err(|error| {
            Error::driver(format!(
                "commit failed; outcome may be unknown, verify before retrying: {error}"
            ))
        })?;
        unfinished.armed = false;
        Ok(returned)
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(last(
            self.run(statement, statement, None, max_rows, &cancel)
                .await?,
            statement,
        ))
    }

    async fn execute_bound(
        &self,
        statement: &str,
        values: &[sqmeow_db::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(last(
            self.run(statement, statement, Some(values), max_rows, &cancel)
                .await?,
            statement,
        ))
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(last(
            self.run(statement, origin, None, max_rows, &cancel).await?,
            statement,
        ))
    }

    async fn execute_results(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.run(statement, origin, None, max_rows, &cancel).await
    }

    async fn execute_bound_results(
        &self,
        statement: &str,
        values: &[sqmeow_db::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.run(statement, statement, Some(values), max_rows, &cancel)
            .await
    }

    /// MySQL has no schemas within a database, so its databases fill that level of the tree.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let rows = query(
            "select schema_name as name, schema_name = database() as is_default
             from information_schema.schemata
             where schema_name not in
                   ('information_schema', 'performance_schema', 'mysql', 'sys')
             order by schema_name",
        )
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(SchemaNode {
                    name: row.try_get::<String, _>("name").ok()?,
                    // `database()` is null when the URL named no database, and comparing against
                    // null is null rather than false.
                    is_default: row
                        .try_get::<Option<bool>, _>("is_default")
                        .ok()?
                        .unwrap_or(false),
                })
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let rows = query(
            "select table_name as name, table_type as kind
             from information_schema.tables
             where table_schema = ?
             order by table_name",
        )
        .bind(schema)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<String, _>("name").ok()?;
                let kind = match row.try_get::<String, _>("kind").ok()?.as_str() {
                    "BASE TABLE" => RelationKind::Table,
                    "VIEW" => RelationKind::View,
                    _ => RelationKind::Other,
                };
                Some(RelationNode { name, kind })
            })
            .collect())
    }

    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        let rows = query(
            "select routine_name as name, lower(routine_type) as kind
             from information_schema.routines
             where routine_schema = ?
             order by routine_name",
        )
        .bind(schema)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<String, _>("name").ok()?;
                let kind = row.try_get::<String, _>("kind").ok()?;
                Some(crate::routine_node(name, &kind))
            })
            .collect())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        // `column_type` keeps the declared width and signedness, which `data_type` drops.
        let rows = query(
            "select c.column_name as name,
                    c.column_type as type_name,
                    c.is_nullable as nullable,
                    c.column_key as key_kind,
                    concat(k.referenced_table_schema, '.', k.referenced_table_name) as references_table,
                    k.referenced_column_name as references_column,
                    c.column_default as default_value
             from information_schema.columns c
             -- One row per column even where a column takes part in several constraints: the
             -- drawer shows one target, and the lowest ordinal is the first one declared.
             left join information_schema.key_column_usage k
                    on k.table_schema = c.table_schema
                   and k.table_name = c.table_name
                   and k.column_name = c.column_name
                   and k.referenced_table_name is not null
                   and k.ordinal_position = (
                       select min(k2.ordinal_position)
                       from information_schema.key_column_usage k2
                       where k2.table_schema = c.table_schema
                         and k2.table_name = c.table_name
                         and k2.column_name = c.column_name
                         and k2.referenced_table_name is not null
                   )
             where c.table_schema = ? and c.table_name = ?
             order by c.ordinal_position",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(ColumnNode {
                    name: row.try_get::<String, _>("name").ok()?,
                    type_name: row.try_get::<String, _>("type_name").ok()?,
                    nullable: row.try_get::<String, _>("nullable").ok()? == "YES",
                    primary_key: row.try_get::<String, _>("key_kind").ok()? == "PRI",
                    foreign_key: foreign_key(row),
                    default: row
                        .try_get::<Option<String>, _>("default_value")
                        .ok()
                        .flatten(),
                })
            })
            .collect())
    }

    async fn indexes(
        &self,
        schema: &str,
        relation: &str,
    ) -> Result<Vec<sqmeow_db::node::IndexNode>> {
        let rows = query(
            "select s.index_name as index_name, s.non_unique as non_unique,
                    s.column_name as column_name
             from information_schema.statistics s
             where s.table_schema = ? and s.table_name = ?
             order by s.index_name, s.seq_in_index",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let mut indexes: Vec<sqmeow_db::node::IndexNode> = Vec::new();
        for row in &rows {
            let name: String = row.try_get("index_name").map_err(Error::driver)?;
            let column = row
                .try_get::<Option<String>, _>("column_name")
                .ok()
                .flatten()
                .unwrap_or_else(|| "(expression)".to_owned());
            match indexes.last_mut() {
                Some(index) if index.name == name => index.columns.push(column),
                _ => indexes.push(sqmeow_db::node::IndexNode {
                    unique: row.try_get::<i64, _>("non_unique").unwrap_or(1) == 0,
                    primary: name == "PRIMARY",
                    columns: vec![column],
                    name,
                }),
            }
        }
        Ok(indexes)
    }

    async fn relationships(
        &self,
        schema: &str,
        relation: &str,
    ) -> Result<Vec<sqmeow_db::node::RelationshipNode>> {
        let rows = query_as::<(String, String, String, String, String, String, String)>(
            "select constraint_name, table_schema, table_name, column_name,
                    referenced_table_schema, referenced_table_name, referenced_column_name
             from information_schema.key_column_usage
             where referenced_table_name is not null
               and ((table_schema = ? and table_name = ?)
                 or (referenced_table_schema = ? and referenced_table_name = ?))
             order by table_schema, table_name, constraint_name, ordinal_position",
        )
        .bind(schema)
        .bind(relation)
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        Ok(crate::relationship_nodes(rows))
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<sqmeow_db::node::Details> {
        let comment = query_scalar::<String>(
            "select table_comment from information_schema.tables
             where table_schema = ? and table_name = ?",
        )
        .bind(schema)
        .bind(relation)
        .fetch_optional(&self.meta)
        .await
        .map_err(Error::driver)?
        .filter(|comment| !comment.is_empty());
        let column_comments = query_as::<(String, String)>(
            "select column_name, column_comment from information_schema.columns
             where table_schema = ? and table_name = ? and column_comment <> ''
             order by ordinal_position",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let parts = query_as::<(String, String, String, String, String)>(
            "select constraint_name, column_name, referenced_table_schema, referenced_table_name,
                    referenced_column_name
             from information_schema.key_column_usage
             where table_schema = ? and table_name = ? and referenced_table_name is not null
             order by constraint_name, ordinal_position",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let mut foreign_keys: Vec<sqmeow_db::node::ForeignKeyNode> = Vec::new();
        for (name, column, target_schema, target, referenced) in parts {
            if foreign_keys.last().is_none_or(|key| key.name != name) {
                foreign_keys.push(sqmeow_db::node::ForeignKeyNode {
                    name,
                    columns: Vec::new(),
                    target: format!("{target_schema}.{target}"),
                    referenced: Vec::new(),
                });
            }
            let key = foreign_keys.last_mut().expect("pushed above");
            key.columns.push(column);
            key.referenced.push(referenced);
        }

        let checks = query_as::<(String, String)>(
            "select cc.constraint_name, cc.check_clause
             from information_schema.check_constraints cc
             join information_schema.table_constraints tc
               on tc.constraint_schema = cc.constraint_schema
              and tc.constraint_name = cc.constraint_name
             where tc.table_schema = ? and tc.table_name = ? and tc.constraint_type = 'CHECK'
             order by cc.constraint_name",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let triggers = query_as::<(String, String)>(
            "select trigger_name, concat(action_timing, ' ', event_manipulation)
             from information_schema.triggers
             where event_object_schema = ? and event_object_table = ?
             order by trigger_name",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let sql = format!(
            "show create table {}.{}",
            self.quote_ident(schema),
            self.quote_ident(relation)
        );
        let definition = query(sql)
            .fetch_optional(&self.meta)
            .await
            .map_err(Error::driver)?
            .and_then(|row| row.try_get::<String, _>(1).ok());

        Ok(sqmeow_db::node::Details {
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
    }

    async fn roles(&self) -> Result<Vec<sqmeow_db::node::RoleNode>> {
        let rows = query_as::<(String, String, String)>(
            "select user, host, account_locked from mysql.user order by user, host",
        )
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        Ok(rows
            .into_iter()
            .map(|(user, host, locked)| sqmeow_db::node::RoleNode {
                name: format!("{user}@{host}"),
                attributes: (locked == "Y")
                    .then(|| "locked".to_owned())
                    .into_iter()
                    .collect(),
            })
            .collect())
    }

    async fn close(&self) {
        for session in [&self.meta, &self.pool] {
            if let Some(connection) = session.lock().await.take() {
                let _ = connection.disconnect().await;
            }
        }
    }
}

/// Bytes that read as text, shown as text.
fn binary(bytes: Vec<u8>) -> Cell {
    match String::from_utf8(bytes) {
        Ok(text)
            if !text.chars().any(|character| {
                character.is_control() && !matches!(character, '\n' | '\r' | '\t')
            }) =>
        {
            Cell::Text(text)
        }
        Ok(text) => Cell::bytes(text.as_bytes()),
        Err(error) => Cell::bytes(error.as_bytes()),
    }
}
