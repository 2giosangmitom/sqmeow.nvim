//! The Redis and Valkey adapter.

use std::time::{Duration, Instant};

use percent_encoding::percent_decode_str;
use redis::aio::{ConnectionLike, MultiplexedConnection};
use redis::cluster::ClusterClient;
use redis::cluster_async::ClusterConnection;
use redis::cluster_routing::{RoutingInfo, SingleNodeRoutingInfo};
use redis::sentinel::{SentinelClientBuilder, SentinelServerType};
use redis::{
    AsyncConnectionConfig, Client, Cmd, ConnectionAddr, FromRedisValue, IntoConnectionInfo,
    Pipeline, ProtocolVersion, RedisFuture, TlsMode, Value,
};
use sqmeow_db::edit::{self, Value as Edit, check_column, check_row};
use sqmeow_db::{
    Adapter, Cell, Changes, Column, ColumnNode, Dialect, Error, KeyType, RedisKind, RelationKind,
    RelationNode, Result, ResultSet, RoutineNode, SchemaNode, Source,
};
use tokio_util::sync::CancellationToken;

/// The most keys the drawer lists from one database.
pub const MAX_KEYS: usize = 10_000;

/// One server, the master a Sentinel names, or a whole cluster.
#[derive(Clone)]
enum Link {
    Server(MultiplexedConnection),
    Cluster(ClusterConnection),
}

impl ConnectionLike for Link {
    fn req_packed_command<'a>(&'a mut self, command: &'a Cmd) -> RedisFuture<'a, Value> {
        match self {
            Self::Server(connection) => connection.req_packed_command(command),
            Self::Cluster(connection) => connection.req_packed_command(command),
        }
    }

    fn req_packed_commands<'a>(
        &'a mut self,
        pipeline: &'a Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisFuture<'a, Vec<Value>> {
        match self {
            Self::Server(connection) => connection.req_packed_commands(pipeline, offset, count),
            Self::Cluster(connection) => connection.req_packed_commands(pipeline, offset, count),
        }
    }

    fn get_db(&self) -> i64 {
        match self {
            Self::Server(connection) => connection.get_db(),
            Self::Cluster(connection) => connection.get_db(),
        }
    }
}

/// One connection to a Redis or Valkey server, cluster, or Sentinel-watched master.
pub struct RedisAdapter {
    link: Link,
    /// The database the URL chose, for a server too old to say which one is current.
    db: i64,
}

impl std::fmt::Debug for RedisAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RedisAdapter")
            .field("db", &self.db)
            .finish_non_exhaustive()
    }
}

/// The login, addresses and path a cluster or Sentinel URL names, as
/// `scheme://user:password@host:port,host:port/path`.
#[derive(Debug, PartialEq)]
struct Hosts {
    user: Option<String>,
    password: Option<String>,
    addresses: Vec<(String, u16)>,
    path: Vec<String>,
}

/// Read a URL naming several hosts, each on `default` when it names no port.
fn hosts(url: &str, default: u16) -> Result<Hosts> {
    let rest = url
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let (login, addresses) = match authority.rsplit_once('@') {
        Some((login, addresses)) => (Some(login), addresses),
        None => (None, authority),
    };
    let decode = |text: &str| -> Result<Option<String>> {
        let text = percent_decode_str(text)
            .decode_utf8()
            .map_err(Error::driver)?;
        Ok((!text.is_empty()).then(|| text.into_owned()))
    };
    let (user, password) = match login.map(|login| login.split_once(':').unwrap_or((login, ""))) {
        Some((user, password)) => (decode(user)?, decode(password)?),
        None => (None, None),
    };
    let addresses = addresses
        .split(',')
        .filter(|address| !address.is_empty())
        .map(|address| {
            let (host, port) = match address.rsplit_once(':') {
                Some((host, port)) if !port.contains(']') => (host, Some(port)),
                _ => (address, None),
            };
            let port = match port {
                Some(port) => port
                    .parse()
                    .map_err(|_| Error::driver(format!("`{port}` is not a port")))?,
                None => default,
            };
            Ok((host.trim_matches(['[', ']']).to_owned(), port))
        })
        .collect::<Result<Vec<_>>>()?;
    if addresses.is_empty() {
        return Err(Error::driver("the URL names no host"));
    }
    Ok(Hosts {
        user,
        password,
        addresses,
        path: path
            .split('/')
            .filter(|part| !part.is_empty())
            .map(str::to_owned)
            .collect(),
    })
}

