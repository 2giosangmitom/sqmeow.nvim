//! The ScyllaDB adapter, which speaks to Apache Cassandra as well.

use std::sync::Arc;
use std::time::Instant;

use futures_util::StreamExt;
use percent_encoding::percent_decode_str;
use scylla::client::session::Session;
use scylla::client::session_builder::SessionBuilder;
use scylla::cluster::metadata::ColumnKind;
use scylla::deserialize::row::DeserializeRow;
use scylla::frame::response::result::{CollectionType, ColumnType};
use scylla::serialize::row::SerializeRow;
use scylla::value::{CqlValue, Row};
use sqlx::types::BigDecimal;
use sqlx::types::chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, KeyKind, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode, Source, TableBinder, TableName,
};
use tokio_util::sync::CancellationToken;

const DEFAULT_PORT: u16 = 9042;

/// One session with a ScyllaDB or Cassandra cluster.
pub struct ScyllaAdapter {
    session: Session,
}

impl std::fmt::Debug for ScyllaAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScyllaAdapter").finish_non_exhaustive()
    }
}

/// What a `scylla://` URL asks for.
#[derive(Debug, PartialEq)]
struct Target {
    hosts: Vec<String>,
    credentials: Option<(String, String)>,
    keyspace: Option<String>,
    /// Whether to speak TLS.
    tls: bool,
    /// A CA certificate file to trust besides the machine's roots.
    ca: Option<String>,
}

impl ScyllaAdapter {
    /// Open a session on the hosts the URL names, in its keyspace if it names one.
    pub async fn connect(url: &str) -> Result<Self> {
        let target = parse_url(url)?;
        let mut builder = SessionBuilder::new()
            .known_nodes(&target.hosts)
            .connection_timeout(crate::CONNECT_TIMEOUT);
        if let Some((user, password)) = target.credentials {
            builder = builder.user(user, password);
        }
        if let Some(keyspace) = target.keyspace {
            builder = builder.use_keyspace(keyspace, true);
        }
        if target.tls {
            builder = builder.tls_context(Some(tls_config(target.ca.as_deref())?));
        }

        let session = tokio::time::timeout(crate::CONNECT_TIMEOUT, builder.build())
            .await
            .map_err(|_| Error::driver("timed out connecting to the cluster"))?
            .map_err(Error::driver)?;
        Ok(Self { session })
    }

    /// Run a metadata query and read every row as `T`.
    async fn rows<T>(&self, cql: &str, values: impl SerializeRow) -> Result<Vec<T>>
    where
        T: for<'frame, 'metadata> DeserializeRow<'frame, 'metadata>,
    {
        self.session
            .query_unpaged(cql, values)
            .await
            .map_err(Error::driver)?
            .into_rows_result()
            .map_err(Error::driver)?
            .rows::<T>()
            .map_err(Error::driver)?
            .collect::<std::result::Result<_, _>>()
            .map_err(Error::driver)
    }

    /// Mark the result columns that are the table's own, and name the table when its whole
    /// primary key is among them.
    async fn source(&self, keyspace: &str, table: &str, columns: &mut [Column]) -> Option<Source> {
        let known = |state: &scylla::cluster::ClusterState| {
            state
                .get_keyspace(keyspace)
                .is_some_and(|k| k.tables.contains_key(table))
        };
        // A table created a moment ago may not be in the driver's picture yet.
        if !known(&self.session.get_cluster_state()) {
            self.session.refresh_metadata().await.ok()?;
        }
        let state = self.session.get_cluster_state();
        let meta = state.get_keyspace(keyspace)?.tables.get(table)?;

        let name = TableName::new(Some(keyspace), table);
        let mut binder = TableBinder::default();
        for (index, column) in columns.iter_mut().enumerate() {
            let Some(found) = meta.columns.get(&column.name) else {
                continue;
            };
            binder.bind(index, name.clone(), column.name.clone());
            if matches!(
                found.kind,
                ColumnKind::PartitionKey | ColumnKind::Clustering
            ) {
                column.key = KeyKind::Primary;
            }
        }
        binder.build(|_| {
            vec![
                meta.partition_key
                    .iter()
                    .chain(&meta.clustering_key)
                    .cloned()
                    .collect(),
            ]
        })
    }

