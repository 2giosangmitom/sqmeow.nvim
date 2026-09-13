//! The PostgreSQL adapter.
//!
//! Postgres speaks a binary protocol, so a value only becomes readable if something knows its
//! type. Decoding therefore switches on the type name the server reported, and a type nothing here
//! recognises becomes an `Unsupported` cell naming it, rather than failing the whole query.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Mutex;

use sqlx::postgres::types::Oid;
use sqlx::postgres::{PgColumn, PgConnectOptions, PgHasArrayType, PgPool, PgPoolOptions, PgRow};
use sqlx::{Decode, Postgres, Row, Statement as _, Type, TypeInfo, ValueRef, types};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyKind, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{self, foreign_key, prepare, result_columns};

/// A pool against one PostgreSQL database.
#[derive(Debug)]
pub struct PostgresAdapter {
    pool: PgPool,
    /// Which of a table's columns are keys, by table OID and attribute number.
    ///
    /// Looked up once per column and then held for the life of the connection. A result's columns
    /// are almost always the same columns as the last result's, so the cache means running a query
    /// twice costs one catalog lookup rather than two. It is never invalidated: a schema changed
    /// under a live connection leaves an icon one query out of date, which is a smaller price than
    /// a catalog round trip before every execution.
    keys: Mutex<HashMap<(Oid, i16), KeyKind>>,
    /// Whether the URL named no database, so the drawer lists the server's databases instead.
    cluster: bool,
}

impl PostgresAdapter {
    /// Open a connection, to `database` when given and otherwise to the one the URL names.
    ///
    /// The pool holds a single connection, because a database client is a session: a transaction,
    /// a `SET`, a temporary table or a prepared statement must still be there for the next
    /// statement the user runs. A larger pool would scatter those across connections.
    ///
    /// A URL naming no database reaches the whole cluster. It connects to `postgres`, which every
    /// server has, rather than to the database named after the user, which most servers do not.
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        let mut options = PgConnectOptions::from_str(url).map_err(Error::driver)?;
        let cluster = database.is_none() && options.get_database().is_none();
        if let Some(database) = database {
            options = options.database(database);
        } else if cluster {
            options = options.database("postgres");
        }
        let pool = crate::connect_retrying(|| {
            PgPoolOptions::new()
                .max_connections(1)
                // sqlx retries a refused connection until this expires. A mistyped host should
                // say so while the user still remembers typing it, not half a minute later.
                .acquire_timeout(crate::CONNECT_TIMEOUT)
                .connect_with(options.clone())
        })
        .await
        .map_err(Error::driver)?;

        Ok(Self {
            pool,
            keys: Mutex::default(),
            cluster,
        })
    }

    /// The databases a connection to the whole cluster can open, or `None` for one database.
    ///
    /// Templates and databases refusing connections are left out: neither can be opened.
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

    /// What a statement's result looks like, with the columns that are keys marked.
    async fn columns(&self, statement: &str) -> Vec<Column> {
        let Some(prepared) = prepare(&self.pool, statement).await else {
            return Vec::new();
        };
        let mut columns = result_columns(prepared.columns());
        self.mark_keys(prepared.columns(), &mut columns).await;
        columns
    }

    /// Mark the result columns that are keys in the table they came from.
    ///
    /// Postgres names a column's source in the row description, as a table OID and an attribute
    /// number, and those are what the keys are looked up by. Not the table's *name*: a name is
    /// resolved through `search_path` and means different tables in different schemas, while the
    /// pair is exact and costs nothing to obtain. A column that is an expression has neither, and
    /// is left unmarked — `count(*)` is nobody's primary key.
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
                // Every pair that was asked about is recorded, including the ones the catalog had
                // nothing to say about. Otherwise a column that is not a key would be looked up
                // again on every execution of the query it appears in.
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
    ///
    /// A failure answers with nothing rather than an error: an icon is worth one query, and it is
    /// not worth failing the result the user actually asked for.
    async fn read_keys(&self, wanted: &[(Oid, i16)]) -> HashMap<(Oid, i16), KeyKind> {
        let relations: Vec<Oid> = wanted.iter().map(|(relation, _)| *relation).collect();
        let attributes: Vec<i16> = wanted.iter().map(|(_, attribute)| *attribute).collect();

        // The primary key wins over a foreign one, which is decided here rather than by the caller
        // so every dialect answers the same question the same way. `conkey` is an array because a
        // constraint can span columns, and a column is a key if it takes part in one at all.
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

    fn quote_ident(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        let columns = self.columns(statement).await;
        stream::execute(
            &self.pool,
            statement,
            columns,
            max_rows,
            &cancel,
            |outcome| outcome.rows_affected(),
            decode_cell,
        )
        .await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        // The catalogue schemas are hidden: they are the same on every server and are not what
        // anyone opened the drawer to look at.
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
        // decoding in SQL where the catalog's own spelling of it is obvious. Aggregates and
        // window functions are left out: neither is something a user calls the way these are.
        //
        // Grouped, because overloads share a name. Three signatures of `format_date` are three
        // rows in the catalog and one line worth showing in a tree.
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
        // `format_type` renders the type the way the schema declares it, so `varchar(10)` and
        // `numeric(30,3)` keep their parameters instead of collapsing to a base type name.
        let rows = sqlx::query(
            "select a.attname as name,
                    format_type(a.atttypid, a.atttypmod) as type_name,
                    not a.attnotnull as nullable,
                    coalesce(i.indisprimary, false) as primary_key,
                    f.table_name as references_table,
                    f.column_name as references_column
             from pg_attribute a
             join pg_class c on c.oid = a.attrelid
             join pg_namespace n on n.oid = c.relnamespace
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
                })
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
        // No binary decoder is needed: the server already sent "1 mon 2 days 03:00:00", which
        // is both more accurate and more familiar than anything reconstructed from its parts.
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
///
/// Statements go through `raw_sql`, which uses the simple query protocol, so every value arrives
/// in text form. That makes the server's own rendering a dependable last resort, and usually a
/// better one than anything reconstructed from a binary layout.
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
