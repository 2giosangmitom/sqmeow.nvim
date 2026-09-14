//! Keeping a finished result on disk.

use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::Path;
use std::time::Duration;

use rmpv::Value;
use sqmeow_db::{Cell, Column, KeyKind, ResultSet, TypeClass};

use crate::value::map;

/// What the header says the file is, so a file that is not one is refused rather than misread.
const FORMAT: &str = "sqmeow-result";

/// Bumped when the layout changes in a way an older reader would get wrong.
const VERSION: u64 = 1;

/// Save a result.
pub fn write(path: &Path, result: &ResultSet) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let temp = path.with_extension("tmp");
    let outcome = write_to(&temp, result).and_then(|()| fs::rename(&temp, path));
    if outcome.is_err() {
        let _ = fs::remove_file(&temp);
    }
    outcome
}

/// Read a saved result back.
pub fn read(path: &Path) -> Result<ResultSet, String> {
    let file =
        File::open(path).map_err(|error| format!("could not open the saved result: {error}"))?;
    let mut input = BufReader::new(file);

    let header = decode(&mut input)?;
    if lookup(&header, "format").and_then(Value::as_str) != Some(FORMAT) {
        return Err("the file is not a saved result".into());
    }
    match lookup(&header, "version").and_then(Value::as_u64) {
        Some(VERSION) => {}
        other => {
            return Err(format!(
                "the result was saved in format {}, and this engine reads format {VERSION}",
                other.map_or_else(|| "?".to_string(), |version| version.to_string())
            ));
        }
    }

    let columns = lookup(&header, "columns")
        .and_then(Value::as_array)
        .ok_or("the saved result has no columns")?
        .iter()
        .map(column)
        .collect::<Result<Vec<_>, _>>()?;
    let rows = lookup(&header, "rows")
        .and_then(Value::as_u64)
        .ok_or("the saved result does not say how many rows it holds")?;
    let statement = lookup(&header, "statement")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let mut result = ResultSet::new(statement, columns);
    for _ in 0..rows {
        let Value::Array(values) = decode(&mut input)? else {
            return Err("the saved result holds a row that is not a row".into());
        };
        result.push_row(values.iter().map(cell).collect::<Result<Vec<_>, _>>()?);
    }

    if lookup(&header, "truncated").and_then(Value::as_bool) == Some(true) {
        result.mark_truncated();
    }
    if let Some(affected) = lookup(&header, "affected").and_then(Value::as_u64) {
        result.set_affected(affected);
    }
    if let Some(elapsed) = lookup(&header, "elapsed_ms").and_then(Value::as_u64) {
        result.set_elapsed(Duration::from_millis(elapsed));
    }

    Ok(result)
}

fn write_to(path: &Path, result: &ResultSet) -> io::Result<()> {
    let mut out = BufWriter::new(create(path)?);
    encode(&mut out, &header(result))?;

    let width = result.columns().len();
    for row in 0..result.row_count() {
        let cells = (0..width)
            .map(|column| encode_cell(result.cell(row, column).unwrap_or(&Cell::Null)))
            .collect();
        encode(&mut out, &Value::Array(cells))?;
    }

    out.flush()
}