    async fn read(&self, statement: &str, max_rows: usize) -> Result<ResultSet> {
        let started = Instant::now();
        let pager = self
            .session
            .query_iter(statement, ())
            .await
            .map_err(Error::driver)?;

        let specs = pager.column_specs();
        let mut columns: Vec<Column> = specs
            .iter()
            .map(|spec| Column::new(spec.name(), type_name(spec.typ())))
            .collect();
        let table = specs.iter().next().map(|spec| {
            let table = spec.table_spec();
            (table.ks_name().to_owned(), table.table_name().to_owned())
        });
        let source = match table {
            Some((keyspace, table)) => self.source(&keyspace, &table, &mut columns).await,
            None => None,
        };

        let mut result = ResultSet::new(statement, columns);
        result.set_source(source);
        let mut rows = pager.rows_stream::<Row>().map_err(Error::driver)?;
        while let Some(row) = rows.next().await {
            let row = row.map_err(Error::driver)?;
            if result.row_count() >= max_rows {
                result.mark_truncated();
                break;
            }
            result.push_row(
                row.columns
                    .into_iter()
                    .map(|value| value.map_or(Cell::Null, decode))
                    .collect(),
            );
        }

        result.set_elapsed(started.elapsed());
        Ok(result)
    }
}

impl Adapter for ScyllaAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Scylla
    }

    /// One statement after another, since CQL has no transactions.
    async fn apply(&self, statements: &[String]) -> Result<Vec<ResultSet>> {
        for (done, statement) in statements.iter().enumerate() {
            let failed = |error: String| {
                Error::driver(format!(
                    "{done} of {} statements were applied before one failed: {error}\nin: {statement}",
                    statements.len()
                ))
            };
            let reply = self
                .session
                .query_unpaged(statement.as_str(), ())
                .await
                .map_err(|error| failed(error.to_string()))?;
            // `IF EXISTS` answers `[applied]`, false when the row is gone.
            if let Ok(rows) = reply.into_rows_result()
                && let Ok(Some(row)) = rows.maybe_first_row::<Row>()
                && matches!(row.columns.first(), Some(Some(CqlValue::Boolean(false))))
            {
                return Err(failed("no row had that key any more".to_owned()));
            }
        }
        Ok(Vec::new())
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<sqmeow_db::IndexNode>> {
        let mut rows = self
            .rows::<(String, std::collections::HashMap<String, String>)>(
                "select index_name, options from system_schema.indexes
                 where keyspace_name = ? and table_name = ?",
                (schema, relation),
            )
            .await?;
        rows.sort_by(|a, b| a.0.cmp(&b.0));

        // The primary key is no index CQL lists, but it is how a row is found.
        let mut key = self
            .rows::<(String, String, i32)>(
                "select column_name, kind, position from system_schema.columns
                 where keyspace_name = ? and table_name = ?",
                (schema, relation),
            )
            .await?;
        key.retain(|(_, kind, _)| kind == "partition_key" || kind == "clustering");
        key.sort_by_key(|(_, kind, position)| (kind != "partition_key", *position));
        let primary = (!key.is_empty()).then(|| sqmeow_db::IndexNode {
            name: "PRIMARY KEY".to_owned(),
            columns: key.into_iter().map(|(name, ..)| name).collect(),
            unique: true,
            primary: true,
        });

        Ok(primary
            .into_iter()
            .chain(
                rows.into_iter()
                    .map(|(name, options)| sqmeow_db::IndexNode {
                        name,
                        // What the index is on, such as `v` or `keys(m)`.
                        columns: options.get("target").cloned().into_iter().collect(),
                        unique: false,
                        primary: false,
                    }),
            )
            .collect())
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        // Dropping the pager stops fetching pages.
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(Error::Cancelled),
            result = self.read(statement, max_rows) => result,
        }
    }

    /// Every keyspace but the system ones.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        let current = self.session.get_keyspace();
        let mut schemas: Vec<SchemaNode> = self
            .rows::<(String,)>("select keyspace_name from system_schema.keyspaces", ())
            .await?
            .into_iter()
            .filter(|(name,)| name != "system" && !name.starts_with("system_"))
            .map(|(name,)| SchemaNode {
                is_default: current.as_deref() == Some(&name),
                name,
            })
            .collect();
        schemas.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(schemas)
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let tables = self
            .rows::<(String,)>(
                "select table_name from system_schema.tables where keyspace_name = ?",
                (schema,),
            )
            .await?;
        let views = self
            .rows::<(String,)>(
                "select view_name from system_schema.views where keyspace_name = ?",
                (schema,),
            )
            .await?;

        let mut relations: Vec<RelationNode> = tables
            .into_iter()
            .map(|(name,)| RelationNode {
                name,
                kind: RelationKind::Table,
            })
            .chain(views.into_iter().map(|(name,)| RelationNode {
                name,
                kind: RelationKind::MaterializedView,
            }))
            .collect();
        relations.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(relations)
    }

    /// User-defined functions and aggregates.
    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        let mut names: Vec<String> = Vec::new();
        for cql in [
            "select function_name from system_schema.functions where keyspace_name = ?",
            "select aggregate_name from system_schema.aggregates where keyspace_name = ?",
        ] {
            names.extend(
                self.rows::<(String,)>(cql, (schema,))
                    .await?
                    .into_iter()
                    .map(|(name,)| name),
            );
        }
        // An overloaded function is listed once.
        names.sort();
        names.dedup();
        Ok(names
            .into_iter()
            .map(|name| crate::routine_node(name, "function"))
            .collect())
    }

    /// Partition key, clustering key, then the rest by name, the order `select *` returns them in.
    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let mut rows = self
            .rows::<(String, String, String, i32)>(
                "select column_name, kind, type, position from system_schema.columns
                 where keyspace_name = ? and table_name = ?",
                (schema, relation),
            )
            .await?;
        let rank = |kind: &str| match kind {
            "partition_key" => 0,
            "clustering" => 1,
            "static" => 2,
            _ => 3,
        };
        rows.sort_by(|a, b| (rank(&a.1), a.3, &a.0).cmp(&(rank(&b.1), b.3, &b.0)));

        Ok(rows
            .into_iter()
            .map(|(name, kind, type_name, _)| {
                let primary_key = rank(&kind) < 2;
                ColumnNode {
                    name,
                    type_name,
                    nullable: !primary_key,
                    primary_key,
                    foreign_key: None,
                    default: None,
                }
            })
            .collect())
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<sqmeow_db::Details> {
        let comment = self
            .rows::<(Option<String>,)>(
                "select comment from system_schema.tables where keyspace_name = ? and table_name = ?",
                (schema, relation),
            )
            .await?
            .into_iter()
            .find_map(|(comment,)| comment.filter(|comment| !comment.is_empty()));
        // The server answers DESCRIBE from ScyllaDB 5 and Cassandra 4 on.
        let describe = format!(
            "DESCRIBE TABLE {}.{}",
            self.quote_ident(schema),
            self.quote_ident(relation)
        );
        let definition = match self.session.query_unpaged(describe, ()).await {
            Ok(reply) => reply.into_rows_result().ok().and_then(|rows| {
                rows.rows::<(String, String, String, String)>()
                    .ok()?
                    .filter_map(std::result::Result::ok)
                    .map(|(.., statement)| statement)
                    .next()
            }),
            Err(error) => {
                tracing::debug!(%error, "could not describe a table");
                None
            }
        };
        Ok(sqmeow_db::Details {
            properties: comment
                .map(|comment| ("comment".to_owned(), comment))
                .into_iter()
                .collect(),
            definition,
            ..sqmeow_db::Details::default()
        })
    }

    async fn close(&self) {}
}

