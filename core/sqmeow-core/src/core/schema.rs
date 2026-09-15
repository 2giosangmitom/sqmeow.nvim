//! Reading the schema tree the drawer shows.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::{
    ColumnNode, Dialect, Error as DbError, IndexNode, KeyType, RelationKind, RelationNode,
    RoutineKind, RoutineNode, SchemaNode,
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
        let path = args.opt_strings("path").unwrap_or_default();
        if path.len() > 3 {
            return Err("a schema path is at most [schema, group, relation]".to_owned());
        }
        let connection = self.connection(conn_id)?;

        let work = self.read_level(connection, path);
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
                Ok::<_, DbError>((columns, backend.indexes(&named, &relation).await?))
            };
            let mut payload = vec![
                ("conn_id", Value::from(conn_id)),
                ("schema", Value::from(schema.as_str())),
                ("relation", Value::from(relation.as_str())),
            ];
            match read.await {
                Ok((columns, indexes)) => {
                    payload.push(("columns", Value::Array(column_nodes(columns))));
                    payload.push(("indexes", Value::Array(index_nodes(indexes))));
                }
                Err(error) => payload.push(("error", Value::from(error.to_string()))),
            }
            self.emit("structure:done", map(payload));
        };
        Ok((Value::Boolean(true), Box::pin(work)))
    }

    /// Read one level of the schema tree.
    async fn read_level(self: Arc<Self>, connection: Arc<Connection>, path: Vec<String>) {
        let nodes = match path.as_slice() {
            // A cluster's databases are each opened as a connection of their own.
            [] => match connection.backend.databases().await {
                Some(databases) => databases.map(database_nodes),
                None => connection.backend.schemas().await.map(schema_nodes),
            },
            [schema] => group_nodes(&connection, schema).await,
            [schema, group] => members(&connection, schema, group).await,
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
async fn group_nodes(connection: &Connection, schema: &str) -> Result<Vec<Value>, DbError> {
    let relations = connection.backend.relations(schema).await?;
    let dialect = connection.backend.dialect();

    // Redis holds keys and nothing else, and what a key holds decides how it is read back.
    if dialect == Dialect::Redis {
        return Ok(KeyType::ALL
            .into_iter()
            .map(|wanted| {
                let (key, name) = wanted.group();
                let count = relations
                    .iter()
                    .filter(|r| r.kind == RelationKind::Key(wanted))
                    .count();
                group_node(key, name, "keys", count)
            })
            .collect());
    }

    let tables = relations.iter().filter(|r| is_table(r.kind)).count();
    let views = relations.len() - tables;

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
    // CQL has user-defined functions and aggregates, but no procedures.
    if dialect != Dialect::Scylla {
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
    !matches!(kind, RelationKind::View | RelationKind::MaterializedView)
}

/// What one group holds.
async fn members(
    connection: &Connection,
    schema: &str,
    group: &str,
) -> Result<Vec<Value>, DbError> {
    match group {
        "tables" | "views" => {
            let want_tables = group == "tables";
            let relations = connection.backend.relations(schema).await?;
            Ok(relation_nodes(
                relations
                    .into_iter()
                    .filter(|relation| is_table(relation.kind) == want_tables)
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
            let relations = connection.backend.relations(schema).await?;
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
                    Value::from(!matches!(relation.kind, RelationKind::Key(_))),
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
