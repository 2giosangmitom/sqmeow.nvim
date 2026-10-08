//! Defines the lossless retained Polars DataFrame and its database metadata.
//!
//! Adapters append row-shaped data into ingestion buffers, transferred to
//! Object columns on first read or publication. Typed view/CSV projections share
//! this source without changing its cells. Source metadata links editable
//! cells back to table keys and is separate from display column metadata.

use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use polars::prelude::{Column as FrameColumn, DataFrame, IntoSeries, ObjectChunked};

use crate::edit::Source;
use crate::types::{KeyKind, TypeClass};
use crate::value::{Cell, RetainedCell};

mod retained;
pub(crate) use retained::CellColumn;
use retained::RetainedFrame;

/// Describes one column of a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    /// The name the database gave it.
    pub name: String,
    /// The database's own type name, shown in the row detail.
    pub type_name: String,
    /// What kind of value it holds, for the icon in the grid header.
    pub class: TypeClass,
    /// Whether it is a key in the table it came from.
    pub key: KeyKind,
    /// Whether the database fills it in, such as an auto-increment key.
    pub generated: bool,
}

impl Column {
    /// Creates a column whose class is inferred from its type name.
    pub fn new(name: impl Into<String>, type_name: impl Into<String>) -> Self {
        let type_name = type_name.into();
        Self {
            name: name.into(),
            class: TypeClass::from_type_name(&type_name),
            type_name,
            key: KeyKind::None,
            generated: false,
        }
    }

    /// Returns this column marked with `key`.
    pub fn with_key(mut self, key: KeyKind) -> Self {
        self.key = key;
        self
    }
}

/// Describes the kinds of values present in a column.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ColumnStats {
    /// Whether any value in the column is `NULL`.
    pub nulls: bool,
    /// Whether every value in the column is a number.
    pub numeric: bool,
}

/// Holds the rows one statement produced in a lossless Polars DataFrame.
///
/// Every data column has `row_count` cells. A statement with no returned rows
/// can still carry affected-row counts and timing. `truncated` means more rows
/// existed than were retained; paging/export cannot recover those omitted rows.
#[derive(Debug, Default)]
pub struct ResultSet {
    columns: Vec<Column>,
    /// Ingestion buffers, moved (not copied) into `frame` on the first read.
    pending: Mutex<Vec<Vec<RetainedCell>>>,
    /// The single retained data model; labels/provenance remain separate metadata.
    frame: OnceLock<RetainedFrame>,
    pub(crate) view_cache: crate::view::cache::FrameCache,
    row_count: usize,
    truncated: bool,
    affected: Option<u64>,
    elapsed: Duration,
    statement: String,
    /// Where the rows are stored, when the adapter could tell and they can be written back.
    source: Option<Source>,
}

impl Clone for ResultSet {
    fn clone(&self) -> Self {
        let frame = OnceLock::new();
        // Finalize before cloning so retained clones share Polars buffers.
        frame.set(self.storage().clone()).expect("new frame slot");
        Self {
            columns: self.columns.clone(),
            pending: Mutex::new(Vec::new()),
            frame,
            view_cache: self.view_cache.clone(),
            row_count: self.row_count,
            truncated: self.truncated,
            affected: self.affected,
            elapsed: self.elapsed,
            statement: self.statement.clone(),
            source: self.source.clone(),
        }
    }
}

fn retained_column(index: usize, cells: Vec<RetainedCell>) -> FrameColumn {
    ObjectChunked::new_from_vec(format!("__sqmeow_cell_{index}").into(), cells)
        .into_series()
        .into()
}

impl ResultSet {
    /// Keep the parameterized source rather than the driver's rewritten placeholders.
    pub fn set_statement(&mut self, statement: impl Into<String>) {
        self.statement = statement.into();
    }

