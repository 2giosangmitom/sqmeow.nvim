//! The PostgreSQL adapter.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use tokio_postgres::{Column as PgColumn, Row as PgRow};
type Oid = u32;
mod codec;
mod native;
use futures_util::StreamExt;
use native as pg;
use native::{Options, Session};
use sqmeow_db::adapter::Adapter;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::Source;
use sqmeow_db::edit::TableBinder;
use sqmeow_db::edit::TableName;
use sqmeow_db::error::Error;
use sqmeow_db::error::Result;
use sqmeow_db::node::ColumnNode;
use sqmeow_db::node::RelationKind;
use sqmeow_db::node::RelationNode;
use sqmeow_db::node::RoutineNode;
use sqmeow_db::node::SchemaNode;
use sqmeow_db::result::Column;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::types::KeyKind;
use tokio_postgres::types::{ToSql, Type};
use tokio_util::sync::CancellationToken;

use crate::stream;
use codec::{decode_cell, result_columns};

/// Persistent execution and drawer sessions against one PostgreSQL database.
#[derive(Debug)]
pub struct PostgresAdapter {
    pool: Session,
    /// A session of its own for the drawer, which a long query on `pool` does not hold up.
    meta: Session,
    /// Which of a table's columns are keys, by table OID and attribute number.
    keys: Mutex<HashMap<(Oid, i16), KeyKind>>,
    /// What a table is called, its columns by attribute number, and its primary key, by OID.
    relations: Mutex<HashMap<Oid, Relation>>,
    /// Whether the URL named no database, so the drawer lists the server's databases instead.
    cluster: bool,
    /// Connection/TLS options for native cancellation and Cockroach's auxiliary session.
    options: Options,
    /// Serializes execution, including cancellation cleanup and manual transactions.
    execution: tokio::sync::Mutex<()>,
    /// The CockroachDB session behind the pool's one connection, which it cancels by instead.
    cockroach_session: Arc<Mutex<Option<String>>>,
    /// Whether a read-only connection's server keeps the session read-only; some servers that
    /// speak the protocol ignore or refuse the setting, leaving only the engine's check.
    read_only_session: Arc<AtomicBool>,
}

impl PostgresAdapter {
    /// Open a connection, to `database` when given and otherwise to the one the URL names.
    pub async fn connect(url: &str, database: Option<&str>, read_only: bool) -> Result<Self> {
        let (options, cluster) = Options::parse(url, database)?;
        let read_only_session = Arc::new(AtomicBool::new(false));
        let cockroach_session = Arc::new(Mutex::new(None));
        let pool = options.open_retrying().await?;
        let version = pool
            .client()
            .await?
            .query_one("select version()", &[])
            .await
            .map_err(Error::driver)?
            .get::<_, String>(0);
        if version.starts_with("CockroachDB") {
            let rows = pool
                .client()
                .await?
                .simple_query("show session_id")
                .await
                .map_err(Error::driver)?;
            if let Some(tokio_postgres::SimpleQueryMessage::Row(row)) = rows.first() {
                *cockroach_session.lock().unwrap() = row.get(0).map(str::to_owned);
            }
        }
        if read_only {
            read_only_session.store(make_read_only(&pool).await, Ordering::Relaxed);
        }
        let meta = options.open_retrying().await?;

        Ok(Self {
            pool,
            meta,
            keys: Mutex::default(),
            relations: Mutex::default(),
            cluster,
            options,
            execution: tokio::sync::Mutex::new(()),
            cockroach_session,
            read_only_session,
        })
    }

