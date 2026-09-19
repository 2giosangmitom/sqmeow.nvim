//! The SurrealDB adapter.

use std::collections::HashSet;
use std::sync::{PoisonError, RwLock};
use std::time::Instant;

use percent_encoding::percent_decode_str;
use sqmeow_db::edit::{self, check_column, check_row};
use sqmeow_db::{
    Adapter, Cell, Changes, Column, ColumnNode, Dialect, Error, IndexNode, RelationKind,
    RelationNode, Result, ResultSet, RoleNode, RoutineNode, SchemaNode, Source,
};
use surrealdb::Surreal;
use surrealdb::engine::remote::ws::{Client, Ws, Wss};
use surrealdb::opt::Config;
use surrealdb::opt::auth::{Database, Namespace, Root};
use surrealdb::types::{Number, SurrealValue, ToSql, Value};
use tokio_util::sync::CancellationToken;

const DEFAULT_PORT: u16 = 8000;

/// The namespace and database SurrealDB starts on when none is named.
const DEFAULT_NAME: &str = "main";

/// How many records a schemaless table's fields are read from.
const SAMPLE_SIZE: usize = 100;

/// One connection to a SurrealDB server, on one namespace and database.
pub struct SurrealAdapter {
    db: Surreal<Client>,
    namespace: String,
    /// The database queries run on. `USE DB` changes it.
    database: RwLock<String>,
    /// Whether the URL named no database, so the drawer lists every one in the namespace.
    cluster: bool,
}

impl std::fmt::Debug for SurrealAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SurrealAdapter")
            .field("namespace", &self.namespace)
            .field("database", &self.database)
            .finish_non_exhaustive()
    }
}

/// Who a login signs in as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Level {
    Root,
    Namespace,
    Database,
}

/// What a `surrealdb://` URL asks for.
#[derive(Debug, PartialEq)]
struct Target {
    address: String,
    tls: bool,
    ca: Option<String>,
    credentials: Option<(String, String)>,
    level: Level,
    namespace: String,
    database: Option<String>,
}

impl SurrealAdapter {
    /// Open a connection, on `database` when given and otherwise on the one the URL names.
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        let target = parse_url(url)?;
        let cluster = database.is_none() && target.database.is_none();
        let database = database
            .map(str::to_owned)
            .or(target.database)
            .unwrap_or_else(|| DEFAULT_NAME.to_owned());

        let open = async {
            let db = if target.tls {
                let tls = crate::scylla::tls_config(target.ca.as_deref())?;
                let config = Config::new().rustls((*tls).clone());
                Surreal::new::<Wss>((target.address.as_str(), config)).await
            } else {
                Surreal::new::<Ws>(target.address.as_str()).await
            }
            .map_err(Error::driver)?;
            if let Some((username, password)) = target.credentials {
                match target.level {
                    Level::Root => db.signin(Root { username, password }).await,
                    Level::Namespace => {
                        db.signin(Namespace {
                            namespace: target.namespace.clone(),
                            username,
                            password,
                        })
                        .await
                    }
                    Level::Database => {
                        db.signin(Database {
                            namespace: target.namespace.clone(),
                            database: database.clone(),
                            username,
                            password,
                        })
                        .await
                    }
                }
                .map_err(Error::driver)?;
            }
            db.use_ns(target.namespace.as_str())
                .use_db(database.as_str())
                .await
                .map_err(Error::driver)?;
            Ok::<_, Error>(db)
        };
        let db = tokio::time::timeout(crate::CONNECT_TIMEOUT, open)
            .await
            .map_err(|_| Error::driver("timed out connecting to the server"))??;

