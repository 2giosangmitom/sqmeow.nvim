//! Reading the schema tree the drawer shows.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::{
    ColumnNode, Details, Dialect, Error as DbError, IndexNode, KeyType, RelationKind, RelationNode,
    RoleNode, RoutineKind, RoutineNode, SchemaNode,
};

use sqmeow_adapters::Backend;

use super::{Core, Started};
use crate::args::Args;
use crate::session::Connection;
use crate::value::{map, strings};

impl Core {
    pub(super) fn introspect(self: Arc<Self>, args: &Args) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        // An empty path means the connection itself, whose children are its schemas.
        let path = args.opt_strings("path")?.unwrap_or_default();
        if path.len() > 3 {
            return Err("a schema path is at most [schema, group, relation]".to_owned());
        }
        // A glob the drawer lists a Redis database's keys by.
        let pattern = args
            .opt_string("pattern")
            .filter(|pattern| !pattern.is_empty());
        let connection = self.connection(conn_id)?;

        let work = self.read_level(connection, path, pattern);
        Ok((Value::Boolean(true), Box::pin(work)))
    }

    /// Read a table's columns and indexes, and report them through `structure:done`.
    pub(super) fn structure(self: Arc<Self>, args: &Args) -> Started {
        let conn_id = args.conn_id("conn_id")?;
        // Empty for a table the result names without one.
        let schema = args.opt_string("schema").unwrap_or_default();
        let relation = args.string("relation")?;
        let connection = self.connection(conn_id)?;

        let work = async move {
            let backend = &connection.backend;
            let read = async {
                let named = match schema.as_str() {
                    "" => default_schema(backend).await?,
                    named => named.to_owned(),
                };
                let columns = backend.columns(&named, &relation).await?;
                let indexes = backend.indexes(&named, &relation).await?;
                Ok::<_, DbError>((columns, indexes, backend.details(&named, &relation).await?))
            };
            let mut payload = vec![
                ("conn_id", Value::from(conn_id)),
                ("schema", Value::from(schema.as_str())),
                ("relation", Value::from(relation.as_str())),
            ];
            match read.await {
                Ok((columns, indexes, details)) => {
                    payload.push(("columns", Value::Array(column_nodes(columns))));
                    payload.push(("indexes", Value::Array(index_nodes(indexes))));
                    payload.extend(details_payload(details));
                }
                Err(error) => payload.push(("error", Value::from(error.to_string()))),
            }
            self.emit("structure:done", map(payload));
        };
        Ok((Value::Boolean(true), Box::pin(work)))
    }

    /// Read one level of the schema tree.
    async fn read_level(
        self: Arc<Self>,
        connection: Arc<Connection>,
        path: Vec<String>,
        pattern: Option<String>,
    ) {
        let pattern = pattern.as_deref();
        let nodes = match path.as_slice() {
            [] => top_nodes(&connection).await,
            [group] if group == ROLES => connection.backend.roles().await.map(role_nodes),
            [schema] => group_nodes(&connection, schema, pattern).await,
            [schema, group] => members(&connection, schema, group, pattern).await,
            // The group a relation sits under says nothing about its columns, so it is skipped.
            [schema, _group, relation] => connection
                .backend
                .columns(schema, relation)
                .await
                .map(column_nodes),
            _ => return,
        };

        let mut payload = vec![
            ("conn_id", Value::from(connection.id)),
            ("path", strings(path)),
        ];
        match nodes {
            Ok(nodes) => payload.push(("nodes", Value::Array(nodes))),
            Err(error) => {
                payload.push(("nodes", Value::Array(vec![])));
                payload.push(("error", Value::from(error.to_string())));
            }
        }
        self.emit("schema:nodes", map(payload));
    }
}

/// The key the Roles heading is drawn under, which no schema is called.
const ROLES: &str = "@roles";

/// A connection's schemas, or a cluster's databases, and the Roles heading where the server has one.
async fn top_nodes(connection: &Connection) -> Result<Vec<Value>, DbError> {
    // A cluster's databases are each opened as a connection of their own.
    let mut nodes = match connection.backend.databases().await {
        Some(databases) => database_nodes(databases?),
        None => schema_nodes(connection.backend.schemas().await?),
    };
    // Left out where the roles cannot be read, as by a user without the right to.
    if matches!(
        connection.backend.dialect(),
        Dialect::Postgres | Dialect::MySql
    ) && let Ok(roles) = connection.backend.roles().await
    {
        nodes.push(group_node(ROLES, "Roles", "roles", roles.len()));
    }
    Ok(nodes)
}

