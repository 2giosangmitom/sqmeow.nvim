//! The MySQL and MariaDB adapter.
//!
//! MySQL distinguishes signed from unsigned in the type name, and an unsigned `BIGINT` reaches
//! past what an `i64` holds. Those decode to an exact decimal rather than being silently wrapped
//! into a negative number.

use std::str::FromStr;
use std::time::Instant;

use sqlx::mysql::{MySqlConnectOptions, MySqlPool, MySqlPoolOptions, MySqlRow};
use sqlx::{
    AssertSqlSafe, Column as _, Decode, Executor, MySql, Row, SqlSafeStr, Statement as _, Type,
    TypeInfo, ValueRef, types,
};
use sqmeow_db::{Adapter, Cell, Column, Dialect, Error, Result, ResultSet};
use tokio_util::sync::CancellationToken;

use crate::stream::drain;

/// A pool against one MySQL or MariaDB database.
#[derive(Debug)]
pub struct MySqlAdapter {
    pool: MySqlPool,
}

impl MySqlAdapter {
    /// Open a connection.
    ///
    /// One pooled connection, so a transaction, a `SET` or a temporary table is still there for
    /// the next statement the user runs.
    pub async fn connect(url: &str) -> Result<Self> {
        let options = MySqlConnectOptions::from_str(url).map_err(Error::driver)?;
        let pool = MySqlPoolOptions::new()
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

    async fn close(&self) {
        self.pool.close().await;
    }
}

fn decode_row(row: &MySqlRow, width: usize) -> Vec<Cell> {
    let width = width.max(row.len());
    (0..width).map(|index| decode_cell(row, index)).collect()
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
        "DATETIME" | "TIMESTAMP" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::NaiveDateTime| Cell::Timestamp(value.to_string()),
        ),
        "YEAR" => scalar(row, index, &type_name, |value: u16| Cell::Int(value.into())),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "BINARY" | "VARBINARY" | "BIT"
        | "GEOMETRY" => scalar(row, index, &type_name, |value: Vec<u8>| Cell::bytes(&value)),
        _ => fallback(row, index, &type_name),
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
        _ => fallback(row, index, type_name),
    }
}

fn scalar<T>(row: &MySqlRow, index: usize, type_name: &str, wrap: impl Fn(T) -> Cell) -> Cell
where
    T: for<'r> Decode<'r, MySql> + Type<MySql>,
{
    row.try_get::<T, _>(index)
        .map_or_else(|_| fallback(row, index, type_name), wrap)
}

/// Last resort for a type nothing above claims.
fn fallback(row: &MySqlRow, index: usize, type_name: &str) -> Cell {
    if let Ok(text) = row.try_get::<String, _>(index) {
        return Cell::Text(text);
    }
    if let Ok(bytes) = row.try_get::<Vec<u8>, _>(index) {
        return Cell::bytes(&bytes);
    }
    Cell::Unsupported {
        type_name: type_name.to_owned(),
        raw: String::new(),
    }
}
