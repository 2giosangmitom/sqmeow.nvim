//! Filters and orders held rows via SQL `WHERE` and `ORDER BY` fragments.

use std::borrow::Cow;
use std::cmp::Ordering;

use sqlparser::ast::{BinaryOperator, Expr, OrderByKind, SetExpr, Statement, UnaryOperator, Value};
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

use crate::result::{Column, ResultSet};
use crate::value::Cell;

/// A condition and an order, compiled against a result's columns.
#[derive(Debug, Clone, PartialEq)]
pub struct Query {
    condition: Option<Node>,
    order: Vec<Key>,
}

#[derive(Debug, Clone, PartialEq)]
struct Key {
    node: Node,
    descending: bool,
    nulls_first: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum Node {
    Column(usize),
    Literal(Literal),
    Not(Box<Node>),
    And(Box<Node>, Box<Node>),
    Or(Box<Node>, Box<Node>),
    Compare(Box<Node>, Comparison, Box<Node>),
    IsNull(Box<Node>, bool),
    Like {
        expr: Box<Node>,
        pattern: Box<Node>,
        negated: bool,
        fold: bool,
    },
    In {
        expr: Box<Node>,
        list: Vec<Node>,
        negated: bool,
    },
    Between {
        expr: Box<Node>,
        low: Box<Node>,
        high: Box<Node>,
        negated: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Comparison {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Debug, Clone, PartialEq)]
enum Literal {
    Null,
    Bool(bool),
    Number(f64),
    Text(String),
}

/// A value while a row is tested.
#[derive(Debug)]
enum Datum<'a> {
    Null,
    Bool(bool),
    Number(f64),
    Text(Cow<'a, str>),
}

/// The names a filter knows columns by, a repeated name numbered `name_2`, `name_3`.
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

impl Query {
    /// Compile a condition and an order for columns called `names`, or `None` when both are empty.
    pub fn parse(condition: &str, order: &str, names: &[String]) -> Result<Option<Self>, String> {
        let (condition, order) = (condition.trim(), order.trim());
        if condition.is_empty() && order.is_empty() {
            return Ok(None);
        }
        // Each clause on its own line, so a trailing `--` comment cannot swallow the next one.
        let mut sql = "SELECT * FROM sqmeow_view".to_owned();
        if !condition.is_empty() {
            sql.push_str("\nWHERE ");
            sql.push_str(condition);
        }
        if !order.is_empty() {
            sql.push_str("\nORDER BY ");
            sql.push_str(order);
        }
        let parsed =
            Parser::parse_sql(&GenericDialect {}, &sql).map_err(|error| error.to_string())?;
        let [Statement::Query(query)] = parsed.as_slice() else {
            return Err("a filter takes one condition and one order".to_owned());
        };
        let SetExpr::Select(select) = query.body.as_ref() else {
            return Err("a filter takes one condition and one order".to_owned());
        };
        if query.limit_clause.is_some()
            || select.from.len() != 1
            || !select.from[0].joins.is_empty()
        {
            return Err("a filter takes one condition and one order".to_owned());
        }

        let compiler = Compiler { names };
        let condition = select
            .selection
            .as_ref()
            .map(|expr| compiler.node(expr))
            .transpose()?;
        let order = match query.order_by.as_ref().map(|order| &order.kind) {
            None => Vec::new(),
            Some(OrderByKind::Expressions(keys)) => keys
                .iter()
                .map(|key| {
                    Ok(Key {
                        node: compiler.key(&key.expr)?,
                        descending: matches!(
                            key.options.sort,
                            Some(sqlparser::ast::OrderBySort::Desc)
                        ),
                        nulls_first: key.options.nulls_first.unwrap_or(false),
                    })
                })
                .collect::<Result<_, String>>()?,
            Some(OrderByKind::All(_)) => {
                return Err("`ORDER BY ALL` is not supported in a filter".to_owned());
            }
        };
        Ok(Some(Self { condition, order }))
    }

    /// Whether a row meets the condition.
    pub fn passes(&self, result: &ResultSet, row: usize) -> bool {
        self.condition
            .as_ref()
            .is_none_or(|condition| truth(condition, result, row) == Some(true))
    }

    /// Whether the query orders rows.
    pub fn orders(&self) -> bool {
        !self.order.is_empty()
    }

    /// How two rows compare in the order.
    pub fn compare(&self, result: &ResultSet, a: usize, b: usize) -> Ordering {
        self.order
            .iter()
            .map(|key| {
                let (left, right) = (value(&key.node, result, a), value(&key.node, result, b));
                match (matches!(left, Datum::Null), matches!(right, Datum::Null)) {
                    (true, true) => Ordering::Equal,
                    (true, false) if key.nulls_first => Ordering::Less,
                    (true, false) => Ordering::Greater,
                    (false, true) if key.nulls_first => Ordering::Greater,
                    (false, true) => Ordering::Less,
                    _ => {
                        // Text that all reads as numbers, as Redis values do, sorts as numbers.
                        let ordering = match (&left, &right) {
                            (Datum::Text(a), Datum::Text(b)) => {
                                match (a.trim().parse::<f64>(), b.trim().parse::<f64>()) {
                                    (Ok(a), Ok(b)) => a.partial_cmp(&b),
                                    _ => compare(&left, &right),
                                }
                            }
                            _ => compare(&left, &right),
                        }
                        .unwrap_or(Ordering::Equal);
                        if key.descending {
                            ordering.reverse()
                        } else {
                            ordering
                        }
                    }
                }
            })
            .find(|ordering| ordering.is_ne())
            .unwrap_or(Ordering::Equal)
    }
}

struct Compiler<'a> {
    names: &'a [String],
}

impl Compiler<'_> {
    fn node(&self, expr: &Expr) -> Result<Node, String> {
        let boxed = |expr: &Expr| self.node(expr).map(Box::new);
        Ok(match expr {
            Expr::Identifier(ident) => Node::Column(self.column(&ident.value)?),
            Expr::Value(value) => Node::Literal(literal(&value.value, expr)?),
            Expr::Nested(inner) => self.node(inner)?,
            Expr::UnaryOp {
                op: UnaryOperator::Not,
                expr,
            } => Node::Not(boxed(expr)?),
            Expr::UnaryOp {
                op: UnaryOperator::Minus,
                expr: inner,
            } => match self.node(inner)? {
                Node::Literal(Literal::Number(number)) => Node::Literal(Literal::Number(-number)),
                _ => return Err(unsupported(expr)),
            },
            Expr::BinaryOp { left, op, right } => {
                let comparison = match op {
                    BinaryOperator::And => return Ok(Node::And(boxed(left)?, boxed(right)?)),
                    BinaryOperator::Or => return Ok(Node::Or(boxed(left)?, boxed(right)?)),
                    BinaryOperator::Eq => Comparison::Eq,
                    BinaryOperator::NotEq => Comparison::Ne,
                    BinaryOperator::Lt => Comparison::Lt,
                    BinaryOperator::LtEq => Comparison::Le,
                    BinaryOperator::Gt => Comparison::Gt,
                    BinaryOperator::GtEq => Comparison::Ge,
                    _ => return Err(unsupported(expr)),
                };
                Node::Compare(boxed(left)?, comparison, boxed(right)?)
            }
            Expr::IsNull(inner) => Node::IsNull(boxed(inner)?, false),
            Expr::IsNotNull(inner) => Node::IsNull(boxed(inner)?, true),
            Expr::Like {
                negated,
                any: false,
                expr: inner,
                pattern,
                escape_char: None,
            } => Node::Like {
                expr: boxed(inner)?,
                pattern: boxed(pattern)?,
                negated: *negated,
                fold: false,
            },
            Expr::ILike {
                negated,
                any: false,
                expr: inner,
                pattern,
                escape_char: None,
            } => Node::Like {
                expr: boxed(inner)?,
                pattern: boxed(pattern)?,
                negated: *negated,
                fold: true,
            },
            Expr::InList {
                expr: inner,
                list,
                negated,
            } => Node::In {
                expr: boxed(inner)?,
                list: list
                    .iter()
                    .map(|item| self.node(item))
                    .collect::<Result<_, _>>()?,
                negated: *negated,
            },
            Expr::Between {
                expr: inner,
                negated,
                low,
                high,
            } => Node::Between {
                expr: boxed(inner)?,
                low: boxed(low)?,
                high: boxed(high)?,
                negated: *negated,
            },
            _ => return Err(unsupported(expr)),
        })
    }

