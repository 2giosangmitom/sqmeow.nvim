//! The MySQL and MariaDB adapter.

use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use sqlx::mysql::{MySqlConnectOptions, MySqlConnection, MySqlPool, MySqlPoolOptions, MySqlRow};
use sqlx::{
    AssertSqlSafe, Connection, Decode, MySql, Pool, Row, Statement as _, Type, TypeInfo, ValueRef,
    types,
};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyKind, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode, Source, TableName,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{
    self, Keys, SqlxAdapter, TableKeys, foreign_key, origins, prepare, result_columns,
    text_or_bytes,
};

/// A pool against one MySQL or MariaDB database.
#[derive(Debug)]
pub struct MySqlAdapter {
    pool: MySqlPool,
    /// A session of its own for the drawer, which a long query on `pool` does not hold up.
    meta: MySqlPool,
    /// Which columns of a table are keys, read from `information_schema` a whole table at a time.
    keys: TableKeys,
    /// How the pool connects, for the second connection that stops a cancelled query.
    options: MySqlConnectOptions,
    /// The server's id for the pool's one connection, which is what `KILL QUERY` names.
    connection_id: Arc<AtomicU64>,
}

impl MySqlAdapter {
    /// Open a connection.
    pub async fn connect(url: &str, read_only: bool) -> Result<Self> {
        // Preparing a statement is how a result learns its columns, and a cached statement keeps
        // the columns its table had when it was first prepared.
        let options = MySqlConnectOptions::from_str(url)
            .map_err(Error::driver)?
            .statement_cache_capacity(0);
        let connection_id = Arc::new(AtomicU64::new(0));
        let pool = crate::connect_retrying(|| {
            let connection_id = connection_id.clone();
            MySqlPoolOptions::new()
                .max_connections(1)
                // sqlx retries a refused connection until this expires.
                .acquire_timeout(crate::CONNECT_TIMEOUT)
                // Read on every connect, since the pool opens a new session after losing one.
                .after_connect(move |connection, _| {
                    let connection_id = connection_id.clone();
                    Box::pin(async move {
                        let id: u64 = sqlx::query_scalar("select connection_id()")
                            .fetch_one(&mut *connection)
                            .await?;
                        connection_id.store(id, Ordering::Relaxed);
                        if read_only {
                            sqlx::query("set session transaction read only")
                                .execute(&mut *connection)
                                .await?;
                        }
                        Ok(())
                    })
                })
                .connect_with(options.clone())
        })
        .await
        .map_err(Error::driver)?;

        let meta = MySqlPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(crate::CONNECT_TIMEOUT)
            .connect_lazy_with(options.clone());

        Ok(Self {
            pool,
            meta,
            keys: TableKeys::default(),
            options,
            connection_id,
        })
    }

