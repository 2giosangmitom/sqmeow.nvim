//! Defines the in-memory result set stored column-wise.
//!
//! Adapters append row-shaped data; the result stores columns independently for
//! paging, filtering, and export. Source metadata links editable
//! cells back to table keys and is separate from display column metadata.

use std::time::Duration;

use crate::edit::Source;
use crate::types::{KeyKind, TypeClass};
use crate::value::Cell;

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

/// Holds the rows one statement produced, stored column-wise.
///
/// Every data column has `row_count` cells. A statement with no returned rows
/// can still carry affected-row counts and timing. `truncated` means more rows
/// existed than were retained; paging/export cannot recover those omitted rows.
#[derive(Debug, Clone, Default)]
pub struct ResultSet {
    columns: Vec<Column>,
    /// `data[column][row]`.
    data: Vec<Vec<Cell>>,
    row_count: usize,
    truncated: bool,
    affected: Option<u64>,
    elapsed: Duration,
    statement: String,
    /// Where the rows are stored, when the adapter could tell and they can be written back.
    source: Option<Source>,
}

impl ResultSet {
    /// Keep the parameterized source rather than the driver's rewritten placeholders.
    pub fn set_statement(&mut self, statement: impl Into<String>) {
        self.statement = statement.into();
    }

    /// Start an empty result for a statement with these columns.
    pub fn new(statement: impl Into<String>, columns: Vec<Column>) -> Self {
        Self {
            data: columns.iter().map(|_| Vec::new()).collect(),
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
        row.resize(self.columns.len(), Cell::Null);
        for (column, cell) in self.data.iter_mut().zip(row) {
            column.push(cell);
        }
        self.row_count += 1;
    }

    /// Take the columns the first row describes, for a result that started without any.
    pub fn adopt_columns(&mut self, columns: Vec<Column>) {
        if !self.columns.is_empty() || self.row_count > 0 {
            return;
        }
        self.data = columns.iter().map(|_| Vec::new()).collect();
        self.columns = columns;
    }

    /// Describe one column's values without formatting or measuring them.
    pub fn column_stats(&self, index: usize) -> ColumnStats {
        let cells = self.column_cells(index);

        let mut stats = ColumnStats {
            nulls: false,
            numeric: !cells.is_empty(),
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
        &mut self.columns
    }

    /// Every value in one column, in row order.
    pub fn column_cells(&self, column: usize) -> &[Cell] {
        self.data.get(column).map_or(&[], Vec::as_slice)
    }

    /// One cell, or `None` if either index is out of range.
    pub fn cell(&self, row: usize, column: usize) -> Option<&Cell> {
        self.data.get(column)?.get(row)
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
            Some(existing) => existing + affected,
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
        assert_eq!(result.column_cells(0), &[Cell::Int(1), Cell::Int(2)]);
        assert_eq!(result.cell(1, 1), Some(&Cell::Text("bob".into())));
    }

    #[test]
    fn out_of_range_lookups_are_none() {
        let result = ResultSet::new("select 1", columns());
        assert_eq!(result.cell(0, 0), None);
        assert_eq!(result.cell(0, 9), None);
        assert!(result.column_cells(9).is_empty());
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
