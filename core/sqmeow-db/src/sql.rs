//! Splitting a buffer of SQL into statements.
//!
//! Naively splitting on `;` breaks the moment a semicolon appears inside a string literal, a
//! comment, or a Postgres function body. This walks the text once, tracking what it is inside, so
//! only a semicolon at the top level ends a statement.

/// One statement, with enough position information to point an error back at the buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    /// The statement text, trimmed, without its terminating semicolon.
    pub sql: String,
    /// Zero-based line the statement starts on.
    pub start_line: usize,
    /// Zero-based line the statement ends on.
    pub end_line: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Code,
    SingleQuote,
    DoubleQuote,
    Backtick,
    LineComment,
    BlockComment,
}

/// Split a buffer of SQL into its statements.
///
/// Whitespace-only and comment-only fragments are dropped, so a trailing semicolon or a trailing
/// comment does not produce an empty statement that the database would reject.
pub fn split(input: &str) -> Vec<Statement> {
    let mut statements = Vec::new();
    let chars: Vec<char> = input.chars().collect();

    let mut mode = Mode::Code;
    let mut block_depth = 0usize;
    // The Postgres tag currently open, such as `$$` or `$body$`.
    let mut dollar_tag: Option<String> = None;

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
                '\'' => mode = Mode::SingleQuote,
                '"' => mode = Mode::DoubleQuote,
                '`' => mode = Mode::Backtick,
                '$' => {
                    if let Some(tag) = read_dollar_tag(&chars, index) {
                        index += tag.chars().count();
                        dollar_tag = Some(tag);
                        continue;
                    }
                }
                ';' => {
                    push(&mut statements, &chars, start, index, start_line, line);
                    index += 1;
                    start = index;
                    start_line = line;
                    continue;
                }
                _ => {}
            },

            // A doubled quote inside a quoted run is an escaped quote, not the end of it. Skipping
            // both characters leaves the mode unchanged, which is exactly right.
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
    chars: &[char],
    start: usize,
    end: usize,
    start_line: usize,
    end_line: usize,
) {
    let text: String = chars[start..end].iter().collect();
    if !has_code(&text) {
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
fn has_code(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    // A fragment of only comments is not a statement.
    !split_comments_only(trimmed)
}

fn split_comments_only(text: &str) -> bool {
    let mut rest = text.trim();
    loop {
        if rest.is_empty() {
            return true;
        }
        if let Some(after) = rest.strip_prefix("--") {
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

    while let Some(&character) = chars.get(cursor) {
        if character == '$' {
            tag.push('$');
            return Some(tag);
        }
        // Tags are identifiers. Anything else means this `$` was arithmetic or a parameter.
        if !character.is_alphanumeric() && character != '_' {
            return None;
        }
        tag.push(character);
        cursor += 1;
    }
    None
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
        split(input).into_iter().map(|s| s.sql).collect()
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
    fn statements_report_the_lines_they_occupy() {
        let statements = split("select 1;\n\nselect\n  2;\n");
        assert_eq!(statements[0].start_line, 0);
        assert_eq!(statements[0].end_line, 0);
        assert_eq!(statements[1].start_line, 2);
        assert_eq!(statements[1].end_line, 3);
    }
}