    /// Start an empty result for a statement with these columns.
    pub fn new(statement: impl Into<String>, columns: Vec<Column>) -> Self {
        Self {
            pending: Mutex::new(columns.iter().map(|_| Vec::new()).collect()),
            frame: OnceLock::new(),
            view_cache: crate::view::cache::FrameCache::default(),
            columns,
            row_count: 0,
            truncated: false,
            affected: None,
            elapsed: Duration::ZERO,
            statement: statement.into(),
            source: None,
        }
    }

    /// Append a row, padding missing cells with NULL and discarding excess cells.
    ///
    /// Preserves rectangular storage. This does not enforce a row limit; the
    /// adapter decides when to stop retaining rows and mark the result truncated.
    pub fn push_row(&mut self, mut row: Vec<Cell>) {
        self.view_cache.clear();
        row.resize(self.columns.len(), Cell::Null);
        // INSERT readback appends a chunk without copying existing values.
        // Polars copy-on-write keeps previously cloned results unchanged.
        if let Some(frame) = self.frame.get_mut() {
            let columns = row
                .into_iter()
                .enumerate()
                .map(|(index, cell)| retained_column(index, vec![RetainedCell(cell)]))
                .collect();
            let appended = DataFrame::new(1, columns).expect("rectangular appended row");
            frame.append(RetainedFrame::new(appended));
            self.row_count += 1;
            return;
        }
        for (column, cell) in self
            .pending
            .get_mut()
            .expect("result ingestion poisoned")
            .iter_mut()
            .zip(row)
        {
            column.push(RetainedCell(cell));
        }
        self.row_count += 1;
    }

    /// Take the columns the first row describes, for a result that started without any.
    pub fn adopt_columns(&mut self, columns: Vec<Column>) {
        if !self.columns.is_empty() || self.row_count > 0 {
            return;
        }
        self.frame.take();
        self.view_cache.clear();
        *self.pending.get_mut().expect("result ingestion poisoned") =
            columns.iter().map(|_| Vec::new()).collect();
        self.columns = columns;
    }

    /// Describe one column's values without formatting or measuring them.
    pub fn column_stats(&self, index: usize) -> ColumnStats {
        let cells = self.column_cells(index);

        let mut stats = ColumnStats {
            nulls: false,
            numeric: cells.len() > 0,
        };

        for cell in cells {
            if cell.is_null() {
                stats.nulls = true;
                continue;
            }
            if !cell.is_numeric() {
                stats.numeric = false;
            }
        }

        stats
    }

    /// The columns, in order.
    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    /// Enrich column metadata after execution without changing the result shape.
    pub fn columns_mut(&mut self) -> &mut [Column] {
        self.view_cache.clear();
        &mut self.columns
    }

    /// Every value in one column, in row order.
    pub fn column_cells(&self, column: usize) -> impl ExactSizeIterator<Item = &Cell> {
        retained::Cells::new(self.column_values(column))
    }

    /// One cell, or `None` if either index is out of range.
    #[inline]
    pub fn cell(&self, row: usize, column: usize) -> Option<&Cell> {
        self.column_values(column)?.get(row)
    }

    /// Lossless shared DataFrame. Internal names are positional, so duplicate
    /// database labels never violate Polars' unique-name invariant.
    /// SQL NULL is an explicit Cell inside an Object, not an Arrow null. Use
    /// typed/text projections for Polars predicates and writers, and `cell`
    /// for lossless database values. Cloning this frame shares cell buffers.
    pub fn frame(&self) -> &DataFrame {
        &self.storage().frame
    }

    fn storage(&self) -> &RetainedFrame {
        self.frame.get_or_init(|| {
            let pending =
                std::mem::take(&mut *self.pending.lock().expect("result ingestion poisoned"));
            let columns = pending
                .into_iter()
                .enumerate()
                .map(|(index, cells)| retained_column(index, cells))
                .collect();
            RetainedFrame::new(
                DataFrame::new(self.row_count, columns).expect("rectangular retained frame"),
            )
        })
    }

    #[inline]
    pub(crate) fn column_values(&self, column: usize) -> Option<&CellColumn> {
        self.frame
            .get()
            .unwrap_or_else(|| self.storage())
            .column(column)
    }

