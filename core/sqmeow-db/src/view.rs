//! Retained-result filtering and sorting. Polars owns the view; the result set remains the
//! source of truth for cells, editing, paging, and export.

mod polars;

pub use polars::{Query, condition, select_with};

use crate::result::Column;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Filter {
    pub column: Option<usize>,
    pub op: Op,
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sort {
    pub column: usize,
    pub descending: bool,
}

/// Distinguish duplicate result columns before registering the frame with Polars SQL.
pub fn names(columns: &[Column]) -> Vec<String> {
    let mut taken: Vec<String> = Vec::new();
    for column in columns {
        let mut candidate = column.name.clone();
        let mut count = 1;
        while taken
            .iter()
            .any(|known| known.eq_ignore_ascii_case(&candidate))
        {
            count += 1;
            candidate = format!("{}_{count}", column.name);
        }
        taken.push(candidate);
    }
    taken
}