/// A schema's relations, or the keys of a Redis database that match `pattern`.
async fn relations_of(
    connection: &Connection,
    schema: &str,
    pattern: Option<&str>,
) -> Result<Vec<RelationNode>, DbError> {
    match pattern {
        Some(pattern) if connection.backend.dialect() == Dialect::Redis => {
            connection.backend.keys(pattern).await
        }
        _ => connection.backend.relations(schema).await,
    }
}

fn role_nodes(roles: Vec<RoleNode>) -> Vec<Value> {
    roles
        .into_iter()
        .map(|role| {
            map(vec![
                ("name", Value::from(role.name)),
                ("kind", Value::from("role")),
                ("expandable", Value::from(false)),
                ("attributes", strings(role.attributes)),
            ])
        })
        .collect()
}

/// The schema unqualified names resolve to.
pub(super) async fn default_schema(backend: &Backend) -> Result<String, DbError> {
    backend
        .schemas()
        .await?
        .into_iter()
        .find(|schema| schema.is_default)
        .map(|schema| schema.name)
        .ok_or_else(|| DbError::driver("no schema is the default, so the table needs one named"))
}

fn schema_nodes(schemas: Vec<SchemaNode>) -> Vec<Value> {
    schemas
        .into_iter()
        .map(|schema| {
            map(vec![
                ("name", Value::from(schema.name)),
                ("kind", Value::from("schema")),
                ("expandable", Value::from(true)),
                ("is_default", Value::from(schema.is_default)),
            ])
        })
        .collect()
}

/// The databases of a cluster, which the plugin opens one connection each for.
fn database_nodes(databases: Vec<String>) -> Vec<Value> {
    databases
        .into_iter()
        .map(|name| {
            map(vec![
                ("name", Value::from(name)),
                ("kind", Value::from("database")),
                ("expandable", Value::from(true)),
            ])
        })
        .collect()
}

/// The groups a schema is drawn as, each with how many things it holds.
async fn group_nodes(
    connection: &Connection,
    schema: &str,
    pattern: Option<&str>,
) -> Result<Vec<Value>, DbError> {
    let relations = relations_of(connection, schema, pattern).await?;
    let dialect = connection.backend.dialect();

    // Redis holds keys and nothing else, and what a key holds decides how it is read back.
    if dialect == Dialect::Redis {
        // The drawer lists no more keys than the cap, so a count at it may be short.
        let capped = relations.len() >= sqmeow_adapters::redis::MAX_KEYS;
        return Ok(KeyType::ALL
            .into_iter()
            .map(|wanted| {
                let (key, name) = wanted.group();
                let count = relations
                    .iter()
                    .filter(|r| r.kind == RelationKind::Key(wanted))
                    .count();
                let mut node = group_node(key, name, "keys", count);
                if capped && let Value::Map(pairs) = &mut node {
                    pairs.push((Value::from("capped"), Value::from(true)));
                }
                node
            })
            .collect());
    }

    let tables = relations.iter().filter(|r| is_table(r.kind)).count();
    let sequences = relations
        .iter()
        .filter(|r| r.kind == RelationKind::Sequence)
        .count();
    let views = relations.len() - tables - sequences;

    // MongoDB calls its tables collections, and has no stored routines to group.
    if dialect == Dialect::MongoDb {
        return Ok(vec![
            group_node("tables", "Collections", "tables", tables),
            group_node("views", "Views", "views", views),
        ]);
    }

    let routines = connection.backend.routines(schema).await?;
    let procedures = routines
        .iter()
        .filter(|r| r.kind == RoutineKind::Procedure)
        .count();
    let functions = routines.len() - procedures;

    let mut groups = vec![
        group_node("tables", "Tables", "tables", tables),
        group_node("views", "Views", "views", views),
        group_node("functions", "Functions", "functions", functions),
    ];
    if sequences > 0 {
        groups.insert(
            2,
            group_node("sequences", "Sequences", "sequences", sequences),
        );
    }
    // CQL and SurrealQL have functions, but no procedures.
    if !matches!(dialect, Dialect::Scylla | Dialect::SurrealDb) {
        groups.push(group_node(
            "procedures",
            "Procedures",
            "procedures",
            procedures,
        ));
    }
    Ok(groups)
}

/// Whether a relation belongs under Tables rather than under Views.
fn is_table(kind: RelationKind) -> bool {
    !matches!(
        kind,
        RelationKind::View | RelationKind::MaterializedView | RelationKind::Sequence
    )
}

