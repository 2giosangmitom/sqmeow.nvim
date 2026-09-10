//! The PostgreSQL adapter.
//!
//! Postgres speaks a binary protocol, so a value only becomes readable if something knows its
//! type. Decoding therefore switches on the type name the server reported, and a type nothing here
//! recognises becomes an `Unsupported` cell naming it, rather than failing the whole query.

use std::str::FromStr;
use std::time::Instant;

use sqlx::postgres::types::Oid;
use sqlx::postgres::{PgConnectOptions, PgHasArrayType, PgPool, PgPoolOptions, PgRow};
use sqlx::{
    AssertSqlSafe, Column as _, Decode, Executor, Postgres, Row, SqlSafeStr, Statement as _, Type,
    TypeInfo, ValueRef, types,
};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, RelationKind, RelationNode, Result,
    ResultSet, SchemaNode,
};
use tokio_util::sync::CancellationToken;

use crate::stream::drain;

/// A pool against one PostgreSQL database.
#[derive(Debug)]
pub struct PostgresAdapter {
    pool: PgPool,
}

impl PostgresAdapter {
    /// Open a connection.
    ///
    /// The pool holds a single connection, because a database client is a session: a transaction,
    /// a `SET`, a temporary table or a prepared statement must still be there for the next
    /// statement the user runs. A larger pool would scatter those across connections.
    pub async fn connect(url: &str) -> Result<Self> {
        let options = PgConnectOptions::from_str(url).map_err(Error::driver)?;
        let pool = PgPoolOptions::new()
            .max_connections(1)
            // sqlx retries a refused connection until this expires. A mistyped host should say so
            // while the user still remembers typing it, not half a minute later.
            .acquire_timeout(crate::CONNECT_TIMEOUT)
            .connect_with(options)
            .await
            .map_err(Error::driver)?;

        Ok(Self { pool })
    }

    async fn columns(&self, statement: &str) -> Vec<Column> {
        let sql = AssertSqlSafe(statement.to_owned()).into_sql_str();

        match self.pool.prepare(sql).await {
            Ok(prepared) => prepared
                .columns()
                .iter()
                .map(|column| Column {
                    name: column.name().to_owned(),
                    type_name: column.type_info().name().to_owned(),
                })
                .collect(),
            Err(error) => {
                tracing::debug!(%error, "could not prepare a statement to read its columns");
                Vec::new()
            }
        }
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
        let started = Instant::now();
        let columns = self.columns(statement).await;
        let width = columns.len();
        let mut result = ResultSet::new(statement, columns);

        let stream = sqlx::raw_sql(AssertSqlSafe(statement.to_owned())).fetch_many(&self.pool);

        drain(
            stream,
            &mut result,
            max_rows,
            &cancel,
            |outcome| outcome.rows_affected(),
            |row| decode_row(row, width),
        )
        .await?;

        result.set_elapsed(started.elapsed());
        Ok(result)
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

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        // `format_type` renders the type the way the schema declares it, so `varchar(10)` and
        // `numeric(30,3)` keep their parameters instead of collapsing to a base type name.
        let rows = sqlx::query(
            "select a.attname as name,
                    format_type(a.atttypid, a.atttypmod) as type_name,
                    not a.attnotnull as nullable,
                    coalesce(i.indisprimary, false) as primary_key
             from pg_attribute a
             join pg_class c on c.oid = a.attrelid
             join pg_namespace n on n.oid = c.relnamespace
             left join pg_index i
               on i.indrelid = c.oid and i.indisprimary and a.attnum = any(i.indkey)
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
                })
            })
            .collect())
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}

fn decode_row(row: &PgRow, width: usize) -> Vec<Cell> {
    let width = width.max(row.len());
    (0..width).map(|index| decode_cell(row, index)).collect()
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
