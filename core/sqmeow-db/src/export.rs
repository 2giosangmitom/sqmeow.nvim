//! Writing a result out as CSV or JSON.
//!
//! Neither format goes through the grid's rendering. A grid cell is one line with escapes and a
//! truncation marker, which is right for reading and wrong for a file: an export must carry the
//! value, line breaks and full length included, and let the format's own rules handle it.

use crate::result::ResultSet;
use crate::value::Cell;

/// What an export is written as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Csv,
    Json,
}

impl Format {
    /// Parse a format name sent by the editor.
    pub fn parse(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "csv" => Some(Self::Csv),
            "json" => Some(Self::Json),
            _ => None,
        }
    }

    /// The name to use when suggesting a file name.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Csv => "csv",
            Self::Json => "json",
        }
    }
}

/// Which rows to write. `end` is exclusive and is clamped to the result.
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

    /// The result rows these positions cover, counted through `view` when the rows on screen are
    /// filtered or sorted, so an export writes what the user is looking at in the order they see it.
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

/// Write rows of a result in the given format. `columns` picks and orders the columns, all of them
/// when `None`. `headers` only affects CSV: JSON keys every value by name.
pub fn write(
    result: &ResultSet,
    format: Format,
    rows: &[usize],
    columns: Option<&[usize]>,
    headers: bool,
) -> String {
    match format {
        Format::Csv => csv(result, rows, columns, headers),
        Format::Json => json(result, rows, columns),
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
///
/// `NULL` becomes an empty field. CSV cannot tell an empty string from a missing value, and every
/// tool that reads CSV already assumes that, so inventing a marker would be worse. A row that is one
/// `NULL` alone is written as `""`, as the `csv` crate does, so it is not read back as a blank line.
pub fn csv(result: &ResultSet, rows: &[usize], columns: Option<&[usize]>, headers: bool) -> String {
    let mut writer = csv::Writer::from_writer(Vec::new());
    let columns = chosen(result, columns);

    if headers {
        writer
            .write_record(
                columns
                    .iter()
                    .map(|column| result.columns()[*column].name.as_str()),
            )
            .expect("writing to memory cannot fail");
    }

    for &row in rows {
        writer
            .write_record(
                columns
                    .iter()
                    .map(|&column| match result.cell(row, column) {
                        Some(Cell::Null) | None => String::new(),
                        Some(cell) => cell.text("").into_owned(),
                    }),
            )
            .expect("writing to memory cannot fail");
    }

    let bytes = writer.into_inner().expect("flushing to memory cannot fail");
    String::from_utf8(bytes).expect("every field written was a string")
}

/// Write a result as a JSON array of objects.
///
/// Numbers stay numbers and booleans stay booleans, so the output can be fed straight to a tool
/// that expects typed JSON rather than a table of strings.
pub fn json(result: &ResultSet, rows: &[usize], columns: Option<&[usize]>) -> String {
    let columns = chosen(result, columns);
    let records: Vec<serde_json::Value> = rows
        .iter()
        .map(|&row| {
            let mut object = serde_json::Map::with_capacity(columns.len());
            for &index in &columns {
                let cell = result.cell(row, index).unwrap_or(&Cell::Null);
                object.insert(result.columns()[index].name.clone(), value(cell));
            }
            serde_json::Value::Object(object)
        })
        .collect();

    serde_json::to_string_pretty(&serde_json::Value::Array(records))
        .unwrap_or_else(|_| "[]".to_owned())
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
        assert_eq!(Format::parse("xml"), None);
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
