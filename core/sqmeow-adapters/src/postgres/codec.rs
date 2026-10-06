//! PostgreSQL wire values. Numeric is decoded base-10000, never through a float.
use sqmeow_db::{result::Column, value::Cell};
use tokio_postgres::{
    Row,
    types::{FromSql, Kind, Type},
};

pub(super) fn type_name(ty: &Type) -> String {
    match ty.kind() {
        Kind::Array(element) => format!("{}[]", type_name(element)),
        _ => ty.name().to_ascii_uppercase(),
    }
}
pub(super) fn result_columns(columns: &[tokio_postgres::Column]) -> Vec<Column> {
    columns
        .iter()
        .map(|c| Column::new(c.name(), type_name(c.type_())))
        .collect()
}
pub(super) fn binary_supported(ty: &Type) -> bool {
    match ty.kind() {
        Kind::Array(element) | Kind::Domain(element) => binary_supported(element),
        _ => matches!(
            ty.name(),
            "bool"
                | "int2"
                | "int4"
                | "int8"
                | "oid"
                | "float4"
                | "float8"
                | "numeric"
                | "text"
                | "varchar"
                | "bpchar"
                | "char"
                | "name"
                | "citext"
                | "unknown"
                | "uuid"
                | "json"
                | "jsonb"
                | "timestamp"
                | "timestamptz"
                | "date"
                | "time"
                | "bytea"
                | "void"
        ),
    }
}
struct Raw(Vec<u8>);
impl<'a> FromSql<'a> for Raw {
    fn from_sql(
        _: &Type,
        raw: &'a [u8],
    ) -> std::result::Result<Self, Box<dyn std::error::Error + Sync + Send>> {
        Ok(Self(raw.to_vec()))
    }
    fn accepts(_: &Type) -> bool {
        true
    }
}
pub(super) fn decode_cell(row: &Row, index: usize) -> Cell {
    match row.try_get::<_, Option<Raw>>(index) {
        Ok(Some(raw)) => binary(row.columns()[index].type_(), &raw.0),
        _ => Cell::Null,
    }
}
fn unsupported(ty: &Type, raw: impl Into<String>) -> Cell {
    Cell::Unsupported {
        type_name: type_name(ty),
        raw: raw.into(),
    }
}
fn binary(ty: &Type, raw: &[u8]) -> Cell {
    if matches!(ty.kind(), Kind::Enum(_)) {
        return unsupported(
            ty,
            String::from_utf8(raw.to_vec()).unwrap_or_else(|_| hex(raw)),
        );
    }
    if let Kind::Domain(base) = ty.kind() {
        return binary(base, raw);
    }
    if let Kind::Array(element) = ty.kind() {
        return binary_array(element, raw).unwrap_or_else(|| unsupported(ty, hex(raw)));
    }
    macro_rules! scalar {
        ($t:ty,$wrap:expr) => {
            <$t as FromSql>::from_sql(ty, raw)
                .map($wrap)
                .unwrap_or_else(|_| unsupported(ty, hex(raw)))
        };
    }
    match ty.name() {
        "bool" => scalar!(bool, Cell::Bool),
        "int2" => scalar!(i16, |v| Cell::Int(v.into())),
        "int4" => scalar!(i32, |v| Cell::Int(v.into())),
        "int8" => scalar!(i64, Cell::Int),
        "oid" => scalar!(u32, |v| Cell::Int(v.into())),
        "float4" => scalar!(f32, |v| Cell::Float(v.into())),
        "float8" => scalar!(f64, Cell::Float),
        "numeric" => numeric(raw)
            .map(Cell::Decimal)
            .unwrap_or_else(|| unsupported(ty, hex(raw))),
        "text" | "varchar" | "bpchar" | "name" | "citext" | "unknown" => {
            Cell::Text(String::from_utf8_lossy(raw).into_owned())
        }
        "char" => Cell::Text(String::from_utf8_lossy(raw).into_owned()),
        "uuid" => scalar!(uuid::Uuid, |v| Cell::Uuid(v.to_string())),
        "json" | "jsonb" => scalar!(serde_json::Value, |v| Cell::Json(v.to_string())),
        "timestamp" | "timestamptz" if raw == i64::MAX.to_be_bytes() => {
            Cell::Timestamp("infinity".into())
        }
        "timestamp" | "timestamptz" if raw == i64::MIN.to_be_bytes() => {
            Cell::Timestamp("-infinity".into())
        }
        "timestamp" => scalar!(chrono::NaiveDateTime, |v| Cell::Timestamp(v.to_string())),
        "timestamptz" => scalar!(chrono::DateTime<chrono::Utc>, |v| Cell::Timestamp(
            v.to_string()
        )),
        "date" if raw == i32::MAX.to_be_bytes() => Cell::Date("infinity".into()),
        "date" if raw == i32::MIN.to_be_bytes() => Cell::Date("-infinity".into()),
        "date" => scalar!(chrono::NaiveDate, |v| Cell::Date(v.to_string())),
        "time" => scalar!(chrono::NaiveTime, |v| Cell::Time(v.to_string())),
        "bytea" => Cell::bytes(raw),
        "inet" | "cidr" => unsupported(ty, network(raw).unwrap_or_else(|| hex(raw))),
        "void" => unsupported(ty, ""),
        // Unknown binary formats are not SQL text even when their bytes happen to be UTF-8.
        _ => unsupported(ty, hex(raw)),
    }
}