impl RedisAdapter {
    /// Open a connection: `redis+cluster://` reaches a cluster through any of its nodes, and
    /// `redis+sentinel://sentinels/master/db` the master the Sentinels name.
    pub async fn connect(url: &str) -> Result<Self> {
        let scheme = url
            .split_once("://")
            .map_or("", |(scheme, _)| scheme)
            .to_ascii_lowercase();
        // `rediss` is TLS, and `redis` is not, though it too ends in an `s`.
        if let Some(base) = scheme.strip_suffix("+cluster") {
            return Self::cluster(url, base == "rediss").await;
        }
        if let Some(base) = scheme.strip_suffix("+sentinel") {
            return Self::sentinel(url, base == "rediss").await;
        }

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
            // The driver gives up on a reply after half a second unless told otherwise.
            .set_response_timeout(None);
        let connection = client
            .get_multiplexed_async_connection_with_config(&config)
            .await
            .map_err(Error::driver)?;

        Ok(Self {
            link: Link::Server(connection),
            db,
        })
    }

    async fn cluster(url: &str, tls: bool) -> Result<Self> {
        let parsed = hosts(url, 6379)?;
        let scheme = if tls { "rediss" } else { "redis" };
        let nodes: Vec<String> = parsed
            .addresses
            .iter()
            .map(|(host, port)| format!("{scheme}://{host}:{port}"))
            .collect();
        let mut builder = ClusterClient::builder(nodes)
            .use_protocol(ProtocolVersion::RESP3)
            .connection_timeout(crate::CONNECT_TIMEOUT)
            // A reply takes as long as its command does.
            .response_timeout(Duration::from_secs(365 * 24 * 60 * 60));
        if let Some(user) = &parsed.user {
            builder = builder.username(user);
        }
        if let Some(password) = &parsed.password {
            builder = builder.password(password);
        }
        let connection = builder
            .build()
            .map_err(Error::driver)?
            .get_async_connection()
            .await
            .map_err(Error::driver)?;
        // A cluster has only database zero.
        Ok(Self {
            link: Link::Cluster(connection),
            db: 0,
        })
    }

    async fn sentinel(url: &str, tls: bool) -> Result<Self> {
        let parsed = hosts(url, 26379)?;
        let [service, rest @ ..] = parsed.path.as_slice() else {
            return Err(Error::driver(
                "a Sentinel URL names its master after the hosts, as in redis+sentinel://host:26379/mymaster/0",
            ));
        };
        let db = rest
            .first()
            .map(|db| {
                db.parse::<i64>()
                    .map_err(|_| Error::driver(format!("`{db}` is not a database number")))
            })
            .transpose()?
            .unwrap_or(0);

        let sentinels = parsed.addresses.iter().map(|(host, port)| {
            if tls {
                ConnectionAddr::TcpTls {
                    host: host.clone(),
                    port: *port,
                    insecure: false,
                    tls_params: None,
                }
            } else {
                ConnectionAddr::Tcp(host.clone(), *port)
            }
        });
        let mut builder =
            SentinelClientBuilder::new(sentinels, service, SentinelServerType::Master)
                .map_err(Error::driver)?
                .set_client_to_redis_db(db)
                .set_client_to_redis_protocol(ProtocolVersion::RESP3);
        if tls {
            builder = builder.set_client_to_redis_tls_mode(TlsMode::Secure);
        }
        // The login is the master's, which a Sentinel without a password of its own would refuse.
        if let Some(user) = &parsed.user {
            builder = builder.set_client_to_redis_username(user);
        }
        if let Some(password) = &parsed.password {
            builder = builder.set_client_to_redis_password(password);
        }
        let config = AsyncConnectionConfig::new()
            .set_connection_timeout(Some(crate::CONNECT_TIMEOUT))
            .set_response_timeout(None);
        let connection = builder
            .build()
            .map_err(Error::driver)?
            .get_async_connection_with_config(&config)
            .await
            .map_err(Error::driver)?;
        Ok(Self {
            link: Link::Server(connection),
            db,
        })
    }

