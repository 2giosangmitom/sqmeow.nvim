//! Exports results as CSV, JSON, or SQL.

use crate::adapter::Dialect;
use crate::edit::{Source, literal};
use crate::result::ResultSet;
use crate::value::Cell;
use polars::prelude::{
    Column as PolarsColumn, CsvWriter, DataFrame, JsonFormat, JsonWriter, SerWriter,
};

/// Describes the format an export is written in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Format {
    Csv,
    Json,
    Sql(Sql),
}

/// How rows are written as SQL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sql {
    pub dialect: Dialect,
    /// The table to insert into, else the table the rows came from.
    pub table: Option<String>,
    /// Many rows per `INSERT` rather than one each.
    pub batch: bool,
    /// Start with a `CREATE TABLE` for the columns written.
    pub create: bool,
}

/// The most rows one multi-row `INSERT` holds.
const BATCH_ROWS: usize = 500;

impl Format {
    /// Parse a format name sent by the editor.
    pub fn parse(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "csv" => Some(Self::Csv),
            "json" => Some(Self::Json),
            "sql" => Some(Self::Sql(Sql {
                dialect: Dialect::Postgres,
                table: None,
                batch: false,
                create: false,
            })),
            _ => None,
        }
    }
}

/// Specifies which rows to write; `end` is exclusive and clamped.
#[derive(Debug, Clone, Copy)]
pub struct Rows {
    pub start: usize,
    pub end: usize,
}

impl Rows {
    /// Every row: `end` is clamped to the result when it is written.
    pub fn all() -> Self {
        Self {
            start: 0,
            end: usize::MAX,
        }
    }

    /// The result rows these positions cover, counted through `view` when given.
    pub fn resolve(self, result: &ResultSet, view: Option<&[usize]>) -> Vec<usize> {
        match view {
            Some(view) => {
                let end = self.end.min(view.len());
                view[self.start.min(end)..end].to_vec()
            }
            None => {
                let end = self.end.min(result.row_count());
                (self.start.min(end)..end).collect()
            }
        }
    }
}

/// Writes rows of a result in the given format.
pub fn write(
    result: &ResultSet,
    format: &Format,
    rows: &[usize],
    columns: Option<&[usize]>,
    headers: bool,
) -> String {
    match format {
        Format::Csv => csv(result, rows, columns, headers),
        Format::Json => json(result, rows, columns),
        Format::Sql(options) => sql(result, rows, columns, options),
    }
}

/// The columns to write: those asked for that exist, or every one.
fn chosen(result: &ResultSet, columns: Option<&[usize]>) -> Vec<usize> {
    let width = result.columns().len();
    match columns {
        Some(columns) => columns
            .iter()
            .copied()
            .filter(|column| *column < width)
            .collect(),
        None => (0..width).collect(),
    }
}

/// Write a result as CSV, optionally with a header row.
pub fn csv(result: &ResultSet, rows: &[usize], columns: Option<&[usize]>, headers: bool) -> String {
    let columns = chosen(result, columns);
    let mut bytes = Vec::new();
    if headers {
        // Polars requires unique frame column names, but result headers may repeat.
        // Write the original names before the Polars rows instead of renaming the export.
        let names = columns
            .iter()
            .map(|&index| csv_field(&result.columns()[index].name, columns.len() == 1))
            .collect::<Vec<_>>()
            .join(",");
        bytes.extend_from_slice(names.as_bytes());
        bytes.push(b'\n');
    }
    if columns.is_empty() {
        bytes.extend(std::iter::repeat_n(b'\n', rows.len()));
        return String::from_utf8(bytes).expect("CSV contains only UTF-8");
    }
    let values: Vec<PolarsColumn> = columns
        .iter()
        .enumerate()
        .map(|(position, &index)| {
            let cells: Vec<Option<String>> = rows
                .iter()
                .map(|&row| {
                    result
                        .cell(row, index)
                        .filter(|cell| !cell.is_null())
                        .map(|cell| cell.text("").into_owned())
                        .or_else(|| (columns.len() == 1).then(String::new))
                })
                .collect();
            PolarsColumn::new(format!("column_{position}").into(), cells)
        })
        .collect();
    let mut frame = DataFrame::new(rows.len(), values).expect("columns share the same row count");
    CsvWriter::new(&mut bytes)
        .include_header(false)
        .finish(&mut frame)
        .expect("writing a string frame to memory cannot fail");
    String::from_utf8(bytes).expect("every field written was a string")
}

