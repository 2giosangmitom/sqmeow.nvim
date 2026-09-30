//! Detects destructive and write statements.

use crate::adapter::Dialect;
use crate::sql::first_word;

/// Words that write wherever they sit in a SQL or CQL statement.
const SQL_WRITES: &[&str] = &[
    "insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "revoke",
    "merge", "call", "copy",
];

/// Words that write wherever they sit in a SurrealQL statement. `fn` is a user-defined function,
/// which may write.
const SURREAL_WRITES: &[&str] = &[
    "create", "update", "upsert", "delete", "insert", "relate", "remove", "define", "alter",
    "kill", "rebuild", "fn",
];

/// Redis commands that only read.
const REDIS_READS: &[&str] = &[
    "get",
    "mget",
    "getrange",
    "strlen",
    "exists",
    "type",
    "ttl",
    "pttl",
    "keys",
    "scan",
    "dbsize",
    "info",
    "ping",
    "echo",
    "time",
    "select",
    "object",
    "memory",
    "hget",
    "hmget",
    "hgetall",
    "hkeys",
    "hvals",
    "hlen",
    "hexists",
    "hstrlen",
    "hscan",
    "lrange",
    "llen",
    "lindex",
    "lpos",
    "smembers",
    "scard",
    "sismember",
    "smismember",
    "srandmember",
    "sscan",
    "sinter",
    "sunion",
    "sdiff",
    "zrange",
    "zrangebyscore",
    "zrevrange",
    "zrevrangebyscore",
    "zcard",
    "zscore",
    "zrank",
    "zrevrank",
    "zcount",
    "zscan",
    "xrange",
    "xrevrange",
    "xlen",
    "xinfo",
];

/// MongoDB commands that only read.
const MONGO_READS: &[&str] = &[
    "find",
    "aggregate",
    "count",
    "distinct",
    "listCollections",
    "listDatabases",
    "listIndexes",
    "dbStats",
    "collStats",
    "ping",
    "buildInfo",
    "serverStatus",
    "hello",
    "isMaster",
    "explain",
];

/// Returns a description of what `statement` would destroy, if anything.
///
/// Used to prompt for confirmation before destructive statements. This is a conservative
/// lexical heuristic, not a database authorization boundary: dialect grammar and server-side
/// functions can make a statement's effects impossible to infer reliably from its text. Enforce
/// permissions at the database as well when statements are untrusted.
pub fn danger(dialect: Dialect, statement: &str) -> Option<String> {
    match dialect {
        Dialect::Redis => {
            let words: Vec<&str> = statement.split_whitespace().collect();
            let word = words.first()?.to_ascii_lowercase();
            match word.as_str() {
                "flushall" | "flushdb" => {
                    Some(format!("{} empties the database", word.to_uppercase()))
                }
                "del" | "unlink" if words.len() > 2 => Some(format!(
                    "{} removes {} keys",
                    word.to_uppercase(),
                    words.len() - 1
                )),
                _ => None,
            }
        }
        Dialect::MongoDb => mongo_danger(statement),
        Dialect::SurrealDb => surreal_danger(statement),
        Dialect::MsSql => {
            let tokens = words(dialect, statement);
            for (at, (word, depth)) in tokens.iter().enumerate() {
                if matches!(word.as_str(), "drop" | "truncate") {
                    return Some(format!("{} cannot be undone", word.to_uppercase()));
                }
                if matches!(word.as_str(), "update" | "delete") {
                    let end = tokens[at + 1..]
                        .iter()
                        .position(|(w, d)| {
                            d <= depth
                                && matches!(
                                    w.as_str(),
                                    "select"
                                        | "insert"
                                        | "update"
                                        | "delete"
                                        | "merge"
                                        | "exec"
                                        | "execute"
                                )
                        })
                        .map_or(tokens.len(), |i| at + 1 + i);
                    if !narrows(&tokens[at..end]) {
                        return Some(format!(
                            "{} without WHERE changes every row",
                            word.to_uppercase()
                        ));
                    }
                }
            }
            None
        }
        _ => {
            let words = words(dialect, statement);
            // The verb a CTE leads up to, or the first one.
            let verb = words.iter().position(|(word, depth)| {
                *depth == 0
                    && matches!(
                        word.as_str(),
                        "select"
                            | "insert"
                            | "update"
                            | "delete"
                            | "drop"
                            | "truncate"
                            | "merge"
                            | "alter"
                            | "create"
                            | "replace"
                    )
            })?;
            let first = words[verb].0.as_str();
            match first {
                "drop" | "truncate" => Some(format!("{} cannot be undone", first.to_uppercase())),
                "delete" | "update" if !narrows(&words[verb..]) => Some(format!(
                    "{} without WHERE changes every row",
                    first.to_uppercase()
                )),
                _ => None,
            }
        }
    }
}

