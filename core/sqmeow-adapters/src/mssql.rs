//! Microsoft SQL Server through Tiberius. A serialized session preserves temporary
//! tables, USE and SET across requests. An interrupted session is discarded;
//! failed requests are never replayed.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use futures_util::TryStreamExt;
use percent_encoding::percent_decode_str;
use sqmeow_db::adapter::Adapter;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::TableBinder;
use sqmeow_db::edit::TableName;
use sqmeow_db::error::Error;
use sqmeow_db::error::Result;
use sqmeow_db::node::ColumnNode;
use sqmeow_db::node::Details;
use sqmeow_db::node::ForeignKeyNode;
use sqmeow_db::node::IndexNode;
use sqmeow_db::node::RelationKind;
use sqmeow_db::node::RelationNode;
use sqmeow_db::node::RoleNode;
use sqmeow_db::node::RoutineNode;
use sqmeow_db::node::SchemaNode;
use sqmeow_db::result::Column;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Kind, Value};
use sqmeow_db::types::ForeignKey;
use sqmeow_db::types::KeyKind;
use sqmeow_db::value::Cell;
use tiberius::{AuthMethod, Client, ColumnData, Config, EncryptionLevel, QueryItem, Row, ToSql};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio_util::{
    compat::{Compat, TokioAsyncWriteCompatExt},
    sync::CancellationToken,
};

type Connection = Client<Compat<TcpStream>>;

enum Execution<'a> {
    Plain,
    Bound(&'a [Value]),
    Edits(&'a [String]),
}

fn parameter(value: &Value) -> &dyn ToSql {
    match value {
        Value::Text(value) => value,
        Value::Int(value) => value,
        Value::Float(value) => value,
        Value::Bool(value) => value,
        Value::Null(Kind::Auto | Kind::Text) => &None::<&str>,
        Value::Null(Kind::Int) => &None::<i64>,
        Value::Null(Kind::Float) => &None::<f64>,
        Value::Null(Kind::Bool) => &None::<bool>,
    }
}

fn parameter_declarations(values: &[Value]) -> Option<String> {
    if values.is_empty() {
        return None;
    }
    Some(
        values
            .iter()
            .enumerate()
            .map(|(index, value)| {
                // Match Tiberius's sp_executesql parameter types, including typed NULLs.
                let kind = match value {
                    Value::Text(value) if value.len() > 4000 => "nvarchar(max)",
                    Value::Text(_) | Value::Null(Kind::Auto | Kind::Text) => "nvarchar(4000)",
                    Value::Int(_) | Value::Null(Kind::Int) => "bigint",
                    Value::Float(_) | Value::Null(Kind::Float) => "float(53)",
                    Value::Bool(_) | Value::Null(Kind::Bool) => "bit",
                };
                format!("@P{} {kind}", index + 1)
            })
            .collect::<Vec<_>>()
            .join(", "),
    )
}

pub struct MsSqlAdapter {
    config: Config,
    connection: Mutex<Option<Connection>>,
    list_databases: bool,
}

impl std::fmt::Debug for MsSqlAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MsSqlAdapter").finish_non_exhaustive()
    }
}