    /// The databases a connection to the whole cluster can open, or `None` for one database.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        if !self.cluster {
            return None;
        }
        Some(
            pg::query_scalar(
                "select datname from pg_database
                 where datallowconn and not datistemplate
                 order by datname",
            )
            .fetch_all(&self.meta)
            .await
            .map_err(Error::driver),
        )
    }

    /// Whether the server itself keeps a read-only connection read-only.
    pub fn read_only_session(&self) -> bool {
        self.read_only_session.load(Ordering::Relaxed)
    }

    /// Stop the query the session is running, from a connection of its own.
    async fn stop_query(&self) -> Result<()> {
        let cockroach = self
            .cockroach_session
            .lock()
            .ok()
            .and_then(|session| session.clone());
        let stop = async {
            if let Some(session) = &cockroach {
                let connection = self.options.open_retrying().await?;
                pg::query(
                    "cancel queries if exists (select query_id from [show cluster statements]
                     where session_id = $1)",
                )
                .bind(session)
                .fetch_all(&connection)
                .await
                .map_err(Error::driver)?;
                connection.close().await;
            } else {
                self.options
                    .cancel(self.pool.client().await?.as_ref())
                    .await?;
            }
            Ok::<_, Error>(())
        };
        match tokio::time::timeout(crate::STOP_TIMEOUT, stop).await {
            Ok(result) => result,
            Err(_) => Err(Error::driver(
                "stopping a cancelled PostgreSQL query timed out",
            )),
        }
    }

    /// Forget every table read so far, so each is read again the next time a result comes from it.
    fn forget_tables(&self) {
        if let Ok(mut keys) = self.keys.lock() {
            keys.clear();
        }
        if let Ok(mut relations) = self.relations.lock() {
            relations.clear();
        }
    }

    /// What a statement's result looks like, with the columns that are keys marked.
    async fn columns(&self, statement: &str) -> (Vec<Column>, Option<Source>) {
        let Ok(client) = self.pool.client().await else {
            return (Vec::new(), None);
        };
        let Ok(prepared) = client.prepare(statement).await else {
            return (Vec::new(), None);
        };
        self.described_columns(statement, prepared.columns()).await
    }

    async fn described_columns(
        &self,
        statement: &str,
        prepared: &[PgColumn],
    ) -> (Vec<Column>, Option<Source>) {
        let mut columns = result_columns(prepared);
        self.mark_keys(prepared, &mut columns).await;
        let plain = sqmeow_db::sql::plain(Dialect::Postgres, statement);
        let sides = sqmeow_db::sql::Sides::read(Dialect::Postgres, statement);
        let source = self.source(prepared, plain, sides).await;
        (columns, source)
    }

    /// Mark the result columns that are keys in the table they came from.
    async fn mark_keys(&self, prepared: &[PgColumn], columns: &mut [Column]) {
        let sources: Vec<Option<(Oid, i16)>> = prepared
            .iter()
            .map(|column| column.table_oid().zip(column.column_id()))
            .collect();

        let missing: Vec<(Oid, i16)> = {
            let Ok(known) = self.keys.lock() else {
                return;
            };
            let mut missing: Vec<(Oid, i16)> = sources
                .iter()
                .flatten()
                .filter(|source| !known.contains_key(source))
                .copied()
                .collect();
            missing.sort_unstable();
            missing.dedup();
            missing
        };

        if !missing.is_empty() {
            let found = self.read_keys(&missing).await;
            if let Ok(mut known) = self.keys.lock() {
                // Record every pair asked about, including ones the catalog knows nothing of.
                for source in missing {
                    let kind = found.get(&source).copied().unwrap_or_default();
                    known.insert(source, kind);
                }
            }
        }

        let Ok(known) = self.keys.lock() else {
            return;
        };
        for (column, source) in columns.iter_mut().zip(sources) {
            if let Some(kind) = source.and_then(|source| known.get(&source)) {
                column.key = *kind;
            }
        }
    }

    /// Ask the catalog which of these columns are keys.
    async fn read_keys(&self, wanted: &[(Oid, i16)]) -> HashMap<(Oid, i16), KeyKind> {
        let relations: Vec<Oid> = wanted.iter().map(|(relation, _)| *relation).collect();
        let attributes: Vec<i16> = wanted.iter().map(|(_, attribute)| *attribute).collect();

        // The primary key wins over a foreign one.
        let rows = pg::query(
            "select want.relation, want.attribute,
                    bool_or(c.contype = 'p') as primary_key,
                    bool_or(c.contype = 'f') as foreign_key
             from unnest($1::oid[], $2::int2[]) as want(relation, attribute)
             left join pg_catalog.pg_constraint c
                    on c.conrelid = want.relation
                   and want.attribute = any(c.conkey)
                   and c.contype in ('p', 'f')
             group by want.relation, want.attribute",
        )
        .bind(&relations)
        .bind(&attributes)
        .fetch_all(&self.pool)
        .await;

        let rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                tracing::debug!(%error, "could not read which result columns are keys");
                return HashMap::new();
            }
        };

        rows.iter()
            .filter_map(|row| {
                let relation = row.try_get::<_, Oid>("relation").ok()?;
                let attribute = row.try_get::<_, i16>("attribute").ok()?;
                Some(((relation, attribute), key_kind(row)))
            })
            .collect()
    }
}