        Ok(Self {
            db,
            namespace: target.namespace,
            database: RwLock::new(database),
            cluster,
        })
    }

    /// Every database in the namespace when the URL named none, and `None` otherwise.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        if !self.cluster {
            return None;
        }
        Some(
            async {
                let info = self.one("INFO FOR NS STRUCTURE").await?;
                let mut names = names(&info, "databases");
                names.sort();
                Ok(names)
            }
            .await,
        )
    }

    /// The database queries run on.
    pub fn database(&self) -> String {
        self.database
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Run one statement and hand back what it answered.
    async fn one(&self, query: &str) -> Result<Value> {
        let mut response = self.db.query(query).await.map_err(Error::driver)?;
        response.take::<Value>(0).map_err(Error::driver)
    }

    /// What `INFO FOR TABLE … STRUCTURE` says of one table.
    async fn table_info(&self, table: &str) -> Result<Value> {
        self.one(&format!(
            "INFO FOR TABLE {} STRUCTURE",
            Dialect::SurrealDb.quote_ident(table)
        ))
        .await
    }

    /// Run a query about one table, with its name bound as `$table`.
    async fn about(&self, query: &str, table: &str) -> Result<Value> {
        let mut response = self
            .db
            .query(query)
            .bind(("table", table.to_owned()))
            .await
            .map_err(Error::driver)?;
        response.take::<Value>(0).map_err(Error::driver)
    }

    async fn read(&self, statement: &str, max_rows: usize) -> Result<ResultSet> {
        let started = Instant::now();
        // The SDK keeps its own namespace and database, which a `USE` sent as a query leaves alone.
        if let Some((namespace, database)) = use_target(statement) {
            let database = database.unwrap_or_else(|| self.database());
            match namespace {
                Some(namespace) => self.db.use_ns(namespace).use_db(database.as_str()).await,
                None => self.db.use_db(database.as_str()).await,
            }
            .map_err(Error::driver)?;
            let mut result = ResultSet::new(statement, vec![Column::new("result", "string")]);
            result.push_row(vec![Cell::Text(format!("switched to db {database}"))]);
            *self
                .database
                .write()
                .unwrap_or_else(PoisonError::into_inner) = database;
            return Ok(result);
        }

        let mut response = self.db.query(statement).await.map_err(Error::driver)?;
        let count = response.num_statements();
        let mut errors = response.take_errors();
        if let Some(error) = first_error(&mut errors) {
            return Err(Error::driver(error));
        }
        // A block answers once per statement: the result is the last answer, past a `COMMIT`'s none.
        let mut value = Value::None;
        for index in (0..count).rev() {
            value = response.take::<Value>(index).map_err(Error::driver)?;
            if !matches!(value, Value::None) {
                break;
            }
        }

        let mut result = to_result(statement, value, max_rows);
        result.set_elapsed(started.elapsed());
        Ok(result)
    }
}

