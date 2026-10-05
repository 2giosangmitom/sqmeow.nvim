//! Named query parameters, discovered lexically and replaced only with native binds.

use std::collections::HashMap;

use sqlparser::dialect::{GenericDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::tokenizer::{Location, Token, TokenWithSpan, Tokenizer, Whitespace};

use crate::adapter::Dialect;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Text,
    Int,
    Float,
    Bool,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Int => "int",
            Self::Float => "float",
            Self::Bool => "bool",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parameter {
    pub name: String,
    pub kind: Kind,
    pub default: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null(Kind),
    Text(String),
    Int(i64),
    Float(f64),
    Bool(bool),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Bound {
    pub sql: String,
    pub values: Vec<Value>,
}

pub fn describe(
    dialect: Dialect,
    source: &str,
    statements: &[&str],
) -> Result<Vec<Parameter>, String> {
    // Redis/JSON/SurrealQL/CQL punctuation is not SQL parameter syntax.
    if matches!(
        dialect,
        Dialect::Redis | Dialect::MongoDb | Dialect::SurrealDb | Dialect::Scylla
    ) {
        if source
            .lines()
            .any(|line| line.trim_start().starts_with("-- @param "))
        {
            return Err(format!(
                "Parameters are not supported for {}",
                dialect.name()
            ));
        }
        return Ok(Vec::new());
    }
    if !source.contains(':') && !source.contains("@param") {
        return Ok(Vec::new());
    }
    let mut names = Vec::new();
    for statement in statements {
        for (_, _, name) in discover(dialect, statement)? {
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    let mut definitions = HashMap::new();
    // A malformed statement elsewhere in a scratchpad must not block a valid selection.
    // Keep only completed lexical tokens, so strings cannot masquerade as annotations.
    let mut source_tokens = Vec::new();
    let _ = tokenizer(dialect, source).tokenize_with_location_into_buf(&mut source_tokens);
    for token in source_tokens {
        let Token::Whitespace(Whitespace::SingleLineComment { prefix, comment }) = token.token
        else {
            continue;
        };
        if prefix != "--" {
            continue;
        }
        let mut words = comment.split_whitespace();
        if words.next() != Some("@param") {
            continue;
        }
        let body = comment.trim().strip_prefix("@param").unwrap().trim();
        let (declaration, default) = body.split_once('=').map_or((body, None), |(head, tail)| {
            (head.trim(), Some(tail.trim().to_owned()))
        });
        let parts: Vec<_> = declaration.split_whitespace().collect();
        if !parts
            .first()
            .is_some_and(|name| names.iter().any(|used| used == name))
        {
            continue;
        }
        if parts.len() != 2 || !valid_name(parts[0]) {
            return Err(format!("Invalid parameter annotation: {body}"));
        }
        let kind = match parts[1] {
            "text" => Kind::Text,
            "int" => Kind::Int,
            "float" => Kind::Float,
            "bool" => Kind::Bool,
            other => return Err(format!("Invalid parameter kind: {other}")),
        };
        let parameter = Parameter {
            name: parts[0].to_owned(),
            kind,
            default,
        };
        if let Some(default) = &parameter.default {
            parse(&parameter, default)?;
        }
        if definitions
            .insert(parameter.name.clone(), parameter)
            .is_some()
        {
            return Err(format!("Duplicate parameter annotation: {}", parts[0]));
        }
    }

    let mut result = Vec::new();
    for name in names {
        result.push(definitions.remove(&name).unwrap_or(Parameter {
            name,
            kind: Kind::Text,
            default: None,
        }));
    }
    Ok(result)
}

pub fn compile(
    dialect: Dialect,
    sql: &str,
    parameters: &[Parameter],
    values: &HashMap<String, String>,
) -> Result<Bound, String> {
    let occurrences = discover(dialect, sql)?;
    let mut bound = Bound {
        sql: String::with_capacity(sql.len()),
        values: Vec::new(),
    };
    let mut indexes = HashMap::new();
    let mut cursor = 0;
    for (start, end, name) in occurrences {
        bound.sql.push_str(&sql[cursor..start]);
        let repeated = indexes.contains_key(&name);
        let index = if let Some(index) = indexes.get(&name) {
            *index
        } else {
            let mut matching = parameters.iter().filter(|parameter| parameter.name == name);
            let parameter = matching
                .next()
                .ok_or_else(|| format!("Unknown parameter: {name}"))?;
            if matching.next().is_some() {
                return Err(format!("Duplicate parameter: {name}"));
            }
            let raw = values
                .get(&name)
                .or(parameter.default.as_ref())
                .ok_or_else(|| format!("Missing value for parameter: {name}"))?;
            bound.values.push(parse(parameter, raw)?);
            let index = bound.values.len();
            indexes.insert(name, index);
            index
        };
        if dialect == Dialect::Postgres {
            bound.sql.push_str(&format!("${index}"));
        } else {
            bound.sql.push('?');
            // Every question mark is a distinct positional bind.
            if repeated {
                bound.values.push(bound.values[index - 1].clone());
            }
        }
        cursor = end;
    }
    bound.sql.push_str(&sql[cursor..]);
    Ok(bound)
}

fn parse(parameter: &Parameter, raw: &str) -> Result<Value, String> {
    let trimmed = raw.trim();
    if trimmed.eq_ignore_ascii_case("null") {
        return Ok(Value::Null(parameter.kind));
    }
    let invalid = || {
        format!(
            "Invalid {} value for parameter: {}",
            parameter.kind.name(),
            parameter.name
        )
    };
    match parameter.kind {
        Kind::Text if trimmed.starts_with('"') => serde_json::from_str::<String>(trimmed)
            .map(Value::Text)
            .map_err(|_| invalid()),
        Kind::Text => Ok(Value::Text(raw.to_owned())),
        Kind::Int => trimmed.parse().map(Value::Int).map_err(|_| invalid()),
        Kind::Float => {
            let value: f64 = trimmed.parse().map_err(|_| invalid())?;
            if !value.is_finite() {
                return Err(invalid());
            }
            Ok(Value::Float(value))
        }
        Kind::Bool => match trimmed {
            "true" => Ok(Value::Bool(true)),
            "false" => Ok(Value::Bool(false)),
            _ => Err(invalid()),
        },
    }
}

fn tokens(dialect: Dialect, sql: &str) -> Result<Vec<TokenWithSpan>, String> {
    tokenizer(dialect, sql)
        .tokenize_with_location()
        .map_err(|error| error.to_string())
}

fn tokenizer(dialect: Dialect, sql: &str) -> Tokenizer<'_> {
    let grammar: &dyn sqlparser::dialect::Dialect = match dialect {
        Dialect::Sqlite => &SQLiteDialect {},
        Dialect::Postgres => &PostgreSqlDialect {},
        Dialect::MySql => &MySqlDialect {},
        _ => &GenericDialect {},
    };
    Tokenizer::new(grammar, sql)
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn discover(dialect: Dialect, sql: &str) -> Result<Vec<(usize, usize, String)>, String> {
    let tokens = tokens(dialect, sql)?;
    // Token locations count characters, not UTF-8 bytes. Preserve the original bytes.
    let mut offsets = HashMap::new();
    let (mut line, mut column) = (1, 1);
    for (offset, character) in sql.char_indices() {
        offsets.insert(Location::new(line, column), offset);
        if character == '\n' {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    let mut occurrences = Vec::new();
    let mut native = false;
    let mut delimiters = Vec::new();
    for (index, token) in tokens.iter().enumerate() {
        match token.token {
            Token::LBracket | Token::LParen => delimiters.push(token.token.clone()),
            Token::RBracket | Token::RParen => {
                delimiters.pop();
            }
            _ => {}
        }
        native |= matches!(token.token, Token::Placeholder(_))
            || dialect != Dialect::Postgres && matches!(token.token, Token::Question)
            || dialect == Dialect::Sqlite && matches!(token.token, Token::AtSign);
        if token.token != Token::Colon {
            continue;
        }
        // PostgreSQL subscripts use ':' for slices, with arbitrary whitespace.
        // Parenthesize named inputs inside a subscript to distinguish them from slices.
        if dialect == Dialect::Postgres && delimiters.last() == Some(&Token::LBracket) {
            continue;
        }
        let Some(next) = tokens.get(index + 1) else {
            continue;
        };
        let Token::Word(word) = &next.token else {
            continue;
        };
        let start = offsets[&token.span.start];
        if word.quote_style.is_none()
            && valid_name(&word.value)
            && offsets[&next.span.start] == start + 1
            && !sql[..start]
                .chars()
                .next_back()
                .is_some_and(|character| character.is_ascii_alphanumeric() || character == '_')
        {
            occurrences.push((start, start + 1 + word.value.len(), word.value.clone()));
        }
    }
    if !occurrences.is_empty() {
        if !matches!(
            dialect,
            Dialect::Sqlite | Dialect::Postgres | Dialect::MySql
        ) {
            return Err(format!(
                "Parameters are not supported for {}",
                dialect.name()
            ));
        }
        if native {
            return Err("Cannot mix named parameters and native positional binds".to_owned());
        }
    }
    Ok(occurrences)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values(entries: &[(&str, &str)]) -> HashMap<String, String> {
        entries
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    #[test]
    fn repeated_names_and_bind_order() {
        for dialect in [Dialect::Sqlite, Dialect::MySql, Dialect::Postgres] {
            let sql = "SELECT :a, :a, :b, :a, :b";
            let parameters = describe(dialect, sql, &[sql]).unwrap();
            let bound = compile(
                dialect,
                sql,
                &parameters,
                &values(&[("a", "one"), ("b", "two")]),
            )
            .unwrap();
            let one = Value::Text("one".into());
            let two = Value::Text("two".into());
            if dialect == Dialect::Postgres {
                assert_eq!(bound.sql, "SELECT $1, $1, $2, $1, $2");
                assert_eq!(bound.values, vec![one, two]);
            } else {
                assert_eq!(bound.sql, "SELECT ?, ?, ?, ?, ?");
                assert_eq!(
                    bound.values,
                    vec![one.clone(), one.clone(), two.clone(), one, two]
                );
            }
        }
    }

    #[test]
    fn header_defaults_and_multiple_statements() {
        let source = "-- @param count int = 42\n-- @param status text = active\n-- @param unused bool = false\nSELECT :status; SELECT :count, :status";
        let parameters = describe(
            Dialect::Sqlite,
            source,
            &["SELECT :status", "SELECT :count, :status"],
        )
        .unwrap();
        assert_eq!(
            parameters
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>(),
            vec!["status", "count"]
        );
        let bound = compile(
            Dialect::Sqlite,
            "SELECT :count, :status",
            &parameters,
            &HashMap::new(),
        )
        .unwrap();
        assert_eq!(
            bound.values,
            vec![Value::Int(42), Value::Text("active".into())]
        );
    }

    #[test]
    fn null_empty_and_quoted_text() {
        let parameter = Parameter {
            name: "x".into(),
            kind: Kind::Text,
            default: None,
        };
        for (raw, expected) in [
            ("NuLl", Value::Null(Kind::Text)),
            ("", Value::Text(String::new())),
            ("\"NULL\"", Value::Text("NULL".into())),
            ("\"  padded  \"", Value::Text("  padded  ".into())),
            ("  plain  ", Value::Text("  plain  ".into())),
        ] {
            assert_eq!(parse(&parameter, raw).unwrap(), expected);
        }
    }

    #[test]
    fn typed_values_and_nulls() {
        for (kind, raw, expected) in [
            (Kind::Int, "-9223372036854775808", Value::Int(i64::MIN)),
            (Kind::Float, "1.25e2", Value::Float(125.0)),
            (Kind::Bool, "true", Value::Bool(true)),
            (Kind::Bool, "false", Value::Bool(false)),
        ] {
            let parameter = Parameter {
                name: "x".into(),
                kind,
                default: None,
            };
            assert_eq!(parse(&parameter, raw).unwrap(), expected);
            assert_eq!(parse(&parameter, "NULL").unwrap(), Value::Null(kind));
        }
    }

    #[test]
    fn invalid_values_and_definitions() {
        for (kind, raw) in [
            (Kind::Int, "9223372036854775808"),
            (Kind::Int, "1.0"),
            (Kind::Float, "NaN"),
            (Kind::Float, "inf"),
            (Kind::Bool, "TRUE"),
            (Kind::Bool, "1"),
            (Kind::Text, "\"unterminated"),
        ] {
            let parameter = Parameter {
                name: "x".into(),
                kind,
                default: None,
            };
            assert!(parse(&parameter, raw).is_err(), "{kind:?}: {raw}");
        }
        for source in [
            "-- @param x integer",
            "-- @param x int = nope",
            "-- @param x bool = yes",
            "-- @param x",
            "-- @param x int\n-- @param x text",
            "-- @param x int\n-- @param x int",
        ] {
            assert!(
                describe(Dialect::Sqlite, source, &["SELECT :x"]).is_err(),
                "{source}"
            );
        }
        let parameters = describe(Dialect::Sqlite, "SELECT :x", &["SELECT :x"]).unwrap();
        assert!(compile(Dialect::Sqlite, "SELECT :x", &parameters, &HashMap::new()).is_err());
        assert!(
            compile(
                Dialect::Sqlite,
                "SELECT :y",
                &parameters,
                &values(&[("y", "a")])
            )
            .is_err()
        );
    }

    #[test]
    fn lexical_context_and_original_bytes() {
        let sql = "SELECT 'é :fake', \"quoted:name\", $$:dollar -- @param x int$$, $tag$:tag$tag$, :x::text, a := 1 /* :comment */ -- :line\n, :x";
        let parameters = describe(Dialect::Postgres, sql, &[sql]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(parameters[0].kind, Kind::Text);
        let bound = compile(
            Dialect::Postgres,
            sql,
            &parameters,
            &values(&[("x", "a' ; DROP TABLE t")]),
        )
        .unwrap();
        assert_eq!(
            bound.sql,
            sql.replace(":x::text", "$1::text").replace(", :x", ", $1")
        );
        assert_eq!(bound.values, vec![Value::Text("a' ; DROP TABLE t".into())]);
        let mysql = "SELECT `:backtick`, 'it\\'s :hidden', :x # :ignored\n";
        let parameters = describe(Dialect::MySql, mysql, &[mysql]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(
            compile(Dialect::MySql, mysql, &parameters, &values(&[("x", "ok")]))
                .unwrap()
                .sql,
            mysql.replace(":x", "?")
        );
    }

    #[test]
    fn annotations_only_in_real_line_comments() {
        let source = "SELECT '-- @param x int = 1'; /* -- @param x bool */\n-- @param x text = yes\nSELECT :x";
        let parameters = describe(Dialect::Sqlite, source, &["SELECT :x"]).unwrap();
        assert_eq!(parameters[0].kind, Kind::Text);
        assert_eq!(parameters[0].default.as_deref(), Some("yes"));
    }

    #[test]
    fn native_binds_and_unsupported_dialects() {
        for (dialect, sql) in [
            (Dialect::Postgres, "SELECT :x, $1"),
            (Dialect::Sqlite, "SELECT :x, ?"),
            (Dialect::Sqlite, "SELECT :x, ?12"),
            (Dialect::Sqlite, "SELECT :x, @native"),
            (Dialect::Sqlite, "SELECT :x, $native"),
            (Dialect::MySql, "SELECT :x, ?"),
        ] {
            assert!(describe(dialect, sql, &[sql]).is_err(), "{sql}");
            assert!(compile(dialect, sql, &[], &HashMap::new()).is_err());
        }
        assert!(describe(Dialect::DuckDb, "SELECT :x", &["SELECT :x"]).is_err());
        let sql = "SELECT $1, 'no :parameters'";
        assert_eq!(
            compile(Dialect::Postgres, sql, &[], &HashMap::new()).unwrap(),
            Bound {
                sql: sql.into(),
                values: vec![]
            }
        );
    }

    #[test]
    fn nosql_punctuation_is_not_a_parameter() {
        for (dialect, sql) in [
            (Dialect::Redis, "HGETALL cache:user:42"),
            (
                Dialect::MongoDb,
                r#"{"find":"users","filter":{"_id":{"$oid":"abc"}}}"#,
            ),
            (Dialect::SurrealDb, "SELECT * FROM user:alice"),
            (Dialect::Scylla, "CREATE TABLE users (id int PRIMARY KEY)"),
        ] {
            assert!(describe(dialect, sql, &[sql]).unwrap().is_empty());
        }
    }

    #[test]
    fn postgres_array_slice_bounds_are_not_placeholders() {
        let sql = "SELECT items[lower:upper], items[lower :upper], items[1 :last], items[:last], items[(:wanted)], :wanted";
        let parameters = describe(Dialect::Postgres, sql, &[sql]).unwrap();
        assert_eq!(
            parameters
                .iter()
                .map(|parameter| parameter.name.as_str())
                .collect::<Vec<_>>(),
            vec!["wanted"]
        );
    }

    #[test]
    fn selected_inputs_ignore_unrelated_invalid_sql_and_declarations() {
        let source =
            "-- @param x int = 42\n-- @param unused invalid = bad\nSELECT :x;\nSELECT 'unfinished";
        let parameters = describe(Dialect::Sqlite, source, &["SELECT :x"]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(parameters[0].kind, Kind::Int);
        assert_eq!(parameters[0].default.as_deref(), Some("42"));
    }
}
