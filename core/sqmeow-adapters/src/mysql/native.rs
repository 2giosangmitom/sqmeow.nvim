//! Native wire protocol, value conversion, and independent catalogue reads.
use crate::stream::Origin;
use mysql_async::{
    Column as WireColumn, Conn, Opts, OptsBuilder, Params, Value,
    consts::{ColumnFlags, ColumnType},
    prelude::{FromRow, FromValue, Queryable},
};
use sqmeow_db::{
    error::{Error, Result},
    result::{Column, ResultSet},
    value::Cell,
};
use tokio::sync::Mutex;

pub(super) type Session = Mutex<Option<Conn>>;

#[derive(Debug)]
pub(super) struct Row(mysql_async::Row);
impl Row {
    pub(super) fn try_get<T: FromValue, I: mysql_async::prelude::ColumnIndex>(
        &self,
        index: I,
    ) -> std::result::Result<T, String> {
        self.0
            .get_opt(index)
            .ok_or_else(|| "missing column".to_owned())?
            .map_err(|error| error.to_string())
    }
}

pub(super) struct Query<T> {
    sql: String,
    values: Vec<Value>,
    marker: std::marker::PhantomData<T>,
}
pub(super) fn query(sql: impl Into<String>) -> Query<Row> {
    Query::new(sql)
}
pub(super) fn query_as<T: FromRow>(sql: impl Into<String>) -> Query<T> {
    Query::new(sql)
}
pub(super) fn query_scalar<T: FromValue>(sql: impl Into<String>) -> Query<(T,)> {
    Query::new(sql)
}
impl<T> Query<T> {
    fn new(sql: impl Into<String>) -> Self {
        Self {
            sql: sql.into(),
            values: Vec::new(),
            marker: std::marker::PhantomData,
        }
    }
    pub(super) fn bind(mut self, value: impl Into<Value>) -> Self {
        self.values.push(value.into());
        self
    }
    async fn rows(self, session: &Session) -> std::result::Result<Vec<mysql_async::Row>, String> {
        let mut session = session.lock().await;
        let connection = session.as_mut().ok_or("connection is closed")?;
        if self.values.is_empty() {
            connection.query(self.sql).await.map_err(|e| e.to_string())
        } else {
            let prepared = connection.prep(self.sql).await.map_err(|e| e.to_string())?;
            let rows = connection
                .exec(&prepared, Params::Positional(self.values))
                .await;
            let closed = connection.close(prepared).await;
            let rows = rows.map_err(|e| e.to_string())?;
            closed.map_err(|e| e.to_string())?;
            Ok(rows)
        }
    }
}
impl Query<Row> {
    pub(super) async fn fetch_all(
        self,
        session: &Session,
    ) -> std::result::Result<Vec<Row>, String> {
        Ok(self.rows(session).await?.into_iter().map(Row).collect())
    }
    pub(super) async fn fetch_optional(
        self,
        session: &Session,
    ) -> std::result::Result<Option<Row>, String> {
        Ok(self.fetch_all(session).await?.into_iter().next())
    }
}
impl<T: FromRow> Query<T> {
    pub(super) async fn fetch_all(self, session: &Session) -> std::result::Result<Vec<T>, String> {
        self.rows(session)
            .await?
            .into_iter()
            .map(|row| mysql_async::from_row_opt(row).map_err(|e| e.to_string()))
            .collect()
    }
}
impl<T: FromValue> Query<(T,)> {
    pub(super) async fn fetch_optional(
        self,
        session: &Session,
    ) -> std::result::Result<Option<T>, String> {
        Ok(self
            .fetch_all(session)
            .await?
            .into_iter()
            .next()
            .map(|(value,)| value))
    }
}
pub(super) fn foreign_key(row: &Row) -> Option<sqmeow_db::types::ForeignKey> {
    Some(sqmeow_db::types::ForeignKey {
        table: row
            .try_get::<Option<String>, _>("references_table")
            .ok()??,
        column: row
            .try_get::<Option<String>, _>("references_column")
            .ok()??,
    })
}

pub(super) fn origins(columns: &[WireColumn]) -> Vec<Origin> {
    columns
        .iter()
        .map(|column| {
            let table = column.org_table_str();
            let name = column.org_name_str();
            if table.is_empty() || name.is_empty() {
                return None;
            }
            Some((
                sqmeow_db::edit::TableName {
                    schema: (!column.schema_str().is_empty())
                        .then(|| column.schema_str().into_owned()),
                    name: table.into_owned(),
                },
                name.into_owned(),
            ))
        })
        .collect()
}