    /// An order key: a column, or a column's 1-based position.
    fn key(&self, expr: &Expr) -> Result<Node, String> {
        if let Expr::Value(value) = expr
            && let Value::Number(number, _) = &value.value
            && let Ok(position) = number.parse::<usize>()
        {
            return (1..=self.names.len())
                .contains(&position)
                .then_some(Node::Column(position - 1))
                .ok_or_else(|| format!("there is no column {position}"));
        }
        self.node(expr)
    }

    fn column(&self, name: &str) -> Result<usize, String> {
        self.names
            .iter()
            .position(|known| known == name)
            .or_else(|| {
                self.names
                    .iter()
                    .position(|known| known.eq_ignore_ascii_case(name))
            })
            .ok_or_else(|| format!("there is no column `{name}`"))
    }
}

fn literal(value: &Value, expr: &Expr) -> Result<Literal, String> {
    Ok(match value {
        Value::Null => Literal::Null,
        Value::Boolean(flag) => Literal::Bool(*flag),
        Value::Number(number, _) => Literal::Number(number.parse().map_err(|_| unsupported(expr))?),
        Value::SingleQuotedString(text) => Literal::Text(text.clone()),
        _ => return Err(unsupported(expr)),
    })
}

fn unsupported(expr: &Expr) -> String {
    format!("`{expr}` is not supported in a filter")
}

