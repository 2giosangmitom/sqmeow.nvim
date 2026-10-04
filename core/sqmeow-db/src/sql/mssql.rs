//! T-SQL batches. Semicolons do not delimit requests: variables and routine
//! definitions belong to the whole batch. GO is a client-side line separator.

use super::Statement;
use sqlparser::{
    ast::{Query, SetExpr, Statement as AstStatement},
    dialect::MsSqlDialect,
    parser::Parser,
};

pub(super) fn query(sql: &str) -> Option<Box<Query>> {
    let mut statements = Parser::parse_sql(&MsSqlDialect {}, sql).ok()?;
    if statements.len() != 1 {
        return None;
    }
    match statements.pop()? {
        AstStatement::Query(query) => Some(query),
        _ => None,
    }
}

pub(super) fn filtered(
    sql: &str,
    condition: &str,
    order: &str,
    columns: &[String],
) -> Option<String> {
    if crate::guard::writes(crate::adapter::Dialect::MsSql, sql) {
        return None;
    }
    let mut query = query(sql)?;
    let with = query.with.take();
    if query.for_clause.is_some() {
        return None;
    }
    let has_top = matches!(query.body.as_ref(), SetExpr::Select(select) if select.top.is_some());
    let mut inner = query.to_string();
    if query.order_by.is_some() && query.limit_clause.is_none() && query.fetch.is_none() && !has_top
    {
        inner.push_str(" OFFSET 0 ROWS");
    }
    let prefix = with.map(|with| with.to_string());
    let mut result = match super::distinct_names(crate::adapter::Dialect::MsSql, columns) {
        Some(names) => format!(
            "{}sqmeow_view ({names}) AS (\n{inner}\n)\nSELECT * FROM sqmeow_view",
            prefix.map_or("WITH ".into(), |p| format!("{p}, "))
        ),
        None => format!(
            "{}SELECT * FROM (\n{inner}\n) AS sqmeow_view",
            prefix.map_or(String::new(), |p| format!("{p}\n"))
        ),
    };
    if !condition.trim().is_empty() {
        result.push_str(&format!("\nWHERE {}", condition.trim()));
    }
    if !order.trim().is_empty() {
        result.push_str(&format!("\nORDER BY {}", order.trim()));
    }
    Some(result)
}

pub(super) fn batches(input: &str) -> Vec<Statement> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut batch = String::new();
    let mut quote = None;
    let mut comment_depth = 0usize;
    let mut last = 0;
    for (line, text) in input.lines().enumerate() {
        last = line;
        if quote.is_none() && comment_depth == 0 && is_go_separator(text) {
            push(&mut result, &mut batch, start, line.saturating_sub(1));
            start = line + 1;
            continue;
        }
        if batch.is_empty() && text.trim().is_empty() {
            start = line + 1;
            continue;
        }
        batch.push_str(text);
        batch.push('\n');
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if comment_depth > 0 {
                if c == '/' && chars.peek() == Some(&'*') {
                    chars.next();
                    comment_depth += 1;
                } else if c == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    comment_depth -= 1;
                }
            } else if let Some(end) = quote {
                if c == end {
                    if chars.peek() == Some(&end) {
                        chars.next();
                    } else {
                        quote = None;
                    }
                }
            } else {
                match c {
                    '-' if chars.peek() == Some(&'-') => break,
                    '/' if chars.peek() == Some(&'*') => {
                        chars.next();
                        comment_depth = 1;
                    }
                    '\'' | '"' => quote = Some(c),
                    '[' => quote = Some(']'),
                    _ => {}
                }
            }
        }
    }
    push(&mut result, &mut batch, start, last);
    result
}

