//! Changing the rows a result showed.

mod binder;
mod sql;

pub use binder::{TableBinder, TableName};
pub use sql::{condition, quote_text, sql_plan, value_literal};

use crate::error::{Error, Result};
use crate::result::ResultSet;

/// Where a result's rows are stored, for a result whose rows can be written back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// SQL tables, ordered by their first column in the result.
    Tables(Vec<Table>),
    /// A MongoDB collection, whose documents are found again by `_id` in the first column.
    Collection { db: String, name: String },
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
            Self::Collection { db, name } => format!("{db}.{name}"),
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
            Self::Collection { .. } => meta.name != "_id",
            Self::Redis { kind, .. } => match kind {
                RedisKind::Hash | RedisKind::SortedSet => column < 2,
                _ => column == 0,
            },
        }
    }

    /// Whether rows can be added, which for SQL needs every editable column to be one table's.
    pub fn insertable(&self) -> bool {
        !matches!(self, Self::Tables(tables) if tables.len() != 1)
    }
}

/// A new value for a cell. `None` is `NULL`.
pub type Value = Option<String>;

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
