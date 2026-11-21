//! Native scalar columns, with Object fallback only where conversion would lose values.

use std::borrow::Cow;

use polars::prelude::{
    AnyValue, Column, CompatLevel, DataFrame, DataType, IntoSeries, ObjectChunked, Series,
};

use crate::value::{Cell, RetainedCell};

pub(super) fn column(name: &str, cells: Vec<RetainedCell>) -> Column {
    let values: Option<Vec<_>> = cells
        .iter()
        .map(|cell| match &cell.0 {
            Cell::Null => Some(AnyValue::Null),
            Cell::Bool(value) => Some(AnyValue::Boolean(*value)),
            Cell::Int(value) => Some(AnyValue::Int64(*value)),
            Cell::Float(value) => Some(AnyValue::Float64(*value)),
            Cell::Text(value) => Some(AnyValue::String(value)),
            Cell::Bytes { head, len } if head.len() == *len => Some(AnyValue::Binary(head)),
            _ => None,
        })
        .collect();
    if let Some(values) = values {
        let dtype = values
            .iter()
            .find(|value| !value.is_null())
            .map(AnyValue::dtype)
            .unwrap_or(DataType::Null);
        // Even strict Polars construction can coerce some numeric types. Do not
        // let mixed Int/Float columns round large integer keys or change variants.
        if values
            .iter()
            .all(|value| value.is_null() || value.dtype() == dtype)
        {
            let series = Series::from_any_values_and_dtype(name.into(), &values, &dtype, true)
                .expect("matching native scalar values");
            return compact_text(series).into();
        }
    }
    object(name, cells)
}

/// Large string-view builders retain spare capacity in their growing buffers.
/// Polars' Arrow compatibility conversion packs the bytes into one buffer;
/// importing it restores native String storage without changing values/nulls.
/// Pay this one-time copy only for substantial out-of-line text, before sharing.
fn compact_text(series: Series) -> Series {
    const MIN_BUFFER_BYTES: usize = 1024 * 1024;
    // Bound the transient copy. Larger columns already benefit from native
    // storage; copying them again can raise ingest peak RSS and latency.
    const MAX_BUFFER_BYTES: usize = 4 * 1024 * 1024;
    if series.str().is_ok_and(|strings| {
        strings.downcast_iter().any(|array| {
            let buffer_bytes = array.total_buffer_len();
            // Offset-based Arrow export also copies inline strings into the
            // byte buffer. Skip inline-heavy columns rather than duplicate
            // substantial text that already fits inside native views.
            let inline_bytes = array.total_bytes_len().saturating_sub(buffer_bytes);
            (MIN_BUFFER_BYTES..=MAX_BUFFER_BYTES).contains(&buffer_bytes)
                && inline_bytes <= buffer_bytes / 8
        })
    }) {
        let compacted = Series::from_arrow(
            series.name().clone(),
            series.to_arrow(0, CompatLevel::oldest()),
        )
        .expect("native text Arrow roundtrip");
        // Arrow import leaves string-byte statistics lazy. Populate them before
        // views clone the array, rather than scanning it during cache admission.
        let _ = compacted.estimated_size();
        compacted
    } else {
        series
    }
}

fn object(name: &str, cells: Vec<RetainedCell>) -> Column {
    ObjectChunked::new_from_vec(name.into(), cells)
        .into_series()
        .into()
}

/// Only native scalar access materializes a Cell. Fallback values stay borrowed.
pub(super) fn cell(column: &Column, row: usize) -> Option<Cow<'_, Cell>> {
    if row >= column.len() {
        return None;
    }
    if let Some(values) = column
        .as_materialized_series()
        .as_any()
        .downcast_ref::<ObjectChunked<RetainedCell>>()
    {
        return values.get(row).map(|value| Cow::Borrowed(&value.0));
    }
    Some(Cow::Owned(
        match column.as_materialized_series().get(row).ok()? {
            AnyValue::Null => Cell::Null,
            AnyValue::Boolean(value) => Cell::Bool(value),
            AnyValue::Int64(value) => Cell::Int(value),
            AnyValue::Float64(value) => Cell::Float(value),
            AnyValue::String(value) => Cell::Text(value.into()),
            AnyValue::Binary(value) => Cell::Bytes {
                head: value.into(),
                len: value.len(),
            },
            other => unreachable!("retained native scalar dtype: {other:?}"),
        },
    ))
}