impl Adapter for SurrealAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::SurrealDb
    }

    fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        plan(result, changes)
    }

    /// The statements in one transaction, each checked to have found its record.
    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        let query = transaction(statements);
        let reply = tokio::select! {
            biased;
            () = cancel.cancelled() => return Err(Error::Cancelled),
            reply = self.db.query(query) => reply,
        };
        let mut response = reply.map_err(Error::driver)?;
        if let Some(error) = first_error(&mut response.take_errors()) {
            return Err(Error::driver(format!("nothing was applied: {error}")));
        }
        Ok(Vec::new())
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        tokio::select! {
            biased;
            () = cancel.cancelled() => Err(Error::Cancelled),
            result = self.read(statement, max_rows) => result,
        }
    }

    /// The database queries run on.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        Ok(vec![SchemaNode {
            name: self.database(),
            is_default: true,
        }])
    }

    /// The tables of the database, with those defined `AS SELECT` as views.
    async fn relations(&self, _schema: &str) -> Result<Vec<RelationNode>> {
        let info = self.one("INFO FOR DB STRUCTURE").await?;
        let mut relations: Vec<RelationNode> = entries(&info, "tables")
            .map(|table| RelationNode {
                name: text(table.get("name")),
                kind: if table.get("view").is_some_and(|view| !view.is_nullish()) {
                    RelationKind::View
                } else {
                    RelationKind::Table
                },
            })
            .collect();
        relations.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(relations)
    }

    /// The `fn::` functions of the database.
    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        let info = self.one("INFO FOR DB STRUCTURE").await?;
        let mut names = names(&info, "functions");
        names.sort();
        Ok(names
            .into_iter()
            .map(|name| crate::routine_node(format!("fn::{name}"), "function"))
            .collect())
    }

    /// `id`, then the defined fields, or for a table with none the fields of a sample of its records.
    async fn columns(&self, _schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let info = self.table_info(relation).await?;
        let mut columns = vec![ColumnNode {
            name: "id".to_owned(),
            type_name: "record".to_owned(),
            nullable: false,
            primary_key: true,
            foreign_key: None,
            default: None,
        }];
        let defined: Vec<ColumnNode> = entries(&info, "fields")
            .map(|field| {
                let type_name = text(field.get("kind"));
                ColumnNode {
                    name: text(field.get("name")),
                    nullable: type_name.is_empty()
                        || type_name.starts_with("option<")
                        || type_name.split(" | ").any(|kind| kind == "none"),
                    type_name: if type_name.is_empty() {
                        "any".to_owned()
                    } else {
                        type_name
                    },
                    primary_key: false,
                    foreign_key: None,
                    default: field
                        .get("default")
                        .filter(|v| !v.is_nullish())
                        .map(text_of),
                }
            })
            .filter(|column| column.name != "id")
            .collect();
        if !defined.is_empty() {
            columns.extend(defined);
            return Ok(columns);
        }

        let sample = self
            .about(
                &format!("SELECT * FROM type::table($table) LIMIT {SAMPLE_SIZE}"),
                relation,
            )
            .await?;
        let records = match sample {
            Value::Array(records) => records.into_vec(),
            _ => Vec::new(),
        };
        columns.extend(field_nodes(&records).into_iter().filter(|c| c.name != "id"));
        Ok(columns)
    }

    async fn indexes(&self, _schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        let info = self.table_info(relation).await?;
        let mut indexes: Vec<IndexNode> = entries(&info, "indexes")
            .map(|index| IndexNode {
                name: text(index.get("name")),
                columns: match index.get("cols") {
                    Some(Value::Array(cols)) => {
                        cols.clone().into_vec().iter().map(text_of).collect()
                    }
                    _ => Vec::new(),
                },
                unique: text(index.get("index")) == "UNIQUE",
                primary: false,
            })
            .collect();
        indexes.sort_by(|a, b| a.name.cmp(&b.name));
        // The record id is the key every record is found by.
        indexes.insert(
            0,
            IndexNode {
                name: "id".to_owned(),
                columns: vec!["id".to_owned()],
                unique: true,
                primary: true,
            },
        );
        Ok(indexes)
    }

    /// Database users, with their roles.
    async fn roles(&self) -> Result<Vec<RoleNode>> {
        let info = self.one("INFO FOR DB STRUCTURE").await?;
        let mut roles: Vec<RoleNode> = entries(&info, "users")
            .map(|user| RoleNode {
                name: text(user.get("name")),
                attributes: match user.get("roles") {
                    Some(Value::Array(roles)) => {
                        roles.clone().into_vec().iter().map(text_of).collect()
                    }
                    _ => Vec::new(),
                },
            })
            .collect();
        roles.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(roles)
    }

    /// The table's definition, comment and events.
    async fn details(&self, _schema: &str, relation: &str) -> Result<sqmeow_db::Details> {
        let db = self.one("INFO FOR DB").await?;
        let definition = match &db {
            Value::Object(info) => match info.get("tables") {
                Some(Value::Object(tables)) => tables.get(relation).map(text_of),
                _ => None,
            },
            _ => None,
        };
        let structure = self.one("INFO FOR DB STRUCTURE").await?;
        let comment = entries(&structure, "tables")
            .find(|table| text(table.get("name")) == relation)
            .and_then(|table| {
                table
                    .get("comment")
                    .filter(|v| !v.is_nullish())
                    .map(text_of)
            });

        let table = self.table_info(relation).await?;
        let triggers = entries(&table, "events")
            .map(|event| {
                (
                    text(event.get("name")),
                    format!("WHEN {}", text(event.get("when"))),
                )
            })
            .collect();

        Ok(sqmeow_db::Details {
            properties: comment
                .map(|comment| ("comment".to_owned(), comment))
                .into_iter()
                .collect(),
            triggers,
            definition,
            ..sqmeow_db::Details::default()
        })
    }

    async fn close(&self) {
        let _ = self.db.invalidate().await;
    }
}

