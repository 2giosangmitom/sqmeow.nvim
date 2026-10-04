//! Polars is the only retained-result view engine. Original row positions travel through the
//! frame as an ordinary column; no Polars value is written back to the retained result.

use polars::prelude::{Column, DataFrame, DataType, Expr, IntoLazy, SortMultipleOptions, col, lit};
use polars::sql::SQLContext;
use sqlparser::ast::{SetExpr, Statement};
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

use super::{Filter, Op, Sort};
use crate::result::ResultSet;
use crate::types::TypeClass;
use crate::value::Cell;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    where_clause: String,
    order_by: String,
}

impl Query {
    pub fn parse(condition: &str, order: &str, _names: &[String]) -> Result<Option<Self>, String> {
        let condition = condition.trim();
        let order = order.trim();
        if condition.is_empty() && order.is_empty() {
            return Ok(None);
        }
        let statement = sql_text(condition, order);
        let parsed =
            Parser::parse_sql(&GenericDialect {}, &statement).map_err(|error| error.to_string())?;
        let [Statement::Query(query)] = parsed.as_slice() else {
            return Err("a filter takes one condition and one order".into());
        };
        let SetExpr::Select(select) = query.body.as_ref() else {
            return Err("a filter takes one condition and one order".into());
        };
        if query.limit_clause.is_some()
            || select.from.len() != 1
            || !select.from[0].joins.is_empty()
        {
            return Err("a filter takes one condition and one order".into());
        }
        Ok(Some(Self {
            where_clause: condition.into(),
            order_by: order.into(),
        }))
    }

    fn orders(&self) -> bool {
        !self.order_by.is_empty()
    }
}

fn sql_text(condition: &str, order: &str) -> String {
    // Separate clauses so a trailing line comment cannot swallow ORDER BY.
    let mut sql = "SELECT * FROM sqmeow_view".to_owned();
    if !condition.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(condition);
    }
    if !order.is_empty() {
        sql.push_str("\nORDER BY ");
        sql.push_str(order);
    }
    sql
}

/// Select the original retained-row positions; every filter/sort is evaluated by Polars.
pub fn select_with(
    result: &ResultSet,
    filters: &[Filter],
    sort: &[Sort],
    scope: Option<&[usize]>,
    query: Option<&Query>,
) -> Result<Vec<usize>, String> {
    let positions: Vec<usize> = scope.map_or_else(
        || (0..result.row_count()).collect(),
        |rows| {
            rows.iter()
                .copied()
                .filter(|row| *row < result.row_count())
                .collect()
        },
    );
    let names = super::names(result.columns());
    let row_name = (0..)
        .map(|number| format!("__sqmeow_row_{number}"))
        .find(|name| !names.iter().any(|column| column.eq_ignore_ascii_case(name)))
        .expect("there is always a free internal column name");
    let mut data = Vec::with_capacity(names.len() + 1);
    for (index, name) in names.iter().enumerate() {
        let cells = result.column_cells(index);
        let kind = positions
            .iter()
            .filter_map(|&row| cells.get(row))
            .find(|cell| !cell.is_null());
        // Keep integer keys exact, including values outside f64's 53-bit integer range.
        let integers = (kind.is_some() || result.columns()[index].class == TypeClass::Number)
            && positions
                .iter()
                .all(|&row| matches!(cells.get(row), Some(Cell::Int(_) | Cell::Null)));
        // Redis and similar backends return numbers as text. If an entire column is
        // numeric, let Polars compare and sort it numerically too.
        let numeric = (kind.is_some() || result.columns()[index].class == TypeClass::Number)
            && positions.iter().all(|&row| {
                cells
                    .get(row)
                    .is_some_and(|cell| cell.is_null() || number(cell).is_some())
            });
        if integers {
            let values: Vec<Option<i64>> = positions
                .iter()
                .map(|&row| match cells.get(row) {
                    Some(Cell::Int(value)) => Some(*value),
                    _ => None,
                })
                .collect();
            data.push(Column::new(name.as_str().into(), values));
        } else if numeric {
            let values: Vec<Option<f64>> = positions
                .iter()
                .map(|&row| cells.get(row).and_then(number))
                .collect();
            data.push(Column::new(name.as_str().into(), values));
        } else {
            let values: Vec<Option<String>> = positions
                .iter()
                .map(|&row| {
                    cells
                        .get(row)
                        .filter(|cell| !cell.is_null())
                        .map(|cell| cell.display("").into_owned())
                })
                .collect();
            data.push(Column::new(name.as_str().into(), values));
        }
    }
    data.push(Column::new(
        row_name.as_str().into(),
        positions.iter().map(|&row| row as u64).collect::<Vec<_>>(),
    ));
    let frame = DataFrame::new(positions.len(), data).map_err(|error| error.to_string())?;
    let schema = frame.schema().clone();
    let mut lazy = frame.lazy();
    for filter in filters {
        let expr = match filter.column {
            Some(index) => names.get(index).map_or_else(
                || lit(false),
                |name| predicate(col(name), schema.get(name.as_str()), filter),
            ),
            None => names
                .iter()
                .map(|name| predicate(col(name), schema.get(name.as_str()), filter))
                .reduce(|left, right| left.or(right))
                .unwrap_or_else(|| lit(false)),
        };
        lazy = lazy.filter(expr);
    }
    let mut frame = lazy.collect().map_err(|error| error.to_string())?;
    if let Some(query) = query {
        let mut context = SQLContext::new();
        context.register("sqmeow_view", frame.lazy());
        frame = context
            .execute(&sql_text(&query.where_clause, &query.order_by))
            .and_then(|lazy| lazy.collect())
            .map_err(|error| error.to_string())?;
    }
    if !query.is_some_and(Query::orders) && !sort.is_empty() {
        let keys: Vec<&str> = sort
            .iter()
            .filter_map(|key| names.get(key.column).map(String::as_str))
            .collect();
        if !keys.is_empty() {
            let descending = sort
                .iter()
                .filter(|key| key.column < names.len())
                .map(|key| key.descending);
            frame = frame
                .sort(
                    keys,
                    SortMultipleOptions::new()
                        .with_order_descending_multi(descending)
                        .with_nulls_last(true)
                        .with_maintain_order(true),
                )
                .map_err(|error| error.to_string())?;
        }
    }
    Ok(frame
        .column(&row_name)
        .map_err(|error| error.to_string())?
        .u64()
        .map_err(|error| error.to_string())?
        .into_no_null_iter()
        .map(|index| index as usize)
        .collect())
}

