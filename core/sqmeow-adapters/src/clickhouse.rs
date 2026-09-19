//! The ClickHouse adapter, over the HTTP interface.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use clickhouse::Client;
use percent_encoding::percent_decode_str;
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Details, Dialect, Error, IndexNode, RelationKind,
    RelationNode, Result, ResultSet, RoleNode, RoutineNode, SchemaNode,
};
use tokio::io::AsyncBufReadExt;
use tokio_util::sync::CancellationToken;

/// Every value as a JSON string, so wide integers and decimals keep their digits.
const FORMAT: &str = "JSONCompactStringsEachRowWithNamesAndTypes";

/// How the strings formats write a NULL.
const NULL: &str = "ᴺᵁᴸᴸ";

/// One ClickHouse server, reached over HTTP(S).
pub struct ClickHouseAdapter {
    client: Client,
}

impl std::fmt::Debug for ClickHouseAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClickHouseAdapter").finish_non_exhaustive()
    }
}

/// What a `clickhouse://` URL asks for.
#[derive(Debug, PartialEq)]
struct Target {
    endpoint: String,
    user: Option<String>,
    password: Option<String>,
    database: Option<String>,
    settings: Vec<(String, String)>,
}

impl ClickHouseAdapter {
    /// Build a client for the URL and check the server answers.
    pub async fn connect(url: &str, read_only: bool) -> Result<Self> {
        let target = parse_url(url)?;
        let mut client = Client::default().with_url(target.endpoint);
        if let Some(user) = target.user {
            client = client.with_user(user);
        }
        if let Some(password) = target.password {
            client = client.with_password(password);
        }
        if let Some(database) = target.database {
            client = client.with_database(database);
        }
        for (name, value) in target.settings {
            client = client.with_setting(name, value);
        }
        if read_only {
            client = client.with_setting("readonly", "1");
        }

        let adapter = Self { client };
        tokio::time::timeout(crate::CONNECT_TIMEOUT, adapter.rows("select 1", &[]))
            .await
            .map_err(|_| Error::driver("timed out connecting to the server"))??;
        Ok(adapter)
    }

    /// Run a metadata query with `?` bound to `binds`, every value read as text.
    async fn rows(&self, sql: &str, binds: &[&str]) -> Result<Vec<Vec<String>>> {
        let mut query = self.client.query(sql);
        for bind in binds {
            query = query.bind(*bind);
        }
        let body = query
            .fetch_bytes("JSONCompactStringsEachRow")
            .map_err(Error::driver)?
            .collect()
            .await
            .map_err(Error::driver)?;
        body.split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_slice(line).map_err(Error::driver))
            .collect()
    }

    async fn read(&self, statement: &str, max_rows: usize, query_id: &str) -> Result<ResultSet> {
        let started = Instant::now();
        let cursor = self
            .client
            .query_raw(statement)
            .with_setting("query_id", query_id)
            .fetch_bytes(FORMAT)
            .map_err(Error::driver)?;
        let mut lines = cursor.lines();
        let mut next = async || -> Result<Option<Vec<Option<String>>>> {
            let Some(line) = lines.next_line().await.map_err(Error::driver)? else {
                return Ok(None);
            };
            // A line that is not JSON is an error the server wrote into the stream.
            serde_json::from_str(&line)
                .map(Some)
                .map_err(|_| Error::driver(line))
        };

        // A statement that returns no rows, such as DDL, answers with an empty body.
        let Some(names) = next().await? else {
            let mut result = ResultSet::new(statement, Vec::new());
            result.set_elapsed(started.elapsed());
            return Ok(result);
        };
        let types: Vec<String> = next()
            .await?
            .unwrap_or_default()
            .into_iter()
            .map(Option::unwrap_or_default)
            .collect();
        let columns = names
            .into_iter()
            .zip(&types)
            .map(|(name, type_name)| Column::new(name.unwrap_or_default(), base_type(type_name)))
            .collect();

        let mut result = ResultSet::new(statement, columns);
        while let Some(row) = next().await? {
            if result.row_count() >= max_rows {
                result.mark_truncated();
                break;
            }
            result.push_row(
                row.into_iter()
                    .zip(&types)
                    .map(|(value, type_name)| match value {
                        Some(value) if !(value == NULL && is_nullable(type_name)) => {
                            decode(base_type(type_name), value)
                        }
                        _ => Cell::Null,
                    })
                    .collect(),
            );
        }
        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    /// Ask the server to stop a query whose response is no longer read.
    async fn kill(&self, query_id: &str) {
        let kill = self
            .client
            .query("KILL QUERY WHERE query_id = ? ASYNC")
            .bind(query_id)
            .execute();
        match tokio::time::timeout(crate::STOP_TIMEOUT, kill).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::debug!(%error, "could not kill a cancelled query"),
            Err(_) => tracing::debug!("timed out killing a cancelled query"),
        }
    }
}