fn value<'a>(node: &'a Node, result: &'a ResultSet, row: usize) -> Datum<'a> {
    match node {
        Node::Column(column) => match result.cell(row, *column).unwrap_or(&Cell::Null) {
            Cell::Null => Datum::Null,
            Cell::Bool(flag) => Datum::Bool(*flag),
            Cell::Int(number) => Datum::Number(*number as f64),
            Cell::Float(number) => Datum::Number(*number),
            Cell::Decimal(text) => text
                .parse()
                .map_or_else(|_| Datum::Text(Cow::Borrowed(text)), Datum::Number),
            cell => Datum::Text(cell.text("")),
        },
        Node::Literal(Literal::Null) => Datum::Null,
        Node::Literal(Literal::Bool(flag)) => Datum::Bool(*flag),
        Node::Literal(Literal::Number(number)) => Datum::Number(*number),
        Node::Literal(Literal::Text(text)) => Datum::Text(Cow::Borrowed(text)),
        predicate => truth(predicate, result, row).map_or(Datum::Null, Datum::Bool),
    }
}

/// Whether a row meets a condition: `None` where SQL says unknown, as for a comparison with NULL.
fn truth<'a>(node: &'a Node, result: &'a ResultSet, row: usize) -> Option<bool> {
    let value = |node: &'a Node| value(node, result, row);
    let truth = |node: &Node| truth(node, result, row);
    match node {
        Node::Column(_) | Node::Literal(_) => match value(node) {
            Datum::Bool(flag) => Some(flag),
            _ => None,
        },
        Node::Not(inner) => truth(inner).map(|flag| !flag),
        Node::And(left, right) => match (truth(left), truth(right)) {
            (Some(false), _) | (_, Some(false)) => Some(false),
            (Some(true), Some(true)) => Some(true),
            _ => None,
        },
        Node::Or(left, right) => match (truth(left), truth(right)) {
            (Some(true), _) | (_, Some(true)) => Some(true),
            (Some(false), Some(false)) => Some(false),
            _ => None,
        },
        Node::Compare(left, comparison, right) => {
            compare(&value(left), &value(right)).map(|ordering| match comparison {
                Comparison::Eq => ordering.is_eq(),
                Comparison::Ne => ordering.is_ne(),
                Comparison::Lt => ordering.is_lt(),
                Comparison::Le => ordering.is_le(),
                Comparison::Gt => ordering.is_gt(),
                Comparison::Ge => ordering.is_ge(),
            })
        }
        Node::IsNull(inner, negated) => Some(matches!(value(inner), Datum::Null) != *negated),
        Node::Like {
            expr,
            pattern,
            negated,
            fold,
        } => match (value(expr), value(pattern)) {
            (Datum::Null, _) | (_, Datum::Null) => None,
            (text, pattern) => Some(like(&text_of(&text), &text_of(&pattern), *fold) != *negated),
        },
        Node::In {
            expr,
            list,
            negated,
        } => {
            let left = value(expr);
            let mut unknown = false;
            for item in list {
                match compare(&left, &value(item)) {
                    Some(Ordering::Equal) => return Some(!negated),
                    None => unknown = true,
                    _ => {}
                }
            }
            (!unknown).then_some(*negated)
        }
        Node::Between {
            expr,
            low,
            high,
            negated,
        } => {
            let left = value(expr);
            let above = compare(&left, &value(low))?.is_ge();
            let below = compare(&left, &value(high))?.is_le();
            Some((above && below) != *negated)
        }
    }
}

