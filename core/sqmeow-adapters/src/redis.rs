//! The Redis and Valkey adapter.
//!
//! Redis has no tables and speaks no SQL, so it fits the adapter contract more loosely than the
//! others. A statement is one command line, split into words the way `redis-cli` splits them. A
//! reply is laid out as rows: a map is a row per field, an array a row per element, and anything
//! else a single row. The drawer's relations are the keys of the current database, grouped by the
//! type of value they hold.

use std::time::Instant;

use redis::aio::MultiplexedConnection;
use redis::{
    AsyncConnectionConfig, Client, Cmd, FromRedisValue, IntoConnectionInfo, ProtocolVersion, Value,
};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyType, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

/// The most keys the drawer lists from one database.
// ponytail: one capped SCAN walk; page through the keyspace if databases this large need browsing
const MAX_KEYS: usize = 10_000;

/// One connection to a Redis or Valkey server.
#[derive(Debug)]
pub struct RedisAdapter {
    connection: MultiplexedConnection,
    /// The database the URL chose, for a server too old to say which one is current.
    db: i64,
}

impl RedisAdapter {
    /// Open a connection.
    ///
    /// One connection rather than a pool, for the reason the SQL adapters hold one: a `SELECT` or a
    /// `MULTI` must still be in effect for the next command the user runs.
    pub async fn connect(url: &str) -> Result<Self> {
        let info = url.into_connection_info().map_err(Error::driver)?;
        let db = info.redis_settings().db();
        // RESP3, so a hash arrives as a map of fields and a score as a number, rather than as one
        // flat list of strings whose shape has to be guessed.
        let settings = info
            .redis_settings()
            .clone()
            .set_protocol(ProtocolVersion::RESP3);
        let client = Client::open(info.set_redis_settings(settings)).map_err(Error::driver)?;

        let config = AsyncConnectionConfig::new()
            .set_connection_timeout(Some(crate::CONNECT_TIMEOUT))
            // The driver gives up on a reply after half a second unless told otherwise, which would
            // report a slow `KEYS *` as a failure. Waiting is the user's call, and they can cancel.
            .set_response_timeout(None);
        let connection = client
            .get_multiplexed_async_connection_with_config(&config)
            .await
            .map_err(Error::driver)?;

        Ok(Self { connection, db })
    }

    async fn query<T: FromRedisValue>(&self, command: &Cmd) -> Result<T> {
        // A multiplexed connection is a handle onto one socket, so a clone is the same session.
        command
            .query_async(&mut self.connection.clone())
            .await
            .map_err(Error::driver)
    }
}

impl Adapter for RedisAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Redis
    }

    /// A key quoted so a command line reads it back as one word.
    fn quote_ident(&self, name: &str) -> String {
        quote(name)
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        let started = Instant::now();
        let words = split_command(statement).map_err(Error::Driver)?;
        if words.is_empty() {
            return Err(Error::driver("there is no command to run"));
        }

        let mut command = Cmd::new();
        for word in &words {
            command.arg(word.as_slice());
        }

        // Dropping the request leaves the connection usable: the multiplexer throws the reply away
        // when it comes. ponytail: a blocking command such as `BLPOP` still holds the session on
        // the server until it returns; send `CLIENT UNBLOCK` from a second connection if that bites.
        let reply = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(Error::Cancelled),
            reply = self.query::<Value>(&command) => reply?,
        };

        let mut result = to_result(statement, reply, max_rows);
        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    /// Only the database the connection is on.
    ///
    /// Listing another one's keys would mean switching the user's session under them, so browsing
    /// another database is `SELECT` followed by a refresh.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        // `CLIENT INFO` rather than the URL, so a `SELECT` the user ran is reflected. A server older
        // than 6.2 does not have it, and the URL's database is the best answer left.
        let info: String = self
            .query(redis::cmd("CLIENT").arg("INFO"))
            .await
            .unwrap_or_default();
        let db = current_db(&info).unwrap_or(self.db);

        Ok(vec![SchemaNode {
            name: format!("db{db}"),
            is_default: true,
        }])
    }

    /// The keys of the current database, each with the type of value it holds.
    ///
    /// The schema is not consulted: a connection has one current database, and it is the one the
    /// drawer listed.
    async fn relations(&self, _schema: &str) -> Result<Vec<RelationNode>> {
        let mut names: Vec<Vec<u8>> = Vec::new();
        let mut cursor = 0u64;
        loop {
            let (next, batch): (u64, Vec<Vec<u8>>) = self
                .query(redis::cmd("SCAN").cursor_arg(cursor).arg("COUNT").arg(1000))
                .await?;
            names.extend(batch);
            cursor = next;
            if cursor == 0 || names.len() >= MAX_KEYS {
                break;
            }
        }
        names.truncate(MAX_KEYS);
        // A scan may return a key twice while the server is resizing its table.
        names.sort_unstable();
        names.dedup();

        if names.is_empty() {
            return Ok(Vec::new());
        }

        // Every `TYPE` in one round trip, rather than one per key.
        let mut pipeline = redis::pipe();
        for name in &names {
            pipeline.cmd("TYPE").arg(name.as_slice());
        }
        let types: Vec<String> = pipeline
            .query_async(&mut self.connection.clone())
            .await
            .map_err(Error::driver)?;

        Ok(names
            .into_iter()
            .zip(types)
            .filter_map(|(name, kind)| {
                // A key that expired since the scan answers `none`, and a module's own type such as
                // `ReJSON-RL` has no group to go under.
                let kind = KeyType::from_redis(&kind)?;
                Some(RelationNode {
                    name: String::from_utf8_lossy(&name).into_owned(),
                    kind: RelationKind::Key(kind),
                })
            })
            .collect())
    }

    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(Vec::new())
    }

    /// A key has no columns. The drawer draws keys as leaves, so this is never asked for.
    async fn columns(&self, _schema: &str, _relation: &str) -> Result<Vec<ColumnNode>> {
        Ok(Vec::new())
    }

    /// Nothing to do: the socket closes once the last handle onto it is dropped.
    async fn close(&self) {}
}

