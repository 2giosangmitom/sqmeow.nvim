//! Filters and sorts rows held in memory.

mod expression;

pub use expression::{Query, names};

use std::cmp::Ordering;

use crate::result::ResultSet;
use crate::value::Cell;

/// How a filter compares a cell with its value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Eq,
    Ne,
    Gt,
    Ge,
    Lt,
    Le,
    Contains,
    StartsWith,
    IsNull,
    NotNull,
}

impl Op {
    /// Parse the name the editor sends.
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "eq" => Self::Eq,
            "ne" => Self::Ne,
            "gt" => Self::Gt,
            "ge" => Self::Ge,
            "lt" => Self::Lt,
            "le" => Self::Le,
            "contains" => Self::Contains,
            "starts_with" => Self::StartsWith,
            "is_null" => Self::IsNull,
            "not_null" => Self::NotNull,
            _ => return None,
        })
    }
}

/// One condition a row must meet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Filter {
    /// The column to test, or `None` to pass when any column does.
    pub column: Option<usize>,
    pub op: Op,
    pub value: String,
}

/// One key the rows are ordered by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sort {
    pub column: usize,
    pub descending: bool,
}

/// The rows that pass every filter, in sort order.
pub fn select(
    result: &ResultSet,
    filters: &[Filter],
    sort: &[Sort],
    scope: Option<&[usize]>,
) -> Vec<usize> {
    select_with(result, filters, sort, scope, None)
}

/// The rows that pass every filter and `query`'s condition, in `query`'s order when it has one and
/// otherwise in sort order.
pub fn select_with(
    result: &ResultSet,
    filters: &[Filter],
    sort: &[Sort],
    scope: Option<&[usize]>,
    query: Option<&Query>,
) -> Vec<usize> {
    let count = result.row_count();
    let mut rows: Vec<usize> = match scope {
        Some(scope) => scope.iter().copied().filter(|row| *row < count).collect(),
        None => (0..count).collect(),
    };

    rows.retain(|row| {
        filters.iter().all(|filter| passes(result, *row, filter))
            && query.is_none_or(|query| query.passes(result, *row))
    });

    if let Some(query) = query.filter(|query| query.orders()) {
        rows.sort_by(|a, b| query.compare(result, *a, *b));
    } else if !sort.is_empty() {
        rows.sort_by(|a, b| {
            sort.iter()
                .map(|key| {
                    let left = result.cell(*a, key.column).unwrap_or(&Cell::Null);
                    let right = result.cell(*b, key.column).unwrap_or(&Cell::Null);
                    order(left, right, key.descending)
                })
                .find(|ordering| ordering.is_ne())
                .unwrap_or(Ordering::Equal)
        });
    }
    rows
}

fn passes(result: &ResultSet, row: usize, filter: &Filter) -> bool {
    match filter.column {
        Some(column) => result
            .cell(row, column)
            .is_some_and(|cell| test(cell, filter.op, &filter.value)),
        None => (0..result.columns().len()).any(|column| {
            result
                .cell(row, column)
                .is_some_and(|cell| test(cell, filter.op, &filter.value))
        }),
    }
}

fn test(cell: &Cell, op: Op, value: &str) -> bool {
    match op {
        Op::IsNull => return cell.is_null(),
        Op::NotNull => return !cell.is_null(),
        _ if cell.is_null() => return false,
        _ => {}
    }

    let text = cell.display("");
    match op {
        // Case folded, because a search is for finding things rather than for proving they match.
        Op::Contains => return text.to_lowercase().contains(&value.to_lowercase()),
        Op::StartsWith => return text.to_lowercase().starts_with(&value.to_lowercase()),
        _ => {}
    }

    // A number compares as a number when the value reads as one.
    let ordering = match (number(cell), value.trim().parse::<f64>()) {
        (Some(left), Ok(right)) => left.partial_cmp(&right).unwrap_or(Ordering::Equal),
        _ => text.as_ref().cmp(value),
    };
    match op {
        Op::Eq => ordering.is_eq(),
        Op::Ne => ordering.is_ne(),
        Op::Gt => ordering.is_gt(),
        Op::Ge => ordering.is_ge(),
        Op::Lt => ordering.is_lt(),
        Op::Le => ordering.is_le(),
        _ => false,
    }
}