/// How two values compare, a number with text that reads as one as numbers, or `None` with a NULL.
fn compare(left: &Datum<'_>, right: &Datum<'_>) -> Option<Ordering> {
    let number = |datum: &Datum<'_>| match datum {
        Datum::Number(number) => Some(*number),
        Datum::Text(text) => text.trim().parse::<f64>().ok(),
        _ => None,
    };
    match (left, right) {
        (Datum::Null, _) | (_, Datum::Null) => None,
        (Datum::Bool(a), Datum::Bool(b)) => Some(a.cmp(b)),
        (Datum::Number(_), _) | (_, Datum::Number(_)) => match (number(left), number(right)) {
            (Some(a), Some(b)) => Some(a.partial_cmp(&b).unwrap_or(Ordering::Equal)),
            _ => Some(text_of(left).cmp(&text_of(right))),
        },
        _ => Some(text_of(left).cmp(&text_of(right))),
    }
}

fn text_of<'a>(datum: &'a Datum<'_>) -> Cow<'a, str> {
    match datum {
        Datum::Null => Cow::Borrowed(""),
        Datum::Bool(flag) => Cow::Borrowed(if *flag { "true" } else { "false" }),
        Datum::Number(number) => Cow::Owned(Cell::Float(*number).display("").into_owned()),
        Datum::Text(text) => Cow::Borrowed(text),
    }
}

