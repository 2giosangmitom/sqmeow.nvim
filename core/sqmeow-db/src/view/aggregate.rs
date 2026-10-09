//! Snapshot-only aggregation. SQL syntax describes a small, validated set of
//! built-in Polars expressions; it never executes source-database SQL.

use polars::prelude::*;
use sqlparser::ast::{
    Expr as SqlExpr, FunctionArg, FunctionArgExpr, FunctionArguments, SelectItem, SetExpr,
    Statement,
};
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

use super::{Filter, Query, Sort};
use crate::result::ResultSet;

#[derive(Debug, Clone)]
pub struct Group {
    keys: Vec<usize>,
    aggregates: Vec<Aggregate>,
}

#[derive(Debug, Clone)]
struct Aggregate {
    op: String,
    column: Option<usize>,
    alias: String,
}

fn projection(text: &str) -> Result<Vec<SelectItem>, String> {
    let parsed = Parser::parse_sql(
        &GenericDialect {},
        &format!("SELECT {text} FROM sqmeow_view"),
    )
    .map_err(|error| error.to_string())?;
    let [Statement::Query(query)] = parsed.as_slice() else {
        return Err("expected one column/expression list".into());
    };
    let SetExpr::Select(select) = query.body.as_ref() else {
        return Err("expected a column/expression list".into());
    };
    let mut shape = query.clone();
    let SetExpr::Select(shape_select) = shape.body.as_mut() else {
        unreachable!()
    };
    let baseline = Parser::parse_sql(&GenericDialect {}, "SELECT * FROM sqmeow_view").unwrap();
    let Statement::Query(base) = &baseline[0] else {
        unreachable!()
    };
    let SetExpr::Select(base_select) = base.body.as_ref() else {
        unreachable!()
    };
    shape_select.projection = base_select.projection.clone();
    if shape != *base {
        return Err("only a column/expression list is allowed".into());
    }
    Ok(select.projection.clone())
}

fn column(expr: &SqlExpr, names: &[String]) -> Result<usize, String> {
    let SqlExpr::Identifier(name) = expr else {
        return Err("use a column name, not an expression".into());
    };
    names
        .iter()
        .position(|candidate| {
            if name.quote_style.is_some() {
                candidate == &name.value
            } else {
                candidate.eq_ignore_ascii_case(&name.value)
            }
        })
        .ok_or_else(|| format!("unknown column `{}`", name.value))
}

impl Group {
    /// GROUP BY is a column list; AGGREGATE accepts COUNT(*), COUNT(column),
    /// SUM, AVG, MIN, MAX, each with an explicit AS output name.
    pub fn parse(keys: &str, aggregates: &str, names: &[String]) -> Result<Option<Self>, String> {
        if keys.trim().is_empty() && aggregates.trim().is_empty() {
            return Ok(None);
        }
        if aggregates.trim().is_empty() {
            return Err("AGGREGATE needs at least one expression, e.g. COUNT(*) AS rows".into());
        }
        let keys = if keys.trim().is_empty() {
            Vec::new()
        } else {
            projection(keys)?
                .iter()
                .map(|item| match item {
                    SelectItem::UnnamedExpr(expr) => column(expr, names),
                    _ => Err("GROUP BY accepts column names only".into()),
                })
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut outputs: Vec<String> = keys.iter().map(|&index| names[index].clone()).collect();
        if outputs
            .iter()
            .enumerate()
            .any(|(index, name)| outputs[..index].contains(name))
        {
            return Err("a GROUP BY column was supplied twice".into());
        }
        let mut built = Vec::new();
        for item in projection(aggregates)? {
            let SelectItem::ExprWithAlias {
                expr: SqlExpr::Function(function),
                alias,
            } = item
            else {
                return Err("use an aggregate with AS, e.g. SUM(amount) AS total".into());
            };
            let op = function.name.to_string().to_ascii_lowercase();
            if !matches!(op.as_str(), "count" | "sum" | "avg" | "min" | "max")
                || function.uses_odbc_syntax
                || function.parameters != FunctionArguments::None
                || !function.within_group.is_empty()
                || function.filter.is_some()
                || function.null_treatment.is_some()
                || function.over.is_some()
            {
                return Err("supported aggregates: COUNT, SUM, AVG, MIN, MAX".into());
            }
            let FunctionArguments::List(args) = function.args else {
                return Err("aggregate needs one argument".into());
            };
            if args.duplicate_treatment.is_some() || !args.clauses.is_empty() {
                return Err("DISTINCT and aggregate clauses are not supported".into());
            }
            let column = match args.args.as_slice() {
                [FunctionArg::Unnamed(FunctionArgExpr::Wildcard)] if op == "count" => None,
                [FunctionArg::Unnamed(FunctionArgExpr::Expr(expr))] => Some(column(expr, names)?),
                _ => return Err("aggregate needs one column, or COUNT(*)".into()),
            };
            if alias.value.is_empty()
                || outputs
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(&alias.value))
            {
                return Err(format!("duplicate/empty output name `{}`", alias.value));
            }
            outputs.push(alias.value.clone());
            built.push(Aggregate {
                op,
                column,
                alias: alias.value,
            });
        }
        Ok(Some(Self {
            keys,
            aggregates: built,
        }))
    }
}

