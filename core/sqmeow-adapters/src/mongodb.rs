//! The MongoDB adapter.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{PoisonError, RwLock};
use std::time::Instant;

use futures_util::StreamExt;
use mongodb::bson::oid::ObjectId;
use mongodb::bson::spec::BinarySubtype;
use mongodb::bson::{self, Bson, Document, doc};
use mongodb::options::ClientOptions;
use mongodb::results::CollectionType;
use mongodb::{Client, Database};
use sqmeow_db::adapter::Adapter;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::edit::Changes;
use sqmeow_db::edit::Source;
use sqmeow_db::edit::{self, check_column, check_row};
use sqmeow_db::error::Error;
use sqmeow_db::error::Result;
use sqmeow_db::node::ColumnNode;
use sqmeow_db::node::RelationKind;
use sqmeow_db::node::RelationNode;
use sqmeow_db::node::RoutineNode;
use sqmeow_db::node::SchemaNode;
use sqmeow_db::result::Column;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::{Value as ParameterValue, named_values};
use sqmeow_db::value::Cell;
use tokio_util::sync::CancellationToken;

/// How many documents a collection's fields are read from.
const SAMPLE_SIZE: i32 = 100;

/// Numbers the commands this process runs, so a cancelled one can be found on the server.
static TAGS: AtomicU64 = AtomicU64::new(0);

/// Commands that answer with a cursor to drain rather than with one document.
const CURSOR_COMMANDS: [&str; 4] = ["find", "aggregate", "listCollections", "listIndexes"];

/// Commands whose `n` counts the documents they wrote.
const WRITE_COMMANDS: [&str; 3] = ["insert", "update", "delete"];

/// One connection to a MongoDB deployment.
#[derive(Debug)]
pub struct MongoAdapter {
    client: Client,
    /// The database a command runs on unless it names another. `use` changes it.
    db: RwLock<String>,
    /// Whether the URL named no database, so the drawer lists every one on the server.
    cluster: bool,
}

/// What one statement asks for.
#[derive(Debug, PartialEq)]
enum Statement {
    /// Run later commands on this database.
    Use(String),
    /// Run a command, on the database it names or else the current one.
    Command {
        db: Option<String>,
        command: Document,
    },
}

impl MongoAdapter {
    /// Open a connection, on `database` when given and otherwise on the one the URL names.
    pub async fn connect(url: &str, database: Option<&str>) -> Result<Self> {
        let mut options = ClientOptions::parse(url).await.map_err(Error::driver)?;
        // The driver waits thirty seconds for a server by default, a long time to watch a
        // connection that is never going to open.
        options
            .server_selection_timeout
            .get_or_insert(crate::CONNECT_TIMEOUT);
        let cluster = database.is_none() && options.default_database.is_none();
        // `test` is what mongosh starts on when the URL names no database.
        let db = database
            .map(str::to_owned)
            .or_else(|| options.default_database.clone())
            .unwrap_or_else(|| "test".to_owned());
        let client = Client::with_options(options).map_err(Error::driver)?;

        // The driver connects lazily.
        client
            .database("admin")
            .run_command(doc! { "ping": 1 })
            .await
            .map_err(Error::driver)?;

        Ok(Self {
            client,
            db: RwLock::new(db),
            cluster,
        })
    }

    /// Every database the user may read when the URL named none, and `None` otherwise.
    pub async fn databases(&self) -> Option<Result<Vec<String>>> {
        if !self.cluster {
            return None;
        }
        // `authorizedDatabases` lists what a restricted user may read instead of refusing.
        Some(
            self.client
                .list_database_names()
                .authorized_databases(true)
                .await
                .map_err(Error::driver),
        )
    }

    /// Commands one after another, stopping at the first that fails.
    async fn apply_in_turn(
        &self,
        commands: &[(String, Document)],
        cancel: &CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        for (done, (db, command)) in commands.iter().enumerate() {
            let failed = |error: String| {
                Error::driver(format!(
                    "{done} of {} commands completed before one failed; the current write outcome may be unknown, verify before retrying: {error}",
                    commands.len()
                ))
            };
            let (command, _tag) = tagged(command.clone());
            let database = self.client.database(db);
            if cancel.is_cancelled() {
                return Err(crate::cancelled_after(done, commands.len()));
            }
            let reply = crate::await_sent(cancel, async { database.run_command(command).await })
                .await
                .map_err(|_| crate::cancelled_after(done, commands.len()))?
                .map_err(|error| failed(error.to_string()))?;
            written(&reply).map_err(failed)?;
        }
        Ok(Vec::new())
    }

