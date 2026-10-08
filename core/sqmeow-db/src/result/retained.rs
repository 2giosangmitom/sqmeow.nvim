//! Native scalar columns, with Object fallback only where conversion would lose values.

use std::borrow::Cow;

use polars::prelude::{AnyValue, Column, DataFrame, DataType, IntoSeries, ObjectChunked, Series};

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
            return Series::from_any_values_and_dtype(name.into(), &values, &dtype, true)
                .expect("matching native scalar values")
                .into();
        }
    }
    object(name, cells)
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