/// Returns whether `statement` may change data or schema.
///
/// Used to block writes on read-only connections when the backend cannot enforce a read-only
/// session. Unknown command forms are treated as writes. The scanner is intentionally
/// conservative, but it cannot replace database credentials that lack write privileges.
pub fn writes(dialect: Dialect, statement: &str) -> bool {
    match dialect {
        Dialect::Redis => !REDIS_READS.contains(&first_word(statement).as_str()),
        Dialect::MongoDb => {
            if first_word(statement) == "use" {
                return false;
            }
            let Some(keys) = mongo_keys(statement) else {
                return true;
            };
            let reads = keys.iter().any(|key| MONGO_READS.contains(&key.as_str()));
            // An aggregation writes through these stages.
            !reads || statement.contains("\"$out\"") || statement.contains("\"$merge\"")
        }
        Dialect::SurrealDb => {
            let words = words(dialect, statement);
            let reads = words.first().is_some_and(|(first, _)| {
                matches!(
                    first.as_str(),
                    "select" | "info" | "show" | "use" | "return" | "let" | "explain"
                )
            });
            !reads
                || words
                    .iter()
                    .any(|(word, _)| SURREAL_WRITES.contains(&word.as_str()))
        }
        Dialect::MsSql => {
            let tokens = words(dialect, statement);
            !tokens
                .first()
                .is_some_and(|(word, _)| matches!(word.as_str(), "select" | "with"))
                || tokens.iter().any(|(word, _)| {
                    SQL_WRITES.contains(&word.as_str())
                        || matches!(
                            word.as_str(),
                            "into"
                                | "exec"
                                | "execute"
                                | "set"
                                | "use"
                                | "dbcc"
                                | "backup"
                                | "restore"
                                | "bulk"
                                | "reconfigure"
                        )
                })
        }
        _ => {
            let words = words(dialect, statement);
            let reads = words.first().is_some_and(|(first, _)| {
                matches!(
                    first.as_str(),
                    "select"
                        | "with"
                        | "explain"
                        | "show"
                        | "table"
                        | "values"
                        | "describe"
                        | "desc"
                )
            });
            // `EXPLAIN ANALYZE` runs what it explains, and a CTE can delete.
            !reads
                || words
                    .iter()
                    .any(|(word, _)| SQL_WRITES.contains(&word.as_str()))
        }
    }
}

/// Whether a top-level `WHERE` narrows the rows, rather than being missing or always true.
fn narrows(words: &[(String, usize)]) -> bool {
    let Some(at) = words
        .iter()
        .position(|(word, depth)| *depth == 0 && word == "where")
    else {
        return false;
    };
    !words[at + 1..]
        .iter()
        .take_while(|(word, _)| !matches!(word.as_str(), "order" | "limit" | "returning"))
        .all(|(word, _)| word == "true" || word.chars().all(|c| c.is_ascii_digit()))
}

/// What a SurrealQL statement destroys: a `REMOVE`, or a whole table's records changed.
fn surreal_danger(statement: &str) -> Option<String> {
    let words = words(Dialect::SurrealDb, statement);
    let verb = words.iter().position(|(word, depth)| {
        *depth == 0 && matches!(word.as_str(), "delete" | "update" | "upsert" | "remove")
    })?;
    let first = words[verb].0.as_str();
    if first == "remove" {
        return Some("REMOVE cannot be undone".to_owned());
    }
    if narrows(&words[verb..]) {
        return None;
    }
    // `DELETE person:1` names one record, where `DELETE person` names every one.
    let target = statement
        .split_whitespace()
        .skip_while(|word| !word.eq_ignore_ascii_case(first))
        .skip(1)
        .find(|word| !word.eq_ignore_ascii_case("only") && !word.eq_ignore_ascii_case("from"))?;
    if target.contains(':') {
        return None;
    }
    Some(format!(
        "{} without WHERE changes every record",
        first.to_uppercase()
    ))
}

