//! Parses keyword arguments sent from Lua.

use rmpv::Value;

/// Holds the argument table for one RPC call.
#[derive(Debug, Default)]
pub struct Args {
    entries: Vec<(String, Value)>,
}

impl Args {
    /// Read the argument table out of a method's parameters.
    pub fn from_params(params: &[Value]) -> Result<Self, String> {
        match params.first() {
            None | Some(Value::Nil) => Ok(Self::default()),
            Some(Value::Map(pairs)) => {
                let mut entries = Vec::with_capacity(pairs.len());
                for (key, value) in pairs {
                    let key = key
                        .as_str()
                        .ok_or_else(|| format!("argument keys must be strings, got {key}"))?;
                    entries.push((key.to_owned(), value.clone()));
                }
                Ok(Self { entries })
            }
            // Lua sends an empty table as an empty array, since it cannot tell the two apart.
            Some(Value::Array(items)) if items.is_empty() => Ok(Self::default()),
            Some(other) => Err(format!("expected a table of arguments, got {other}")),
        }
    }

    /// The raw value of one argument.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    /// A required string argument.
    pub fn string(&self, key: &str) -> Result<String, String> {
        match self.get(key) {
            Some(Value::String(text)) => text
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("`{key}` is not valid utf-8")),
            Some(other) => Err(format!("`{key}` must be a string, got {other}")),
            None => Err(format!("`{key}` is required")),
        }
    }

    /// An optional string argument.
    pub fn opt_string(&self, key: &str) -> Option<String> {
        self.get(key)?.as_str().map(str::to_owned)
    }

    /// An optional integer argument. A value of the wrong type is treated as absent.
    pub fn opt_integer(&self, key: &str) -> Option<i64> {
        self.get(key)?.as_i64()
    }

    /// An optional count, clamped at zero so a negative never wraps.
    pub fn opt_usize(&self, key: &str) -> Option<usize> {
        Some(usize::try_from(self.opt_integer(key)?).unwrap_or(0))
    }

    /// An optional boolean argument.
    pub fn opt_bool(&self, key: &str) -> Option<bool> {
        self.get(key)?.as_bool()
    }

    /// An optional array of strings. Returns an error if the array contains non-string items.
    pub fn opt_strings(&self, key: &str) -> Result<Option<Vec<String>>, String> {
        match self.get(key) {
            None => Ok(None),
            Some(Value::Array(items)) => {
                let mut strings = Vec::with_capacity(items.len());
                for (i, item) in items.iter().enumerate() {
                    match item.as_str() {
                        Some(s) => strings.push(s.to_owned()),
                        None => return Err(format!("`{key}[{i}]` must be a string, got {item}")),
                    }
                }
                Ok(Some(strings))
            }
            // Lua sends an empty table as an empty map, since it cannot tell a list from a table.
            Some(Value::Map(pairs)) if pairs.is_empty() => Ok(Some(Vec::new())),
            Some(_) => Ok(None),
        }
    }

    /// A required integer argument.
    pub fn integer(&self, key: &str) -> Result<i64, String> {
        match self.get(key) {
            Some(value) => value
                .as_i64()
                .ok_or_else(|| format!("`{key}` must be an integer, got {value}")),
            None => Err(format!("`{key}` is required")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(pairs: Vec<(&str, Value)>) -> Vec<Value> {
        vec![Value::Map(
            pairs
                .into_iter()
                .map(|(key, value)| (Value::from(key), value))
                .collect(),
        )]
    }

    #[test]
    fn reads_a_table() {
        let params = table(vec![
            ("sql", Value::from("select 1")),
            ("conn_id", Value::from(3)),
        ]);
        let args = Args::from_params(&params).expect("table should parse");
        assert_eq!(args.string("sql").unwrap(), "select 1");
        assert_eq!(args.integer("conn_id").unwrap(), 3);
    }

    #[test]
    fn missing_arguments_are_named_in_the_error() {
        let args = Args::from_params(&[]).expect("no params is an empty table");
        assert!(args.string("sql").unwrap_err().contains("sql"));
        assert_eq!(args.opt_string("sql"), None);
    }

    #[test]
    fn an_empty_lua_table_is_accepted() {
        assert!(Args::from_params(&[Value::Array(vec![])]).is_ok());
        assert!(Args::from_params(&[Value::Nil]).is_ok());
    }

    #[test]
    fn a_non_table_is_rejected() {
        assert!(Args::from_params(&[Value::from("nope")]).is_err());
    }

    #[test]
    fn optional_readers_tolerate_absent_and_wrong_types() {
        let params = table(vec![
            ("offset", Value::from(5)),
            ("refresh", Value::from(true)),
        ]);
        let args = Args::from_params(&params).unwrap();

        assert_eq!(args.opt_integer("offset"), Some(5));
        assert_eq!(args.opt_usize("offset"), Some(5));
        assert_eq!(args.opt_bool("refresh"), Some(true));
        assert_eq!(args.opt_integer("missing"), None);
        assert_eq!(args.opt_bool("offset"), None);
    }

    #[test]
    fn a_string_array_is_read() {
        let params = table(vec![(
            "path",
            Value::Array(vec![Value::from("public"), Value::from("users")]),
        )]);
        let args = Args::from_params(&params).unwrap();
        assert_eq!(
            args.opt_strings("path").unwrap(),
            Some(vec!["public".to_owned(), "users".to_owned()])
        );
    }

    #[test]
    fn an_empty_lua_list_reads_as_an_empty_array() {
        let params = table(vec![("path", Value::Map(vec![]))]);
        let args = Args::from_params(&params).unwrap();
        assert_eq!(args.opt_strings("path").unwrap(), Some(vec![]));
        assert_eq!(
            Args::from_params(&[]).unwrap().opt_strings("path").unwrap(),
            None
        );
    }

    #[test]
    fn non_string_items_in_array_are_rejected() {
        let params = table(vec![(
            "path",
            Value::Array(vec![
                Value::from("host1"),
                Value::from(5432),
                Value::from(true),
            ]),
        )]);
        let args = Args::from_params(&params).unwrap();
        let err = args.opt_strings("path").unwrap_err();
        assert!(err.contains("`path[1]` must be a string"));
    }

    #[test]
    fn a_negative_count_clamps_to_zero() {
        let params = table(vec![("offset", Value::from(-3))]);
        let args = Args::from_params(&params).unwrap();
        assert_eq!(args.opt_usize("offset"), Some(0));
    }

    #[test]
    fn wrong_types_are_rejected() {
        let params = table(vec![("sql", Value::from(1))]);
        let args = Args::from_params(&params).unwrap();
        assert!(args.string("sql").is_err());
    }
}