/// Appends preserve exact variants. A type change promotes only that column to Object.
pub(super) fn append(frame: &mut DataFrame, row: Vec<Cell>) {
    let height = frame.height();
    let columns = frame
        .columns()
        .iter()
        .zip(row)
        .map(|(held, value)| {
            let name = held.name().as_str();
            let mut tail = if matches!(held.dtype(), DataType::Object(_)) {
                object(name, vec![RetainedCell(value)])
            } else {
                column(name, vec![RetainedCell(value)])
            };
            let mut head = held.clone();
            if tail.dtype() == &DataType::Null {
                tail = tail
                    .cast(head.dtype())
                    .expect("null casts to retained dtype");
            } else if head.dtype() == &DataType::Null {
                head = if matches!(tail.dtype(), DataType::Object(_)) {
                    object(name, vec![RetainedCell(Cell::Null); height])
                } else {
                    head.cast(tail.dtype())
                        .expect("null casts to appended dtype")
                };
            } else if head.dtype() != tail.dtype() {
                let mut cells: Vec<_> = (0..height)
                    .map(|row| RetainedCell(cell(held, row).expect("retained row").into_owned()))
                    .collect();
                cells.push(RetainedCell(
                    cell(&tail, 0).expect("appended row").into_owned(),
                ));
                return object(name, cells);
            }
            let mut series = head.take_materialized_series();
            series
                .append(tail.as_materialized_series())
                .expect("matching retained dtype");
            series.into()
        })
        .collect();
    *frame = DataFrame::new(height + 1, columns).expect("rectangular appended frame");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_text_buffers_are_packed_without_changing_cells() {
        let cells: Vec<_> = (0..12_000)
            .map(|index| {
                RetainedCell(match index % 7 {
                    0 => Cell::Null,
                    1 => Cell::Text(String::new()),
                    2 => Cell::Text("中🙂".into()),
                    _ => Cell::Text(format!("{index}\n\t{}", "é".repeat(128))),
                })
            })
            .collect();
        let expected: Vec<_> = cells.iter().map(|value| value.0.clone()).collect();
        let column = column("text", cells);
        assert_eq!(column.dtype(), &DataType::String);
        let values = column.str().unwrap();
        assert_eq!(values.chunks().len(), 1);
        assert_eq!(
            values.downcast_iter().next().unwrap().data_buffers().len(),
            1
        );
        for (index, expected) in expected.iter().enumerate() {
            assert_eq!(cell(&column, index).unwrap().as_ref(), expected);
        }
    }

    #[rstest::rstest]
    #[case::small(100, 1)]
    #[case::large(8_000, 1)]
    #[case::inline_heavy(20_000, 10)]
    fn text_keeps_original_buffers(#[case] rows: usize, #[case] long_every: usize) {
        let text: Vec<_> = (0..rows)
            .map(|index| {
                if index % long_every == 0 {
                    "x".repeat(600)
                } else {
                    "short-inline".into()
                }
            })
            .collect();
        let values: Vec<_> = text.iter().map(|value| AnyValue::String(value)).collect();
        let series =
            Series::from_any_values_and_dtype("text".into(), &values, &DataType::String, true)
                .unwrap();
        let before = series
            .str()
            .unwrap()
            .downcast_iter()
            .next()
            .unwrap()
            .data_buffers()
            .as_ptr();
        let compacted = compact_text(series);
        let after = compacted
            .str()
            .unwrap()
            .downcast_iter()
            .next()
            .unwrap()
            .data_buffers()
            .as_ptr();
        assert_eq!(
            before, after,
            "skip compaction outside the byte/copy budget"
        );
    }
}
