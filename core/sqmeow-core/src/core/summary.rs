//! Describing results to the editor.

use rmpv::Value;
use sqmeow_db::Cell;

use crate::session::Call;
use crate::value::map;

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
pub(super) fn summarize(call: &Call) -> Vec<(&'static str, Value)> {
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
    ];
    if let Some(source) = result.source() {
        let mut described = vec![
            ("kind", Value::from(source.kind())),
            ("name", Value::from(source.name())),
        ];
        if source.insertable() {
            described.push(("insertable", Value::from(true)));
        }
        pairs.push(("source", map(described)));
    }
    if let Some(affected) = result.affected() {
        pairs.push(("affected", Value::from(affected)));
    }
    pairs
}