fn network(raw: &[u8]) -> Option<String> {
    let [family, prefix, cidr, length, address @ ..] = raw else {
        return None;
    };
    let (address, full_prefix) = match (*family, *length, address.len()) {
        (2, 4, 4) => (
            std::net::Ipv4Addr::from(<[u8; 4]>::try_from(address).ok()?).to_string(),
            32,
        ),
        (3, 16, 16) => (
            std::net::Ipv6Addr::from(<[u8; 16]>::try_from(address).ok()?).to_string(),
            128,
        ),
        _ => return None,
    };
    if *prefix > full_prefix {
        return None;
    }
    Some(if *cidr != 0 || *prefix != full_prefix {
        format!("{address}/{prefix}")
    } else {
        address
    })
}
fn hex(raw: &[u8]) -> String {
    format!(
        "\\x{}",
        raw.iter().map(|b| format!("{b:02x}")).collect::<String>()
    )
}

fn numeric(raw: &[u8]) -> Option<String> {
    if raw.len() < 8 {
        return None;
    }
    let word = |i| u16::from_be_bytes([raw[i], raw[i + 1]]);
    let count = word(0) as usize;
    let weight = word(2) as i16 as i32;
    let sign = word(4);
    let scale = word(6) as usize;
    match sign {
        0xc000 => return Some("NaN".into()),
        0xd000 => return Some("Infinity".into()),
        0xf000 => return Some("-Infinity".into()),
        0 | 0x4000 => {}
        _ => return None,
    }
    if raw.len() != 8 + count * 2 || scale > 16383 {
        return None;
    }
    let digits: Vec<_> = (0..count).map(|i| word(8 + i * 2)).collect();
    if digits.iter().any(|d| *d >= 10000) {
        return None;
    }
    let digit = |position: i32| -> u16 {
        let i = weight - position;
        if i >= 0 {
            digits.get(i as usize).copied().unwrap_or(0)
        } else {
            0
        }
    };
    let mut out = String::new();
    if sign == 0x4000 && digits.iter().any(|d| *d != 0) {
        out.push('-');
    }
    if weight < 0 {
        out.push('0');
    } else {
        out.push_str(&digit(weight).to_string());
        for position in (0..weight).rev() {
            out.push_str(&format!("{:04}", digit(position)));
        }
    }
    if scale > 0 {
        out.push('.');
        let start = out.len();
        for i in 1..=scale.div_ceil(4) {
            out.push_str(&format!("{:04}", digit(-(i as i32))));
        }
        out.truncate(start + scale);
    }
    Some(out)
}