fn parse_url(input: &str, database: Option<&str>) -> Result<(Config, bool)> {
    let url = url::Url::parse(input).map_err(|_| Error::driver("invalid MSSQL URL"))?;
    if !matches!(url.scheme(), "mssql" | "sqlserver") || url.fragment().is_some() {
        return Err(Error::driver(
            "expected mssql://user:password@host:1433/database",
        ));
    }
    let decode = |s: &str| {
        percent_decode_str(s)
            .decode_utf8()
            .map(|s| s.into_owned())
            .map_err(Error::driver)
    };
    let mut config = Config::new();
    config.host(
        url.host_str()
            .unwrap_or("localhost")
            .trim_matches(['[', ']']),
    );
    config.port(url.port().unwrap_or(1433));
    let user = decode(url.username())?;
    if user.is_empty() {
        return Err(Error::driver("MSSQL requires a SQL authentication user"));
    }
    config.authentication(AuthMethod::sql_server(
        user,
        decode(url.password().unwrap_or(""))?,
    ));
    config.application_name("sqmeow.nvim");
    config.encryption(EncryptionLevel::Required);
    let name = database
        .map(str::to_owned)
        .unwrap_or(decode(url.path().trim_start_matches('/'))?);
    if !name.is_empty() {
        config.database(&name);
    }
    let mut trust = false;
    let mut ca = None;
    let mut seen = std::collections::HashSet::new();
    for (key, value) in url.query_pairs() {
        if !seen.insert(key.to_string()) {
            return Err(Error::driver(format!("duplicate MSSQL option: {key}")));
        }
        match key.as_ref() {
            "encrypt" => config.encryption(match value.as_ref() {
                "true" | "required" => EncryptionLevel::Required,
                "false" | "off" => EncryptionLevel::Off,
                _ => {
                    return Err(Error::driver(
                        "encrypt must be true, required, false or off",
                    ));
                }
            }),
            "trust_server_certificate" => {
                trust = match value.as_ref() {
                    "true" => true,
                    "false" => false,
                    _ => {
                        return Err(Error::driver(
                            "trust_server_certificate must be true or false",
                        ));
                    }
                }
            }
            "sslrootcert" => ca = Some(value.into_owned()),
            "hostname_in_certificate" => config.hostname_in_certificate(value),
            _ => return Err(Error::driver(format!("unknown MSSQL option: {key}"))),
        }
    }
    if trust && ca.is_some() {
        return Err(Error::driver(
            "trust_server_certificate and sslrootcert cannot be combined",
        ));
    }
    if trust {
        config.trust_cert();
    }
    if let Some(ca) = ca {
        config.trust_cert_ca(ca);
    }
    Ok((config, name.is_empty()))
}

async fn open(config: &Config) -> Result<Connection> {
    tokio::time::timeout(crate::CONNECT_TIMEOUT, async {
        let tcp = TcpStream::connect(config.get_addr())
            .await
            .map_err(Error::driver)?;
        tcp.set_nodelay(true).map_err(Error::driver)?;
        Client::connect(config.clone(), tcp.compat_write())
            .await
            .map_err(Error::driver)
    })
    .await
    .map_err(|_| Error::driver("timed out connecting to SQL Server"))?
}

