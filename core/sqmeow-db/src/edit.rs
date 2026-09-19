//! Tracks and plans edits to rows shown in a result.

mod binder;
mod sql;

pub use binder::{TableBinder, TableName};
pub use sql::{condition, literal, quote_text, sql_plan, value_literal};

use crate::adapter::Dialect;
use crate::error::{Error, Result};
use crate::result::ResultSet;
use crate::value::Cell;

/// Where a result's rows are stored, for a result whose rows can be written back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// SQL tables, ordered by their first column in the result.
    Tables(Vec<Table>),
    /// A collection, whose documents are found again by its adapter-specific key field.
    Collection {
        db: String,
        name: String,
        key: String,
    },
    /// One Redis key, laid out by the command that read it.
    Redis { key: String, kind: RedisKind },
}

/// A table some result columns came from, with its whole primary key among them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub schema: Option<String>,
    pub name: String,
    /// The result columns that make up the primary key.
    pub key: Vec<usize>,
    /// Each result column from this table, with its name in the table.
    pub columns: Vec<(usize, String)>,
}

impl Table {
    /// The table column a result column shows.
    pub fn column(&self, index: usize) -> Option<&str> {
        self.columns
            .iter()
            .find(|(at, _)| *at == index)
            .map(|(_, name)| name.as_str())
    }

    /// The table's name quoted for `dialect`, with its schema when it has one.
    pub fn quoted(&self, dialect: Dialect) -> String {
        let name = dialect.quote_ident(&self.name);
        match &self.schema {
            // DuckDB names another database's schema as `database.schema`.
            Some(schema) => {
                let parts: Vec<String> = schema
                    .split('.')
                    .map(|part| dialect.quote_ident(part))
                    .collect();
                format!("{}.{name}", parts.join("."))
            }
            None => name,
        }
    }

    /// `schema.name`, or `name` without a schema.
    pub fn qualified(&self) -> String {
        match &self.schema {
            Some(schema) => format!("{schema}.{}", self.name),
            None => self.name.clone(),
        }
    }
}

/// What a Redis key read back as, which decides the commands that change it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedisKind {
    /// `GET`: one row, one value.
    String,
    /// `HGETALL`: a row per field, `field` and `value`.
    Hash,
    /// `SMEMBERS`: a row per member.
    Set,
    /// `LRANGE key start stop`: a row per element, the first at index `start`.
    List { start: i64 },
    /// `ZRANGE ... WITHSCORES`: a row per member, member then score.
    SortedSet,
    /// `JSON.GET key`: one row, the document.
    Json,
    /// `XRANGE key start end`: a row per entry, its id then its fields.
    Stream,
    /// `KEYS pattern`: a row per key name.
    Keys,
}

impl Source {
    /// What kind of thing is being edited, for the editor to say.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Tables(tables) if tables.len() > 1 => "tables",
            Self::Tables(_) => "table",
            Self::Collection { .. } => "collection",
            Self::Redis { kind, .. } => match kind {
                RedisKind::String => "string",
                RedisKind::Hash => "hash",
                RedisKind::Set => "set",
                RedisKind::List { .. } => "list",
                RedisKind::SortedSet => "sorted set",
                RedisKind::Json => "json",
                RedisKind::Stream => "stream",
                RedisKind::Keys => "keys",
            },
        }
    }

    /// The name of what is being edited, for the editor to say.
    pub fn name(&self) -> String {
        match self {
            Self::Tables(tables) => tables
                .iter()
                .map(Table::qualified)
                .collect::<Vec<_>>()
                .join(", "),
            Self::Collection { db, name, .. } => format!("{db}.{name}"),
            Self::Redis { key, .. } => key.clone(),
        }
    }

    /// Whether a column's values can be changed.
    pub fn editable(&self, result: &ResultSet, column: usize) -> bool {
        let Some(meta) = result.columns().get(column) else {
            return false;
        };
        match self {
            Self::Tables(tables) => tables.iter().any(|table| table.column(column).is_some()),
            Self::Collection { key, .. } => meta.name != *key,
            Self::Redis { kind, .. } => match kind {
                RedisKind::Hash | RedisKind::SortedSet => column < 2,
                // An entry's id is the server's to give; its fields are what is written.
                RedisKind::Stream => column == 1,
                _ => column == 0,
            },
        }
    }

    /// Whether rows can be added, which for SQL needs every editable column to be one table's.
    pub fn insertable(&self) -> bool {
        !matches!(self, Self::Tables(tables) if tables.len() != 1)
    }
}

/// A new value for a cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Null,
    Text(String),
    /// A SQL expression written into the statement as is, such as `now()`.
    Sql(String),
}

impl Value {
    /// The text, for a value that is text.
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            _ => None,
        }
    }
}

impl From<&str> for Value {
    fn from(text: &str) -> Self {
        Self::Text(text.to_owned())
    }
}

/// Everything staged against one result.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Changes {
    /// A row, and the cells in it that changed.
    pub updates: Vec<(usize, Vec<(usize, Value)>)>,
    /// Rows to remove.
    pub deletes: Vec<usize>,
    /// New rows, each the cells given a value.
    pub inserts: Vec<Vec<(usize, Value)>>,
}