    /// Stop the operations a cancelled command left running on the server.
    async fn kill(&self, tag: &str) {
        let admin = self.client.database("admin");
        let stop = async {
            let reply = admin
                .run_command(doc! { "currentOp": true, "command.comment": tag })
                .await?;
            for operation in reply.get_array("inprog").cloned().unwrap_or_default() {
                if let Some(id) = operation.as_document().and_then(|op| op.get("opid")) {
                    admin
                        .run_command(doc! { "killOp": 1, "op": id.clone() })
                        .await?;
                }
            }
            Ok::<_, mongodb::error::Error>(())
        };
        match tokio::time::timeout(crate::STOP_TIMEOUT, stop).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::debug!(%error, "could not stop a cancelled command"),
            Err(_) => tracing::debug!("stopping a cancelled command took too long"),
        }
    }

    /// The validator a collection was created with, if it has one.
    async fn validator(&self, schema: &str, relation: &str) -> Result<Option<Document>> {
        let mut cursor = self
            .client
            .database(schema)
            .list_collections()
            .filter(doc! { "name": relation })
            .await
            .map_err(Error::driver)?;
        match cursor.next().await {
            Some(specification) => Ok(specification.map_err(Error::driver)?.options.validator),
            None => Ok(None),
        }
    }

    /// The database commands run on, which `use` changes.
    pub fn database(&self) -> String {
        self.db
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    async fn execute_statement(
        &self,
        statement: &str,
        parsed: Statement,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        let started = Instant::now();
        let mut result = match parsed {
            Statement::Use(name) => {
                let mut result = ResultSet::new(statement, vec![Column::new("result", "string")]);
                result.push_row(vec![Cell::Text(format!("switched to db {name}"))]);
                *self.db.write().unwrap_or_else(PoisonError::into_inner) = name;
                result
            }
            Statement::Command { db, command } => {
                let database = self.client.database(&db.unwrap_or_else(|| self.database()));
                let (command, tag) = tagged(command);
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => {
                        self.kill(&tag).await;
                        return Err(Error::Cancelled);
                    }
                    result = run(&database, statement, command, max_rows) => result?,
                }
            }
        };
        result.set_elapsed(started.elapsed());
        Ok(result)
    }
}