fn csv_field(text: &str, only_field: bool) -> String {
    if (text.is_empty() && only_field) || text.contains([',', '"', '\r', '\n']) {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_owned()
    }
}

/// Write a result as a JSON array of objects.
pub fn json(result: &ResultSet, rows: &[usize], columns: Option<&[usize]>) -> String {
    let columns = chosen(result, columns);
    if columns.is_empty() {
        let records = vec![serde_json::json!({}); rows.len()];
        return serde_json::to_string_pretty(&records).expect("empty objects serialize");
    }

    // Polars requires unique, homogeneous columns. Use native types when every non-null
    // cell agrees; preserve mixed, nested and non-finite values after the Polars writer.
    let mut overlays = Vec::with_capacity(columns.len());
    let frame_columns: Vec<PolarsColumn> = columns
        .iter()
        .enumerate()
        .map(|(position, &index)| {
            let cells: Vec<&Cell> = rows
                .iter()
                .map(|&row| result.cell(row, index).unwrap_or(&Cell::Null))
                .collect();
            let name = format!("column_{position}");
            if cells
                .iter()
                .all(|cell| matches!(cell, Cell::Null | Cell::Bool(_)))
            {
                overlays.push(false);
                PolarsColumn::new(
                    name.into(),
                    cells
                        .iter()
                        .map(|cell| match cell {
                            Cell::Bool(value) => Some(*value),
                            _ => None,
                        })
                        .collect::<Vec<_>>(),
                )
            } else if cells
                .iter()
                .all(|cell| matches!(cell, Cell::Null | Cell::Int(_)))
            {
                overlays.push(false);
                PolarsColumn::new(
                    name.into(),
                    cells
                        .iter()
                        .map(|cell| match cell {
                            Cell::Int(value) => Some(*value),
                            _ => None,
                        })
                        .collect::<Vec<_>>(),
                )
            } else if cells.iter().all(|cell| {
                matches!(cell, Cell::Null) || matches!(cell, Cell::Float(v) if v.is_finite())
            }) {
                // Use the original values for formatting: JSON numbers distinguish 1.0 from 1.
                overlays.push(true);
                PolarsColumn::new(
                    name.into(),
                    cells
                        .iter()
                        .map(|cell| match cell {
                            Cell::Float(value) => Some(*value),
                            _ => None,
                        })
                        .collect::<Vec<_>>(),
                )
            } else if cells.iter().all(|cell| {
                matches!(
                    cell,
                    Cell::Null
                        | Cell::Text(_)
                        | Cell::Decimal(_)
                        | Cell::Bytes { .. }
                        | Cell::Timestamp(_)
                        | Cell::Date(_)
                        | Cell::Time(_)
                        | Cell::Uuid(_)
                        | Cell::Unsupported { .. }
                )
            }) {
                overlays.push(false);
                PolarsColumn::new(
                    name.into(),
                    cells
                        .iter()
                        .map(|cell| match cell {
                            Cell::Null => None,
                            other => Some(other.text("").into_owned()),
                        })
                        .collect::<Vec<_>>(),
                )
            } else {
                overlays.push(true);
                PolarsColumn::new(
                    name.into(),
                    cells
                        .iter()
                        .map(|cell| match cell {
                            Cell::Null => None,
                            other => Some(other.text("").into_owned()),
                        })
                        .collect::<Vec<_>>(),
                )
            }
        })
        .collect();
    let mut frame =
        DataFrame::new(rows.len(), frame_columns).expect("columns share the same row count");
    let mut bytes = Vec::new();
    JsonWriter::new(&mut bytes)
        .with_json_format(JsonFormat::Json)
        .finish(&mut frame)
        .expect("writing a Polars frame to memory cannot fail");
    let encoded: Vec<serde_json::Map<String, serde_json::Value>> =
        serde_json::from_slice(&bytes).expect("Polars writes valid JSON records");
    let records: Vec<serde_json::Value> = encoded
        .into_iter()
        .zip(rows)
        .map(|(record, &row)| {
            let mut object = serde_json::Map::with_capacity(columns.len());
            for (position, &index) in columns.iter().enumerate() {
                let name = format!("column_{position}");
                let cell = record
                    .get(&name)
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                object.insert(
                    result.columns()[index].name.clone(),
                    if overlays[position] {
                        value(result.cell(row, index).unwrap_or(&Cell::Null))
                    } else {
                        cell
                    },
                );
            }
            serde_json::Value::Object(object)
        })
        .collect();
    serde_json::to_string_pretty(&records).expect("valid JSON records serialize")
}

