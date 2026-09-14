//! Changing the rows a result showed.

use crate::adapter::Dialect;
use crate::error::{Error, Result};
use crate::result::ResultSet;
use crate::types::TypeClass;
use crate::value::Cell;

/// Where a result's rows are stored, for a result whose rows can be written back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// One SQL table, with its whole primary key among the result's columns.
    Table {
        schema: Option<String>,
        name: String,
        /// The result columns that make up the primary key.
        key: Vec<usize>,
    },
    /// A MongoDB collection, whose documents are found again by `_id` in the first column.
    Collection { db: String, name: String },
    /// One Redis key, laid out by the command that read it.
    Redis { key: String, kind: RedisKind },
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
            Self::Table { .. } => "table",
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
            Self::Table { schema, name, .. } => match schema {
                Some(schema) => format!("{schema}.{name}"),
                None => name.clone(),
            },
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
            Self::Table { .. } => meta.origin.is_some(),
            Self::Collection { .. } => meta.name != "_id",
            Self::Redis { kind, .. } => match kind {
                RedisKind::Hash | RedisKind::SortedSet => column < 2,
                _ => column == 0,
            },
        }
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

/// Plan changes to a SQL table.
pub fn sql_plan(
    dialect: Dialect,
    quote: impl Fn(&str) -> String,
    result: &ResultSet,
    changes: &Changes,
) -> Result<Vec<String>> {
    let Some(source @ Source::Table { schema, name, key }) = result.source() else {
        return Err(not_editable());
    };

    let table = match schema {
        Some(schema) => format!("{}.{}", quote(schema), quote(name)),
        None => quote(name),
    };
    let column = |index: usize| -> Result<String> {
        check_column(source, result, index)?;
        Ok(quote(
            result.columns()[index]
                .origin
                .as_deref()
                .unwrap_or_default(),
        ))
    };
    let locate = |row: usize| -> Result<String> {
        check_row(result, row)?;
        let parts = key
            .iter()
            .map(|&index| {
                let name = column(index)?;
                let cell = result.cell(row, index).unwrap_or(&Cell::Null);
                Ok(if cell.is_null() {
                    format!("{name} IS NULL")
                } else {
                    format!("{name} = {}", cell_literal(dialect, cell)?)
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(parts.join(" AND "))
    };

    // CQL writes a missing row instead of failing, so each change checks the row is there.
    let exists = if dialect == Dialect::Scylla {
        " IF EXISTS"
    } else {
        ""
    };
    let type_name = |index: usize| result.columns()[index].type_name.as_str();

    let mut statements = Vec::new();
    for (row, cells) in changes.live_updates() {
        let sets = cells
            .iter()
            .map(|(index, value)| {
                Ok(format!(
                    "{} = {}",
                    column(*index)?,
                    value_literal(dialect, type_name(*index), value.as_deref())
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        statements.push(format!(
            "UPDATE {table} SET {} WHERE {}{exists}",
            sets.join(", "),
            locate(*row)?
        ));
    }
    for row in &changes.deletes {
        statements.push(format!(
            "DELETE FROM {table} WHERE {}{exists}",
            locate(*row)?
        ));
    }
    for cells in &changes.inserts {
        if cells.is_empty() {
            statements.push(match dialect {
                Dialect::MySql => format!("INSERT INTO {table} () VALUES ()"),
                _ => format!("INSERT INTO {table} DEFAULT VALUES"),
            });
            continue;
        }
        let names = cells
            .iter()
            .map(|(index, _)| column(*index))
            .collect::<Result<Vec<_>>>()?;
        let values: Vec<String> = cells
            .iter()
            .map(|(index, value)| value_literal(dialect, type_name(*index), value.as_deref()))
            .collect();
        statements.push(format!(
            "INSERT INTO {table} ({}) VALUES ({})",
            names.join(", "),
            values.join(", ")
        ));
    }
    Ok(statements)
}

/// A value the user typed, as a SQL literal for a column of `type_name`.
pub fn value_literal(dialect: Dialect, type_name: &str, value: Option<&str>) -> String {
    match value {
        None => "NULL".to_owned(),
        // CQL does not read a quoted string as a number, a boolean, a uuid or a blob.
        Some(text) if dialect == Dialect::Scylla && is_bare_literal(type_name, text) => {
            text.to_owned()
        }
        Some(text) => quote_text(dialect, text),
    }
}

/// Whether text is a valid unquoted literal for a column of `type_name`.
fn is_bare_literal(type_name: &str, text: &str) -> bool {
    match TypeClass::from_type_name(type_name) {
        TypeClass::Number => text.parse::<f64>().is_ok(),
        TypeClass::Boolean => {
            text.eq_ignore_ascii_case("true") || text.eq_ignore_ascii_case("false")
        }
        TypeClass::Uuid => {
            !text.is_empty() && text.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
        }
        TypeClass::Binary => text
            .strip_prefix("0x")
            .is_some_and(|hex| hex.chars().all(|c| c.is_ascii_hexdigit())),
        _ => false,
    }
}

/// Text as a quoted SQL string.
pub fn quote_text(dialect: Dialect, text: &str) -> String {
    let escaped = match dialect {
        Dialect::MySql => text.replace('\\', "\\\\").replace('\'', "''"),
        _ => text.replace('\'', "''"),
    };
    format!("'{escaped}'")
}

/// A value the result holds, as the SQL literal that matches it again.
fn cell_literal(dialect: Dialect, cell: &Cell) -> Result<String> {
    Ok(match cell {
        Cell::Int(value) => value.to_string(),
        Cell::Float(value) if value.is_finite() => cell.display("").into_owned(),
        Cell::Decimal(text) => text.clone(),
        Cell::Bool(value) => match dialect {
            Dialect::Sqlite => u8::from(*value).to_string(),
            _ => if *value { "TRUE" } else { "FALSE" }.to_owned(),
        },
        Cell::Bytes { head, len } => {
            if *len > head.len() {
                return Err(Error::driver(format!(
                    "a binary key of {len} bytes is longer than the engine keeps, so its row cannot be found again"
                )));
            }
            let hex: String = head.iter().map(|byte| format!("{byte:02x}")).collect();
            match dialect {
                Dialect::Postgres => format!("'\\x{hex}'"),
                Dialect::Scylla => format!("0x{hex}"),
                // DuckDB reads `X'ab'` as text, and `\x` escapes one byte at a time.
                Dialect::DuckDb => {
                    let escaped: String =
                        head.iter().map(|byte| format!("\\x{byte:02x}")).collect();
                    format!("'{escaped}'")
                }
                _ => format!("X'{hex}'"),
            }
        }
        Cell::Uuid(text) if dialect == Dialect::Scylla => text.clone(),
        other => quote_text(dialect, &other.text("")),
    })
}

#[cfg(test)]
mod tests {
    use crate::result::Column;

    use super::*;

    fn quote(name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "select id, name as who, upper(name) from people",
            vec![
                Column::new("id", "INTEGER").with_origin("id"),
                Column::new("who", "TEXT").with_origin("name"),
                Column::new("upper", "TEXT"),
            ],
        );
        result.push_row(vec![
            Cell::Int(1),
            Cell::Text("it's".into()),
            Cell::Text("IT'S".into()),
        ]);
        result.set_source(Some(Source::Table {
            schema: Some("public".into()),
            name: "people".into(),
            key: vec![0],
        }));
        result
    }

    #[test]
    fn an_update_sets_the_table_column_and_finds_the_row_by_its_key() {
        let changes = Changes {
            updates: vec![(0, vec![(1, Some("o'brien".into())), (0, None)])],
            ..Changes::default()
        };
        let plan = sql_plan(Dialect::Postgres, quote, &people(), &changes).unwrap();
        assert_eq!(
            plan,
            vec![r#"UPDATE "public"."people" SET "name" = 'o''brien', "id" = NULL WHERE "id" = 1"#]
        );
    }

    #[test]
    fn deletes_and_inserts_follow_updates() {
        let changes = Changes {
            updates: vec![(0, vec![(1, Some("x".into()))])],
            deletes: vec![0],
            inserts: vec![vec![(1, Some("new".into()))], vec![]],
        };
        let plan = sql_plan(Dialect::Sqlite, quote, &people(), &changes).unwrap();
        // The update to a row being deleted is dropped.
        assert_eq!(
            plan,
            vec![
                r#"DELETE FROM "public"."people" WHERE "id" = 1"#.to_owned(),
                r#"INSERT INTO "public"."people" ("name") VALUES ('new')"#.to_owned(),
                r#"INSERT INTO "public"."people" DEFAULT VALUES"#.to_owned(),
            ]
        );
    }

    #[test]
    fn an_expression_column_is_refused() {
        let changes = Changes {
            updates: vec![(0, vec![(2, Some("x".into()))])],
            ..Changes::default()
        };
        let error = sql_plan(Dialect::Postgres, quote, &people(), &changes).unwrap_err();
        assert!(
            error.to_string().contains("`upper` cannot be edited"),
            "{error}"
        );
    }

    #[test]
    fn a_result_without_a_source_is_refused() {
        let mut result = people();
        result.set_source(None);
        assert!(sql_plan(Dialect::Postgres, quote, &result, &Changes::default()).is_err());
    }

    #[test]
    fn a_row_past_the_end_is_refused() {
        let changes = Changes {
            deletes: vec![5],
            ..Changes::default()
        };
        assert!(sql_plan(Dialect::Postgres, quote, &people(), &changes).is_err());
    }

    #[test]
    fn mysql_doubles_backslashes() {
        assert_eq!(quote_text(Dialect::MySql, r"a\b'c"), r"'a\\b''c'");
        assert_eq!(quote_text(Dialect::Postgres, r"a\b'c"), r"'a\b''c'");
    }

    #[test]
    fn key_literals_match_their_type() {
        assert_eq!(
            cell_literal(Dialect::Sqlite, &Cell::Bool(true)).unwrap(),
            "1"
        );
        assert_eq!(
            cell_literal(Dialect::MySql, &Cell::Bool(false)).unwrap(),
            "FALSE"
        );
        assert_eq!(
            cell_literal(Dialect::Postgres, &Cell::bytes(&[0xab])).unwrap(),
            r"'\xab'"
        );
        assert_eq!(
            cell_literal(Dialect::Sqlite, &Cell::bytes(&[0xab])).unwrap(),
            "X'ab'"
        );
        assert_eq!(
            cell_literal(Dialect::DuckDb, &Cell::bytes(&[0xab, 0x63])).unwrap(),
            r"'\xab\x63'"
        );
        assert!(cell_literal(Dialect::Sqlite, &Cell::bytes(&[0; 200])).is_err());
    }

    #[test]
    fn a_cql_plan_writes_typed_literals_and_checks_the_row_exists() {
        let id = "5b6962dd-3f90-4c93-8f61-eabfa4a803e2";
        let mut result = ResultSet::new(
            "select id, n, label from t",
            vec![
                Column::new("id", "uuid").with_origin("id"),
                Column::new("n", "int").with_origin("n"),
                Column::new("label", "text").with_origin("label"),
            ],
        );
        result.push_row(vec![Cell::Uuid(id.into()), Cell::Int(1), Cell::Null]);
        result.set_source(Some(Source::Table {
            schema: Some("ks".into()),
            name: "t".into(),
            key: vec![0],
        }));

        let update = Changes {
            updates: vec![(0, vec![(1, Some("42".into())), (2, Some("42".into()))])],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Scylla, quote, &result, &update).unwrap(),
            vec![format!(
                r#"UPDATE "ks"."t" SET "n" = 42, "label" = '42' WHERE "id" = {id} IF EXISTS"#
            )]
        );
        let delete = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Scylla, quote, &result, &delete).unwrap(),
            vec![format!(
                r#"DELETE FROM "ks"."t" WHERE "id" = {id} IF EXISTS"#
            )]
        );
        // Anything that is not a valid literal stays quoted.
        assert_eq!(
            value_literal(Dialect::Scylla, "int", Some("1; x")),
            "'1; x'"
        );
        assert_eq!(
            cell_literal(Dialect::Scylla, &Cell::bytes(&[0xab])).unwrap(),
            "0xab"
        );
    }

    #[test]
    fn a_composite_key_is_anded() {
        let mut result = ResultSet::new(
            "select a, b from t",
            vec![
                Column::new("a", "INTEGER").with_origin("a"),
                Column::new("b", "TEXT").with_origin("b"),
            ],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("x".into())]);
        result.set_source(Some(Source::Table {
            schema: None,
            name: "t".into(),
            key: vec![0, 1],
        }));
        let changes = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Sqlite, quote, &result, &changes).unwrap(),
            vec![r#"DELETE FROM "t" WHERE "a" = 1 AND "b" = 'x'"#]
        );
    }

    #[test]
    fn which_columns_are_editable_depends_on_the_source() {
        let result = people();
        let source = result.source().unwrap();
        assert!(source.editable(&result, 1));
        assert!(!source.editable(&result, 2));
        assert!(!source.editable(&result, 9));
    }
}