impl MsSqlAdapter {
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        let (config, list_databases) = parse_url(url, database)?;
        let connection = open(&config).await?;
        Ok(Self {
            config,
            connection: Mutex::new(Some(connection)),
            list_databases,
        })
    }

    async fn metadata(&self, sql: &str, params: &[&dyn ToSql]) -> Result<Vec<Row>> {
        let mut slot = self.connection.lock().await;
        if slot.is_none() {
            *slot = Some(open(&self.config).await?);
        }
        let result = rows(slot.as_mut().expect("connected"), sql, params).await;
        if result.is_err() {
            *slot = None;
        }
        result
    }

    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        if !self.list_databases {
            return None;
        }
        Some(self.metadata("SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1 ORDER BY name", &[])
            .await.map(|rows| rows.iter().map(|row| text(row, 0)).collect()))
    }

    async fn run(
        &self,
        sql: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
        execution: Execution<'_>,
    ) -> Result<Vec<ResultSet>> {
        let transaction = matches!(execution, Execution::Edits(_));
        let values = match &execution {
            Execution::Bound(values) => *values,
            _ => &[],
        };
        let params: Vec<&dyn ToSql> = values.iter().map(parameter).collect();
        let mut slot = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(Error::Cancelled),
            slot = self.connection.lock() => slot,
        };
        if slot.is_none() {
            *slot = Some(tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(Error::Cancelled),
                result = open(&self.config) => result?,
            });
        }
        let client = slot.as_mut().expect("connected");
        if transaction {
            let active = tokio::select! {
                biased;
                () = cancel.cancelled() => Err(Error::Cancelled),
                result = rows(client, "SELECT @@TRANCOUNT", &[]) => result,
            };
            match active {
                Ok(active) if active.first().and_then(|r| r.get::<i32, _>(0)).unwrap_or(0) != 0 => {
                    return Err(Error::driver(
                        "finish the current transaction before applying grid edits",
                    ));
                }
                Err(error) => {
                    *slot = None;
                    return Err(error);
                }
                _ => {}
            }
        }
        let result = tokio::select! {
            biased;
            () = cancel.cancelled() => Err(Error::Cancelled),
            result = async {
                if transaction {
                    client.begin_transaction().await.map_err(Error::driver)?;
                }
                let mut result = if let Execution::Edits(statements) = execution {
                    let mut results = Vec::new();
                    for statement in statements {
                        let output = query(client, statement, None, usize::MAX).await?;
                        crate::stream::check_affected(statement, output.iter().filter_map(ResultSet::affected).sum())?;
                        results.extend(output);
                    }
                    results
                } else {
                    query(client, sql, matches!(execution, Execution::Bound(_)).then_some(params.as_slice()), max_rows).await?
                };
                if result.len() == 1 {
                    // Description is best-effort; unsupported batches stay read-only.
                    if let Err(error) = describe(client, origin, values, &mut result[0]).await {
                        tracing::debug!(%error, "could not describe MSSQL result");
                    }
                }
                Ok(result)
            } => result,
        };
        match result {
            Ok(result) => {
                if transaction {
                    // A cancellation never interrupts COMMIT: its outcome must be reported.
                    if cancel.is_cancelled() {
                        let _ = tokio::time::timeout(
                            crate::STOP_TIMEOUT,
                            client.rollback_transaction(),
                        )
                        .await;
                        *slot = None;
                        return Err(Error::Cancelled);
                    }
                    if let Err(error) = client.commit_transaction().await {
                        *slot = None;
                        return Err(Error::driver(format!(
                            "{error}; commit outcome may be unknown; session discarded"
                        )));
                    }
                }
                Ok(result)
            }
            Err(error) => {
                // Attention is bounded; never reuse an interrupted protocol stream.
                let _ = tokio::time::timeout(crate::STOP_TIMEOUT, client.cancel_query()).await;
                if transaction {
                    let _ =
                        tokio::time::timeout(crate::STOP_TIMEOUT, client.rollback_transaction())
                            .await;
                }
                *slot = None;
                match error {
                    Error::Cancelled => Err(Error::Cancelled),
                    error => Err(Error::driver(format!(
                        "{error}; MSSQL session discarded; next request reconnects. Transaction and session state are lost; request was not replayed"
                    ))),
                }
            }
        }
    }
}

async fn rows(client: &mut Connection, sql: &str, params: &[&dyn ToSql]) -> Result<Vec<Row>> {
    client
        .query(sql, params)
        .await
        .map_err(Error::driver)?
        .into_first_result()
        .await
        .map_err(Error::driver)
}

fn text(row: &Row, index: usize) -> String {
    row.get::<&str, _>(index).unwrap_or("").to_owned()
}

