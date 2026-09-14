//! The SQLite adapter.

use std::collections::HashMap;
use std::str::FromStr;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{AssertSqlSafe, Row, SqlitePool, Statement as _, TypeInfo, ValueRef};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, ForeignKey, KeyKind, RelationKind,
    RelationNode, Result, ResultSet, RoutineNode, SchemaNode, Source,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{self, TableKeys, origins, prepare, result_columns, text_or_bytes};

/// A pool against one SQLite database.
#[derive(Debug)]
pub struct SqliteAdapter {
    pool: SqlitePool,
    /// Which columns of a table are keys, read from the pragmas a whole table at a time.
    keys: TableKeys,
}

impl SqliteAdapter {
    /// Open a database.
    pub async fn connect(url: &str) -> Result<Self> {
        // Preparing a statement is how a result learns its columns, and a cached statement keeps
        // the columns its table had when it was first prepared.
        let options = SqliteConnectOptions::from_str(url)
            .map_err(Error::driver)?
            .statement_cache_capacity(0);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            // sqlx retries a refused connection until this expires.
            .acquire_timeout(crate::CONNECT_TIMEOUT)
            .connect_with(options)
            .await
            .map_err(Error::driver)?;

        Ok(Self {
            pool,
            keys: TableKeys::default(),
        })
    }

    /// What a statement's result looks like, with the columns that are keys marked.
    async fn columns(&self, statement: &str) -> (Vec<Column>, Option<Source>) {
        let Some(prepared) = prepare(&self.pool, statement).await else {
            return (Vec::new(), None);
        };
        let mut columns = result_columns(prepared.columns());
        let origins = origins(prepared.columns());
        // SQLite names the table and column a result column came from, for a prepared statement,
        // without being asked and without a query.
        self.keys
            .mark(&origins, &mut columns, |table| self.read_keys(table))
            .await;
        let source = self.keys.source(&origins);
        (columns, source)
    }

    /// Ask the pragmas which columns of one table are keys.
    async fn read_keys(&self, table: String) -> HashMap<String, KeyKind> {
        let mut keys = HashMap::new();

        // Foreign keys first.
        let sql = format!("pragma foreign_key_list({})", self.quote_ident(&table));
        match sqlx::query(AssertSqlSafe(sql)).fetch_all(&self.pool).await {
            Ok(rows) => {
                for row in &rows {
                    if let Ok(column) = row.try_get::<String, _>("from") {
                        keys.insert(column, KeyKind::Foreign);
                    }
                }
            }
            Err(error) => {
                tracing::debug!(%error, %table, "could not read a table's foreign keys");
            }
        }

        let sql = format!("pragma table_info({})", self.quote_ident(&table));
        match sqlx::query(AssertSqlSafe(sql)).fetch_all(&self.pool).await {
            Ok(rows) => {
                for row in &rows {
                    // `pk` is the column's position in the primary key, counted from one, and zero
                    // for a column that is not part of it.
                    if row.try_get::<i64, _>("pk").unwrap_or(0) > 0
                        && let Ok(column) = row.try_get::<String, _>("name")
                    {
                        keys.insert(column, KeyKind::Primary);
                    }
                }
            }
            Err(error) => {
                tracing::debug!(%error, %table, "could not read a table's primary key");
            }
        }

        keys
    }
}

impl Adapter for SqliteAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Sqlite
    }

    fn quote_ident(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
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
        let (columns, source) = self.columns(statement).await;
        let outcome = stream::execute(
            &self.pool,
            statement,
            columns,
            max_rows,
            &cancel,
            |outcome| outcome.rows_affected(),
            decode_cell,
        )
        .await;
        if stream::may_change_schema(statement) {
            self.keys.forget();
        }
        let mut result = outcome?;
        result.set_source(source);
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
        // The schema cannot be a bind parameter here.
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
        // SQLite has no stored functions or procedures.
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

        let sql = format!(
            "pragma {}.foreign_key_list({})",
            self.quote_ident(schema),
            self.quote_ident(relation)
        );
        let references: HashMap<String, ForeignKey> = sqlx::query(AssertSqlSafe(sql))
            .fetch_all(&self.pool)
            .await
            .unwrap_or_default()
            .iter()
            .filter_map(|row| {
                let from = row.try_get::<String, _>("from").ok()?;
                let table = row.try_get::<String, _>("table").ok()?;
                // A reference that names no column points at the other table's primary key.
                let column = row
                    .try_get::<Option<String>, _>("to")
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| "rowid".to_owned());
                Some((from, ForeignKey { table, column }))
            })
            .collect();

        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.try_get::<String, _>("name").ok()?;
                Some(ColumnNode {
                    foreign_key: references.get(&name).cloned(),
                    name,
                    // SQLite allows a column with no declared type.
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
            .map_or_else(|_| text_or_bytes(row, index, &type_name), Cell::Int),
        "REAL" | "FLOAT" | "DOUBLE" => row
            .try_get::<f64, _>(index)
            .map_or_else(|_| text_or_bytes(row, index, &type_name), Cell::Float),
        "BOOLEAN" | "BOOL" => row
            .try_get::<bool, _>(index)
            .map_or_else(|_| text_or_bytes(row, index, &type_name), Cell::Bool),
        "TEXT" | "VARCHAR" | "CHAR" | "CLOB" => row
            .try_get::<String, _>(index)
            .map_or_else(|_| text_or_bytes(row, index, &type_name), Cell::Text),
        "BLOB" => row.try_get::<Vec<u8>, _>(index).map_or_else(
            |_| text_or_bytes(row, index, &type_name),
            |bytes| Cell::bytes(&bytes),
        ),
        _ => text_or_bytes(row, index, &type_name),
    }
}
