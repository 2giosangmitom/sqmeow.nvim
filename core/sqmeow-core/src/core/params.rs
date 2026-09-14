//! Reading method arguments into engine types.

use rmpv::Value;
use sqmeow_db::Changes;
use sqmeow_db::export::Format;
use sqmeow_db::view::{Filter, Op, Sort};

use crate::args::Args;
use crate::session::{CallId, ConnId};

impl Args {
    /// The required `call_id`.
    pub fn call_id(&self) -> Result<CallId, String> {
        self.integer("call_id").map(|id| CallId(id as u64))
    }

    /// A required connection id.
    pub fn conn_id(&self, key: &str) -> Result<ConnId, String> {
        self.integer(key).map(ConnId)
    }
}

/// The export format an argument names, CSV when it names none.
pub(super) fn format(args: &Args) -> Result<Format, String> {
    match args.opt_string("format").as_deref().map(Format::parse) {
        Some(Some(format)) => Ok(format),
        Some(None) => Err("format must be `csv` or `json`".to_owned()),
        None => Ok(Format::Csv),
    }
}

/// The elements of an array argument.
fn items(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().collect(),
        _ => Vec::new(),
    }
}

/// One field of a map argument.
fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value
        .as_map()?
        .iter()
        .find(|(name, _)| name.as_str() == Some(key))
        .map(|(_, value)| value)
}

/// An array of zero-based indices, or `None` when there is none or it is empty.
pub(super) fn indices(value: Option<&Value>) -> Option<Vec<usize>> {
    let indices: Vec<usize> = items(value)
        .into_iter()
        .filter_map(|item| usize::try_from(item.as_u64()?).ok())
        .collect();
    (!indices.is_empty()).then_some(indices)
}

/// The filters a `view` call carries. A filter without a column searches every column.
pub(super) fn filters(value: Option<&Value>) -> Result<Vec<Filter>, String> {
    items(value)
        .into_iter()
        .map(|item| {
            let op = field(item, "op")
                .and_then(Value::as_str)
                .unwrap_or_default();
            Ok(Filter {
                column: field(item, "column")
                    .and_then(Value::as_u64)
                    .and_then(|column| usize::try_from(column).ok()),
                op: Op::parse(op).ok_or_else(|| format!("`{op}` is not a filter"))?,
                value: field(item, "value")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            })
        })
        .collect()
}

/// The sort keys a `view` call carries.
pub(super) fn sort(value: Option<&Value>) -> Vec<Sort> {
    items(value)
        .into_iter()
        .filter_map(|item| {
            Some(Sort {
                column: usize::try_from(field(item, "column")?.as_u64()?).ok()?,
                descending: field(item, "descending")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect()
}

/// The staged changes a `plan` call carries.
pub(super) fn changes(value: Option<&Value>) -> Result<Changes, String> {
    let Some(value) = value else {
        return Ok(Changes::default());
    };
    let index = |item: &Value, key: &str| -> Result<usize, String> {
        field(item, key)
            .and_then(Value::as_u64)
            .and_then(|index| usize::try_from(index).ok())
            .ok_or_else(|| format!("a change needs a `{key}`"))
    };
    let cells = |list: Option<&Value>| -> Result<Vec<(usize, Option<String>)>, String> {
        items(list)
            .into_iter()
            .map(|cell| {
                let text = field(cell, "value")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                Ok((index(cell, "column")?, text))
            })
            .collect()
    };

    Ok(Changes {
        updates: items(field(value, "updates"))
            .into_iter()
            .map(|update| Ok((index(update, "row")?, cells(field(update, "cells"))?)))
            .collect::<Result<_, String>>()?,
        deletes: indices(field(value, "deletes")).unwrap_or_default(),
        inserts: items(field(value, "inserts"))
            .into_iter()
            .map(|insert| cells(Some(insert)))
            .collect::<Result<_, String>>()?,
    })
}