fn order(left: &Cell, right: &Cell, descending: bool) -> Ordering {
    let ordering = match (left.is_null(), right.is_null()) {
        (true, true) => return Ordering::Equal,
        (true, false) => return Ordering::Greater,
        (false, true) => return Ordering::Less,
        _ => match (number(left), number(right)) {
            (Some(a), Some(b)) => a.partial_cmp(&b).unwrap_or(Ordering::Equal),
            _ => left.display("").cmp(&right.display("")),
        },
    };
    if descending {
        ordering.reverse()
    } else {
        ordering
    }
}

fn number(cell: &Cell) -> Option<f64> {
    match cell {
        Cell::Int(value) => Some(*value as f64),
        Cell::Float(value) => Some(*value),
        Cell::Decimal(text) => text.parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::result::Column;

    use super::*;

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "select id, name, age from people",
            vec![
                Column::new("id", "INTEGER"),
                Column::new("name", "TEXT"),
                Column::new("age", "INTEGER"),
            ],
        );
        result.push_row(vec![
            Cell::Int(1),
            Cell::Text("Alice".into()),
            Cell::Int(30),
        ]);
        result.push_row(vec![Cell::Int(2), Cell::Text("bob".into()), Cell::Null]);
        result.push_row(vec![Cell::Int(3), Cell::Text("carol".into()), Cell::Int(9)]);
        result.push_row(vec![Cell::Int(4), Cell::Text("alan".into()), Cell::Int(30)]);
        result
    }

    fn filter(column: Option<usize>, op: Op, value: &str) -> Filter {
        Filter {
            column,
            op,
            value: value.into(),
        }
    }

    #[test]
    fn no_filter_and_no_sort_is_every_row_in_order() {
        assert_eq!(select(&people(), &[], &[], None), vec![0, 1, 2, 3]);
    }

    #[test]
    fn numbers_compare_as_numbers() {
        // As text, "9" would be greater than "30".
        let rows = select(&people(), &[filter(Some(2), Op::Lt, "10")], &[], None);
        assert_eq!(rows, vec![2]);
    }

    #[test]
    fn a_null_passes_only_the_null_tests() {
        let result = people();
        assert_eq!(
            select(&result, &[filter(Some(2), Op::IsNull, "")], &[], None),
            vec![1]
        );
        assert_eq!(
            select(&result, &[filter(Some(2), Op::Ne, "30")], &[], None),
            vec![2]
        );
    }

    #[test]
    fn contains_ignores_case() {
        let rows = select(&people(), &[filter(Some(1), Op::Contains, "AL")], &[], None);
        assert_eq!(rows, vec![0, 3]);
    }

    #[test]
    fn a_filter_without_a_column_searches_every_column() {
        let rows = select(&people(), &[filter(None, Op::Eq, "3")], &[], None);
        assert_eq!(rows, vec![2]);
    }

    #[test]
    fn filters_are_anded() {
        let rows = select(
            &people(),
            &[
                filter(Some(1), Op::StartsWith, "a"),
                filter(Some(2), Op::Eq, "30"),
            ],
            &[],
            None,
        );
        assert_eq!(rows, vec![0, 3]);
    }

    #[test]
    fn nulls_sort_last_either_way() {
        let result = people();
        let ascending = [Sort {
            column: 2,
            descending: false,
        }];
        let descending = [Sort {
            column: 2,
            descending: true,
        }];
        assert_eq!(select(&result, &[], &ascending, None), vec![2, 0, 3, 1]);
        assert_eq!(select(&result, &[], &descending, None), vec![0, 3, 2, 1]);
    }

    #[test]
    fn a_second_key_breaks_ties() {
        let sort = [
            Sort {
                column: 2,
                descending: true,
            },
            Sort {
                column: 1,
                descending: false,
            },
        ];
        // Alice and alan tie on age; "Alice" sorts before "alan" as text.
        assert_eq!(select(&people(), &[], &sort, None), vec![0, 3, 2, 1]);
    }

    #[test]
    fn scope_limits_the_rows_before_filtering() {
        let rows = select(
            &people(),
            &[filter(Some(2), Op::Eq, "30")],
            &[],
            Some(&[3, 1, 99]),
        );
        assert_eq!(rows, vec![3]);
    }

    #[test]
    fn op_names_parse() {
        assert_eq!(Op::parse("starts_with"), Some(Op::StartsWith));
        assert_eq!(Op::parse("like"), None);
    }
}