/// Whether `text` matches a `LIKE` pattern, where `%` is any run, `_` any one character and `\`
/// escapes the next.
fn like(text: &str, pattern: &str, fold: bool) -> bool {
    let fold = |text: &str| {
        if fold {
            text.to_lowercase().chars().collect::<Vec<_>>()
        } else {
            text.chars().collect()
        }
    };
    let (text, pattern) = (fold(text), fold(pattern));
    // Each pattern token: `None` for `%`, `Some(None)` for `_`, `Some(Some(c))` for a literal.
    let mut tokens: Vec<Option<Option<char>>> = Vec::new();
    let mut chars = pattern.iter();
    while let Some(&character) = chars.next() {
        tokens.push(match character {
            '%' => None,
            '_' => Some(None),
            '\\' => Some(Some(chars.next().copied().unwrap_or('\\'))),
            other => Some(Some(other)),
        });
    }

    let (mut at, mut token) = (0, 0);
    let mut resume: Option<(usize, usize)> = None;
    while at < text.len() {
        match tokens.get(token) {
            Some(Some(wanted)) if wanted.is_none_or(|wanted| wanted == text[at]) => {
                at += 1;
                token += 1;
            }
            Some(None) => {
                resume = Some((token, at));
                token += 1;
            }
            _ => match resume {
                Some((star, from)) => {
                    token = star + 1;
                    at = from + 1;
                    resume = Some((star, from + 1));
                }
                None => return false,
            },
        }
    }
    tokens[token..].iter().all(Option::is_none)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "HGETALL people",
            vec![
                Column::new("name", "TEXT"),
                Column::new("age", "TEXT"),
                Column::new("name", "TEXT"),
            ],
        );
        for (name, age, nick) in [
            ("alice", Some("30"), "al"),
            ("bob", None, "b_b"),
            ("carol", Some("9"), "C"),
            ("Alan", Some("30"), "al"),
        ] {
            result.push_row(vec![
                Cell::Text(name.into()),
                age.map_or(Cell::Null, |age| Cell::Text(age.into())),
                Cell::Text(nick.into()),
            ]);
        }
        result
    }

    fn rows(condition: &str, order: &str) -> Vec<usize> {
        let result = people();
        let names = names(result.columns());
        let query = Query::parse(condition, order, &names).unwrap().unwrap();
        let mut rows: Vec<usize> = (0..result.row_count())
            .filter(|row| query.passes(&result, *row))
            .collect();
        rows.sort_by(|a, b| query.compare(&result, *a, *b));
        rows
    }

    #[test]
    fn a_repeated_name_is_numbered() {
        assert_eq!(names(people().columns()), vec!["name", "age", "name_2"]);
    }

    #[test]
    fn text_that_reads_as_a_number_compares_as_one() {
        assert_eq!(rows("age < 10", ""), vec![2]);
        // A quoted value is text, and compares as text.
        assert_eq!(rows("age >= '10'", ""), vec![0, 2, 3]);
    }

    #[test]
    fn null_is_unknown_except_to_is_null() {
        assert_eq!(rows("age <> 30", ""), vec![2]);
        assert_eq!(rows("age IS NULL", ""), vec![1]);
        assert_eq!(rows("NOT (age = 30) OR age IS NULL", ""), vec![1, 2]);
    }

    #[test]
    fn like_in_and_between_match_as_sql_does() {
        assert_eq!(rows("name LIKE 'a%'", ""), vec![0]);
        assert_eq!(rows("name ILIKE 'a%'", ""), vec![0, 3]);
        assert_eq!(rows(r"name_2 LIKE 'b\_b'", ""), vec![1]);
        assert_eq!(
            rows("name IN ('bob', 'carol') AND age BETWEEN 1 AND 10", ""),
            vec![2]
        );
        assert_eq!(rows("\"NAME\" NOT IN ('bob')", ""), vec![0, 2, 3]);
    }

    #[test]
    fn rows_order_by_keys_with_nulls_last_unless_asked() {
        assert_eq!(rows("", "age DESC, name"), vec![3, 0, 2, 1]);
        assert_eq!(rows("", "2 NULLS FIRST, 1 DESC"), vec![1, 2, 0, 3]);
    }

    #[test]
    fn a_mistake_is_explained() {
        let names = names(people().columns());
        let error =
            |condition: &str, order: &str| Query::parse(condition, order, &names).unwrap_err();
        assert!(error("nope = 1", "").contains("no column `nope`"));
        assert!(error("lower(name) = 'a'", "").contains("not supported"));
        assert!(error("", "4").contains("no column 4"));
        assert!(error("age = 1 LIMIT 1", "").contains("one condition"));
        assert_eq!(Query::parse(" ", "", &names), Ok(None));
    }
}
