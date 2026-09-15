//! Builds msgpack payloads for events sent to the editor.

use rmpv::Value;

/// Build a msgpack map from string keys.
pub fn map(pairs: Vec<(&str, Value)>) -> Value {
    Value::Map(
        pairs
            .into_iter()
            .map(|(key, value)| (Value::from(key), value))
            .collect(),
    )
}

/// Build a msgpack array of strings.
pub fn strings<I, S>(items: I) -> Value
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    Value::Array(
        items
            .into_iter()
            .map(|item| Value::from(item.into()))
            .collect(),
    )
}

/// Represent an optional value, using nil for absence.
pub fn optional(value: Option<Value>) -> Value {
    value.unwrap_or(Value::Nil)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_map_keeps_its_keys() {
        let value = map(vec![
            ("state", Value::from("done")),
            ("rows", Value::from(3)),
        ]);
        match value {
            Value::Map(pairs) => {
                assert_eq!(pairs.len(), 2);
                assert_eq!(pairs[0].0.as_str(), Some("state"));
                assert_eq!(pairs[1].1.as_u64(), Some(3));
            }
            other => panic!("expected a map, got {other:?}"),
        }
    }

    #[test]
    fn strings_become_an_array() {
        assert_eq!(
            strings(vec!["sqlite", "postgres"]),
            Value::Array(vec![Value::from("sqlite"), Value::from("postgres")])
        );
        assert_eq!(strings(Vec::<String>::new()), Value::Array(vec![]));
    }

    #[test]
    fn absence_is_nil() {
        assert_eq!(optional(None), Value::Nil);
        assert_eq!(optional(Some(Value::from(1))), Value::from(1));
    }
}