#[async_trait::async_trait]
impl Adapter for MongoAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::MongoDb
    }

    /// A name as a JSON string, which is how a command document names a collection.
    fn quote_ident(&self, name: &str) -> String {
        serde_json::Value::from(name).to_string()
    }

    fn plan(&self, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
        plan(result, changes)
    }

    /// The commands in one transaction where the deployment has transactions, and one after another
    /// where it has not, stopping at the first that fails.
    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let commands = statements
            .iter()
            .map(|statement| match parse(statement)? {
                Statement::Command { db, command } => {
                    Ok((db.unwrap_or_else(|| self.database()), command))
                }
                Statement::Use(_) => Err(Error::driver("only commands can be applied")),
            })
            .collect::<Result<Vec<_>>>()?;

        let mut session = self.client.start_session().await.map_err(Error::driver)?;
        session.start_transaction().await.map_err(Error::driver)?;
        for (index, (db, command)) in commands.iter().enumerate() {
            let (command, tag) = tagged(command.clone());
            let database = self.client.database(db);
            let reply = tokio::select! {
                biased;
                () = cancel.cancelled() => Err(None),
                reply = database.run_command(command).session(&mut session) => {
                    reply.map_err(Some)
                }
            };
            let outcome = match reply {
                Err(None) => {
                    self.kill(&tag).await;
                    session.abort_transaction().await.map_err(Error::driver)?;
                    return Err(Error::Cancelled);
                }
                // A standalone server has no transactions, and says so to the first command.
                Err(Some(error)) if index == 0 && no_transactions(&error) => {
                    let _ = session.abort_transaction().await;
                    return self.apply_in_turn(&commands, &cancel).await;
                }
                Err(Some(error)) => Err(error.to_string()),
                Ok(reply) => written(&reply),
            };
            if let Err(error) = outcome {
                session.abort_transaction().await.map_err(|abort| {
                    Error::driver(format!("MongoDB rollback failed; write outcome may be unknown, verify before retrying: {abort}; original error: {error}"))
                })?;
                return Err(Error::driver(format!("nothing was applied: {error}")));
            }
        }
        if cancel.is_cancelled() {
            session.abort_transaction().await.map_err(Error::driver)?;
            return Err(Error::Cancelled);
        }
        session.commit_transaction().await.map_err(|error| {
            Error::driver(format!(
                "MongoDB commit outcome may be unknown; verify before retrying: {error}"
            ))
        })?;
        Ok(Vec::new())
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.execute_statement(statement, parse(statement)?, max_rows, cancel)
            .await
    }

    async fn execute_bound(
        &self,
        statement: &str,
        values: &[ParameterValue],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.execute_statement(
            statement,
            bound_statement(statement, values)?,
            max_rows,
            cancel,
        )
        .await
    }

    /// The database commands run on.
    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        Ok(vec![SchemaNode {
            name: self.database(),
            is_default: true,
        }])
    }

    /// The collections and views of one database.
    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let mut cursor = self
            .client
            .database(schema)
            .list_collections()
            .await
            .map_err(Error::driver)?;

        let mut relations = Vec::new();
        while let Some(collection) = cursor.next().await {
            let collection = collection.map_err(Error::driver)?;
            // A time series is read like any collection, so it goes with them.
            let kind = if matches!(collection.collection_type, CollectionType::View) {
                RelationKind::View
            } else {
                RelationKind::Table
            };
            relations.push(RelationNode {
                name: collection.name,
                kind,
            });
        }
        relations.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(relations)
    }

    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(Vec::new())
    }

    /// The fields of a sample of the collection's documents, since a collection has no schema.
    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let mut cursor = self
            .client
            .database(schema)
            .collection::<Document>(relation)
            .aggregate([doc! { "$sample": { "size": SAMPLE_SIZE } }])
            .await
            .map_err(Error::driver)?;

        let mut documents = Vec::new();
        while let Some(document) = cursor.next().await {
            documents.push(document.map_err(Error::driver)?);
        }
        let mut columns = field_nodes(&documents);

        // A validator's schema says what the sample may not: every field and which are required.
        let json_schema = self
            .validator(schema, relation)
            .await?
            .and_then(|validator| validator.get_document("$jsonSchema").ok().cloned());
        if let Some(json_schema) = json_schema {
            let required: Vec<String> = json_schema
                .get_array("required")
                .map(|names| {
                    names
                        .iter()
                        .filter_map(|name| name.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            if let Ok(properties) = json_schema.get_document("properties") {
                for (name, property) in properties {
                    let type_name = match property.as_document().and_then(|p| p.get("bsonType")) {
                        Some(Bson::String(kind)) => kind.clone(),
                        Some(other) => other.clone().into_relaxed_extjson().to_string(),
                        None => "any".to_owned(),
                    };
                    let nullable = !required.contains(name);
                    match columns.iter_mut().find(|column| &column.name == name) {
                        Some(column) => {
                            column.type_name = type_name;
                            column.nullable = nullable;
                        }
                        None => columns.push(ColumnNode {
                            name: name.clone(),
                            type_name,
                            nullable,
                            primary_key: name == "_id",
                            foreign_key: None,
                            default: None,
                        }),
                    }
                }
            }
        }
        Ok(columns)
    }

    /// How many documents a collection holds, and the validator it was created with.
    async fn details(&self, schema: &str, relation: &str) -> Result<sqmeow_db::node::Details> {
        let reply = self
            .client
            .database(schema)
            .run_command(doc! { "count": relation })
            .await
            .map_err(Error::driver)?;
        let documents = reply.get("n").and_then(count).unwrap_or(0);
        let definition = self.validator(schema, relation).await?.map(|validator| {
            serde_json::to_string_pretty(&Bson::Document(validator).into_relaxed_extjson())
                .unwrap_or_default()
        });
        Ok(sqmeow_db::node::Details {
            properties: vec![("documents".to_owned(), documents.to_string())],
            definition,
            ..sqmeow_db::node::Details::default()
        })
    }

    async fn indexes(
        &self,
        schema: &str,
        relation: &str,
    ) -> Result<Vec<sqmeow_db::node::IndexNode>> {
        let mut cursor = self
            .client
            .database(schema)
            .collection::<Document>(relation)
            .list_indexes()
            .await
            .map_err(Error::driver)?;

        let mut indexes = Vec::new();
        while let Some(model) = cursor.next().await {
            let model = model.map_err(Error::driver)?;
            let options = model.options.unwrap_or_default();
            let name = options.name.unwrap_or_default();
            let primary = name == "_id_";
            indexes.push(sqmeow_db::node::IndexNode {
                // An ascending key is named alone, and any other kind with its direction or type.
                columns: model
                    .keys
                    .iter()
                    .map(|(field, kind)| match kind {
                        Bson::Int32(1) | Bson::Int64(1) => field.clone(),
                        Bson::String(kind) => format!("{field} {kind}"),
                        other => format!("{field} {}", other.clone().into_relaxed_extjson()),
                    })
                    .collect(),
                unique: primary || options.unique == Some(true),
                primary,
                name,
            });
        }
        Ok(indexes)
    }

    /// Close the pool without waiting on a cursor a running query still holds.
    async fn close(&self) {
        self.client.clone().shutdown().immediate(true).await;
    }
}

/// A `find` or `aggregate` narrowed by `condition` and ordered by `order`, each a JSON document.
pub fn filtered(statement: &str, condition: &str, order: &str) -> Result<String> {
    let document = |text: &str, what: &str| -> Result<Option<Document>> {
        if text.trim().is_empty() {
            return Ok(None);
        }
        let json: serde_json::Value = serde_json::from_str(text)
            .map_err(|error| Error::driver(format!("the {what} is not JSON: {error}")))?;
        match Bson::try_from(json).map_err(Error::driver)? {
            Bson::Document(document) => Ok(Some(document)),
            _ => Err(Error::driver(format!(
                r#"the {what} must be a document, such as {{"age": {{"$gt": 30}}}}"#
            ))),
        }
    };
    let condition = document(condition, "filter")?;
    let order = document(order, "sort")?;
    let Statement::Command { db, mut command } = parse(statement)? else {
        return Err(Error::driver("only a command can be filtered"));
    };

    match command_name(&command) {
        "find" => {
            if let Some(condition) = condition {
                let filter = match command.remove("filter") {
                    Some(Bson::Document(existing)) if !existing.is_empty() => {
                        doc! { "$and": [existing, condition] }
                    }
                    _ => condition,
                };
                command.insert("filter", filter);
            }
            if let Some(order) = order {
                command.insert("sort", order);
            }
        }
        "aggregate" => {
            let pipeline = command
                .get_array_mut("pipeline")
                .map_err(|_| Error::driver("an aggregate needs a pipeline"))?;
            if let Some(condition) = condition {
                pipeline.push(Bson::Document(doc! { "$match": condition }));
            }
            if let Some(order) = order {
                pipeline.push(Bson::Document(doc! { "$sort": order }));
            }
        }
        _ => return Err(Error::driver("only a find or an aggregate can be filtered")),
    }
    if let Some(db) = db {
        command.insert("$db", db);
    }
    Ok(Bson::Document(command).into_relaxed_extjson().to_string())
}

/// The filter a document meets when field `name` holds `cell`, as the result read it.
pub fn condition(name: &str, type_name: &str, cell: &Cell) -> Result<String> {
    let value = match cell {
        Cell::Null => Bson::Null,
        Cell::Json(text) => serde_json::from_str::<serde_json::Value>(text)
            .ok()
            .and_then(|json| Bson::try_from(json).ok())
            .unwrap_or_else(|| Bson::String(text.clone())),
        other => id_bson(other, type_name)?,
    };
    let mut filter = Document::new();
    filter.insert(name, value);
    Ok(Bson::Document(filter).into_relaxed_extjson().to_string())
}

/// Whether an error says the deployment has no transactions, as a standalone server does.
fn no_transactions(error: &mongodb::error::Error) -> bool {
    matches!(*error.kind, mongodb::error::ErrorKind::Command(ref command) if command.code == 20)
}

/// Why a write's reply means it did not happen: the server refused it, or nothing had the `_id`.
fn written(reply: &Document) -> std::result::Result<(), String> {
    // A write the server refused still answers `ok`, with the reason in `writeErrors`.
    if let Ok(errors) = reply.get_array("writeErrors")
        && let Some(first) = errors.first()
    {
        return Err(first.clone().into_relaxed_extjson().to_string());
    }
    // Nothing matched the `_id`, so the document went away since the result was read.
    if reply.get("n").and_then(count) == Some(0) {
        return Err("no document had that _id any more".to_owned());
    }
    Ok(())
}

/// Read a statement: `use <database>`, or a command document.
fn parse(statement: &str) -> Result<Statement> {
    let mut words = statement.split_whitespace();
    if words.next() == Some("use") {
        return match (words.next(), words.next()) {
            (Some(name), None) => Ok(Statement::Use(name.to_owned())),
            _ => Err(Error::driver("`use` takes one database name")),
        };
    }

    let json: serde_json::Value = serde_json::from_str(statement).map_err(|error| {
        Error::driver(format!(
            "a MongoDB statement is a command in Extended JSON, or `use <database>`: {error}"
        ))
    })?;
    let Bson::Document(mut command) = Bson::try_from(json).map_err(Error::driver)? else {
        return Err(Error::driver(
            r#"a command is a JSON object, such as {"ping": 1}"#,
        ));
    };

    // `$db` is the database the wire protocol sends a command to, so it reads as that here too.
    let db = match command.remove("$db") {
        None => None,
        Some(Bson::String(name)) => Some(name),
        Some(_) => return Err(Error::driver("`$db` must be a database name")),
    };
    if command.is_empty() {
        return Err(Error::driver("there is no command to run"));
    }
    Ok(Statement::Command { db, command })
}

/// Bind BSON scalars after Extended JSON parsing, retaining the original command structure.
fn bound_statement(statement: &str, values: &[ParameterValue]) -> Result<Statement> {
    let values = named_values(Dialect::MongoDb, statement, values).map_err(Error::Driver)?;
    let mut parsed = parse(statement)?;
    match &mut parsed {
        Statement::Use(name) => {
            if parameter_value(name, &values).is_some() {
                return Err(Error::driver("a parameter cannot name a MongoDB database"));
            }
        }
        Statement::Command { db, command } => {
            if db
                .as_ref()
                .is_some_and(|name| parameter_value(name, &values).is_some())
            {
                return Err(Error::driver("a parameter cannot name a MongoDB database"));
            }
            // The first value dispatches the command (usually to a collection). Even a nested
            // placeholder here must not change that dispatch after the engine's safety check.
            if command
                .iter()
                .next()
                .is_some_and(|(_, value)| contains_parameter(value, &values))
            {
                return Err(Error::driver(
                    "a parameter cannot change MongoDB command dispatch",
                ));
            }
            bind_document(command, &values)?;
        }
    }
    Ok(parsed)
}

fn parameter_value<'a>(
    text: &str,
    values: &'a HashMap<String, ParameterValue>,
) -> Option<&'a ParameterValue> {
    text.strip_prefix(':').and_then(|name| values.get(name))
}

