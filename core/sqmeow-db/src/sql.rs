//! Splits SQL buffers into statements.

mod sides;

pub use sides::{Side, Sides};

use crate::adapter::Dialect;

/// Represents one statement with its buffer line range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    /// The statement text, trimmed, without its terminating semicolon.
    pub sql: String,
    /// Zero-based line the statement starts on.
    pub start_line: usize,
    /// Zero-based line the statement ends on.
    pub end_line: usize,
}

/// Returns the statement containing `line`, or the nearest one before it.
pub fn statement_at(statements: &[Statement], line: usize) -> Option<&Statement> {
    if let Some(inside) = statements
        .iter()
        .find(|statement| statement.start_line <= line && line <= statement.end_line)
    {
        return Some(inside);
    }

    statements
        .iter()
        .rev()
        .find(|statement| statement.start_line <= line)
        .or_else(|| statements.first())
}

/// Returns the first word of `statement` past leading comments, in lower case.
pub fn first_word(statement: &str) -> String {
    let mut rest = statement.trim_start();
    loop {
        if let Some(after) = rest.strip_prefix("--").or_else(|| rest.strip_prefix('#')) {
            rest = after
                .split_once('\n')
                .map_or("", |(_, tail)| tail)
                .trim_start();
        } else if let Some(after) = rest.strip_prefix("/*") {
            rest = after
                .split_once("*/")
                .map_or("", |(_, tail)| tail)
                .trim_start();
        } else {
            break;
        }
    }
    rest.chars()
        .take_while(|character| character.is_alphabetic())
        .collect::<String>()
        .to_lowercase()
}

/// Returns whether each row of `statement` maps directly to a table row.
///
/// A plain query has no grouping, `DISTINCT`, or set operation at the top
/// level and is therefore editable.
pub fn plain(dialect: Dialect, statement: &str) -> bool {
    !crate::guard::words(dialect, statement)
        .iter()
        .any(|(word, depth)| {
            *depth == 0
                && matches!(
                    word.as_str(),
                    "group" | "having" | "distinct" | "union" | "intersect" | "except"
                )
        })
}

/// Wraps `statement` as a subquery filtered by `condition` and ordered by `order`.
///
/// Returns `None` if `statement` is not a row-returning query. `columns`
/// disambiguates repeated names via a CTE.
pub fn filtered(
    dialect: Dialect,
    statement: &str,
    condition: &str,
    order: &str,
    columns: &[String],
) -> Option<String> {
    let statement = statement.trim().trim_end_matches(';').trim_end();
    if !matches!(
        first_word(statement).as_str(),
        "select" | "with" | "values" | "table"
    ) {
        return None;
    }
    let words = crate::guard::words(dialect, statement);
    let top = |wanted: &str| {
        words
            .iter()
            .any(|(word, depth)| *depth == 0 && word == wanted)
    };
    // MySQL forgets the order of a derived table without a LIMIT.
    let inner =
        if dialect == Dialect::MySql && order.trim().is_empty() && top("order") && !top("limit") {
            format!("{statement}\nLIMIT 18446744073709551615")
        } else {
            statement.to_owned()
        };

    // Each clause on its own line, so a trailing `--` comment cannot swallow the next one.
    let mut sql = match distinct_names(dialect, columns) {
        // A subquery cannot hold two columns of one name, so a CTE names them apart.
        Some(names) => {
            format!("WITH sqmeow_view ({names}) AS (\n{inner}\n)\nSELECT * FROM sqmeow_view")
        }
        None => format!("SELECT * FROM (\n{inner}\n) AS sqmeow_view"),
    };
    if !condition.trim().is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(condition.trim());
    }
    if !order.trim().is_empty() {
        sql.push_str("\nORDER BY ");
        sql.push_str(order.trim());
    }
    Some(sql)
}

