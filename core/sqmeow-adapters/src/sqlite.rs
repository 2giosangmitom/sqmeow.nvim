//! SQLite connections live exclusively on dedicated native worker threads.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use sqmeow_db::adapter::{Adapter, Dialect};
use sqmeow_db::error::{Error, Result};
use sqmeow_db::node::*;
use sqmeow_db::result::ResultSet;
use sqmeow_db::sql::parameters::Value;
use sqmeow_db::types::ForeignKey;
use tokio_util::sync::CancellationToken;

mod worker;
use worker::{Options, OwnedRow, Worker};

#[derive(Debug)]
pub struct SqliteAdapter {
    execution: Worker,
    metadata: Option<Worker>,
    // Conservatively preserve session visibility after ATTACH, temporary DDL or BEGIN.
    session_metadata: AtomicBool,
}

impl SqliteAdapter {
    pub async fn connect(url: &str, read_only: bool) -> Result<Self> {
        let options = Options::parse(url, read_only)?;
        let execution = Worker::open(options.clone()).await?;
        let metadata = if options.memory {
            None
        } else {
            Some(Worker::open(options).await?)
        };
        Ok(Self {
            execution,
            metadata,
            session_metadata: AtomicBool::new(false),
        })
    }

    fn meta(&self) -> &Worker {
        if self.session_metadata.load(Ordering::Acquire) {
            &self.execution
        } else {
            self.metadata.as_ref().unwrap_or(&self.execution)
        }
    }

    fn note_session(&self, sql: &str) {
        if sqmeow_db::sql::split(sql, Dialect::Sqlite)
            .iter()
            .any(|statement| {
                matches!(
                    sqmeow_db::sql::first_word(&statement.sql).as_str(),
                    "begin" | "savepoint" | "attach" | "detach"
                )
            })
            || sql.to_ascii_lowercase().contains("temp")
        {
            self.session_metadata.store(true, Ordering::Release);
        }
    }

    async fn fetch(&self, sql: impl Into<String>) -> Result<Vec<OwnedRow>> {
        self.meta().fetch(sql.into(), Vec::new()).await
    }

    async fn run(
        &self,
        sql: &str,
        origin: &str,
        values: &[Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.note_session(sql);
        self.execution
            .run(
                sql.to_owned(),
                origin.to_owned(),
                values.to_vec(),
                max_rows,
                cancel,
            )
            .await
    }
}

impl Adapter for SqliteAdapter {
    fn dialect(&self) -> Dialect {
        Dialect::Sqlite
    }

    async fn execute(
        &self,
        statement: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, statement, &[], max_rows, cancel).await
    }

