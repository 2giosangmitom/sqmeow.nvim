//! The PostgreSQL adapter.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};

use sqlx::postgres::types::Oid;
use sqlx::postgres::{
    PgColumn, PgConnectOptions, PgConnection, PgHasArrayType, PgPool, PgPoolOptions, PgRow,
};
use sqlx::{
    Connection, Decode, Pool, Postgres, Row, Statement as _, Type, TypeInfo, ValueRef, types,
};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyKind, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode, Source, TableBinder, TableName,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{self, SqlxAdapter, foreign_key, prepare, result_columns};

/// A pool against one PostgreSQL database.
#[derive(Debug)]
pub struct PostgresAdapter {
    pool: PgPool,
    /// Which of a table's columns are keys, by table OID and attribute number.
    keys: Mutex<HashMap<(Oid, i16), KeyKind>>,
    /// What a table is called, its columns by attribute number, and its primary key, by OID.
    relations: Mutex<HashMap<Oid, Relation>>,
    /// Whether the URL named no database, so the drawer lists the server's databases instead.
    cluster: bool,
    /// How the pool connects, for the second connection that stops a cancelled query.
    options: PgConnectOptions,
    /// The server process behind the pool's one connection, which is what a cancel names.
    backend_pid: Arc<AtomicI32>,
}

impl PostgresAdapter {
    /// Open a connection, to `database` when given and otherwise to the one the URL names.
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        // Preparing a statement is how a result learns its columns, and a cached statement keeps
        // the columns its table had when it was first prepared.
        let mut options = PgConnectOptions::from_str(url)
            .map_err(Error::driver)?
            .statement_cache_capacity(0);
        let cluster = database.is_none() && options.get_database().is_none();
        if let Some(database) = database {
            options = options.database(database);
        } else if cluster {
            options = options.database("postgres");
        }
        let backend_pid = Arc::new(AtomicI32::new(0));
        let pool = crate::connect_retrying(|| {
            let backend_pid = backend_pid.clone();
            PgPoolOptions::new()
                .max_connections(1)
                // sqlx retries a refused connection until this expires.
                .acquire_timeout(crate::CONNECT_TIMEOUT)
                // Read on every connect, since the pool opens a new session after losing one.
                .after_connect(move |connection, _| {
                    let backend_pid = backend_pid.clone();
                    Box::pin(async move {
                        let pid: i32 = sqlx::query_scalar("select pg_backend_pid()")
                            .fetch_one(&mut *connection)
                            .await?;
                        backend_pid.store(pid, Ordering::Relaxed);
                        Ok(())
                    })
                })
                .connect_with(options.clone())
        })
        .await
        .map_err(Error::driver)?;

