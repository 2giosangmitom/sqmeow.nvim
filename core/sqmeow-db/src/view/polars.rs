//! Polars is the only retained-result view engine. Original row positions travel through the
//! frame as an ordinary column; no Polars value is written back to the retained result.

use polars::prelude::{Column, DataFrame, DataType, Expr, IntoLazy, SortMultipleOptions, col, lit};
use polars_sql::SQLContext;
use sqlparser::ast::{SetExpr, Statement, Visit, Visitor};
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
        // Only WHERE and ORDER BY may differ from the fixed SELECT. Never allow
        // extra clauses or subqueries/table functions to read outside the retained data.
        let mut shape = query.clone();
        shape.order_by = None;
        let SetExpr::Select(shape_select) = shape.body.as_mut() else {
            unreachable!()
        };
        shape_select.selection = None;
        let baseline = Parser::parse_sql(&GenericDialect {}, &sql_text("", ""))
            .expect("the fixed view query is valid SQL");
        if Statement::Query(shape) != baseline[0]
            || (!condition.is_empty() && select.selection.is_none())
            || (!order.is_empty() && query.order_by.is_none())
            || parsed[0].visit(&mut NoSubqueries::default()).is_break()
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

/// The view accepts row expressions, not nested queries (including file-reading table functions).
#[derive(Default)]
struct NoSubqueries {
    queries: usize,
}

impl Visitor for NoSubqueries {
    type Break = ();