/// What one group holds.
async fn members(
    connection: &Connection,
    schema: &str,
    group: &str,
    pattern: Option<&str>,
) -> Result<Vec<Value>, DbError> {
    match group {
        "tables" | "views" | "sequences" => {
            let relations = connection.backend.relations(schema).await?;
            Ok(relation_nodes(
                relations
                    .into_iter()
                    .filter(|relation| match group {
                        "tables" => is_table(relation.kind),
                        "views" => matches!(
                            relation.kind,
                            RelationKind::View | RelationKind::MaterializedView
                        ),
                        _ => relation.kind == RelationKind::Sequence,
                    })
                    .collect(),
            ))
        }
        "functions" | "procedures" => {
            let want = if group == "procedures" {
                RoutineKind::Procedure
            } else {
                RoutineKind::Function
            };
            let routines = connection.backend.routines(schema).await?;
            Ok(routine_nodes(
                routines
                    .into_iter()
                    .filter(|routine| routine.kind == want)
                    .collect(),
            ))
        }
        other => {
            // Anything else is a Redis type's group, or a path the plugin invented.
            let Some(wanted) = KeyType::ALL
                .into_iter()
                .find(|kind| kind.group().0 == other)
            else {
                return Err(DbError::driver(format!("no `{other}` group in a schema")));
            };
            let relations = relations_of(connection, schema, pattern).await?;
            Ok(relation_nodes(
                relations
                    .into_iter()
                    .filter(|relation| relation.kind == RelationKind::Key(wanted))
                    .collect(),
            ))
        }
    }
}

/// One group heading.
fn group_node(key: &str, name: &str, kind: &str, count: usize) -> Value {
    map(vec![
        ("key", Value::from(key)),
        ("name", Value::from(name)),
        ("kind", Value::from(kind)),
        ("expandable", Value::from(count > 0)),
        ("count", Value::from(count as u64)),
    ])
}

fn routine_nodes(routines: Vec<RoutineNode>) -> Vec<Value> {
    routines
        .into_iter()
        .map(|routine| {
            map(vec![
                ("name", Value::from(routine.name)),
                ("kind", Value::from(routine.kind.name())),
                ("expandable", Value::from(false)),
            ])
        })
        .collect()
}

fn relation_nodes(relations: Vec<RelationNode>) -> Vec<Value> {
    relations
        .into_iter()
        .map(|relation| {
            map(vec![
                ("name", Value::from(relation.name)),
                ("kind", Value::from(relation.kind.name())),
                // A Redis key has no columns to open onto.
                (
                    "expandable",
                    Value::from(!matches!(
                        relation.kind,
                        RelationKind::Key(_) | RelationKind::Sequence
                    )),
                ),
            ])
        })
        .collect()
}

fn column_nodes(columns: Vec<ColumnNode>) -> Vec<Value> {
    columns
        .into_iter()
        .map(|column| {
            // Read before the name is moved out.
            let class = column.class().name();
            let mut pairs = vec![
                ("name", Value::from(column.name)),
                ("kind", Value::from("column")),
                ("expandable", Value::from(false)),
                ("class", Value::from(class)),
                ("type_name", Value::from(column.type_name)),
                ("nullable", Value::from(column.nullable)),
                ("primary_key", Value::from(column.primary_key)),
            ];
            if let Some(key) = column.foreign_key {
                pairs.push((
                    "references",
                    Value::from(format!("{}.{}", key.table, key.column)),
                ));
            }
            if let Some(default) = column.default {
                pairs.push(("default", Value::from(default)));
            }
            map(pairs)
        })
        .collect()
}

/// Name and value pairs, each as a two-element array.
fn pairs(pairs: Vec<(String, String)>) -> Value {
    Value::Array(
        pairs
            .into_iter()
            .map(|(name, value)| strings([name, value]))
            .collect(),
    )
}

fn details_payload(details: Details) -> Vec<(&'static str, Value)> {
    let foreign_keys = details
        .foreign_keys
        .into_iter()
        .map(|key| {
            map(vec![
                ("name", Value::from(key.name)),
                ("columns", strings(key.columns)),
                ("target", Value::from(key.target)),
                ("referenced", strings(key.referenced)),
            ])
        })
        .collect();
    let mut payload = vec![
        ("properties", pairs(details.properties)),
        ("comments", pairs(details.column_comments)),
        ("foreign_keys", Value::Array(foreign_keys)),
        ("checks", pairs(details.checks)),
        ("triggers", pairs(details.triggers)),
    ];
    if let Some(definition) = details.definition {
        payload.push(("definition", Value::from(definition)));
    }
    payload
}

fn index_nodes(indexes: Vec<IndexNode>) -> Vec<Value> {
    indexes
        .into_iter()
        .map(|index| {
            map(vec![
                ("name", Value::from(index.name)),
                ("columns", strings(index.columns)),
                ("unique", Value::from(index.unique)),
                ("primary", Value::from(index.primary)),
            ])
        })
        .collect()
}
