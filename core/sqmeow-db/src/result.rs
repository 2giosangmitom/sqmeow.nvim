//! A result set, stored by column.
//!
//! Columnar rather than row-major because both things done with a result walk columns: measuring
//! how wide each one must be, and laying out a page. A row-major store would stride through memory
//! once per column on every measurement.

use std::time::Duration;

use crate::value::Cell;

/// One column of a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    /// The name the database gave it.
    pub name: String,
    /// The database's own type name, shown in the row detail.
    pub type_name: String,
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
        vec![
            Column {
                name: "id".into(),
                type_name: "INTEGER".into(),
            },
            Column {
                name: "name".into(),
                type_name: "TEXT".into(),
            },
        ]
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