    /// Text projection shared by views and CSV. Nulls stay null unless the
    /// caller explicitly requests a textual replacement (single-field CSV).
    /// Only requested rows are formatted, in their original selection order.
    pub(crate) fn text_column(
        &self,
        column: usize,
        rows: &[usize],
        name: &str,
        null: Option<&str>,
    ) -> FrameColumn {
        let cells = self.column_values(column);
        let values: Vec<Option<String>> = rows
            .iter()
            .map(|&row| {
                cells
                    .and_then(|cells| cells.get(row))
                    .filter(|cell| !cell.is_null())
                    .map(|cell| cell.text("").into_owned())
                    .or_else(|| null.map(str::to_owned))
            })
            .collect();
        FrameColumn::new(name.into(), values)
    }

    /// How many rows are held.
    pub fn row_count(&self) -> usize {
        self.row_count
    }

    /// Whether the row cap stopped this result short of what the query would have returned.
    pub fn is_truncated(&self) -> bool {
        self.truncated
    }

    /// Mark this result as cut short by the row cap.
    pub fn mark_truncated(&mut self) {
        self.truncated = true;
    }

    /// Rows changed, for a statement that changes rows rather than returning them.
    pub fn affected(&self) -> Option<u64> {
        self.affected
    }

    /// Record how many rows a statement changed.
    pub fn set_affected(&mut self, affected: u64) {
        self.affected = Some(match self.affected {
            // One statement can report more than once; the counts add up.
            Some(existing) => existing.saturating_add(affected),
            None => affected,
        });
    }

    /// How long the statement took.
    pub fn elapsed(&self) -> Duration {
        self.elapsed
    }

    /// Record how long the statement took.
    pub fn set_elapsed(&mut self, elapsed: Duration) {
        self.elapsed = elapsed;
    }

    /// The statement that produced this result.
    pub fn statement(&self) -> &str {
        &self.statement
    }

    /// Where the rows are stored, for a result that can be edited.
    pub fn source(&self) -> Option<&Source> {
        self.source.as_ref()
    }

    /// Record where the rows are stored.
    pub fn set_source(&mut self, source: Option<Source>) {
        self.source = source;
    }