impl PostgresAdapter {
    /// A table's `CREATE TABLE`, built from the catalog, with the indexes no constraint made.
    async fn table_definition(&self, oid: Oid, schema: &str, relation: &str) -> Result<String> {
        let columns = pg::query_as::<(String, String, bool, Option<String>)>(
            "select a.attname::text, format_type(a.atttypid, a.atttypmod), a.attnotnull,
                    pg_get_expr(d.adbin, d.adrelid)
             from pg_catalog.pg_attribute a
             left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
             where a.attrelid = $1 and a.attnum > 0 and not a.attisdropped
             order by a.attnum",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let constraints = pg::query_as::<(String, String)>(
            "select conname::text, pg_get_constraintdef(oid) from pg_catalog.pg_constraint
             where conrelid = $1 and contype in ('p', 'u', 'f', 'c', 'x')
             order by contype, conname",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let indexes = pg::query_scalar::<String>(
            "select pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i
             where i.indrelid = $1
               and not exists (select 1 from pg_catalog.pg_constraint k where k.conindid = i.indexrelid)
             order by i.indexrelid",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let mut lines: Vec<String> = columns
            .into_iter()
            .map(|(name, type_name, not_null, default)| {
                let mut line = format!("  {} {type_name}", self.quote_ident(&name));
                if not_null {
                    line.push_str(" NOT NULL");
                }
                if let Some(default) = default {
                    line.push_str(&format!(" DEFAULT {default}"));
                }
                line
            })
            .collect();
        lines.extend(constraints.into_iter().map(|(name, definition)| {
            format!("  CONSTRAINT {} {definition}", self.quote_ident(&name))
        }));
        let mut sql = format!(
            "CREATE TABLE {}.{} (\n{}\n);",
            self.quote_ident(schema),
            self.quote_ident(relation),
            lines.join(",\n")
        );
        for index in indexes {
            sql.push_str(&format!("\n{index};"));
        }
        Ok(sql)
    }
}

/// A table a result column came from, as the catalog describes it.
#[derive(Debug)]
struct Relation {
    table: TableName,
    /// Column names by attribute number.
    columns: HashMap<i16, String>,
    /// The attribute numbers of the primary key.
    primary: Vec<i16>,
    /// The attribute numbers of each unique index on columns alone.
    unique: Vec<Vec<i16>>,
}

impl PostgresAdapter {
    /// Bind each result column to its table column, keeping the tables whose whole key is selected.
    async fn source(
        &self,
        prepared: &[PgColumn],
        plain: bool,
        sides: sqmeow_db::sql::Sides,
    ) -> Option<Source> {
        let sources: Vec<Option<(Oid, i16)>> = prepared
            .iter()
            .map(|column| column.table_oid().zip(column.column_id()))
            .collect();
        let mut wanted: Vec<Oid> = sources.iter().flatten().map(|(oid, _)| *oid).collect();
        wanted.sort_unstable();
        wanted.dedup();
        if wanted.is_empty() {
            return None;
        }

        let missing: Vec<Oid> = {
            let known = self.relations.lock().ok()?;
            wanted
                .iter()
                .filter(|oid| !known.contains_key(oid))
                .copied()
                .collect()
        };
        if !missing.is_empty() {
            let found = self.read_relations(&missing).await;
            self.relations.lock().ok()?.extend(found);
        }

        let known = self.relations.lock().ok()?;
        let mut binder = TableBinder::default().every_column(plain).sides(sides);
        for (index, source) in sources.iter().enumerate() {
            if let Some((oid, attribute)) = source
                && let Some(relation) = known.get(oid)
                && let Some(column) = relation.columns.get(attribute)
            {
                binder.bind(index, relation.table.clone(), column.clone());
            }
        }
        binder.build(|table| {
            known
                .values()
                .find(|relation| relation.table == *table)
                .map_or_else(Vec::new, |relation| {
                    std::iter::once(&relation.primary)
                        .chain(&relation.unique)
                        .map(|attributes| {
                            attributes
                                .iter()
                                .map(|attribute| relation.columns.get(attribute).cloned())
                                .collect::<Option<Vec<_>>>()
                                .unwrap_or_default()
                        })
                        .collect()
                })
        })
    }

    /// Ask the catalog what these tables are called, what their columns are, and which of those
    /// make up the primary key.
    async fn read_relations(&self, wanted: &[Oid]) -> HashMap<Oid, Relation> {
        let rows = pg::query(
            "select c.oid as relation, n.nspname::text as schema, c.relname::text as name,
                    a.attnum as attribute, a.attname::text as column_name,
                    coalesce(a.attnum = any(pk.conkey), false) as primary_key
             from pg_catalog.pg_class c
             join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             join pg_catalog.pg_attribute a
               on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
             left join pg_catalog.pg_constraint pk
               on pk.conrelid = c.oid and pk.contype = 'p'
             where c.oid = any($1::oid[])",
        )
        .bind(wanted.to_vec())
        .fetch_all(&self.pool)
        .await;

        let rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                tracing::debug!(%error, "could not read which tables result columns come from");
                return HashMap::new();
            }
        };