/// What a MongoDB command destroys: a drop, or a delete or multiple update with an empty filter.
fn mongo_danger(statement: &str) -> Option<String> {
    use serde_json::Value;

    let command = serde_json::from_str::<serde_json::Map<String, Value>>(statement).ok()?;
    if let Some(key) = command
        .keys()
        .find(|key| matches!(key.as_str(), "drop" | "dropDatabase" | "dropIndexes"))
    {
        return Some(format!("{key} removes everything it names"));
    }
    let unfiltered = |list: &str, every: fn(&Value) -> bool| {
        command
            .get(list)
            .and_then(Value::as_array)
            .is_some_and(|items| {
                items.iter().any(|item| {
                    item.get("q")
                        .and_then(Value::as_object)
                        .is_none_or(serde_json::Map::is_empty)
                        && every(item)
                })
            })
    };
    if unfiltered("deletes", |item| {
        item.get("limit").and_then(Value::as_i64) != Some(1)
    }) {
        return Some("a delete with an empty filter removes every document".to_owned());
    }
    if unfiltered("updates", |item| {
        item.get("multi").and_then(Value::as_bool) == Some(true)
    }) {
        return Some("an update with an empty filter changes every document".to_owned());
    }
    None
}

/// The top-level keys of a MongoDB command.
fn mongo_keys(statement: &str) -> Option<Vec<String>> {
    serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(statement)
        .ok()
        .map(|command| command.into_iter().map(|(key, _)| key).collect())
}

/// The words of a statement outside quotes and comments, in lower case, each with how deep in
/// parentheses it sits.
///
/// This lightweight tokenizer exists for safety checks and query-shape decisions, not to validate
/// SQL syntax. It preserves neither punctuation nor source positions; consumers should not use it
/// to rewrite a statement.
pub fn words(dialect: Dialect, statement: &str) -> Vec<(String, usize)> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut depth = 0usize;
    let mut chars = statement.chars().peekable();

    while let Some(character) = chars.next() {
        if character.is_alphanumeric() || character == '_' {
            word.extend(character.to_lowercase());
            continue;
        }
        if !word.is_empty() {
            words.push((std::mem::take(&mut word), depth));
        }
        match character {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            '[' if dialect == Dialect::MsSql => {
                while let Some(next) = chars.next() {
                    if next == ']' {
                        if chars.peek() == Some(&']') {
                            chars.next();
                        } else {
                            break;
                        }
                    }
                }
            }
            // A doubled quote ends one run and starts the next, which reads the same.
            '\'' | '"' | '`' => {
                while let Some(next) = chars.next() {
                    // SurrealQL and ClickHouse escape a quote with a backslash.
                    if next == '\\' && matches!(dialect, Dialect::SurrealDb | Dialect::ClickHouse) {
                        chars.next();
                        continue;
                    }
                    if next == character {
                        break;
                    }
                }
            }
            '⟨' if dialect == Dialect::SurrealDb => {
                for next in chars.by_ref() {
                    if next == '⟩' {
                        break;
                    }
                }
            }
            '-' if chars.peek() == Some(&'-') => skip_line(&mut chars),
            '#' if matches!(dialect, Dialect::MySql | Dialect::SurrealDb) => skip_line(&mut chars),
            '/' if dialect == Dialect::SurrealDb && chars.peek() == Some(&'/') => {
                skip_line(&mut chars);
            }
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut star = false;
                for next in chars.by_ref() {
                    if star && next == '/' {
                        break;
                    }
                    star = next == '*';
                }
            }
            _ => {}
        }
    }
    if !word.is_empty() {
        words.push((word, depth));
    }
    words
}

