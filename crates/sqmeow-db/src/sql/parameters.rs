//! Named query parameters, discovered lexically and replaced only with native binds.

use std::collections::HashMap;

use sqlparser::dialect::{
    ClickHouseDialect, DuckDbDialect, GenericDialect, MsSqlDialect, MySqlDialect, OracleDialect,
    PostgreSqlDialect, SQLiteDialect,
};
use sqlparser::tokenizer::{Location, Token, TokenWithSpan, Tokenizer, Whitespace};

use crate::adapter::Dialect;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Auto,
    Text,
    Int,
    Float,
    Bool,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Auto => "auto",
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
            kind: Kind::Auto,
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
    if matches!(dialect, Dialect::Redis | Dialect::MongoDb) {
        let mut bound = Bound {
            sql: sql.to_owned(),
            values: Vec::new(),
        };
        let mut names = Vec::new();
        for (_, _, name) in occurrences {
            if names.contains(&name) {
                continue;
            }
            let parameter = parameters
                .iter()
                .find(|parameter| parameter.name == name)
                .ok_or_else(|| format!("Unknown parameter: {name}"))?;
            let raw = values
                .get(&name)
                .or(parameter.default.as_ref())
                .ok_or_else(|| format!("Missing value for parameter: {name}"))?;
            let value = parse(parameter, raw)?;
            if dialect == Dialect::Redis && matches!(value, Value::Null(_)) {
                return Err(format!("Redis command arguments cannot be NULL: {name}"));
            }
            bound.values.push(value);
            names.push(name);
        }
        return Ok(bound);
    }
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
        match dialect {
            Dialect::Postgres => bound.sql.push_str(&format!("${index}")),
            Dialect::MsSql => bound.sql.push_str(&format!("@P{index}")),
            Dialect::Oracle => bound.sql.push_str(&format!(":{index}")),
            Dialect::SurrealDb => bound.sql.push_str(&format!("$sqmeow_p{index}")),
            Dialect::ClickHouse => {
                let (kind, nullable) = match &bound.values[index - 1] {
                    Value::Text(_) => ("String", false),
                    Value::Int(_) => ("Int64", false),
                    Value::Float(_) => ("Float64", false),
                    Value::Bool(_) => ("Bool", false),
                    Value::Null(kind) => (
                        match kind {
                            Kind::Auto | Kind::Text => "String",
                            Kind::Int => "Int64",
                            Kind::Float => "Float64",
                            Kind::Bool => "Bool",
                        },
                        true,
                    ),
                };
                let kind = if nullable {
                    format!("Nullable({kind})")
                } else {
                    kind.to_owned()
                };
                bound.sql.push_str(&format!("{{sqmeow_p{index}:{kind}}}"));
            }
            _ => {
                bound.sql.push('?');
                // Every question mark is a distinct positional bind.
                if repeated {
                    bound.values.push(bound.values[index - 1].clone());
                }
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
        return Ok(Value::Null(if parameter.kind == Kind::Auto {
            Kind::Text
        } else {
            parameter.kind
        }));
    }
    let invalid = || {
        format!(
            "Invalid {} value for parameter: {}",
            parameter.kind.name(),
            parameter.name
        )
    };
    match parameter.kind {
        Kind::Auto => {
            if trimmed.starts_with('"') {
                return serde_json::from_str::<String>(trimmed)
                    .map(Value::Text)
                    .map_err(|_| invalid());
            }
            if trimmed == "true" || trimmed == "false" {
                return Ok(Value::Bool(trimmed == "true"));
            }
            if let Ok(value) = trimmed.parse::<i64>() {
                return Ok(Value::Int(value));
            }
            if trimmed.contains(['.', 'e', 'E'])
                && let Ok(value) = trimmed.parse::<f64>()
                && value.is_finite()
            {
                return Ok(Value::Float(value));
            }
            Ok(Value::Text(raw.to_owned()))
        }
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
        Dialect::DuckDb => &DuckDbDialect {},
        Dialect::MsSql => &MsSqlDialect {},
        Dialect::ClickHouse => &ClickHouseDialect {},
        Dialect::Oracle => &OracleDialect {},
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

/// Native document/command adapters receive the original source and typed named inputs.
pub fn named_values(
    dialect: Dialect,
    source: &str,
    values: &[Value],
) -> Result<HashMap<String, Value>, String> {
    let mut names = Vec::new();
    for (_, _, name) in discover(dialect, source)? {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    if names.len() != values.len() {
        return Err("parameter count does not match the command".into());
    }
    Ok(names.into_iter().zip(values.iter().cloned()).collect())
}

/// Raw Redis argument spans. Quoted words remain literals, including quoted ':name'.
pub fn redis_tokens(source: &str) -> Result<Vec<(usize, usize)>, String> {
    let mut chars = source.char_indices().peekable();
    let mut spans = Vec::new();
    while let Some((start, first)) = chars.next() {
        if first.is_whitespace() {
            continue;
        }
        if first == '\'' || first == '"' {
            let mut closed = false;
            while let Some((_, character)) = chars.next() {
                if character == '\\' {
                    chars.next().ok_or("unbalanced quotes")?;
                } else if character == first {
                    closed = true;
                    break;
                }
            }
            if !closed {
                return Err("unbalanced quotes".into());
            }
            if chars
                .peek()
                .is_some_and(|(_, character)| !character.is_whitespace())
            {
                return Err("a closing quote must be followed by a space".into());
            }
        } else {
            while chars
                .peek()
                .is_some_and(|(_, character)| !character.is_whitespace())
            {
                chars.next();
            }
        }
        let end = chars.peek().map_or(source.len(), |(offset, _)| *offset);
        spans.push((start, end));
    }
    Ok(spans)
}

fn mongo_names(
    value: &serde_json::Value,
    names: &mut Vec<String>,
    root: bool,
) -> Result<(), String> {
    match value {
        serde_json::Value::String(value) => {
            if let Some(name) = value.strip_prefix(':').filter(|name| valid_name(name)) {
                names.push(name.to_owned());
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                mongo_names(value, names, false)?;
            }
        }
        serde_json::Value::Object(fields) => {
            for (key, value) in fields {
                if key.starts_with(':') && valid_name(&key[1..]) {
                    return Err("MongoDB field names cannot be parameters".into());
                }
                let before = names.len();
                mongo_names(value, names, false)?;
                if root
                    && names.len() != before
                    && !matches!(
                        key.as_str(),
                        "filter"
                            | "query"
                            | "pipeline"
                            | "documents"
                            | "updates"
                            | "deletes"
                            | "comment"
                            | "projection"
                            | "sort"
                            | "let"
                            | "hint"
                            | "arrayFilters"
                            | "limit"
                            | "skip"
                            | "batchSize"
                            | "maxTimeMS"
                    )
                {
                    return Err(
                        "MongoDB command/database/collection names cannot be parameters".into(),
                    );
                }
            }
        }
        _ => {}
    }
    Ok(())
}

/// Expression operands need explicit $literal protection; identifiers and code never bind.
fn mongo_context(
    value: &serde_json::Value,
    expression: bool,
    forbidden: bool,
    pipeline: bool,
    lookup: bool,
) -> Result<(), String> {
    match value {
        serde_json::Value::String(text) if text.strip_prefix(':').is_some_and(valid_name) => {
            if forbidden {
                return Err("MongoDB identifiers and executable code cannot be parameters".into());
            }
            if expression {
                return Err("MongoDB expression parameters must be wrapped in $literal".into());
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                mongo_context(value, expression, forbidden, pipeline, lookup)?;
            }
        }
        serde_json::Value::Object(fields) => {
            for (key, value) in fields {
                let structural = forbidden
                    || matches!(
                        key.as_str(),
                        "$where"
                            | "$function"
                            | "$accumulator"
                            | "$getField"
                            | "$setField"
                            | "$regularExpression"
                            | "$date"
                            | "$numberInt"
                            | "$numberLong"
                            | "$numberDouble"
                            | "$numberDecimal"
                            | "$oid"
                            | "$binary"
                            | "$uuid"
                            | "$code"
                            | "$scope"
                            | "$symbol"
                            | "$timestamp"
                            | "$dbPointer"
                    )
                    || pipeline
                        && matches!(
                            key.as_str(),
                            "$out"
                                | "$merge"
                                | "$unset"
                                | "$unionWith"
                                | "$unwind"
                                | "$search"
                                | "$searchMeta"
                                | "$vectorSearch"
                                | "$geoNear"
                                | "$densify"
                        )
                    || lookup
                        && matches!(
                            key.as_str(),
                            "from"
                                | "localField"
                                | "foreignField"
                                | "as"
                                | "connectFromField"
                                | "connectToField"
                        );
                let expression = if key == "$literal" || key == "$match" {
                    false
                } else {
                    expression
                        || matches!(key.as_str(), "$expr" | "projection" | "let")
                        || pipeline
                            && matches!(
                                key.as_str(),
                                "$project"
                                    | "$addFields"
                                    | "$set"
                                    | "$group"
                                    | "$replaceRoot"
                                    | "$replaceWith"
                                    | "$redact"
                                    | "$bucket"
                                    | "$bucketAuto"
                                    | "$sortByCount"
                                    | "$setWindowFields"
                            )
                        || lookup && matches!(key.as_str(), "let" | "startWith")
                };
                mongo_context(
                    value,
                    expression,
                    structural,
                    key == "pipeline"
                        || key == "$facet"
                        || key == "u" && value.is_array()
                        || pipeline,
                    key == "$lookup" || key == "$graphLookup",
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn discover(dialect: Dialect, sql: &str) -> Result<Vec<(usize, usize, String)>, String> {
    if dialect == Dialect::SurrealDb {
        return surreal_occurrences(sql);
    }
    if dialect == Dialect::Redis {
        let spans = redis_tokens(sql)?;
        let has_parameters = spans
            .iter()
            .any(|(start, end)| sql[*start..*end].strip_prefix(':').is_some_and(valid_name));
        let command = spans
            .first()
            .map(|(start, end)| sql[*start..*end].to_ascii_uppercase())
            .unwrap_or_default();
        let subcommand = spans
            .get(1)
            .map(|(start, end)| sql[*start..*end].to_ascii_uppercase())
            .unwrap_or_default();
        if has_parameters
            && !command
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
        {
            return Err("Parameterized Redis commands require a literal command name".into());
        }
        return spans
            .into_iter()
            .enumerate()
            .filter_map(|(index, (start, end))| {
                let name = sql[start..end]
                    .strip_prefix(':')
                    .filter(|name| valid_name(name))?;
                Some(if index == 0 {
                    Err("The Redis command name cannot be a parameter".into())
                } else if index == 1 && matches!(command.as_str(), "EVAL" | "EVAL_RO")
                    || matches!(command.as_str(), "SCRIPT" | "FUNCTION")
                        && (index == 1 || subcommand == "LOAD")
                {
                    Err("Redis script bodies and script subcommands cannot be parameters".into())
                } else {
                    Ok((start, end, name.to_owned()))
                })
            })
            .collect();
    }
    if dialect == Dialect::MongoDb {
        let mut words = sql.split_whitespace();
        if words.next() == Some("use") {
            if words
                .next()
                .is_some_and(|name| name.strip_prefix(':').is_some_and(valid_name))
            {
                return Err("MongoDB database names cannot be parameters".into());
            }
            return Ok(Vec::new());
        }
        if !sql.contains(':') {
            return Ok(Vec::new());
        }
        let json: serde_json::Value =
            serde_json::from_str(sql).map_err(|error| error.to_string())?;
        mongo_context(&json, false, false, false, false)?;
        let mut names = Vec::new();
        mongo_names(&json, &mut names, true)?;
        return Ok(names.into_iter().map(|name| (0, 0, name)).collect());
    }
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
            Token::LBracket | Token::LParen | Token::LBrace => delimiters.push(token.token.clone()),
            Token::RBracket | Token::RParen | Token::RBrace => {
                delimiters.pop();
            }
            _ => {}
        }
        native |= matches!(token.token, Token::Placeholder(_))
            || dialect != Dialect::Postgres && matches!(token.token, Token::Question)
            || dialect == Dialect::Sqlite && matches!(token.token, Token::AtSign);
        if dialect == Dialect::MsSql
            && let Token::Word(word) = &token.token
            && word.quote_style.is_none()
        {
            let name = word.value.to_ascii_lowercase();
            native |= name.strip_prefix("@p").is_some_and(|suffix| {
                !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit())
            });
        }
        if dialect == Dialect::MsSql
            && token.token == Token::AtSign
            && let Some(TokenWithSpan {
                token: Token::Word(word),
                ..
            }) = tokens.get(index + 1)
        {
            let name = word.value.to_ascii_lowercase();
            native |= name.strip_prefix('p').is_some_and(|suffix| {
                !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit())
            });
        }
        if token.token != Token::Colon {
            continue;
        }
        if dialect == Dialect::Oracle
            && tokens
                .get(index + 1)
                .is_some_and(|next| matches!(next.token, Token::Number(_, _)))
        {
            native = true;
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
        if matches!(dialect, Dialect::DuckDb | Dialect::ClickHouse)
            && delimiters.last() == Some(&Token::LBrace)
        {
            let previous = tokens[..index]
                .iter()
                .rev()
                .find(|token| !matches!(token.token, Token::Whitespace(_)));
            if previous.is_some_and(|token| {
                matches!(
                    token.token,
                    Token::SingleQuotedString(_) | Token::Word(_) | Token::Number(_, _)
                )
            }) {
                native |= dialect == Dialect::ClickHouse;
                continue;
            }
        }
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
    if !occurrences.is_empty() && native {
        return Err("Cannot mix named parameters and native positional binds".to_owned());
    }
    Ok(occurrences)
}

fn surreal_occurrences(sql: &str) -> Result<Vec<(usize, usize, String)>, String> {
    let mut chars = sql.char_indices().peekable();
    let mut occurrences = Vec::new();
    let mut objects = 0usize;
    let mut previous = None;
    let mut collision = false;
    while let Some((offset, character)) = chars.next() {
        if character.is_whitespace() {
            continue;
        }
        if character == '\'' || character == '"' || character == '`' || character == '⟨' {
            let close = if character == '⟨' { '⟩' } else { character };
            let mut closed = false;
            while let Some((_, next)) = chars.next() {
                if next == '\\' {
                    chars.next();
                } else if next == close {
                    closed = true;
                    break;
                }
            }
            if !closed {
                return Err("unterminated SurrealQL string or identifier".into());
            }
            previous = Some(close);
            continue;
        }
        if (character == '-' && chars.peek().is_some_and(|(_, c)| *c == '-'))
            || (character == '/' && chars.peek().is_some_and(|(_, c)| *c == '/'))
        {
            for (_, next) in chars.by_ref() {
                if next == '\n' {
                    break;
                }
            }
            continue;
        }
        if character == '/' && chars.peek().is_some_and(|(_, c)| *c == '*') {
            chars.next();
            let mut depth = 1;
            while let Some((_, next)) = chars.next() {
                if next == '/' && chars.peek().is_some_and(|(_, c)| *c == '*') {
                    chars.next();
                    depth += 1;
                } else if next == '*' && chars.peek().is_some_and(|(_, c)| *c == '/') {
                    chars.next();
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
            }
            if depth != 0 {
                return Err("unterminated SurrealQL comment".into());
            }
            continue;
        }
        if character == '$'
            && let Some(rest) = sql[offset..].strip_prefix("$sqmeow_p")
        {
            let suffix = rest
                .split(|c: char| !c.is_alphanumeric() && c != '_')
                .next()
                .unwrap_or_default();
            collision |= !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit());
        }
        if character == '{' {
            objects += 1;
        }
        if character == '}' {
            objects = objects.saturating_sub(1);
        }
        if character == ':' {
            if chars.peek().is_some_and(|(_, c)| *c == ':') {
                chars.next();
                previous = Some(':');
                continue;
            }
            let adjacent = sql[..offset].chars().next_back();
            let identifier =
                |c: char| c.is_alphanumeric() || matches!(c, '_' | '`' | '⟩' | '\'' | '"');
            if !adjacent.is_some_and(identifier)
                && !(objects > 0 && previous.is_some_and(identifier))
            {
                let end = sql[offset + 1..]
                    .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                    .map_or(sql.len(), |end| offset + 1 + end);
                let name = &sql[offset + 1..end];
                if valid_name(name)
                    && sql[end..]
                        .chars()
                        .next()
                        .is_none_or(|c| !c.is_alphanumeric() && c != '_')
                {
                    occurrences.push((offset, end, name.to_owned()));
                }
            }
        }
        previous = Some(character);
    }
    if collision && !occurrences.is_empty() {
        return Err("Native $sqmeow_p variables conflict with generated parameter bindings".into());
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
        assert_eq!(parameters[0].kind, Kind::Auto);
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
    fn oracle_alternative_quotes_do_not_discover_parameters() {
        let sql = "SELECT q'[O'Brien :hidden]', q'{-- @param fake int :ignored}', :value FROM dual";
        let parameters = describe(Dialect::Oracle, sql, &[sql]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(parameters[0].name, "value");
        assert_eq!(
            compile(
                Dialect::Oracle,
                sql,
                &parameters,
                &values(&[("value", "42")])
            )
            .unwrap()
            .sql,
            sql.replace(":value", ":1")
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
        assert_eq!(
            describe(Dialect::DuckDb, "SELECT :x", &["SELECT :x"])
                .unwrap()
                .len(),
            1
        );
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
            (Dialect::MongoDb, "use analytics:dev"),
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

    #[test]
    fn automatic_inputs_remain_typed_and_can_force_text() {
        let sql = "SELECT :id, :ratio, :enabled, :text, :empty, :missing";
        let parameters = describe(Dialect::Sqlite, sql, &[sql]).unwrap();
        let bound = compile(
            Dialect::Sqlite,
            sql,
            &parameters,
            &values(&[
                ("id", "42"),
                ("ratio", "1.25"),
                ("enabled", "true"),
                ("text", "\"42\""),
                ("empty", ""),
                ("missing", "NULL"),
            ]),
        )
        .unwrap();
        assert_eq!(
            bound.values,
            vec![
                Value::Int(42),
                Value::Float(1.25),
                Value::Bool(true),
                Value::Text("42".into()),
                Value::Text("".into()),
                Value::Null(Kind::Text)
            ]
        );
    }

    #[test]
    fn each_adapter_uses_native_placeholder_syntax() {
        for (dialect, expected) in [
            (Dialect::DuckDb, "SELECT ?, ?, ?"),
            (Dialect::Scylla, "SELECT ?, ?, ?"),
            (Dialect::MsSql, "SELECT @P1, @P1, @P2"),
            (Dialect::Oracle, "SELECT :1, :1, :2"),
            (
                Dialect::SurrealDb,
                "SELECT $sqmeow_p1, $sqmeow_p1, $sqmeow_p2",
            ),
            (
                Dialect::ClickHouse,
                "SELECT {sqmeow_p1:Int64}, {sqmeow_p1:Int64}, {sqmeow_p2:String}",
            ),
        ] {
            let sql = "SELECT :x, :x, :y";
            let parameters = describe(dialect, sql, &[sql]).unwrap();
            let bound = compile(
                dialect,
                sql,
                &parameters,
                &values(&[("x", "42"), ("y", "text")]),
            )
            .unwrap();
            assert_eq!(bound.sql, expected, "{dialect:?}");
            assert_eq!(
                bound.values.len(),
                if matches!(dialect, Dialect::DuckDb | Dialect::Scylla) {
                    3
                } else {
                    2
                }
            );
        }
    }

    #[test]
    fn native_command_inputs_do_not_rewrite_source_or_literals() {
        for (dialect, sql) in [
            (
                Dialect::Redis,
                "HSET cache:user:1 value :x literal ':literal' repeated :x",
            ),
            (
                Dialect::MongoDb,
                r#"{"find":"users","filter":{"name":":x","nested":[":x", "not :literal"]}}"#,
            ),
        ] {
            let parameters = describe(dialect, sql, &[sql]).unwrap();
            assert_eq!(parameters.len(), 1);
            assert_eq!(parameters[0].name, "x");
            let bound = compile(
                dialect,
                sql,
                &parameters,
                &values(&[("x", "\"Alice' \\n DROP TABLE t\"")]),
            )
            .unwrap();
            assert_eq!(bound.sql, sql);
            assert_eq!(bound.values.len(), 1);
            assert_eq!(named_values(dialect, sql, &bound.values).unwrap().len(), 1);
        }
        assert!(describe(Dialect::Redis, ":command key", &[":command key"]).is_err());
        for sql in [
            "EVAL :script 0",
            "SCRIPT LOAD :script",
            "FUNCTION LOAD REPLACE :script",
        ] {
            assert!(describe(Dialect::Redis, sql, &[sql]).is_err());
        }
        let sql = r#"{"find":":collection","filter":{}}"#;
        assert!(describe(Dialect::MongoDb, sql, &[sql]).is_err());
    }

    #[test]
    fn surreal_record_ids_objects_variables_and_quotes_are_preserved() {
        let sql = "RETURN {record: person:alice, quoted: person:⟨odd name⟩, flag :true, input: :input, message: \"escaped \\\" :hidden\", variable: $event}; -- :comment\nRETURN fn::greet(:input);";
        let parameters = describe(Dialect::SurrealDb, sql, &[sql]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(parameters[0].name, "input");
        let bound = compile(
            Dialect::SurrealDb,
            sql,
            &parameters,
            &values(&[("input", "42")]),
        )
        .unwrap();
        assert_eq!(bound.sql, sql.replace(":input", "$sqmeow_p1"));
        assert_eq!(bound.values, vec![Value::Int(42)]);
        let collision = "RETURN $sqmeow_p1 + :x";
        assert!(describe(Dialect::SurrealDb, collision, &[collision]).is_err());
    }

    #[test]
    fn named_inputs_do_not_hide_writes_from_guards() {
        for dialect in [
            Dialect::Sqlite,
            Dialect::DuckDb,
            Dialect::Postgres,
            Dialect::MySql,
            Dialect::MsSql,
            Dialect::Oracle,
            Dialect::ClickHouse,
            Dialect::Scylla,
            Dialect::SurrealDb,
        ] {
            assert!(
                !crate::guard::writes(dialect, "SELECT * FROM users WHERE id = :id"),
                "{dialect:?}"
            );
            assert!(
                crate::guard::writes(dialect, "UPDATE users SET name = :name WHERE id = :id"),
                "{dialect:?}"
            );
        }
        assert!(!crate::guard::writes(Dialect::Redis, "HGET :key field"));
        assert!(crate::guard::writes(
            Dialect::Redis,
            "HSET :key field :value"
        ));
        assert!(!crate::guard::writes(
            Dialect::MongoDb,
            r#"{"find":"users","filter":{"_id":":id"}}"#
        ));
        assert!(crate::guard::writes(
            Dialect::MongoDb,
            r#"{"update":"users","updates":[{"q":{"_id":":id"},"u":{"$set":{"name":":name"}}}]}"#
        ));
    }

    #[test]
    fn native_variables_struct_fields_and_generated_names_do_not_collide() {
        let sql = "SELECT {'enabled':true, 'missing':NULL}, :x";
        let parameters = describe(Dialect::DuckDb, sql, &[sql]).unwrap();
        assert_eq!(parameters.len(), 1);
        assert_eq!(
            compile(Dialect::DuckDb, sql, &parameters, &values(&[("x", "7")]))
                .unwrap()
                .sql,
            "SELECT {'enabled':true, 'missing':NULL}, ?"
        );
        let sql = "SELECT :x, @@ROWCOUNT, @local";
        assert_eq!(describe(Dialect::MsSql, sql, &[sql]).unwrap().len(), 1);
        for (dialect, sql) in [
            (Dialect::MsSql, "SELECT @p1, :x"),
            (Dialect::ClickHouse, "SELECT {sqmeow_p1:Int64}, :x"),
            (Dialect::Oracle, "SELECT :1, :x FROM dual"),
        ] {
            assert!(describe(dialect, sql, &[sql]).is_err(), "{sql}");
        }
    }

    #[test]
    fn mongo_binds_only_data_not_identifiers_expressions_or_code() {
        for sql in [
            r#"{"aggregate":"users","pipeline":[{"$lookup":{"from":":collection","localField":"id","foreignField":"id","as":"joined"}}],"cursor":{}}"#,
            r#"{"aggregate":"users","pipeline":[{"$project":{"v":":value"}}],"cursor":{}}"#,
            r#"{"find":"users","filter":{"$where":":code"}}"#,
            r#"{"find":"users","projection":{"v":":value"}}"#,
            r#"{"find":"users","let":{"v":":value"}}"#,
            r#"{"find":"users","filter":{"name":{"$regularExpression":{"pattern":":pattern","options":""}}}}"#,
            r#"{"update":"users","updates":[{"q":{},"u":[{"$set":{"v":":value"}}]}]}"#,
            r#"{"aggregate":"users","pipeline":[{"$unionWith":":collection"}],"cursor":{}}"#,
            r#"{"aggregate":"users","pipeline":[{"$project":{"v":{"$getField":{"field":{"$literal":":field"},"input":"$$ROOT"}}}}],"cursor":{}}"#,
        ] {
            assert!(describe(Dialect::MongoDb, sql, &[sql]).is_err(), "{sql}");
        }
        let sql = r#"{"aggregate":"users","pipeline":[{"$project":{"v":{"$literal":":value"}}}],"cursor":{}}"#;
        let parameters = describe(Dialect::MongoDb, sql, &[sql]).unwrap();
        let bound = compile(
            Dialect::MongoDb,
            sql,
            &parameters,
            &values(&[("value", "$secret")]),
        )
        .unwrap();
        assert_eq!(bound.sql, sql);
        assert_eq!(bound.values, vec![Value::Text("$secret".into())]);
    }
}