fn contains_parameter(value: &Bson, values: &HashMap<String, ParameterValue>) -> bool {
    match value {
        Bson::String(text) => parameter_value(text, values).is_some(),
        Bson::Array(items) => items.iter().any(|item| contains_parameter(item, values)),
        Bson::Document(document) => document.iter().any(|(key, value)| {
            parameter_value(key, values).is_some() || contains_parameter(value, values)
        }),
        _ => false,
    }
}

fn bind_document(document: &mut Document, values: &HashMap<String, ParameterValue>) -> Result<()> {
    for (key, value) in document.iter_mut() {
        if parameter_value(key, values).is_some() {
            return Err(Error::driver("a parameter cannot name a MongoDB field"));
        }
        bind_bson(value, values)?;
    }
    Ok(())
}

fn bind_bson(value: &mut Bson, values: &HashMap<String, ParameterValue>) -> Result<()> {
    match value {
        Bson::String(text) => {
            if let Some(parameter) = parameter_value(text, values) {
                *value = match parameter {
                    ParameterValue::Text(text) => Bson::String(text.clone()),
                    ParameterValue::Int(number) => Bson::Int64(*number),
                    ParameterValue::Float(number) => Bson::Double(*number),
                    ParameterValue::Bool(flag) => Bson::Boolean(*flag),
                    ParameterValue::Null(_) => Bson::Null,
                };
            }
        }
        Bson::Array(items) => {
            for item in items {
                bind_bson(item, values)?;
            }
        }
        Bson::Document(document) => bind_document(document, values)?,
        _ => {}
    }
    Ok(())
}

/// The command with a `comment` that `kill` can find it by, and that comment.
fn tagged(mut command: Document) -> (Document, String) {
    let tag = match command.get_str("comment") {
        Ok(comment) => comment.to_owned(),
        Err(_) => {
            let tag = format!(
                "sqmeow-{}-{}",
                std::process::id(),
                TAGS.fetch_add(1, Ordering::Relaxed)
            );
            command.insert("comment", tag.as_str());
            tag
        }
    };
    (command, tag)
}

/// The command's name, which the server reads off the first key.
fn command_name(command: &Document) -> &str {
    command.keys().next().map_or("", String::as_str)
}