/// The namespace and database a `USE NS a DB b` statement names.
fn use_target(statement: &str) -> Option<(Option<String>, Option<String>)> {
    let mut words = statement.trim().trim_end_matches(';').split_whitespace();
    if !words.next()?.eq_ignore_ascii_case("use") {
        return None;
    }
    let (mut namespace, mut database) = (None, None);
    while let Some(word) = words.next() {
        let name = words.next()?.trim_matches(['`', '⟨', '⟩']).to_owned();
        match word.to_ascii_lowercase().as_str() {
            "ns" | "namespace" => namespace = Some(name),
            "db" | "database" => database = Some(name),
            _ => return None,
        }
    }
    (namespace.is_some() || database.is_some()).then_some((namespace, database))
}

/// The first error a response holds: a `THROW` or the statement that failed, rather than the
/// statements a failed transaction skipped.
fn first_error(errors: &mut std::collections::HashMap<usize, surrealdb::Error>) -> Option<String> {
    let mut errors: Vec<(usize, surrealdb::Error)> = errors.drain().collect();
    errors.sort_by_key(|(index, _)| *index);
    let thrown = errors.iter().position(|(_, error)| error.is_thrown());
    let skipped = |error: &surrealdb::Error| error.message().contains("not executed");
    let at = thrown
        .or_else(|| errors.iter().position(|(_, error)| !skipped(error)))
        .or((!errors.is_empty()).then_some(0))?;
    Some(errors[at].1.message().to_owned())
}

/// Statements in one transaction, where an update or delete that found no record throws.
fn transaction(statements: &[String]) -> String {
    let mut query = String::from("BEGIN TRANSACTION;\n");
    for statement in statements {
        query.push_str(&format!(
            "IF !({statement}) {{ THROW \"no record had that id any more: {}\" }};\n",
            statement.replace('\\', "\\\\").replace('"', "\\\"")
        ));
    }
    query.push_str("COMMIT TRANSACTION;");
    query
}

/// Plan changes to a table's records into `UPDATE`, `DELETE` and `CREATE` statements.
fn plan(result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
    let Some(source @ Source::Collection { name, .. }) = result.source() else {
        return Err(edit::not_editable());
    };
    let id_column = result
        .columns()
        .iter()
        .position(|column| column.name == "id")
        .ok_or_else(edit::not_editable)?;
    let record = |row: usize| -> Result<String> {
        check_row(result, row)?;
        match result.cell(row, id_column) {
            Some(Cell::Text(id)) => Ok(id.clone()),
            _ => Err(Error::driver("this record has no id to find it by")),
        }
    };
    let field = |column: usize| Dialect::SurrealDb.quote_ident(&result.columns()[column].name);
    let sets = |cells: &[(usize, edit::Value)], check: bool| -> Result<String> {
        cells
            .iter()
            .map(|(column, value)| {
                if check {
                    check_column(source, result, *column)?;
                } else if *column >= result.columns().len() {
                    return Err(Error::driver(format!("there is no column {column}")));
                }
                Ok(format!("{} = {}", field(*column), literal(value)))
            })
            .collect::<Result<Vec<_>>>()
            .map(|sets| sets.join(", "))
    };

    let mut statements = Vec::new();
    for (row, cells) in changes.live_updates() {
        statements.push(format!(
            "UPDATE {} SET {}",
            record(*row)?,
            sets(cells, true)?
        ));
    }
    for &row in &changes.deletes {
        statements.push(format!("DELETE {} RETURN BEFORE", record(row)?));
    }
    let table = Dialect::SurrealDb.quote_ident(name);
    for cells in &changes.inserts {
        // A new record's id is the server's to give unless one was typed.
        let (ids, rest): (Vec<_>, Vec<_>) = cells
            .iter()
            .cloned()
            .partition(|(column, _)| *column == id_column);
        let target = match ids.first() {
            Some((_, edit::Value::Text(key))) => {
                format!(
                    "type::record({}, {})",
                    Value::String(name.clone()).to_sql(),
                    literal(&edit::Value::Text(key.clone()))
                )
            }
            _ => table.clone(),
        };
        if rest.is_empty() {
            statements.push(format!("CREATE {target}"));
        } else {
            statements.push(format!("CREATE {target} SET {}", sets(&rest, false)?));
        }
    }
    Ok(statements)
}