        Ok(Self {
            pool,
            keys: Mutex::default(),
            relations: Mutex::default(),
            cluster,
            options,
            backend_pid,
        })
    }

    /// The databases a connection to the whole cluster can open, or `None` for one database.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        if !self.cluster {
            return None;
        }
        Some(
            sqlx::query_scalar(
                "select datname from pg_database
                 where datallowconn and not datistemplate
                 order by datname",
            )
            .fetch_all(&self.pool)
            .await
            .map_err(Error::driver),
        )
    }

    /// Stop the query the session is running, from a connection of its own.
    async fn stop_query(&self) {
        let pid = self.backend_pid.load(Ordering::Relaxed);
        let stop = async {
            let mut connection = PgConnection::connect_with(&self.options).await?;
            sqlx::query("select pg_cancel_backend($1)")
                .bind(pid)
                .execute(&mut connection)
                .await?;
            connection.close().await
        };
        match tokio::time::timeout(crate::STOP_TIMEOUT, stop).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::debug!(%error, "could not stop a cancelled query"),
            Err(_) => tracing::debug!("stopping a cancelled query took too long"),
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
        let Some(prepared) = prepare(&self.pool, statement).await else {
            return (Vec::new(), None);
        };
        let mut columns = result_columns(prepared.columns());
        self.mark_keys(prepared.columns(), &mut columns).await;
        let source = self.source(prepared.columns()).await;
        (columns, source)
    }

    /// Mark the result columns that are keys in the table they came from.
    async fn mark_keys(&self, prepared: &[PgColumn], columns: &mut [Column]) {
        let sources: Vec<Option<(Oid, i16)>> = prepared
            .iter()
            .map(|column| column.relation_id().zip(column.relation_attribute_no()))
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
            // Sorted by the OID's own integer, because `Oid` is a newtype that does not order.
            missing.sort_unstable_by_key(|(relation, attribute)| (relation.0, *attribute));
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
        let rows = sqlx::query(
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
                let relation = row.try_get::<Oid, _>("relation").ok()?;
                let attribute = row.try_get::<i16, _>("attribute").ok()?;
                Some(((relation, attribute), key_kind(row)))
            })
            .collect()
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
    async fn source(&self, prepared: &[PgColumn]) -> Option<Source> {
        let sources: Vec<Option<(Oid, i16)>> = prepared
            .iter()
            .map(|column| column.relation_id().zip(column.relation_attribute_no()))
            .collect();
        let mut wanted: Vec<Oid> = sources.iter().flatten().map(|(oid, _)| *oid).collect();
        wanted.sort_unstable_by_key(|oid| oid.0);
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
        let mut binder = TableBinder::default();
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
        let rows = sqlx::query(
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
                row.try_get::<Oid, _>("relation"),
                row.try_get::<String, _>("schema"),
                row.try_get::<String, _>("name"),
                row.try_get::<i16, _>("attribute"),
                row.try_get::<String, _>("column_name"),
                row.try_get::<bool, _>("primary_key"),
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

        let unique = sqlx::query_as::<_, (Oid, Vec<i16>)>(
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

impl SqlxAdapter for PostgresAdapter {
    type Db = Postgres;

    fn pool(&self) -> &Pool<Postgres> {
        &self.pool
    }

    async fn describe(&self, statement: &str) -> (Vec<Column>, Option<Source>) {
        self.columns(statement).await
    }

    fn decode(row: &PgRow, index: usize) -> Cell {
        decode_cell(row, index)
    }

    fn affected(outcome: &<Postgres as sqlx::Database>::QueryResult) -> u64 {
        outcome.rows_affected()
    }

    async fn stop_running(&self) {
        self.stop_query().await;
    }

    fn forget(&self) {
        self.forget_tables();
    }
}

/// Which key a catalog row says a column is.
fn key_kind(row: &PgRow) -> KeyKind {
    let flag = |name| row.try_get::<Option<bool>, _>(name).ok().flatten() == Some(true);

    if flag("primary_key") {
        KeyKind::Primary
    } else if flag("foreign_key") {
        KeyKind::Foreign
    } else {
        KeyKind::None
    }
}

impl Adapter for PostgresAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Postgres
    }

    async fn apply(&self, statements: &[String]) -> Result<()> {
        stream::transact(&self.pool, statements, |outcome| outcome.rows_affected()).await
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        stream::run(self, statement, statement, max_rows, &cancel).await
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        stream::run(self, statement, origin, max_rows, &cancel).await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        // The catalogue schemas are hidden.
        let rows = sqlx::query(
            "select nspname as name, nspname = current_schema() as is_default
             from pg_namespace
             where nspname not like 'pg\\_%' and nspname <> 'information_schema'
             order by nspname",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(SchemaNode {
                    name: row.try_get::<String, _>("name").ok()?,
                    is_default: row
                        .try_get::<Option<bool>, _>("is_default")
                        .ok()?
                        .unwrap_or(false),
                })
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let rows = sqlx::query(
            "select c.relname as name, c.relkind as kind
             from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = $1 and c.relkind in ('r', 'p', 'v', 'm', 'f')
             order by c.relname",
        )
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<String, _>("name").ok()?;
                // relkind is a "char", which decodes as one byte.
                let kind = match row.try_get::<i8, _>("kind").ok()? as u8 {
                    // An ordinary table and a partitioned one are both tables to the user.
                    b'r' | b'p' => RelationKind::Table,
                    b'v' => RelationKind::View,
                    b'm' => RelationKind::MaterializedView,
                    _ => RelationKind::Other,
                };
                Some(RelationNode { name, kind })
            })
            .collect())
    }

    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        // `prokind` is a "char", and reading it as text here rather than as a byte keeps the
        // decoding in SQL where the catalog's own spelling of it is obvious.
        let rows = sqlx::query(
            "select p.proname as name,
                    case p.prokind when 'p' then 'procedure' else 'function' end as kind
             from pg_catalog.pg_proc p
             join pg_catalog.pg_namespace n on n.oid = p.pronamespace
             where n.nspname = $1 and p.prokind in ('f', 'p')
             group by p.proname, p.prokind
             order by p.proname",
        )
        .bind(schema)
        .fetch_all(&self.pool)
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
        // `format_type` renders the type the way the schema declares it.
        let rows = sqlx::query(
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
                 select fc.relname as table_name, fa.attname as column_name
                 from pg_constraint k
                 cross join unnest(k.conkey, k.confkey) as pair(local, remote)
                 join pg_class fc on fc.oid = k.confrelid
                 join pg_attribute fa on fa.attrelid = k.confrelid and fa.attnum = pair.remote
                 where k.conrelid = c.oid and k.contype = 'f' and pair.local = a.attnum
                 limit 1
             ) f on true
             where n.nspname = $1 and c.relname = $2 and a.attnum > 0 and not a.attisdropped
             order by a.attnum",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.pool)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(ColumnNode {
                    name: row.try_get::<String, _>("name").ok()?,
                    type_name: row.try_get::<String, _>("type_name").ok()?,
                    nullable: row.try_get::<bool, _>("nullable").unwrap_or(true),
                    primary_key: row.try_get::<bool, _>("primary_key").unwrap_or(false),
                    foreign_key: foreign_key(row),
                    default: row
                        .try_get::<Option<String>, _>("default_value")
                        .ok()
                        .flatten(),
                })
            })
            .collect())
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<sqmeow_db::IndexNode>> {
        let rows = sqlx::query_as::<_, (String, Vec<String>, bool, bool)>(
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
        .fetch_all(&self.pool)
        .await
        .map_err(Error::driver)?;

        Ok(rows
            .into_iter()
            .map(|(name, columns, unique, primary)| sqmeow_db::IndexNode {
                name,
                columns,
                unique,
                primary,
            })
            .collect())
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}

fn decode_cell(row: &PgRow, index: usize) -> Cell {
    let Ok(raw) = row.try_get_raw(index) else {
        return Cell::Null;
    };
    if raw.is_null() {
        return Cell::Null;
    }

    let type_name = raw.type_info().name().to_ascii_uppercase();

    if let Some(element) = type_name.strip_suffix("[]") {
        return decode_array(row, index, element);
    }

    match type_name.as_str() {
        "BOOL" => scalar(row, index, &type_name, Cell::Bool),
        "INT2" => scalar(row, index, &type_name, |value: i16| Cell::Int(value.into())),
        "INT4" => scalar(row, index, &type_name, |value: i32| Cell::Int(value.into())),
        "INT8" => scalar(row, index, &type_name, Cell::Int),
        "OID" => scalar(row, index, &type_name, |value: Oid| {
            Cell::Int(value.0.into())
        }),
        "FLOAT4" => scalar(row, index, &type_name, |value: f32| {
            Cell::Float(value.into())
        }),
        "FLOAT8" => scalar(row, index, &type_name, Cell::Float),
        "NUMERIC" => scalar(row, index, &type_name, |value: types::BigDecimal| {
            Cell::Decimal(value.to_string())
        }),
        "TEXT" | "VARCHAR" | "BPCHAR" | "CHAR" | "NAME" | "CITEXT" | "UNKNOWN" => {
            scalar(row, index, &type_name, Cell::Text)
        }
        "UUID" => scalar(row, index, &type_name, |value: types::Uuid| {
            Cell::Uuid(value.to_string())
        }),
        "JSON" | "JSONB" => scalar(row, index, &type_name, |value: serde_json::Value| {
            Cell::Json(value.to_string())
        }),
        "TIMESTAMP" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::NaiveDateTime| Cell::Timestamp(value.to_string()),
        ),
        "TIMESTAMPTZ" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::DateTime<types::chrono::Utc>| Cell::Timestamp(value.to_string()),
        ),
        "DATE" => scalar(row, index, &type_name, |value: types::chrono::NaiveDate| {
            Cell::Date(value.to_string())
        }),
        "TIME" => scalar(row, index, &type_name, |value: types::chrono::NaiveTime| {
            Cell::Time(value.to_string())
        }),
        // No binary decoder is needed.
        "INTERVAL" => raw_text(row, index).map_or_else(|| unsupported(&type_name), Cell::Text),
        "BYTEA" => scalar(row, index, &type_name, |value: Vec<u8>| Cell::bytes(&value)),
        _ => fallback(row, index, &type_name),
    }
}