    fn pre_visit_query(&mut self, _query: &sqlparser::ast::Query) -> std::ops::ControlFlow<()> {
        self.queries += 1;
        if self.queries > 1 {
            std::ops::ControlFlow::Break(())
        } else {
            std::ops::ControlFlow::Continue(())
        }
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
        let dtype = column_type(result, index, &positions);
        if dtype == DataType::Boolean {
            let values: Vec<Option<bool>> = positions
                .iter()
                .map(|&row| match cells.get(row) {
                    Some(Cell::Bool(value)) => Some(*value),
                    _ => None,
                })
                .collect();
            data.push(Column::new(name.as_str().into(), values));
        } else if dtype == DataType::Int64 {
            let values: Vec<Option<i64>> = positions
                .iter()
                .map(|&row| match cells.get(row) {
                    Some(Cell::Int(value)) => Some(*value),
                    _ => None,
                })
                .collect();
            data.push(Column::new(name.as_str().into(), values));
        } else if dtype == DataType::Float64 {
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
                        .map(|cell| cell.text("").into_owned())
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
        let mut sql = sql_text(&query.where_clause, &query.order_by);
        if query.orders() {
            // Stable ties follow original row positions, independently of Polars' sort defaults.
            sql.push_str(&format!("\n, \"{row_name}\" ASC"));
        }
        frame = context
            .execute(&sql)
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

/// Choose one column type for both the frame and generated cell-match predicates.
fn column_type(result: &ResultSet, index: usize, positions: &[usize]) -> DataType {
    let cells = result.column_cells(index);
    let populated = positions
        .iter()
        .any(|&row| cells.get(row).is_some_and(|cell| !cell.is_null()));
    let class = result.columns()[index].class;
    if (populated || class == TypeClass::Boolean)
        && positions
            .iter()
            .all(|&row| matches!(cells.get(row), Some(Cell::Bool(_) | Cell::Null)))
    {
        DataType::Boolean
    } else if (populated || class == TypeClass::Number)
        && positions
            .iter()
            .all(|&row| matches!(cells.get(row), Some(Cell::Int(_) | Cell::Null)))
    {
        // Keep integer keys exact, including values outside f64's 53-bit integer range.
        DataType::Int64
    } else if (populated || class == TypeClass::Number)
        && (class == TypeClass::Number
            || positions
                .iter()
                .all(|&row| !matches!(cells.get(row), Some(Cell::Text(_)))))
        && positions.iter().all(|&row| {
            cells
                .get(row)
                .is_some_and(|cell| cell.is_null() || number(cell).is_some())
        })
    {
        // Only declared numeric text may be coerced; string identities remain exact.
        DataType::Float64
    } else {
        DataType::String
    }
}

/// Match a cell using Polars column names and types, not its source database's dialect.
pub fn condition(result: &ResultSet, row: usize, column: usize) -> Result<String, String> {
    let names = super::names(result.columns());
    let name = names.get(column).ok_or("no such column")?;
    let cell = result.cell(row, column).ok_or("no such row")?;
    let positions: Vec<usize> = (0..result.row_count()).collect();
    let value = if cell.is_null() {
        Cell::Null
    } else {
        match column_type(result, column, &positions) {
            DataType::Float64 => {
                let value = number(cell).expect("a numeric column has numeric cells");
                if value.is_finite() {
                    // Polars identifies float literals by the decimal point, not the exponent.
                    let mut literal = format!("{value:e}");
                    if !literal.contains('.') {
                        let exponent = literal
                            .find('e')
                            .expect("scientific notation has an exponent");
                        literal.insert_str(exponent, ".0");
                    }
                    return Ok(format!("\"{}\" = {literal}", name.replace('"', "\"\"")));
                }
                Cell::Float(value)
            }
            DataType::String => Cell::Text(cell.text("").into_owned()),
            _ => cell.clone(),
        }
    };
    crate::edit::condition(crate::adapter::Dialect::Postgres, name, &value)
        .map_err(|error| error.to_string())
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
            let right = if dtype == Some(&DataType::Boolean) {
                filter
                    .value
                    .trim()
                    .parse::<bool>()
                    .map_or_else(|_| lit(filter.value.clone()), lit)
            } else if dtype == Some(&DataType::Int64) {
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
    fn a_view_accepts_only_row_predicates_and_sort_expressions() {
        let result = people();
        let names = super::super::names(result.columns());
        for (condition, order) in [
            ("true; DELETE FROM sqmeow_view", ""),
            ("true GROUP BY id", ""),
            ("true HAVING id > 1", ""),
            ("true UNION SELECT * FROM sqmeow_view", ""),
            ("id IN (SELECT id FROM sqmeow_view)", ""),
            ("id IN (SELECT id FROM read_csv('/must/not/read.csv'))", ""),
            ("", "id LIMIT 1"),
            ("", "id OFFSET 1"),
            ("", "id; DROP TABLE sqmeow_view"),
        ] {
            assert!(
                Query::parse(condition, order, &names).is_err(),
                "{condition} / {order}"
            );
        }
    }

    #[test]
    fn sql_sort_is_stable_and_supports_explicit_null_placement() {
        let result = people();
        let names = super::super::names(result.columns());
        let query = Query::parse("", "age DESC NULLS LAST", &names).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![0, 3, 4, 2, 1]
        );
        let query =
            Query::parse("name ILIKE '%AL%'", "age ASC -- ties stay stable", &names).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![0, 3, 4]
        );
    }

    #[test]
    fn booleans_and_raw_text_have_matching_sql_and_structured_predicates() {
        let mut result = ResultSet::new(
            "typed",
            vec![
                ResultColumn::new("active", "BOOLEAN"),
                ResultColumn::new("note", "TEXT"),
            ],
        );
        result.push_row(vec![Cell::Bool(true), Cell::Text("o'alice\nnext".into())]);
        result.push_row(vec![Cell::Bool(false), Cell::Text("other".into())]);
        result.push_row(vec![Cell::Null, Cell::Null]);
        let names = super::super::names(result.columns());
        let query = Query::parse("active = TRUE", "", &names).unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![0]
        );
        let filter = Filter {
            column: Some(0),
            op: Op::Eq,
            value: "false".into(),
        };
        assert_eq!(
            select_with(&result, &[filter], &[], None, None).unwrap(),
            vec![1]
        );
        for column in 0..2 {
            let condition = condition(&result, 0, column).unwrap();
            let query = Query::parse(&condition, "", &names).unwrap();
            assert_eq!(
                select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
                vec![0]
            );
        }
    }

    #[test]
    fn generated_conditions_use_duplicate_names_and_preserve_decimal_text() {
        let mut result = ResultSet::new(
            "typed",
            vec![
                ResultColumn::new("amount", "NUMERIC"),
                ResultColumn::new("amount", "NUMERIC"),
            ],
        );
        result.push_row(vec![
            Cell::Decimal("9007199254740993.01".into()),
            Cell::Decimal("1.25".into()),
        ]);
        result.push_row(vec![
            Cell::Decimal("9007199254740993.02".into()),
            Cell::Decimal("2.25".into()),
        ]);
        let names = super::super::names(result.columns());
        for column in 0..2 {
            let condition = condition(&result, 0, column).unwrap();
            let query = Query::parse(&condition, "", &names).unwrap();
            assert_eq!(
                select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
                vec![0]
            );
        }
        assert_eq!(condition(&result, 0, 1).unwrap(), "\"amount_2\" = '1.25'");
    }

    #[test]
    fn numeric_text_values_can_be_filtered_as_polars_numbers() {
        let mut result = ResultSet::new("redis", vec![ResultColumn::new("value", "TEXT")]);
        for value in ["1", "10", "5"] {
            result.push_row(vec![Cell::Text(value.into())]);
        }
        let names = super::super::names(result.columns());
        let query = Query::parse(
            "CAST(value AS DOUBLE) >= 5",
            "CAST(value AS DOUBLE) DESC",
            &names,
        )
        .unwrap();
        assert_eq!(
            select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
            vec![1, 2]
        );
    }

    #[test]
    fn numeric_looking_strings_keep_their_identity() {
        for type_name in ["TEXT", "VARCHAR", "unknown"] {
            let mut result = ResultSet::new("codes", vec![ResultColumn::new("code", type_name)]);
            for value in ["001", "1", "9007199254740992", "9007199254740993"] {
                result.push_row(vec![Cell::Text(value.into())]);
            }
            let names = super::super::names(result.columns());
            for row in 0..result.row_count() {
                let condition = condition(&result, row, 0).unwrap();
                let query = Query::parse(&condition, "", &names).unwrap();
                assert_eq!(
                    select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
                    vec![row]
                );
            }
            let query = Query::parse("code = '001'", "", &names).unwrap();
            assert_eq!(
                select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
                vec![0]
            );
            let filter = Filter {
                column: Some(0),
                op: Op::Eq,
                value: "001".into(),
            };
            assert_eq!(
                select_with(&result, &[filter], &[], None, None).unwrap(),
                vec![0]
            );
        }
    }

    #[test]
    fn finite_float_cell_conditions_use_float_literals() {
        let mut result = ResultSet::new("floats", vec![ResultColumn::new("n", "DOUBLE")]);
        for value in [1e20, 2e20, -1e20, 1e-20, f64::MAX] {
            result.push_row(vec![Cell::Float(value)]);
        }
        let names = super::super::names(result.columns());
        for row in 0..result.row_count() {
            let condition = condition(&result, row, 0).unwrap();
            let query = Query::parse(&condition, "", &names).unwrap();
            assert_eq!(
                select_with(&result, &[], &[], None, query.as_ref()).unwrap(),
                vec![row]
            );
        }
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