fn is_go_separator(text: &str) -> bool {
    // Only a standalone GO is supported. Do not silently discard repeat
    // counts or SQL following a comment; leave unsupported forms to diagnose.
    let Some(rest) = text.trim_start().get(2..).filter(|_| {
        text.trim_start()
            .get(..2)
            .is_some_and(|s| s.eq_ignore_ascii_case("go"))
    }) else {
        return false;
    };
    let mut rest = rest.trim_start();
    loop {
        if rest.is_empty() || rest.starts_with("--") {
            return true;
        }
        if !rest.starts_with("/*") {
            return false;
        }
        let mut depth = 1usize;
        let mut at = 2;
        let bytes = rest.as_bytes();
        while at + 1 < bytes.len() && depth > 0 {
            match &bytes[at..at + 2] {
                b"/*" => {
                    depth += 1;
                    at += 2;
                }
                b"*/" => {
                    depth -= 1;
                    at += 2;
                }
                _ => at += 1,
            }
        }
        if depth > 0 {
            return false;
        }
        rest = rest[at..].trim_start();
    }
}

fn push(result: &mut Vec<Statement>, batch: &mut String, start_line: usize, end_line: usize) {
    let sql = batch.trim().to_owned();
    batch.clear();
    if !super::super::guard::words(crate::adapter::Dialect::MsSql, &sql).is_empty() {
        result.push(Statement {
            sql,
            start_line,
            end_line,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_require_one_query_and_keep_ctes_outside_derived_tables() {
        assert!(filtered("SELECT 1; DELETE FROM t", "n=1", "", &[]).is_none());
        let sql = filtered(
            "WITH t AS (SELECT 1 AS n) SELECT n FROM t ORDER BY n",
            "n=1",
            "n",
            &[],
        )
        .unwrap();
        assert!(sql.starts_with("WITH t AS"));
        assert!(sql.contains("OFFSET 0 ROWS"));
        assert!(!sql.contains("(\nWITH"));
    }

    #[test]
    fn variables_stay_in_their_batch() {
        let result = batches("DECLARE @n int = 1;\nSELECT @n;\nGO -- next\nSELECT 2;");
        assert_eq!(result.len(), 2);
        assert!(result[0].sql.contains("SELECT @n"));
        assert_eq!((result[1].start_line, result[1].end_line), (3, 3));
    }

    #[test]
    fn go_inside_quotes_and_nested_comments_is_not_a_separator() {
        let sql = "SELECT N'a\nGO\nb', [a]]\nGO\nb];\n/* outer /* inner */\nGO\n*/\nGO\nSELECT 2";
        assert_eq!(batches(sql).len(), 2);
    }

    #[test]
    fn go_with_case_and_trailing_comment_separates() {
        for separator in [
            "GO",
            "go",
            "  Go  ",
            "\tGO\t",
            "GO -- next",
            "GO /* trailing */",
            "GO /* outer /* nested */ end */ -- next",
        ] {
            let sql = format!("SELECT 1;\n{separator}\nSELECT 2;");
            let result = batches(&sql);
            assert_eq!(result.len(), 2, "{separator:?} should separate: {result:?}");
            assert_eq!(result[0].sql, "SELECT 1;");
            assert_eq!(result[1].sql, "SELECT 2;");
        }
    }

    #[test]
    fn go_with_words_after_it_is_not_a_separator() {
        for line in [
            "GOTO x",
            "GOOFY",
            "SELECT 1 GO",
            "GO 1x",
            "GO -1",
            "GO 2",
            "GO;",
            "GO /* closed */ SELECT 9",
            "🐱",
            "GO /* unclosed",
        ] {
            // The last case keeps the comment open, so nothing after it can be GO;
            // the point here is it does not split on that line itself.
            let sql = format!("SELECT 1;\n{line}\nGO\nSELECT 2;");
            let result = batches(&sql);
            if line == "GO /* unclosed" {
                assert_eq!(result.len(), 1, "{line:?}: {result:?}");
            } else {
                assert_eq!(result.len(), 2, "{line:?}: {result:?}");
            }
        }
    }

    #[test]
    fn go_inside_a_line_comment_is_not_a_separator() {
        let result = batches("-- GO\nSELECT 1;\nGO\nSELECT 2;");
        assert_eq!(result.len(), 2);
        assert!(result[0].sql.contains("SELECT 1"));
    }
}