    /// Stop the query the session is running, from a connection of its own.
    async fn stop_query(&self) {
        let id = self.connection_id.load(Ordering::Relaxed);
        let stop = async {
            let mut connection = MySqlConnection::connect_with(&self.options).await?;
            // `KILL` cannot be prepared, and the id is a number this adapter read itself.
            sqlx::raw_sql(AssertSqlSafe(format!("kill query {id}")))
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

    /// What a statement's result looks like, with the columns that are keys marked.
    async fn columns(&self, statement: &str) -> (Vec<Column>, Option<Source>) {
        let Some(prepared) = prepare(&self.meta, statement).await else {
            return (Vec::new(), None);
        };
        let mut columns = result_columns(prepared.columns());
        let origins = origins(prepared.columns());
        // MySQL reports the table and column a result column really came from in the column
        // definitions it sends with every result.
        self.keys
            .mark(&origins, &mut columns, |table| self.read_keys(table))
            .await;
        let source = self.keys.source(
            &origins,
            sqmeow_db::sql::plain(Dialect::MySql, statement),
            sqmeow_db::sql::Sides::read(Dialect::MySql, statement),
        );
        (columns, source)
    }

    /// Ask `information_schema` which columns of one table are keys.
    async fn read_keys(&self, origin: TableName) -> Keys {
        let (schema, table) = (origin.schema.as_deref(), origin.name.as_str());

        let rows = sqlx::query(
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
        .fetch_all(&self.pool)
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
        let rows = sqlx::query(
            "select s.index_name as index_name, s.column_name as column_name
             from information_schema.statistics s
             where s.table_schema = coalesce(?, database()) and s.table_name = ?
               and s.non_unique = 0 and s.index_name <> 'PRIMARY'
             order by s.index_name, s.seq_in_index",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
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

impl SqlxAdapter for MySqlAdapter {
    type Db = MySql;

    fn pool(&self) -> &Pool<MySql> {
        &self.pool
    }

    async fn describe(&self, statement: &str) -> (Vec<Column>, Option<Source>) {
        self.columns(statement).await
    }

    fn decode(row: &MySqlRow, index: usize) -> Cell {
        decode_cell(row, index)
    }

    fn affected(outcome: &<MySql as sqlx::Database>::QueryResult) -> u64 {
        outcome.rows_affected()
    }

    async fn stop_running(&self) {
        self.stop_query().await;
    }

    fn forget(&self) {
        self.keys.forget();
    }
}

/// Which key an `information_schema` row says a column is.
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

    async fn apply(&self, statements: &[String]) -> Result<Vec<ResultSet>> {
        let affected = |outcome: &sqlx::mysql::MySqlQueryResult| outcome.rows_affected();
        stream::transact(&self.pool, statements, affected, decode_cell).await
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

    /// MySQL has no schemas within a database, so its databases fill that level of the tree.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let rows = sqlx::query(
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
        let rows = sqlx::query(
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
        let rows = sqlx::query(
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
        let rows = sqlx::query(
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
                    default: row
                        .try_get::<Option<String>, _>("default_value")
                        .ok()
                        .flatten(),
                })
            })
            .collect())
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<sqmeow_db::IndexNode>> {
        let rows = sqlx::query(
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

        let mut indexes: Vec<sqmeow_db::IndexNode> = Vec::new();
        for row in &rows {
            let name: String = row.try_get("index_name").map_err(Error::driver)?;
            let column = row
                .try_get::<Option<String>, _>("column_name")
                .ok()
                .flatten()
                .unwrap_or_else(|| "(expression)".to_owned());
            match indexes.last_mut() {
                Some(index) if index.name == name => index.columns.push(column),
                _ => indexes.push(sqmeow_db::IndexNode {
                    unique: row.try_get::<i64, _>("non_unique").unwrap_or(1) == 0,
                    primary: name == "PRIMARY",
                    columns: vec![column],
                    name,
                }),
            }
        }
        Ok(indexes)
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<sqmeow_db::Details> {
        let comment = sqlx::query_scalar::<_, String>(
            "select table_comment from information_schema.tables
             where table_schema = ? and table_name = ?",
        )
        .bind(schema)
        .bind(relation)
        .fetch_optional(&self.meta)
        .await
        .map_err(Error::driver)?
        .filter(|comment| !comment.is_empty());
        let column_comments = sqlx::query_as::<_, (String, String)>(
            "select column_name, column_comment from information_schema.columns
             where table_schema = ? and table_name = ? and column_comment <> ''
             order by ordinal_position",
        )
        .bind(schema)
        .bind(relation)
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;

        let parts = sqlx::query_as::<_, (String, String, String, String, String)>(
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
        let mut foreign_keys: Vec<sqmeow_db::ForeignKeyNode> = Vec::new();
        for (name, column, target_schema, target, referenced) in parts {
            if foreign_keys.last().is_none_or(|key| key.name != name) {
                foreign_keys.push(sqmeow_db::ForeignKeyNode {
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

        let checks = sqlx::query_as::<_, (String, String)>(
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
        let triggers = sqlx::query_as::<_, (String, String)>(
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
        let definition = sqlx::query(AssertSqlSafe(sql))
            .fetch_optional(&self.meta)
            .await
            .map_err(Error::driver)?
            .and_then(|row| row.try_get::<String, _>(1).ok());

        Ok(sqmeow_db::Details {
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

    async fn roles(&self) -> Result<Vec<sqmeow_db::RoleNode>> {
        let rows = sqlx::query_as::<_, (String, String, String)>(
            "select user, host, account_locked from mysql.user order by user, host",
        )
        .fetch_all(&self.meta)
        .await
        .map_err(Error::driver)?;
        Ok(rows
            .into_iter()
            .map(|(user, host, locked)| sqmeow_db::RoleNode {
                name: format!("{user}@{host}"),
                attributes: (locked == "Y")
                    .then(|| "locked".to_owned())
                    .into_iter()
                    .collect(),
            })
            .collect())
    }

    async fn close(&self) {
        self.meta.close().await;
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
        // sqlx refuses to read a TIMESTAMP as a naive date and time, only as a zoned one.
        "TIMESTAMP" => scalar(
            row,
            index,
            &type_name,
            |value: types::chrono::DateTime<types::chrono::Utc>| Cell::Timestamp(value.to_string()),
        ),
        "YEAR" => scalar(row, index, &type_name, |value: u16| Cell::Int(value.into())),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "BINARY" | "VARBINARY" => {
            scalar(row, index, &type_name, binary)
        }
        "GEOMETRY" => scalar(row, index, &type_name, |value: Vec<u8>| Cell::bytes(&value)),
        "BIT" => bits(row, index, &type_name),
        _ => text_or_bytes(row, index, &type_name),
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

/// A `BIT` column as the number its bits spell, which is how MySQL compares one.
fn bits(row: &MySqlRow, index: usize, type_name: &str) -> Cell {
    // sqlx decodes nothing from a `BIT`, so its bytes are taken without asking.
    match row.try_get_unchecked::<Vec<u8>, _>(index) {
        Ok(bytes) if bytes.len() <= 8 => {
            let value = bytes
                .iter()
                .fold(0u64, |value, byte| (value << 8) | u64::from(*byte));
            i64::try_from(value).map_or_else(|_| Cell::Decimal(value.to_string()), Cell::Int)
        }
        _ => text_or_bytes(row, index, type_name),
    }
}

fn decode_unsigned(row: &MySqlRow, index: usize, base: &str, type_name: &str) -> Cell {
    match base {
        "TINYINT" => scalar(row, index, type_name, |value: u8| Cell::Int(value.into())),
        "SMALLINT" => scalar(row, index, type_name, |value: u16| Cell::Int(value.into())),
        "INT" | "MEDIUMINT" => scalar(row, index, type_name, |value: u32| Cell::Int(value.into())),
        // An unsigned BIGINT reaches past i64.
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
