//! The SQLite adapter.
//!
//! SQLite is dynamically typed: a column declared `INTEGER` may hold text, so what a value *is*
//! comes from the value, not from the column. Decoding here asks each value for its storage class
//! rather than trusting the schema.

use std::str::FromStr;
use std::time::Instant;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{
    AssertSqlSafe, Column as _, Executor, Row, SqlSafeStr, SqlitePool, Statement as _, TypeInfo,
    ValueRef,
};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

use crate::stream::drain;

/// A pool against one SQLite database.
#[derive(Debug)]
pub struct SqliteAdapter {
    pool: SqlitePool,
}

impl SqliteAdapter {
    /// Open a database.
    ///
    /// A missing file is an error unless the URL asks for one with `?mode=rwc`. Silently creating
    /// an empty database because a path was mistyped is far more confusing than being told the
    /// file is not there.
    ///
    /// The pool holds a single connection so that every statement of a multi-statement execution
    /// shares one session. Otherwise `BEGIN`, a temporary table, or a pragma would apply to a
    /// connection the next statement might not get.
    pub async fn connect(url: &str) -> Result<Self> {
        let options = SqliteConnectOptions::from_str(url).map_err(Error::driver)?;
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            // sqlx retries a refused connection until this expires. A mistyped host should say so
            // while the user still remembers typing it, not half a minute later.
            .acquire_timeout(crate::CONNECT_TIMEOUT)
            .connect_with(options)
            .await
            .map_err(Error::driver)?;

        Ok(Self { pool })
    }

    /// Ask the database what a statement's result looks like, before running it.
    ///
    /// This is what lets a query returning no rows still show its header, which is the difference
    /// between "no rows" and "something went wrong" at a glance.
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
            // Preparing is a convenience. A statement that will not prepare may still run, and if
            // it cannot, executing it reports the real error.
            Err(error) => {
                tracing::debug!(%error, "could not prepare a statement to read its columns");
                Vec::new()
            }
        }
    }
}

impl Adapter for SqliteAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Sqlite
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

        // The SQL is whatever the user typed into their own editor, against their own
        // database. There is no untrusted input to escape here, and refusing to run it would
        // defeat the point of the plugin.
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

    /// SQLite calls them databases: `main`, `temp`, and anything attached.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let rows = sqlx::query("pragma database_list")
            .fetch_all(&self.pool)
            .await
            .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| row.try_get::<String, _>("name").ok())
            .map(|name| SchemaNode {
                is_default: name == "main",
                name,
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        // The schema cannot be a bind parameter here: it qualifies the table being read, not a
        // value in it. Quoting it is what makes that safe.
        let sql = format!(
            "select name, type from {}.sqlite_master
             where type in ('table', 'view') and name not like 'sqlite_%'
             order by name",
            self.quote_ident(schema)
        );

        let rows = sqlx::query(AssertSqlSafe(sql))
            .fetch_all(&self.pool)
            .await
            .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<String, _>("name").ok()?;
                let kind = match row.try_get::<String, _>("type").ok()?.as_str() {
                    "view" => RelationKind::View,
                    "table" => RelationKind::Table,
                    _ => RelationKind::Other,
                };
                Some(RelationNode { name, kind })
            })
            .collect())
    }

    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        // SQLite has no stored functions or procedures. An empty list rather than an error, so
        // the drawer shows the groups as empty instead of failing the whole schema.
        Ok(Vec::new())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let sql = format!(
            "pragma {}.table_info({})",
            self.quote_ident(schema),
            self.quote_ident(relation)
        );

        let rows = sqlx::query(AssertSqlSafe(sql))
            .fetch_all(&self.pool)
            .await
            .map_err(Error::driver)?;

        Ok(rows
            .iter()
            .filter_map(|row| {
                Some(ColumnNode {
                    name: row.try_get::<String, _>("name").ok()?,
                    // A column with no declared type is legal in SQLite, and its values can be
                    // anything, which is worth showing rather than leaving blank.
                    type_name: match row.try_get::<String, _>("type").ok()? {
                        empty if empty.is_empty() => "any".to_owned(),
                        declared => declared,
                    },
                    nullable: row.try_get::<i64, _>("notnull").unwrap_or(0) == 0,
                    primary_key: row.try_get::<i64, _>("pk").unwrap_or(0) > 0,
                })
            })
            .collect())
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}

fn decode_row(row: &SqliteRow, width: usize) -> Vec<Cell> {
    // A row can be wider than `describe` predicted, so take whichever is larger and let the result
    // set trim or pad. Losing a column silently would be worse than showing an extra one.
    let width = width.max(row.len());
    (0..width).map(|index| decode_cell(row, index)).collect()
}

fn decode_cell(row: &SqliteRow, index: usize) -> Cell {
    let Ok(raw) = row.try_get_raw(index) else {
        return Cell::Null;
    };
    if raw.is_null() {
        return Cell::Null;
    }

    let type_name = raw.type_info().name().to_ascii_uppercase();

    match type_name.as_str() {
        "INTEGER" | "INT" | "BIGINT" => row
            .try_get::<i64, _>(index)
            .map_or_else(|_| fallback(row, index, &type_name), Cell::Int),
        "REAL" | "FLOAT" | "DOUBLE" => row
            .try_get::<f64, _>(index)
            .map_or_else(|_| fallback(row, index, &type_name), Cell::Float),
        "BOOLEAN" | "BOOL" => row
            .try_get::<bool, _>(index)
            .map_or_else(|_| fallback(row, index, &type_name), Cell::Bool),
        "TEXT" | "VARCHAR" | "CHAR" | "CLOB" => row
            .try_get::<String, _>(index)
            .map_or_else(|_| fallback(row, index, &type_name), Cell::Text),
        "BLOB" => row.try_get::<Vec<u8>, _>(index).map_or_else(
            |_| fallback(row, index, &type_name),
            |bytes| Cell::bytes(&bytes),
        ),
        _ => fallback(row, index, &type_name),
    }
}

/// Last resort for a value whose declared type did not decode.
///
/// SQLite will happily store text in an integer column, so a failed decode is a normal event
/// rather than a bug, and the value itself is still worth showing.
fn fallback(row: &SqliteRow, index: usize, type_name: &str) -> Cell {
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