/// A value typed into a cell, as SurrealQL: JSON where it reads as JSON, and a string otherwise.
fn literal(value: &edit::Value) -> String {
    match value {
        edit::Value::Null => "NULL".to_owned(),
        edit::Value::Sql(expression) => expression.clone(),
        edit::Value::Text(text) => serde_json::from_str::<serde_json::Value>(text)
            .map_or_else(|_| Value::String(text.clone()), SurrealValue::into_value)
            .to_sql(),
    }
}

/// Read the address, login, namespace and database from
/// `surrealdb://user:password@host:8000/namespace/database?auth=database`.
fn parse_url(url: &str) -> Result<Target> {
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| Error::UnsupportedUrl(url.to_owned()))?;
    let (rest, options) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
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
    let mut level = Level::Root;
    let mut ca = None;
    for option in options.split('&').filter(|option| !option.is_empty()) {
        let (key, value) = option.split_once('=').unwrap_or((option, ""));
        match (key, value) {
            ("auth", "root") => level = Level::Root,
            ("auth", "namespace" | "ns") => level = Level::Namespace,
            ("auth", "database" | "db") => level = Level::Database,
            ("sslrootcert", path) => ca = Some(decode(path)?),
            _ => {
                return Err(Error::driver(format!(
                    "a SurrealDB url takes `auth=root|namespace|database` and `sslrootcert`, not `{option}`"
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

    let host = if host.is_empty() { "localhost" } else { host };
    // A bracketed IPv6 address has colons of its own.
    let address = if host.ends_with(']') || !host.contains(':') {
        format!("{host}:{DEFAULT_PORT}")
    } else {
        host.to_owned()
    };
    let mut parts = path.split('/').filter(|part| !part.is_empty());
    let namespace = parts
        .next()
        .map(decode)
        .transpose()?
        .unwrap_or_else(|| DEFAULT_NAME.to_owned());
    let database = parts.next().map(decode).transpose()?;
    if level == Level::Database && database.is_none() {
        return Err(Error::driver(
            "signing in to a database needs the database in the url",
        ));
    }

    Ok(Target {
        address,
        tls: scheme.eq_ignore_ascii_case("surrealdbs"),
        ca,
        credentials,
        level,
        namespace,
        database,
    })
}

/// The objects listed under `key` in an `INFO … STRUCTURE` answer.
fn entries<'a>(info: &'a Value, key: &str) -> impl Iterator<Item = &'a surrealdb::types::Object> {
    let list = match info {
        Value::Object(info) => match info.get(key) {
            Some(Value::Array(list)) => Some(list),
            _ => None,
        },
        _ => None,
    };
    list.into_iter()
        .flat_map(|list| list.iter())
        .filter_map(|entry| match entry {
            Value::Object(entry) => Some(entry),
            _ => None,
        })
}

/// The names listed under `key` in an `INFO … STRUCTURE` answer.
fn names(info: &Value, key: &str) -> Vec<String> {
    entries(info, key)
        .map(|entry| text(entry.get("name")))
        .collect()
}

fn text(value: Option<&Value>) -> String {
    value.map(text_of).unwrap_or_default()
}

/// A value as plain text: a string without its quotes, anything else as SurrealQL.
fn text_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_sql(),
    }
}

/// Lay an answer out as rows: records a column per field with `id` first, and anything else in one
/// `result` column.
fn to_result(statement: &str, value: Value, max_rows: usize) -> ResultSet {
    let (rows, listed) = match value {
        Value::Array(rows) => (rows.into_vec(), true),
        Value::None => (Vec::new(), true),
        other => (vec![other], false),
    };
    let truncated = rows.len() > max_rows;
    let rows: Vec<Value> = rows.into_iter().take(max_rows).collect();

    let records =
        listed && !rows.is_empty() && rows.iter().all(|row| matches!(row, Value::Object(_)));
    let mut result = if records {
        let mut names: Vec<String> = Vec::new();
        let mut seen = HashSet::new();
        for row in &rows {
            if let Value::Object(record) = row {
                for key in record.keys() {
                    if seen.insert(key.clone()) {
                        names.push(key.clone());
                    }
                }
            }
        }
        if let Some(at) = names.iter().position(|name| name == "id") {
            let id = names.remove(at);
            names.insert(0, id);
        }
        let columns = names
            .iter()
            .map(|name| Column::new(name.clone(), common_type(&rows, name)))
            .collect();
        let table = record_table(&rows);
        let mut result = ResultSet::new(statement, columns);
        for row in rows {
            let Value::Object(record) = row else { continue };
            let mut record = record.into_inner();
            result.push_row(
                names
                    .iter()
                    .map(|name| record.remove(name).map_or(Cell::Null, cell))
                    .collect(),
            );
        }
        // Records of one table, read with their ids, are found again by them.
        if let Some(table) = table {
            result.set_source(Some(Source::Collection {
                db: String::new(),
                name: table,
                key: "id".into(),
            }));
        }
        result
    } else {
        let mut result = ResultSet::new(statement, vec![Column::new("result", common_kind(&rows))]);
        for row in rows {
            result.push_row(vec![cell(row)]);
        }
        result
    };
    if truncated {
        result.mark_truncated();
    }
    result
}

/// The table every record's `id` points into, when they all have one and it is the same.
fn record_table(rows: &[Value]) -> Option<String> {
    let mut tables = rows.iter().map(|row| match row {
        Value::Object(record) => match record.get("id") {
            Some(Value::RecordId(id)) => Some(id.table.as_str().to_owned()),
            _ => None,
        },
        _ => None,
    });
    let first = tables.next()??;
    tables
        .all(|table| table.as_deref() == Some(&first))
        .then_some(first)
}

/// The type every value of a field shares, or nothing when they differ.
fn common_type(rows: &[Value], field: &str) -> &'static str {
    let values = rows.iter().filter_map(|row| match row {
        Value::Object(record) => record.get(field),
        _ => None,
    });
    shared_kind(values)
}