        let mut relations: HashMap<Oid, Relation> = HashMap::new();
        for row in &rows {
            let (Ok(oid), Ok(schema), Ok(name), Ok(attribute), Ok(column), Ok(primary)) = (
                row.try_get::<_, Oid>("relation"),
                row.try_get::<_, String>("schema"),
                row.try_get::<_, String>("name"),
                row.try_get::<_, i16>("attribute"),
                row.try_get::<_, String>("column_name"),
                row.try_get::<_, bool>("primary_key"),
            ) else {
                continue;
            };
            let relation = relations.entry(oid).or_insert_with(|| Relation {
                table: TableName {
                    schema: Some(schema),
                    name,
                },
                columns: HashMap::new(),
                primary: Vec::new(),
                unique: Vec::new(),
            });
            relation.columns.insert(attribute, column);
            if primary {
                relation.primary.push(attribute);
            }
        }

        let unique = pg::query_as::<(Oid, Vec<i16>)>(
            "select indrelid, array(select unnest(indkey))::int2[] from pg_catalog.pg_index
             where indrelid = any($1::oid[]) and indisunique and not indisprimary
               and indpred is null and indexprs is null",
        )
        .bind(wanted.to_vec())
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();
        for (oid, attributes) in unique {
            if let Some(relation) = relations.get_mut(&oid) {
                relation.unique.push(attributes);
            }
        }
        relations
    }
}

/// Make the session read-only, and read the setting back, since some servers accept it silently.
async fn make_read_only(connection: &Session) -> bool {
    let Ok(client) = connection.client().await else {
        return false;
    };
    if client
        .batch_execute("set default_transaction_read_only = on")
        .await
        .is_err()
    {
        return false;
    }
    let setting: Option<Option<String>> =
        pg::query_scalar("select current_setting('default_transaction_read_only')")
            .fetch_one(connection)
            .await
            .ok();
    setting.flatten().as_deref() == Some("on")
}

/// Which key a catalog row says a column is.
fn key_kind(row: &PgRow) -> KeyKind {
    let flag = |name| row.try_get::<_, Option<bool>>(name).ok().flatten() == Some(true);

    if flag("primary_key") {
        KeyKind::Primary
    } else if flag("foreign_key") {
        KeyKind::Foreign
    } else {
        KeyKind::None
    }
}

impl PostgresAdapter {
    async fn rearm(&self) -> Result<()> {
        if self.read_only_session() && !make_read_only(&self.pool).await {
            return Err(Error::driver(
                "could not rearm and verify the read-only PostgreSQL session",
            ));
        }
        Ok(())
    }