fn type_name(column: &WireColumn) -> String {
    use ColumnType::*;
    let name = match column.column_type() {
        MYSQL_TYPE_TINY => "TINYINT",
        MYSQL_TYPE_SHORT => "SMALLINT",
        MYSQL_TYPE_LONG => "INT",
        MYSQL_TYPE_INT24 => "MEDIUMINT",
        MYSQL_TYPE_LONGLONG => "BIGINT",
        MYSQL_TYPE_FLOAT => "FLOAT",
        MYSQL_TYPE_DOUBLE => "DOUBLE",
        MYSQL_TYPE_DECIMAL | MYSQL_TYPE_NEWDECIMAL => "DECIMAL",
        MYSQL_TYPE_DATE | MYSQL_TYPE_NEWDATE => "DATE",
        MYSQL_TYPE_TIME | MYSQL_TYPE_TIME2 => "TIME",
        MYSQL_TYPE_TIMESTAMP | MYSQL_TYPE_TIMESTAMP2 => "TIMESTAMP",
        MYSQL_TYPE_DATETIME | MYSQL_TYPE_DATETIME2 => "DATETIME",
        MYSQL_TYPE_YEAR => "YEAR",
        MYSQL_TYPE_BIT => "BIT",
        MYSQL_TYPE_JSON => "JSON",
        MYSQL_TYPE_GEOMETRY => "GEOMETRY",
        MYSQL_TYPE_ENUM => "ENUM",
        MYSQL_TYPE_SET => "SET",
        MYSQL_TYPE_NULL => "NULL",
        MYSQL_TYPE_TINY_BLOB | MYSQL_TYPE_MEDIUM_BLOB | MYSQL_TYPE_LONG_BLOB | MYSQL_TYPE_BLOB => {
            if column.character_set() == 63 {
                "BLOB"
            } else {
                "TEXT"
            }
        }
        _ => {
            if column.character_set() == 63 {
                "VARBINARY"
            } else {
                "VARCHAR"
            }
        }
    };
    if column.flags().contains(ColumnFlags::UNSIGNED_FLAG)
        && matches!(
            name,
            "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT"
        )
    {
        format!("{name} UNSIGNED")
    } else {
        name.to_owned()
    }
}
pub(super) fn result_columns(columns: &[WireColumn]) -> Vec<Column> {
    columns
        .iter()
        .map(|column| Column::new(column.name_str(), type_name(column)))
        .collect()
}
fn unsigned(value: u64) -> Cell {
    i64::try_from(value).map_or_else(|_| Cell::Decimal(value.to_string()), Cell::Int)
}
fn timestamp(text: &str, timezone: &str) -> Cell {
    // Named zones (including SYSTEM) do not tell us the offset at this instant.
    let offset = timezone
        .strip_prefix('+')
        .or_else(|| timezone.strip_prefix('-'))
        .and_then(|offset| offset.split_once(':'))
        .filter(|(hours, minutes)| {
            !hours.is_empty()
                && hours.len() <= 2
                && minutes.len() == 2
                && hours
                    .chars()
                    .chain(minutes.chars())
                    .all(|c| c.is_ascii_digit())
        })
        .and_then(|(hours, minutes)| Some((hours.parse::<u8>().ok()?, minutes.parse::<u8>().ok()?)))
        .filter(|(hours, minutes)| *hours <= 14 && *minutes < 60);
    Cell::Timestamp(match offset {
        Some((0, 0)) => format!("{text} UTC"),
        Some(_) => format!("{text} {timezone}"),
        None => text.to_owned(),
    })
}