    async fn execute_bound(
        &self,
        statement: &str,
        values: &[Value],
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, statement, values, max_rows, cancel)
            .await
    }

    async fn execute_wrapped(
        &self,
        statement: &str,
        origin: &str,
        max_rows: usize,
        cancel: CancellationToken,
    ) -> Result<ResultSet> {
        self.run(statement, origin, &[], max_rows, cancel).await
    }

    async fn apply(
        &self,
        statements: &[String],
        cancel: CancellationToken,
    ) -> Result<Vec<ResultSet>> {
        for sql in statements {
            self.note_session(sql);
        }
        self.execution.apply(statements.to_vec(), cancel).await
    }

    async fn schemas(&self) -> Result<Vec<SchemaNode>> {
        Ok(self
            .execution
            .fetch("pragma database_list".into(), vec![])
            .await?
            .iter()
            .filter_map(|row| row.text("name"))
            .map(|name| SchemaNode {
                is_default: name == "main",
                name,
            })
            .collect())
    }

    async fn relations(&self, schema: &str) -> Result<Vec<RelationNode>> {
        let sql = format!(
            "select name, type from {}.sqlite_master where type in ('table', 'view') and name not like 'sqlite_%' order by name",
            self.quote_ident(schema)
        );
        let worker = if schema.eq_ignore_ascii_case("temp") {
            &self.execution
        } else {
            self.meta()
        };
        Ok(worker
            .fetch(sql, vec![])
            .await?
            .iter()
            .filter_map(|row| {
                Some(RelationNode {
                    name: row.text("name")?,
                    kind: match row.text("type")?.as_str() {
                        "view" => RelationKind::View,
                        "table" => RelationKind::Table,
                        _ => RelationKind::Other,
                    },
                })
            })
            .collect())
    }

    async fn routines(&self, _schema: &str) -> Result<Vec<RoutineNode>> {
        Ok(Vec::new())
    }

    async fn columns(&self, schema: &str, relation: &str) -> Result<Vec<ColumnNode>> {
        let rows = self
            .execution
            .fetch(
                format!(
                    "pragma {}.table_info({})",
                    self.quote_ident(schema),
                    self.quote_ident(relation)
                ),
                vec![],
            )
            .await?;
        let references: HashMap<String, ForeignKey> = self
            .execution
            .fetch(
                format!(
                    "pragma {}.foreign_key_list({})",
                    self.quote_ident(schema),
                    self.quote_ident(relation)
                ),
                vec![],
            )
            .await
            .unwrap_or_default()
            .iter()
            .filter_map(|row| {
                Some((
                    row.text("from")?,
                    ForeignKey {
                        table: row.text("table")?,
                        column: row.text("to").unwrap_or_else(|| "rowid".into()),
                    },
                ))
            })
            .collect();
        Ok(rows
            .iter()
            .filter_map(|row| {
                let name = row.text("name")?;
                Some(ColumnNode {
                    foreign_key: references.get(&name).cloned(),
                    name,
                    type_name: match row.text("type")? {
                        t if t.is_empty() => "any".into(),
                        t => t,
                    },
                    nullable: row.int("notnull") == 0,
                    primary_key: row.int("pk") > 0,
                    default: row.text("dflt_value"),
                })
            })
            .collect())
    }

    async fn indexes(&self, schema: &str, relation: &str) -> Result<Vec<IndexNode>> {
        let rows = self
            .fetch(format!(
                "pragma {}.index_list({})",
                self.quote_ident(schema),
                self.quote_ident(relation)
            ))
            .await?;
        let mut indexes = Vec::new();
        for row in rows {
            let name = row.required("name")?;
            let columns = self
                .fetch(format!(
                    "pragma {}.index_info({})",
                    self.quote_ident(schema),
                    self.quote_ident(&name)
                ))
                .await?
                .iter()
                .map(|r| r.text("name").unwrap_or_else(|| "(expression)".into()))
                .collect();
            indexes.push(IndexNode {
                name,
                columns,
                unique: row.int("unique") == 1,
                primary: row.text("origin").is_some_and(|v| v == "pk"),
            });
        }
        indexes.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(indexes)
    }

    async fn relationships(&self, schema: &str, relation: &str) -> Result<Vec<RelationshipNode>> {
        let schemas = self.schemas().await?;
        let schema = schemas
            .into_iter()
            .find(|s| s.name.eq_ignore_ascii_case(schema))
            .ok_or_else(|| Error::driver(format!("unknown SQLite database: {schema}")))?
            .name;
        let tables: Vec<String> = self
            .fetch(format!(
                "select name from {}.sqlite_master where type = 'table' order by name",
                self.quote_ident(&schema)
            ))
            .await?
            .iter()
            .map(|r| r.required("name"))
            .collect::<Result<_>>()?;
        let mut nodes = Vec::new();
        for table in &tables {
            let mut rows = self
                .fetch(format!(
                    "pragma {}.foreign_key_list({})",
                    self.quote_ident(&schema),
                    self.quote_ident(table)
                ))
                .await?;
            rows.sort_by_key(|r| (r.int("id"), r.int("seq")));
            let mut keys: Vec<(i64, RelationshipNode)> = Vec::new();
            for row in rows {
                let id = row.int("id");
                let target = row.required("table")?;
                let target = tables
                    .iter()
                    .find(|t| t.eq_ignore_ascii_case(&target))
                    .cloned()
                    .unwrap_or(target);
                if !table.eq_ignore_ascii_case(relation) && !target.eq_ignore_ascii_case(relation) {
                    continue;
                }
                if keys.last().is_none_or(|(known, _)| *known != id) {
                    keys.push((
                        id,
                        RelationshipNode {
                            name: format!("fk_{id}"),
                            source_schema: schema.clone(),
                            source_relation: table.clone(),
                            columns: vec![],
                            target_schema: schema.clone(),
                            target_relation: target,
                            referenced: vec![],
                        },
                    ));
                }
                let key = &mut keys.last_mut().expect("inserted above").1;
                key.columns.push(row.required("from")?);
                if let Some(column) = row.text("to") {
                    key.referenced.push(column);
                }
            }
            for (_, mut key) in keys {
                if key.referenced.is_empty() {
                    let mut primary = self
                        .fetch(format!(
                            "pragma {}.table_info({})",
                            self.quote_ident(&schema),
                            self.quote_ident(&key.target_relation)
                        ))
                        .await?;
                    primary.retain(|r| r.int("pk") > 0);
                    primary.sort_by_key(|r| r.int("pk"));
                    key.referenced = primary
                        .iter()
                        .map(|r| r.required("name"))
                        .collect::<Result<_>>()?;
                }
                if key.columns.len() != key.referenced.len() {
                    return Err(Error::driver(format!(
                        "cannot resolve referenced columns for {} on {}",
                        key.name, key.source_relation
                    )));
                }
                nodes.push(key);
            }
        }
        Ok(nodes)
    }

    async fn details(&self, schema: &str, relation: &str) -> Result<Details> {
        let master = format!("{}.sqlite_master", self.quote_ident(schema));
        let values = vec![Value::Text(relation.into())];
        let definition = self
            .meta()
            .fetch(
                format!("select sql from {master} where name = ? and type in ('table', 'view')"),
                values.clone(),
            )
            .await?
            .first()
            .and_then(|r| r.text("sql"));
        let triggers = self.meta().fetch(format!("select name, sql from {master} where type = 'trigger' and tbl_name = ? order by name"), values).await?.iter().map(|r| Ok((r.required("name")?, r.text("sql").as_deref().map(trigger_event).unwrap_or_default()))).collect::<Result<_>>()?;
        let mut rows = self
            .fetch(format!(
                "pragma {}.foreign_key_list({})",
                self.quote_ident(schema),
                self.quote_ident(relation)
            ))
            .await?;
        rows.sort_by_key(|r| (r.int("id"), r.int("seq")));
        let mut keys: Vec<(i64, ForeignKeyNode)> = Vec::new();
        for row in rows {
            let id = row.int("id");
            if keys.last().is_none_or(|(known, _)| *known != id) {
                keys.push((
                    id,
                    ForeignKeyNode {
                        name: String::new(),
                        columns: vec![],
                        target: row.required("table")?,
                        referenced: vec![],
                    },
                ));
            }
            let key = &mut keys.last_mut().expect("inserted above").1;
            key.columns.push(row.required("from")?);
            key.referenced.extend(row.text("to"));
        }
        Ok(Details {
            definition,
            triggers,
            foreign_keys: keys.into_iter().map(|(_, k)| k).collect(),
            ..Details::default()
        })
    }

    async fn close(&self) {
        if let Some(meta) = &self.metadata {
            meta.close().await;
        }
        self.execution.close().await;
    }
}

fn trigger_event(sql: &str) -> String {
    let lower = sql.to_ascii_lowercase();
    ["before", "after", "instead of"]
        .iter()
        .find_map(|timing| {
            let at = lower.find(&format!(" {timing} "))? + 1;
            let end = lower[at..].find(" on ")?;
            Some(
                sql[at..at + end]
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .to_uppercase(),
            )
        })
        .unwrap_or_default()
}
