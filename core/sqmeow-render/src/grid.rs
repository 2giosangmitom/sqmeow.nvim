//! Turning a result set into the lines of a buffer.
//!
//! All of this happens in the engine rather than in Lua. Laying out a hundred thousand rows is the
//! one part of showing a result that is genuinely expensive, and doing it here is what keeps the
//! editor responsive.

use sqmeow_db::{Cell, ResultSet};

use crate::width;

/// The smallest `max_column_width` may be, so a truncation marker still fits.
///
/// This floors the cap, not the column. A column narrower than this is simply narrow: truncation
/// can only happen once a value exceeds the cap, and the cap is never below this.
pub const MIN_COLUMN_WIDTH: usize = 3;

/// The characters a grid is drawn with.
///
/// Owned rather than borrowed, because every one of them is the plugin user's to choose. There is
/// no fixed set of styles to pick from: the four characters arrive with the configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GridStyle {
    /// Between columns.
    pub vertical: String,
    /// Along the rule under the header.
    pub horizontal: String,
    /// Where the rule meets a column separator.
    pub cross: String,
    /// Appended to a value that did not fit.
    pub ellipsis: String,
}

/// The characters one `configure` call carries. Absent ones are left alone.
#[derive(Debug, Clone, Default)]
pub struct GridStylePatch {
    pub vertical: Option<String>,
    pub horizontal: Option<String>,
    pub cross: Option<String>,
    pub ellipsis: Option<String>,
}

/// Take a separator only if it is exactly one column wide.
///
/// A rule is drawn by repeating one of these under a column measured in columns, so a wide glyph
/// or an empty string would put every rule out of step with the header above it. An unchanged
/// separator is a much smaller surprise than a misaligned grid.
fn set_separator(target: &mut String, value: Option<String>) {
    match value {
        Some(value) if width::width(&value) == 1 => *target = value,
        _ => {}
    }
}

impl GridStyle {
    /// Apply the characters the plugin sent, ignoring any that would misalign the grid.
    pub fn update(&mut self, patch: GridStylePatch) {
        set_separator(&mut self.vertical, patch.vertical);
        set_separator(&mut self.horizontal, patch.horizontal);
        set_separator(&mut self.cross, patch.cross);
        // The ellipsis is free to be any width, because `truncate` measures whatever it is given
        // and takes that out of the column's budget.
        if let Some(value) = patch.ellipsis {
            self.ellipsis = value;
        }
    }
}

impl Default for GridStyle {
    /// Box-drawing characters, which is what the plugin sends unless its user changed them.
    fn default() -> Self {
        Self {
            vertical: "│".to_owned(),
            horizontal: "─".to_owned(),
            cross: "┼".to_owned(),
            ellipsis: "…".to_owned(),
        }
    }
}

/// How a result should be drawn.
#[derive(Debug, Clone)]
pub struct GridOptions {
    /// Columns wider than this are truncated.
    pub max_column_width: usize,
    /// What `NULL` is shown as.
    pub null_text: String,
    /// Rows per page.
    pub page_size: usize,
    pub style: GridStyle,
}

impl Default for GridOptions {
    fn default() -> Self {
        Self {
            max_column_width: 48,
            null_text: "NULL".into(),
            page_size: 100,
            style: GridStyle::default(),
        }
    }
}

/// Column widths and alignment, measured once per result.
///
/// Measured across every row rather than only the visible page, so a column does not change width
/// when the user pages, which would make the grid appear to shift under them.
#[derive(Debug, Clone, Default)]
pub struct Layout {
    widths: Vec<usize>,
    align_right: Vec<bool>,
}

impl Layout {
    /// Measure a result.
    pub fn measure(result: &ResultSet, options: &GridOptions) -> Self {
        let cap = options.max_column_width.max(MIN_COLUMN_WIDTH);

        let mut widths = Vec::with_capacity(result.columns().len());
        let mut align_right = Vec::with_capacity(result.columns().len());

        for (index, column) in result.columns().iter().enumerate() {
            let cells = result.column_cells(index);

            let mut widest = width::width_capped(&column.name, cap).min(cap);
            // A column is numeric when every value in it is, so a column of numbers with one
            // `NULL` still aligns right, and one stray text value turns the whole column left.
            let mut numeric = !cells.is_empty();

            for cell in cells {
                if !cell.is_null() && !cell.is_numeric() {
                    numeric = false;
                }
                if widest < cap {
                    let shown = cell.display(&options.null_text);
                    widest = widest.max(width::width_capped(&shown, cap).min(cap));
                }
            }

            widths.push(widest);
            align_right.push(numeric);
        }

        Self {
            widths,
            align_right,
        }
    }