/// A TLS configuration trusting the machine's roots and the certificates in the `ca` file.
fn tls_config(ca: Option<&str>) -> Result<Arc<rustls::ClientConfig>> {
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_native_certs::load_native_certs().certs {
        // A root the machine holds that rustls cannot read is one fewer to trust, not a failure.
        let _ = roots.add(certificate);
    }
    if let Some(path) = ca {
        use rustls::pki_types::CertificateDer;
        use rustls::pki_types::pem::PemObject;

        let certificates = CertificateDer::pem_file_iter(path)
            .map_err(|error| Error::driver(format!("`{path}` could not be read: {error}")))?;
        for certificate in certificates {
            let certificate = certificate.map_err(|error| {
                Error::driver(format!("`{path}` holds no certificate: {error}"))
            })?;
            roots.add(certificate).map_err(Error::driver)?;
        }
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(Error::driver)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(config))
}

/// Read the hosts, login, keyspace and TLS options from
/// `scylla://user:password@host1,host2:9042/keyspace?ssl=true&sslrootcert=ca.pem`.
fn parse_url(url: &str) -> Result<Target> {
    let rest = url
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let (rest, options) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, keyspace) = rest.split_once('/').unwrap_or((rest, ""));
    let (login, hosts) = match authority.rsplit_once('@') {
        Some((login, hosts)) => (Some(login), hosts),
        None => (None, authority),
    };

    let decode = |text: &str| {
        percent_decode_str(text)
            .decode_utf8()
            .map(|text| text.into_owned())
            .map_err(Error::driver)
    };
    let mut tls = false;
    let mut ca = None;
    for option in options.split('&').filter(|option| !option.is_empty()) {
        let (key, value) = option.split_once('=').unwrap_or((option, ""));
        match key {
            "ssl" | "tls" => tls = matches!(value, "true" | "1" | "yes"),
            "sslrootcert" => {
                tls = true;
                ca = Some(decode(value)?);
            }
            other => {
                return Err(Error::driver(format!(
                    "a ScyllaDB url takes `ssl` and `sslrootcert`, not `{other}`"
                )));
            }
        }
    }
    let credentials = login
        .map(|login| {
            let (user, password) = login.split_once(':').unwrap_or((login, ""));
            Ok::<_, Error>((decode(user)?, decode(password)?))
        })
        .transpose()?;
    let hosts = hosts
        .split(',')
        .map(|host| {
            let host = if host.is_empty() { "localhost" } else { host };
            // A bracketed IPv6 address has colons of its own.
            if host.ends_with(']') || !host.contains(':') {
                format!("{host}:{DEFAULT_PORT}")
            } else {
                host.to_owned()
            }
        })
        .collect();
    let keyspace = (!keyspace.is_empty())
        .then(|| decode(keyspace))
        .transpose()?;

    Ok(Target {
        hosts,
        credentials,
        keyspace,
        tls,
        ca,
    })
}

