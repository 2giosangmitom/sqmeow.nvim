//! The MySQL and MariaDB adapter.
//!
//! MySQL distinguishes signed from unsigned in the type name, and an unsigned `BIGINT` reaches
//! past what an `i64` holds. Those decode to an exact decimal rather than being silently wrapped
//! into a negative number.

use std::collections::HashMap;
use std::str::FromStr;

use sqlx::mysql::{MySqlConnectOptions, MySqlPool, MySqlPoolOptions, MySqlRow};
use sqlx::{Decode, MySql, Row, Statement as _, Type, TypeInfo, ValueRef, types};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyKind, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{
    self, TableKeys, foreign_key, origins, prepare, result_columns, text_or_bytes,
};

/// A pool against one MySQL or MariaDB database.
#[derive(Debug)]
pub struct MySqlAdapter {
    pool: MySqlPool,
    /// Which columns of a table are keys, read from `information_schema` a whole table at a time.
    keys: TableKeys,
}

impl MySqlAdapter {
    /// Open a connection.
    ///
    /// One pooled connection, so a transaction, a `SET` or a temporary table is still there for
    /// the next statement the user runs.
    pub async fn connect(url: &str) -> Result<Self> {
        let options = MySqlConnectOptions::from_str(url).map_err(Error::driver)?;
        let pool = crate::connect_retrying(|| {
            MySqlPoolOptions::new()
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
            keys: TableKeys::default(),
        })
    }

    /// What a statement's result looks like, with the columns that are keys marked.
    async fn columns(&self, statement: &str) -> Vec<Column> {
        let Some(prepared) = prepare(&self.pool, statement).await else {
            return Vec::new();
        };
        let mut columns = result_columns(prepared.columns());
        // MySQL reports the table and column a result column really came from in the column
        // definitions it sends with every result, so the source costs nothing to read.
        self.keys
            .mark(&origins(prepared.columns()), &mut columns, |table| {
                self.read_keys(table)
            })
            .await;
        columns
    }

    /// Ask `information_schema` which columns of one table are keys.
    ///
    /// A failure answers with nothing rather than an error: an icon is worth one query, and it is
    /// not worth failing the result the user actually asked for.
    async fn read_keys(&self, origin: String) -> HashMap<String, KeyKind> {
        // MySQL qualifies the table with its schema when it knows one, so a cross-database join is
        // resolved against the right database rather than against a same-named table here.
        let (schema, table) = match origin.rsplit_once('.') {
            Some((schema, table)) => (Some(schema), table),
            None => (None, origin.as_str()),
        };

        let rows = sqlx::query(
            "select c.column_name as column_name,
                    c.column_key = 'PRI' as primary_key,
                    exists (
                        select 1 from information_schema.key_column_usage k
                        where k.table_schema = c.table_schema
                          and k.table_name = c.table_name
                          and k.column_name = c.column_name
                          and k.referenced_table_name is not null
                    ) as foreign_key
             from information_schema.columns c
             -- An unqualified table is one in the connection's own database, which is the server's
             -- to name rather than something this side has to go and ask for.
             where c.table_schema = coalesce(?, database()) and c.table_name = ?",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
        .await;

        let rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                tracing::debug!(%error, %origin, "could not read which result columns are keys");
                return HashMap::new();
            }
        };

        rows.iter()
            .filter_map(|row| {
                let column = row.try_get::<String, _>("column_name").ok()?;
                Some((column, key_kind(row)))
            })
            .collect()
    }
}

/// Which key an `information_schema` row says a column is.
///
/// The primary key wins over a foreign one, matching every other adapter: a column that is both is
/// more usefully described as the one rows are identified by.
fn key_kind(row: &MySqlRow) -> KeyKind {
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

impl Adapter for MySqlAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::MySql
    }

    fn quote_ident(&self, name: &str) -> String {
        format!("`{}`", name.replace('`', "``"))
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

    /// MySQL has no schemas within a database, so its databases fill that level of the tree.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let rows = sqlx::query(
            "select schema_name as name, schema_name = database() as is_default
             from information_schema.schemata
             where schema_name not in
                   ('information_schema', 'performance_schema', 'mysql', 'sys')
             order by schema_name",
        )
        .fetch_all(&self.pool)
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
        let rows = sqlx::query(
            "select table_name as name, table_type as kind
             from information_schema.tables
             where table_schema = ?
             order by table_name",
        )
        .bind(schema)
        .fetch_all(&self.pool)
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
        let rows = sqlx::query(
            "select routine_name as name, lower(routine_type) as kind
             from information_schema.routines
             where routine_schema = ?
             order by routine_name",
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
        // `column_type` keeps the declared width and signedness, which `data_type` drops.
        let rows = sqlx::query(
            "select c.column_name as name,
                    c.column_type as type_name,
                    c.is_nullable as nullable,
                    c.column_key as key_kind,
                    k.referenced_table_name as references_table,
                    k.referenced_column_name as references_column
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
        .fetch_all(&self.pool)
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
                })
            })
            .collect())
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}