#[cfg(unix)]
fn create(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn create(path: &Path) -> io::Result<File> {
    File::create(path)
}

fn encode(out: &mut impl Write, value: &Value) -> io::Result<()> {
    rmpv::encode::write_value(out, value).map_err(io::Error::other)
}

fn decode(input: &mut impl Read) -> Result<Value, String> {
    // A file that ends early is the one failure worth naming.
    rmpv::decode::read_value(input).map_err(|_| "the saved result is incomplete".to_string())
}

fn header(result: &ResultSet) -> Value {
    let columns = result
        .columns()
        .iter()
        .map(|column| {
            let mut pairs = vec![
                ("name", Value::from(column.name.as_str())),
                ("type_name", Value::from(column.type_name.as_str())),
                ("class", Value::from(column.class.name())),
            ];
            if let Some(key) = column.key.name() {
                pairs.push(("key", Value::from(key)));
            }
            map(pairs)
        })
        .collect();

    let mut pairs = vec![
        ("format", Value::from(FORMAT)),
        ("version", Value::from(VERSION)),
        ("statement", Value::from(result.statement())),
        ("columns", Value::Array(columns)),
        ("rows", Value::from(result.row_count() as u64)),
        ("truncated", Value::from(result.is_truncated())),
        (
            "elapsed_ms",
            Value::from(result.elapsed().as_millis() as u64),
        ),
    ];
    if let Some(affected) = result.affected() {
        pairs.push(("affected", Value::from(affected)));
    }
    map(pairs)
}

fn column(value: &Value) -> Result<Column, String> {
    let name = lookup(value, "name")
        .and_then(Value::as_str)
        .ok_or("the saved result has a column with no name")?;
    let type_name = lookup(value, "type_name")
        .and_then(Value::as_str)
        .unwrap_or_default();

    // Kept as it was saved rather than worked out again.
    let mut column = Column::new(name, type_name);
    if let Some(class) = lookup(value, "class")
        .and_then(Value::as_str)
        .and_then(TypeClass::from_name)
    {
        column.class = class;
    }
    if let Some(key) = lookup(value, "key")
        .and_then(Value::as_str)
        .and_then(KeyKind::from_name)
    {
        column = column.with_key(key);
    }
    Ok(column)
}

fn encode_cell(cell: &Cell) -> Value {
    match cell {
        Cell::Null => Value::Nil,
        Cell::Bool(value) => Value::from(*value),
        Cell::Int(value) => Value::from(*value),
        Cell::Float(value) => Value::from(*value),
        // The commonest kind by far, so it goes untagged.
        Cell::Text(text) => Value::from(text.as_str()),
        Cell::Decimal(text) => tagged("decimal", vec![Value::from(text.as_str())]),
        Cell::Json(text) => tagged("json", vec![Value::from(text.as_str())]),
        Cell::Timestamp(text) => tagged("timestamp", vec![Value::from(text.as_str())]),
        Cell::Date(text) => tagged("date", vec![Value::from(text.as_str())]),
        Cell::Time(text) => tagged("time", vec![Value::from(text.as_str())]),
        Cell::Uuid(text) => tagged("uuid", vec![Value::from(text.as_str())]),
        Cell::Bytes { head, len } => tagged(
            "bytes",
            vec![Value::Binary(head.clone()), Value::from(*len as u64)],
        ),
        Cell::Array(items) => tagged(
            "array",
            vec![Value::Array(items.iter().map(encode_cell).collect())],
        ),
        Cell::Unsupported { type_name, raw } => tagged(
            "unsupported",
            vec![Value::from(type_name.as_str()), Value::from(raw.as_str())],
        ),
    }
}

fn tagged(kind: &str, mut values: Vec<Value>) -> Value {
    values.insert(0, Value::from(kind));
    Value::Array(values)
}

fn cell(value: &Value) -> Result<Cell, String> {
    Ok(match value {
        Value::Nil => Cell::Null,
        Value::Boolean(value) => Cell::Bool(*value),
        Value::Integer(value) => Cell::Int(value.as_i64().ok_or("an integer out of range")?),
        Value::F64(value) => Cell::Float(*value),
        Value::F32(value) => Cell::Float(f64::from(*value)),
        Value::String(text) => {
            Cell::Text(text.as_str().ok_or("text that is not UTF-8")?.to_owned())
        }
        Value::Array(items) => {
            let kind = items
                .first()
                .and_then(Value::as_str)
                .ok_or("a cell that does not say what kind it is")?;
            let text = |index: usize| {
                items
                    .get(index)
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| format!("a {kind} cell with its value missing"))
            };

            match kind {
                "decimal" => Cell::Decimal(text(1)?),
                "json" => Cell::Json(text(1)?),
                "timestamp" => Cell::Timestamp(text(1)?),
                "date" => Cell::Date(text(1)?),
                "time" => Cell::Time(text(1)?),
                "uuid" => Cell::Uuid(text(1)?),
                "bytes" => match (items.get(1), items.get(2).and_then(Value::as_u64)) {
                    (Some(Value::Binary(head)), Some(len)) => Cell::Bytes {
                        head: head.clone(),
                        len: len as usize,
                    },
                    _ => return Err("a bytes cell with its value missing".into()),
                },
                "array" => match items.get(1) {
                    Some(Value::Array(inner)) => {
                        Cell::Array(inner.iter().map(cell).collect::<Result<Vec<_>, _>>()?)
                    }
                    _ => return Err("an array cell with its value missing".into()),
                },
                "unsupported" => Cell::Unsupported {
                    type_name: text(1)?,
                    raw: text(2)?,
                },
                other => return Err(format!("a cell of unknown kind `{other}`")),
            }
        }
        other => return Err(format!("a cell that cannot be read: {other}")),
    })
}