/// Write rows as `INSERT`s, into the table asked for or else the first table the result came from.
pub fn sql(result: &ResultSet, rows: &[usize], columns: Option<&[usize]>, options: &Sql) -> String {
    let dialect = options.dialect;
    let columns = chosen(result, columns);
    let source = match result.source() {
        Some(Source::Tables(tables)) => tables.first(),
        _ => None,
    };
    let table = match (&options.table, source) {
        (Some(table), _) => table.clone(),
        (None, Some(source)) => source.quoted(dialect),
        (None, None) => dialect.quote_ident("result"),
    };
    // A column is named as its table names it, not by its alias in the query.
    let names: Vec<String> = columns
        .iter()
        .map(|&column| {
            let shown = &result.columns()[column].name;
            dialect.quote_ident(source.and_then(|s| s.column(column)).unwrap_or(shown))
        })
        .collect();
    let values = |row: usize| {
        let values = columns
            .iter()
            .map(|&column| literal(dialect, result.cell(row, column).unwrap_or(&Cell::Null)))
            .collect::<Vec<_>>()
            .join(", ");
        format!("({values})")
    };

    let mut text = String::new();
    if options.create {
        let definitions = columns
            .iter()
            .zip(&names)
            .map(|(&column, name)| {
                format!(
                    "  {name} {}",
                    column_type(dialect, &result.columns()[column].type_name)
                )
            })
            .collect::<Vec<_>>()
            .join(",\n");
        text.push_str(&format!("CREATE TABLE {table} (\n{definitions}\n);\n\n"));
    }
    let names = names.join(", ");
    // CQL has no multi-row VALUES.
    if options.batch && dialect != Dialect::Scylla {
        for chunk in rows.chunks(BATCH_ROWS) {
            let values = chunk
                .iter()
                .map(|&row| values(row))
                .collect::<Vec<_>>()
                .join(",\n  ");
            text.push_str(&format!(
                "INSERT INTO {table} ({names}) VALUES\n  {values};\n"
            ));
        }
    } else {
        for &row in rows {
            text.push_str(&format!(
                "INSERT INTO {table} ({names}) VALUES {};\n",
                values(row)
            ));
        }
    }
    text
}

/// A type a `CREATE TABLE` can declare a column as, from the type name the driver reported.
fn column_type(dialect: Dialect, type_name: &str) -> String {
    let name = type_name.trim();
    match (dialect, name.to_ascii_uppercase().as_str()) {
        (_, "" | "NULL") => "TEXT".to_owned(),
        // MySQL needs a length for these, which the driver does not report.
        (Dialect::MySql, "VARCHAR" | "CHAR") => "TEXT".to_owned(),
        (Dialect::MySql, "VARBINARY" | "BINARY") => "BLOB".to_owned(),
        _ => name.to_owned(),
    }
}

fn value(cell: &Cell) -> serde_json::Value {
    match cell {
        Cell::Null => serde_json::Value::Null,
        Cell::Bool(flag) => serde_json::Value::Bool(*flag),
        Cell::Int(number) => serde_json::Value::from(*number),
        Cell::Float(number) => serde_json::Number::from_f64(*number)
            .map(serde_json::Value::Number)
            // NaN and the infinities have no JSON form, so they travel as their text.
            .unwrap_or_else(|| serde_json::Value::from(cell.text("").into_owned())),
        // Already JSON: parse it so it nests as structure rather than as a quoted string.
        Cell::Json(text) => {
            serde_json::from_str(text).unwrap_or_else(|_| serde_json::Value::from(text.clone()))
        }
        Cell::Array(items) => serde_json::Value::Array(items.iter().map(value).collect()),
        other => serde_json::Value::from(other.text("").into_owned()),
    }
}