    /// How many pages of `size` rows this result holds.
    pub fn page_count(&self, size: usize) -> usize {
        if size == 0 {
            return 1;
        }
        self.row_count.div_ceil(size).max(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_read_handles_cover_empty_initial_chunks_and_many_appends() {
        let mut result = ResultSet::new("appends", vec![Column::new("v", "INTEGER")]);
        result.frame();
        for row in 0..64 {
            result.push_row(vec![Cell::Int(row)]);
        }
        let snapshot = result.clone();
        for row in 64..80 {
            result.push_row(vec![Cell::Int(row)]);
        }
        for row in 0..80 {
            assert_eq!(result.cell(row, 0), Some(&Cell::Int(row as i64)));
        }
        assert_eq!(result.column_cells(0).len(), 80);
        assert_eq!(
            result.column_cells(0).cloned().collect::<Vec<_>>(),
            (0..80).map(Cell::Int).collect::<Vec<_>>()
        );
        assert_eq!(snapshot.row_count(), 64);
        assert!(snapshot.cell(64, 0).is_none());
        assert!(result.cell(usize::MAX, 0).is_none());
        assert!(result.cell(0, usize::MAX).is_none());
        assert_eq!(result.column_cells(99).len(), 0);
        assert!(std::ptr::eq(
            result.cell(0, 0).unwrap(),
            snapshot.cell(0, 0).unwrap()
        ));
    }

    #[test]
    fn retained_frame_moves_cells_and_clones_share_buffers() {
        let values = vec![
            Cell::Null,
            Cell::Bool(true),
            Cell::Int(i64::MAX),
            Cell::Decimal("12345678901234567890.012300".into()),
            Cell::Text(String::new()),
            Cell::Bytes {
                head: vec![0, 255],
                len: 8,
            },
            Cell::Json(r#"{"a":[1,"x",null]}"#.into()),
            Cell::Timestamp("2026-10-08T01:02:03+07:00".into()),
            Cell::Date("2026-10-08".into()),
            Cell::Time("01:02:03".into()),
            Cell::Uuid("original-uuid-text".into()),
            Cell::Array(vec![Cell::Int(1), Cell::Text("x".into()), Cell::Null]),
            Cell::Unsupported {
                type_name: "custom".into(),
                raw: "exact".into(),
            },
        ];
        let mut result = ResultSet::new("mixed", vec![Column::new("value", "TEXT")]);
        for cell in &values {
            result.push_row(vec![cell.clone()]);
        }
        let ingested = {
            let pending = result.pending.lock().unwrap();
            &pending[0][0].0 as *const Cell
        };
        assert_eq!(result.frame().height(), values.len());
        assert_eq!(ingested, result.cell(0, 0).unwrap() as *const Cell);
        assert!(result.pending.lock().unwrap().is_empty());
        assert_eq!(result.column_cells(0).cloned().collect::<Vec<_>>(), values);
        let clone = result.clone();
        assert!(std::ptr::eq(
            result.cell(0, 0).unwrap(),
            clone.cell(0, 0).unwrap()
        ));
        result.push_row(vec![Cell::Float(f64::NAN)]);
        result.push_row(vec![Cell::Float(f64::INFINITY)]);
        result.push_row(vec![Cell::Float(f64::NEG_INFINITY)]);
        assert!(matches!(result.cell(values.len(), 0), Some(Cell::Float(v)) if v.is_nan()));
        assert_eq!(
            result.cell(values.len() + 1, 0),
            Some(&Cell::Float(f64::INFINITY))
        );
        assert_eq!(
            result.cell(values.len() + 2, 0),
            Some(&Cell::Float(f64::NEG_INFINITY))
        );
        assert_eq!(clone.row_count(), values.len());
        assert!(std::ptr::eq(
            result.cell(0, 0).unwrap(),
            clone.cell(0, 0).unwrap()
        ));
        assert_eq!(clone.column_cells(0).cloned().collect::<Vec<_>>(), values);
    }

    #[test]
    fn finalized_frame_keeps_duplicate_labels_and_rectangular_appends() {
        let mut result = ResultSet::new(
            "duplicates",
            vec![Column::new("v", "TEXT"), Column::new("v", "TEXT")],
        );
        result.push_row(vec![Cell::Int(1)]);
        assert_eq!(result.frame().width(), 2);
        assert_ne!(
            result.frame().columns()[0].name(),
            result.frame().columns()[1].name()
        );
        result.push_row(vec![
            Cell::Text("exact".into()),
            Cell::Int(i64::MAX),
            Cell::Bool(true),
        ]);
        assert_eq!(result.cell(0, 1), Some(&Cell::Null));
        assert_eq!(result.cell(1, 1), Some(&Cell::Int(i64::MAX)));
        assert_eq!(result.columns()[0].name, result.columns()[1].name);
        assert!(result.cell(usize::MAX, 0).is_none());
        assert!(result.cell(0, usize::MAX).is_none());
        let mut empty = ResultSet::default();
        assert_eq!(empty.frame().width(), 0);
        empty.adopt_columns(vec![Column::new("adopted", "TEXT")]);
        empty.push_row(vec![Cell::Text("ok".into())]);
        assert_eq!(empty.cell(0, 0), Some(&Cell::Text("ok".into())));
        let mut no_columns = ResultSet::default();
        no_columns.push_row(Vec::new());
        assert_eq!(no_columns.frame().height(), 1);
    }

    #[test]
    fn retained_frame_initialization_is_shared_between_readers() {
        let mut result = ResultSet::new("concurrent", columns());
        result.push_row(vec![Cell::Int(7), Cell::Text("shared".into())]);
        std::thread::scope(|scope| {
            let a = scope.spawn(|| result.frame() as *const DataFrame as usize);
            let b = scope.spawn(|| result.frame() as *const DataFrame as usize);
            assert_eq!(a.join().unwrap(), b.join().unwrap());
        });
        assert!(result.pending.lock().unwrap().is_empty());
    }

    fn columns() -> Vec<Column> {
        vec![Column::new("id", "INTEGER"), Column::new("name", "TEXT")]
    }

    #[test]
    fn column_stats_preserve_nulls_and_numeric_kinds() {
        let mut result = ResultSet::new("select id, name from t", columns());
        assert_eq!(result.column_stats(0), ColumnStats::default());
        result.push_row(vec![Cell::Int(1), Cell::Text("中é".into())]);
        result.push_row(vec![Cell::Null, Cell::Text("NULL".into())]);
        assert_eq!(
            result.column_stats(0),
            ColumnStats {
                nulls: true,
                numeric: true
            }
        );
        assert_eq!(
            result.column_stats(1),
            ColumnStats {
                nulls: false,
                numeric: false
            }
        );
    }

    #[test]
    fn rows_land_in_their_columns() {
        let mut result = ResultSet::new("select id, name from t", columns());
        result.push_row(vec![Cell::Int(1), Cell::Text("alice".into())]);
        result.push_row(vec![Cell::Int(2), Cell::Text("bob".into())]);

        assert_eq!(result.row_count(), 2);
        assert_eq!(
            result.column_cells(0).cloned().collect::<Vec<_>>(),
            vec![Cell::Int(1), Cell::Int(2)]
        );
        assert_eq!(result.cell(1, 1), Some(&Cell::Text("bob".into())));
    }

    #[test]
    fn out_of_range_lookups_are_none() {
        let result = ResultSet::new("select 1", columns());
        assert_eq!(result.cell(0, 0), None);
        assert_eq!(result.cell(0, 9), None);
        assert_eq!(result.column_cells(9).len(), 0);
    }

    #[test]
    fn a_result_started_without_columns_takes_them_from_its_first_row() {
        let mut result = ResultSet::new("explain select 1", vec![]);
        result.adopt_columns(vec![Column::new("EXPLAIN", "TEXT")]);
        result.push_row(vec![Cell::Text("-> Rows fetched before execution".into())]);
        assert_eq!(result.columns()[0].name, "EXPLAIN");
        assert_eq!(result.row_count(), 1);

        // Columns it already has are never replaced.
        result.adopt_columns(vec![Column::new("other", "TEXT")]);
        assert_eq!(result.columns()[0].name, "EXPLAIN");
    }

    #[test]
    fn a_short_row_is_padded_with_nulls() {
        let mut result = ResultSet::new("select id, name from t", columns());
        result.push_row(vec![Cell::Int(1)]);
        assert_eq!(result.cell(0, 1), Some(&Cell::Null));
    }

    #[test]
    fn a_long_row_is_trimmed() {
        let mut result = ResultSet::new("select id, name from t", columns());
        result.push_row(vec![Cell::Int(1), Cell::Null, Cell::Int(9)]);
        assert_eq!(result.row_count(), 1);
        assert_eq!(result.columns().len(), 2);
    }

    #[test]
    fn affected_counts_accumulate() {
        let mut result = ResultSet::new("update t set x = 1", vec![]);
        assert_eq!(result.affected(), None);
        result.set_affected(2);
        result.set_affected(3);
        assert_eq!(result.affected(), Some(5));
    }

    #[test]
    fn pages_round_up() {
        let mut result = ResultSet::new("select 1", columns());
        assert_eq!(result.page_count(100), 1);
        for index in 0..101 {
            result.push_row(vec![Cell::Int(index), Cell::Null]);
        }
        assert_eq!(result.page_count(100), 2);
        assert_eq!(result.page_count(101), 1);
        // A page size of zero would divide by zero; one page is the sane answer.
        assert_eq!(result.page_count(0), 1);
    }
}