fn lookup<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value
        .as_map()?
        .iter()
        .find(|(name, _)| name.as_str() == Some(key))
        .map(|(_, value)| value)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    /// A path in a directory of its own, removed when the test is done with it.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let directory = std::env::temp_dir().join(format!(
                "sqmeow-archive-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            Self(directory)
        }

        fn file(&self) -> PathBuf {
            self.0.join("results").join("one.msgpack")
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn every_kind() -> Vec<Cell> {
        vec![
            Cell::Null,
            Cell::Bool(true),
            Cell::Int(-42),
            Cell::Float(1.5),
            Cell::Decimal("12345678901234567890.01".into()),
            Cell::Text("line one\nline two".into()),
            Cell::bytes(&[0, 1, 2, 255]),
            Cell::Json(r#"{"a":1}"#.into()),
            Cell::Timestamp("2026-09-13 10:00:00+00".into()),
            Cell::Date("2026-09-13".into()),
            Cell::Time("10:00:00".into()),
            Cell::Uuid("7f1c2d3e-0000-4000-8000-000000000000".into()),
            Cell::Array(vec![Cell::Int(1), Cell::Null, Cell::Text("x".into())]),
            Cell::Unsupported {
                type_name: "POINT".into(),
                raw: "(1,2)".into(),
            },
        ]
    }

    fn result() -> ResultSet {
        let columns = every_kind()
            .iter()
            .enumerate()
            .map(|(index, _)| Column::new(format!("c{index}"), "TEXT"))
            .collect();
        let mut result = ResultSet::new("select everything", columns);
        result.push_row(every_kind());
        result.push_row(vec![Cell::Null; every_kind().len()]);
        result
    }

    #[test]
    fn every_kind_of_cell_comes_back_as_it_went_in() {
        let scratch = Scratch::new();
        let original = result();
        write(&scratch.file(), &original).expect("the result should be written");

        let restored = read(&scratch.file()).expect("the result should be read");
        assert_eq!(restored.row_count(), 2);
        for (index, expected) in every_kind().iter().enumerate() {
            assert_eq!(restored.cell(0, index), Some(expected));
            assert_eq!(restored.cell(1, index), Some(&Cell::Null));
        }
        assert_eq!(restored.statement(), "select everything");
    }

    #[test]
    fn columns_keep_their_type_class_and_key() {
        let scratch = Scratch::new();
        let mut original = ResultSet::new(
            "select id, author_id",
            vec![
                Column::new("id", "INT4").with_key(KeyKind::Primary),
                Column::new("author_id", "INT4").with_key(KeyKind::Foreign),
                Column::new("shape", "POINT"),
            ],
        );
        original.push_row(vec![Cell::Int(1), Cell::Int(2), Cell::Null]);
        write(&scratch.file(), &original).expect("written");

        let restored = read(&scratch.file()).expect("read");
        assert_eq!(restored.columns(), original.columns());
    }

    #[test]
    fn what_is_known_about_the_run_survives() {
        let scratch = Scratch::new();
        let mut original = result();
        original.mark_truncated();
        original.set_affected(7);
        original.set_elapsed(Duration::from_millis(1234));
        write(&scratch.file(), &original).expect("written");

        let restored = read(&scratch.file()).expect("read");
        assert!(restored.is_truncated());
        assert_eq!(restored.affected(), Some(7));
        assert_eq!(restored.elapsed(), Duration::from_millis(1234));
    }

    #[test]
    fn a_file_that_is_not_a_saved_result_is_refused() {
        let scratch = Scratch::new();
        fs::create_dir_all(scratch.file().parent().unwrap()).unwrap();
        fs::write(scratch.file(), b"not msgpack at all").unwrap();

        assert!(read(&scratch.file()).is_err());
    }

    #[test]
    fn a_file_cut_short_is_refused_rather_than_read_as_fewer_rows() {
        let scratch = Scratch::new();
        write(&scratch.file(), &result()).expect("written");

        let bytes = fs::read(scratch.file()).unwrap();
        fs::write(scratch.file(), &bytes[..bytes.len() - 4]).unwrap();

        assert_eq!(
            read(&scratch.file()).err().as_deref(),
            Some("the saved result is incomplete")
        );
    }

    #[test]
    fn nothing_is_left_beside_the_file() {
        let scratch = Scratch::new();
        write(&scratch.file(), &result()).expect("written");

        let names: Vec<_> = fs::read_dir(scratch.file().parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("one.msgpack")]);
    }

    #[cfg(unix)]
    #[test]
    fn only_its_owner_can_read_it() {
        use std::os::unix::fs::PermissionsExt;

        let scratch = Scratch::new();
        write(&scratch.file(), &result()).expect("written");

        let mode = fs::metadata(scratch.file()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