/// A result column's type as CQL writes it.
fn type_name(typ: &ColumnType<'_>) -> String {
    let join = |types: &mut dyn Iterator<Item = &ColumnType<'_>>| {
        types.map(type_name).collect::<Vec<_>>().join(", ")
    };
    match typ {
        ColumnType::Native(native) => format!("{native:?}").to_ascii_lowercase(),
        ColumnType::Collection { typ, .. } => match typ {
            CollectionType::List(item) => format!("list<{}>", type_name(item)),
            CollectionType::Set(item) => format!("set<{}>", type_name(item)),
            CollectionType::Map(key, value) => {
                format!("map<{}, {}>", type_name(key), type_name(value))
            }
            _ => "collection".to_owned(),
        },
        ColumnType::Vector { typ, dimensions } => {
            format!("vector<{}, {dimensions}>", type_name(typ))
        }
        ColumnType::UserDefinedType { definition, .. } => definition.name.to_string(),
        ColumnType::Tuple(items) => format!("tuple<{}>", join(&mut items.iter())),
        _ => "unknown".to_owned(),
    }
}

fn decode(value: CqlValue) -> Cell {
    match value {
        CqlValue::Ascii(text) | CqlValue::Text(text) => Cell::Text(text),
        CqlValue::Boolean(v) => Cell::Bool(v),
        CqlValue::Blob(bytes) => Cell::bytes(&bytes),
        CqlValue::Counter(counter) => Cell::Int(counter.0),
        CqlValue::Decimal(v) => Cell::Decimal(BigDecimal::from(v).to_string()),
        CqlValue::Varint(v) => Cell::Decimal(BigDecimal::new(v.into(), 0).to_string()),
        CqlValue::Double(v) => Cell::Float(v),
        CqlValue::Float(v) => Cell::Float(v.into()),
        CqlValue::Int(v) => Cell::Int(v.into()),
        CqlValue::BigInt(v) => Cell::Int(v),
        CqlValue::SmallInt(v) => Cell::Int(v.into()),
        CqlValue::TinyInt(v) => Cell::Int(v.into()),
        CqlValue::Timestamp(v) => match TryInto::<DateTime<Utc>>::try_into(v) {
            // An offset CQL reads back, so the value can find its row again.
            Ok(time) => Cell::Timestamp(time.format("%Y-%m-%d %H:%M:%S%.3f%z").to_string()),
            Err(_) => unsupported("timestamp", v.0),
        },
        CqlValue::Date(v) => match TryInto::<NaiveDate>::try_into(v) {
            Ok(date) => Cell::Date(date.to_string()),
            Err(_) => unsupported("date", v.0),
        },
        CqlValue::Time(v) => match TryInto::<NaiveTime>::try_into(v) {
            Ok(time) => Cell::Time(time.to_string()),
            Err(_) => unsupported("time", v.0),
        },
        CqlValue::Uuid(v) => Cell::Uuid(v.to_string()),
        CqlValue::Timeuuid(v) => Cell::Uuid(v.to_string()),
        CqlValue::Inet(v) => Cell::Text(v.to_string()),
        CqlValue::Empty => Cell::Text(String::new()),
        CqlValue::Duration(_) => Cell::Text(value.to_string()),
        other => Cell::Json(json(other).to_string()),
    }
}