fn common_kind(rows: &[Value]) -> &'static str {
    shared_kind(rows.iter())
}

fn shared_kind<'a>(values: impl Iterator<Item = &'a Value>) -> &'static str {
    let mut kinds = values.filter(|value| !value.is_nullish()).map(type_name);
    let Some(first) = kinds.next() else {
        return "";
    };
    if kinds.all(|kind| kind == first) {
        first
    } else {
        ""
    }
}

/// A value's type, spelled the way SurrealQL spells it.
fn type_name(value: &Value) -> &'static str {
    match value {
        Value::None => "none",
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(Number::Int(_)) => "int",
        Value::Number(Number::Float(_)) => "float",
        Value::Number(Number::Decimal(_)) => "decimal",
        Value::String(_) => "string",
        Value::Bytes(_) => "bytes",
        Value::Duration(_) => "duration",
        Value::Datetime(_) => "datetime",
        Value::Uuid(_) => "uuid",
        Value::Geometry(_) => "geometry",
        Value::Table(_) => "table",
        Value::RecordId(_) => "record",
        Value::File(_) => "file",
        Value::Range(_) => "range",
        Value::Regex(_) => "regex",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
        Value::Set(_) => "set",
    }
}

/// The fields a sample of records has, for the drawer.
fn field_nodes(records: &[Value]) -> Vec<ColumnNode> {
    let mut columns: Vec<ColumnNode> = Vec::new();
    let objects: Vec<&surrealdb::types::Object> = records
        .iter()
        .filter_map(|record| match record {
            Value::Object(record) => Some(record),
            _ => None,
        })
        .collect();
    for record in &objects {
        for (name, value) in record.iter() {
            let null = value.is_nullish();
            match columns.iter_mut().find(|column| &column.name == name) {
                Some(column) => {
                    column.nullable |= null;
                    // A null says nothing about the type, so the first value that is not one does.
                    if column.type_name == "null" && !null {
                        type_name(value).clone_into(&mut column.type_name);
                    }
                }
                None => columns.push(ColumnNode {
                    name: name.clone(),
                    type_name: if null { "null" } else { type_name(value) }.to_owned(),
                    nullable: null,
                    primary_key: name == "id",
                    foreign_key: None,
                    default: None,
                }),
            }
        }
    }
    for column in &mut columns {
        column.nullable |= objects
            .iter()
            .any(|record| record.get(&column.name).is_none());
    }
    columns
}

