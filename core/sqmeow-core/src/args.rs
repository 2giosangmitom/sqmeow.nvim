//! Reading the keyword arguments Lua sends.
//!
//! Every method takes one table, so `rpcrequest(chan, 'execute', { conn_id = 1, sql = '...' })`
//! arrives as a single map. Positional arguments were rejected early: adding a field to a table
//! does not break older callers, and the wire form stays readable in a log.

use rmpv::Value;

/// The argument table of one call.
#[derive(Debug, Default)]
pub struct Args {
    entries: Vec<(String, Value)>,
}

impl Args {
    /// Read the argument table out of a method's parameters.
    ///
    /// An absent table is an empty one, so methods that take no arguments work whether Lua sends
    /// `{}`, `nil`, or nothing at all.
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
    // The unit tests below exercise these, so they are only dead in a non-test build.
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "the query and connection methods land in the next milestone"
        )
    )]
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

    /// A required integer argument.
    // The unit tests below exercise these, so they are only dead in a non-test build.
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "the query and connection methods land in the next milestone"
        )
    )]
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
    fn wrong_types_are_rejected() {
        let params = table(vec![("sql", Value::from(1))]);
        let args = Args::from_params(&params).unwrap();
        assert!(args.string("sql").is_err());
    }
}