fn decode_array(row: &PgRow, index: usize, element: &str) -> Cell {
    let name = format!("{element}[]");

    match element {
        "BOOL" => array(row, index, &name, Cell::Bool),
        "INT2" => array(row, index, &name, |value: i16| Cell::Int(value.into())),
        "INT4" => array(row, index, &name, |value: i32| Cell::Int(value.into())),
        "INT8" => array(row, index, &name, Cell::Int),
        "FLOAT4" => array(row, index, &name, |value: f32| Cell::Float(value.into())),
        "FLOAT8" => array(row, index, &name, Cell::Float),
        "TEXT" | "VARCHAR" | "BPCHAR" | "NAME" => array(row, index, &name, Cell::Text),
        "UUID" => array(row, index, &name, |value: types::Uuid| {
            Cell::Uuid(value.to_string())
        }),
        _ => fallback(row, index, &name),
    }
}

fn scalar<T>(row: &PgRow, index: usize, type_name: &str, wrap: impl Fn(T) -> Cell) -> Cell
where
    T: for<'r> Decode<'r, Postgres> + Type<Postgres>,
{
    row.try_get::<T, _>(index)
        .map_or_else(|_| fallback(row, index, type_name), wrap)
}

/// The value exactly as the server wrote it.
fn raw_text(row: &PgRow, index: usize) -> Option<String> {
    let raw = row.try_get_raw(index).ok()?;
    raw.as_str().ok().map(str::to_owned)
}

/// A type nothing above decodes, kept as the server's text rather than discarded.
fn fallback(row: &PgRow, index: usize, type_name: &str) -> Cell {
    Cell::Unsupported {
        type_name: type_name.to_owned(),
        raw: raw_text(row, index).unwrap_or_default(),
    }
}

fn array<T>(row: &PgRow, index: usize, type_name: &str, wrap: impl Fn(T) -> Cell) -> Cell
where
    T: for<'r> Decode<'r, Postgres> + Type<Postgres> + PgHasArrayType,
{
    match row.try_get::<Vec<Option<T>>, _>(index) {
        // A null element inside an array is still a null, and showing it as one keeps the array's
        // length honest.
        Ok(items) => Cell::Array(
            items
                .into_iter()
                .map(|item| item.map_or(Cell::Null, &wrap))
                .collect(),
        ),
        Err(_) => fallback(row, index, type_name),
    }
}

fn unsupported(type_name: &str) -> Cell {
    Cell::Unsupported {
        type_name: type_name.to_owned(),
        raw: String::new(),
    }
}
