//! A result set, stored by column.
//!
//! Columnar rather than row-major because both things done with a result walk columns: measuring
//! how wide each one must be, and laying out a page. A row-major store would stride through memory
//! once per column on every measurement.

use std::time::Duration;

use crate::edit::Source;
use crate::types::{KeyKind, TypeClass};
use crate::value::Cell;
use crate::width;

/// The widest a column is measured to, past which the exact figure stops mattering.
///
/// The editor caps columns far below this, so a value wider than the cap only ever needs to be
/// known as "wider than the cap". Measuring a megabyte of text to learn that costs real time when
/// a result holds a hundred thousand of them.
pub const MAX_MEASURED_WIDTH: usize = 512;

/// One column of a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    /// The name the database gave it.
    pub name: String,
    /// The database's own type name, shown in the row detail.
    pub type_name: String,
    /// What kind of value it holds, for the icon in the grid header.
    pub class: TypeClass,
    /// Whether it is a key in the table it came from.
    ///
    /// Note that this is the one field here the plugin cannot work out for itself.
    ///
    /// Always [`KeyKind::None`] for a column that is an expression rather than a table's: a
    /// `count(*)` is nobody's primary key. An adapter that cannot attribute a column to a table
    /// leaves this alone rather than guessing.
    pub key: KeyKind,
    /// The column's name in the table it came from, which an alias hides: `name as who` is `name`.
    ///
    /// `None` for an expression, and for a result whose adapter cannot say. It is what lets an edit
    /// to an aliased column update the right one.
    pub origin: Option<String>,
}

impl Column {
    /// A column whose class follows from its type name and which is not a key.
    ///
    /// Every adapter builds result columns through here, so classification happens once rather
    /// than three times, and a dialect cannot forget to do it.
    pub fn new(name: impl Into<String>, type_name: impl Into<String>) -> Self {
        let type_name = type_name.into();
        Self {
            name: name.into(),
            class: TypeClass::from_type_name(&type_name),
            type_name,
            key: KeyKind::None,
            origin: None,
        }
    }

    /// The same column, naming the table column it came from.
    pub fn with_origin(mut self, origin: impl Into<String>) -> Self {
        self.origin = Some(origin.into());
        self
    }

    /// The same column, marked as a key.
    pub fn with_key(mut self, key: KeyKind) -> Self {
        self.key = key;
        self
    }
}

/// What the editor needs to size a column, measured once over the whole result.
///
/// Measured here rather than in the editor because the editor is only ever sent one page, and a
/// column sized from one page changes width when the user turns to the next: the grid would appear
/// to shift under them. Counting characters is not laying anything out — nothing here knows what a
/// separator is, how a value is aligned, or what `NULL` is shown as.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ColumnStats {
    /// Display columns taken by the widest value, `NULL`s excluded and capped at
    /// [`MAX_MEASURED_WIDTH`].
    ///
    /// `NULL`s are excluded because what they are shown as is the plugin's to choose, so only the
    /// plugin can say how wide one is.
    pub widest: usize,
    /// Whether any value in the column is `NULL`.
    pub nulls: bool,
    /// Whether every value in the column is a number, which is what decides right alignment.
    ///
    /// A column of numbers with one `NULL` is still numeric, and one stray text value makes the
    /// whole column textual.
    pub numeric: bool,
}