/// Run one command and lay out what it answers.
async fn run(
    database: &Database,
    statement: &str,
    command: Document,
    max_rows: usize,
) -> Result<ResultSet> {
    let name = command_name(&command).to_owned();
    let collection = command.get_str(&name).ok().map(str::to_owned);

    if !CURSOR_COMMANDS.contains(&name.as_str()) {
        let reply = database.run_command(command).await.map_err(Error::driver)?;
        let written = WRITE_COMMANDS
            .contains(&name.as_str())
            .then(|| reply.get("n").and_then(count))
            .flatten();
        // The cluster's clock and signature are the driver's business, not an answer.
        let reply: Document = reply
            .into_iter()
            .filter(|(key, _)| key != "operationTime" && !key.starts_with('$'))
            .collect();

        let mut result = to_result(statement, vec![reply]);
        if let Some(written) = written {
            result.set_affected(written);
        }
        return Ok(result);
    }

    // An aggregate that only filters, sorts and pages answers with documents as they are stored.
    let stored = name == "find"
        || (name == "aggregate"
            && command.get_array("pipeline").is_ok_and(|stages| {
                stages.iter().all(|stage| {
                    stage.as_document().is_some_and(|stage| {
                        stage.keys().all(|key| {
                            matches!(key.as_str(), "$match" | "$sort" | "$limit" | "$skip")
                        })
                    })
                })
            }));

    let mut cursor = database
        .run_cursor_command(command)
        .await
        .map_err(Error::driver)?;
    let mut documents = Vec::new();
    let mut truncated = false;
    while let Some(document) = cursor.next().await {
        if documents.len() >= max_rows {
            truncated = true;
            break;
        }
        documents.push(document.map_err(Error::driver)?);
    }

    let mut result = to_result(statement, documents);
    if truncated {
        result.mark_truncated();
    }
    // Stored documents are found again by `_id`, unless a projection left it out.
    if stored
        && let Some(collection) = collection
        && (result.row_count() == 0
            || result
                .columns()
                .first()
                .is_some_and(|column| column.name == "_id"))
    {
        result.set_source(Some(Source::Collection {
            db: database.name().to_owned(),
            name: collection,
            key: "_id".into(),
        }));
    }
    Ok(result)
}

/// Plan changes to a collection into `update`, `delete` and `insert` commands, one per line of
/// Extended JSON, each naming its database.
fn plan(result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
    let Some(source @ Source::Collection { db, name, .. }) = result.source() else {
        return Err(edit::not_editable());
    };
    let line = |mut command: Document| {
        command.insert("$db", db.clone());
        Bson::Document(command).into_relaxed_extjson().to_string()
    };
    let field = |column: usize| result.columns()[column].name.clone();
    let id = |row: usize| -> Result<Bson> {
        check_row(result, row)?;
        let kind = result
            .columns()
            .first()
            .map_or("", |column| column.type_name.as_str());
        id_bson(result.cell(row, 0).as_deref().unwrap_or(&Cell::Null), kind)
    };

    let mut commands = Vec::new();
    for (row, cells) in changes.live_updates() {
        let mut set = Document::new();
        for (column, value) in cells {
            check_column(source, result, *column)?;
            set.insert(field(*column), value_bson(value)?);
        }
        commands.push(line(doc! {
            "update": name,
            "updates": [{ "q": { "_id": id(*row)? }, "u": { "$set": set } }],
        }));
    }
    for &row in &changes.deletes {
        commands.push(line(doc! {
            "delete": name,
            "deletes": [{ "q": { "_id": id(row)? }, "limit": 1 }],
        }));
    }
    for cells in &changes.inserts {
        let mut document = Document::new();
        for (column, value) in cells {
            if *column >= result.columns().len() {
                return Err(Error::driver(format!("there is no column {column}")));
            }
            document.insert(field(*column), value_bson(value)?);
        }
        commands.push(line(doc! { "insert": name, "documents": [document] }));
    }
    Ok(commands)
}

/// A value typed into a cell.
fn value_bson(value: &edit::Value) -> Result<Bson> {
    let text = match value {
        edit::Value::Null => return Ok(Bson::Null),
        edit::Value::Text(text) => text,
        edit::Value::Sql(_) => return Err(Error::driver("MongoDB takes no SQL expression")),
    };
    Ok(serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|json| Bson::try_from(json).ok())
        .unwrap_or_else(|| Bson::String(text.clone())))
}

/// The `_id` a row was read with, as the BSON that matches it again.
fn id_bson(cell: &Cell, kind: &str) -> Result<Bson> {
    Ok(match cell {
        Cell::Text(hex) if kind == "objectId" => {
            Bson::ObjectId(ObjectId::parse_str(hex).map_err(Error::driver)?)
        }
        Cell::Text(text) => Bson::String(text.clone()),
        Cell::Int(number) => Bson::Int64(*number),
        Cell::Float(number) => Bson::Double(*number),
        Cell::Bool(flag) => Bson::Boolean(*flag),
        Cell::Uuid(text) => Bson::Binary(bson::Binary::from_uuid(
            bson::Uuid::parse_str(text).map_err(Error::driver)?,
        )),
        other => {
            return Err(Error::driver(format!(
                "an _id of type {} cannot be matched again",
                other.type_name()
            )));
        }
    })
}

fn count(value: &Bson) -> Option<u64> {
    match value {
        Bson::Int32(n) => u64::try_from(*n).ok(),
        Bson::Int64(n) => u64::try_from(*n).ok(),
        _ => None,
    }
}