async fn query(
    client: &mut Connection,
    sql: &str,
    params: Option<&[&dyn ToSql]>,
    max_rows: usize,
) -> Result<Vec<ResultSet>> {
    let start = Instant::now();
    let mut results = Vec::new();
    let mut inner_count = None;
    // sp_executesql preserves the caller's @@ROWCOUNT. Capture it inside the
    // bound batch instead of reading a stale value on the outer session.
    static NEXT_COUNT: AtomicU64 = AtomicU64::new(0);
    let mut count_column = format!(
        "__sqmeow_bound_affected_{}_{}",
        std::process::id(),
        NEXT_COUNT.fetch_add(1, Ordering::Relaxed)
    );
    let lower = sql.to_ascii_lowercase();
    while lower.contains(&count_column) {
        count_column.push('_');
    }
    let executed = if params.is_some() {
        format!("{sql}\n; SELECT CAST(@@ROWCOUNT AS bigint) AS [{count_column}]")
    } else {
        sql.to_owned()
    };
    let mut stream = if let Some(params) = params {
        client.query(&executed, params).await
    } else {
        client.simple_query(sql).await
    }
    .map_err(Error::driver)?;
    while let Some(item) = stream.try_next().await.map_err(Error::driver)? {
        match item {
            QueryItem::Metadata(meta) => {
                inner_count = None;
                results.push(ResultSet::new(
                    sql,
                    meta.columns()
                        .iter()
                        .map(|column| Column::new(column.name(), type_name(column.column_type())))
                        .collect(),
                ));
            }
            QueryItem::Row(row) => {
                let result = results.last_mut().expect("metadata precedes rows");
                if params.is_some()
                    && result.columns().len() == 1
                    && result.columns()[0].name == count_column
                {
                    inner_count = row.try_get::<i64, _>(0).ok().flatten();
                }
                if result.row_count() < max_rows {
                    result.push_row(
                        row.cells()
                            .map(|(_, data)| decode(data))
                            .collect::<Result<Vec<_>>>()?,
                    );
                } else {
                    result.mark_truncated();
                }
            }
        }
    }
    drop(stream);
    let bound_count = if params.is_some()
        && results.last().is_some_and(|result| {
            result.columns().len() == 1 && result.columns()[0].name == count_column
        }) {
        results.pop();
        inner_count
    } else {
        None
    };
    if results.is_empty() {
        // QueryStream omits DONE counts. Read the last statement's count on the
        // same session, without executing the user's batch a second time.
        let count = if params.is_some() {
            bound_count
        } else {
            rows(client, "SELECT CAST(@@ROWCOUNT AS bigint)", &[])
                .await?
                .first()
                .and_then(|r| r.get::<i64, _>(0))
        };
        let mut result = ResultSet::new(sql, vec![]);
        if let Some(count) = count {
            result.set_affected(count as u64);
        }
        results.push(result);
    }
    for result in &mut results {
        result.set_elapsed(start.elapsed());
    }
    Ok(results)
}

fn type_name(kind: tiberius::ColumnType) -> &'static str {
    use tiberius::ColumnType::*;
    match kind {
        Int1 => "tinyint",
        Int2 => "smallint",
        Int4 => "int",
        Int8 | Intn => "bigint",
        Bit | Bitn => "bit",
        Float4 => "real",
        Float8 | Floatn => "float",
        Decimaln | Numericn => "decimal",
        Money | Money4 => "money",
        Datetime | Datetime4 | Datetimen => "datetime",
        Daten => "date",
        Timen => "time",
        Datetime2 => "datetime2",
        DatetimeOffsetn => "datetimeoffset",
        Guid => "uniqueidentifier",
        BigVarBin | BigBinary | Image => "varbinary(max)",
        Xml => "xml",
        BigVarChar | BigChar | Text => "varchar(max)",
        NVarchar | NChar | NText => "nvarchar(max)",
        _ => "sql_variant",
    }
}

fn decode(data: &ColumnData<'static>) -> Result<Cell> {
    use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime};
    use tiberius::FromSql;
    Ok(match data {
        ColumnData::U8(v) => v.map(|v| Cell::Int(v.into())).unwrap_or(Cell::Null),
        ColumnData::I16(v) => v.map(|v| Cell::Int(v.into())).unwrap_or(Cell::Null),
        ColumnData::I32(v) => v.map(|v| Cell::Int(v.into())).unwrap_or(Cell::Null),
        ColumnData::I64(v) => v.map(Cell::Int).unwrap_or(Cell::Null),
        ColumnData::F32(v) => v.map(|v| Cell::Float(v.into())).unwrap_or(Cell::Null),
        ColumnData::F64(v) => v.map(Cell::Float).unwrap_or(Cell::Null),
        ColumnData::Bit(v) => v.map(Cell::Bool).unwrap_or(Cell::Null),
        ColumnData::String(v) => v
            .as_ref()
            .map(|v| Cell::Text(v.to_string()))
            .unwrap_or(Cell::Null),
        ColumnData::Guid(v) => v.map(|v| Cell::Uuid(v.to_string())).unwrap_or(Cell::Null),
        ColumnData::Binary(v) => v.as_ref().map(|v| Cell::bytes(v)).unwrap_or(Cell::Null),
        ColumnData::Numeric(v) => v
            .map(|v| Cell::Decimal(v.to_string()))
            .unwrap_or(Cell::Null),
        ColumnData::Xml(v) => v
            .as_ref()
            .map(|v| Cell::Text(v.to_string()))
            .unwrap_or(Cell::Null),
        ColumnData::Date(_) => NaiveDate::from_sql(data)
            .map_err(Error::driver)?
            .map(|v| Cell::Date(v.to_string()))
            .unwrap_or(Cell::Null),
        ColumnData::Time(_) => NaiveTime::from_sql(data)
            .map_err(Error::driver)?
            .map(|v| Cell::Time(v.to_string()))
            .unwrap_or(Cell::Null),
        ColumnData::DateTimeOffset(_) => DateTime::<FixedOffset>::from_sql(data)
            .map_err(Error::driver)?
            .map(|v| Cell::Timestamp(v.to_rfc3339()))
            .unwrap_or(Cell::Null),
        _ => NaiveDateTime::from_sql(data)
            .map_err(Error::driver)?
            .map(|v| Cell::Timestamp(v.to_string()))
            .unwrap_or(Cell::Null),
    })
}

