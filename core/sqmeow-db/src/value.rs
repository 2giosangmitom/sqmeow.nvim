//! One decoded cell.
//!
//! Every driver funnels its own types into this enum, so the renderer and the exporters never
//! learn what a Postgres `timestamptz` or a SQLite storage class is. Adding a database adds
//! decoding, not new cases to handle downstream.

use std::borrow::Cow;

/// How much of a large binary value is kept.
///
/// A blob column can hold megabytes. Only the head is needed to show the user what is there, and
/// keeping whole blobs for a page of results would dwarf the rest of the result set.
pub const BYTES_PREVIEW: usize = 64;

/// A single value from a result row.
#[derive(Debug, Clone, PartialEq)]
pub enum Cell {
    /// SQL `NULL`, which is distinct from an empty string and displayed as such.
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    /// Exact numerics, kept as text because they do not fit a float without losing digits.
    Decimal(String),
    Text(String),
    /// A binary value, possibly only the head of one.
    Bytes {
        /// The first [`BYTES_PREVIEW`] bytes, or all of them if the value is shorter.
        head: Vec<u8>,
        /// The true length, which may exceed what `head` holds.
        len: usize,
    },
    Json(String),
    Timestamp(String),
    Date(String),
    Time(String),
    Uuid(String),
    Array(Vec<Cell>),
    /// A type no adapter claims to understand, kept as the driver's own text form.
    ///
    /// This case is what keeps one exotic column from failing a whole query.
    Unsupported {
        type_name: String,
        raw: String,
    },
}

impl Cell {
    /// Whether this is SQL `NULL`.
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    /// Whether this value reads as a number, which is what decides right alignment.
    pub fn is_numeric(&self) -> bool {
        matches!(self, Self::Int(_) | Self::Float(_) | Self::Decimal(_))
    }

    /// Build a binary cell, keeping only the head of a large value.
    pub fn bytes(data: &[u8]) -> Self {
        Self::Bytes {
            head: data.iter().take(BYTES_PREVIEW).copied().collect(),
            len: data.len(),
        }
    }

    /// The value's text, exactly as it is.
    ///
    /// Line breaks and tabs survive. This is what an export writes, where the file format has its
    /// own way of carrying them and mangling them would corrupt the data.
    pub fn text<'a>(&'a self, null_text: &'a str) -> Cow<'a, str> {
        match self {
            Self::Text(text) | Self::Json(text) => Cow::Borrowed(text),
            Self::Unsupported { raw, .. } if !raw.is_empty() => Cow::Borrowed(raw),
            other => other.display(null_text),
        }
    }

    /// The single-line form shown in a grid cell.
    ///
    /// Line breaks and tabs become their escape sequences rather than a symbol, because a grid row
    /// is one line and an ASCII escape reads the same in every terminal and every font.
    pub fn display<'a>(&'a self, null_text: &'a str) -> Cow<'a, str> {
        match self {
            Self::Null => Cow::Borrowed(null_text),
            Self::Bool(value) => Cow::Borrowed(if *value { "true" } else { "false" }),
            Self::Int(value) => Cow::Owned(value.to_string()),
            Self::Float(value) => Cow::Owned(format_float(*value)),
            Self::Decimal(text)
            | Self::Timestamp(text)
            | Self::Date(text)
            | Self::Time(text)
            | Self::Uuid(text) => escape(text),
            Self::Text(text) | Self::Json(text) => escape(text),
            // A driver that cannot give a text form still owes the user the type name, so the
            // cell reads as "a value of a type we cannot show" rather than as an empty one.
            Self::Unsupported { type_name, raw } if raw.is_empty() => {
                Cow::Owned(format!("<{type_name}>"))
            }
            Self::Unsupported { raw, .. } => escape(raw),
            Self::Bytes { head, len } => Cow::Owned(format_bytes(head, *len)),
            Self::Array(items) => Cow::Owned(format_array(items, null_text)),
        }
    }

    /// The type name to show in a row detail view.
    pub fn type_name(&self) -> &str {
        match self {
            Self::Null => "null",
            Self::Bool(_) => "boolean",
            Self::Int(_) => "integer",
            Self::Float(_) => "float",
            Self::Decimal(_) => "decimal",
            Self::Text(_) => "text",
            Self::Bytes { .. } => "bytes",
            Self::Json(_) => "json",
            Self::Timestamp(_) => "timestamp",
            Self::Date(_) => "date",
            Self::Time(_) => "time",
            Self::Uuid(_) => "uuid",
            Self::Array(_) => "array",
            Self::Unsupported { type_name, .. } => type_name,
        }
    }
}

/// Render a float without an exponent for ordinary magnitudes, and without a trailing `.0`.
fn format_float(value: f64) -> String {
    if value.is_nan() {
        return "NaN".into();
    }
    if value.is_infinite() {
        return if value.is_sign_negative() {
            "-Infinity".into()
        } else {
            "Infinity".into()
        };
    }
    let text = format!("{value}");
    text.strip_suffix(".0").map(str::to_owned).unwrap_or(text)
}