impl Changes {
    /// The updates, less those to a row that is also being deleted.
    pub fn live_updates(&self) -> impl Iterator<Item = &(usize, Vec<(usize, Value)>)> {
        self.updates
            .iter()
            .filter(|(row, cells)| !cells.is_empty() && !self.deletes.contains(row))
    }
}

/// The error for a result nothing can be written back to.
pub fn not_editable() -> Error {
    Error::driver(
        "this result cannot be edited: its rows cannot be traced back to where they are stored",
    )
}

/// Refuse a row the result does not hold.
pub fn check_row(result: &ResultSet, row: usize) -> Result<()> {
    if row < result.row_count() {
        Ok(())
    } else {
        Err(Error::driver(format!(
            "row {row} is past the end of the result"
        )))
    }
}

/// Refuse a column that cannot be written.
pub fn check_column(source: &Source, result: &ResultSet, column: usize) -> Result<()> {
    if source.editable(result, column) {
        return Ok(());
    }
    let name = result
        .columns()
        .get(column)
        .map_or_else(|| column.to_string(), |meta| meta.name.clone());
    Err(Error::driver(format!("`{name}` cannot be edited")))
}

/// Append the rows inserts returned into `result`'s one table that it does not hold yet, so a new row
/// the query does not select is still shown. Answers with how many were added.
pub fn append_inserted(result: &mut ResultSet, dialect: Dialect, inserted: &[ResultSet]) -> usize {
    let Some(Source::Tables(tables)) = result.source() else {
        return 0;
    };
    let [table] = tables.as_slice() else {
        return 0;
    };
    let table = table.clone();
    let name = table.quoted(dialect);
    // MySQL reads a new row back with a `SELECT` rather than `RETURNING`.
    let into = format!("INSERT INTO {name} ");
    let read = format!("SELECT * FROM {name} WHERE ");
    let width = result.columns().len();

    let mut added = 0;
    for returned in inserted
        .iter()
        .filter(|r| r.statement().starts_with(&into) || r.statement().starts_with(&read))
    {
        for row in 0..returned.row_count() {
            let value = |name: &str| {
                returned
                    .columns()
                    .iter()
                    .position(|column| column.name.eq_ignore_ascii_case(name))
                    .and_then(|at| returned.cell(row, at))
                    .cloned()
                    .unwrap_or(Cell::Null)
            };
            let cells: Vec<Cell> = (0..width)
                .map(|index| table.column(index).map_or(Cell::Null, value))
                .collect();
            let held = (0..result.row_count()).any(|held| {
                table
                    .key
                    .iter()
                    .all(|&key| result.cell(held, key) == Some(&cells[key]))
            });
            if !held {
                result.push_row(cells);
                added += 1;
            }
        }
    }
    added
}

#[cfg(test)]
mod tests {
    use crate::result::Column;

    use super::*;

    #[test]
    fn an_inserted_row_the_result_lacks_is_appended_once() {
        let mut result = ResultSet::new(
            "select id, name as who, 1 as one from t",
            vec![
                Column::new("id", "INTEGER"),
                Column::new("who", "TEXT"),
                Column::new("one", "INTEGER"),
            ],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("a".into()), Cell::Int(1)]);
        result.set_source(Some(Source::Tables(vec![Table {
            schema: None,
            name: "t".into(),
            key: vec![0],
            columns: vec![(0, "id".into()), (1, "name".into())],
        }])));

        let mut returned = ResultSet::new(
            r#"INSERT INTO "t" ("name") VALUES ('b') RETURNING *"#,
            vec![Column::new("id", "INTEGER"), Column::new("name", "TEXT")],
        );
        returned.push_row(vec![Cell::Int(2), Cell::Text("b".into())]);
        returned.push_row(vec![Cell::Int(1), Cell::Text("a".into())]);
        let mut elsewhere = ResultSet::new(
            r#"INSERT INTO "u" DEFAULT VALUES RETURNING *"#,
            vec![Column::new("id", "INTEGER")],
        );
        elsewhere.push_row(vec![Cell::Int(3)]);

        assert_eq!(
            append_inserted(&mut result, Dialect::Sqlite, &[returned, elsewhere]),
            1
        );
        assert_eq!(result.row_count(), 2);
        assert_eq!(result.cell(1, 1), Some(&Cell::Text("b".into())));
        assert_eq!(result.cell(1, 2), Some(&Cell::Null));
    }

    #[test]
    fn only_a_collection_key_is_not_editable() {
        let result = ResultSet::new(
            "find people",
            vec![
                Column::new("_id", "objectId"),
                Column::new("id", "string"),
                Column::new("name", "string"),
            ],
        );
        let mongo = Source::Collection {
            db: "app".into(),
            name: "people".into(),
            key: "_id".into(),
        };
        let surreal = Source::Collection {
            db: String::new(),
            name: "people".into(),
            key: "id".into(),
        };

        assert!(!mongo.editable(&result, 0));
        assert!(mongo.editable(&result, 1));
        assert!(mongo.editable(&result, 2));
        assert!(surreal.editable(&result, 0));
        assert!(!surreal.editable(&result, 1));
        assert!(surreal.editable(&result, 2));
    }
}