fn number(cell: &Cell) -> Option<f64> {
    match cell {
        Cell::Int(value) => Some(*value as f64),
        Cell::Float(value) => Some(*value),
        // Keep exact decimals as text rather than silently rounding them to f64.
        Cell::Text(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn predicate(column: Expr, dtype: Option<&DataType>, filter: &Filter) -> Expr {
    match filter.op {
        Op::IsNull => column.is_null(),
        Op::NotNull => column.is_not_null(),
        Op::Contains | Op::StartsWith => {
            let lower = column.cast(DataType::String).str().to_lowercase();
            let value = lit(filter.value.to_lowercase());
            if filter.op == Op::Contains {
                lower.str().contains_literal(value)
            } else {
                lower.str().starts_with(value)
            }
        }
        op => {
            let right = if dtype == Some(&DataType::Int64) {
                filter.value.trim().parse::<i64>().map_or_else(
                    |_| {
                        filter
                            .value
                            .trim()
                            .parse::<f64>()
                            .map_or_else(|_| lit(filter.value.clone()), lit)
                    },
                    lit,
                )
            } else if dtype == Some(&DataType::Float64) {
                filter
                    .value
                    .trim()
                    .parse::<f64>()
                    .map_or_else(|_| lit(filter.value.clone()), lit)
            } else {
                lit(filter.value.clone())
            };
            match op {
                Op::Eq => column.eq(right),
                Op::Ne => column.neq(right),
                Op::Gt => column.gt(right),
                Op::Ge => column.gt_eq(right),
                Op::Lt => column.lt(right),
                Op::Le => column.lt_eq(right),
                _ => unreachable!(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::result::Column as ResultColumn;

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "people",
            vec![
                ResultColumn::new("id", "INTEGER"),
                ResultColumn::new("name", "TEXT"),
                ResultColumn::new("age", "INTEGER"),
            ],
        );
        for (id, name, age) in [
            (1, "Alice", Some(30)),
            (2, "bob", None),
            (3, "carol", Some(9)),
            (4, "alan", Some(30)),
            (5, "alan", Some(30)),
        ] {
            result.push_row(vec![
                Cell::Int(id),
                Cell::Text(name.into()),
                age.map_or(Cell::Null, Cell::Int),
            ]);
        }
        result
    }

    #[test]
    fn structured_filters_sort_stably_and_keep_original_positions() {
        let result = people();
        let filter = Filter {
            column: Some(1),
            op: Op::Contains,
            value: "AL".into(),
        };
        let order = [Sort {
            column: 2,
            descending: true,
        }];
        assert_eq!(
            select_with(&result, &[filter], &order, None, None).unwrap(),
            vec![0, 3, 4]
        );
        assert_eq!(
            select_with(&result, &[], &order, None, None).unwrap(),
            vec![0, 3, 4, 2, 1]
        );
        assert_eq!(
            select_with(&result, &[], &[], Some(&[4, 1, 4, 99]), None).unwrap(),
            vec![4, 1, 4]
        );
    }

    #[test]
    fn sql_uses_polars_and_preserves_row_indices() {
        let result = people();
        let names = super::super::names(result.columns());
        let query = Query::parse("age > 20 OR age IS NULL", "id DESC", &names).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![4, 3, 1, 0]
        );
        let query = Query::parse("id > 1", "id DESC", &names).unwrap();
        let filters = [Filter {
            column: Some(1),
            op: Op::StartsWith,
            value: "a".into(),
        }];
        assert_eq!(
            select_with(&result, &filters, &[], None, query.as_ref()).unwrap(),
            vec![4, 3]
        );
    }

    #[test]
    fn invalid_sql_does_not_change_the_retained_result() {
        let result = people();
        let names = super::super::names(result.columns());
        assert!(Query::parse("id >", "", &names).is_err());
        assert!(Query::parse("id > 1 LIMIT 1", "", &names).is_err());
        let query = Query::parse("missing = 1", "", &names).unwrap();
        assert!(select_with(&result, &[], &[], None, query.as_ref()).is_err());
        assert_eq!(result.row_count(), 5);
    }

    #[test]
    fn numeric_text_values_can_be_filtered_as_polars_numbers() {
        let mut result = ResultSet::new("redis", vec![ResultColumn::new("value", "TEXT")]);
        for value in ["1", "10", "5"] {
            result.push_row(vec![Cell::Text(value.into())]);
        }
        let names = super::super::names(result.columns());
        let query = Query::parse("value >= 5", "value DESC", &names).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![1, 2]
        );
    }

    #[test]
    fn large_integer_ids_do_not_round_into_each_other() {
        let mut result = ResultSet::new("ids", vec![ResultColumn::new("id", "BIGINT")]);
        for value in [9_007_199_254_740_992, 9_007_199_254_740_993] {
            result.push_row(vec![Cell::Int(value)]);
        }
        let filter = [Filter {
            column: Some(0),
            op: Op::Eq,
            value: "9007199254740993".into(),
        }];
        assert_eq!(
            select_with(&result, &filter, &[], None, None).unwrap(),
            vec![1]
        );
        let query = Query::parse(
            "id = 9007199254740993",
            "",
            &super::super::names(result.columns()),
        )
        .unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![1]
        );
    }

    #[test]
    fn an_empty_numeric_result_still_accepts_a_numeric_condition() {
        let result = ResultSet::new("empty", vec![ResultColumn::new("id", "INTEGER")]);
        let query = Query::parse("id > 1", "", &super::super::names(result.columns())).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            Vec::<usize>::new()
        );
    }

    #[test]
    fn duplicate_columns_and_export_use_the_original_cells() {
        use crate::export::{self, Format, Rows};
        let mut result = ResultSet::new(
            "saved",
            vec![
                ResultColumn::new("value", "TEXT"),
                ResultColumn::new("value", "TEXT"),
            ],
        );
        result.push_row(vec![
            Cell::Text("first".into()),
            Cell::Json("{\"n\":1}".into()),
        ]);
        result.push_row(vec![
            Cell::Text("second".into()),
            Cell::Json("{\"n\":2}".into()),
        ]);
        let names = super::super::names(result.columns());
        assert_eq!(names, ["value", "value_2"]);
        let query = Query::parse("value_2 = '{\"n\":2}'", "", &names).unwrap();
        let view = select_with(&result, &[], &[], None, query.as_ref()).unwrap();
        assert_eq!(view, vec![1]);
        let rows = Rows::all().resolve(&result, Some(&view));
        assert_eq!(
            export::write(&result, &Format::Csv, &rows, None, true),
            "value,value\nsecond,\"{\"\"n\"\":2}\"\n"
        );
    }

    #[test]
    fn null_and_literal_text_filters_keep_row_positions() {
        let result = people();
        let nulls = [Filter {
            column: Some(2),
            op: Op::IsNull,
            value: String::new(),
        }];
        assert_eq!(
            select_with(&result, &nulls, &[], None, None).unwrap(),
            vec![1]
        );
        let prefix = [Filter {
            column: Some(1),
            op: Op::StartsWith,
            value: "AL".into(),
        }];
        assert_eq!(
            select_with(&result, &prefix, &[], None, None).unwrap(),
            vec![0, 3, 4]
        );
        let query = Query::parse(
            "name LIKE 'a%'",
            "id DESC",
            &super::super::names(result.columns()),
        )
        .unwrap();
        assert_eq!(
            select_with(&result, &[], &[], Some(&[0, 3, 4]), query.as_ref()).unwrap(),
            vec![4, 3]
        );
    }
}