/// The `db=` field of a `CLIENT INFO` line.
fn current_db(info: &str) -> Option<i64> {
    info.split_whitespace()
        .find_map(|field| field.strip_prefix("db=")?.parse().ok())
}

/// Quote a word so [`split_command`] reads it back unchanged.
fn quote(word: &str) -> String {
    let mut quoted = String::with_capacity(word.len() + 2);
    quoted.push('"');
    for character in word.chars() {
        match character {
            '"' | '\\' => {
                quoted.push('\\');
                quoted.push(character);
            }
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

/// Split a command line into words, the way `redis-cli` does.
///
/// Inside double quotes, `\n`, `\r`, `\t`, `\b`, `\a` and `\xHH` are escapes, and any other
/// character after a backslash stands for itself. Inside single quotes only `\'` is an escape. A
/// closing quote must end its word, so `"a"b` is reported as a mistake rather than guessed at.
fn split_command(line: &str) -> std::result::Result<Vec<Vec<u8>>, String> {
    let chars: Vec<char> = line.chars().collect();
    let mut words = Vec::new();
    let mut index = 0;

    loop {
        while chars.get(index).is_some_and(|c| c.is_whitespace()) {
            index += 1;
        }
        let Some(&first) = chars.get(index) else {
            return Ok(words);
        };

        let mut word = Vec::new();
        if first == '"' || first == '\'' {
            index += 1;
            loop {
                let Some(&character) = chars.get(index) else {
                    return Err("unbalanced quotes".to_owned());
                };
                index += 1;
                if character == first {
                    break;
                }
                if character != '\\' {
                    push_char(&mut word, character);
                    continue;
                }

                let Some(&escaped) = chars.get(index) else {
                    return Err("unbalanced quotes".to_owned());
                };
                index += 1;
                if first == '\'' {
                    if escaped != '\'' {
                        word.push(b'\\');
                    }
                    push_char(&mut word, escaped);
                    continue;
                }
                match escaped {
                    'n' => word.push(b'\n'),
                    'r' => word.push(b'\r'),
                    't' => word.push(b'\t'),
                    'b' => word.push(0x08),
                    'a' => word.push(0x07),
                    'x' => match hex_byte(chars.get(index..index + 2)) {
                        Some(byte) => {
                            word.push(byte);
                            index += 2;
                        }
                        None => word.push(b'x'),
                    },
                    other => push_char(&mut word, other),
                }
            }
            if chars.get(index).is_some_and(|c| !c.is_whitespace()) {
                return Err("a closing quote must be followed by a space".to_owned());
            }
        } else {
            while let Some(&character) = chars.get(index).filter(|c| !c.is_whitespace()) {
                push_char(&mut word, character);
                index += 1;
            }
        }
        words.push(word);
    }
}

fn push_char(word: &mut Vec<u8>, character: char) {
    word.extend_from_slice(character.encode_utf8(&mut [0; 4]).as_bytes());
}

fn hex_byte(digits: Option<&[char]>) -> Option<u8> {
    let &[high, low] = digits? else {
        return None;
    };
    u8::try_from(high.to_digit(16)? * 16 + low.to_digit(16)?).ok()
}

/// Lay a reply out as rows.
///
/// A map is a row per field and an array a row per element, with an element that is an array of
/// its own spread across columns: that is what puts `ZRANGE ... WITHSCORES` scores in a column
/// beside their members. Anything else is one row. The whole reply is in memory by now, so
/// `max_rows` limits what is kept rather than what is read.
fn to_result(statement: &str, reply: Value, max_rows: usize) -> ResultSet {
    let (names, rows): (Vec<String>, Vec<Vec<Cell>>) = match strip_attribute(reply) {
        Value::Map(pairs) => (
            vec!["field".to_owned(), "value".to_owned()],
            pairs
                .into_iter()
                .map(|(field, value)| vec![cell(field), cell(value)])
                .collect(),
        ),
        Value::Array(items) | Value::Set(items) | Value::Push { data: items, .. } => {
            let rows: Vec<Vec<Cell>> = items
                .into_iter()
                .map(|item| match strip_attribute(item) {
                    Value::Array(parts) => parts.into_iter().map(cell).collect(),
                    other => vec![cell(other)],
                })
                .collect();
            let width = rows.iter().map(Vec::len).max().unwrap_or(1);
            let names = if width <= 1 {
                vec!["value".to_owned()]
            } else {
                (1..=width).map(|position| position.to_string()).collect()
            };
            (names, rows)
        }
        other => (vec!["value".to_owned()], vec![vec![cell(other)]]),
    };

    let columns = names
        .into_iter()
        .enumerate()
        .map(|(index, name)| Column::new(name, common_type(&rows, index)))
        .collect();
    let mut result = ResultSet::new(statement, columns);

    for row in rows {
        if result.row_count() >= max_rows {
            result.mark_truncated();
            break;
        }
        result.push_row(row);
    }
    result
}

/// The type every value in a column shares, or nothing when they differ.
///
/// A reply carries no column types, so this is what gives the grid header an icon. Nulls are
/// skipped: a missing value says nothing about what the others hold.
fn common_type(rows: &[Vec<Cell>], index: usize) -> String {
    let mut kinds = rows
        .iter()
        .filter_map(|row| row.get(index))
        .filter(|cell| !cell.is_null())
        .map(Cell::type_name);
    let Some(first) = kinds.next() else {
        return String::new();
    };
    if kinds.all(|kind| kind == first) {
        first.to_owned()
    } else {
        String::new()
    }
}

/// A reply without its RESP3 attribute, which annotates a reply rather than being one.
fn strip_attribute(value: Value) -> Value {
    match value {
        Value::Attribute { data, .. } => strip_attribute(*data),
        other => other,
    }
}

fn cell(value: Value) -> Cell {
    match value {
        Value::Nil => Cell::Null,
        Value::Int(number) => Cell::Int(number),
        Value::Double(number) => Cell::Float(number),
        Value::Boolean(flag) => Cell::Bool(flag),
        Value::BigNumber(digits) => Cell::Decimal(String::from_utf8_lossy(&digits).into_owned()),
        // Redis strings are bytes. Most of them are text, and the ones that are not are shown as
        // bytes rather than mangled into replacement characters.
        Value::BulkString(bytes) => {
            String::from_utf8(bytes).map_or_else(|error| Cell::bytes(error.as_bytes()), Cell::Text)
        }
        Value::SimpleString(text) | Value::VerbatimString { text, .. } => Cell::Text(text),
        Value::Okay => Cell::Text("OK".to_owned()),
        Value::Array(items) | Value::Set(items) | Value::Push { data: items, .. } => {
            Cell::Array(items.into_iter().map(cell).collect())
        }
        Value::Map(pairs) => Cell::Array(
            pairs
                .into_iter()
                .flat_map(|(key, value)| [cell(key), cell(value)])
                .collect(),
        ),
        Value::Attribute { data, .. } => cell(*data),
        // An error inside a reply, such as one command of a transaction failing, is that command's
        // answer rather than a failure of the whole reply.
        Value::ServerError(error) => Cell::Text(error.to_string()),
        // The enum is non-exhaustive, so a reply type newer than this adapter still shows as
        // something rather than failing the query.
        other => Cell::Unsupported {
            type_name: "reply".to_owned(),
            raw: format!("{other:?}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use sqmeow_db::TypeClass;

    use super::*;

    fn words(line: &str) -> Vec<String> {
        split_command(line)
            .unwrap()
            .into_iter()
            .map(|word| String::from_utf8(word).unwrap())
            .collect()
    }

    fn text(value: &str) -> Value {
        Value::BulkString(value.as_bytes().to_vec())
    }

    #[test]
    fn splits_on_whitespace() {
        assert_eq!(words("  SET  visits 10 "), vec!["SET", "visits", "10"]);
        assert!(words("   ").is_empty());
    }

    #[test]
    fn a_double_quoted_word_keeps_its_spaces_and_reads_escapes() {
        assert_eq!(
            words(r#"SET greeting "hello \"world\"\n""#),
            vec!["SET", "greeting", "hello \"world\"\n"]
        );
        assert_eq!(words(r#"GET "\x41\x42""#), vec!["GET", "AB"]);
    }

    #[test]
    fn a_single_quoted_word_takes_backslashes_literally() {
        assert_eq!(words(r"GET 'a\nb\'c'"), vec!["GET", r"a\nb'c"]);
    }

    #[test]
    fn a_quoting_mistake_is_reported() {
        assert!(split_command(r#"GET "open"#).is_err());
        assert!(split_command(r#"GET "a"b"#).is_err());
    }

    #[test]
    fn a_quoted_key_reads_back_as_itself() {
        let key = "user \"one\"\\\n\tend";
        assert_eq!(
            split_command(&format!("GET {}", quote(key))).unwrap(),
            vec![b"GET".to_vec(), key.as_bytes().to_vec()]
        );
    }

    #[test]
    fn reads_the_current_database_from_client_info() {
        assert_eq!(current_db("id=3 addr=127.0.0.1:1 db=4 sub=0"), Some(4));
        assert_eq!(current_db(""), None);
    }

    #[test]
    fn a_map_is_a_row_per_field() {
        let reply = Value::Map(vec![
            (text("name"), text("alice")),
            (text("age"), text("30")),
        ]);
        let result = to_result("HGETALL user", reply, usize::MAX);

        let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["field", "value"]);
        assert_eq!(result.row_count(), 2);
        assert_eq!(result.cell(1, 1), Some(&Cell::Text("30".into())));
    }

    #[test]
    fn nested_arrays_spread_across_columns() {
        let reply = Value::Array(vec![
            Value::Array(vec![text("alice"), Value::Double(1.5)]),
            Value::Array(vec![text("bob"), Value::Double(2.0)]),
        ]);
        let result = to_result("ZRANGE z 0 -1 WITHSCORES", reply, usize::MAX);

        let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["1", "2"]);
        assert_eq!(result.cell(1, 0), Some(&Cell::Text("bob".into())));
        assert_eq!(result.columns()[1].class, TypeClass::Number);
    }

    #[test]
    fn a_scalar_is_one_row() {
        let result = to_result("GET absent", Value::Nil, usize::MAX);
        assert_eq!(result.row_count(), 1);
        assert_eq!(result.cell(0, 0), Some(&Cell::Null));

        let result = to_result("SET k v", Value::Okay, usize::MAX);
        assert_eq!(result.cell(0, 0), Some(&Cell::Text("OK".into())));
    }

    #[test]
    fn a_column_of_mixed_types_claims_none() {
        let reply = Value::Array(vec![text("a"), Value::Int(1)]);
        let result = to_result("x", reply, usize::MAX);
        assert_eq!(result.columns()[0].class, TypeClass::Unknown);
    }

    #[test]
    fn stops_at_the_row_cap_and_says_so() {
        let reply = Value::Array((0..10).map(Value::Int).collect());
        let result = to_result("LRANGE l 0 -1", reply, 3);
        assert_eq!(result.row_count(), 3);
        assert!(result.is_truncated());
    }

    #[test]
    fn binary_values_stay_bytes() {
        assert_eq!(
            cell(Value::BulkString(vec![0xff, 0x00])),
            Cell::bytes(&[0xff, 0x00])
        );
    }
}
