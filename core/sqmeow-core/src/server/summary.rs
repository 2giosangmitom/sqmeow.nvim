//! Describing results to the editor.

use rmpv::Value;
use sqmeow_db::edit::Source;
use sqmeow_db::result::{AnyValue, ResultSet};
use sqmeow_db::value::{Cell, escape};

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
    // Read native scalars once. Falling through to Cell would repeat Polars
    // dispatch and materialize a value that MessagePack can encode directly.
    match result.scalar(row, column) {
        Some(AnyValue::Null) | None => return Value::Nil,
        Some(AnyValue::Boolean(value)) => return Value::from(value),
        Some(AnyValue::Int64(value)) => return Value::from(value),
        Some(AnyValue::Float64(value)) if value.is_finite() => return Value::from(value),
        Some(AnyValue::String(value)) => return Value::from(escape(value).into_owned()),
        Some(AnyValue::Binary(_)) => {
            return Value::from(
                result
                    .cell_display(row, column, "")
                    .expect("retained row")
                    .into_owned(),
            );
        }
        _ => {}
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

/// Dispatch native column types once per page, not once per displayed cell.
/// Object/binary columns keep the lossless compatibility encoder.
pub(super) fn page_values(result: &ResultSet, chosen: &[usize]) -> Vec<Value> {
    let mut rows: Vec<Vec<Value>> = chosen
        .iter()
        .map(|_| Vec::with_capacity(result.columns().len()))
        .collect();
    for (index, column) in result.frame().columns().iter().enumerate() {
        let series = column.as_materialized_series();
        if let Ok(values) = series.str() {
            for (row, &source) in rows.iter_mut().zip(chosen) {
                row.push(
                    values
                        .get(source)
                        .map_or(Value::Nil, |value| Value::from(escape(value).into_owned())),
                );
            }
        } else if let Ok(values) = series.i64() {
            for (row, &source) in rows.iter_mut().zip(chosen) {
                row.push(values.get(source).map_or(Value::Nil, Value::from));
            }
        } else if let Ok(values) = series.f64() {
            for (row, &source) in rows.iter_mut().zip(chosen) {
                row.push(match values.get(source) {
                    Some(value) if value.is_finite() => Value::from(value),
                    Some(value) => Value::from(Cell::Float(value).display("").into_owned()),
                    None => Value::Nil,
                });
            }
        } else if let Ok(values) = series.bool() {
            for (row, &source) in rows.iter_mut().zip(chosen) {
                row.push(values.get(source).map_or(Value::Nil, Value::from));
            }
        } else {
            for (row, &source) in rows.iter_mut().zip(chosen) {
                row.push(cell_value(result, source, index));
            }
        }
    }
    rows.into_iter().map(Value::Array).collect()
}

/// What the editor needs to describe a result and lay its columns out.
pub(super) fn summarize(call: &Call, connected: bool) -> Vec<(&'static str, Value)> {
    let (derived, _) = call.display();
    let result = derived.as_deref().unwrap_or(&call.result);

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
            Cell::Bool(false),
            Cell::Int(i64::MAX),
            Cell::Int(i64::MIN),
            Cell::Float(0.125),
            Cell::Float(-0.0),
            Cell::Float(f64::NAN),
            Cell::Float(f64::INFINITY),
            Cell::Text("中\n\t\\\"".into()),
            Cell::Text("plain\rtext".into()),
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
        assert_eq!(cell_value(&native, 1, 0), Value::Nil);
        assert_eq!(cell_value(&native, 0, values.len()), Value::Nil);
    }

    #[test]
    fn page_encoding_matches_cell_encoding_for_native_and_fallback_columns() {
        use sqmeow_db::result::Column;
        let mut result = ResultSet::new(
            "paging",
            vec![
                Column::new("text", "TEXT"),
                Column::new("int", "BIGINT"),
                Column::new("float", "DOUBLE"),
                Column::new("bool", "BOOLEAN"),
                Column::new("object", "DECIMAL"),
                Column::new("bytes", "BLOB"),
            ],
        );
        result.push_row(vec![
            Cell::Text("中\r\n\t".into()),
            Cell::Int(i64::MAX),
            Cell::Float(f64::INFINITY),
            Cell::Bool(false),
            Cell::Decimal("9999999999999999.00100".into()),
            Cell::bytes(&[255; 128]),
        ]);
        result.push_row(vec![
            Cell::Null,
            Cell::Null,
            Cell::Float(f64::NAN),
            Cell::Null,
            Cell::Null,
            Cell::Null,
        ]);
        result.push_row(vec![
            Cell::Text("plain".into()),
            Cell::Int(i64::MIN),
            Cell::Float(-0.0),
            Cell::Bool(true),
            Cell::Text("mixed".into()),
            Cell::bytes(&[]),
        ]);
        for chosen in [vec![], vec![0, 1, 2], vec![2, 0, 2, 1]] {
            let expected: Vec<Value> = chosen
                .iter()
                .map(|&row| {
                    Value::Array(
                        (0..result.columns().len())
                            .map(|column| cell_value(&result, row, column))
                            .collect(),
                    )
                })
                .collect();
            assert_eq!(page_values(&result, &chosen), expected);
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