#[cfg(test)]
mod tests {
    use crate::result::Column;

    use super::*;

    fn options(dialect: Dialect) -> Sql {
        Sql {
            dialect,
            table: None,
            batch: false,
            create: false,
        }
    }

    fn column(name: &str) -> Column {
        Column::new(name, "TEXT")
    }

    fn sample() -> ResultSet {
        let mut result = ResultSet::new(
            "select id, name from people",
            vec![column("id"), column("name")],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("alice".into())]);
        result.push_row(vec![Cell::Int(2), Cell::Null]);
        result
    }

    #[test]
    fn a_format_name_is_parsed_either_case() {
        assert_eq!(Format::parse("csv"), Some(Format::Csv));
        assert_eq!(Format::parse("JSON"), Some(Format::Json));
        assert!(matches!(Format::parse("sql"), Some(Format::Sql { .. })));
        assert_eq!(Format::parse("xml"), None);
    }

    #[test]
    fn sql_writes_an_insert_per_row_into_the_source_table() {
        let mut result = sample();
        result.set_source(Some(Source::Tables(vec![crate::edit::Table {
            schema: Some("app".into()),
            name: "people".into(),
            key: vec![0],
            columns: vec![(0, "id".into()), (1, "full_name".into())],
        }])));
        assert_eq!(
            sql(&result, &[0, 1], None, &options(Dialect::MySql)),
            "INSERT INTO `app`.`people` (`id`, `full_name`) VALUES (1, 'alice');\n\
             INSERT INTO `app`.`people` (`id`, `full_name`) VALUES (2, NULL);\n"
        );
    }

    #[test]
    fn sql_quotes_text_and_takes_a_table_it_is_given() {
        let mut result = ResultSet::new("select v", vec![column("v"), column("n")]);
        result.push_row(vec![Cell::Text("it's".into()), Cell::Float(f64::NAN)]);
        assert_eq!(
            sql(
                &result,
                &[0],
                None,
                &Sql {
                    table: Some("copy".into()),
                    ..options(Dialect::Sqlite)
                }
            ),
            "INSERT INTO copy (\"v\", \"n\") VALUES ('it''s', 'NaN');\n"
        );
        assert_eq!(
            sql(&result, &[0], Some(&[0]), &options(Dialect::Postgres)),
            "INSERT INTO \"result\" (\"v\") VALUES ('it''s');\n"
        );
    }

    #[test]
    fn sql_can_batch_rows_and_start_with_create_table() {
        let mut result = ResultSet::new(
            "select id, name from people",
            vec![Column::new("id", "BIGINT"), Column::new("name", "VARCHAR")],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("alice".into())]);
        result.push_row(vec![Cell::Int(2), Cell::Null]);
        let options = Sql {
            batch: true,
            create: true,
            ..options(Dialect::MySql)
        };
        assert_eq!(
            sql(&result, &[0, 1], None, &options),
            "CREATE TABLE `result` (\n  `id` BIGINT,\n  `name` TEXT\n);\n\n\
             INSERT INTO `result` (`id`, `name`) VALUES\n  (1, 'alice'),\n  (2, NULL);\n"
        );

        let many: Vec<usize> = (0..BATCH_ROWS + 1).map(|row| row % 2).collect();
        let text = sql(
            &result,
            &many,
            None,
            &Sql {
                create: false,
                ..options
            },
        );
        assert_eq!(text.matches("INSERT INTO").count(), 2);
    }

    #[test]
    fn cql_keeps_an_insert_per_row_when_batching() {
        let text = sql(
            &sample(),
            &[0, 1],
            None,
            &Sql {
                batch: true,
                ..options(Dialect::Scylla)
            },
        );
        assert_eq!(text.matches("INSERT INTO").count(), 2);
    }

    #[test]
    fn csv_starts_with_a_header() {
        let text = csv(&sample(), &Rows::all().resolve(&sample(), None), None, true);
        assert_eq!(text.lines().next(), Some("id,name"));
    }

    #[test]
    fn csv_writes_null_as_an_empty_field() {
        let text = csv(&sample(), &Rows::all().resolve(&sample(), None), None, true);
        assert_eq!(text.lines().nth(2), Some("2,"));
    }

    #[test]
    fn csv_quotes_only_what_needs_it() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Text("plain".into())]);
        result.push_row(vec![Cell::Text("has,comma".into())]);
        result.push_row(vec![Cell::Text("has\"quote".into())]);
        result.push_row(vec![Cell::Text("has\nbreak".into())]);

        let text = csv(&result, &Rows::all().resolve(&result, None), None, true);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[1], "plain");
        assert_eq!(lines[2], "\"has,comma\"");
        assert_eq!(lines[3], "\"has\"\"quote\"");
        // The line break survives inside the quoted field rather than being escaped away.
        assert_eq!(lines[4], "\"has");
        assert_eq!(lines[5], "break\"");
    }

    #[test]
    fn csv_writes_only_the_rows_asked_for() {
        let result = sample();
        let text = csv(
            &result,
            &Rows { start: 1, end: 2 }.resolve(&result, None),
            None,
            true,
        );
        assert_eq!(text.lines().count(), 2);
        assert_eq!(text.lines().nth(1), Some("2,"));
    }

    #[test]
    fn csv_quotes_a_lone_null_so_the_row_is_not_a_blank_line() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Null]);
        assert_eq!(
            csv(&result, &Rows::all().resolve(&result, None), None, false),
            "\"\"\n"
        );
    }

    #[test]
    fn csv_can_leave_the_header_out() {
        let result = sample();
        assert_eq!(
            csv(&result, &Rows::all().resolve(&result, None), None, false),
            "1,alice\n2,\n"
        );
    }

    #[test]
    fn csv_preserves_duplicate_and_quoted_headers_with_reordered_rows() {
        let mut result = ResultSet::new(
            "select",
            vec![column("same"), column("same"), column("has,\"quote")],
        );
        result.push_row(vec![Cell::Text("first".into()), Cell::Int(1), Cell::Null]);
        result.push_row(vec![
            Cell::Text("second".into()),
            Cell::Int(2),
            Cell::Text("x".into()),
        ]);
        assert_eq!(
            csv(&result, &[1, 0, 1], Some(&[2, 1, 0, 99]), true),
            "\"has,\"\"quote\",same,same\nx,2,second\n,1,first\nx,2,second\n"
        );
    }

    #[test]
    fn csv_keeps_cell_text_exact_and_handles_empty_selections() {
        let mut result = ResultSet::new("select", vec![column("value")]);
        result.push_row(vec![Cell::Decimal("12345678901234567890.0123".into())]);
        result.push_row(vec![Cell::Text(String::new())]);
        assert_eq!(
            csv(&result, &[0, 1], None, false),
            "12345678901234567890.0123\n\"\"\n"
        );
        assert_eq!(csv(&result, &[], None, true), "value\n");
        assert_eq!(csv(&result, &[0, 1], Some(&[]), false), "\n\n");
        let empty_name = ResultSet::new("select", vec![column("")]);
        assert_eq!(csv(&empty_name, &[], None, true), "\"\"\n");
    }

    #[test]
    fn a_row_range_past_the_end_is_clamped() {
        let result = sample();
        let text = csv(
            &result,
            &Rows { start: 0, end: 99 }.resolve(&result, None),
            None,
            true,
        );
        assert_eq!(text.lines().count(), 3);

        let empty = csv(
            &result,
            &Rows {
                start: 99,
                end: 100,
            }
            .resolve(&result, None),
            None,
            true,
        );
        assert_eq!(empty.lines().count(), 1);
    }

    #[test]
    fn json_keeps_types() {
        let mut result = ResultSet::new(
            "select a, b, c, d",
            vec![column("a"), column("b"), column("c"), column("d")],
        );
        result.push_row(vec![
            Cell::Int(1),
            Cell::Bool(true),
            Cell::Null,
            Cell::Text("x".into()),
        ]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, &Rows::all().resolve(&result, None), None))
                .unwrap();
        assert_eq!(parsed[0]["a"], serde_json::json!(1));
        assert_eq!(parsed[0]["b"], serde_json::json!(true));
        assert_eq!(parsed[0]["c"], serde_json::Value::Null);
        assert_eq!(parsed[0]["d"], serde_json::json!("x"));
    }

    #[test]
    fn json_nests_a_json_column_rather_than_quoting_it() {
        let mut result = ResultSet::new("select doc", vec![column("doc")]);
        result.push_row(vec![Cell::Json("{\"a\":1}".into())]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, &Rows::all().resolve(&result, None), None))
                .unwrap();
        assert_eq!(parsed[0]["doc"]["a"], serde_json::json!(1));
    }

    #[test]
    fn json_keeps_line_breaks_in_a_string() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Text("a\nb".into())]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, &Rows::all().resolve(&result, None), None))
                .unwrap();
        assert_eq!(parsed[0]["v"], serde_json::json!("a\nb"));
    }

    #[test]
    fn json_falls_back_to_text_for_a_number_it_cannot_represent() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Float(f64::INFINITY)]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, &Rows::all().resolve(&result, None), None))
                .unwrap();
        assert_eq!(parsed[0]["v"], serde_json::json!("Infinity"));
    }

    #[test]
    fn an_empty_result_writes_an_empty_json_array() {
        let result = ResultSet::new("select 1", vec![column("v")]);
        assert_eq!(
            json(&result, &Rows::all().resolve(&result, None), None),
            "[]"
        );
    }

    #[test]
    fn json_preserves_mixed_and_nested_values_and_selected_order() {
        let mut result = ResultSet::new(
            "select",
            vec![column("value"), column("value"), column("extra")],
        );
        result.push_row(vec![
            Cell::Int(9_007_199_254_740_993),
            Cell::Json("{\"n\":1}".into()),
            Cell::Array(vec![Cell::Bool(true), Cell::Null]),
        ]);
        result.push_row(vec![
            Cell::Text("one".into()),
            Cell::Json("invalid json".into()),
            Cell::Float(f64::INFINITY),
        ]);
        let text = json(&result, &[1, 0, 1], Some(&[0, 1, 2]));
        let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            parsed,
            serde_json::json!([
                {"value": "invalid json", "extra": "Infinity"},
                {"value": {"n": 1}, "extra": [true, null]},
                {"value": "invalid json", "extra": "Infinity"},
            ])
        );
        assert!(text.contains("\n  {\n"), "export stays pretty-printed");
        assert_eq!(json(&result, &[0, 1], Some(&[])), "[\n  {},\n  {}\n]");
    }

    #[test]
    fn json_preserves_exact_integers_and_float_formatting() {
        let mut result = ResultSet::new("select", vec![column("id"), column("float")]);
        result.push_row(vec![Cell::Int(9_007_199_254_740_993), Cell::Float(1.0)]);
        assert_eq!(
            json(&result, &[0], None),
            "[\n  {\n    \"id\": 9007199254740993,\n    \"float\": 1.0\n  }\n]"
        );
    }

    #[test]
    fn rows_are_counted_through_a_view() {
        let result = sample();
        let view = [1, 0];
        assert_eq!(Rows::all().resolve(&result, Some(&view)), vec![1, 0]);
        assert_eq!(
            Rows { start: 1, end: 5 }.resolve(&result, Some(&view)),
            vec![0]
        );
    }

    #[test]
    fn only_the_columns_asked_for_are_written_in_that_order() {
        let result = sample();
        let text = csv(&result, &[0], Some(&[1, 0, 9]), true);
        assert_eq!(text, "name,id\nalice,1\n");

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, &[0], Some(&[1]))).unwrap();
        assert_eq!(parsed[0], serde_json::json!({"name": "alice"}));
    }
}