fn decode(value: &Value, column: &WireColumn, timezone: &str) -> Cell {
    use ColumnType::*;
    if matches!(value, Value::NULL) {
        return Cell::Null;
    }
    let bytes = match value {
        Value::Bytes(bytes) => Some(bytes.as_slice()),
        _ => None,
    };
    let text = bytes.and_then(|bytes| std::str::from_utf8(bytes).ok());
    match column.column_type() {
        MYSQL_TYPE_TINY | MYSQL_TYPE_SHORT | MYSQL_TYPE_LONG | MYSQL_TYPE_INT24
        | MYSQL_TYPE_LONGLONG | MYSQL_TYPE_YEAR => {
            return if column.flags().contains(ColumnFlags::UNSIGNED_FLAG) {
                mysql_async::from_value_opt::<u64>(value.clone())
                    .map(unsigned)
                    .unwrap_or(Cell::Null)
            } else {
                mysql_async::from_value_opt::<i64>(value.clone())
                    .map(Cell::Int)
                    .unwrap_or(Cell::Null)
            };
        }
        MYSQL_TYPE_FLOAT | MYSQL_TYPE_DOUBLE => {
            return mysql_async::from_value_opt::<f64>(value.clone())
                .map(Cell::Float)
                .unwrap_or(Cell::Null);
        }
        MYSQL_TYPE_NEWDECIMAL | MYSQL_TYPE_DECIMAL => {
            if let Some(text) = text {
                return Cell::Decimal(text.to_owned());
            }
        }
        MYSQL_TYPE_JSON => {
            if let Some(text) = text {
                return Cell::Json(
                    serde_json::from_str::<serde_json::Value>(text)
                        .map_or_else(|_| text.to_owned(), |value| value.to_string()),
                );
            }
        }
        MYSQL_TYPE_BIT => {
            if let Some(bytes) = bytes
                && bytes.len() <= 8
            {
                return unsigned(bytes.iter().fold(0, |n, b| (n << 8) | u64::from(*b)));
            }
        }
        MYSQL_TYPE_DATE | MYSQL_TYPE_NEWDATE => {
            if let Some(text) = text {
                return Cell::Date(text.to_owned());
            }
        }
        MYSQL_TYPE_TIME | MYSQL_TYPE_TIME2 => {
            if let Some(text) = text {
                return Cell::Time(text.to_owned());
            }
        }
        MYSQL_TYPE_DATETIME
        | MYSQL_TYPE_DATETIME2
        | MYSQL_TYPE_TIMESTAMP
        | MYSQL_TYPE_TIMESTAMP2 => {
            if let Some(text) = text {
                return if matches!(
                    column.column_type(),
                    MYSQL_TYPE_TIMESTAMP | MYSQL_TYPE_TIMESTAMP2
                ) {
                    timestamp(text, timezone)
                } else {
                    Cell::Timestamp(text.to_owned())
                };
            }
        }
        _ => {}
    }
    match value {
        Value::NULL => Cell::Null,
        Value::Int(value) => Cell::Int(*value),
        Value::UInt(value) => unsigned(*value),
        Value::Float(value) => Cell::Float(f64::from(*value)),
        Value::Double(value) => Cell::Float(*value),
        Value::Bytes(bytes) => {
            if column.column_type() == MYSQL_TYPE_GEOMETRY {
                Cell::bytes(bytes)
            } else {
                super::binary(bytes.clone())
            }
        }
        Value::Date(year, month, day, hour, minute, second, micros) => {
            let date = format!("{year:04}-{month:02}-{day:02}");
            if matches!(column.column_type(), MYSQL_TYPE_DATE | MYSQL_TYPE_NEWDATE) {
                return Cell::Date(date);
            }
            let fraction = if *micros == 0 {
                String::new()
            } else {
                format!(".{micros:06}").trim_end_matches('0').to_owned()
            };
            let stamp = format!("{date} {hour:02}:{minute:02}:{second:02}{fraction}");
            if matches!(
                column.column_type(),
                MYSQL_TYPE_TIMESTAMP | MYSQL_TYPE_TIMESTAMP2
            ) {
                timestamp(&stamp, timezone)
            } else {
                Cell::Timestamp(stamp)
            }
        }
        Value::Time(negative, days, hours, minute, second, micros) => {
            let fraction = if *micros == 0 {
                String::new()
            } else {
                format!(".{micros:06}").trim_end_matches('0').to_owned()
            };
            Cell::Time(format!(
                "{}{:02}:{minute:02}:{second:02}{fraction}",
                if *negative { "-" } else { "" },
                days * 24 + u32::from(*hours)
            ))
        }
    }
}

fn execution_error(error: mysql_async::Error) -> Error {
    if matches!(&error, mysql_async::Error::Server(server) if server.code == 1317) {
        Error::Cancelled
    } else {
        Error::driver(error)
    }
}

pub(super) type Results = Vec<(ResultSet, Vec<Origin>)>;

