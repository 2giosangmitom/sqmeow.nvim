//! Distinguishes the sides of a table read more than once.

use sqlparser::ast::{Expr, Query, SelectItem, SetExpr, Statement, TableFactor, TableWithJoins};
use sqlparser::dialect::{
    Dialect as Grammar, DuckDbDialect, GenericDialect, MySqlDialect, PostgreSqlDialect,
    SQLiteDialect,
};
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer};

use crate::adapter::Dialect;
use crate::edit::TableName;

/// Which read of its table a result column came through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Side {
    /// The table is read once.
    Only,
    /// Through this alias, in lower case, of a table read more than once.
    Alias(String),
    /// Not known, so the table cannot be edited.
    Unknown,
}

/// How a query reads its tables, for a driver that names only the table a column came from.
#[derive(Debug, Default)]
pub struct Sides {
    /// Each table read, in lower case, with its alias when `FROM` reads it directly.
    reads: Vec<(String, Option<String>)>,
    /// Each result column's qualifier and column name, when the select list has no wildcard.
    qualifiers: Option<Vec<Option<(String, String)>>>,
    /// The lower-case words of a statement the parser could not read.
    words: Option<Vec<String>>,
    /// A view the query reads could not be read, so no table's reads are known.
    opaque: bool,
}

impl Sides {
    /// Read `statement` as `dialect` writes it.
    pub fn read(dialect: Dialect, statement: &str) -> Self {
        let grammar = grammar(dialect);
        match Parser::parse_sql(grammar.as_ref(), statement).as_deref() {
            Ok([Statement::Query(query)]) => {
                let mut sides = Self::default();
                sides.query(query, true);
                sides.qualifiers = qualifiers(query);
                sides
            }
            _ => Self {
                words: Some(words(grammar.as_ref(), statement)),
                ..Self::default()
            },
        }
    }

    /// Count the tables each view the query reads reads in turn, from `views`' names and definitions,
    /// for a driver that traces a view's columns to its tables. Each read of a view counts again.
    pub fn expand_views(&mut self, dialect: Dialect, views: &[(String, String)]) {
        // Far past any real nesting, so a definition that reads itself cannot loop.
        const LIMIT: usize = 10_000;

        let grammar = grammar(dialect);
        let mut at = 0;
        loop {
            let read = match &self.words {
                Some(words) => words.get(at).cloned(),
                None => self.reads.get(at).map(|(table, _)| table.clone()),
            };
            let Some(read) = read else {
                return;
            };
            at += 1;
            let Some((view, definition)) = views
                .iter()
                .find(|(view, _)| view.eq_ignore_ascii_case(&read))
            else {
                continue;
            };
            if at > LIMIT {
                self.opaque = true;
                return;
            }
            if let Some(words) = &mut self.words {
                let own = view.to_lowercase();
                words.extend(
                    self::words(grammar.as_ref(), definition)
                        .into_iter()
                        .filter(|word| *word != own),
                );
                continue;
            }
            match Parser::parse_sql(grammar.as_ref(), definition).as_deref() {
                Ok([Statement::CreateView(created)]) => self.query(&created.query, false),
                _ => {
                    self.opaque = true;
                    return;
                }
            }
        }
    }

    /// Which read of `table` result column `column`, its column `name`, came through.
    pub fn side(&self, table: &TableName, column: usize, name: &str) -> Side {
        if self.opaque {
            return Side::Unknown;
        }
        let wanted = table.name.to_lowercase();
        if let Some(words) = &self.words {
            return match words.iter().filter(|word| **word == wanted).count() {
                0 | 1 => Side::Only,
                _ => Side::Unknown,
            };
        }
        let reads: Vec<&Option<String>> = self
            .reads
            .iter()
            .filter(|(table, _)| *table == wanted)
            .map(|(_, alias)| alias)
            .collect();
        if reads.len() <= 1 {
            return Side::Only;
        }
        let Some(Some((qualifier, shown))) = self
            .qualifiers
            .as_ref()
            .and_then(|qualifiers| qualifiers.get(column))
        else {
            return Side::Unknown;
        };
        let direct = reads.iter().all(|alias| alias.is_some());
        if direct
            && shown.eq_ignore_ascii_case(name)
            && reads
                .iter()
                .any(|alias| alias.as_deref() == Some(qualifier))
        {
            Side::Alias(qualifier.clone())
        } else {
            Side::Unknown
        }
    }

    fn query(&mut self, query: &Query, direct: bool) {
        for cte in query.with.iter().flat_map(|with| &with.cte_tables) {
            self.query(&cte.query, false);
        }
        self.set(&query.body, direct);
    }

    fn set(&mut self, body: &SetExpr, direct: bool) {
        match body {
            SetExpr::Select(select) => {
                for from in &select.from {
                    self.joined(from, direct);
                }
            }
            SetExpr::Query(query) => self.query(query, false),
            SetExpr::SetOperation { left, right, .. } => {
                self.set(left, false);
                self.set(right, false);
            }
            _ => {}
        }
    }

    fn joined(&mut self, from: &TableWithJoins, direct: bool) {
        self.factor(&from.relation, direct);
        for join in &from.joins {
            self.factor(&join.relation, direct);
        }
    }