    async fn query<T: FromRedisValue>(&self, command: &Cmd) -> Result<T> {
        // A connection is a handle onto shared sockets, so a clone is the same session.
        command
            .query_async(&mut self.link.clone())
            .await
            .map_err(Error::driver)
    }

    /// The keys matching a glob, from one server or every primary of a cluster, each with the type
    /// of value it holds.
    pub async fn keys(&self, pattern: &str) -> Result<Vec<RelationNode>> {
        let mut names = Vec::new();
        match &self.link {
            Link::Server(_) => names = self.scan(None, pattern).await?,
            Link::Cluster(_) => {
                for (host, port) in self.primaries().await? {
                    let node =
                        RoutingInfo::SingleNode(SingleNodeRoutingInfo::ByAddress { host, port });
                    names.extend(self.scan(Some(&node), pattern).await?);
                    if names.len() >= MAX_KEYS {
                        break;
                    }
                }
            }
        }
        names.truncate(MAX_KEYS);
        // A scan may return a key twice while the server is resizing its table.
        names.sort_unstable();
        names.dedup();

        if names.is_empty() {
            return Ok(Vec::new());
        }

        let types: Vec<String> = match &self.link {
            // Every `TYPE` in one round trip, rather than one per key.
            Link::Server(_) => {
                let mut pipeline = redis::pipe();
                for name in &names {
                    pipeline.cmd("TYPE").arg(name.as_slice());
                }
                pipeline
                    .query_async(&mut self.link.clone())
                    .await
                    .map_err(Error::driver)?
            }
            // A cluster's keys sit on different nodes, so each `TYPE` goes to its own.
            Link::Cluster(_) => {
                let asked = names.iter().map(|name| async move {
                    self.query::<String>(redis::cmd("TYPE").arg(name.as_slice()))
                        .await
                });
                futures_util::future::join_all(asked)
                    .await
                    .into_iter()
                    .collect::<Result<_>>()?
            }
        };

        Ok(names
            .into_iter()
            .zip(types)
            .filter_map(|(name, kind)| {
                // A key that expired since the scan answers `none`, and a type nothing reads back
                // yet, such as a Bloom filter's `MBbloom--`, has no group to go under.
                let kind = KeyType::from_redis(&kind)?;
                Some(RelationNode {
                    name: String::from_utf8_lossy(&name).into_owned(),
                    kind: RelationKind::Key(kind),
                })
            })
            .collect())
    }

    /// The keys matching a glob on one server, or one cluster node, up to the cap.
    async fn scan(&self, node: Option<&RoutingInfo>, pattern: &str) -> Result<Vec<Vec<u8>>> {
        let mut names: Vec<Vec<u8>> = Vec::new();
        let mut cursor = 0u64;
        loop {
            let mut command = redis::cmd("SCAN");
            command
                .cursor_arg(cursor)
                .arg("MATCH")
                .arg(pattern)
                .arg("COUNT")
                .arg(1000);
            let (next, batch): (u64, Vec<Vec<u8>>) = match (&self.link, node) {
                (Link::Cluster(connection), Some(routing)) => {
                    let reply = connection
                        .clone()
                        .route_command(command, routing.clone())
                        .await
                        .map_err(Error::driver)?;
                    FromRedisValue::from_redis_value(reply).map_err(Error::driver)?
                }
                _ => self.query(&command).await?,
            };
            names.extend(batch);
            cursor = next;
            if cursor == 0 || names.len() >= MAX_KEYS {
                return Ok(names);
            }
        }
    }