async fn collect<P: mysql_async::prelude::Protocol>(
    mut output: mysql_async::QueryResult<'_, '_, P>,
    statement: &str,
    max_rows: usize,
    timezone: &str,
) -> Result<Results> {
    let mut results = Vec::new();
    let mut result = ResultSet::new(statement, result_columns(output.columns_ref()));
    let mut provenance = origins(output.columns_ref());
    loop {
        let affected = output.affected_rows();
        match output.next().await.map_err(execution_error)? {
            Some(row) => {
                if result.row_count() >= max_rows {
                    result.mark_truncated();
                } else {
                    result.push_row(
                        (0..row.len())
                            .map(|i| decode(&row[i], &row.columns_ref()[i], timezone))
                            .collect(),
                    );
                }
            }
            None => {
                result.set_affected(affected);
                results.push((result, provenance));
                if output.is_empty() {
                    break;
                }
                result = ResultSet::new(statement, result_columns(output.columns_ref()));
                provenance = origins(output.columns_ref());
            }
        }
    }
    output.drop_result().await.map_err(Error::driver)?;
    Ok(results)
}
pub(super) async fn execute(
    connection: &mut Conn,
    statement: &str,
    values: Option<&[sqmeow_db::sql::parameters::Value]>,
    max_rows: usize,
    cancel: &tokio_util::sync::CancellationToken,
    timezone: &str,
) -> Result<Results> {
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    if let Some(values) = values {
        use sqmeow_db::sql::parameters::Value as Bound;
        let values = values
            .iter()
            .map(|value| match value {
                Bound::Text(value) => Value::Bytes(value.as_bytes().to_vec()),
                Bound::Int(value) => Value::Int(*value),
                Bound::Float(value) => Value::Double(*value),
                Bound::Bool(value) => Value::Int(i64::from(*value)),
                Bound::Null(_) => Value::NULL,
            })
            .collect::<Vec<_>>();
        let prepared = connection.prep(statement).await.map_err(execution_error)?;
        let outcome = async {
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            let output = connection
                .exec_iter(&prepared, Params::Positional(values))
                .await
                .map_err(execution_error)?;
            collect(output, statement, max_rows, timezone).await
        }
        .await;
        let closed = connection.close(prepared).await;
        let result = outcome?;
        closed.map_err(execution_error)?;
        Ok(result)
    } else {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        collect(
            connection
                .query_iter(statement)
                .await
                .map_err(execution_error)?,
            statement,
            max_rows,
            timezone,
        )
        .await
    }
}

pub(super) fn retryable(error: &mysql_async::Error) -> bool {
    matches!(error, mysql_async::Error::Io(mysql_async::IoError::Io(error)) if matches!(error.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::TimedOut | std::io::ErrorKind::ConnectionAborted))
}

pub(super) async fn connect(options: Opts, preferred: bool) -> mysql_async::Result<Conn> {
    let open = async {
        match Conn::new(options.clone()).await {
            // This fails before authentication or SQL execution. PREFERRED permits plaintext
            // only when the server handshake explicitly says TLS is unavailable.
            Err(mysql_async::Error::Driver(
                mysql_async::DriverError::NoClientSslFlagFromServer,
            )) if preferred => Conn::new(OptsBuilder::from_opts(options).ssl_opts(None)).await,
            outcome => outcome,
        }
    };
    tokio::time::timeout(crate::CONNECT_TIMEOUT, open)
        .await
        .unwrap_or_else(|_| {
            Err(mysql_async::Error::Io(mysql_async::IoError::Io(
                std::io::Error::new(std::io::ErrorKind::TimedOut, "MySQL connection timed out"),
            )))
        })
}

