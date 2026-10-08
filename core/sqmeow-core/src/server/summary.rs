//! Describing results to the editor.

use rmpv::Value;
use sqmeow_db::edit::Source;
use sqmeow_db::result::{AnyValue, ResultSet};
use sqmeow_db::value::Cell;

use crate::server::payload::map;
use crate::server::session::Call;

/// Every retained result can filter/sort locally. Only refresh requires a connection.
pub(super) fn capabilities(connected: bool) -> Value {
    map(vec![
        ("query", Value::from(connected)),
        ("memory", Value::from(true)),
        ("filter", Value::from(true)),
    ])
}

/// Encode nulls, booleans, and integers as MessagePack values; send other cells as text.
pub(super) fn cell_value(result: &ResultSet, row: usize, column: usize) -> Value {
    if matches!(
        result.scalar(row, column),
        Some(AnyValue::String(_) | AnyValue::Binary(_))
    ) {
        return Value::from(
            result
                .cell_display(row, column, "")
                .expect("retained row")
                .into_owned(),
        );
    }
    // Both native and fallback cells use the same wire-format rules.
    let cell = result.cell(row, column);
    match cell.as_deref().unwrap_or(&Cell::Null) {
        Cell::Null => Value::Nil,
        Cell::Bool(value) => Value::from(*value),
        Cell::Int(value) => Value::from(*value),
        // NaN and infinities have no MessagePack float form Neovim reads back.
        Cell::Float(value) if value.is_finite() => Value::from(*value),
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
                ("nulls", Value::from(stats.nulls)),
                ("numeric", Value::from(stats.numeric)),
            ];
            // Omit the key field for non-key columns.
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
        ("capabilities", capabilities(connected)),
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
    fn native_and_fallback_cells_keep_the_same_rpc_values() {
        let values = vec![
            Cell::Null,
            Cell::Bool(true),
            Cell::Int(i64::MAX),
            Cell::Float(0.125),
            Cell::Float(f64::NAN),
            Cell::Float(f64::INFINITY),
            Cell::Text("中\n\t\\\"".into()),
            Cell::bytes(&[255; 128]),
            Cell::Decimal("12345678901234567890.00100".into()),
            Cell::Timestamp("infinity".into()),
            Cell::Array(vec![Cell::Int(1), Cell::Null]),
        ];
        let columns = values
            .iter()
            .enumerate()
            .map(|(index, _)| sqmeow_db::result::Column::new(index.to_string(), "TEXT"))
            .collect();
        let mut native = ResultSet::new("native", columns);
        native.push_row(values.clone());
        let mut fallback =
            ResultSet::new("mixed", vec![sqmeow_db::result::Column::new("v", "TEXT")]);
        for value in &values {
            fallback.push_row(vec![value.clone()]);
        }
        for (index, value) in values.iter().enumerate() {
            let expected = match value {
                Cell::Null => Value::Nil,
                Cell::Bool(value) => Value::from(*value),
                Cell::Int(value) => Value::from(*value),
                Cell::Float(value) if value.is_finite() => Value::from(*value),
                value => Value::from(value.display("").into_owned()),
            };
            assert_eq!(cell_value(&native, 0, index), expected);
            assert_eq!(cell_value(&fallback, index, 0), expected);
        }
    }

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
        for connected in [true, false] {
            let flags = capabilities(connected);
            assert_eq!(get(&flags, "query"), Some(connected));
            assert_eq!(get(&flags, "memory"), Some(true));
            assert_eq!(get(&flags, "filter"), Some(true));
        }
    }
}