    /// The measured width of each column.
    pub fn widths(&self) -> &[usize] {
        &self.widths
    }

    /// Where each column sits, counted in display columns from the start of the line.
    ///
    /// Display columns rather than bytes, because a row holding CJK text puts the same column at a
    /// different byte offset on every line. Display position is the one thing that is constant,
    /// and it is what the editor needs to work out which cell a cursor is on.
    ///
    /// Returns `(start, width)` per column.
    pub fn spans(&self) -> Vec<(usize, usize)> {
        let mut spans = Vec::with_capacity(self.widths.len());
        // One leading space before the first column.
        let mut at = 1usize;

        for (index, width) in self.widths.iter().enumerate() {
            if index > 0 {
                // The " │ " between columns.
                at += 3;
            }
            spans.push((at, *width));
            at += width;
        }

        spans
    }

    /// The header line and the rule beneath it.
    /// How many lines `header` produces: the column names, and the rule under them.
    ///
    /// The editor is told this with every page, because it is what turns a cursor line into a row
    /// of the result now that the header shares the grid's buffer.
    pub const HEADER_LINES: usize = 2;

    pub fn header(&self, result: &ResultSet, options: &GridOptions) -> Vec<String> {
        let names: Vec<String> = result
            .columns()
            .iter()
            .map(|column| column.name.clone())
            .collect();

        vec![self.row(&names, options, false), self.rule(options)]
    }

    /// One page of rows, starting at `offset`.
    ///
    /// An out-of-range offset yields no rows rather than an error, because a page request can race
    /// a result being replaced.
    pub fn rows(&self, result: &ResultSet, options: &GridOptions, offset: usize) -> Vec<String> {
        let last = (offset + options.page_size).min(result.row_count());
        if offset >= last {
            return Vec::new();
        }

        (offset..last)
            .map(|row| {
                let cells: Vec<String> = (0..self.widths.len())
                    .map(|column| {
                        result
                            .cell(row, column)
                            .unwrap_or(&Cell::Null)
                            .display(&options.null_text)
                            .into_owned()
                    })
                    .collect();
                self.row(&cells, options, true)
            })
            .collect()
    }

    /// The header, the rule, and one page of rows.
    pub fn page(&self, result: &ResultSet, options: &GridOptions, offset: usize) -> Vec<String> {
        let mut lines = self.header(result, options);
        lines.extend(self.rows(result, options, offset));
        lines
    }

    fn row(&self, cells: &[String], options: &GridOptions, align: bool) -> String {
        let separator = format!(" {} ", options.style.vertical);
        let mut line = String::from(" ");

        for (index, target) in self.widths.iter().enumerate() {
            if index > 0 {
                line.push_str(&separator);
            }

            let empty = String::new();
            let text = cells.get(index).unwrap_or(&empty);
            let text = width::truncate(text, *target, &options.style.ellipsis);
            let right = align && self.align_right.get(index).copied().unwrap_or(false);

            line.push_str(&width::pad(&text, *target, right));
        }

        // Nothing needs the padding past the last visible character, and a buffer full of lines
        // with invisible trailing spaces is a nuisance to yank from and to diff.
        line.truncate(line.trim_end().len());
        line
    }

    fn rule(&self, options: &GridOptions) -> String {
        let joint = format!(
            "{h}{cross}{h}",
            h = options.style.horizontal,
            cross = options.style.cross
        );

        let mut line = options.style.horizontal.clone();
        for (index, target) in self.widths.iter().enumerate() {
            if index > 0 {
                line.push_str(&joint);
            }
            line.push_str(&options.style.horizontal.repeat(*target));
        }
        line
    }
}

#[cfg(test)]
mod tests {
    use sqmeow_db::Column;