/// Lay documents out as rows, a column per top-level field in the order fields are first seen.
fn to_result(statement: &str, documents: Vec<Document>) -> ResultSet {
    let mut names: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for document in &documents {
        for key in document.keys() {
            if seen.insert(key.as_str()) {
                names.push(key.clone());
            }
        }
    }
    if let Some(at) = names.iter().position(|name| name == "_id") {
        let id = names.remove(at);
        names.insert(0, id);
    }

    let columns = names
        .iter()
        .map(|name| Column::new(name.clone(), common_type(&documents, name)))
        .collect();
    let mut result = ResultSet::new(statement, columns);
    for mut document in documents {
        result.push_row(
            names
                .iter()
                .map(|name| document.remove(name).map_or(Cell::Null, cell))
                .collect(),
        );
    }
    result
}

/// The BSON type every value of a field shares, or nothing when they differ.
fn common_type(documents: &[Document], field: &str) -> &'static str {
    let mut kinds = documents
        .iter()
        .filter_map(|document| document.get(field))
        .filter(|value| !matches!(value, Bson::Null))
        .map(type_name);
    let Some(first) = kinds.next() else {
        return "";
    };
    if kinds.all(|kind| kind == first) {
        first
    } else {
        ""
    }
}

/// A value's type, spelled the way `$type` spells it.
fn type_name(value: &Bson) -> &'static str {
    match value {
        Bson::Double(_) => "double",
        Bson::String(_) => "string",
        Bson::Document(_) => "object",
        Bson::Array(_) => "array",
        Bson::Binary(_) => "binData",
        Bson::Undefined => "undefined",
        Bson::ObjectId(_) => "objectId",
        Bson::Boolean(_) => "bool",
        Bson::DateTime(_) => "date",
        Bson::Null => "null",
        Bson::RegularExpression(_) => "regex",
        Bson::DbPointer(_) => "dbPointer",
        Bson::JavaScriptCode(_) => "javascript",
        Bson::Symbol(_) => "symbol",
        Bson::JavaScriptCodeWithScope(_) => "javascriptWithScope",
        Bson::Int32(_) => "int",
        Bson::Timestamp(_) => "timestamp",
        Bson::Int64(_) => "long",
        Bson::Decimal128(_) => "decimal",
        Bson::MinKey => "minKey",
        Bson::MaxKey => "maxKey",
    }
}

/// The fields a sample of documents has, for the drawer.
fn field_nodes(documents: &[Document]) -> Vec<ColumnNode> {
    let mut columns: Vec<ColumnNode> = Vec::new();
    for document in documents {
        for (name, value) in document {
            let null = matches!(value, Bson::Null);
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
                    type_name: type_name(value).to_owned(),
                    nullable: null,
                    primary_key: name == "_id",
                    foreign_key: None,
                    default: None,
                }),
            }
        }
    }
    for column in &mut columns {
        column.nullable |= documents
            .iter()
            .any(|document| !document.contains_key(&column.name));
    }
    columns
}