pub fn aggregate(
    result: &ResultSet,
    group: &Group,
    filters: &[Filter],
    scope: Option<&[usize]>,
    before: Option<&Query>,
    post: (&str, &str, &[Sort]),
) -> Result<ResultSet, String> {
    let (having, order, sort) = post;
    let names = super::names(result.columns());
    let mut needed = group.keys.clone();
    needed.extend(
        group
            .aggregates
            .iter()
            .filter_map(|aggregate| aggregate.column),
    );
    needed.sort_unstable();
    needed.dedup();
    for &index in &needed {
        let source = result.column_values(index).expect("validated column");
        if !matches!(
            source.dtype(),
            DataType::Boolean
                | DataType::Int64
                | DataType::Float64
                | DataType::String
                | DataType::Null
        ) {
            return Err(format!(
                "column `{}` needs a native Polars dtype; mixed/special values cannot be aggregated",
                names[index]
            ));
        }
        if group.keys.contains(&index) && source.dtype() == &DataType::Float64 {
            return Err("floating-point GROUP BY keys are not supported; use Bool/Int/Text".into());
        }
    }
    let (lazy, native_names) = if filters.is_empty() && scope.is_none() && before.is_none() {
        // No row selection is needed. Project shared native columns straight
        // into Polars, without an O(rows) row-id buffer or typed view cache.
        let columns = needed
            .iter()
            .map(|&index| {
                result
                    .column_values(index)
                    .expect("validated native column")
                    .clone()
                    .with_name(names[index].as_str().into())
            })
            .collect();
        let frame =
            DataFrame::new(result.row_count(), columns).map_err(|error| error.to_string())?;
        (
            frame.lazy(),
            needed
                .iter()
                .map(|&index| names[index].clone())
                .collect::<Vec<_>>(),
        )
    } else {
        let (lazy, _, native_names) =
            super::polars::plan_with(result, filters, &[], scope, before, &needed)?;
        (lazy, native_names)
    };
    let native = |index: usize| {
        col(&native_names[needed
            .binary_search(&index)
            .expect("required native column")])
    };
    let mut expressions = Vec::new();
    for aggregate in &group.aggregates {
        let expression = if let Some(index) = aggregate.column {
            let name = &names[index];
            let dtype = result.column_values(index).unwrap().dtype();
            if matches!(aggregate.op.as_str(), "sum" | "avg")
                && !matches!(dtype, DataType::Int64 | DataType::Float64 | DataType::Null)
            {
                return Err(format!(
                    "{} requires a numeric native column: `{name}`",
                    aggregate.op
                ));
            }
            if matches!(aggregate.op.as_str(), "min" | "max") && dtype == &DataType::Boolean {
                return Err("MIN/MAX accept numeric or text columns".into());
            }
            let value = native(index);
            match aggregate.op.as_str() {
                "count" => value.count().cast(DataType::Int64),
                "sum" => {
                    // Built-in wide sum, then checked narrowing: never wrap i64.
                    let sum = if dtype == &DataType::Int64 {
                        value
                            .clone()
                            .cast(DataType::Int128)
                            .sum()
                            .strict_cast(DataType::Int64)
                    } else {
                        value.clone().cast(DataType::Float64).sum()
                    };
                    when(value.count().gt(lit(0u32)))
                        .then(sum)
                        .otherwise(lit(NULL))
                }
                "avg" => value.cast(DataType::Float64).mean(),
                "min" => value.min(),
                "max" => value.max(),
                _ => unreachable!(),
            }
        } else {
            len().cast(DataType::Int64)
        };
        expressions.push(expression.alias(&aggregate.alias));
    }
    let output_names: Vec<String> = group
        .keys
        .iter()
        .map(|&index| names[index].clone())
        .chain(
            group
                .aggregates
                .iter()
                .map(|aggregate| aggregate.alias.clone()),
        )
        .collect();
    // Validate non-finite inputs inside the same lazy aggregation, including
    // COUNT(float). Filtered-out NaN/infinity never enters a group.
    let mut diagnostics: Vec<(String, usize)> = Vec::new();
    for &index in &needed {
        if result.column_values(index).unwrap().dtype() == &DataType::Float64 {
            let name = (0..)
                .map(|number| format!("__sqmeow_nonfinite_{number}"))
                .find(|name| {
                    !output_names
                        .iter()
                        .any(|output| output.eq_ignore_ascii_case(name))
                        && !diagnostics
                            .iter()
                            .any(|(output, _)| output.eq_ignore_ascii_case(name))
                })
                .expect("there is always a free diagnostic name");
            let value = native(index);
            expressions.push(
                value
                    .clone()
                    .is_not_null()
                    .and(value.is_finite().not())
                    .cast(DataType::Int64)
                    .sum()
                    .alias(&name),
            );
            diagnostics.push((name, index));
        }
    }
    let mut computed = if group.keys.is_empty() {
        lazy.select(expressions)
    } else {
        lazy.group_by_stable(
            group
                .keys
                .iter()
                .map(|&index| native(index).alias(&names[index]))
                .collect::<Vec<_>>(),
        )
        .agg(expressions)
    }
    .collect()
    .map_err(|error| format!("aggregation failed (integer sums must fit i64): {error}"))?;
    for (name, index) in diagnostics {
        if computed
            .column(&name)
            .map_err(|error| error.to_string())?
            .i64()
            .map_err(|error| error.to_string())?
            .max()
            .unwrap_or(0)
            > 0
        {
            return Err(format!("column `{}` contains NaN/infinity", names[index]));
        }
    }
    computed = computed
        .select(output_names.iter().map(String::as_str))
        .map_err(|error| error.to_string())?;
    // Keep the retained model's supported dtypes, including all-NULL outputs.
    let normalized = computed
        .columns()
        .iter()
        .map(|column| {
            if column.dtype() == &DataType::Null {
                column.cast(&DataType::String)
            } else {
                Ok(column.clone())
            }
        })
        .collect::<PolarsResult<Vec<_>>>()
        .map_err(|error| error.to_string())?;
    computed = DataFrame::new(computed.height(), normalized).map_err(|error| error.to_string())?;
    for column in computed.columns() {
        if column.dtype() == &DataType::Float64
            && column
                .f64()
                .unwrap()
                .iter()
                .flatten()
                .any(|value| !value.is_finite())
        {
            return Err(format!(
                "aggregate `{}` produced NaN/infinity",
                column.name()
            ));
        }
    }
    let derived = ResultSet::from_frame(result.statement(), computed, result.is_truncated());
    let post = Query::parse(having, order, &super::names(derived.columns()))?;
    if post.is_some() || !sort.is_empty() {
        // Keep typed filter projections separate from raw output columns: a
        // numeric-looking text MIN/MAX must not become a floating-point value.
        // Collect the selected/sorted columns directly, not row ids followed
        // by a second gather of the entire aggregate frame.
        let columns: Vec<usize> = (0..derived.columns().len()).collect();
        let (lazy, _, native_names) =
            super::polars::plan_with(&derived, &[], sort, None, post.as_ref(), &columns)?;
        let computed = lazy
            .select(
                native_names
                    .iter()
                    .zip(&output_names)
                    .map(|(native, output)| col(native).alias(output))
                    .collect::<Vec<_>>(),
            )
            .collect()
            .map_err(|error| error.to_string())?;
        return Ok(ResultSet::from_frame(
            result.statement(),
            computed,
            result.is_truncated(),
        ));
    }
    Ok(derived)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::result::Column;
    use crate::value::Cell;

    fn sample() -> ResultSet {
        let mut result = ResultSet::new(
            "snapshot",
            vec![
                Column::new("country", "TEXT"),
                Column::new("amount", "BIGINT"),
            ],
        );
        for (country, amount) in [
            (Some("a"), Some(2)),
            (Some("b"), Some(5)),
            (Some("a"), Some(3)),
            (None, None),
            (None, None),
        ] {
            result.push_row(vec![
                country.map_or(Cell::Null, |value| Cell::Text(value.into())),
                amount.map_or(Cell::Null, Cell::Int),
            ]);
        }
        result
    }

    fn run(
        result: &ResultSet,
        keys: &str,
        expressions: &str,
        having: &str,
        order: &str,
    ) -> Result<ResultSet, String> {
        let group =
            Group::parse(keys, expressions, &super::super::names(result.columns()))?.unwrap();
        aggregate(result, &group, &[], None, None, (having, order, &[]))
    }

    #[test]
    fn groups_native_values_and_nulls_without_editable_provenance() {
        let result = sample();
        let grouped = run(&result, "country", "COUNT(*) AS rows, COUNT(amount) AS populated, SUM(amount) AS total, AVG(amount) AS average, MIN(amount) AS low, MAX(amount) AS high", "", "").unwrap();
        assert_eq!(grouped.row_count(), 3);
        assert_eq!(grouped.cell(0, 3).as_deref(), Some(&Cell::Int(5)));
        assert_eq!(grouped.cell(0, 4).as_deref(), Some(&Cell::Float(2.5)));
        assert_eq!(grouped.cell(2, 1).as_deref(), Some(&Cell::Int(2)));
        assert_eq!(grouped.cell(2, 2).as_deref(), Some(&Cell::Int(0)));
        assert_eq!(grouped.cell(2, 3).as_deref(), Some(&Cell::Null));
        assert!(grouped.source().is_none());
        assert_eq!(result.row_count(), 5);
        assert_eq!(grouped.frame().columns()[3].dtype(), &DataType::Int64);
    }

    #[test]
    fn filters_before_grouping_and_having_after_grouping() {
        let result = sample();
        let group = Group::parse(
            "country",
            "SUM(amount) AS total",
            &super::super::names(result.columns()),
        )
        .unwrap()
        .unwrap();
        let before = Query::parse("amount >= 3", "", &[]).unwrap();
        let grouped = aggregate(
            &result,
            &group,
            &[],
            None,
            before.as_ref(),
            ("total >= 5", "total DESC", &[]),
        )
        .unwrap();
        assert_eq!(grouped.row_count(), 1);
        assert_eq!(grouped.cell(0, 0).as_deref(), Some(&Cell::Text("b".into())));
    }

    #[test]
    fn integer_sums_are_wide_and_checked_not_wrapped() {
        let mut result = ResultSet::new("exact", vec![Column::new("v", "BIGINT")]);
        result.push_row(vec![Cell::Int(i64::MAX)]);
        result.push_row(vec![Cell::Int(1)]);
        assert!(run(&result, "", "SUM(v) AS total", "", "").is_err());
        result.push_row(vec![Cell::Int(-1)]);
        assert_eq!(
            run(&result, "", "SUM(v) AS total", "", "")
                .unwrap()
                .cell(0, 0)
                .as_deref(),
            Some(&Cell::Int(i64::MAX))
        );
    }

    #[test]
    fn rejects_unsafe_syntax_and_unsupported_dtypes() {
        let names = vec!["v".into()];
        for (keys, expressions) in [
            ("v; SELECT 1", "COUNT(*) AS n"),
            ("v", "COUNT(*) AS v"),
            ("", "COUNT(DISTINCT v) AS n"),
            ("", "read_csv('x') AS n"),
            ("", "SUM(v + 1) AS n"),
            ("v, v", "COUNT(*) AS n"),
            ("", "SUM(v) OVER () AS n"),
            ("", "COUNT(*) AS n FROM read_csv('x') --"),
        ] {
            assert!(
                Group::parse(keys, expressions, &names).is_err(),
                "{keys}, {expressions}"
            );
        }
        let mut result = ResultSet::new("special", vec![Column::new("v", "DECIMAL")]);
        result.push_row(vec![Cell::Decimal("1.000".into())]);
        assert!(run(&result, "v", "COUNT(*) AS n", "", "").is_err());
    }

    #[test]
    fn grouping_keeps_raw_text_identity_despite_numeric_filter_projection() {
        let mut result = ResultSet::new("numeric-looking keys", vec![Column::new("key", "BIGINT")]);
        result.push_row(vec![Cell::Text("001".into())]);
        result.push_row(vec![Cell::Text("1".into())]);
        let group = Group::parse(
            "key",
            "COUNT(*) AS n",
            &super::super::names(result.columns()),
        )
        .unwrap()
        .unwrap();
        let before = Query::parse("key >= 0", "", &[]).unwrap();
        let grouped =
            aggregate(&result, &group, &[], None, before.as_ref(), ("", "", &[])).unwrap();
        assert_eq!(grouped.row_count(), 2);
        assert_eq!(
            grouped.cell(0, 0).as_deref(),
            Some(&Cell::Text("001".into()))
        );
        assert_eq!(grouped.cell(1, 0).as_deref(), Some(&Cell::Text("1".into())));
    }

    #[test]
    fn multiple_native_keys_text_extrema_and_duplicate_scopes_work() {
        let mut result = ResultSet::new(
            "keys",
            vec![
                Column::new("b", "BOOLEAN"),
                Column::new("i", "BIGINT"),
                Column::new("s", "TEXT"),
            ],
        );
        result.push_row(vec![
            Cell::Bool(true),
            Cell::Int(i64::MAX),
            Cell::Text("z".into()),
        ]);
        result.push_row(vec![
            Cell::Bool(true),
            Cell::Int(i64::MAX),
            Cell::Text("a".into()),
        ]);
        result.push_row(vec![Cell::Bool(false), Cell::Int(i64::MAX), Cell::Null]);
        let group = Group::parse(
            "b, i",
            "COUNT(*) AS n, MIN(s) AS first, MAX(s) AS last",
            &super::super::names(result.columns()),
        )
        .unwrap()
        .unwrap();
        let grouped = aggregate(
            &result,
            &group,
            &[],
            Some(&[1, 0, 1, 2, 99]),
            None,
            ("", "n DESC", &[]),
        )
        .unwrap();
        assert_eq!(grouped.row_count(), 2);
        assert_eq!(grouped.cell(0, 2).as_deref(), Some(&Cell::Int(3)));
        assert_eq!(grouped.cell(0, 3).as_deref(), Some(&Cell::Text("a".into())));
        assert_eq!(grouped.cell(0, 4).as_deref(), Some(&Cell::Text("z".into())));
        assert_eq!(grouped.cell(1, 3).as_deref(), Some(&Cell::Null));
    }

    #[test]
    fn nonfinite_inputs_are_validated_after_filtering_even_for_counts() {
        let mut result = ResultSet::new(
            "floats",
            vec![Column::new("id", "BIGINT"), Column::new("v", "DOUBLE")],
        );
        result.push_row(vec![Cell::Int(1), Cell::Float(f64::NAN)]);
        result.push_row(vec![Cell::Int(2), Cell::Float(2.5)]);
        assert!(run(&result, "", "COUNT(v) AS n", "", "").is_err());
        let group = Group::parse(
            "",
            "COUNT(v) AS n, SUM(v) AS total",
            &super::super::names(result.columns()),
        )
        .unwrap()
        .unwrap();
        let before = Query::parse("id = 2", "", &[]).unwrap();
        let grouped =
            aggregate(&result, &group, &[], None, before.as_ref(), ("", "", &[])).unwrap();
        assert_eq!(grouped.cell(0, 0).as_deref(), Some(&Cell::Int(1)));
        assert_eq!(grouped.cell(0, 1).as_deref(), Some(&Cell::Float(2.5)));
    }

    #[test]
    fn post_view_preserves_raw_text_and_stable_ties() {
        let mut result = ResultSet::new(
            "text outputs",
            vec![Column::new("key", "BIGINT"), Column::new("text", "TEXT")],
        );
        for (key, text) in [(2, "001"), (1, "1"), (3, "002")] {
            result.push_row(vec![Cell::Int(key), Cell::Text(text.into())]);
        }
        let grouped = run(
            &result,
            "key",
            "MIN(text) AS label, COUNT(*) AS n",
            "label >= '001'",
            "n DESC",
        )
        .unwrap();
        assert_eq!(grouped.row_count(), 3);
        for (row, text) in ["001", "1", "002"].iter().enumerate() {
            assert_eq!(
                grouped.cell(row, 1).as_deref(),
                Some(&Cell::Text((*text).into()))
            );
        }
        let empty = run(&result, "key", "COUNT(*) AS n", "n > 10", "n DESC").unwrap();
        assert_eq!(empty.row_count(), 0);
        assert_eq!(empty.columns()[1].name, "n");
    }

    #[test]
    fn having_cannot_hide_nonfinite_or_overflow_errors() {
        let mut result = ResultSet::new("invalid", vec![Column::new("v", "DOUBLE")]);
        result.push_row(vec![Cell::Float(f64::INFINITY)]);
        assert!(run(&result, "", "COUNT(v) AS n", "n < 0", "").is_err());
        let mut result = ResultSet::new("overflow", vec![Column::new("v", "BIGINT")]);
        result.push_row(vec![Cell::Int(i64::MAX)]);
        result.push_row(vec![Cell::Int(1)]);
        assert!(run(&result, "", "SUM(v) AS total", "total < 0", "").is_err());
    }

    #[test]
    fn empty_global_counts_and_truncation_are_explicit() {
        let mut result = sample();
        result.mark_truncated();
        let count = run(&result, "", "COUNT(*) AS n", "", "").unwrap();
        assert_eq!(count.cell(0, 0).as_deref(), Some(&Cell::Int(5)));
        let group = Group::parse(
            "",
            "COUNT(*) AS n, SUM(amount) AS total",
            &super::super::names(result.columns()),
        )
        .unwrap()
        .unwrap();
        let empty = aggregate(&result, &group, &[], Some(&[]), None, ("", "", &[])).unwrap();
        assert_eq!(empty.row_count(), 1);
        assert_eq!(empty.cell(0, 0).as_deref(), Some(&Cell::Int(0)));
        assert_eq!(empty.cell(0, 1).as_deref(), Some(&Cell::Null));
        assert!(empty.is_truncated());
        let empty = run(
            &ResultSet::new("empty", vec![Column::new("v", "TEXT")]),
            "v",
            "COUNT(*) AS n",
            "",
            "",
        )
        .unwrap();
        assert_eq!(empty.row_count(), 0);
    }
}