fn cell(value: Value) -> Cell {
    match value {
        Value::None | Value::Null => Cell::Null,
        Value::Bool(flag) => Cell::Bool(flag),
        Value::Number(Number::Int(number)) => Cell::Int(number),
        Value::Number(Number::Float(number)) => Cell::Float(number),
        Value::Number(Number::Decimal(number)) => Cell::Decimal(number.to_string()),
        Value::String(text) => Cell::Text(text),
        Value::Bytes(bytes) => Cell::bytes(&bytes.into_inner()),
        Value::Datetime(at) => Cell::Timestamp(at.into_inner().to_rfc3339()),
        Value::Uuid(id) => Cell::Uuid(id.to_string()),
        Value::Duration(duration) => Cell::Text(duration.to_string()),
        // As SurrealQL, which is also what finds the record again.
        Value::RecordId(id) => Cell::Text(id.to_sql()),
        value @ (Value::Array(_) | Value::Object(_) | Value::Set(_)) => {
            Cell::Json(value.into_json_value().to_string())
        }
        other => Cell::Unsupported {
            type_name: type_name(&other).to_owned(),
            raw: other.to_sql(),
        },
    }
}

#[cfg(test)]
mod tests {
    use sqmeow_db::TypeClass;
    use surrealdb::types::{Object, RecordId};

    use super::*;

    fn record(id: &str, name: Value) -> Value {
        let mut object = Object::new();
        object.insert("name", name);
        object.insert("id", RecordId::new("person", id));
        Value::Object(object)
    }

    fn people() -> ResultSet {
        to_result(
            "SELECT * FROM person",
            Value::Array(
                vec![
                    record("alice", Value::String("Alice".into())),
                    record("bob", Value::Null),
                ]
                .into(),
            ),
            100,
        )
    }