    /// The address of each primary in the cluster, read from `CLUSTER NODES`.
    async fn primaries(&self) -> Result<Vec<(String, u16)>> {
        let nodes: String = self.query(redis::cmd("CLUSTER").arg("NODES")).await?;
        Ok(nodes
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                let address = fields.nth(1)?;
                let flags = fields.next()?;
                flags
                    .split(',')
                    .any(|flag| flag == "master")
                    .then_some(())?;
                let (host, port) = address.split('@').next()?.rsplit_once(':')?;
                Some((host.trim_matches(['[', ']']).to_owned(), port.parse().ok()?))
            })
            .collect())
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

    fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        plan(result, changes)
    }

    /// One `MULTI`/`EXEC`, which can only be cancelled before it is sent.
    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let mut pipeline = redis::pipe();
        pipeline.atomic();
        for line in statements {
            let mut command = Cmd::new();
            for word in split_command(line).map_err(Error::Driver)? {
                command.arg(word);
            }
            pipeline.add_command(command);
        }

        let reply: Value = pipeline
            .query_async(&mut self.link.clone())
            .await
            .map_err(Error::driver)?;
        let Value::Array(replies) = &reply else {
            return Ok(Vec::new());
        };
        if let Some(Value::ServerError(error)) = replies
            .iter()
            .find(|reply| matches!(reply, Value::ServerError(_)))
        {
            return Err(Error::driver(format!(
                "a command failed, and Redis kept the ones that did not: {error}"
            )));
        }
        // `RENAMENX` answers 0 rather than failing when the new name is taken.
        for (line, reply) in statements.iter().zip(replies) {
            if let (Value::Int(0), Ok(words)) = (reply, split_command(line))
                && let [command, from, to] = words.as_slice()
                && command.eq_ignore_ascii_case(b"RENAMENX")
            {
                return Err(Error::driver(format!(
                    "`{}` already exists, so `{}` was not renamed, and Redis kept the other changes",
                    String::from_utf8_lossy(to),
                    String::from_utf8_lossy(from)
                )));
            }
        }
        Ok(Vec::new())
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

        // Dropping the request leaves the connection usable.
        let reply = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(Error::Cancelled),
            reply = self.query::<Value>(&command) => reply?,
        };

        let mut result = to_result(statement, reply, max_rows);
        result.set_source(source(&words));
        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    /// Only the database the connection is on.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        // `CLIENT INFO` rather than the URL.
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

    /// The keys of the current database, or of every primary of a cluster, each with the type of
    /// value it holds.
    async fn relations(&self, _schema: &str) -> Result<Vec<RelationNode>> {
        self.keys("*").await
    }

    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(Vec::new())
    }

    /// A key has no columns. The drawer draws keys as leaves, so this is never asked for.
    async fn columns(&self, _schema: &str, _relation: &str) -> Result<Vec<ColumnNode>> {
        Ok(Vec::new())
    }

    /// A key's type, TTL, length, encoding and memory.
    async fn details(&self, _schema: &str, key: &str) -> Result<sqmeow_db::Details> {
        let kind: String = self.query(redis::cmd("TYPE").arg(key)).await?;
        if kind == "none" {
            return Err(Error::driver(format!("there is no key `{key}`")));
        }
        let ttl: i64 = self.query(redis::cmd("TTL").arg(key)).await?;
        let mut properties = vec![
            ("type".to_owned(), kind.clone()),
            (
                "ttl".to_owned(),
                if ttl < 0 {
                    "none".to_owned()
                } else {
                    format!("{ttl} s")
                },
            ),
        ];
        let length = match kind.as_str() {
            "string" => Some("STRLEN"),
            "hash" => Some("HLEN"),
            "list" => Some("LLEN"),
            "set" => Some("SCARD"),
            "zset" => Some("ZCARD"),
            "stream" => Some("XLEN"),
            _ => None,
        };
        if let Some(command) = length {
            let length: i64 = self.query(redis::cmd(command).arg(key)).await?;
            properties.push(("length".to_owned(), length.to_string()));
        }
        // Not every server speaking the protocol answers these.
        if let Ok(encoding) = self
            .query::<String>(redis::cmd("OBJECT").arg("ENCODING").arg(key))
            .await
        {
            properties.push(("encoding".to_owned(), encoding));
        }
        if let Ok(bytes) = self
            .query::<i64>(redis::cmd("MEMORY").arg("USAGE").arg(key))
            .await
        {
            properties.push(("memory".to_owned(), format!("{bytes} bytes")));
        }
        Ok(sqmeow_db::Details {
            properties,
            ..sqmeow_db::Details::default()
        })
    }

    /// Nothing to do: the socket closes once the last handle onto it is dropped.
    async fn close(&self) {}
}