pub(super) fn options(input: &str) -> Result<(Opts, bool, String)> {
    let mut url = url::Url::parse(input).map_err(Error::driver)?;
    if url.scheme() == "mariadb" {
        url.set_scheme("mysql")
            .map_err(|_| Error::driver("invalid MariaDB URL"))?;
    }
    let pairs = url
        .query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    url.set_query(None);
    let mut mode = "preferred".to_owned();
    let mut ca = None;
    let mut cert = None;
    let mut key = None;
    let mut charset = "utf8mb4".to_owned();
    let mut collation = None;
    let mut timezone = "+00:00".to_owned();
    for (name, value) in pairs {
        match name.as_str() {
            "sslmode" | "ssl-mode" => mode = value.to_ascii_lowercase().replace('_', "-"),
            "sslca" | "ssl-ca" => ca = Some(value),
            "sslcert" | "ssl-cert" => cert = Some(value),
            "sslkey" | "ssl-key" => key = Some(value),
            "charset" => charset = value,
            "collation" => collation = Some(value),
            "timezone" | "time-zone" => timezone = value,
            "statement-cache-capacity" => {
                value.parse::<usize>().map_err(Error::driver)?;
            }
            "socket" => {
                url.query_pairs_mut().append_pair("socket", &value);
            }
            _ => {
                return Err(Error::driver(format!(
                    "unsupported MySQL URL option: {name}"
                )));
            }
        }
    }
    let ssl = match mode.as_str() {
        "disabled" => None,
        "preferred" | "required" | "verify-ca" | "verify-identity" => {
            let roots = rustls_native_certs::load_native_certs();
            let mut certificates = roots
                .certs
                .into_iter()
                .map(|cert| cert.as_ref().to_vec().into())
                .collect::<Vec<_>>();
            if let Some(ca) = ca {
                certificates.push(std::path::PathBuf::from(ca).into());
            }
            let mut ssl = mysql_async::SslOpts::default()
                .with_root_certs(certificates)
                .with_disable_built_in_roots(true)
                .with_danger_accept_invalid_certs(matches!(mode.as_str(), "preferred" | "required"))
                .with_danger_skip_domain_validation(mode != "verify-identity");
            match (cert, key) {
                (Some(cert), Some(key)) => {
                    ssl = ssl.with_client_identity(Some(mysql_async::ClientIdentity::new(
                        std::path::PathBuf::from(cert).into(),
                        std::path::PathBuf::from(key).into(),
                    )))
                }
                (None, None) => {}
                _ => {
                    return Err(Error::driver(
                        "ssl-cert and ssl-key must be supplied together",
                    ));
                }
            }
            Some(ssl)
        }
        _ => return Err(Error::driver(format!("invalid MySQL ssl-mode: {mode}"))),
    };
    // Identifiers in SET NAMES are options, not arbitrary SQL.
    for value in std::iter::once(&charset).chain(collation.iter()) {
        if !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return Err(Error::driver("invalid charset or collation"));
        }
    }
    let names = format!(
        "set names {charset}{}",
        collation.map_or_else(String::new, |value| format!(" collate {value}"))
    );
    let escaped_timezone = timezone.replace('\\', "\\\\").replace('\'', "''");
    Ok((
        OptsBuilder::from_opts(Opts::from_url(url.as_str()).map_err(Error::driver)?)
            .stmt_cache_size(0)
            .prefer_socket(false)
            .client_found_rows(true)
            .ssl_opts(ssl)
            .init(vec![names, format!("set time_zone = '{escaped_timezone}'")])
            .into(),
        mode == "preferred",
        timezone,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_labels_only_known_session_offsets() {
        let text = "2026-01-02 15:04:05";
        for (zone, suffix) in [
            ("+00:00", " UTC"),
            ("-00:00", " UTC"),
            ("+08:00", " +08:00"),
            ("-05:30", " -05:30"),
            ("SYSTEM", ""),
            ("America/New_York", ""),
            ("", ""),
        ] {
            assert_eq!(
                timestamp(text, zone),
                Cell::Timestamp(format!("{text}{suffix}"))
            );
        }
    }

    #[test]
    fn url_options_preserve_verification_and_session_configuration() {
        let (options, preferred, timezone) = options("mysql://root@localhost/db?ssl-mode=VERIFY_IDENTITY&charset=utf8mb4&collation=utf8mb4_bin&timezone=%2B08:00&statement-cache-capacity=25").unwrap();
        assert_eq!(timezone, "+08:00");
        assert!(!preferred);
        let tls = options.ssl_opts().unwrap();
        assert!(!tls.accept_invalid_certs());
        assert!(!tls.skip_domain_validation());
        assert!(tls.disable_built_in_roots());
        assert_eq!(options.stmt_cache_size(), 0);
        assert!(options.client_found_rows());
        assert_eq!(
            options.init(),
            [
                "set names utf8mb4 collate utf8mb4_bin",
                "set time_zone = '+08:00'"
            ]
        );
    }

    #[test]
    fn malformed_options_do_not_silently_weaken_tls() {
        for url in [
            "mysql://root@localhost/db?ssl-mode=typo",
            "mysql://root@localhost/db?ssl-cert=cert.pem",
            "mysql://root@localhost/db?charset=utf8;drop",
            "mysql://root@localhost/db?ssl-verify=false",
        ] {
            assert!(options(url).is_err(), "{url}");
        }
    }

    #[test]
    fn mariadb_urls_use_the_mysql_protocol_options() {
        let (options, _, _) = options("mariadb://root@localhost/db?ssl-mode=disabled").unwrap();
        assert_eq!(options.db_name(), Some("db"));
        assert!(options.ssl_opts().is_none());
    }
}