    #[test]
    fn records_become_rows_with_id_first_and_their_table_as_source() {
        let result = people();
        let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["id", "name"]);
        assert_eq!(result.cell(0, 0), Some(&Cell::Text("person:alice".into())));
        assert_eq!(result.cell(1, 1), Some(&Cell::Null));
        assert_eq!(result.columns()[0].type_name, "record");
        assert_eq!(result.columns()[1].type_name, "string");
        assert!(matches!(
            result.source(),
            Some(Source::Collection { name, .. }) if name == "person"
        ));
    }

    #[test]
    fn anything_but_records_is_one_result_column_and_cannot_be_edited() {
        let result = to_result("RETURN 1", Value::Number(Number::Int(1)), 100);
        assert_eq!(result.columns()[0].name, "result");
        assert_eq!(result.cell(0, 0), Some(&Cell::Int(1)));
        assert!(result.source().is_none());

        let mut object = Object::new();
        object.insert("count", 3);
        let counted = to_result(
            "SELECT count() FROM person GROUP ALL",
            Value::Array(vec![Value::Object(object)].into()),
            100,
        );
        assert!(counted.source().is_none());
    }

    #[test]
    fn rows_past_the_cap_are_cut() {
        let result = to_result(
            "SELECT * FROM person",
            Value::Array(vec![Value::Number(Number::Int(1)); 3].into()),
            2,
        );
        assert_eq!(result.row_count(), 2);
        assert!(result.is_truncated());
    }

    #[test]
    fn changes_become_statements_finding_records_by_id() {
        let result = people();
        let changes = Changes {
            updates: vec![(0, vec![(1, edit::Value::Text("Al \"the\" ice".into()))])],
            deletes: vec![1],
            inserts: vec![
                vec![(1, edit::Value::Text("42".into()))],
                vec![
                    (0, edit::Value::Text("carol".into())),
                    (1, edit::Value::Null),
                ],
            ],
        };
        assert_eq!(
            plan(&result, &changes).unwrap(),
            [
                r#"UPDATE person:alice SET `name` = 'Al "the" ice'"#,
                "DELETE person:bob RETURN BEFORE",
                "CREATE `person` SET `name` = 42",
                "CREATE type::record('person', 'carol') SET `name` = NULL",
            ]
        );
    }

    #[test]
    fn the_id_itself_cannot_be_edited() {
        let changes = Changes {
            updates: vec![(0, vec![(0, edit::Value::Text("person:x".into()))])],
            ..Changes::default()
        };
        assert!(plan(&people(), &changes).is_err());
    }

    #[test]
    fn a_transaction_throws_when_a_statement_finds_nothing() {
        assert_eq!(
            transaction(&["DELETE person:bob RETURN BEFORE".to_owned()]),
            "BEGIN TRANSACTION;\n\
             IF !(DELETE person:bob RETURN BEFORE) { THROW \"no record had that id any more: DELETE person:bob RETURN BEFORE\" };\n\
             COMMIT TRANSACTION;"
        );
    }

    #[test]
    fn use_names_a_namespace_and_database() {
        assert_eq!(
            use_target("USE NS shop DB `main`;"),
            Some((Some("shop".into()), Some("main".into())))
        );
        assert_eq!(
            use_target("use db other"),
            Some((None, Some("other".into())))
        );
        assert_eq!(use_target("USE"), None);
        assert_eq!(use_target("SELECT * FROM use"), None);
    }

    #[test]
    fn a_url_names_the_namespace_database_and_login() {
        assert_eq!(
            parse_url("surrealdbs://ro%40t:p%3Ass@db.example.com/shop/main?auth=database").unwrap(),
            Target {
                address: "db.example.com:8000".into(),
                tls: true,
                ca: None,
                credentials: Some(("ro@t".into(), "p:ss".into())),
                level: Level::Database,
                namespace: "shop".into(),
                database: Some("main".into()),
            }
        );
        let bare = parse_url("surrealdb://").unwrap();
        assert_eq!(bare.address, "localhost:8000");
        assert_eq!(bare.namespace, "main");
        assert_eq!(bare.database, None);
        assert!(!bare.tls);
        assert!(parse_url("surrealdb://h/ns?auth=database").is_err());
        assert!(parse_url("surrealdb://h/ns?nope=1").is_err());
    }

    #[test]
    fn surreal_values_become_cells() {
        assert_eq!(cell(Value::None), Cell::Null);
        assert_eq!(cell(Value::Number(Number::Float(1.5))), Cell::Float(1.5));
        let mut object = Object::new();
        object.insert("c", vec![1, 2]);
        assert_eq!(
            cell(Value::Object(object)),
            Cell::Json(r#"{"c":[1,2]}"#.into())
        );
        assert_eq!(TypeClass::from_type_name("record"), TypeClass::Text);
    }

    #[test]
    fn a_field_missing_from_some_records_is_nullable() {
        let mut bare = Object::new();
        bare.insert("id", RecordId::new("person", "x"));
        let columns = field_nodes(&[
            record("alice", Value::String("Alice".into())),
            Value::Object(bare),
        ]);
        let name = columns.iter().find(|c| c.name == "name").unwrap();
        assert!(name.nullable);
        assert_eq!(name.type_name, "string");
        assert!(columns.iter().find(|c| c.name == "id").unwrap().primary_key);
    }
}