    use super::*;

    fn column(name: &str) -> Column {
        Column {
            name: name.into(),
            type_name: "TEXT".into(),
        }
    }

    fn people() -> ResultSet {
        let mut result = ResultSet::new(
            "select id, name from people",
            vec![column("id"), column("name")],
        );
        result.push_row(vec![Cell::Int(1), Cell::Text("alice".into())]);
        result.push_row(vec![Cell::Int(20), Cell::Text("bo".into())]);
        result
    }

    fn render(result: &ResultSet, options: &GridOptions) -> Vec<String> {
        Layout::measure(result, options).page(result, options, 0)
    }

    #[test]
    fn columns_fit_their_widest_value() {
        let result = people();
        let layout = Layout::measure(&result, &GridOptions::default());
        // "id" is two wide, but "20" is as well; "name" is four, wider than "alice" is not.
        assert_eq!(layout.widths(), &[2, 5]);
    }

    #[test]
    fn spans_line_up_with_what_was_drawn() {
        let result = people();
        let options = GridOptions::default();
        let layout = Layout::measure(&result, &options);
        let spans = layout.spans();

        let header = &layout.header(&result, &options)[0];
        for (index, (start, width)) in spans.iter().enumerate() {
            let name = &result.columns()[index].name;
            let taken: String = header.chars().skip(*start).take(*width).collect();
            assert!(
                taken.starts_with(name.as_str()),
                "column {index}: {taken:?}"
            );
        }
    }

    #[test]
    fn a_result_with_no_columns_has_no_spans() {
        let result = ResultSet::new("create table t (x int)", vec![]);
        assert!(
            Layout::measure(&result, &GridOptions::default())
                .spans()
                .is_empty()
        );
    }

    #[test]
    fn the_header_names_the_columns() {
        let lines = render(&people(), &GridOptions::default());
        assert_eq!(lines[0], " id │ name");
        assert_eq!(lines[1], "────┼──────");
    }

    #[test]
    fn the_rule_is_as_wide_as_the_header() {
        let lines = render(&people(), &GridOptions::default());
        assert_eq!(width::width(&lines[1]), width::width(&lines[0]) + 1);
    }

    #[test]
    fn numbers_align_right_and_text_aligns_left() {
        let lines = render(&people(), &GridOptions::default());
        assert_eq!(lines[2], "  1 │ alice");
        assert_eq!(lines[3], " 20 │ bo");
    }

    #[test]
    fn no_line_carries_trailing_whitespace() {
        for line in render(&people(), &GridOptions::default()) {
            assert_eq!(line.trim_end(), line, "trailing space in {line:?}");
        }
    }

    #[test]
    fn an_empty_last_cell_leaves_no_trailing_space() {
        // The separator before a column carries a space of its own, so an empty final cell would
        // otherwise end the line with it.
        let mut result = ResultSet::new("select a, b", vec![column("a"), column("b")]);
        result.push_row(vec![Cell::Null, Cell::Text(String::new())]);

        let lines = render(&result, &GridOptions::default());
        assert_eq!(lines[2], " NULL │");
    }

    #[test]
    fn a_short_last_cell_leaves_no_trailing_space() {
        let mut result = ResultSet::new("select a, b", vec![column("a"), column("b")]);
        result.push_row(vec![Cell::Text("x".into()), Cell::Text("y".into())]);
        result.push_row(vec![Cell::Text("xx".into()), Cell::Text("yyyy".into())]);

        for line in render(&result, &GridOptions::default()) {
            assert_eq!(line.trim_end(), line, "trailing space in {line:?}");
        }
    }