async fn describe(
    client: &mut Connection,
    sql: &str,
    values: &[Value],
    result: &mut ResultSet,
) -> Result<()> {
    if !sqmeow_db::sql::mssql_query(sql)
        || !sqmeow_db::sql::plain(Dialect::MsSql, sql)
        || result.columns().is_empty()
    {
        return Ok(());
    }
    let declarations = parameter_declarations(values);
    let metadata = rows(
        client,
        "SELECT name, system_type_name, source_schema, source_table, source_column,
                is_identity_column, is_updateable, is_part_of_unique_key
         FROM sys.dm_exec_describe_first_result_set(@P1, @P2, 1)
         WHERE is_hidden = 0 AND (source_database IS NULL OR source_database = DB_NAME())
         ORDER BY column_ordinal",
        &[&sql, &declarations],
    )
    .await?;
    if metadata.len() != result.columns().len() {
        return Ok(());
    }
    let mut binder = TableBinder::default().sides(sqmeow_db::sql::Sides::read(Dialect::MsSql, sql));
    let mut keys = HashMap::new();
    for (i, row) in metadata.iter().enumerate() {
        let column = &mut result.columns_mut()[i];
        column.type_name = text(row, 1);
        column.class = sqmeow_db::types::TypeClass::from_type_name(&column.type_name);
        column.generated =
            row.get::<bool, _>(5).unwrap_or(false) || !row.get::<bool, _>(6).unwrap_or(false);
        let schema = text(row, 2);
        let table = text(row, 3);
        let column = text(row, 4);
        if schema.is_empty() || table.is_empty() || column.is_empty() {
            continue;
        }
        if !row.get::<bool, _>(6).unwrap_or(false) && !row.get::<bool, _>(5).unwrap_or(false) {
            continue;
        }
        let name = TableName::new(Some(&schema), &table);
        if !keys.contains_key(&name) {
            let indexes = index_rows(client, &schema, &table).await?;
            keys.insert(name.clone(), indexes);
        }
        if keys[&name]
            .iter()
            .any(|i| i.primary && i.columns.contains(&column))
        {
            result.columns_mut()[i].key = KeyKind::Primary;
        }
        binder.bind(i, name, column);
    }
    result.set_source(binder.build(|table| {
        keys.get(table)
            .into_iter()
            .flatten()
            .filter(|i| i.unique)
            .map(|i| i.columns.clone())
            .collect()
    }));
    Ok(())
}

async fn index_rows(client: &mut Connection, schema: &str, table: &str) -> Result<Vec<IndexNode>> {
    let data = rows(
        client,
        "SELECT i.name, c.name, i.is_unique, i.is_primary_key
         FROM sys.indexes i JOIN sys.tables t ON t.object_id=i.object_id
         JOIN sys.schemas s ON s.schema_id=t.schema_id
         JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
         JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
         WHERE s.name=@P1 AND t.name=@P2 AND ic.key_ordinal>0 AND i.is_disabled=0 AND i.has_filter=0
         ORDER BY i.is_primary_key DESC, i.index_id, ic.key_ordinal",
        &[&schema, &table],
    )
    .await?;
    let mut indexes: Vec<IndexNode> = Vec::new();
    for row in data {
        let name = text(&row, 0);
        if indexes.last().is_none_or(|i| i.name != name) {
            indexes.push(IndexNode {
                name,
                columns: vec![],
                unique: row.get(2).unwrap_or(false),
                primary: row.get(3).unwrap_or(false),
            });
        }
        indexes
            .last_mut()
            .expect("inserted")
            .columns
            .push(text(&row, 1));
    }
    Ok(indexes)
}

