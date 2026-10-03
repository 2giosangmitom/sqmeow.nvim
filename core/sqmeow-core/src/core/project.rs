//! Decode project connections without evaluating or interpolating their contents.
//!
//! Lua locates and reads the file, then sends its contents through
//! `project_connections`. This module checks TOML syntax and the flat connection
//! table shape; Lua validates dialect fields and builds URLs. No filesystem,
//! environment, shell, or database access occurs during parsing.

use rmpv::Value;

/// Convert named TOML connection tables to a MessagePack map of scalar fields.
///
/// Strings, integers, and booleans retain their types across RPC so Lua can
/// distinguish a port from a string and a boolean flag from a truthy value.
/// An empty document returns an empty map; section names become connection names.
///
/// # Errors
///
/// Rejects malformed TOML, non-table top-level entries, and non-scalar fields.
/// Parsing is all-or-nothing. Syntax errors identify the line without including
/// the source line, which may contain credentials.
pub(super) fn parse(contents: &str) -> Result<Value, String> {
    let tables = contents.parse::<toml::Table>().map_err(|error| {
        // TOML's Display includes the source line, which could contain a password.
        let line = error.span().map_or(1, |span| {
            contents[..span.start.min(contents.len())]
                .bytes()
                .filter(|byte| *byte == b'\n')
                .count()
                + 1
        });
        format!("invalid TOML at line {line}: {}", error.message())
    })?;

    let mut connections = Vec::new();
    for (name, entry) in tables {
        let toml::Value::Table(fields) = entry else {
            return Err(format!("`{name}` must be a connection table"));
        };
        let mut values = Vec::new();
        for (key, value) in fields {
            let value = match value {
                toml::Value::String(value) => Value::from(value),
                toml::Value::Integer(value) => Value::from(value),
                toml::Value::Boolean(value) => Value::from(value),
                _ => {
                    return Err(format!(
                        "`{name}.{key}` must be a string, integer or boolean"
                    ));
                }
            };
            values.push((Value::from(key), value));
        }
        connections.push((Value::from(name), Value::Map(values)));
    }
    Ok(Value::Map(connections))
}