    fn factor(&mut self, factor: &TableFactor, direct: bool) {
        match factor {
            TableFactor::Table { name, alias, .. } => {
                let Some(table) = name.0.last().and_then(|part| part.as_ident()) else {
                    return;
                };
                let table = table.value.to_lowercase();
                let alias = direct.then(|| {
                    alias
                        .as_ref()
                        .map_or_else(|| table.clone(), |alias| alias.name.value.to_lowercase())
                });
                self.reads.push((table, alias));
            }
            TableFactor::Derived { subquery, .. } => self.query(subquery, false),
            TableFactor::NestedJoin {
                table_with_joins, ..
            } => self.joined(table_with_joins, direct),
            _ => {}
        }
    }
}

/// Each select-list item's qualifier and column, or `None` when a wildcard hides the positions.
fn qualifiers(query: &Query) -> Option<Vec<Option<(String, String)>>> {
    let SetExpr::Select(select) = query.body.as_ref() else {
        return None;
    };
    select
        .projection
        .iter()
        .map(|item| match item {
            SelectItem::UnnamedExpr(expr) | SelectItem::ExprWithAlias { expr, .. } => {
                Some(match expr {
                    Expr::CompoundIdentifier(parts) if parts.len() >= 2 => Some((
                        parts[parts.len() - 2].value.to_lowercase(),
                        parts[parts.len() - 1].value.clone(),
                    )),
                    _ => None,
                })
            }
            _ => None,
        })
        .collect()
}

/// The lower-case words of a statement.
fn words(grammar: &dyn Grammar, statement: &str) -> Vec<String> {
    Tokenizer::new(grammar, statement)
        .tokenize()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|token| match token {
            Token::Word(word) => Some(word.value.to_lowercase()),
            _ => None,
        })
        .collect()
}

fn grammar(dialect: Dialect) -> Box<dyn Grammar> {
    match dialect {
        Dialect::Postgres => Box::new(PostgreSqlDialect {}),
        Dialect::MySql => Box::new(MySqlDialect {}),
        Dialect::Sqlite => Box::new(SQLiteDialect {}),
        Dialect::DuckDb => Box::new(DuckDbDialect {}),
        _ => Box::new(GenericDialect {}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn side(statement: &str, column: usize, name: &str) -> Side {
        Sides::read(Dialect::Postgres, statement).side(&TableName::parse("public.t"), column, name)
    }

    #[test]
    fn a_table_read_once_has_one_side() {
        assert_eq!(side("select id, name from t", 1, "name"), Side::Only);
        assert_eq!(
            side("select * from t join u on u.id = t.u", 0, "id"),
            Side::Only
        );
    }

    #[test]
    fn each_alias_of_a_self_join_is_a_side() {
        let sql = r#"select c.id, p.name as parent, "P".id from t c join public.t "P" on "P".id = c.parent"#;
        assert_eq!(side(sql, 0, "id"), Side::Alias("c".into()));
        assert_eq!(side(sql, 1, "name"), Side::Alias("p".into()));
        assert_eq!(side(sql, 2, "id"), Side::Alias("p".into()));
    }

    #[test]
    fn a_self_join_side_that_cannot_be_told_is_unknown() {
        let join = "from t c join t p on p.id = c.parent";
        assert_eq!(side(&format!("select * {join}"), 0, "id"), Side::Unknown);
        assert_eq!(
            side(&format!("select c.id, name {join}"), 1, "name"),
            Side::Unknown
        );
        assert_eq!(
            side(&format!("select p.name {join}"), 0, "id"),
            Side::Unknown
        );
    }

    #[test]
    fn a_table_read_again_in_a_subquery_or_cte_is_unknown() {
        assert_eq!(
            side(
                "select t.id, s.name from t join (select * from t) s on s.id = t.id",
                0,
                "id"
            ),
            Side::Unknown
        );
        assert_eq!(
            side(
                "with s as (select * from t) select t.id from t join s on s.id = t.id",
                0,
                "id"
            ),
            Side::Unknown
        );
    }

    #[test]
    fn a_statement_the_parser_cannot_read_counts_the_table_name() {
        assert_eq!(side("select id from t where id @@@ 1", 0, "id"), Side::Only);
        assert_eq!(side("select id from t, t @@@ 1", 0, "id"), Side::Unknown);
    }

    #[test]
    fn a_table_read_twice_inside_a_view_is_unknown() {
        let views = [
            (
                "family".to_owned(),
                "CREATE VIEW family AS SELECT c.id, p.name FROM t c JOIN t p ON p.id = c.parent"
                    .to_owned(),
            ),
            (
                "named".to_owned(),
                "create view named as select id, name from t".to_owned(),
            ),
            (
                "again".to_owned(),
                "create view again as select * from named".to_owned(),
            ),
            ("broken".to_owned(), "create view broken as @@@".to_owned()),
        ];
        let side = |statement: &str| {
            let mut sides = Sides::read(Dialect::Sqlite, statement);
            sides.expand_views(Dialect::Sqlite, &views);
            sides.side(&TableName::parse("t"), 0, "id")
        };
        assert_eq!(side("select * from family"), Side::Unknown);
        assert_eq!(side("select * from again"), Side::Only);
        assert_eq!(
            side("select a.id from again a join named n on n.id = a.id"),
            Side::Unknown
        );
        assert_eq!(side("select * from family where id @@@ 1"), Side::Unknown);
        assert_eq!(side("select * from named where id @@@ 1"), Side::Only);
        assert_eq!(side("select * from broken"), Side::Unknown);
    }
}