    async fn run(
        &self,
        statement: &str,
        origin: &str,
        values: Option<&[Value]>,
        max_rows: usize,
        cancel: &CancellationToken,
    ) -> Result<ResultSet> {
        let _guard = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(Error::Cancelled),
            guard = self.execution.lock() => guard,
        };
        let mut in_flight = self.pool.in_flight();
        self.rearm().await?;
        let outcome = self
            .run_locked(statement, origin, values, max_rows, cancel)
            .await;
        if outcome.is_ok() || self.protocol_drained().await {
            in_flight.complete();
        }
        outcome
    }

    /// Errors may arrive before ReadyForQuery; preserve error reuse only after
    /// an ordered barrier proves there is no outstanding protocol work.
    async fn protocol_drained(&self) -> bool {
        let barrier = async {
            self.pool
                .client()
                .await?
                .simple_query("")
                .await
                .map_err(native::driver)?;
            Ok::<_, Error>(())
        };
        matches!(
            tokio::time::timeout(crate::STOP_TIMEOUT, barrier).await,
            Ok(Ok(()))
        )
    }

    async fn run_locked(
        &self,
        statement: &str,
        origin: &str,
        values: Option<&[Value]>,
        max_rows: usize,
        cancel: &CancellationToken,
    ) -> Result<ResultSet> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        // COPY has a separate streaming protocol, not a tabular SQL result. Reject
        // it before sending so COPY FROM cannot strand the session awaiting input.
        if sqmeow_db::sql::split(statement, Dialect::Postgres)
            .iter()
            .any(|s| sqmeow_db::sql::first_word(&s.sql) == "copy")
        {
            return Err(Error::driver(
                "COPY streaming is not supported; use SELECT or INSERT instead",
            ));
        }
        let started = std::time::Instant::now();
        let operation = self.collect(statement, origin, values, max_rows, cancel);
        tokio::pin!(operation);
        let outcome = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                let cleanup = async {
                    self.stop_query().await?;
                    // Retain serialization until cancellation EOF and ReadyForQuery.
                    let _ = operation.await;
                    self.pool.client().await?.simple_query("").await.map_err(native::driver)?;
                    Ok::<_, Error>(())
                };
                if !matches!(tokio::time::timeout(crate::STOP_TIMEOUT, cleanup).await, Ok(Ok(()))) {
                    self.pool.retire().await;
                }
                Err(Error::Cancelled)
            },
            result = &mut operation => result,
        };
        if stream::may_change_schema(statement) {
            self.forget_tables();
        }
        let mut result = outcome?;
        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    async fn collect(
        &self,
        statement: &str,
        origin: &str,
        values: Option<&[Value]>,
        max_rows: usize,
        cancel: &CancellationToken,
    ) -> Result<ResultSet> {
        let client = self.pool.client().await?;
        let mut params: Vec<Box<dyn ToSql + Sync + Send>> = Vec::new();
        let mut types = Vec::new();
        for value in values.unwrap_or_default() {
            match value {
                Value::Text(v) => {
                    params.push(Box::new(Some(v.clone())));
                    types.push(Type::TEXT);
                }
                Value::Int(v) => {
                    params.push(Box::new(Some(*v)));
                    types.push(Type::INT8);
                }
                Value::Float(v) => {
                    params.push(Box::new(Some(*v)));
                    types.push(Type::FLOAT8);
                }
                Value::Bool(v) => {
                    params.push(Box::new(Some(*v)));
                    types.push(Type::BOOL);
                }
                Value::Null(Kind::Auto | Kind::Text) => {
                    params.push(Box::new(None::<String>));
                    types.push(Type::TEXT);
                }
                Value::Null(Kind::Int) => {
                    params.push(Box::new(None::<i64>));
                    types.push(Type::INT8);
                }
                Value::Null(Kind::Float) => {
                    params.push(Box::new(None::<f64>));
                    types.push(Type::FLOAT8);
                }
                Value::Null(Kind::Bool) => {
                    params.push(Box::new(None::<bool>));
                    types.push(Type::BOOL);
                }
            }
        }
        let statements = sqmeow_db::sql::split(statement, Dialect::Postgres);
        let batch = statements.len() > 1;
        let preparable = matches!(
            sqmeow_db::sql::first_word(statement).as_str(),
            "select"
                | "with"
                | "values"
                | "table"
                | "show"
                | "explain"
                | "insert"
                | "update"
                | "delete"
                | "merge"
        );
        let prepared = if values.is_none() && (batch || !preparable) {
            None
        } else {
            match client.prepare_typed(statement, &types).await {
                Ok(prepared) => Some(prepared),
                // A parse failure inside a manual transaction aborts it. Do not try
                // another protocol or replay execution after a server error.
                Err(error) => return Err(native::driver(error)),
            }
        };
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let (columns, source) = if origin == statement {
            if let Some(prepared) = &prepared {
                self.described_columns(origin, prepared.columns()).await
            } else {
                (Vec::new(), None)
            }
        } else {
            self.columns(origin).await
        };
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let mut result = ResultSet::new(statement, columns);
        result.set_source(source);
        let binary = values.is_some()
            || prepared.as_ref().is_some_and(|p| {
                p.columns()
                    .iter()
                    .all(|c| codec::binary_supported(c.type_()))
            });
        if binary {
            let prepared = prepared
                .as_ref()
                .expect("binary execution requires prepare");
            let params: Vec<&(dyn ToSql + Sync)> = params.iter().map(|p| &**p as _).collect();
            let rows = client
                .query_raw(prepared, params)
                .await
                .map_err(native::driver)?;
            tokio::pin!(rows);
            while let Some(row) = rows.next().await {
                let row = row.map_err(native::driver)?;
                if result.row_count() < max_rows {
                    result.push_row((0..row.len()).map(|i| decode_cell(&row, i)).collect());
                } else {
                    result.mark_truncated();
                }
            }
            if let Some(affected) = rows.rows_affected() {
                result.set_affected(affected);
            }
        } else {
            // Keep the batch a single simple-protocol request (and its implicit
            // transaction). The dialect lexer handles dollar bodies and comments.
            // Describing on the drawer session cannot abort a user's transaction.
            let mut descriptions = Vec::new();
            if batch {
                let meta = self.meta.client().await?;
                for part in &statements {
                    descriptions.push(meta.prepare(&part.sql).await.ok());
                    if cancel.is_cancelled() {
                        return Err(Error::Cancelled);
                    }
                }
            }
            let mut part = 0;
            let rows = client
                .simple_query_raw(statement)
                .await
                .map_err(native::driver)?;
            tokio::pin!(rows);
            while let Some(message) = rows.next().await {
                match message.map_err(native::driver)? {
                    tokio_postgres::SimpleQueryMessage::RowDescription(columns) => {
                        if result.columns().is_empty() {
                            if let Some(description) =
                                descriptions.get(part).and_then(Option::as_ref)
                            {
                                result.adopt_columns(result_columns(description.columns()));
                            } else {
                                result.adopt_columns(
                                    columns
                                        .iter()
                                        .map(|c| Column::new(c.name(), "TEXT"))
                                        .collect(),
                                );
                            }
                        }
                    }
                    tokio_postgres::SimpleQueryMessage::Row(row) => {
                        if result.row_count() < max_rows {
                            let description = prepared
                                .as_ref()
                                .or_else(|| descriptions.get(part).and_then(Option::as_ref));
                            result.push_row(
                                (0..row.len())
                                    .map(|i| {
                                        codec::text(
                                            description
                                                .and_then(|p| p.columns().get(i))
                                                .map(|c| c.type_()),
                                            row.get(i),
                                        )
                                    })
                                    .collect(),
                            );
                        } else {
                            result.mark_truncated();
                        }
                    }
                    tokio_postgres::SimpleQueryMessage::CommandComplete(affected) => {
                        result.set_affected(affected);
                        part += 1;
                    }
                    _ => {}
                }
            }
        }
        Ok(result)
    }
}

