//! Defines a single decoded cell value.

use std::borrow::Cow;

/// How much of a binary value a grid cell shows.
pub const BYTES_SHOWN: usize = 64;

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
    /// A binary value.
    Bytes {
        /// Every byte of it.
        head: Vec<u8>,
        /// How many bytes it holds.
        len: usize,
    },
    Json(String),
    Timestamp(String),
    Date(String),
    Time(String),
    Uuid(String),
    Array(Vec<Cell>),
    /// A type no adapter claims to understand, kept as the driver's own text form.
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

    /// Build a binary cell.
    pub fn bytes(data: &[u8]) -> Self {
        Self::Bytes {
            head: data.to_vec(),
            len: data.len(),
        }
    }

    /// The value's text, exactly as it is.
    pub fn text<'a>(&'a self, null_text: &'a str) -> Cow<'a, str> {
        match self {
            Self::Text(text) | Self::Json(text) => Cow::Borrowed(text),
            Self::Unsupported { raw, .. } if !raw.is_empty() => Cow::Borrowed(raw),
            Self::Bytes { head, len } => Cow::Owned(format_bytes(head, *len)),
            other => other.display(null_text),
        }
    }

    /// The single-line form shown in a grid cell.
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
            // A driver that cannot give a text form still owes the user the type name.
            Self::Unsupported { type_name, raw } if raw.is_empty() => {
                Cow::Owned(format!("<{type_name}>"))
            }
            Self::Unsupported { raw, .. } => escape(raw),
            Self::Bytes { head, len } => {
                Cow::Owned(format_bytes(&head[..head.len().min(BYTES_SHOWN)], *len))
            }
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

    #[test]
    fn null_and_empty_text_remain_distinct() {
        assert!(Cell::Null.is_null());
        assert!(!Cell::Text(String::new()).is_null());
    }

    #[test]
    fn binary_text_preserves_the_whole_value() {
        let cell = Cell::bytes(&[0u8; BYTES_SHOWN * 2]);
        assert_eq!(cell.text("").len(), 2 + BYTES_SHOWN * 4);
    }

    #[test]
    fn numeric_cells_are_distinct_from_numeric_text_and_null() {
        assert!(Cell::Int(1).is_numeric());
        assert!(Cell::Float(1.0).is_numeric());
        assert!(Cell::Decimal("1.00".into()).is_numeric());
        assert!(!Cell::Text("1".into()).is_numeric());
        assert!(!Cell::Null.is_numeric());
    }

    #[test]
    fn text_keeps_line_breaks() {
        let cell = Cell::Text("a\nb".into());
        assert_eq!(cell.text("NULL"), "a\nb");
    }

    #[test]
    fn an_unsupported_value_keeps_its_type_name() {
        let cell = Cell::Unsupported {
            type_name: "tsvector".into(),
            raw: "'cat':1".into(),
        };
        assert_eq!(cell.type_name(), "tsvector");
        assert_eq!(cell.text(""), "'cat':1");
    }
}