/// The rows one statement produced.
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

    /// Append a row.
    ///
    /// A row with the wrong number of cells is padded or trimmed rather than rejected, because
    /// losing a whole result to one malformed row helps nobody.
    pub fn push_row(&mut self, mut row: Vec<Cell>) {
        row.resize(self.columns.len(), Cell::Null);
        for (column, cell) in self.data.iter_mut().zip(row) {
            column.push(cell);
        }
        self.row_count += 1;
    }

    /// Take the columns the first row describes, for a result that started without any.
    ///
    /// Preparing a statement is how an adapter learns its columns before running it, and some
    /// statements that return rows will not prepare: MySQL's `EXPLAIN` is one. Without this, every
    /// row of such a result would be trimmed to the no columns it was started with. Once a result
    /// has columns or rows, it keeps them.
    pub fn adopt_columns(&mut self, columns: Vec<Column>) {
        if !self.columns.is_empty() || self.row_count > 0 {
            return;
        }
        self.data = columns.iter().map(|_| Vec::new()).collect();
        self.columns = columns;
    }

    /// Measure one column for the editor.
    ///
    /// Walks the whole column once. This is the only pass over every cell the engine makes on a
    /// result, and it is what lets the editor draw a page at a time without the columns moving.
    pub fn column_stats(&self, index: usize) -> ColumnStats {
        let cells = self.column_cells(index);

        let mut stats = ColumnStats {
            widest: 0,
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
            if stats.widest < MAX_MEASURED_WIDTH {
                // Measured against the same text the plugin will draw, so a value holding a line
                // break is measured as the escape sequence that reaches the grid rather than as
                // the two lines it would otherwise be.
                let shown = cell.display("");
                stats.widest = stats
                    .widest
                    .max(width::width_capped(&shown, MAX_MEASURED_WIDTH));
            }
        }

        stats.widest = stats.widest.min(MAX_MEASURED_WIDTH);
        stats
    }

    /// The columns, in order.
    pub fn columns(&self) -> &[Column] {
        &self.columns
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

    /// How many pages of `size` rows this result holds. Always at least one, so an empty result
    /// still has a page to show.
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
    fn a_column_is_measured_over_every_row() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "TEXT")]);
        result.push_row(vec![Cell::Text("short".into())]);
        result.push_row(vec![Cell::Text("a much longer value".into())]);

        // Over the whole column, not one page of it, which is the point: a column sized from the
        // first page would change width when the user turned to the second.
        let stats = result.column_stats(0);
        assert_eq!(stats.widest, 19);
        assert!(!stats.nulls);
        assert!(!stats.numeric);
    }

    #[test]
    fn a_null_is_reported_rather_than_measured() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "INTEGER")]);
        result.push_row(vec![Cell::Int(1)]);
        result.push_row(vec![Cell::Null]);

        // What `NULL` is drawn as is the plugin's to choose, so only the plugin can say how wide
        // one is. A `NULL` still leaves the column numeric.
        let stats = result.column_stats(0);
        assert_eq!(stats.widest, 1);
        assert!(stats.nulls);
        assert!(stats.numeric);
    }

    #[test]
    fn one_text_value_makes_a_column_textual() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "TEXT")]);
        result.push_row(vec![Cell::Int(1)]);
        result.push_row(vec![Cell::Text("x".into())]);
        assert!(!result.column_stats(0).numeric);
    }

    #[test]
    fn an_empty_column_is_not_numeric() {
        // Nothing to align, and calling it numeric would right-align a header over no rows.
        let result = ResultSet::new("select v", vec![Column::new("v", "INTEGER")]);
        assert!(!result.column_stats(0).numeric);
    }

    #[test]
    fn a_very_wide_value_is_measured_only_far_enough() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "TEXT")]);
        result.push_row(vec![Cell::Text("a".repeat(100_000))]);

        // The editor caps columns far below this, so the exact figure stops mattering; measuring
        // the whole megabyte to learn it is wide would cost real time on a large result.
        assert_eq!(result.column_stats(0).widest, MAX_MEASURED_WIDTH);
    }

    #[test]
    fn width_is_measured_in_display_columns() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "TEXT")]);
        result.push_row(vec![Cell::Text("日本".into())]);
        assert_eq!(result.column_stats(0).widest, 4);
    }

    #[test]
    fn a_line_break_is_measured_as_what_reaches_the_grid() {
        let mut result = ResultSet::new("select v", vec![Column::new("v", "TEXT")]);
        result.push_row(vec![Cell::Text("a\nb".into())]);
        // Four columns: the escape is what the plugin draws, so it is what was measured.
        assert_eq!(result.column_stats(0).widest, 4);
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
    fn an_empty_result_still_has_one_page() {
        let result = ResultSet::new("select 1", columns());
        assert_eq!(result.page_count(100), 1);
    }

    #[test]
    fn pages_round_up() {
        let mut result = ResultSet::new("select 1", columns());
        for index in 0..101 {
            result.push_row(vec![Cell::Int(index), Cell::Null]);
        }
        assert_eq!(result.page_count(100), 2);
        assert_eq!(result.page_count(101), 1);
        // A page size of zero would divide by zero; one page is the sane answer.
        assert_eq!(result.page_count(0), 1);
    }
}