fn binary_array(element: &Type, raw: &[u8]) -> Option<Cell> {
    let mut pos = 0;
    fn int(raw: &[u8], pos: &mut usize) -> Option<i32> {
        let n = i32::from_be_bytes(raw.get(*pos..*pos + 4)?.try_into().ok()?);
        *pos += 4;
        Some(n)
    }
    let dimensions = int(raw, &mut pos)?;
    if !(0..=6).contains(&dimensions) {
        return None;
    }
    int(raw, &mut pos)?;
    int(raw, &mut pos)?;
    let mut lengths = Vec::new();
    for _ in 0..dimensions {
        let length = int(raw, &mut pos)?;
        if length < 0 || length as usize > raw.len() {
            return None;
        }
        lengths.push(length as usize);
        int(raw, &mut pos)?;
    }
    fn level(element: &Type, raw: &[u8], pos: &mut usize, lengths: &[usize]) -> Option<Cell> {
        let mut cells = Vec::new();
        for _ in 0..*lengths.first()? {
            if lengths.len() > 1 {
                cells.push(level(element, raw, pos, &lengths[1..])?);
            } else {
                let length = int(raw, pos)?;
                if length == -1 {
                    cells.push(Cell::Null);
                } else {
                    let length = usize::try_from(length).ok()?;
                    cells.push(binary(element, raw.get(*pos..*pos + length)?));
                    *pos += length;
                }
            }
        }
        Some(Cell::Array(cells))
    }
    let result = if dimensions == 0 {
        Cell::Array(Vec::new())
    } else {
        level(element, raw, &mut pos, &lengths)?
    };
    (pos == raw.len()).then_some(result)
}

/// Simple protocol has text values but no type OIDs. When prepare succeeds its types
/// are authoritative; otherwise preserve text, never guess a literal's SQL type.
pub(super) fn text(ty: Option<&Type>, value: Option<&str>) -> Cell {
    let Some(value) = value else {
        return Cell::Null;
    };
    let Some(ty) = ty else {
        return Cell::Text(value.into());
    };
    if let Kind::Domain(base) = ty.kind() {
        return text(Some(base), Some(value));
    }
    if let Kind::Array(element) = ty.kind() {
        // box uses ';' as typdelim. Unknown element types may use other delimiters;
        // preserve their authoritative server text rather than guessing its grammar.
        if !binary_supported(element) && element.name() != "interval" {
            return unsupported(ty, value);
        }
        return text_array(element, value).unwrap_or_else(|| unsupported(ty, value));
    }
    match ty.name() {
        "bool" => Cell::Bool(value == "t" || value == "true"),
        "int2" | "int4" | "int8" | "oid" => value
            .parse()
            .map(Cell::Int)
            .unwrap_or_else(|_| unsupported(ty, value)),
        "float4" | "float8" => value
            .parse()
            .map(Cell::Float)
            .unwrap_or_else(|_| unsupported(ty, value)),
        "numeric" => Cell::Decimal(value.into()),
        "text" | "varchar" | "bpchar" | "char" | "name" | "citext" | "unknown" | "interval" => {
            Cell::Text(value.into())
        }
        "uuid" => Cell::Uuid(value.into()),
        "json" | "jsonb" => serde_json::from_str::<serde_json::Value>(value)
            .map(|v| Cell::Json(v.to_string()))
            .unwrap_or_else(|_| unsupported(ty, value)),
        "timestamp" => Cell::Timestamp(value.into()),
        "timestamptz" => chrono::DateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S%.f%#z")
            .map(|v| Cell::Timestamp(v.with_timezone(&chrono::Utc).to_string()))
            .unwrap_or_else(|_| Cell::Timestamp(value.into())),
        "date" => Cell::Date(value.into()),
        "time" => Cell::Time(value.into()),
        "bytea" if value.starts_with("\\x") => {
            let bytes: Option<Vec<u8>> = value.as_bytes()[2..]
                .chunks(2)
                .map(|b| {
                    std::str::from_utf8(b)
                        .ok()
                        .and_then(|s| u8::from_str_radix(s, 16).ok())
                })
                .collect();
            bytes
                .map(|b| Cell::bytes(&b))
                .unwrap_or_else(|| unsupported(ty, value))
        }
        _ => unsupported(ty, value),
    }
}

