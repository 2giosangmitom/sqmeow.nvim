//! The MongoDB adapter.
//!
//! MongoDB speaks no SQL, and the mongosh syntax people know is JavaScript run by Node, which no
//! Rust library reads. So a statement is a database command written as Extended JSON, the form
//! `bson` reads itself: `{"find": "users", "filter": {"age": {"$gt": 30}}}`. Documents are rows,
//! with a column per top-level field. The drawer's schemas are databases and its relations are
//! collections.

use std::collections::HashSet;
use std::sync::{PoisonError, RwLock};
use std::time::Instant;

use futures_util::StreamExt;
use mongodb::bson::spec::BinarySubtype;
use mongodb::bson::{self, Bson, Document, doc};
use mongodb::options::ClientOptions;
use mongodb::results::CollectionType;
use mongodb::{Client, Database};
use sqmeow_db::{
    Adapter, Cell, Column, ColumnNode, Dialect, Error, RelationKind, RelationNode, Result,
    ResultSet, RoutineNode, SchemaNode,
};
use tokio_util::sync::CancellationToken;

/// How many documents a collection's fields are read from.
// ponytail: a random sample, so a field only rare documents have can be missed; widen it if so
const SAMPLE_SIZE: i32 = 100;

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
    ///
    /// The driver keeps a pool of its own, and a `use` is this adapter's state rather than the
    /// server's, so nothing depends on one socket staying the same.
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

        // The driver connects lazily, so without this a wrong host would only be reported by the
        // first query.
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
    ///
    /// Each is then opened as a connection of its own, as a PostgreSQL cluster's are, so the one to
    /// query is chosen with the drawer's `u` rather than a `use` typed into a scratchpad.
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

    /// The database commands run on, which `use` changes.
    pub fn database(&self) -> String {
        self.db
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl Adapter for MongoAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::MongoDb
    }

    /// A name as a JSON string, which is how a command document names a collection.
    fn quote_ident(&self, name: &str) -> String {
        serde_json::Value::from(name).to_string()
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        let started = Instant::now();

        let mut result = match parse(statement)? {
            Statement::Use(name) => {
                let mut result = ResultSet::new(statement, vec![Column::new("result", "string")]);
                result.push_row(vec![Cell::Text(format!("switched to db {name}"))]);
                *self.db.write().unwrap_or_else(PoisonError::into_inner) = name;
                result
            }
            Statement::Command { db, command } => {
                let database = self.client.database(&db.unwrap_or_else(|| self.database()));
                // Dropping the query drops its cursor, which tells the server to stop.
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => return Err(Error::Cancelled),
                    result = run(&database, statement, command, max_rows) => result?,
                }
            }
        };

        result.set_elapsed(started.elapsed());
        Ok(result)
    }

    /// The database commands run on, which `use` changes, even before it holds anything.
    ///
    /// Only that one. A URL that names no database has the others listed as databases of their own.
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
        Ok(field_nodes(&documents))
    }

    /// Close the pool without waiting on a cursor a running query still holds, which the driver
    /// would otherwise wait for indefinitely.
    async fn close(&self) {
        self.client.clone().shutdown().immediate(true).await;
    }
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
    Ok(result)
}

fn count(value: &Bson) -> Option<u64> {
    match value {
        Bson::Int32(n) => u64::try_from(*n).ok(),
        Bson::Int64(n) => u64::try_from(*n).ok(),
        _ => None,
    }
}

/// Lay documents out as rows, a column per top-level field in the order fields are first seen.
///
/// `_id` comes first, as it does in every stored document. A document without a field has a null
/// in its column.
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
///
/// Nulls and missing fields are skipped: they say nothing about what the others hold.
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
///
/// A field is nullable when any sampled document holds null in it or lacks it altogether.
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
    use mongodb::bson::oid::ObjectId;
    use mongodb::bson::{DateTime, Decimal128};
    use sqmeow_db::TypeClass;

    use super::*;

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
        assert_eq!(result.cell(0, 2), Some(&Cell::Json(r#"["a","b"]"#.into())));
        assert_eq!(result.cell(1, 1), Some(&Cell::Null));
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
}