    #[test]
    fn a_mixed_column_aligns_left() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Int(1)]);
        result.push_row(vec![Cell::Text("x".into())]);

        let lines = render(&result, &GridOptions::default());
        assert_eq!(lines[2], " 1");
    }

    #[test]
    fn a_null_does_not_make_a_number_column_textual() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Int(1)]);
        result.push_row(vec![Cell::Null]);

        let lines = render(&result, &GridOptions::default());
        assert_eq!(lines[2], "    1");
        assert_eq!(lines[3], " NULL");
    }

    #[test]
    fn wide_values_are_truncated_to_the_cap() {
        let mut result = ResultSet::new("select v", vec![column("v")]);
        result.push_row(vec![Cell::Text("abcdefghij".into())]);

        let options = GridOptions {
            max_column_width: 5,
            ..GridOptions::default()
        };
        let lines = render(&result, &options);
        assert_eq!(lines[2], " abcd…");
    }

    #[test]
    fn wide_scripts_still_align() {
        let mut result = ResultSet::new("select a, b", vec![column("a"), column("b")]);
        result.push_row(vec![Cell::Text("日本".into()), Cell::Text("x".into())]);
        result.push_row(vec![Cell::Text("ab".into()), Cell::Text("y".into())]);

        let lines = render(&result, &GridOptions::default());
        let separators: Vec<usize> = lines
            .iter()
            .skip(2)
            .map(|line| width::width(line.split('│').next().unwrap()))
            .collect();
        assert_eq!(separators[0], separators[1]);
    }

    #[test]
    fn paging_walks_the_rows() {
        let mut result = ResultSet::new("select n", vec![column("n")]);
        for n in 0..10 {
            result.push_row(vec![Cell::Int(n)]);
        }

        let options = GridOptions {
            page_size: 4,
            ..GridOptions::default()
        };
        let layout = Layout::measure(&result, &options);

        assert_eq!(layout.rows(&result, &options, 0).len(), 4);
        assert_eq!(layout.rows(&result, &options, 8).len(), 2);
        assert!(layout.rows(&result, &options, 10).is_empty());
        assert!(layout.rows(&result, &options, 999).is_empty());
    }

    #[test]
    fn column_widths_do_not_change_between_pages() {
        // Measured over the whole result, so the first page already reserves the room the second
        // page needs. Otherwise the grid would visibly shift as the user pages through it.
        let mut result = ResultSet::new("select v, n", vec![column("v"), column("n")]);
        result.push_row(vec![Cell::Text("short".into()), Cell::Int(1)]);
        result.push_row(vec![Cell::Text("much longer value".into()), Cell::Int(2)]);

        let options = GridOptions {
            page_size: 1,
            ..GridOptions::default()
        };
        let layout = Layout::measure(&result, &options);

        let first = layout.rows(&result, &options, 0);
        let second = layout.rows(&result, &options, 1);
        assert_eq!(first[0], " short             │ 1");
        assert_eq!(second[0], " much longer value │ 2");
    }

    #[test]
    fn an_empty_result_still_renders_its_header() {
        let result = ResultSet::new(
            "select id, name from people where false",
            vec![column("id"), column("name")],
        );
        let lines = render(&result, &GridOptions::default());
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], " id │ name");
    }

    #[test]
    fn a_result_with_no_columns_renders_nothing_useful_but_does_not_panic() {
        let result = ResultSet::new("create table t (x int)", vec![]);
        let lines = render(&result, &GridOptions::default());
        assert_eq!(lines, vec![String::new(), "─".to_string()]);
    }

    #[test]
    fn a_configured_style_replaces_the_box_drawing() {
        let mut style = GridStyle::default();
        style.update(GridStylePatch {
            vertical: Some("|".to_owned()),
            horizontal: Some("-".to_owned()),
            cross: Some("+".to_owned()),
            ellipsis: Some("~".to_owned()),
        });

        let options = GridOptions {
            style,
            ..GridOptions::default()
        };
        let lines = render(&people(), &options);
        assert_eq!(lines[0], " id | name");
        assert_eq!(lines[1], "----+------");
    }

    #[test]
    fn a_separator_that_is_not_one_column_wide_is_ignored() {
        let mut style = GridStyle::default();
        style.update(GridStylePatch {
            // Two columns, nothing at all, and a whole word: each would put the rule out of step
            // with the header above it.
            vertical: Some("██".to_owned()),
            horizontal: Some(String::new()),
            cross: Some("cross".to_owned()),
            ellipsis: Some("...".to_owned()),
        });

        assert_eq!(style.vertical, "│");
        assert_eq!(style.horizontal, "─");
        assert_eq!(style.cross, "┼");
        // The ellipsis has no alignment to keep, so a wider one is honoured.
        assert_eq!(style.ellipsis, "...");
    }
}