// PostgreSQL array text grammar: quoted commas/braces, escapes, NULL and dimensions.
fn text_array(element: &Type, input: &str) -> Option<Cell> {
    let input = if input.starts_with('[') {
        input.split_once('=')?.1
    } else {
        input
    };
    let bytes = input.as_bytes();
    fn array(element: &Type, b: &[u8], pos: &mut usize) -> Option<Cell> {
        if b.get(*pos) != Some(&b'{') {
            return None;
        }
        *pos += 1;
        let mut cells = Vec::new();
        if b.get(*pos) == Some(&b'}') {
            *pos += 1;
            return Some(Cell::Array(cells));
        }
        loop {
            if b.get(*pos) == Some(&b'{') {
                cells.push(array(element, b, pos)?);
            } else {
                let quoted = b.get(*pos) == Some(&b'"');
                if quoted {
                    *pos += 1;
                }
                let mut value = Vec::new();
                loop {
                    let ch = *b.get(*pos)?;
                    if quoted && ch == b'"' {
                        *pos += 1;
                        break;
                    }
                    if !quoted && (ch == b',' || ch == b'}') {
                        break;
                    }
                    *pos += 1;
                    if ch == b'\\' {
                        value.push(*b.get(*pos)?);
                        *pos += 1;
                    } else {
                        value.push(ch);
                    }
                }
                let value = String::from_utf8(value).ok()?;
                cells.push(if !quoted && value == "NULL" {
                    Cell::Null
                } else {
                    text(Some(element), Some(&value))
                });
            }
            match b.get(*pos)? {
                b',' => *pos += 1,
                b'}' => {
                    *pos += 1;
                    break;
                }
                _ => return None,
            }
        }
        Some(Cell::Array(cells))
    }
    let mut pos = 0;
    let result = array(element, bytes, &mut pos)?;
    (pos == bytes.len()).then_some(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn box_array_preserves_semicolon_delimited_server_text() {
        let value = "{(3,4),(1,2);(7,8),(5,6)}";
        assert_eq!(
            text(Some(&Type::BOX_ARRAY), Some(value)),
            Cell::Unsupported {
                type_name: "BOX[]".into(),
                raw: value.into(),
            }
        );
    }
    #[test]
    fn numeric_preserves_groups_scale_and_sign() {
        assert_eq!(
            numeric(&[0, 3, 0, 1, 0, 0, 0, 5, 0, 12, 13, 128, 0, 50]),
            Some("123456.00500".into())
        );
        assert_eq!(
            numeric(&[0, 1, 255, 255, 64, 0, 0, 4, 0, 1]),
            Some("-0.0001".into())
        );
        assert_eq!(numeric(&[0, 0, 0, 0, 0, 0, 0, 2]), Some("0.00".into()));
        assert!(numeric(&[0, 1, 0, 0, 0, 0, 0, 0, 39, 16]).is_none());
    }
    #[test]
    fn text_array_handles_quoted_delimiters_escapes_nulls_and_dimensions() {
        assert_eq!(
            text_array(&Type::TEXT, r#"[0:3]={"a,b","NULL",NULL,"a\\b\"c"}"#),
            Some(Cell::Array(vec![
                Cell::Text("a,b".into()),
                Cell::Text("NULL".into()),
                Cell::Null,
                Cell::Text("a\\b\"c".into())
            ]))
        );
        assert_eq!(
            text_array(&Type::INT4, "{{1,NULL},{2,3}}"),
            Some(Cell::Array(vec![
                Cell::Array(vec![Cell::Int(1), Cell::Null]),
                Cell::Array(vec![Cell::Int(2), Cell::Int(3)])
            ]))
        );
    }
}
