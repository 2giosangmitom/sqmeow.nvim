//! Describing results to the editor.

use rmpv::Value;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::Source;
use sqmeow_db::value::Cell;

use crate::server::payload::map;
use crate::server::session::Call;

/// The view operations a result can currently perform. Structured memory views work on every
/// held result; free-form filter fragments on a disconnected MongoDB result do not.
pub(super) fn capabilities(dialect: Option<Dialect>, connected: bool) -> Value {
    let query = connected
        && !matches!(
            dialect,
            None | Some(Dialect::Redis | Dialect::Scylla | Dialect::SurrealDb)
        );
    let memory = true;
    map(vec![
        ("query", Value::from(query)),
        ("memory", Value::from(memory)),
        (
            "filter",
            Value::from(query || dialect != Some(Dialect::MongoDb)),
        ),
    ])
}

/// One cell, as the value it really is rather than as text.
pub(super) fn cell_value(cell: &Cell) -> Value {
    match cell {
        Cell::Null => Value::Nil,
        Cell::Bool(value) => Value::from(*value),
        Cell::Int(value) => Value::from(*value),
        Cell::Float(value) => Value::from(*value),
        // Exact numerics stay text.
        other => Value::from(other.display("").into_owned()),
    }
}

/// What the editor needs to describe a result and lay its columns out.
pub(super) fn summarize(call: &Call, connected: bool) -> Vec<(&'static str, Value)> {
    let result = &call.result;

    let columns: Vec<Value> = result
        .columns()
        .iter()
        .enumerate()
        .map(|(index, column)| {
            let stats = result.column_stats(index);
            let mut pairs = vec![
                ("name", Value::from(column.name.as_str())),
                ("type_name", Value::from(column.type_name.as_str())),
                ("class", Value::from(column.class.name())),
                // Display columns taken by the widest value, `NULL`s excluded.
                ("widest", Value::from(stats.widest as u64)),
                ("nulls", Value::from(stats.nulls)),
                ("numeric", Value::from(stats.numeric)),
            ];
            // Left out rather than sent as nil or false.
            if let Some(key) = column.key.name() {
                pairs.push(("key", Value::from(key)));
            }
            if result
                .source()
                .is_some_and(|source| source.editable(result, index))
            {
                pairs.push(("editable", Value::from(true)));
            }
            map(pairs)
        })
        .collect();

    let mut pairs = vec![
        ("columns", Value::Array(columns)),
        ("call_id", Value::from(call.id)),
        ("conn_id", Value::from(call.conn_id)),
        ("rows", Value::from(result.row_count() as u64)),
        ("sql", Value::from(result.statement())),
        ("truncated", Value::from(result.is_truncated())),
        ("capabilities", capabilities(call.dialect, connected)),
    ];
    if let Some(source) = result.source() {
        let mut described = vec![
            ("kind", Value::from(source.kind())),
            ("name", Value::from(source.name())),
        ];
        if source.insertable() {
            described.push(("insertable", Value::from(true)));
        }
        if let Source::Tables(tables) = source {
            let tables = tables
                .iter()
                .map(|table| {
                    let mut pairs = vec![
                        ("name", Value::from(table.name.as_str())),
                        (
                            "columns",
                            Value::Array(
                                table
                                    .columns
                                    .iter()
                                    .map(|(index, _)| Value::from(*index as u64))
                                    .collect(),
                            ),
                        ),
                    ];
                    if let Some(schema) = &table.schema {
                        pairs.push(("schema", Value::from(schema.as_str())));
                    }
                    map(pairs)
                })
                .collect();
            described.push(("tables", Value::Array(tables)));
        }
        pairs.push(("source", map(described)));
    }
    if let Some(affected) = result.affected() {
        pairs.push(("affected", Value::from(affected)));
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_distinguish_local_and_remote_results() {
        let get = |value: &Value, name: &str| {
            value
                .as_map()
                .unwrap()
                .iter()
                .find(|(key, _)| key.as_str() == Some(name))
                .and_then(|(_, value)| value.as_bool())
        };
        let sqlite = capabilities(Some(Dialect::Sqlite), true);
        assert_eq!(get(&sqlite, "query"), Some(true));
        assert_eq!(get(&sqlite, "memory"), Some(true));
        let redis = capabilities(Some(Dialect::Redis), true);
        assert_eq!(get(&redis, "query"), Some(false));
        assert_eq!(get(&redis, "memory"), Some(true));
        let mongo = capabilities(Some(Dialect::MongoDb), false);
        assert_eq!(get(&mongo, "filter"), Some(false));
        assert_eq!(get(&mongo, "memory"), Some(true));
        let mongo_open = capabilities(Some(Dialect::MongoDb), true);
        assert_eq!(get(&mongo_open, "query"), Some(true));
        assert_eq!(get(&mongo_open, "memory"), Some(true));
    }
}
