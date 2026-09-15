//! Planning changes to SQL tables.

use crate::adapter::Dialect;
use crate::error::{Error, Result};
use crate::result::ResultSet;
use crate::types::TypeClass;
use crate::value::Cell;

use super::{Changes, Source, Table, Value, check_column, check_row, not_editable};

/// Plan changes to the tables a result came from: deletes, then inserts, then updates, as DBeaver
/// orders them.
pub fn sql_plan(dialect: Dialect, result: &ResultSet, changes: &Changes) -> Result<Vec<String>> {
    let Some(source @ Source::Tables(tables)) = result.source() else {
        return Err(not_editable());
    };
    let planner = Planner {
        dialect,
        result,
        source,
        tables,
    };

    let mut statements = Vec::new();
    for &row in &changes.deletes {
        statements.push(planner.delete(row)?);
    }
    for cells in &changes.inserts {
        statements.extend(planner.insert(cells)?);
    }
    for (row, cells) in changes.live_updates() {
        statements.extend(planner.update(*row, cells)?);
    }
    Ok(statements)
}

/// Writes statements against the tables of one result.
struct Planner<'a> {
    dialect: Dialect,
    result: &'a ResultSet,
    source: &'a Source,
    tables: &'a [Table],
}

impl Planner<'_> {
    /// Delete from the table of the first editable column, which is DBeaver's default row identifier.
    fn delete(&self, row: usize) -> Result<String> {
        let table = &self.tables[0];
        Ok(format!(
            "DELETE FROM {} WHERE {}{}",
            self.table(table),
            self.locate(table, row)?,
            self.exists()
        ))
    }

    /// Insert into the one table the result shows, and for MySQL read the row back.
    fn insert(&self, cells: &[(usize, Value)]) -> Result<Vec<String>> {
        let [table] = self.tables else {
            return Err(Error::driver(
                "a row cannot be added to a result that shows more than one table",
            ));
        };
        let name = self.table(table);
        // The row comes back, so one the query does not select can still be shown.
        let returning = match self.dialect {
            Dialect::Postgres | Dialect::Sqlite | Dialect::DuckDb => " RETURNING *",
            _ => "",
        };
        if cells.is_empty() {
            let insert = match self.dialect {
                Dialect::MySql => format!("INSERT INTO {name} () VALUES ()"),
                _ => format!("INSERT INTO {name} DEFAULT VALUES{returning}"),
            };
            return Ok(std::iter::once(insert)
                .chain(self.read_back(table, cells)?)
                .collect());
        }
        let columns = cells
            .iter()
            .map(|(index, _)| self.column(table, *index))
            .collect::<Result<Vec<_>>>()?;
        let values: Vec<String> = cells
            .iter()
            .map(|(index, value)| self.value(*index, value))
            .collect();
        let insert = format!(
            "INSERT INTO {name} ({}) VALUES ({}){returning}",
            columns.join(", "),
            values.join(", ")
        );
        Ok(std::iter::once(insert)
            .chain(self.read_back(table, cells)?)
            .collect())
    }

    /// The `SELECT` that reads a new MySQL row back, since MySQL has no `RETURNING`: by the key it was
    /// given, or by `LAST_INSERT_ID()` for an auto-increment key it was not.
    fn read_back(&self, table: &Table, cells: &[(usize, Value)]) -> Result<Option<String>> {
        if self.dialect != Dialect::MySql {
            return Ok(None);
        }
        let mut parts = Vec::new();
        for &index in &table.key {
            let name = self.column(table, index)?;
            match cells.iter().find(|(at, _)| *at == index) {
                Some((_, value @ Value::Text(_))) => {
                    parts.push(format!("{name} = {}", self.value(index, value)));
                }
                None if table.key.len() == 1 && self.result.columns()[index].generated => {
                    parts.push(format!("{name} = LAST_INSERT_ID()"));
                }
                _ => return Ok(None),
            }
        }
        Ok(Some(format!(
            "SELECT * FROM {} WHERE {}",
            self.table(table),
            parts.join(" AND ")
        )))
    }

    /// One `UPDATE` for each table the changed cells belong to.
    fn update(&self, row: usize, cells: &[(usize, Value)]) -> Result<Vec<String>> {
        for (index, _) in cells {
            check_column(self.source, self.result, *index)?;
        }
        let mut statements = Vec::new();
        for table in self.tables {
            let sets = cells
                .iter()
                .filter(|(index, _)| table.column(*index).is_some())
                .map(|(index, value)| {
                    Ok(format!(
                        "{} = {}",
                        self.column(table, *index)?,
                        self.value(*index, value)
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            if sets.is_empty() {
                continue;
            }
            statements.push(format!(
                "UPDATE {} SET {} WHERE {}{}",
                self.table(table),
                sets.join(", "),
                self.locate(table, row)?,
                self.exists()
            ));
        }
        Ok(statements)
    }

    fn table(&self, table: &Table) -> String {
        table.quoted(self.dialect)
    }

    fn column(&self, table: &Table, index: usize) -> Result<String> {
        check_column(self.source, self.result, index)?;
        let name = table.column(index).ok_or_else(|| {
            let shown = &self.result.columns()[index].name;
            Error::driver(format!(
                "`{shown}` is not a column of `{}`",
                table.qualified()
            ))
        })?;
        Ok(self.dialect.quote_ident(name))
    }

    fn value(&self, index: usize, value: &Value) -> String {
        if let Value::Sql(expression) = value {
            return expression.trim().to_owned();
        }
        let type_name = &self.result.columns()[index].type_name;
        value_literal(self.dialect, type_name, value.text())
    }

    /// The `WHERE` condition that finds a row's table row by its key.
    fn locate(&self, table: &Table, row: usize) -> Result<String> {
        check_row(self.result, row)?;
        let cells: Vec<&Cell> = table
            .key
            .iter()
            .map(|&index| self.result.cell(row, index).unwrap_or(&Cell::Null))
            .collect();
        // An outer join leaves rows with nothing from the table on its other side.
        if cells.iter().all(|cell| cell.is_null()) {
            return Err(Error::driver(format!(
                "row {row} has no `{}` row to change",
                table.qualified()
            )));
        }
        let parts = table
            .key
            .iter()
            .zip(cells)
            // A JSON, array or unread value has no dependable equality; applying checks that
            // exactly one row matched what is left.
            .filter(|(_, cell)| {
                !matches!(
                    cell,
                    Cell::Json(_) | Cell::Array(_) | Cell::Unsupported { .. }
                )
            })
            .map(|(&index, cell)| {
                let name = self.column(table, index)?;
                Ok(if cell.is_null() {
                    format!("{name} IS NULL")
                } else {
                    format!("{name} = {}", cell_literal(self.dialect, cell)?)
                })
            })
            .collect::<Result<Vec<_>>>()?;
        if parts.is_empty() {
            return Err(Error::driver(format!(
                "row {row} holds nothing its `{}` row can be found again by",
                table.qualified()
            )));
        }
        Ok(parts.join(" AND "))
    }

    /// CQL writes a missing row instead of failing, so each change checks the row is there.
    fn exists(&self) -> &'static str {
        if self.dialect == Dialect::Scylla {
            " IF EXISTS"
        } else {
            ""
        }
    }
}

/// A value the user typed, as a SQL literal for a column of `type_name`.
pub fn value_literal(dialect: Dialect, type_name: &str, value: Option<&str>) -> String {
    if TypeClass::from_type_name(type_name) == TypeClass::Binary
        && let Some(bytes) = value.and_then(hex_bytes)
    {
        return bytes_literal(dialect, &bytes);
    }
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

/// The bytes a `0x` or `\\x` hex text spells.
fn hex_bytes(text: &str) -> Option<Vec<u8>> {
    let digits = text
        .strip_prefix("0x")
        .or_else(|| text.strip_prefix("\\x"))?;
    if digits.len() % 2 != 0 {
        return None;
    }
    (0..digits.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(digits.get(at..at + 2)?, 16).ok())
        .collect()
}

/// Bytes as a binary literal.
fn bytes_literal(dialect: Dialect, bytes: &[u8]) -> String {
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    match dialect {
        Dialect::Postgres => format!("'\\x{hex}'"),
        Dialect::Scylla => format!("0x{hex}"),
        // DuckDB reads `X'ab'` as text, and `\\x` escapes one byte at a time.
        Dialect::DuckDb => {
            let escaped: String = bytes.iter().map(|byte| format!("\\x{byte:02x}")).collect();
            format!("'{escaped}'")
        }
        _ => format!("X'{hex}'"),
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

/// The condition a row meets when `column` holds `cell`.
pub fn condition(dialect: Dialect, column: &str, cell: &Cell) -> Result<String> {
    let column = dialect.quote_ident(column);
    Ok(match cell {
        Cell::Null => format!("{column} IS NULL"),
        cell => format!("{column} = {}", cell_literal(dialect, cell)?),
    })
}

/// A value the result holds as a SQL literal, falling back to its text where no literal matches it.
pub fn literal(dialect: Dialect, cell: &Cell) -> String {
    match cell {
        Cell::Null => "NULL".to_owned(),
        cell => cell_literal(dialect, cell).unwrap_or_else(|_| quote_text(dialect, &cell.text(""))),
    }
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
        Cell::Bytes { head, .. } => bytes_literal(dialect, head),
        Cell::Uuid(text) if dialect == Dialect::Scylla => text.clone(),
        other => quote_text(dialect, &other.text("")),
    })
}

#[cfg(test)]
mod tests {
    use crate::result::Column;

    use super::*;

    #[test]
    fn a_condition_matches_the_cell_again() {
        assert_eq!(
            condition(Dialect::Postgres, "na\"me", &Cell::Text("o'k".into())).unwrap(),
            "\"na\"\"me\" = 'o''k'"
        );
        assert_eq!(
            condition(Dialect::MySql, "age", &Cell::Int(3)).unwrap(),
            "`age` = 3"
        );
        assert_eq!(
            condition(Dialect::Sqlite, "gone", &Cell::Null).unwrap(),
            "\"gone\" IS NULL"
        );
    }

    fn table(schema: Option<&str>, name: &str, key: &[usize], columns: &[(usize, &str)]) -> Table {
        Table {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
            key: key.to_vec(),
            columns: columns
                .iter()
                .map(|(index, name)| (*index, (*name).to_owned()))
                .collect(),
        }
    }

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "select id, name as who, upper(name) from people",
            vec![
                Column::new("id", "INTEGER"),
                Column::new("who", "TEXT"),
                Column::new("upper", "TEXT"),
            ],
        );
        result.push_row(vec![
            Cell::Int(1),
            Cell::Text("it's".into()),
            Cell::Text("IT'S".into()),
        ]);
        result.set_source(Some(Source::Tables(vec![table(
            Some("public"),
            "people",
            &[0],
            &[(0, "id"), (1, "name")],
        )])));
        result
    }

    /// `select p.id, p.name, t.id, t.name from people p left join teams t ...`
    fn joined() -> ResultSet {
        let mut result = ResultSet::new(
            "select p.id, p.name, t.id, t.name from people p left join teams t on t.id = p.team",
            vec![
                Column::new("id", "INTEGER"),
                Column::new("name", "TEXT"),
                Column::new("id", "INTEGER"),
                Column::new("name", "TEXT"),
            ],
        );
        result.push_row(vec![
            Cell::Int(1),
            Cell::Text("ann".into()),
            Cell::Int(7),
            Cell::Text("red".into()),
        ]);
        result.push_row(vec![
            Cell::Int(2),
            Cell::Text("bob".into()),
            Cell::Null,
            Cell::Null,
        ]);
        result.set_source(Some(Source::Tables(vec![
            table(None, "people", &[0], &[(0, "id"), (1, "name")]),
            table(None, "teams", &[2], &[(2, "id"), (3, "name")]),
        ])));
        result
    }

    #[test]
    fn an_update_sets_the_table_column_and_finds_the_row_by_its_key() {
        let changes = Changes {
            updates: vec![(0, vec![(1, "o'brien".into()), (0, Value::Null)])],
            ..Changes::default()
        };
        let plan = sql_plan(Dialect::Postgres, &people(), &changes).unwrap();
        assert_eq!(
            plan,
            vec![r#"UPDATE "public"."people" SET "name" = 'o''brien', "id" = NULL WHERE "id" = 1"#]
        );
    }

    #[test]
    fn a_sql_expression_is_written_as_is() {
        let changes = Changes {
            updates: vec![(0, vec![(1, Value::Sql(" upper('x') ".into()))])],
            ..Changes::default()
        };
        let plan = sql_plan(Dialect::Postgres, &people(), &changes).unwrap();
        assert_eq!(
            plan,
            vec![r#"UPDATE "public"."people" SET "name" = upper('x') WHERE "id" = 1"#]
        );
    }

    #[test]
    fn a_new_mysql_row_is_read_back_by_its_key() {
        let mut id = Column::new("id", "INT");
        id.generated = true;
        let mut result = ResultSet::new(
            "select id, name from t",
            vec![id, Column::new("name", "TEXT")],
        );
        result.set_source(Some(Source::Tables(vec![table(
            None,
            "t",
            &[0],
            &[(0, "id"), (1, "name")],
        )])));
        let changes = Changes {
            inserts: vec![
                vec![(1, "a".into())],
                vec![(0, "9".into()), (1, "b".into())],
            ],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::MySql, &result, &changes).unwrap(),
            vec![
                "INSERT INTO `t` (`name`) VALUES ('a')",
                "SELECT * FROM `t` WHERE `id` = LAST_INSERT_ID()",
                "INSERT INTO `t` (`id`, `name`) VALUES ('9', 'b')",
                "SELECT * FROM `t` WHERE `id` = '9'",
            ]
        );
    }

    #[test]
    fn a_row_with_null_in_its_key_is_found_by_is_null() {
        let mut result = people();
        result.push_row(vec![Cell::Int(2), Cell::Null, Cell::Null]);
        result.set_source(Some(Source::Tables(vec![table(
            None,
            "people",
            &[0, 1],
            &[(0, "id"), (1, "name")],
        )])));
        let changes = Changes {
            deletes: vec![1],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Sqlite, &result, &changes).unwrap(),
            vec![r#"DELETE FROM "people" WHERE "id" = 2 AND "name" IS NULL"#]
        );
    }

    #[test]
    fn deletes_and_inserts_come_before_updates() {
        let changes = Changes {
            updates: vec![(0, vec![(1, "x".into())])],
            deletes: vec![0],
            inserts: vec![vec![(1, "new".into())], vec![]],
        };
        let plan = sql_plan(Dialect::Sqlite, &people(), &changes).unwrap();
        // The update to a row being deleted is dropped.
        assert_eq!(
            plan,
            vec![
                r#"DELETE FROM "public"."people" WHERE "id" = 1"#.to_owned(),
                r#"INSERT INTO "public"."people" ("name") VALUES ('new') RETURNING *"#.to_owned(),
                r#"INSERT INTO "public"."people" DEFAULT VALUES RETURNING *"#.to_owned(),
            ]
        );
    }

    #[test]
    fn an_update_to_a_joined_row_writes_each_table_by_its_own_key() {
        let changes = Changes {
            updates: vec![(0, vec![(1, "amy".into()), (3, "blue".into())])],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::MySql, &joined(), &changes).unwrap(),
            vec![
                "UPDATE `people` SET `name` = 'amy' WHERE `id` = 1",
                "UPDATE `teams` SET `name` = 'blue' WHERE `id` = 7",
            ]
        );
    }

    #[test]
    fn a_joined_row_is_deleted_from_the_first_table_only() {
        let changes = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Sqlite, &joined(), &changes).unwrap(),
            vec![r#"DELETE FROM "people" WHERE "id" = 1"#]
        );
    }

    #[test]
    fn a_row_cannot_be_added_to_a_join() {
        let changes = Changes {
            inserts: vec![vec![(1, "cat".into())]],
            ..Changes::default()
        };
        let error = sql_plan(Dialect::Sqlite, &joined(), &changes).unwrap_err();
        assert!(error.to_string().contains("more than one table"), "{error}");
        assert!(!joined().source().unwrap().insertable());
    }

    #[test]
    fn the_missing_side_of_an_outer_join_is_refused() {
        let changes = Changes {
            updates: vec![(1, vec![(3, "green".into())])],
            ..Changes::default()
        };
        let error = sql_plan(Dialect::Sqlite, &joined(), &changes).unwrap_err();
        assert!(error.to_string().contains("no `teams` row"), "{error}");
    }

    #[test]
    fn an_expression_column_is_refused() {
        let changes = Changes {
            updates: vec![(0, vec![(2, "x".into())])],
            ..Changes::default()
        };
        let error = sql_plan(Dialect::Postgres, &people(), &changes).unwrap_err();
        assert!(
            error.to_string().contains("`upper` cannot be edited"),
            "{error}"
        );
    }

    #[test]
    fn a_result_without_a_source_is_refused() {
        let mut result = people();
        result.set_source(None);
        assert!(sql_plan(Dialect::Postgres, &result, &Changes::default()).is_err());
    }

    #[test]
    fn a_row_past_the_end_is_refused() {
        let changes = Changes {
            deletes: vec![5],
            ..Changes::default()
        };
        assert!(sql_plan(Dialect::Postgres, &people(), &changes).is_err());
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
        assert!(
            cell_literal(Dialect::Sqlite, &Cell::bytes(&[0; 200]))
                .unwrap()
                .ends_with("00'")
        );
        assert_eq!(
            value_literal(Dialect::MySql, "BLOB", Some("0xDEad")),
            "X'dead'"
        );
        assert_eq!(
            value_literal(Dialect::Postgres, "BYTEA", Some(r"\xab")),
            r"'\xab'"
        );
        assert_eq!(
            value_literal(Dialect::Sqlite, "BLOB", Some("0xabc")),
            "'0xabc'"
        );
        assert_eq!(
            value_literal(Dialect::Sqlite, "TEXT", Some("0xab")),
            "'0xab'"
        );
    }

    #[test]
    fn a_cql_plan_writes_typed_literals_and_checks_the_row_exists() {
        let id = "5b6962dd-3f90-4c93-8f61-eabfa4a803e2";
        let mut result = ResultSet::new(
            "select id, n, label from t",
            vec![
                Column::new("id", "uuid"),
                Column::new("n", "int"),
                Column::new("label", "text"),
            ],
        );
        result.push_row(vec![Cell::Uuid(id.into()), Cell::Int(1), Cell::Null]);
        result.set_source(Some(Source::Tables(vec![table(
            Some("ks"),
            "t",
            &[0],
            &[(0, "id"), (1, "n"), (2, "label")],
        )])));

        let update = Changes {
            updates: vec![(0, vec![(1, "42".into()), (2, "42".into())])],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Scylla, &result, &update).unwrap(),
            vec![format!(
                r#"UPDATE "ks"."t" SET "n" = 42, "label" = '42' WHERE "id" = {id} IF EXISTS"#
            )]
        );
        let delete = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Scylla, &result, &delete).unwrap(),
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
            vec![Column::new("a", "INTEGER"), Column::new("b", "TEXT")],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("x".into())]);
        result.set_source(Some(Source::Tables(vec![table(
            None,
            "t",
            &[0, 1],
            &[(0, "a"), (1, "b")],
        )])));
        let changes = Changes {
            deletes: vec![0],
            ..Changes::default()
        };
        assert_eq!(
            sql_plan(Dialect::Sqlite, &result, &changes).unwrap(),
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
        assert!(source.insertable());
    }
}
