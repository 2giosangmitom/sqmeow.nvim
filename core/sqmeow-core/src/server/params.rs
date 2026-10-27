//! Reading method arguments into engine types.

use rmpv::Value;
use sqmeow_db::edit::Changes;
use sqmeow_db::edit::Value as Edit;
use sqmeow_db::export::Format;
use sqmeow_db::view::{Filter, Op, Sort};

use crate::server::args::Args;
use crate::server::session::{CallId, ConnId};

/// Query inputs are strings until the engine validates each declared type.
pub(super) fn query_values(
    value: Option<&Value>,
) -> Result<std::collections::HashMap<String, String>, String> {
    let mut values = std::collections::HashMap::new();
    match value {
        None | Some(Value::Nil) => return Ok(values),
        Some(Value::Array(items)) if items.is_empty() => return Ok(values),
        Some(Value::Map(pairs)) => {
            for (name, value) in pairs {
                let name = name.as_str().ok_or("parameter names must be strings")?;
                let value = value
                    .as_str()
                    .ok_or_else(|| format!("parameter `{name}` must be a string"))?;
                if values.insert(name.to_owned(), value.to_owned()).is_some() {
                    return Err(format!("parameter `{name}` was supplied twice"));
                }
            }
        }
        Some(_) => return Err("parameters must be a map of names to input strings".into()),
    }
    Ok(values)
}

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
        Some(None) => Err("format must be `csv`, `json` or `sql`".to_owned()),
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

/// One result column and the table column a key predicate compares it with.
pub(super) struct KeyColumn {
    /// Zero-based result column holding the key value.
    pub index: usize,
    /// The table column to compare in the target relation.
    pub column: String,
    /// The field's name in the result, for messages about its value.
    pub source: String,
}

/// The result columns and table column names that locate a row's foreign-key endpoints.
pub(super) fn key_columns(value: Option<&Value>) -> Result<Vec<KeyColumn>, String> {
    let Some(Value::Array(items)) = value else {
        return Err("`columns` must be a list of key columns".to_owned());
    };
    if items.is_empty() {
        return Err("`columns` must name at least one key column".to_owned());
    }
    items
        .iter()
        .map(|item| {
            let index = field(item, "index")
                .and_then(Value::as_u64)
                .and_then(|index| usize::try_from(index).ok())
                .ok_or("a key column needs a zero-based `index`")?;
            let column = field(item, "column")
                .and_then(Value::as_str)
                .ok_or("a key column needs a `column` name")?;
            let source = field(item, "source")
                .and_then(Value::as_str)
                .ok_or("a key column needs a `source` name")?;
            Ok(KeyColumn {
                index,
                column: column.to_owned(),
                source: source.to_owned(),
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
    let cells = |list: Option<&Value>| -> Result<Vec<(usize, Edit)>, String> {
        items(list)
            .into_iter()
            .map(|cell| {
                let expression = field(cell, "sql").and_then(Value::as_str);
                let value = match expression {
                    Some(expression) => Edit::Sql(expression.to_owned()),
                    None => field(cell, "value")
                        .and_then(Value::as_str)
                        .map_or(Edit::Null, Edit::from),
                };
                Ok((index(cell, "column")?, value))
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

#[cfg(test)]
mod query_tests {
    use super::*;

    #[test]
    fn query_inputs_are_strict_and_errors_do_not_include_values() {
        let values = Value::Map(vec![(Value::from("name"), Value::from("secret"))]);
        assert_eq!(query_values(Some(&values)).unwrap()["name"], "secret");
        for malformed in [
            Value::from("secret"),
            Value::Map(vec![(Value::from("name"), Value::from(42))]),
        ] {
            let error = query_values(Some(&malformed)).unwrap_err();
            assert!(!error.contains("secret"));
            assert!(!error.contains("42"));
        }
        assert!(
            query_values(Some(&Value::Map(vec![
                (Value::from("name"), Value::from("a")),
                (Value::from("name"), Value::from("b"))
            ])))
            .is_err()
        );
        assert!(
            query_values(Some(&Value::Array(vec![])))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn key_columns_need_an_index_a_column_and_a_source() {
        let value = Value::Array(vec![Value::Map(vec![
            (Value::from("index"), Value::from(0u64)),
            (Value::from("column"), Value::from("id")),
            (Value::from("source"), Value::from("user_id")),
        ])]);
        let parsed = key_columns(Some(&value)).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].index, 0);
        assert_eq!(parsed[0].column, "id");
        assert_eq!(parsed[0].source, "user_id");

        for malformed in [
            None,
            Some(Value::Array(vec![])),
            Some(Value::Array(vec![Value::from("id")])),
            Some(Value::Array(vec![Value::Map(vec![(
                Value::from("column"),
                Value::from("id"),
            )])])),
            Some(Value::Array(vec![Value::Map(vec![(
                Value::from("index"),
                Value::from(0u64),
            )])])),
            Some(Value::Array(vec![Value::Map(vec![
                (Value::from("index"), Value::from(0u64)),
                (Value::from("column"), Value::from("id")),
            ])])),
        ] {
            assert!(key_columns(malformed.as_ref()).is_err());
        }
    }
}