fn format_bytes(head: &[u8], len: usize) -> String {
    let mut out = String::with_capacity(head.len() * 2 + 16);
    out.push_str("0x");
    for byte in head {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    if len > head.len() {
        use std::fmt::Write as _;
        let _ = write!(out, "… ({len} bytes)");
    }
    out
}

fn format_array(items: &[Cell], null_text: &str) -> String {
    let parts: Vec<Cow<'_, str>> = items.iter().map(|item| item.display(null_text)).collect();
    format!("[{}]", parts.join(", "))
}

/// Replace the characters that would break a one-line cell, allocating only when one is present.
fn escape(text: &str) -> Cow<'_, str> {
    if !text.contains(['\n', '\r', '\t']) {
        return Cow::Borrowed(text);
    }

    let mut out = String::with_capacity(text.len() + 8);
    for character in text.chars() {
        match character {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(cell: &Cell) -> String {
        cell.display("NULL").into_owned()
    }

    #[test]
    fn null_uses_the_configured_text() {
        assert_eq!(shown(&Cell::Null), "NULL");
        assert_eq!(Cell::Null.display("~").into_owned(), "~");
        assert!(Cell::Null.is_null());
    }

    #[test]
    fn an_empty_string_is_not_null() {
        assert_eq!(shown(&Cell::Text(String::new())), "");
        assert!(!Cell::Text(String::new()).is_null());
    }

    #[test]
    fn floats_drop_a_trailing_zero() {
        assert_eq!(shown(&Cell::Float(1.0)), "1");
        assert_eq!(shown(&Cell::Float(1.5)), "1.5");
        assert_eq!(shown(&Cell::Float(f64::NAN)), "NaN");
        assert_eq!(shown(&Cell::Float(f64::NEG_INFINITY)), "-Infinity");
    }

    #[test]
    fn line_breaks_become_escapes() {
        assert_eq!(shown(&Cell::Text("a\nb\tc".into())), "a\\nb\\tc");
    }

    #[test]
    fn text_without_control_characters_is_not_copied() {
        let cell = Cell::Text("plain".into());
        assert!(matches!(cell.display("NULL"), Cow::Borrowed(_)));
    }

    #[test]
    fn short_blobs_are_shown_whole() {
        assert_eq!(shown(&Cell::bytes(&[0xde, 0xad])), "0xdead");
    }

    #[test]
    fn long_blobs_report_their_true_length() {
        let cell = Cell::bytes(&[0u8; BYTES_PREVIEW * 2]);
        let shown = shown(&cell);
        assert!(
            shown.ends_with(&format!("… ({} bytes)", BYTES_PREVIEW * 2)),
            "{shown}"
        );
        match cell {
            Cell::Bytes { head, len } => {
                assert_eq!(head.len(), BYTES_PREVIEW);
                assert_eq!(len, BYTES_PREVIEW * 2);
            }
            other => panic!("expected bytes, got {other:?}"),
        }
    }

    #[test]
    fn arrays_show_their_elements() {
        let cell = Cell::Array(vec![Cell::Int(1), Cell::Null, Cell::Text("x".into())]);
        assert_eq!(shown(&cell), "[1, NULL, x]");
    }

    #[test]
    fn only_numbers_align_right() {
        assert!(Cell::Int(1).is_numeric());
        assert!(Cell::Float(1.0).is_numeric());
        assert!(Cell::Decimal("1.00".into()).is_numeric());
        assert!(!Cell::Text("1".into()).is_numeric());
        assert!(!Cell::Null.is_numeric());
    }

    #[test]
    fn text_keeps_line_breaks_that_display_escapes() {
        let cell = Cell::Text("a\nb".into());
        assert_eq!(cell.text("NULL"), "a\nb");
        assert_eq!(cell.display("NULL"), "a\\nb");
    }

    #[test]
    fn text_agrees_with_display_where_there_is_nothing_to_escape() {
        for cell in [Cell::Int(1), Cell::Bool(true), Cell::Null, Cell::Float(1.5)] {
            assert_eq!(cell.text("NULL"), cell.display("NULL"));
        }
    }

    #[test]
    fn an_unsupported_value_with_no_text_shows_its_type() {
        let cell = Cell::Unsupported {
            type_name: "INTERVAL".into(),
            raw: String::new(),
        };
        assert_eq!(shown(&cell), "<INTERVAL>");
    }

    #[test]
    fn an_unsupported_value_keeps_its_type_name() {
        let cell = Cell::Unsupported {
            type_name: "tsvector".into(),
            raw: "'cat':1".into(),
        };
        assert_eq!(cell.type_name(), "tsvector");
        assert_eq!(shown(&cell), "'cat':1");
    }
}
