//! Writing a result out as CSV or JSON.
//!
//! Neither format goes through the grid's rendering. A grid cell is one line with escapes and a
//! truncation marker, which is right for reading and wrong for a file: an export must carry the
//! value, line breaks and full length included, and let the format's own rules handle it.

use sqmeow_db::{Cell, ResultSet};

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
    /// Every row.
    pub fn all(result: &ResultSet) -> Self {
        Self {
            start: 0,
            end: result.row_count(),
        }
    }

    /// One row.
    pub fn one(index: usize) -> Self {
        Self {
            start: index,
            end: index.saturating_add(1),
        }
    }

    fn clamped(self, result: &ResultSet) -> std::ops::Range<usize> {
        let end = self.end.min(result.row_count());
        self.start.min(end)..end
    }
}

/// Write a result in the given format.
pub fn write(result: &ResultSet, format: Format, rows: Rows) -> String {
    match format {
        Format::Csv => csv(result, rows),
        Format::Json => json(result, rows),
    }
}

/// Write a result as CSV, with a header row.
///
/// `NULL` becomes an empty field. CSV cannot tell an empty string from a missing value, and every
/// tool that reads CSV already assumes that, so inventing a marker would be worse.
pub fn csv(result: &ResultSet, rows: Rows) -> String {
    let mut out = String::new();

    let header: Vec<String> = result
        .columns()
        .iter()
        .map(|column| quote(&column.name))
        .collect();
    out.push_str(&header.join(","));
    out.push('\n');

    for row in rows.clamped(result) {
        let fields: Vec<String> = (0..result.columns().len())
            .map(|column| match result.cell(row, column) {
                Some(Cell::Null) | None => String::new(),
                Some(cell) => quote(&cell.text("")),
            })
            .collect();
        out.push_str(&fields.join(","));
        out.push('\n');
    }

    out
}

/// Write a result as a JSON array of objects.
///
/// Numbers stay numbers and booleans stay booleans, so the output can be fed straight to a tool
/// that expects typed JSON rather than a table of strings.
pub fn json(result: &ResultSet, rows: Rows) -> String {
    let records: Vec<serde_json::Value> = rows
        .clamped(result)
        .map(|row| {
            let mut object = serde_json::Map::with_capacity(result.columns().len());
            for (index, column) in result.columns().iter().enumerate() {
                let cell = result.cell(row, index).unwrap_or(&Cell::Null);
                object.insert(column.name.clone(), value(cell));
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

/// Quote a CSV field, per RFC 4180.
fn quote(field: &str) -> String {
    if !field.contains([',', '"', '\n', '\r']) {
        return field.to_owned();
    }
    format!("\"{}\"", field.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use sqmeow_db::Column;

    use super::*;

    fn column(name: &str) -> Column {
        Column {
            name: name.into(),
            type_name: "TEXT".into(),
        }
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
        let text = csv(&sample(), Rows::all(&sample()));
        assert_eq!(text.lines().next(), Some("id,name"));
    }

    #[test]
    fn csv_writes_null_as_an_empty_field() {
        let text = csv(&sample(), Rows::all(&sample()));
        assert_eq!(text.lines().nth(2), Some("2,"));
    }

    #[test]
    fn csv_quotes_only_what_needs_it() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Text("plain".into())]);
        result.push_row(vec![Cell::Text("has,comma".into())]);
        result.push_row(vec![Cell::Text("has\"quote".into())]);
        result.push_row(vec![Cell::Text("has\nbreak".into())]);

        let text = csv(&result, Rows::all(&result));
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
        let text = csv(&result, Rows::one(1));
        assert_eq!(text.lines().count(), 2);
        assert_eq!(text.lines().nth(1), Some("2,"));
    }

    #[test]
    fn a_row_range_past_the_end_is_clamped() {
        let result = sample();
        let text = csv(&result, Rows { start: 0, end: 99 });
        assert_eq!(text.lines().count(), 3);

        let empty = csv(
            &result,
            Rows {
                start: 99,
                end: 100,
            },
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
            serde_json::from_str(&json(&result, Rows::all(&result))).unwrap();
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
            serde_json::from_str(&json(&result, Rows::all(&result))).unwrap();
        assert_eq!(parsed[0]["doc"]["a"], serde_json::json!(1));
    }

    #[test]
    fn json_keeps_line_breaks_in_a_string() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Text("a\nb".into())]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, Rows::all(&result))).unwrap();
        assert_eq!(parsed[0]["v"], serde_json::json!("a\nb"));
    }

    #[test]
    fn json_falls_back_to_text_for_a_number_it_cannot_represent() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Float(f64::INFINITY)]);

        let parsed: serde_json::Value =
            serde_json::from_str(&json(&result, Rows::all(&result))).unwrap();
        assert_eq!(parsed[0]["v"], serde_json::json!("Infinity"));
    }

    #[test]
    fn an_empty_result_writes_an_empty_json_array() {
        let result = ResultSet::new("select 1", vec![column("v")]);
        assert_eq!(json(&result, Rows::all(&result)), "[]");
    }
}