impl Adapter for PostgresAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Postgres
    }

    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        let _guard = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(Error::Cancelled),
            guard = self.execution.lock() => guard,
        };
        let mut in_flight = self.pool.in_flight();
        self.rearm().await?;
        let client = self.pool.client().await?;
        client
            .batch_execute("BEGIN")
            .await
            .map_err(native::driver)?;
        let mut returned = Vec::new();
        for statement in statements {
            let outcome = self
                .run_locked(statement, statement, None, usize::MAX, &cancel)
                .await;
            let outcome = outcome.and_then(|result| {
                stream::check_affected(statement, result.affected().unwrap_or(0))?;
                Ok(result)
            });
            match outcome {
                Ok(result) => {
                    if result.row_count() > 0 {
                        returned.push(result);
                    }
                }
                Err(error) => {
                    // Do not unlock until rollback is acknowledged, including on cancellation.
                    if matches!(error, Error::Cancelled) && self.pool.client().await.is_err() {
                        return Err(error);
                    }
                    match tokio::time::timeout(
                        crate::STOP_TIMEOUT,
                        client.batch_execute("ROLLBACK"),
                    )
                    .await
                    {
                        Ok(Ok(())) => {
                            in_flight.complete();
                        }
                        outcome => {
                            self.pool.retire().await;
                            if matches!(error, Error::Cancelled) {
                                return Err(error);
                            }
                            return Err(match outcome {
                                Ok(Err(error)) => native::driver(error),
                                _ => Error::driver(
                                    "PostgreSQL rollback timed out; connection retired",
                                ),
                            });
                        }
                    }
                    return Err(if matches!(error, Error::Cancelled) {
                        error
                    } else {
                        stream::rolled_back(format!("{error}\nin: {statement}"))
                    });
                }
            }
        }
        if cancel.is_cancelled() {
            if !matches!(
                tokio::time::timeout(crate::STOP_TIMEOUT, client.batch_execute("ROLLBACK")).await,
                Ok(Ok(()))
            ) {
                self.pool.retire().await;
            } else {
                in_flight.complete();
            }
            return Err(Error::Cancelled);
        }
        // Once commit starts, report its actual outcome; never interrupt or replay it.
        if let Err(error) = client.batch_execute("COMMIT").await {
            if error.as_db_error().is_some() && self.protocol_drained().await {
                in_flight.complete();
            }
            return Err(native::commit_error(error));
        }
        in_flight.complete();
        Ok(returned)
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, statement, None, max_rows, &cancel)
            .await
    }

    async fn execute_bound(
        &self,
        statement: &str,
        values: &[sqmeow_db::sql::parameters::Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, statement, Some(values), max_rows, &cancel)
            .await
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, origin, None, max_rows, &cancel).await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        // The catalogue schemas are hidden.
        let rows = pg::query(
            "select nspname as name, nspname = current_schema() as is_default
             from pg_namespace
             where nspname not like 'pg\\_%' and nspname <> 'information_schema'
             order by nspname",
        )
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(SchemaNode {
                    name: row.try_get::<_, String>("name").ok()?,
                    is_default: row
                        .try_get::<_, Option<bool>>("is_default")
                        .ok()?
                        .unwrap_or(false),
                })
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let rows = pg::query(
            "select c.relname as name, c.relkind as kind
             from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = $1 and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
             order by c.relname",
        )
        .bind(schema)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<_, String>("name").ok()?;
                // relkind is a "char", which decodes as one byte.
                let kind = match row.try_get::<_, i8>("kind").ok()? as u8 {
                    // An ordinary table and a partitioned one are both tables to the user.
                    b'r' | b'p' => RelationKind::Table,
                    b'v' => RelationKind::View,
                    b'm' => RelationKind::MaterializedView,
                    b'S' => RelationKind::Sequence,
                    _ => RelationKind::Other,
                };
                Some(RelationNode { name, kind })
            })
            .collect())
    }

    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        // `prokind` is a "char", and reading it as text here rather than as a byte keeps the
        // decoding in SQL where the catalog's own spelling of it is obvious.
        let rows = pg::query(
            "select p.proname as name,
                    case p.prokind when 'p' then 'procedure' else 'function' end as kind
             from pg_catalog.pg_proc p
             join pg_catalog.pg_namespace n on n.oid = p.pronamespace
             where n.nspname = $1 and p.prokind in ('f', 'p')
             group by p.proname, p.prokind
             order by p.proname",
        )
        .bind(schema)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<_, String>("name").ok()?;
                let kind = row.try_get::<_, String>("kind").ok()?;
                Some(crate::routine_node(name, &kind))
            })
            .collect())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        // `format_type` renders the type the way the schema declares it.
        let rows = pg::query(
            "select a.attname as name,
                    format_type(a.atttypid, a.atttypmod) as type_name,
                    not a.attnotnull as nullable,
                    coalesce(i.indisprimary, false) as primary_key,
                    f.table_name as references_table,
                    f.column_name as references_column,
                    pg_get_expr(d.adbin, d.adrelid) as default_value
             from pg_attribute a
             join pg_class c on c.oid = a.attrelid
             join pg_namespace n on n.oid = c.relnamespace
             left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
             left join pg_index i
               on i.indrelid = c.oid and i.indisprimary and a.attnum = any(i.indkey)
             -- A foreign key can span columns, so the referenced column is the one sitting at the
             -- same position in `confkey` as this column sits in `conkey`. Laterally, because that
             -- position is not known until the row is in hand. The first match wins: a column
             -- constrained twice is still one line in a tree.
             left join lateral (
                 select fn.nspname || '.' || fc.relname as table_name, fa.attname as column_name
                 from pg_constraint k
                 cross join unnest(k.conkey, k.confkey) as pair(local, remote)
                 join pg_class fc on fc.oid = k.confrelid
                 join pg_namespace fn on fn.oid = fc.relnamespace
                 join pg_attribute fa on fa.attrelid = k.confrelid and fa.attnum = pair.remote
                 where k.conrelid = c.oid and k.contype = 'f' and pair.local = a.attnum
                 limit 1
             ) f on true
             where n.nspname = $1 and c.relname = $2 and a.attnum > 0 and not a.attisdropped
             order by a.attnum",
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
                    name: row.try_get::<_, String>("name").ok()?,
                    type_name: row.try_get::<_, String>("type_name").ok()?,
                    nullable: row.try_get::<_, bool>("nullable").unwrap_or(true),
                    primary_key: row.try_get::<_, bool>("primary_key").unwrap_or(false),
                    foreign_key: native::foreign_key(row),
                    default: row
                        .try_get::<_, Option<String>>("default_value")
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
        let rows = pg::query_as::<(String, Vec<String>, bool, bool)>(
            "select i.relname::text,
                    array(select pg_get_indexdef(ix.indexrelid, k, true)
                          from generate_series(1, ix.indnkeyatts::int) k order by k)::text[],
                    ix.indisunique, ix.indisprimary
             from pg_catalog.pg_index ix
             join pg_catalog.pg_class i on i.oid = ix.indexrelid
             join pg_catalog.pg_class t on t.oid = ix.indrelid
             join pg_catalog.pg_namespace n on n.oid = t.relnamespace
             where n.nspname = $1 and t.relname = $2
             order by i.relname",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .into_iter()
            .map(
                |(name, columns, unique, primary)| sqmeow_db::node::IndexNode {
                    name,
                    columns,
                    unique,
                    primary,
                },
            )
            .collect())
    }

    async fn relationships(
        &self,
        schema: &str,
        relation: &str,
    ) -> Result<Vec<sqmeow_db::node::RelationshipNode>> {
        let rows = pg::query_as::<(String, String, String, Vec<String>, String, String, Vec<String>)>(
            "select k.conname::text, sn.nspname::text, s.relname::text,
                    array(select a.attname::text from unnest(k.conkey) with ordinality as u(n, i)
                          join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = u.n order by u.i),
                    tn.nspname::text, t.relname::text,
                    array(select a.attname::text from unnest(k.confkey) with ordinality as u(n, i)
                          join pg_catalog.pg_attribute a on a.attrelid = k.confrelid and a.attnum = u.n order by u.i)
             from pg_catalog.pg_constraint k
             join pg_catalog.pg_class s on s.oid = k.conrelid
             join pg_catalog.pg_namespace sn on sn.oid = s.relnamespace
             join pg_catalog.pg_class t on t.oid = k.confrelid
             join pg_catalog.pg_namespace tn on tn.oid = t.relnamespace
             where k.contype = 'f' and ((sn.nspname = $1 and s.relname = $2)
                                    or (tn.nspname = $1 and t.relname = $2))
             order by sn.nspname, s.relname, k.conname, k.oid",
        ).bind(schema).bind(relation).fetch_all(&self.meta).await.map_err(Error::driver)?;
        Ok(rows
            .into_iter()
            .map(
                |(
                    name,
                    source_schema,
                    source_relation,
                    columns,
                    target_schema,
                    target_relation,
                    referenced,
                )| {
                    sqmeow_db::node::RelationshipNode {
                        name,
                        source_schema,
                        source_relation,
                        columns,
                        target_schema,
                        target_relation,
                        referenced,
                    }
                },
            )
            .collect())
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<sqmeow_db::node::Details> {
        let Some((oid, kind)) = pg::query_as::<(Oid, i8)>(
            "select c.oid, c.relkind from pg_catalog.pg_class c
             join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where n.nspname = $1 and c.relname = $2",
        )
        .bind(schema)
        .bind(relation)
        .fetch_optional(&self.meta)
        .await
        .map_err(Error::driver)?
        else {
            return Ok(sqmeow_db::node::Details::default());
        };

        let comment = pg::query_scalar::<Option<String>>("select obj_description($1, 'pg_class')")
            .bind(oid)
            .fetch_one(&self.meta)
            .await
            .map_err(Error::driver)?;
        let column_comments = pg::query_as::<(String, String)>(
            "select a.attname::text, col_description(a.attrelid, a.attnum)
             from pg_catalog.pg_attribute a
             where a.attrelid = $1 and a.attnum > 0 and not a.attisdropped
               and col_description(a.attrelid, a.attnum) is not null
             order by a.attnum",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let foreign_keys = pg::query_as::<(String, Vec<String>, String, Vec<String>)>(
            "select k.conname::text,
                    array(select a.attname::text
                          from unnest(k.conkey) with ordinality as u(n, i)
                          join pg_catalog.pg_attribute a on a.attrelid = k.conrelid and a.attnum = u.n
                          order by u.i),
                    k.confrelid::regclass::text,
                    array(select a.attname::text
                          from unnest(k.confkey) with ordinality as u(n, i)
                          join pg_catalog.pg_attribute a on a.attrelid = k.confrelid and a.attnum = u.n
                          order by u.i)
             from pg_catalog.pg_constraint k
             where k.conrelid = $1 and k.contype = 'f'
             order by k.conname",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?
        .into_iter()
        .map(|(name, columns, target, referenced)| sqmeow_db::node::ForeignKeyNode {
            name,
            columns,
            target,
            referenced,
        })
        .collect();
        let checks = pg::query_as::<(String, String)>(
            "select conname::text, pg_get_constraintdef(oid) from pg_catalog.pg_constraint
             where conrelid = $1 and contype = 'c' order by conname",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        let triggers = pg::query_as::<(String, String)>(
            "select tgname::text, pg_get_triggerdef(oid, true) from pg_catalog.pg_trigger
             where tgrelid = $1 and not tgisinternal order by tgname",
        )
        .bind(oid)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let definition = match kind as u8 {
            b'v' | b'm' => {
                let body = pg::query_scalar::<String>("select pg_get_viewdef($1, true)")
                    .bind(oid)
                    .fetch_one(&self.meta)
                    .await
                    .map_err(Error::driver)?;
                let what = if kind as u8 == b'm' {
                    "MATERIALIZED VIEW"
                } else {
                    "VIEW"
                };
                format!(
                    "CREATE {what} {}.{} AS\n{}",
                    self.quote_ident(schema),
                    self.quote_ident(relation),
                    body.trim_end()
                )
            }
            _ => self.table_definition(oid, schema, relation).await?,
        };

        Ok(sqmeow_db::node::Details {
            properties: comment
                .map(|comment| ("comment".to_owned(), comment))
                .into_iter()
                .collect(),
            column_comments,
            foreign_keys,
            checks,
            triggers,
            definition: Some(definition),
        })
    }

    async fn roles(&self) -> Result<Vec<sqmeow_db::node::RoleNode>> {
        let rows = pg::query_as::<(String, bool, bool, bool, bool)>(
            "select rolname::text, rolsuper, rolcanlogin, rolcreatedb, rolcreaterole
             from pg_catalog.pg_roles where rolname !~ '^pg_' order by rolname",
        )
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        Ok(rows
            .into_iter()
            .map(
                |(name, superuser, login, create_db, create_role)| sqmeow_db::node::RoleNode {
                    name,
                    attributes: [
                        (superuser, "superuser"),
                        (login, "login"),
                        (create_db, "create db"),
                        (create_role, "create role"),
                    ]
                    .into_iter()
                    .filter(|(held, _)| *held)
                    .map(|(_, attribute)| attribute.to_owned())
                    .collect(),
                },
            )
            .collect())
    }

    async fn close(&self) {
        let _guard = self.execution.lock().await;
        self.meta.close().await;
        self.pool.close().await;
    }
}