/// The column names quoted for a CTE, a repeated one numbered, or `None` when none repeats.
fn distinct_names(dialect: Dialect, columns: &[String]) -> Option<String> {
    let mut taken: Vec<String> = Vec::new();
    let mut repeated = false;
    for name in columns {
        let mut candidate = name.clone();
        let mut count = 1;
        while taken
            .iter()
            .any(|known| known.eq_ignore_ascii_case(&candidate))
        {
            count += 1;
            candidate = format!("{name}_{count}");
            repeated = true;
        }
        taken.push(candidate);
    }
    repeated.then(|| {
        taken
            .iter()
            .map(|name| dialect.quote_ident(name))
            .collect::<Vec<_>>()
            .join(", ")
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Code,
    SingleQuote,
    DoubleQuote,
    Backtick,
    /// A SurrealQL identifier in `⟨` and `⟩`.
    Angle,
    LineComment,
    BlockComment,
}

/// Splits a buffer of Redis commands into statements, one per non-comment line.
pub fn split_lines(input: &str) -> Vec<Statement> {
    input
        .lines()
        .enumerate()
        .filter_map(|(line, text)| {
            let sql = text.trim();
            let skip = sql.is_empty() || sql.starts_with('#') || sql.starts_with("--");
            (!skip).then(|| Statement {
                sql: sql.to_owned(),
                start_line: line,
                end_line: line,
            })
        })
        .collect()
}

/// Splits a buffer of MongoDB commands into Extended JSON documents.
pub fn split_documents(input: &str) -> Vec<Statement> {
    let mut statements = Vec::new();
    let mut current: Option<(usize, String)> = None;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;

    for (line, text) in input.lines().enumerate() {
        let (_, sql) = match &mut current {
            Some(open) => {
                open.1.push('\n');
                open
            }
            None => {
                let trimmed = text.trim();
                if trimmed.is_empty() || trimmed.starts_with("//") || trimmed.starts_with('#') {
                    continue;
                }
                current.insert((line, String::new()))
            }
        };
        sql.push_str(text);

        for character in text.chars() {
            if in_string {
                match character {
                    _ if escaped => escaped = false,
                    '\\' => escaped = true,
                    '"' => in_string = false,
                    _ => {}
                }
                continue;
            }
            match character {
                '"' => in_string = true,
                '{' | '[' => depth += 1,
                '}' | ']' => depth = depth.saturating_sub(1),
                _ => {}
            }
        }

        if depth == 0
            && !in_string
            && let Some((start_line, sql)) = current.take()
        {
            statements.push(Statement {
                sql: sql.trim().to_owned(),
                start_line,
                end_line: line,
            });
        }
    }

    // A document left open runs to the end of the buffer.
    if let Some((start_line, sql)) = current {
        statements.push(Statement {
            sql: sql.trim().to_owned(),
            start_line,
            end_line: input.lines().count().saturating_sub(1),
        });
    }
    statements
}

/// Splits a SQL buffer into statements respecting the given dialect.
pub fn split(input: &str, dialect: Dialect) -> Vec<Statement> {
    let mut statements = Vec::new();
    let chars: Vec<char> = input.chars().collect();

    let mut mode = Mode::Code;
    let mut block_depth = 0usize;
    // The Postgres tag currently open, such as `$$` or `$body$`.
    let mut dollar_tag: Option<String> = None;
    // Whether a backslash in the quoted run currently open escapes the character after it.
    let mut escapes = false;
    // Whether the statement being read starts with `CREATE`, once its first word is read.
    let mut creating: Option<bool> = None;
    let mut routine = false;
    let mut body_depth = 0usize;
    // Inside a CQL `BEGIN BATCH` or a SurrealQL `BEGIN`, which end at `APPLY` or `COMMIT`/`CANCEL`.
    let mut batch = false;

    let mut start = 0usize;
    let mut line = 0usize;
    let mut start_line = 0usize;
    let mut index = 0usize;

    macro_rules! peek {
        ($offset:expr) => {
            chars.get(index + $offset).copied()
        };
    }

    while index < chars.len() {
        let character = chars[index];

        if let Some(tag) = &dollar_tag {
            // Inside a dollar-quoted body nothing matters but the closing tag.
            if character == '$' && starts_with(&chars, index, tag) {
                index += tag.chars().count();
                dollar_tag = None;
                continue;
            }
            if character == '\n' {
                line += 1;
            }
            index += 1;
            continue;
        }

        match mode {
            Mode::Code => match character {
                '-' if peek!(1) == Some('-') => {
                    mode = Mode::LineComment;
                    index += 2;
                    continue;
                }
                '/' if peek!(1) == Some('*') => {
                    mode = Mode::BlockComment;
                    block_depth = 1;
                    index += 2;
                    continue;
                }
                '/' if matches!(dialect, Dialect::Scylla | Dialect::SurrealDb)
                    && peek!(1) == Some('/') =>
                {
                    mode = Mode::LineComment;
                    index += 2;
                    continue;
                }
                '#' if matches!(dialect, Dialect::MySql | Dialect::SurrealDb) => {
                    mode = Mode::LineComment;
                    index += 1;
                    continue;
                }
                '\'' => {
                    mode = Mode::SingleQuote;
                    escapes = matches!(dialect, Dialect::MySql | Dialect::SurrealDb)
                        || (dialect == Dialect::Postgres && is_escape_string(&chars, index));
                }
                '"' => {
                    mode = Mode::DoubleQuote;
                    escapes = matches!(dialect, Dialect::MySql | Dialect::SurrealDb);
                }
                '`' => {
                    mode = Mode::Backtick;
                    escapes = dialect == Dialect::SurrealDb;
                }
                '⟨' if dialect == Dialect::SurrealDb => mode = Mode::Angle,
                // A SurrealQL block, such as a function body, holds statements of its own.
                '{' if dialect == Dialect::SurrealDb => body_depth += 1,
                '}' if dialect == Dialect::SurrealDb => body_depth = body_depth.saturating_sub(1),
                // A `$` inside a word is part of an identifier, such as `price$usd`, not a tag.
                '$' if matches!(dialect, Dialect::Postgres | Dialect::Scylla)
                    && !index
                        .checked_sub(1)
                        .is_some_and(|before| is_word(chars[before])) =>
                {
                    if let Some(tag) = read_dollar_tag(&chars, index) {
                        index += tag.chars().count();
                        dollar_tag = Some(tag);
                        continue;
                    }
                }
                ';' if body_depth == 0 && !batch => {
                    push(
                        &mut statements,
                        dialect,
                        &chars,
                        start,
                        index,
                        start_line,
                        line,
                    );
                    creating = None;
                    routine = false;
                    index += 1;
                    start = index;
                    start_line = line;
                    continue;
                }
                _ if character.is_alphabetic()
                    && !index
                        .checked_sub(1)
                        .is_some_and(|before| is_word(chars[before])) =>
                {
                    let mut end = word_end(&chars, index);
                    let word = chars[index..end].iter().collect::<String>().to_lowercase();
                    match word.as_str() {
                        _ if creating.is_none() => {
                            creating = Some(word == "create");
                            batch = matches!(dialect, Dialect::Scylla | Dialect::SurrealDb)
                                && word == "begin";
                        }
                        "apply" if batch && dialect == Dialect::Scylla => batch = false,
                        "commit" | "cancel" if batch && dialect == Dialect::SurrealDb => {
                            batch = false;
                        }
                        "trigger" | "procedure" | "function" | "event"
                            if creating == Some(true) =>
                        {
                            routine = true;
                        }
                        "begin" | "case" if routine => body_depth += 1,
                        "end" if routine => {
                            let (next, after) = next_word(&chars, end);
                            // `END IF`/`LOOP`/`WHILE`/`REPEAT` close blocks that were never counted open.
                            let closes =
                                matches!(next.as_str(), "if" | "loop" | "while" | "repeat");
                            if !closes {
                                body_depth = body_depth.saturating_sub(1);
                            }
                            if closes || next == "case" {
                                line += chars[end..after].iter().filter(|c| **c == '\n').count();
                                end = after;
                            }
                        }
                        _ => {}
                    }
                    index = end;
                    continue;
                }
                _ => {}
            },

            // An escaped character is taken as it is, even a quote or a line break.
            Mode::SingleQuote | Mode::DoubleQuote | Mode::Backtick
                if escapes && character == '\\' =>
            {
                if peek!(1) == Some('\n') {
                    line += 1;
                }
                index += 2;
                continue;
            }

            // A doubled quote inside a quoted run is an escaped quote, not the end of it.
            Mode::SingleQuote if character == '\'' => {
                if peek!(1) == Some('\'') {
                    index += 2;
                    continue;
                }
                mode = Mode::Code;
            }
            Mode::DoubleQuote if character == '"' => {
                if peek!(1) == Some('"') {
                    index += 2;
                    continue;
                }
                mode = Mode::Code;
            }
            Mode::Backtick if character == '`' => mode = Mode::Code,
            Mode::Angle if character == '⟩' => mode = Mode::Code,

            Mode::LineComment if character == '\n' => mode = Mode::Code,

            Mode::BlockComment => {
                if character == '/' && peek!(1) == Some('*') {
                    // Postgres nests block comments; the others do not mind us tracking depth.
                    block_depth += 1;
                    index += 2;
                    continue;
                }
                if character == '*' && peek!(1) == Some('/') {
                    block_depth -= 1;
                    if block_depth == 0 {
                        mode = Mode::Code;
                    }
                    index += 2;
                    continue;
                }
            }

            _ => {}
        }

        if character == '\n' {
            line += 1;
        }
        index += 1;
    }

    push(
        &mut statements,
        dialect,
        &chars,
        start,
        chars.len(),
        start_line,
        line,
    );
    statements
}

fn push(
    statements: &mut Vec<Statement>,
    dialect: Dialect,
    chars: &[char],
    start: usize,
    end: usize,
    start_line: usize,
    end_line: usize,
) {
    let text: String = chars[start..end].iter().collect();
    if !has_code(&text, dialect) {
        return;
    }

    // Report the lines the statement's text actually occupies, not the whitespace around it.
    let leading = text
        .chars()
        .take_while(|c| c.is_whitespace())
        .collect::<String>();
    let trailing = text
        .chars()
        .rev()
        .take_while(|c| c.is_whitespace())
        .collect::<String>();

    statements.push(Statement {
        sql: text.trim().to_owned(),
        start_line: start_line + leading.matches('\n').count(),
        end_line: end_line - trailing.matches('\n').count(),
    });
}

/// Whether a fragment holds anything a database would act on.
fn has_code(text: &str, dialect: Dialect) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    // A fragment of only comments is not a statement.
    !split_comments_only(trimmed, dialect)
}

fn split_comments_only(text: &str, dialect: Dialect) -> bool {
    let mut rest = text.trim();
    loop {
        if rest.is_empty() {
            return true;
        }
        let line_comment = rest
            .strip_prefix("--")
            .or_else(|| {
                rest.strip_prefix('#')
                    .filter(|_| matches!(dialect, Dialect::MySql | Dialect::SurrealDb))
            })
            .or_else(|| {
                rest.strip_prefix("//")
                    .filter(|_| matches!(dialect, Dialect::Scylla | Dialect::SurrealDb))
            });
        if let Some(after) = line_comment {
            rest = after
                .split_once('\n')
                .map(|(_, tail)| tail)
                .unwrap_or("")
                .trim();
            continue;
        }
        if let Some(after) = rest.strip_prefix("/*") {
            match after.split_once("*/") {
                Some((_, tail)) => rest = tail.trim(),
                None => return true,
            }
            continue;
        }
        return false;
    }
}

/// Read a Postgres dollar-quote tag at `index`, such as `$$` or `$body$`.
fn read_dollar_tag(chars: &[char], index: usize) -> Option<String> {
    let mut tag = String::from("$");
    let mut cursor = index + 1;

    // A tag does not start with a digit, so `$1` is a parameter even when a `$` follows it.
    if chars.get(cursor).is_some_and(char::is_ascii_digit) {
        return None;
    }
    while let Some(&character) = chars.get(cursor) {
        if character == '$' {
            tag.push('$');
            return Some(tag);
        }
        // Tags are identifiers. Anything else means this `$` was arithmetic or a parameter.
        if !is_word(character) {
            return None;
        }
        tag.push(character);
        cursor += 1;
    }
    None
}

/// Whether a character can be part of an unquoted identifier.
fn is_word(character: char) -> bool {
    character.is_alphanumeric() || character == '_' || character == '$'
}

/// Where the word starting at `index` ends.
fn word_end(chars: &[char], index: usize) -> usize {
    chars[index..]
        .iter()
        .position(|character| !is_word(*character))
        .map_or(chars.len(), |length| index + length)
}

/// The word after `index`, past any whitespace, in lower case, and where it ends.
fn next_word(chars: &[char], index: usize) -> (String, usize) {
    let start = chars[index..]
        .iter()
        .position(|character| !character.is_whitespace())
        .map_or(chars.len(), |gap| index + gap);
    let end = word_end(chars, start);
    (
        chars[start..end].iter().collect::<String>().to_lowercase(),
        end,
    )
}

/// Whether the quote at `index` opens a PostgreSQL escape string, `E'…'`, in which a backslash
/// escapes.
fn is_escape_string(chars: &[char], index: usize) -> bool {
    let Some(before) = index.checked_sub(1) else {
        return false;
    };
    matches!(chars[before], 'e' | 'E')
        && !before
            .checked_sub(1)
            .is_some_and(|word| is_word(chars[word]))
}

fn starts_with(chars: &[char], index: usize, needle: &str) -> bool {
    needle
        .chars()
        .enumerate()
        .all(|(offset, expected)| chars.get(index + offset) == Some(&expected))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sqls(input: &str) -> Vec<String> {
        sqls_as(input, Dialect::Postgres)
    }

    fn sqls_as(input: &str, dialect: Dialect) -> Vec<String> {
        split(input, dialect).into_iter().map(|s| s.sql).collect()
    }

    #[test]
    fn a_filter_wraps_the_query_so_its_own_clauses_hold() {
        assert_eq!(
            filtered(
                Dialect::Postgres,
                "select * from t order by a limit 5;",
                "b > 1",
                "a desc",
                &[]
            )
            .as_deref(),
            Some(
                "SELECT * FROM (\nselect * from t order by a limit 5\n) AS sqmeow_view\nWHERE b > 1\nORDER BY a desc"
            )
        );
        assert_eq!(
            filtered(
                Dialect::Postgres,
                "  with x as (select 1) select * from x -- note",
                "",
                " ",
                &[]
            )
            .as_deref(),
            Some("SELECT * FROM (\nwith x as (select 1) select * from x -- note\n) AS sqmeow_view")
        );
    }

    #[test]
    fn only_a_query_that_returns_rows_is_filtered() {
        assert!(filtered(Dialect::Sqlite, "/* rows */ VALUES (1)", "x = 1", "", &[]).is_some());
        for statement in ["delete from t", "explain select 1", "pragma table_info(t)"] {
            assert_eq!(
                filtered(Dialect::Sqlite, statement, "x = 1", "", &[]),
                None,
                "{statement}"
            );
        }
    }

    #[test]
    fn a_filter_keeps_mysql_order_and_names_repeated_columns_apart() {
        assert_eq!(
            filtered(
                Dialect::MySql,
                "select a from t order by a",
                "a > 1",
                "",
                &[]
            )
            .as_deref(),
            Some(
                "SELECT * FROM (\nselect a from t order by a\nLIMIT 18446744073709551615\n) AS sqmeow_view\nWHERE a > 1"
            )
        );
        // Its own LIMIT, or an order the bar gives, needs no help.
        assert!(
            !filtered(
                Dialect::MySql,
                "select a from t order by a limit 3",
                "",
                "a",
                &[]
            )
            .unwrap()
            .contains("18446744073709551615")
        );
        let names = ["id".to_owned(), "ID".to_owned(), "name".to_owned()];
        assert_eq!(
            filtered(
                Dialect::Postgres,
                "select a.id, b.id, a.name from a join b",
                "id_2 > 1",
                "",
                &names
            )
            .as_deref(),
            Some(
                "WITH sqmeow_view (\"id\", \"ID_2\", \"name\") AS (\nselect a.id, b.id, a.name from a join b\n)\nSELECT * FROM sqmeow_view\nWHERE id_2 > 1"
            )
        );
    }

    #[test]
    fn redis_commands_are_one_per_line() {
        let statements = split_lines("SET k \"a;b\"\n\n# note\n-- note\n  GET k  \n");
        let sql: Vec<&str> = statements.iter().map(|s| s.sql.as_str()).collect();
        assert_eq!(sql, vec!["SET k \"a;b\"", "GET k"]);
        assert_eq!((statements[1].start_line, statements[1].end_line), (4, 4));
        // The cursor on the comment runs the command above it, as with SQL.
        assert_eq!(statement_at(&statements, 2).unwrap().sql, "SET k \"a;b\"");
    }

    #[test]
    fn mongodb_documents_span_lines_and_use_stands_alone() {
        let input = "// orders\n{\"find\": \"orders\",\n  \"filter\": {\"note\": \"a } b\\\" {\"}}\n\nuse shop\n{\"ping\": 1}\n";
        let statements = split_documents(input);
        let sql: Vec<&str> = statements.iter().map(|s| s.sql.as_str()).collect();
        assert_eq!(
            sql,
            vec![
                "{\"find\": \"orders\",\n  \"filter\": {\"note\": \"a } b\\\" {\"}}",
                "use shop",
                "{\"ping\": 1}"
            ]
        );
        assert_eq!((statements[0].start_line, statements[0].end_line), (1, 2));
        assert_eq!(statement_at(&statements, 2).unwrap().sql, sql[0]);
        assert_eq!(statement_at(&statements, 4).unwrap().sql, "use shop");
    }

    #[test]
    fn an_unclosed_mongodb_document_runs_to_the_end() {
        let statements = split_documents("{\"find\": \"a\",\n\n");
        assert_eq!(statements.len(), 1);
        assert_eq!((statements[0].start_line, statements[0].end_line), (0, 1));
    }

    #[test]
    fn splits_on_top_level_semicolons() {
        assert_eq!(sqls("select 1; select 2"), vec!["select 1", "select 2"]);
    }

    #[test]
    fn a_single_statement_needs_no_semicolon() {
        assert_eq!(sqls("select 1"), vec!["select 1"]);
    }

    #[test]
    fn a_trailing_semicolon_makes_no_empty_statement() {
        assert_eq!(sqls("select 1;"), vec!["select 1"]);
        assert_eq!(sqls("select 1;;  ;"), vec!["select 1"]);
    }

    #[test]
    fn empty_input_has_no_statements() {
        assert!(sqls("").is_empty());
        assert!(sqls("   \n\t ").is_empty());
    }

    #[test]
    fn a_semicolon_in_a_string_does_not_split() {
        assert_eq!(sqls("select 'a;b'"), vec!["select 'a;b'"]);
    }

    #[test]
    fn a_doubled_quote_is_an_escape() {
        assert_eq!(sqls("select 'it''s; fine'"), vec!["select 'it''s; fine'"]);
    }

    #[test]
    fn a_semicolon_in_a_quoted_identifier_does_not_split() {
        assert_eq!(sqls(r#"select "od;d""#), vec![r#"select "od;d""#]);
        assert_eq!(sqls("select `od;d`"), vec!["select `od;d`"]);
    }

    #[test]
    fn a_semicolon_in_a_line_comment_does_not_split() {
        assert_eq!(
            sqls("select 1 -- ; not a split\n, 2"),
            vec!["select 1 -- ; not a split\n, 2"]
        );
    }

    #[test]
    fn a_semicolon_in_a_block_comment_does_not_split() {
        assert_eq!(sqls("select /* ; */ 1"), vec!["select /* ; */ 1"]);
    }

    #[test]
    fn block_comments_nest() {
        assert_eq!(
            sqls("select /* a /* ; */ b */ 1"),
            vec!["select /* a /* ; */ b */ 1"]
        );
    }

    #[test]
    fn a_comment_only_fragment_is_not_a_statement() {
        assert_eq!(sqls("select 1; -- trailing note"), vec!["select 1"]);
        assert!(sqls("-- just a note").is_empty());
        assert!(sqls("/* just a note */").is_empty());
    }

    #[test]
    fn dollar_quoted_bodies_are_one_statement() {
        let input =
            "create function f() returns int as $$ begin; return 1; end; $$ language plpgsql";
        assert_eq!(sqls(input).len(), 1);
    }

    #[test]
    fn named_dollar_tags_are_matched() {
        let input = "create function f() as $body$ select 1; $body$ language sql; select 2";
        assert_eq!(sqls(input).len(), 2);
    }

    #[test]
    fn a_bare_dollar_is_not_a_tag() {
        assert_eq!(sqls("select $1; select $2"), vec!["select $1", "select $2"]);
    }

    #[test]
    fn mysql_reads_a_backslash_in_a_string_as_an_escape() {
        let input = "select 'it\\'s; fine', \"a\\\"; b\"; select 2";
        assert_eq!(
            sqls_as(input, Dialect::MySql),
            vec!["select 'it\\'s; fine', \"a\\\"; b\"", "select 2"]
        );
    }

    #[test]
    fn a_trailing_backslash_ends_a_standard_string() {
        // PostgreSQL and SQLite take a backslash literally, so this string is `C:\`.
        for dialect in [Dialect::Postgres, Dialect::Sqlite] {
            assert_eq!(
                sqls_as("select 'C:\\'; select 2", dialect),
                vec!["select 'C:\\'", "select 2"],
                "{dialect:?}"
            );
        }
    }

    #[test]
    fn a_postgres_escape_string_reads_backslashes() {
        assert_eq!(
            sqls("select E'it\\'s; fine'; select e'\\\\'; select 3"),
            vec!["select E'it\\'s; fine'", "select e'\\\\'", "select 3"]
        );
        // A word ending in `e` before a string is not an escape string's prefix.
        assert_eq!(
            sqls("select 1 where name = 'a\\'; select 2"),
            vec!["select 1 where name = 'a\\'", "select 2"]
        );
    }

    #[test]
    fn an_escaped_line_break_still_counts_as_a_line() {
        let statements = split("select 'a\\\n';\nselect 2", Dialect::MySql);
        assert_eq!((statements[1].start_line, statements[1].end_line), (2, 2));
    }

    #[test]
    fn mysql_reads_a_hash_as_a_line_comment() {
        assert_eq!(
            sqls_as(
                "select 1 # it's; a note\n, 2; # only a note",
                Dialect::MySql
            ),
            vec!["select 1 # it's; a note\n, 2"]
        );
        // PostgreSQL's `#` is an operator.
        assert_eq!(sqls("select 1 # 2; select 3").len(), 2);
    }

    #[test]
    fn a_dollar_inside_a_word_is_not_a_tag() {
        assert_eq!(
            sqls("select price$usd$ from t; select 2"),
            vec!["select price$usd$ from t", "select 2"]
        );
        assert_eq!(sqls("select $1$2; select 3").len(), 2);
    }

    #[test]
    fn only_postgres_has_dollar_quoting() {
        assert_eq!(
            sqls_as("select $a$; select 2", Dialect::MySql),
            vec!["select $a$", "select 2"]
        );
    }

    #[test]
    fn a_trigger_body_is_part_of_its_create() {
        let input = "create trigger audit after update on people begin\n  insert into log values (1);\n  update t set n = case when n > 1 then 0 else n end;\nend;\nselect 1";
        let statements = sqls_as(input, Dialect::Sqlite);
        assert_eq!(statements.len(), 2, "{statements:?}");
        assert!(statements[0].ends_with("end"), "{}", statements[0]);
        assert_eq!(statements[1], "select 1");
    }

    #[test]
    fn a_mysql_procedure_body_is_part_of_its_create() {
        let input = "CREATE PROCEDURE p(n INT)\nlabel: BEGIN\n  IF n > 0 THEN\n    SELECT 1;\n  END IF;\n  CASE n WHEN 1 THEN SELECT 2; ELSE BEGIN SELECT 3; END; END CASE;\n  WHILE n > 0 DO SET n = n - 1; END WHILE;\n  REPEAT SET n = n + 1; UNTIL n > 2 END REPEAT;\nEND label;\nCALL p(1)";
        let statements = sqls_as(input, Dialect::MySql);
        assert_eq!(statements.len(), 2, "{statements:?}");
        assert!(statements[0].ends_with("END label"), "{}", statements[0]);
        assert_eq!(statements[1], "CALL p(1)");
        assert_eq!(
            split(input, Dialect::MySql)[1].start_line,
            input.lines().count() - 1
        );
        // A line break between `END` and what it closes still counts.
        let statements = split(
            "create procedure p() begin\nif 1 then select 1; end\nif;\nend;\nselect 2",
            Dialect::MySql,
        );
        assert_eq!(statements.len(), 2);
        assert_eq!(statements[1].start_line, 4);
    }

    #[test]
    fn a_postgres_begin_atomic_body_is_part_of_its_create() {
        assert_eq!(
            sqls(
                "create function one() returns int language sql begin atomic select 1; end; select one()"
            ),
            vec![
                "create function one() returns int language sql begin atomic select 1; end",
                "select one()"
            ]
        );
    }

    #[test]
    fn a_transaction_begin_is_a_statement_of_its_own() {
        assert_eq!(
            sqls_as(
                "BEGIN; select 1; END; begin transaction; commit",
                Dialect::Sqlite
            ),
            vec!["BEGIN", "select 1", "END", "begin transaction", "commit"]
        );
        // Outside a routine, `CASE … END` is an expression that ends with its statement.
        assert_eq!(
            sqls("create view v as select case when true then 1 end; select 2").len(),
            2
        );
        assert_eq!(
            sqls("create table t (id int); create index i on t (id); select 3").len(),
            3
        );
    }

    #[test]
    fn the_statement_at_a_line_is_the_one_containing_it() {
        let statements = split("select 1;\n\nselect\n  2;\n\nselect 3;", Dialect::Postgres);

        assert_eq!(statement_at(&statements, 0).unwrap().sql, "select 1");
        assert_eq!(statement_at(&statements, 2).unwrap().sql, "select\n  2");
        assert_eq!(statement_at(&statements, 3).unwrap().sql, "select\n  2");
        assert_eq!(statement_at(&statements, 5).unwrap().sql, "select 3");
    }

    #[test]
    fn a_line_between_statements_picks_the_one_above() {
        let statements = split("select 1;\n\nselect 2;", Dialect::Postgres);
        assert_eq!(statement_at(&statements, 1).unwrap().sql, "select 1");
    }

    #[test]
    fn a_line_before_every_statement_picks_the_first() {
        let statements = split("\n\nselect 1;", Dialect::Postgres);
        assert_eq!(statement_at(&statements, 0).unwrap().sql, "select 1");
    }

    #[test]
    fn a_line_past_every_statement_picks_the_last() {
        let statements = split("select 1;\nselect 2;", Dialect::Postgres);
        assert_eq!(statement_at(&statements, 99).unwrap().sql, "select 2");
    }

    #[test]
    fn there_is_no_statement_in_an_empty_buffer() {
        assert!(statement_at(&split("", Dialect::Postgres), 0).is_none());
    }

    #[test]
    fn statements_report_the_lines_they_occupy() {
        let statements = split("select 1;\n\nselect\n  2;\n", Dialect::Postgres);
        assert_eq!(statements[0].start_line, 0);
        assert_eq!(statements[0].end_line, 0);
        assert_eq!(statements[1].start_line, 2);
        assert_eq!(statements[1].end_line, 3);
    }

    #[test]
    fn a_cql_batch_and_function_body_are_one_statement_each() {
        let input = "BEGIN BATCH\n  INSERT INTO t (a) VALUES (1);\n  INSERT INTO t (a) VALUES (2);\nAPPLY BATCH;\n\
                     CREATE FUNCTION f(x int) CALLED ON NULL INPUT RETURNS int LANGUAGE lua AS $$ return x; $$;\n\
                     // a note\nselect * from t;\n// only a note";
        let statements = split(input, Dialect::Scylla);
        assert_eq!(statements.len(), 3, "{statements:?}");
        assert!(statements[0].sql.ends_with("APPLY BATCH"));
        assert!(statements[1].sql.ends_with("$$ return x; $$"));
        assert!(statements[2].sql.ends_with("select * from t"));
    }

    #[test]
    fn a_surrealql_block_and_transaction_are_one_statement_each() {
        let input = "BEGIN TRANSACTION;\nCREATE a;\nCREATE b;\nCOMMIT TRANSACTION;\n\
                     DEFINE FUNCTION fn::f($x: int) { LET $y = $x; RETURN $y; };\n\
                     // a note\n# another\nSELECT * FROM `we;ird\\``, ⟨o;k⟩ WHERE s = 'it\\'s;';\n-- only a note";
        let statements = split(input, Dialect::SurrealDb);
        assert_eq!(statements.len(), 3, "{statements:?}");
        assert!(statements[0].sql.ends_with("COMMIT TRANSACTION"));
        assert!(statements[1].sql.ends_with("RETURN $y; }"));
        assert!(statements[2].sql.ends_with(r"'it\'s;'"), "{statements:?}");
    }

    #[test]
    fn a_grouped_distinct_or_combined_query_is_not_plain() {
        let pg = Dialect::Postgres;
        assert!(plain(
            pg,
            "select * from t where a in (select a from u group by a)"
        ));
        assert!(plain(
            pg,
            "with x as (select distinct a from t) select * from x"
        ));
        assert!(!plain(pg, "select a, count(*) from t group by a"));
        assert!(!plain(pg, "select distinct a from t"));
        assert!(!plain(pg, "select a from t union all select a from u"));
    }
}