/// Which key a command read, for the commands whose reply can be written back.
fn source(words: &[Vec<u8>]) -> Option<Source> {
    let name = String::from_utf8_lossy(words.first()?).to_ascii_uppercase();
    let key = String::from_utf8(words.get(1)?.clone()).ok()?;
    let number =
        |index: usize| -> Option<i64> { String::from_utf8_lossy(words.get(index)?).parse().ok() };

    let kind = match (name.as_str(), words.len()) {
        ("GET", 2) => RedisKind::String,
        ("JSON.GET", 2) => RedisKind::Json,
        ("HGETALL", 2) => RedisKind::Hash,
        ("SMEMBERS", 2) => RedisKind::Set,
        // Counted from the end, an index stays right only while the whole range is.
        ("LRANGE", 4) => RedisKind::List {
            start: number(2)
                .filter(|start| *start >= 0 || number(3).is_some_and(|stop| stop < 0))?,
        },
        ("ZRANGE", 5)
            if words[4].eq_ignore_ascii_case(b"WITHSCORES")
                && number(2).is_some()
                && number(3).is_some() =>
        {
            RedisKind::SortedSet
        }
        ("XRANGE", 4) => RedisKind::Stream,
        ("XRANGE", 6) if words[4].eq_ignore_ascii_case(b"COUNT") => RedisKind::Stream,
        ("KEYS", 2) => RedisKind::Keys,
        _ => return None,
    };
    Some(Source::Redis { key, kind })
}