fn unsupported(type_name: &str, raw: impl ToString) -> Cell {
    Cell::Unsupported {
        type_name: type_name.to_owned(),
        raw: raw.to_string(),
    }
}

/// A collection, tuple or user-defined type as JSON.
fn json(value: CqlValue) -> serde_json::Value {
    use serde_json::Value as Json;

    let field = |value: Option<CqlValue>| value.map_or(Json::Null, json);
    match value {
        CqlValue::List(items) | CqlValue::Set(items) | CqlValue::Vector(items) => {
            items.into_iter().map(json).collect()
        }
        CqlValue::Tuple(items) => items.into_iter().map(field).collect(),
        CqlValue::Map(entries) => entries
            .into_iter()
            .map(|(key, value)| {
                let key = match json(key) {
                    Json::String(text) => text,
                    other => other.to_string(),
                };
                (key, json(value))
            })
            .collect(),
        CqlValue::UserDefinedType { fields, .. } => fields
            .into_iter()
            .map(|(name, value)| (name, field(value)))
            .collect(),
        scalar => match decode(scalar) {
            Cell::Bool(v) => v.into(),
            Cell::Int(v) => v.into(),
            Cell::Float(v) => v.into(),
            cell => cell.text("").into_owned().into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_hosts_login_and_keyspace_from_the_url() {
        assert_eq!(
            parse_url("scylla://u%40x:p%3As@a,b:9043,[::1]/shop").unwrap(),
            Target {
                hosts: vec!["a:9042".into(), "b:9043".into(), "[::1]:9042".into()],
                credentials: Some(("u@x".into(), "p:s".into())),
                keyspace: Some("shop".into()),
                tls: false,
                ca: None,
            }
        );
        assert_eq!(
            parse_url("cassandra://").unwrap(),
            Target {
                hosts: vec!["localhost:9042".into()],
                credentials: None,
                keyspace: None,
                tls: false,
                ca: None,
            }
        );
    }

    #[test]
    fn a_url_turns_tls_on_and_names_a_ca_file() {
        let target = parse_url("scylla://h/ks?ssl=true").unwrap();
        assert!(target.tls);
        assert_eq!(target.ca, None);

        let target = parse_url("scylla://h/ks?sslrootcert=%2Fetc%2Fca.pem").unwrap();
        assert!(target.tls);
        assert_eq!(target.ca.as_deref(), Some("/etc/ca.pem"));

        let error = parse_url("scylla://h/ks?compression=lz4").unwrap_err();
        assert!(error.to_string().contains("compression"), "{error}");
    }

    #[test]
    fn a_tls_configuration_trusts_the_machine_and_refuses_a_missing_ca_file() {
        assert!(tls_config(None).is_ok());
        let error = tls_config(Some("/nonexistent/ca.pem")).unwrap_err();
        assert!(error.to_string().contains("/nonexistent/ca.pem"), "{error}");
    }
}