fn skip_line(chars: &mut impl Iterator<Item = char>) {
    for next in chars {
        if next == '\n' {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mssql_checks_every_statement_in_a_batch() {
        let dialect = Dialect::MsSql;
        assert!(!writes(
            dialect,
            "SELECT [drop], N'EXEC delete' FROM [odd]]name]"
        ));
        assert!(writes(dialect, "SELECT * INTO new_table FROM old_table"));
        assert!(writes(dialect, "SELECT 1; EXEC sp_test"));
        assert!(writes(dialect, "SELECT 1; DELETE FROM t"));
        assert!(danger(dialect, "SELECT 1; DELETE FROM t").is_some());
        assert!(danger(dialect, "SELECT 1; DROP TABLE t").is_some());
        assert!(danger(dialect, "DELETE FROM t; SELECT 1 WHERE 1=2").is_some());
        assert!(danger(dialect, "UPDATE t SET n=2 WHERE id=1").is_none());
    }

    #[test]
    fn a_whole_table_change_or_a_drop_is_dangerous() {
        let pg = Dialect::Postgres;
        assert!(danger(pg, "delete from t").is_some());
        assert!(danger(pg, "DELETE FROM t WHERE id = 1").is_none());
        assert!(danger(pg, "update t set a = (select b from u where u.id = 1)").is_some());
        assert!(danger(pg, "update t set note = 'no where' where id = 2").is_none());
        assert!(danger(pg, "-- clean up\ndrop table t").is_some());
        assert!(danger(pg, "truncate t").is_some());
        assert!(danger(pg, "select * from t").is_none());
        assert!(danger(Dialect::Redis, "FLUSHALL").is_some());
        assert!(danger(Dialect::MongoDb, r#"{"drop": "users"}"#).is_some());
        assert!(danger(Dialect::MongoDb, r#"{"find": "drop"}"#).is_none());

        let surreal = Dialect::SurrealDb;
        assert!(danger(surreal, "DELETE person").is_some());
        assert!(danger(surreal, "UPDATE person SET a = 1").is_some());
        assert!(danger(surreal, "REMOVE TABLE person").is_some());
        assert!(danger(surreal, "DELETE person:alice").is_none());
        assert!(danger(surreal, "UPDATE ONLY person:1 SET a = 1").is_none());
        assert!(danger(surreal, "DELETE person WHERE age < 3").is_none());
        assert!(danger(surreal, "SELECT * FROM person").is_none());
    }

    #[test]
    fn a_hidden_or_always_true_whole_table_change_is_dangerous() {
        let pg = Dialect::Postgres;
        assert!(danger(pg, "with old as (select 1) delete from t").is_some());
        assert!(danger(pg, "delete from t where 1 = 1").is_some());
        assert!(danger(pg, "update t set a = 1 where true returning *").is_some());
        assert!(
            danger(
                pg,
                "with x as (delete from t where id = 1 returning *) select * from x"
            )
            .is_none()
        );
        assert!(danger(pg, "insert into t select * from u").is_none());
        assert!(danger(pg, "alter table t drop column a").is_none());

        assert!(danger(Dialect::Redis, "DEL a b").is_some());
        assert!(danger(Dialect::Redis, "DEL a").is_none());

        let mongo = Dialect::MongoDb;
        assert!(
            danger(
                mongo,
                r#"{"delete": "u", "deletes": [{"q": {}, "limit": 0}]}"#
            )
            .is_some()
        );
        assert!(danger(mongo, r#"{"delete": "u", "deletes": [{"q": {"_id": 1}}]}"#).is_none());
        assert!(
            danger(
                mongo,
                r#"{"delete": "u", "deletes": [{"q": {}, "limit": 1}]}"#
            )
            .is_none()
        );
        assert!(
            danger(
                mongo,
                r#"{"update": "u", "updates": [{"q": {}, "u": {"$set": {"a": 1}}, "multi": true}]}"#
            )
            .is_some()
        );
        assert!(danger(mongo, r#"{"dropIndexes": "u", "index": "*"}"#).is_some());
    }

    #[test]
    fn only_reads_pass_a_read_only_connection() {
        let pg = Dialect::Postgres;
        for sql in [
            "select * from t",
            "with x as (select 1) select * from x",
            "explain select 1",
            "select 'drop table t'",
            "/* delete */ select 1",
        ] {
            assert!(!writes(pg, sql), "{sql}");
        }
        for sql in [
            "insert into t values (1)",
            "explain analyze delete from t",
            "with gone as (delete from t returning *) select * from gone",
            "pragma journal_mode = wal",
        ] {
            assert!(writes(pg, sql), "{sql}");
        }

        assert!(!writes(Dialect::Redis, "HGETALL user:1"));
        assert!(writes(Dialect::Redis, "SET a 1"));
        assert!(!writes(Dialect::MongoDb, "use shop"));
        assert!(!writes(
            Dialect::MongoDb,
            r#"{"find": "users", "filter": {}}"#
        ));
        assert!(writes(
            Dialect::MongoDb,
            r#"{"aggregate": "users", "pipeline": [{"$out": "copy"}]}"#
        ));
        assert!(writes(
            Dialect::MongoDb,
            r#"{"delete": "users", "deletes": []}"#
        ));

        let surreal = Dialect::SurrealDb;
        for sql in [
            "SELECT * FROM person",
            "INFO FOR DB",
            "USE DB other",
            "SELECT * FROM person WHERE note = 'it\\'s DELETE'",
            "SELECT * FROM ⟨delete⟩",
        ] {
            assert!(!writes(surreal, sql), "{sql}");
        }
        for sql in [
            "CREATE person",
            "LET $x = (DELETE person:1)",
            "SELECT fn::cleanup() FROM ONLY 1",
            "RELATE person:1->knows->person:2",
            "BEGIN TRANSACTION; SELECT * FROM a; COMMIT TRANSACTION",
        ] {
            assert!(writes(surreal, sql), "{sql}");
        }

        let clickhouse = Dialect::ClickHouse;
        for sql in [
            "SELECT 'it\\'s DELETE'",
            "SELECT \"a\\\" DROP TABLE users\"",
            "SELECT `a\\` TRUNCATE TABLE users`",
        ] {
            assert!(!writes(clickhouse, sql), "{sql}");
        }
    }
}