impl Adapter for ClickHouseAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::ClickHouse
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let query_id = format!(
            "sqmeow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        tokio::select! {
            biased;
            () = cancel.cancelled() => {
                self.kill(&query_id).await;
                Err(Error::Cancelled)
            }
            result = self.read(statement, max_rows, &query_id) => result,
        }
    }

    async fn apply(&self, _: &[String], _: CancellationToken) -> Result<Vec<ResultSet>> {
        Err(Error::driver("ClickHouse results are read-only"))
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        Ok(self
            .rows(
                "select name, name = currentDatabase() from system.databases
                 where name not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
                 order by name",
                &[],
            )
            .await?
            .into_iter()
            .map(|row| SchemaNode {
                is_default: row[1] == "1",
                name: row[0].clone(),
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        Ok(self
            .rows(
                "select name, engine from system.tables where database = ? order by name",
                &[schema],
            )
            .await?
            .into_iter()
            .map(|row| RelationNode {
                kind: match row[1].as_str() {
                    "View" => RelationKind::View,
                    "MaterializedView" => RelationKind::MaterializedView,
                    "Dictionary" => RelationKind::Other,
                    _ => RelationKind::Table,
                },
                name: row[0].clone(),
            })
            .collect())
    }

    /// User-defined functions, which belong to the server rather than a database.
    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(self
            .rows(
                "select name from system.functions where origin = 'SQLUserDefined' order by name",
                &[],
            )
            .await?
            .into_iter()
            .map(|row| crate::routine_node(row[0].clone(), "function"))
            .collect())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        Ok(self
            .rows(
                "select name, type, default_expression, is_in_primary_key from system.columns
                 where database = ? and table = ? order by position",
                &[schema, relation],
            )
            .await?
            .into_iter()
            .map(|row| ColumnNode {
                name: row[0].clone(),
                type_name: base_type(&row[1]).to_owned(),
                nullable: is_nullable(&row[1]),
                primary_key: row[3] == "1",
                foreign_key: None,
                default: (!row[2].is_empty()).then(|| row[2].clone()),
            })
            .collect())
    }

    /// The primary key, which does not make rows unique, then the data skipping indexes.
    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        let primary = self
            .rows(
                "select primary_key from system.tables where database = ? and name = ?",
                &[schema, relation],
            )
            .await?
            .into_iter()
            .filter(|row| !row[0].is_empty())
            .map(|row| IndexNode {
                name: "PRIMARY KEY".to_owned(),
                columns: vec![row[0].clone()],
                unique: false,
                primary: true,
            });
        let skipping = self
            .rows(
                "select name, expr from system.data_skipping_indices
                 where database = ? and table = ? order by name",
                &[schema, relation],
            )
            .await?
            .into_iter()
            .map(|row| IndexNode {
                name: row[0].clone(),
                columns: vec![row[1].clone()],
                unique: false,
                primary: false,
            });
        Ok(primary.chain(skipping).collect())
    }

    async fn roles(&self) -> Result<Vec<RoleNode>> {
        Ok(self
            .rows(
                "select name, 'user' from system.users
                 union all select name, 'role' from system.roles
                 order by 1",
                &[],
            )
            .await?
            .into_iter()
            .map(|row| RoleNode {
                name: row[0].clone(),
                attributes: vec![row[1].clone()],
            })
            .collect())
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<Details> {
        let table = self
            .rows(
                "select comment, engine_full, create_table_query from system.tables
                 where database = ? and name = ?",
                &[schema, relation],
            )
            .await?;
        let column_comments = self
            .rows(
                "select name, comment from system.columns
                 where database = ? and table = ? and comment != '' order by position",
                &[schema, relation],
            )
            .await?
            .into_iter()
            .map(|row| (row[0].clone(), row[1].clone()))
            .collect();
        let Some(table) = table.into_iter().next() else {
            return Ok(Details::default());
        };
        let properties = [("comment", &table[0]), ("engine", &table[1])]
            .into_iter()
            .filter(|(_, value)| !value.is_empty())
            .map(|(name, value)| (name.to_owned(), value.clone()))
            .collect();
        Ok(Details {
            properties,
            column_comments,
            definition: Some(table[2].clone()).filter(|query| !query.is_empty()),
            ..Details::default()
        })
    }

    async fn close(&self) {}
}

/// Read `clickhouse[s]://user:password@host:port/database?setting=value`.
fn parse_url(url: &str) -> Result<Target> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let tls = scheme.eq_ignore_ascii_case("clickhouses");
    let (rest, options) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, database) = rest.split_once('/').unwrap_or((rest, ""));
    let (login, host) = match authority.rsplit_once('@') {
        Some((login, host)) => (Some(login), host),
        None => (None, authority),
    };

    let decode = |text: &str| {
        percent_decode_str(text)
            .decode_utf8()
            .map(|text| text.into_owned())
            .map_err(Error::driver)
    };
    let host = if host.is_empty() { "localhost" } else { host };
    // A bracketed IPv6 address has colons of its own.
    let host = if host.ends_with(']') || !host.contains(':') {
        format!("{host}:{}", if tls { 8443 } else { 8123 })
    } else {
        host.to_owned()
    };
    let (user, password) = match login {
        Some(login) => {
            let (user, password) = login.split_once(':').unwrap_or((login, ""));
            (
                Some(decode(user)?),
                (!password.is_empty())
                    .then(|| decode(password))
                    .transpose()?,
            )
        }
        None => (None, None),
    };
    let settings = options
        .split('&')
        .filter(|option| !option.is_empty())
        .map(|option| {
            let (name, value) = option.split_once('=').unwrap_or((option, ""));
            Ok((decode(name)?, decode(value)?))
        })
        .collect::<Result<_>>()?;

    Ok(Target {
        endpoint: format!("{}://{host}", if tls { "https" } else { "http" }),
        user,
        password,
        database: (!database.is_empty())
            .then(|| decode(database))
            .transpose()?,
        settings,
    })
}