fn decode_cell(row: &MySqlRow, index: usize) -> Cell {
    let Ok(raw) = row.try_get_raw(index) else {
        return Cell::Null;
    };
    if raw.is_null() {
        return Cell::Null;
    }

    let type_name = raw.type_info().name().to_ascii_uppercase();

    // Unsigned columns are named "INT UNSIGNED" and friends, so the suffix is the switch.
    if let Some(base) = type_name.strip_suffix(" UNSIGNED") {
        return decode_unsigned(row, index, base, &type_name);
    }

    match type_name.as_str() {
        "BOOLEAN" | "BOOL" => scalar(row, index, &type_name, Cell::Bool),
        "TINYINT" => scalar(row, index, &type_name, |value: i8| Cell::Int(value.into())),
        "SMALLINT" => scalar(row, index, &type_name, |value: i16| Cell::Int(value.into())),
        "INT" | "MEDIUMINT" => scalar(row, index, &type_name, |value: i32| Cell::Int(value.into())),
        "BIGINT" => scalar(row, index, &type_name, Cell::Int),
        "FLOAT" => scalar(row, index, &type_name, |value: f32| {
            Cell::Float(value.into())
        }),
        "DOUBLE" => scalar(row, index, &type_name, Cell::Float),
        "DECIMAL" | "NEWDECIMAL" => scalar(row, index, &type_name, |value: types::BigDecimal| {
            Cell::Decimal(value.to_string())
        }),
        "VARCHAR" | "CHAR" | "TEXT" | "TINYTEXT" | "MEDIUMTEXT" | "LONGTEXT" | "ENUM" | "SET" => {
            scalar(row, index, &type_name, Cell::Text)
        }
        "JSON" => scalar(row, index, &type_name, |value: serde_json::Value| {
            Cell::Json(value.to_string())
        }),
        "DATE" => scalar(row, index, &type_name, |value: types::chrono::NaiveDate| {
            Cell::Date(value.to_string())
        }),
        "TIME" => scalar(row, index, &type_name, |value: types::chrono::NaiveTime| {
            Cell::Time(value.to_string())
        }),
        "DATETIME" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::NaiveDateTime| Cell::Timestamp(value.to_string()),
        ),
        // sqlx refuses to read a TIMESTAMP as a naive date and time, only as a zoned one. It is a
        // zoned one: MySQL stores it as UTC and converts to the session's zone, which sqlx sets to
        // `+00:00` on connect, so it is shown with its zone the way a Postgres `timestamptz` is.
        "TIMESTAMP" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::DateTime<types::chrono::Utc>| Cell::Timestamp(value.to_string()),
        ),
        "YEAR" => scalar(row, index, &type_name, |value: u16| Cell::Int(value.into())),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "BINARY" | "VARBINARY" | "BIT"
        | "GEOMETRY" => scalar(row, index, &type_name, |value: Vec<u8>| Cell::bytes(&value)),
        _ => text_or_bytes(row, index, &type_name),
    }
}

fn decode_unsigned(row: &MySqlRow, index: usize, base: &str, type_name: &str) -> Cell {
    match base {
        "TINYINT" => scalar(row, index, type_name, |value: u8| Cell::Int(value.into())),
        "SMALLINT" => scalar(row, index, type_name, |value: u16| Cell::Int(value.into())),
        "INT" | "MEDIUMINT" => scalar(row, index, type_name, |value: u32| Cell::Int(value.into())),
        // An unsigned BIGINT reaches past i64. Keeping it exact matters more than keeping it an
        // integer, so anything that does not fit becomes a decimal rather than a wrong number.
        "BIGINT" => scalar(row, index, type_name, |value: u64| {
            i64::try_from(value).map_or_else(|_| Cell::Decimal(value.to_string()), Cell::Int)
        }),
        _ => text_or_bytes(row, index, type_name),
    }
}

fn scalar<T>(row: &MySqlRow, index: usize, type_name: &str, wrap: impl Fn(T) -> Cell) -> Cell
where
    T: for<'r> Decode<'r, MySql> + Type<MySql>,
{
    row.try_get::<T, _>(index)
        .map_or_else(|_| text_or_bytes(row, index, type_name), wrap)
}
