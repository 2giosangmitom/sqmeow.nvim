//! The DuckDB adapter.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use duckdb::types::{Value, ValueRef};
use duckdb::{Connection, InterruptHandle, Row, Statement};
use sqlx::types::chrono::{NaiveDate, NaiveDateTime, NaiveTime};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, ForeignKey, KeyKind, RelationKind,
    RelationNode, Result, ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

use crate::stream::{Origin, TableKeys, check_affected};

/// One DuckDB database, driven from blocking threads since the driver is synchronous.
pub struct DuckDbAdapter {
    connection: Arc<Mutex<Connection>>,
    interrupt: Arc<InterruptHandle>,
}

impl std::fmt::Debug for DuckDbAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DuckDbAdapter").finish_non_exhaustive()
    }
}

impl DuckDbAdapter {
    /// Open a database file, or an in-memory one for `duckdb::memory:`.
    pub async fn connect(url: &str) -> Result<Self> {
        let path = database_path(url);
        let connection = tokio::task::spawn_blocking(move || match path {
            Some(path) => Connection::open(path),
            None => Connection::open_in_memory(),
        })
        .await
        .map_err(Error::driver)?
        .map_err(Error::driver)?;

        Ok(Self {
            interrupt: connection.interrupt_handle(),
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    /// Run `work` against the connection on a blocking thread.
    async fn run<T, F>(&self, work: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T> + Send + 'static,
    {
        let connection = Arc::clone(&self.connection);
        tokio::task::spawn_blocking(move || {
            let connection = connection.lock().map_err(Error::driver)?;
            work(&connection)
        })
        .await
        .map_err(Error::driver)?
    }
}

impl Adapter for DuckDbAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::DuckDb
    }

    fn quote_ident(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    async fn apply(&self, statements: &[String]) -> Result<()> {
        let statements = statements.to_vec();
        self.run(move |connection| {
            let transaction = connection.unchecked_transaction().map_err(Error::driver)?;
            for statement in &statements {
                let affected = transaction
                    .execute(statement, [])
                    .map_err(|error| Error::driver(format!("{error}\nin: {statement}")))?;
                check_affected(statement, affected as u64)?;
            }
            transaction.commit().map_err(Error::driver)
        })
        .await
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        let statement = statement.to_owned();
        let work = self.run(move |connection| read(connection, &statement, max_rows));
        tokio::select! {
            biased;

            () = cancel.cancelled() => {
                self.interrupt.interrupt();
                Err(Error::Cancelled)
            }
            result = work => result,
        }
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        self.run(|connection| {
            rows(
                connection,
                "select schema_name, schema_name = current_schema() from duckdb_schemas()
                 where database_name = current_database()
                   and schema_name not in ('information_schema', 'pg_catalog')
                 order by schema_name",
                [],
                |row| {
                    Ok(SchemaNode {
                        name: row.get(0)?,
                        is_default: row.get(1)?,
                    })
                },
            )
        })
        .await
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let schema = schema.to_owned();
        self.run(move |connection| {
            rows(
                connection,
                "select table_name, table_type from information_schema.tables
                 where table_catalog = current_database() and table_schema = ?
                 order by table_name",
                [schema],
                |row| {
                    let kind = match row.get::<_, String>(1)?.as_str() {
                        "BASE TABLE" => RelationKind::Table,
                        "VIEW" => RelationKind::View,
                        _ => RelationKind::Other,
                    };
                    Ok(RelationNode {
                        name: row.get(0)?,
                        kind,
                    })
                },
            )
        })
        .await
    }

    /// DuckDB's macros, which are the closest thing it has to stored functions.
    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        let schema = schema.to_owned();
        self.run(move |connection| {
            rows(
                connection,
                "select distinct function_name from duckdb_functions()
                 where database_name = current_database() and schema_name = ? and not internal
                 order by function_name",
                [schema],
                |row| Ok(crate::routine_node(row.get(0)?, "function")),
            )
        })
        .await
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let params = [schema.to_owned(), relation.to_owned()];
        self.run(move |connection| {
            rows(
                connection,
                "select c.column_name, c.data_type, c.is_nullable,
                        coalesce(list_contains(p.constraint_column_names, c.column_name), false),
                        f.referenced_table,
                        f.referenced_column_names[list_position(f.constraint_column_names, c.column_name)]
                 from duckdb_columns() c
                 left join duckdb_constraints() p
                   on p.table_oid = c.table_oid and p.constraint_type = 'PRIMARY KEY'
                 left join duckdb_constraints() f
                   on f.table_oid = c.table_oid and f.constraint_type = 'FOREIGN KEY'
                  and list_contains(f.constraint_column_names, c.column_name)
                 where c.database_name = current_database() and c.schema_name = ? and c.table_name = ?
                 order by c.column_index",
                params,
                |row| {
                    let table: Option<String> = row.get(4)?;
                    let column: Option<String> = row.get(5)?;
                    Ok(ColumnNode {
                        name: row.get(0)?,
                        type_name: row.get(1)?,
                        nullable: row.get(2)?,
                        primary_key: row.get(3)?,
                        foreign_key: table.zip(column).map(|(table, column)| ForeignKey { table, column }),
                    })
                },
            )
        })
        .await
    }

    async fn close(&self) {
        self.interrupt.interrupt();
    }
}

/// The file a `duckdb:` URL names, or `None` for an in-memory database.
fn database_path(url: &str) -> Option<String> {
    let rest = url.split_once(':').map_or("", |(_, rest)| rest);
    let rest = rest.strip_prefix("//").unwrap_or(rest);
    let path = rest.split_once('?').map_or(rest, |(path, _)| path);
    (!path.is_empty() && path != ":memory:").then(|| path.to_owned())
}

/// Run a metadata query and read each row with `read`.
fn rows<T, P: duckdb::Params>(
    connection: &Connection,
    sql: &str,
    params: P,
    read: impl FnMut(&Row<'_>) -> duckdb::Result<T>,
) -> Result<Vec<T>> {
    let mut statement = connection.prepare(sql).map_err(Error::driver)?;
    statement
        .query_map(params, read)
        .and_then(Iterator::collect)
        .map_err(Error::driver)
}

/// Run one statement and read up to `max_rows` of its rows.
fn read(connection: &Connection, sql: &str, max_rows: usize) -> Result<ResultSet> {
    let started = Instant::now();
    // Before the query, since another query on the connection would end its stream of rows.
    let described = describe(connection, sql);
    let mut statement = connection.prepare(sql).map_err(Error::driver)?;
    let mut rows = statement.query([]).map_err(Error::driver)?;
    let mut columns = rows.as_ref().map(result_columns).unwrap_or_default();
    let source = described
        .filter(|(_, origins, _)| origins.len() == columns.len())
        .and_then(|(table, origins, keys)| {
            for (column, origin) in columns.iter_mut().zip(&origins) {
                if let Some((_, name)) = origin {
                    column.key = keys.get(name).copied().unwrap_or_default();
                    column.origin = Some(name.clone());
                }
            }
            let known = TableKeys::default();
            known.remember(table, keys);
            known.source(&origins)
        });
    let uuids: Vec<bool> = columns.iter().map(|c| c.type_name == "UUID").collect();
    let mut result = ResultSet::new(sql, columns);
    result.set_source(source);

    while let Some(row) = rows.next().map_err(Error::driver)? {
        if result.row_count() >= max_rows {
            result.mark_truncated();
            break;
        }
        let cells = uuids
            .iter()
            .enumerate()
            .map(|(index, &uuid)| match decode_cell(row, index) {
                Cell::Text(text) if uuid => Cell::Uuid(text),
                cell => cell,
            })
            .collect();
        result.push_row(cells);
    }

    result.set_elapsed(started.elapsed());
    Ok(result)
}

/// For a `SELECT` whose rows are one table's rows: the table as `schema.table`, where each result
/// column came from, and the table's keys. Read with DuckDB's own parser.
fn describe(
    connection: &Connection,
    sql: &str,
) -> Option<(String, Vec<Origin>, HashMap<String, KeyKind>)> {
    use serde_json::Value as Json;

    let tree: String = connection
        .query_row("select json_serialize_sql(?::varchar)", [sql], |row| {
            row.get(0)
        })
        .ok()?;
    let tree: Json = serde_json::from_str(&tree).ok()?;
    let [statement] = tree["statements"].as_array()?.as_slice() else {
        return None;
    };
    let node = &statement["node"];
    let from = &node["from_table"];
    let empty = |value: &Json| value.as_array().is_some_and(Vec::is_empty);
    let plain = node["type"] == "SELECT_NODE"
        && from["type"] == "BASE_TABLE"
        && from["catalog_name"] == ""
        && from["at_clause"].is_null()
        && empty(&node["cte_map"]["map"])
        && empty(&node["group_expressions"])
        && node["having"].is_null()
        && node["modifiers"]
            .as_array()?
            .iter()
            .all(|modifier| modifier["type"] != "DISTINCT_MODIFIER");
    if !plain {
        return None;
    }

    let alias = from["alias"].as_str()?;
    let table_name = from["table_name"].as_str()?;
    let columns: Vec<(String, String, String, Option<KeyKind>)> = rows(
        connection,
        "select c.schema_name, c.table_name, c.column_name,
                case
                  when list_contains(p.constraint_column_names, c.column_name) then 'primary_key'
                  when exists (select 1 from duckdb_constraints() f
                               where f.table_oid = c.table_oid and f.constraint_type = 'FOREIGN KEY'
                                 and list_contains(f.constraint_column_names, c.column_name))
                    then 'foreign_key'
                  else ''
                end
         from duckdb_columns() c
         left join duckdb_constraints() p
           on p.table_oid = c.table_oid and p.constraint_type = 'PRIMARY KEY'
         where c.database_name = current_database()
           and lower(c.schema_name) = lower(coalesce(nullif(?, ''), current_schema()))
           and lower(c.table_name) = lower(?)
         order by c.column_index",
        [from["schema_name"].as_str()?, table_name],
        |row| {
            let kind: String = row.get(3)?;
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                KeyKind::from_name(&kind),
            ))
        },
    )
    .ok()?;

    let (schema, table, ..) = columns.first()?;
    let qualified = format!("{schema}.{table}");
    let keys = columns
        .iter()
        .filter_map(|(_, _, name, kind)| Some((name.clone(), (*kind)?)))
        .collect();
    let ours = |relation: &str| {
        relation.eq_ignore_ascii_case(alias) || relation.eq_ignore_ascii_case(table_name)
    };
    let origin = |name: &str| {
        columns
            .iter()
            .find(|(_, _, column, _)| column.eq_ignore_ascii_case(name))
            .map(|(_, _, column, _)| (qualified.clone(), column.clone()))
    };

    let mut origins = Vec::new();
    for item in node["select_list"].as_array()? {
        match item["class"].as_str()? {
            "STAR" => {
                let relation = item["relation_name"].as_str()?;
                let bare = (relation.is_empty() || ours(relation))
                    && item["columns"] == false
                    && item["expr"].is_null()
                    && empty(&item["replace_list"])
                    && empty(&item["rename_list"])
                    && empty(&item["qualified_exclude_list"]);
                if !bare {
                    return None;
                }
                let excluded: Vec<&str> = item["exclude_list"]
                    .as_array()?
                    .iter()
                    .filter_map(Json::as_str)
                    .collect();
                origins.extend(
                    columns
                        .iter()
                        .filter(|(_, _, name, _)| {
                            !excluded.iter().any(|e| e.eq_ignore_ascii_case(name))
                        })
                        .map(|(_, _, name, _)| Some((qualified.clone(), name.clone()))),
                );
            }
            "COLUMN_REF" => {
                let parts: Vec<&str> = item["column_names"]
                    .as_array()?
                    .iter()
                    .filter_map(Json::as_str)
                    .collect();
                origins.push(match parts.as_slice() {
                    [name] => origin(name),
                    [relation, name] if ours(relation) => origin(name),
                    _ => None,
                });
            }
            _ => origins.push(None),
        }
    }
    Some((qualified, origins, keys))
}

fn result_columns(statement: &Statement<'_>) -> Vec<Column> {
    (0..statement.column_count())
        .map(|index| {
            let name = statement.column_name(index).cloned().unwrap_or_default();
            let type_name = statement.column_logical_type(index).try_id().map_or_else(
                |_| "UNKNOWN".to_owned(),
                |id| format!("{id:?}").to_ascii_uppercase(),
            );
            Column::new(name, type_name)
        })
        .collect()
}

fn decode_cell(row: &Row<'_>, index: usize) -> Cell {
    let Ok(value) = row.get_ref(index) else {
        return Cell::Null;
    };
    let temporal = |text: std::result::Result<String, duckdb::Error>, wrap: fn(String) -> Cell| {
        text.map_or_else(|error| unsupported(value, error), wrap)
    };

    match value {
        ValueRef::Null => Cell::Null,
        ValueRef::Boolean(v) => Cell::Bool(v),
        ValueRef::TinyInt(v) => Cell::Int(v.into()),
        ValueRef::SmallInt(v) => Cell::Int(v.into()),
        ValueRef::Int(v) => Cell::Int(v.into()),
        ValueRef::BigInt(v) => Cell::Int(v),
        ValueRef::UTinyInt(v) => Cell::Int(v.into()),
        ValueRef::USmallInt(v) => Cell::Int(v.into()),
        ValueRef::UInt(v) => Cell::Int(v.into()),
        ValueRef::UBigInt(v) => {
            i64::try_from(v).map_or_else(|_| Cell::Decimal(v.to_string()), Cell::Int)
        }
        ValueRef::HugeInt(v) => Cell::Decimal(v.to_string()),
        ValueRef::UHugeInt(v) => Cell::Decimal(v.to_string()),
        ValueRef::Float(v) => Cell::Float(v.into()),
        ValueRef::Double(v) => Cell::Float(v),
        ValueRef::Decimal(v) => Cell::Decimal(v.to_string()),
        ValueRef::Text(_) | ValueRef::Enum(..) => value.as_str().map_or_else(
            |error| unsupported(value, error),
            |text| Cell::Text(text.to_owned()),
        ),
        ValueRef::Blob(bytes) | ValueRef::Geometry(bytes) => Cell::bytes(bytes),
        ValueRef::Date32(_) => temporal(
            row.get::<_, NaiveDate>(index).map(|v| v.to_string()),
            Cell::Date,
        ),
        ValueRef::Timestamp(..) => temporal(
            row.get::<_, NaiveDateTime>(index).map(|v| v.to_string()),
            Cell::Timestamp,
        ),
        ValueRef::Time64(..) => temporal(
            row.get::<_, NaiveTime>(index).map(|v| v.to_string()),
            Cell::Time,
        ),
        ValueRef::Interval {
            months,
            days,
            nanos,
        } => Cell::Text(format!("{months} months {days} days {nanos} ns")),
        _ => Cell::Json(json(value.to_owned()).to_string()),
    }
}

fn unsupported(value: ValueRef<'_>, error: impl std::fmt::Display) -> Cell {
    Cell::Unsupported {
        type_name: format!("{:?}", value.data_type()),
        raw: error.to_string(),
    }
}

/// A list, struct, map or union as JSON.
fn json(value: Value) -> serde_json::Value {
    use serde_json::Value as Json;

    match value {
        Value::Null => Json::Null,
        Value::Boolean(v) => v.into(),
        Value::TinyInt(v) => v.into(),
        Value::SmallInt(v) => v.into(),
        Value::Int(v) => v.into(),
        Value::BigInt(v) => v.into(),
        Value::UTinyInt(v) => v.into(),
        Value::USmallInt(v) => v.into(),
        Value::UInt(v) => v.into(),
        Value::UBigInt(v) => v.into(),
        Value::Float(v) => f64::from(v).into(),
        Value::Double(v) => v.into(),
        Value::HugeInt(v) => v.to_string().into(),
        Value::UHugeInt(v) => v.to_string().into(),
        Value::Decimal(v) => v.to_string().into(),
        Value::Text(v) | Value::Enum(v) => v.into(),
        Value::List(items) | Value::Array(items) => items.into_iter().map(json).collect(),
        Value::Struct(fields) => fields
            .iter()
            .map(|(name, v)| (name.clone(), json(v.clone())))
            .collect(),
        Value::Map(entries) => entries
            .iter()
            .map(|(key, v)| {
                let key = match json(key.clone()) {
                    Json::String(text) => text,
                    other => other.to_string(),
                };
                (key, json(v.clone()))
            })
            .collect(),
        Value::Union(v) => json(*v),
        other => format!("{other:?}").into(),
    }
}

#[cfg(test)]
mod tests {
    use super::database_path;

    #[test]
    fn reads_the_file_from_each_url_spelling() {
        assert_eq!(database_path("duckdb:app.db").as_deref(), Some("app.db"));
        assert_eq!(database_path("duckdb://app.db").as_deref(), Some("app.db"));
        assert_eq!(
            database_path("duckdb:///var/app.db").as_deref(),
            Some("/var/app.db")
        );
        assert_eq!(
            database_path("duckdb:app.db?x=1").as_deref(),
            Some("app.db")
        );
        assert_eq!(database_path("duckdb::memory:"), None);
        assert_eq!(database_path("duckdb:"), None);
    }
}