fn cell(value: Bson) -> Cell {
    match value {
        Bson::Null | Bson::Undefined => Cell::Null,
        Bson::Boolean(flag) => Cell::Bool(flag),
        Bson::Int32(number) => Cell::Int(number.into()),
        Bson::Int64(number) => Cell::Int(number),
        Bson::Double(number) => Cell::Float(number),
        Bson::Decimal128(number) => Cell::Decimal(number.to_string()),
        Bson::String(text) | Bson::Symbol(text) => Cell::Text(text),
        Bson::ObjectId(id) => Cell::Text(id.to_hex()),
        // A date past year 9999 has no RFC 3339 form, and its milliseconds are still the truth.
        Bson::DateTime(at) => at
            .try_to_rfc3339_string()
            .map_or_else(|_| Cell::Int(at.timestamp_millis()), Cell::Timestamp),
        Bson::Binary(binary) if binary.subtype == BinarySubtype::Uuid => {
            match <[u8; 16]>::try_from(binary.bytes.as_slice()) {
                Ok(bytes) => Cell::Uuid(bson::Uuid::from_bytes(bytes).to_string()),
                Err(_) => Cell::bytes(&binary.bytes),
            }
        }
        Bson::Binary(binary) => Cell::bytes(&binary.bytes),
        value @ (Bson::Document(_) | Bson::Array(_)) => {
            Cell::Json(value.into_relaxed_extjson().to_string())
        }
        other => Cell::Unsupported {
            type_name: type_name(&other).to_owned(),
            raw: other.into_relaxed_extjson().to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    #[tokio::test(flavor = "current_thread")]
    async fn standalone_cancel_after_server_write_reports_partial_progress() {
        use mongodb::event::{EventHandler, command::CommandEvent};
        let Ok(url) = std::env::var("SQMEOW_TEST_MONGODB_URL") else {
            eprintln!("skipped: set SQMEOW_TEST_MONGODB_URL");
            return;
        };
        let cancel = CancellationToken::new();
        let stopped = cancel.clone();
        let mut options = ClientOptions::parse(&url).await.unwrap();
        let db = options
            .default_database
            .clone()
            .unwrap_or_else(|| "test".into());
        // Monitoring runs before run_command returns the successful reply.
        // Cancel exactly after a server-confirmed insert, not on a timer.
        options.command_event_handler = Some(EventHandler::callback(move |event| {
            if matches!(event, CommandEvent::Succeeded(event) if event.command_name == "insert") {
                stopped.cancel();
            }
        }));
        let adapter = MongoAdapter {
            client: Client::with_options(options).unwrap(),
            db: RwLock::new(db),
            cluster: false,
        };
        let observer = MongoAdapter::connect(&url, None).await.unwrap();
        let collection = observer
            .client
            .database(&observer.database())
            .collection::<Document>("audit_cancel_reply");
        collection.delete_many(doc! {}).await.unwrap();
        let commands = [
            (
                adapter.database(),
                doc! {"insert":"audit_cancel_reply", "documents":[{"_id":1}]},
            ),
            (
                adapter.database(),
                doc! {"insert":"audit_cancel_reply", "documents":[{"_id":2}]},
            ),
        ];
        let error = adapter.apply_in_turn(&commands, &cancel).await.unwrap_err();
        assert!(!matches!(error, Error::Cancelled));
        assert!(error.to_string().contains("1 of 2"), "{error}");
        assert_eq!(collection.count_documents(doc! {"_id":1}).await.unwrap(), 1);
        assert_eq!(collection.count_documents(doc! {"_id":2}).await.unwrap(), 0);
        collection.drop().await.unwrap();
    }

    #[test]
    fn aggregation_bindings_require_literal_expression_protection() {
        let source = r#"{"aggregate":"users","pipeline":[{"$project":{"value":{"$literal":":value"}}}],"cursor":{}}"#;
        let Statement::Command { command, .. } =
            bound_statement(source, &[ParameterValue::Text("$secret".into())]).unwrap()
        else {
            panic!("expected a command")
        };
        let stage = command.get_array("pipeline").unwrap()[0]
            .as_document()
            .unwrap();
        let projected = stage
            .get_document("$project")
            .unwrap()
            .get_document("value")
            .unwrap();
        assert_eq!(projected.get_str("$literal").unwrap(), "$secret");
        let unsafe_source =
            r#"{"aggregate":"users","pipeline":[{"$project":{"value":":value"}}],"cursor":{}}"#;
        assert!(bound_statement(unsafe_source, &[ParameterValue::Text("$secret".into())]).is_err());
    }

    #[test]
    fn native_bindings_preserve_nested_scalar_types_and_never_parse_text() {
        let input = "hello world\n\"}, \"delete\": \"other\"\n:text";
        let parsed = bound_statement(
            r#"{"find":"users","filter":{"nested":[":text",{"i":":int","f":":float","b":":bool","n":":null","again":":text"}],"literal":"prefix :text","id":{"$oid":"507f1f77bcf86cd799439011"}}}"#,
            &[
                ParameterValue::Text(input.into()), ParameterValue::Int(42),
                ParameterValue::Float(1.5), ParameterValue::Bool(true),
                ParameterValue::Null(sqmeow_db::sql::parameters::Kind::Text),
            ],
        ).unwrap();
        let Statement::Command { command, .. } = parsed else {
            panic!("expected command")
        };
        assert_eq!(command.get_str("find").unwrap(), "users");
        let filter = command.get_document("filter").unwrap();
        let nested = filter.get_array("nested").unwrap();
        assert_eq!(nested[0], Bson::String(input.into()));
        let document = nested[1].as_document().unwrap();
        assert_eq!(document.get("i"), Some(&Bson::Int64(42)));
        assert_eq!(document.get("f"), Some(&Bson::Double(1.5)));
        assert_eq!(document.get("b"), Some(&Bson::Boolean(true)));
        assert_eq!(document.get("n"), Some(&Bson::Null));
        assert_eq!(document.get_str("again").unwrap(), input);
        assert_eq!(filter.get_str("literal").unwrap(), "prefix :text");
        assert!(matches!(filter.get("id"), Some(Bson::ObjectId(_))));
    }

    #[test]
    fn bindings_cannot_change_dispatch_database_or_document_keys() {
        let values = [ParameterValue::Text("other".into())];
        assert!(bound_statement(r#"{"find":":name"}"#, &values).is_err());
        assert!(bound_statement(r#"{"find":"users","$db":":name"}"#, &values).is_err());
        assert!(bound_statement("use :name", &values).is_err());
        assert!(bound_statement(r#"{"find":"users","filter":{":name":1}}"#, &values).is_err());
        // Harden the structural binder too, independently of lexical validation.
        let map = HashMap::from([("name".into(), ParameterValue::Text("other".into()))]);
        assert!(bind_document(&mut doc! { ":name": 1 }, &map).is_err());
    }

    use mongodb::bson::oid::ObjectId;
    use mongodb::bson::{DateTime, Decimal128};
    use sqmeow_db::types::TypeClass;

    use super::*;

    fn people() -> ResultSet {
        let id = ObjectId::parse_str("65a1b2c3d4e5f60718293a4b").unwrap();
        let mut result = to_result("find", vec![doc! { "_id": id, "name": "al" }]);
        result.set_source(Some(Source::Collection {
            db: "app".into(),
            name: "people".into(),
            key: "_id".into(),
        }));
        result
    }

    #[test]
    fn changes_become_commands_finding_documents_by_id() {
        let changes = Changes {
            updates: vec![(0, vec![(1, "bob".into())])],
            deletes: vec![0],
            inserts: vec![vec![(1, "42".into())]],
        };
        // The update to a document being deleted is dropped.
        assert_eq!(
            plan(&people(), &changes).unwrap(),
            vec![
                r#"{"delete":"people","deletes":[{"q":{"_id":{"$oid":"65a1b2c3d4e5f60718293a4b"}},"limit":1}],"$db":"app"}"#,
                r#"{"insert":"people","documents":[{"name":42}],"$db":"app"}"#,
            ]
        );
    }

    #[test]
    fn a_planned_command_parses_back_with_its_name_first() {
        let changes = Changes {
            updates: vec![(0, vec![(1, sqmeow_db::edit::Value::Null)])],
            ..Changes::default()
        };
        let line = &plan(&people(), &changes).unwrap()[0];
        let Statement::Command { db, command } = parse(line).unwrap() else {
            panic!("a command");
        };
        assert_eq!(db.as_deref(), Some("app"));
        assert_eq!(command_name(&command), "update");
    }

    #[test]
    fn the_id_itself_cannot_be_edited() {
        let changes = Changes {
            updates: vec![(0, vec![(0, "x".into())])],
            ..Changes::default()
        };
        assert!(plan(&people(), &changes).is_err());
    }

    #[test]
    fn use_names_a_database() {
        assert_eq!(
            parse("  use   shop ").unwrap(),
            Statement::Use("shop".into())
        );
        assert!(parse("use").is_err());
        assert!(parse("use a b").is_err());
    }

    #[test]
    fn a_command_keeps_its_key_order_and_gives_up_its_db() {
        let Ok(Statement::Command { db, command }) =
            parse(r#"{"find": "users", "filter": {"age": {"$gt": 30}}, "$db": "shop"}"#)
        else {
            panic!("should parse as a command");
        };
        assert_eq!(db.as_deref(), Some("shop"));
        assert_eq!(command_name(&command), "find");
        assert_eq!(command.keys().collect::<Vec<_>>(), vec!["find", "filter"]);
    }

    #[test]
    fn extended_json_types_are_read() {
        let Ok(Statement::Command { command, .. }) =
            parse(r#"{"find": "a", "filter": {"_id": {"$oid": "65a1b2c3d4e5f60718293a4b"}}}"#)
        else {
            panic!("should parse as a command");
        };
        let filter = command.get_document("filter").unwrap();
        assert!(matches!(filter.get("_id"), Some(Bson::ObjectId(_))));
    }

    #[test]
    fn anything_but_an_object_is_refused() {
        assert!(parse("[1, 2]").is_err());
        assert!(parse("{}").is_err());
        assert!(parse("db.users.find()").is_err());
        assert!(parse(r#"{"ping": 1, "$db": 3}"#).is_err());
    }

    #[test]
    fn documents_share_one_set_of_columns_with_id_first() {
        let documents = vec![
            doc! { "name": "alice", "_id": 1, "tags": ["a", "b"] },
            doc! { "_id": 2, "age": 30 },
        ];
        let result = to_result("find", documents);

        let names: Vec<&str> = result.columns().iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["_id", "name", "tags", "age"]);
        assert_eq!(
            result.cell(0, 2).as_deref(),
            Some(&Cell::Json(r#"["a","b"]"#.into()))
        );
        assert_eq!(result.cell(1, 1).as_deref(), Some(&Cell::Null));
        assert_eq!(result.columns()[3].class, TypeClass::Number);
        assert_eq!(result.columns()[2].class, TypeClass::Json);
    }

    #[test]
    fn a_column_of_mixed_types_claims_none() {
        let result = to_result("find", vec![doc! { "v": 1 }, doc! { "v": "one" }]);
        assert_eq!(result.columns()[0].class, TypeClass::Unknown);
    }

    #[test]
    fn bson_values_become_cells() {
        let id = ObjectId::parse_str("65a1b2c3d4e5f60718293a4b").unwrap();
        assert_eq!(
            cell(Bson::ObjectId(id)),
            Cell::Text("65a1b2c3d4e5f60718293a4b".into())
        );
        assert_eq!(
            cell(Bson::DateTime(DateTime::from_millis(0))),
            Cell::Timestamp("1970-01-01T00:00:00Z".into())
        );
        assert_eq!(
            cell(Bson::Decimal128("1.50".parse::<Decimal128>().unwrap())),
            Cell::Decimal("1.50".into())
        );
        assert_eq!(cell(Bson::Int32(7)), Cell::Int(7));
    }

    #[test]
    fn a_null_does_not_decide_a_fields_type() {
        let fields = field_nodes(&[doc! { "name": null }, doc! { "name": "a" }]);
        assert_eq!(fields[0].type_name, "string");
        assert!(fields[0].nullable);
    }

    #[test]
    fn a_field_missing_from_some_documents_is_nullable() {
        let fields = field_nodes(&[doc! { "_id": 1, "name": "a" }, doc! { "_id": 2 }]);
        assert_eq!(fields.len(), 2);
        assert!(fields[0].primary_key && !fields[0].nullable);
        assert!(fields[1].nullable);
        assert_eq!(fields[1].type_name, "string");
    }

    #[test]
    fn a_find_or_an_aggregate_is_filtered_and_sorted() {
        assert_eq!(
            filtered(
                r#"{"find": "people", "filter": {"age": {"$gt": 1}}, "$db": "app"}"#,
                r#"{"name": "al"}"#,
                r#"{"age": -1}"#
            )
            .unwrap(),
            r#"{"find":"people","filter":{"$and":[{"age":{"$gt":1}},{"name":"al"}]},"sort":{"age":-1},"$db":"app"}"#
        );
        assert_eq!(
            filtered(
                r#"{"aggregate": "people", "pipeline": [], "cursor": {}}"#,
                r#"{"a": 1}"#,
                ""
            )
            .unwrap(),
            r#"{"aggregate":"people","pipeline":[{"$match":{"a":1}}],"cursor":{}}"#
        );
        assert!(filtered(r#"{"count": "people"}"#, r#"{"a": 1}"#, "").is_err());
        assert!(filtered(r#"{"find": "people"}"#, "[1]", "").is_err());
    }

    #[test]
    fn a_cell_becomes_the_filter_that_matches_it() {
        let id = "65a1b2c3d4e5f60718293a4b";
        assert_eq!(
            condition("_id", "objectId", &Cell::Text(id.into())).unwrap(),
            format!(r#"{{"_id":{{"$oid":"{id}"}}}}"#)
        );
        assert_eq!(condition("n", "int", &Cell::Int(3)).unwrap(), r#"{"n":3}"#);
        assert_eq!(
            condition("gone", "null", &Cell::Null).unwrap(),
            r#"{"gone":null}"#
        );
    }
}
