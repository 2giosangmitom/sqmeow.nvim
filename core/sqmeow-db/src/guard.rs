//! Telling statements that destroy or write from statements that only read.

use crate::adapter::Dialect;
use crate::sql::first_word;

/// Words that write wherever they sit in a SQL or CQL statement.
const SQL_WRITES: &[&str] = &[
    "insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "revoke",
    "merge", "call", "copy",
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

/// What a statement destroys, said for a confirmation, or `None` when it destroys nothing.
pub fn danger(dialect: Dialect, statement: &str) -> Option<String> {
    match dialect {
        Dialect::Redis => {
            let word = first_word(statement);
            matches!(word.as_str(), "flushall" | "flushdb")
                .then(|| format!("{} empties the database", word.to_uppercase()))
        }
        Dialect::MongoDb => {
            let keys = mongo_keys(statement)?;
            let command = keys
                .into_iter()
                .find(|key| key == "drop" || key == "dropDatabase")?;
            Some(format!("{command} removes everything it names"))
        }
        _ => {
            let words = words(dialect, statement);
            let (first, _) = words.first()?;
            match first.as_str() {
                "drop" | "truncate" => Some(format!("{} cannot be undone", first.to_uppercase())),
                "delete" | "update"
                    if !words
                        .iter()
                        .any(|(word, depth)| *depth == 0 && word == "where") =>
                {
                    Some(format!(
                        "{} without WHERE changes every row",
                        first.to_uppercase()
                    ))
                }
                _ => None,
            }
        }
    }
}

/// Whether a statement may change data or schema, for a connection opened read-only.
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

/// The top-level keys of a MongoDB command.
fn mongo_keys(statement: &str) -> Option<Vec<String>> {
    serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(statement)
        .ok()
        .map(|command| command.into_iter().map(|(key, _)| key).collect())
}

/// The words of a statement outside quotes and comments, in lower case, each with how deep in
/// parentheses it sits.
fn words(dialect: Dialect, statement: &str) -> Vec<(String, usize)> {
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
            // A doubled quote ends one run and starts the next, which reads the same.
            '\'' | '"' | '`' => {
                for next in chars.by_ref() {
                    if next == character {
                        break;
                    }
                }
            }
            '-' if chars.peek() == Some(&'-') => skip_line(&mut chars),
            '#' if dialect == Dialect::MySql => skip_line(&mut chars),
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
    }
}