/// Plan changes to one key into command lines that [`split_command`] reads back.
fn plan(result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
    let Some(source @ Source::Redis { key, kind }) = result.source() else {
        return Err(edit::not_editable());
    };
    let kind = *kind;
    let key = quote(key);
    // A deleted list element is marked by its index, then every mark is removed at once, so an equal
    // element elsewhere in the list stays.
    let deleted = quote(&format!(
        "sqmeow:deleted:{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos())
    ));

    let original = |row: usize, column: usize| -> Result<String> {
        check_row(result, row)?;
        Ok(match result.cell(row, column) {
            Some(Cell::Bytes { head, .. }) => quote_bytes(head),
            Some(cell) => quote(&cell.text("")),
            None => quote(""),
        })
    };
    let given = |cells: &[(usize, Edit)], column: usize| -> Result<Option<String>> {
        cells
            .iter()
            .find(|(at, _)| *at == column)
            .map(|(_, value)| match value {
                Edit::Text(text) => Ok(quote(text)),
                Edit::Null => Err(Error::driver("Redis has no NULL: delete the row instead")),
                Edit::Sql(_) => Err(Error::driver("Redis takes no SQL expression")),
            })
            .transpose()
    };
    // What removes a row: from the key, or the key itself.
    let removal = |row: usize| -> Result<String> {
        Ok(match kind {
            RedisKind::String | RedisKind::Json => {
                check_row(result, row)?;
                format!("DEL {key}")
            }
            RedisKind::Hash => format!("HDEL {key} {}", original(row, 0)?),
            RedisKind::Set => format!("SREM {key} {}", original(row, 0)?),
            RedisKind::List { start } => {
                check_row(result, row)?;
                format!("LSET {key} {} {deleted}", start + row as i64)
            }
            RedisKind::SortedSet => format!("ZREM {key} {}", original(row, 0)?),
            RedisKind::Stream => format!("XDEL {key} {}", original(row, 0)?),
            RedisKind::Keys => format!("DEL {}", original(row, 0)?),
        })
    };

    let mut commands = Vec::new();
    for (row, cells) in changes.live_updates() {
        for (column, _) in cells {
            check_column(source, result, *column)?;
        }
        let row = *row;
        // Redis holds no NULL, so a value set to one goes the way a deleted row does.
        if cells.iter().any(|(_, value)| *value == Edit::Null) {
            commands.push(removal(row)?);
            continue;
        }
        match kind {
            RedisKind::String => {
                if let Some(value) = given(cells, 0)? {
                    commands.push(format!("SET {key} {value} KEEPTTL"));
                }
            }
            RedisKind::Json => {
                if let Some(value) = given(cells, 0)? {
                    commands.push(format!("JSON.SET {key} $ {value}"));
                }
            }
            RedisKind::Hash => {
                let field = original(row, 0)?;
                let value = match given(cells, 1)? {
                    Some(value) => value,
                    None => original(row, 1)?,
                };
                match given(cells, 0)? {
                    Some(renamed) if renamed != field => {
                        commands.push(format!("HDEL {key} {field}"));
                        commands.push(format!("HSET {key} {renamed} {value}"));
                    }
                    _ => commands.push(format!("HSET {key} {field} {value}")),
                }
            }
            RedisKind::Set => {
                if let Some(member) = given(cells, 0)? {
                    commands.push(format!("SREM {key} {}", original(row, 0)?));
                    commands.push(format!("SADD {key} {member}"));
                }
            }
            RedisKind::List { start } => {
                if let Some(value) = given(cells, 0)? {
                    check_row(result, row)?;
                    commands.push(format!("LSET {key} {} {value}", start + row as i64));
                }
            }
            RedisKind::SortedSet => {
                let member = original(row, 0)?;
                let score = match given(cells, 1)? {
                    Some(score) => score,
                    None => original(row, 1)?,
                };
                match given(cells, 0)? {
                    Some(renamed) if renamed != member => {
                        commands.push(format!("ZREM {key} {member}"));
                        commands.push(format!("ZADD {key} {score} {renamed}"));
                    }
                    _ => commands.push(format!("ZADD {key} {score} {member}")),
                }
            }
            RedisKind::Stream => {
                return Err(Error::driver(
                    "a stream entry cannot change: delete it and add another",
                ));
            }
            RedisKind::Keys => {
                if let Some(renamed) = given(cells, 0)? {
                    commands.push(format!("RENAMENX {} {renamed}", original(row, 0)?));
                }
            }
        }
    }

    for &row in &changes.deletes {
        commands.push(removal(row)?);
    }
    if matches!(kind, RedisKind::List { .. })
        && commands.iter().any(|command| command.ends_with(&deleted))
    {
        commands.push(format!("LREM {key} 0 {deleted}"));
    }

    for cells in &changes.inserts {
        let need = |column: usize, what: &str| -> Result<String> {
            given(cells, column)?.ok_or_else(|| Error::driver(format!("a new row needs a {what}")))
        };
        commands.push(match kind {
            RedisKind::String | RedisKind::Json => {
                return Err(Error::driver(
                    "the key holds one value: edit it rather than adding a row",
                ));
            }
            RedisKind::Keys => {
                return Err(Error::driver(
                    "a key is added by writing to it, not to a list of keys",
                ));
            }
            RedisKind::Hash => format!("HSET {key} {} {}", need(0, "field")?, need(1, "value")?),
            RedisKind::Set => format!("SADD {key} {}", need(0, "member")?),
            RedisKind::List { .. } => format!("RPUSH {key} {}", need(0, "value")?),
            RedisKind::SortedSet => {
                format!("ZADD {key} {} {}", need(1, "score")?, need(0, "member")?)
            }
            // The fields are typed as they are written after `XADD`: `name alice age 3`.
            RedisKind::Stream => {
                let fields = cells
                    .iter()
                    .find_map(|(at, value)| (*at == 1).then(|| value.text()).flatten())
                    .filter(|fields| !fields.trim().is_empty())
                    .ok_or_else(|| {
                        Error::driver("a new entry needs its fields, as `name alice`")
                    })?;
                format!("XADD {key} * {fields}")
            }
        });
    }
    Ok(commands)
}