impl Adapter for MsSqlAdapter {
    fn plan(&self, result: &ResultSet, changes: &sqmeow_db::edit::Changes) -> Result<Vec<String>> {
        for (index, _) in changes
            .live_updates()
            .flat_map(|(_, cells)| cells)
            .chain(changes.inserts.iter().flatten())
        {
            if result
                .columns()
                .get(*index)
                .is_some_and(|column| column.generated)
            {
                return Err(Error::driver(
                    "identity and computed columns cannot be edited",
                ));
            }
        }
        sqmeow_db::edit::sql_plan(Dialect::MsSql, result, changes)
    }

    fn dialect(&self) -> Dialect {
        Dialect::MsSql
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(self
            .execute_results(statement, statement, max_rows, cancel)
            .await?
            .remove(0))
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(self
            .execute_results(statement, origin, max_rows, cancel)
            .await?
            .remove(0))
    }

    async fn execute_results(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.run(statement, origin, max_rows, cancel, Execution::Plain)
            .await
    }

    async fn execute_bound(
        &self,
        statement: &str,
        values: &[Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        Ok(self
            .execute_bound_results(statement, values, max_rows, cancel)
            .await?
            .remove(0))
    }

    async fn execute_bound_results(
        &self,
        statement: &str,
        values: &[Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.run(
            statement,
            statement,
            max_rows,
            cancel,
            Execution::Bound(values),
        )
        .await
    }

    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        self.run("", "", usize::MAX, cancel, Execution::Edits(statements))
            .await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        Ok(self.metadata("SELECT name, CAST(CASE WHEN name=SCHEMA_NAME() THEN 1 ELSE 0 END AS bit) FROM sys.schemas WHERE schema_id<16384 AND name NOT IN ('sys','INFORMATION_SCHEMA') ORDER BY name", &[]).await?
            .iter().map(|r| SchemaNode { name: text(r, 0), is_default: r.get(1).unwrap_or(false) }).collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        Ok(self.metadata("SELECT o.name, o.type FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name=@P1 AND o.type IN ('U','V','SO') AND o.is_ms_shipped=0 ORDER BY o.name", &[&schema]).await?
            .iter().map(|r| RelationNode { name: text(r, 0), kind: match text(r, 1).trim() { "V" => RelationKind::View, "SO" => RelationKind::Sequence, _ => RelationKind::Table } }).collect())
    }

    async fn routines(&self, schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(self.metadata("SELECT o.name, CASE WHEN o.type IN ('P','PC') THEN 'procedure' ELSE 'function' END FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name=@P1 AND o.type IN ('P','PC','FN','IF','TF','FS','FT') AND o.is_ms_shipped=0 ORDER BY o.name", &[&schema]).await?
            .iter().map(|r| crate::routine_node(text(r, 0), &text(r, 1))).collect())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        Ok(self.metadata(
            "SELECT c.name, TYPE_NAME(c.user_type_id), c.is_nullable,
             CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id WHERE i.object_id=c.object_id AND i.is_primary_key=1 AND ic.column_id=c.column_id) THEN 1 ELSE 0 END AS bit),
             d.definition, rs.name, rt.name, rc.name
             FROM sys.columns c JOIN sys.objects o ON o.object_id=c.object_id
             JOIN sys.schemas s ON s.schema_id=o.schema_id
             LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id
             OUTER APPLY (SELECT TOP (1) referenced_object_id, referenced_column_id FROM sys.foreign_key_columns WHERE parent_object_id=c.object_id AND parent_column_id=c.column_id) fk
             LEFT JOIN sys.tables rt ON rt.object_id=fk.referenced_object_id
             LEFT JOIN sys.schemas rs ON rs.schema_id=rt.schema_id
             LEFT JOIN sys.columns rc ON rc.object_id=rt.object_id AND rc.column_id=fk.referenced_column_id
             WHERE s.name=@P1 AND o.name=@P2 ORDER BY c.column_id", &[&schema, &relation]).await?
            .iter().map(|r| ColumnNode { name: text(r, 0), type_name: text(r, 1), nullable: r.get(2).unwrap_or(false), primary_key: r.get(3).unwrap_or(false), default: r.get::<&str, _>(4).map(str::to_owned), foreign_key: r.get::<&str, _>(6).map(|table| ForeignKey { table: format!("{}.{}", text(r, 5), table), column: text(r, 7) }) }).collect())
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        let mut slot = self.connection.lock().await;
        if slot.is_none() {
            *slot = Some(open(&self.config).await?);
        }
        let result = index_rows(slot.as_mut().expect("connected"), schema, relation).await;
        if result.is_err() {
            *slot = None;
        }
        result
    }

    async fn roles(&self) -> Result<Vec<RoleNode>> {
        Ok(self.metadata("SELECT name, type_desc FROM sys.database_principals WHERE principal_id>4 ORDER BY name", &[]).await?
            .iter().map(|r| RoleNode { name: text(r, 0), attributes: vec![text(r, 1)] }).collect())
    }

    async fn relationships(
        &self,
        schema: &str,
        relation: &str,
    ) -> Result<Vec<sqmeow_db::node::RelationshipNode>> {
        let data = self.metadata(
            "SELECT fk.name, ps.name, pt.name, pc.name, rs.name, rt.name, rc.name
             FROM sys.foreign_keys fk
             JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=fk.object_id
             JOIN sys.tables pt ON pt.object_id=fk.parent_object_id
             JOIN sys.schemas ps ON ps.schema_id=pt.schema_id
             JOIN sys.columns pc ON pc.object_id=pt.object_id AND pc.column_id=fc.parent_column_id
             JOIN sys.tables rt ON rt.object_id=fk.referenced_object_id
             JOIN sys.schemas rs ON rs.schema_id=rt.schema_id
             JOIN sys.columns rc ON rc.object_id=rt.object_id AND rc.column_id=fc.referenced_column_id
             WHERE (ps.name=@P1 AND pt.name=@P2) OR (rs.name=@P1 AND rt.name=@P2)
             ORDER BY ps.name, pt.name, fk.object_id, fc.constraint_column_id",
            &[&schema, &relation],
        ).await?;
        Ok(crate::relationship_nodes(data.iter().map(|r| {
            (
                text(r, 0),
                text(r, 1),
                text(r, 2),
                text(r, 3),
                text(r, 4),
                text(r, 5),
                text(r, 6),
            )
        })))
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<Details> {
        let mut details = Details::default();
        let object = format!(
            "{}.{}",
            Dialect::MsSql.quote_ident(schema),
            Dialect::MsSql.quote_ident(relation)
        );
        let data = self
            .metadata("SELECT OBJECT_DEFINITION(OBJECT_ID(@P1))", &[&object])
            .await?;
        details.definition = data
            .first()
            .and_then(|r| r.get::<&str, _>(0))
            .map(str::to_owned);
        details.checks = self.metadata("SELECT name, definition FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(@P1) ORDER BY name", &[&object]).await?.iter().map(|r| (text(r, 0), text(r, 1))).collect();
        details.triggers = self.metadata("SELECT name, OBJECT_DEFINITION(object_id) FROM sys.triggers WHERE parent_id=OBJECT_ID(@P1) ORDER BY name", &[&object]).await?.iter().map(|r| (text(r, 0), text(r, 1))).collect();
        let data = self.metadata("SELECT fk.name, pc.name, rs.name, rt.name, rc.name FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=fk.object_id JOIN sys.columns pc ON pc.object_id=fc.parent_object_id AND pc.column_id=fc.parent_column_id JOIN sys.tables rt ON rt.object_id=fc.referenced_object_id JOIN sys.schemas rs ON rs.schema_id=rt.schema_id JOIN sys.columns rc ON rc.object_id=rt.object_id AND rc.column_id=fc.referenced_column_id WHERE fk.parent_object_id=OBJECT_ID(@P1) ORDER BY fk.name, fc.constraint_column_id", &[&object]).await?;
        for row in data {
            let name = text(&row, 0);
            if details.foreign_keys.last().is_none_or(|k| k.name != name) {
                details.foreign_keys.push(ForeignKeyNode {
                    name,
                    columns: vec![],
                    target: format!("{}.{}", text(&row, 2), text(&row, 3)),
                    referenced: vec![],
                });
            }
            let key = details.foreign_keys.last_mut().expect("inserted");
            key.columns.push(text(&row, 1));
            key.referenced.push(text(&row, 4));
        }
        Ok(details)
    }

    async fn close(&self) {
        self.connection.lock().await.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binds_native_scalars_and_typed_nulls() {
        let value = Value::Text("'; SELECT 99; -- 日本🐱".into());
        assert!(
            matches!(parameter(&value).to_sql(), ColumnData::String(Some(text)) if text == "'; SELECT 99; -- 日本🐱")
        );
        assert!(matches!(
            parameter(&Value::Int(i64::MAX)).to_sql(),
            ColumnData::I64(Some(i64::MAX))
        ));
        assert!(
            matches!(parameter(&Value::Float(1.25)).to_sql(), ColumnData::F64(Some(value)) if value == 1.25)
        );
        assert!(matches!(
            parameter(&Value::Bool(true)).to_sql(),
            ColumnData::Bit(Some(true))
        ));
        assert!(matches!(
            parameter(&Value::Null(Kind::Text)).to_sql(),
            ColumnData::String(None)
        ));
        assert!(matches!(
            parameter(&Value::Null(Kind::Int)).to_sql(),
            ColumnData::I64(None)
        ));
        assert!(matches!(
            parameter(&Value::Null(Kind::Float)).to_sql(),
            ColumnData::F64(None)
        ));
        assert!(matches!(
            parameter(&Value::Null(Kind::Bool)).to_sql(),
            ColumnData::Bit(None)
        ));
    }

    #[test]
    fn declares_metadata_parameters_without_value_interpolation() {
        assert_eq!(parameter_declarations(&[]), None);
        assert_eq!(
            parameter_declarations(&[
                Value::Text("'; SELECT 99; --".into()),
                Value::Int(7),
                Value::Float(1.25),
                Value::Bool(true),
                Value::Null(Kind::Text),
                Value::Null(Kind::Int),
                Value::Null(Kind::Float),
                Value::Null(Kind::Bool),
                Value::Text("a".repeat(4001)),
            ])
            .as_deref(),
            Some(
                "@P1 nvarchar(4000), @P2 bigint, @P3 float(53), @P4 bit, @P5 nvarchar(4000), @P6 bigint, @P7 float(53), @P8 bit, @P9 nvarchar(max)"
            )
        );
    }

    #[test]
    fn validates_options_without_echoing_credentials() {
        assert!(
            parse_url(
                "mssql://sa:secret@localhost/db?trust_server_certificate=true&sslrootcert=ca.pem",
                None
            )
            .is_err()
        );
        assert!(parse_url("mssql://sa:secret@localhost/db?unknown=true", None).is_err());
        let (config, list) =
            parse_url("mssql://sa:p%40ss@[::1]:1434/a%20b?encrypt=true", None).unwrap();
        assert_eq!(config.get_addr(), "::1:1434");
        assert!(!list);
        assert!(parse_url("mssql://sa:secret@localhost", None).unwrap().1);
        assert!(
            !parse_url("mssql://sa:secret@localhost", Some("app"))
                .unwrap()
                .1
        );
    }

    #[test]
    fn decodes_exact_numbers_nulls_and_binary() {
        assert_eq!(
            decode(&ColumnData::I64(Some(i64::MAX))).unwrap(),
            Cell::Int(i64::MAX)
        );
        assert_eq!(decode(&ColumnData::String(None)).unwrap(), Cell::Null);
        assert_eq!(
            decode(&ColumnData::Binary(Some(vec![0, 255].into()))).unwrap(),
            Cell::bytes(&[0, 255])
        );
        let numeric =
            tiberius::numeric::Numeric::new_with_scale(12345678901234567890123456789012345678, 8);
        assert_eq!(
            decode(&ColumnData::Numeric(Some(numeric))).unwrap(),
            Cell::Decimal("123456789012345678901234567890.12345678".into())
        );
    }
}