/// A type without the `Nullable` and `LowCardinality` wrappers around it.
fn base_type(mut name: &str) -> &str {
    while let Some(inner) = name
        .strip_prefix("Nullable(")
        .or_else(|| name.strip_prefix("LowCardinality("))
        .and_then(|inner| inner.strip_suffix(')'))
    {
        name = inner;
    }
    name
}

fn is_nullable(type_name: &str) -> bool {
    type_name.starts_with("Nullable(") || type_name.starts_with("LowCardinality(Nullable(")
}

/// A value in its text form, typed by its column's type.
fn decode(type_name: &str, value: String) -> Cell {
    let head = type_name.split('(').next().unwrap_or(type_name);
    match head {
        _ if head.starts_with("Int") || head.starts_with("UInt") => value
            .parse()
            .map_or_else(|_| Cell::Decimal(value), Cell::Int),
        "Float32" | "Float64" | "BFloat16" => value
            .parse()
            .map_or_else(|_| Cell::Text(value), Cell::Float),
        _ if head.starts_with("Decimal") => Cell::Decimal(value),
        "Bool" => Cell::Bool(value == "true"),
        "Date" | "Date32" => Cell::Date(value),
        "DateTime" | "DateTime64" => Cell::Timestamp(value),
        "UUID" => Cell::Uuid(value),
        "JSON" | "Object" => Cell::Json(value),
        _ => Cell::Text(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_full_url() {
        let target =
            parse_url("clickhouses://me:p%40ss@db.example:9443/logs?max_threads=2").unwrap();
        assert_eq!(
            target,
            Target {
                endpoint: "https://db.example:9443".into(),
                user: Some("me".into()),
                password: Some("p@ss".into()),
                database: Some("logs".into()),
                settings: vec![("max_threads".into(), "2".into())],
            }
        );
    }

    #[test]
    fn fills_in_the_default_host_and_port() {
        let target = parse_url("clickhouse://").unwrap();
        assert_eq!(target.endpoint, "http://localhost:8123");
        assert_eq!(target.user, None);
        assert_eq!(target.database, None);
    }

    #[test]
    fn unwraps_nullable_and_low_cardinality() {
        assert_eq!(base_type("Nullable(Int32)"), "Int32");
        assert_eq!(base_type("LowCardinality(Nullable(String))"), "String");
        assert_eq!(
            base_type("Array(Nullable(String))"),
            "Array(Nullable(String))"
        );
    }

    #[test]
    fn decodes_values_by_type() {
        assert_eq!(decode("UInt8", "7".into()), Cell::Int(7));
        assert_eq!(
            decode("UInt64", "18446744073709551615".into()),
            Cell::Decimal("18446744073709551615".into())
        );
        assert_eq!(decode("Float64", "1.5".into()), Cell::Float(1.5));
        assert_eq!(
            decode("Decimal(10, 2)", "1.10".into()),
            Cell::Decimal("1.10".into())
        );
        assert_eq!(decode("Bool", "true".into()), Cell::Bool(true));
        assert_eq!(
            decode("DateTime64(3)", "2024-01-01 00:00:00.000".into()),
            Cell::Timestamp("2024-01-01 00:00:00.000".into())
        );
        assert_eq!(
            decode("Array(String)", "['a']".into()),
            Cell::Text("['a']".into())
        );
    }
}