/// Bytes as a quoted word, anything that is not printable text escaped as `\xhh`.
fn quote_bytes(bytes: &[u8]) -> String {
    let mut quoted = String::with_capacity(bytes.len() + 2);
    quoted.push('"');
    for &byte in bytes {
        match byte {
            b'"' | b'\\' => {
                quoted.push('\\');
                quoted.push(byte as char);
            }
            0x20..=0x7e => quoted.push(byte as char),
            other => quoted.push_str(&format!("\\x{other:02x}")),
        }
    }
    quoted.push('"');
    quoted
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
        // Redis strings are bytes.
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
        // The enum is non-exhaustive.
        other => Cell::Unsupported {
            type_name: "reply".to_owned(),
            raw: format!("{other:?}"),
        },
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_cluster_or_sentinel_url_names_its_hosts_login_and_path() {
        assert_eq!(
            hosts("redis+sentinel://u:p%40ss@s1,[::1]:26380/mymaster/2", 26379).unwrap(),
            Hosts {
                user: Some("u".into()),
                password: Some("p@ss".into()),
                addresses: vec![("s1".into(), 26379), ("::1".into(), 26380)],
                path: vec!["mymaster".into(), "2".into()],
            }
        );
        assert_eq!(
            hosts("redis+cluster://a:7000,b:7001", 6379)
                .unwrap()
                .addresses,
            vec![("a".into(), 7000), ("b".into(), 7001)]
        );
        assert!(hosts("redis+cluster:///", 6379).is_err());
    }

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

    fn hash() -> ResultSet {
        let reply = Value::Map(vec![(text("name"), text("al \"x\""))]);
        let mut result = to_result("HGETALL user", reply, usize::MAX);
        result.set_source(source(&split_command("HGETALL user").unwrap()));
        result
    }

    #[test]
    fn the_commands_that_can_be_written_back_have_a_source() {
        let kind = |line: &str| match source(&split_command(line).unwrap()) {
            Some(Source::Redis { kind, .. }) => Some(kind),
            _ => None,
        };
        assert_eq!(kind("get k"), Some(RedisKind::String));
        assert_eq!(kind("LRANGE k 5 10"), Some(RedisKind::List { start: 5 }));
        assert_eq!(kind("LRANGE k -5 -1"), Some(RedisKind::List { start: -5 }));
        assert_eq!(kind("ZRANGE k 0 -1 WITHSCORES"), Some(RedisKind::SortedSet));
        assert_eq!(kind("ZRANGE k 0 -1"), None);
        assert_eq!(kind("KEYS *"), Some(RedisKind::Keys));
    }

    #[test]
    fn more_commands_can_be_written_back() {
        let kind = |line: &str| match source(&split_command(line).unwrap()) {
            Some(Source::Redis { kind, .. }) => Some(kind),
            _ => None,
        };
        assert_eq!(kind("LRANGE k -3 -1"), Some(RedisKind::List { start: -3 }));
        assert_eq!(kind("LRANGE k -3 5"), None);
        assert_eq!(kind("JSON.GET k"), Some(RedisKind::Json));
        assert_eq!(kind("XRANGE k - + COUNT 10"), Some(RedisKind::Stream));
        assert_eq!(kind("KEYS user:*"), Some(RedisKind::Keys));
    }

    #[test]
    fn a_null_removes_a_field_and_a_key_list_renames_and_deletes() {
        let result = hash();
        let changes = Changes {
            updates: vec![(0, vec![(1, sqmeow_db::edit::Value::Null)])],
            ..Changes::default()
        };
        assert_eq!(
            plan(&result, &changes).unwrap(),
            vec![r#"HDEL "user" "name""#]
        );

        let reply = Value::Array(vec![text("a"), text("b")]);
        let mut keys = to_result("KEYS *", reply, usize::MAX);
        keys.set_source(source(&split_command("KEYS *").unwrap()));
        let changes = Changes {
            updates: vec![(0, vec![(0, "c".into())])],
            deletes: vec![1],
            ..Changes::default()
        };
        assert_eq!(
            plan(&keys, &changes).unwrap(),
            vec![r#"RENAMENX "a" "c""#, r#"DEL "b""#]
        );
    }

    #[test]
    fn a_binary_value_is_written_back_byte_for_byte() {
        assert_eq!(quote_bytes(&[0x61, 0x00, 0xff, b'"']), r#""a\x00\xff\"""#);
        assert_eq!(
            split_command(&format!("SET k {}", quote_bytes(&[0x00, 0xff]))).unwrap()[2],
            vec![0x00, 0xff]
        );
    }

    #[test]
    fn a_hash_field_is_changed_renamed_deleted_and_added() {
        let result = hash();
        let changes = Changes {
            updates: vec![(0, vec![(1, "bob".into())])],
            ..Changes::default()
        };
        assert_eq!(
            plan(&result, &changes).unwrap(),
            vec![r#"HSET "user" "name" "bob""#]
        );

        let changes = Changes {
            updates: vec![(0, vec![(0, "who".into())])],
            inserts: vec![vec![(0, "age".into()), (1, "3".into())]],
            ..Changes::default()
        };
        assert_eq!(
            plan(&result, &changes).unwrap(),
            vec![
                r#"HDEL "user" "name""#,
                r#"HSET "user" "who" "al \"x\"""#,
                r#"HSET "user" "age" "3""#,
            ]
        );

        let changes = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            plan(&result, &changes).unwrap(),
            vec![r#"HDEL "user" "name""#]
        );
    }

    #[test]
    fn a_planned_command_splits_back_into_its_words() {
        let result = hash();
        let changes = Changes {
            updates: vec![(0, vec![(1, "a b\n".into())])],
            ..Changes::default()
        };
        let line = &plan(&result, &changes).unwrap()[0];
        let words = split_command(line).unwrap();
        assert_eq!(words[3], b"a b\n");
    }

    #[test]
    fn redis_refuses_a_null_new_row_and_a_result_without_a_source() {
        let result = hash();
        let changes = Changes {
            inserts: vec![vec![(0, "f".into()), (1, sqmeow_db::edit::Value::Null)]],
            ..Changes::default()
        };
        assert!(plan(&result, &changes).is_err());

        let unsourced = to_result("KEYS *", Value::Array(vec![]), usize::MAX);
        assert!(plan(&unsourced, &Changes::default()).is_err());
    }

    #[test]
    fn a_list_element_is_set_by_its_index() {
        let reply = Value::Array(vec![text("a"), text("b")]);
        let mut result = to_result("LRANGE l 10 11", reply, usize::MAX);
        result.set_source(source(&split_command("LRANGE l 10 11").unwrap()));
        let changes = Changes {
            updates: vec![(1, vec![(0, "c".into())])],
            ..Changes::default()
        };
        assert_eq!(plan(&result, &changes).unwrap(), vec![r#"LSET "l" 11 "c""#]);
    }

    #[test]
    fn a_list_element_is_deleted_by_its_index_and_a_string_keeps_its_ttl() {
        let reply = Value::Array(vec![text("a"), text("a")]);
        let mut result = to_result("LRANGE l 0 -1", reply, usize::MAX);
        result.set_source(source(&split_command("LRANGE l 0 -1").unwrap()));
        let changes = Changes {
            updates: vec![(0, vec![(0, sqmeow_db::edit::Value::Null)])],
            deletes: vec![1],
            inserts: vec![vec![(0, "b".into())]],
        };
        let planned = plan(&result, &changes).unwrap();
        let mark = planned[0].rsplit(' ').next().unwrap().to_owned();
        assert!(mark.starts_with(r#""sqmeow:deleted:"#), "{mark}");
        assert_eq!(
            planned,
            vec![
                format!(r#"LSET "l" 0 {mark}"#),
                format!(r#"LSET "l" 1 {mark}"#),
                format!(r#"LREM "l" 0 {mark}"#),
                r#"RPUSH "l" "b""#.to_owned(),
            ]
        );

        let mut string = to_result("GET s", text("x"), usize::MAX);
        string.set_source(source(&split_command("GET s").unwrap()));
        let changes = Changes {
            updates: vec![(0, vec![(0, "y".into())])],
            ..Changes::default()
        };
        assert_eq!(
            plan(&string, &changes).unwrap(),
            vec![r#"SET "s" "y" KEEPTTL"#]
        );
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
