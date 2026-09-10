//! Measuring and cutting text by how wide it looks, not how many bytes it is.
//!
//! A grid whose columns are measured in bytes or in `char`s misaligns the moment a result holds
//! CJK text, an emoji, or a combining accent. Every measurement here goes through the Unicode
//! width tables instead.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// How many terminal columns a string occupies.
pub fn width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// How many columns a string occupies, giving up once past `cap`.
///
/// Measuring a megabyte of text to learn that it is wider than a 48 column limit is wasted work,
/// and a result set can hold a hundred thousand such cells.
pub fn width_capped(text: &str, cap: usize) -> usize {
    let mut total = 0usize;
    for character in text.chars() {
        total += UnicodeWidthChar::width(character).unwrap_or(0);
        if total > cap {
            return cap + 1;
        }
    }
    total
}

/// Cut a string to at most `limit` columns, marking it if anything was dropped.
///
/// The marker takes one column of the budget, so the result never exceeds `limit`. A `limit` of
/// zero yields an empty string rather than a lone marker.
pub fn truncate(text: &str, limit: usize, marker: &str) -> String {
    if width_capped(text, limit) <= limit {
        return text.to_owned();
    }
    if limit == 0 {
        return String::new();
    }

    let budget = limit.saturating_sub(width(marker));
    let mut out = String::with_capacity(text.len().min(budget * 4));
    let mut total = 0usize;

    for character in text.chars() {
        let step = UnicodeWidthChar::width(character).unwrap_or(0);
        if total + step > budget {
            break;
        }
        total += step;
        out.push(character);
    }

    out.push_str(marker);
    out
}

/// Pad a string to `target` columns.
///
/// Padding is by display width, so a column of mixed scripts still lines up.
pub fn pad(text: &str, target: usize, align_right: bool) -> String {
    let current = width(text);
    if current >= target {
        return text.to_owned();
    }

    let fill = " ".repeat(target - current);
    if align_right {
        fill + text
    } else {
        text.to_owned() + &fill
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_is_one_column_per_character() {
        assert_eq!(width("hello"), 5);
        assert_eq!(width(""), 0);
    }

    #[test]
    fn wide_scripts_take_two_columns() {
        assert_eq!(width("日本語"), 6);
        assert_eq!(width("한글"), 4);
    }

    #[test]
    fn emoji_take_two_columns() {
        assert_eq!(width("🐱"), 2);
    }

    #[test]
    fn combining_marks_add_nothing() {
        // "e" followed by a combining acute accent renders as one column.
        assert_eq!(width("e\u{301}"), 1);
    }

    #[test]
    fn capped_measurement_stops_early() {
        let long = "a".repeat(10_000);
        assert_eq!(width_capped(&long, 10), 11);
        assert_eq!(width_capped("abc", 10), 3);
        assert_eq!(width_capped("abcdefghijk", 10), 11);
    }

    #[test]
    fn short_text_is_not_truncated() {
        assert_eq!(truncate("abc", 10, "…"), "abc");
        assert_eq!(truncate("abc", 3, "…"), "abc");
    }

    #[test]
    fn truncation_leaves_room_for_the_marker() {
        assert_eq!(truncate("abcdef", 4, "…"), "abc…");
        assert_eq!(width(&truncate("abcdef", 4, "…")), 4);
    }

    #[test]
    fn truncation_never_splits_a_wide_character() {
        // Four columns of budget, one taken by the marker, leaves three: one wide character fits,
        // the second would overflow.
        let cut = truncate("日本語", 4, "…");
        assert_eq!(cut, "日…");
        assert_eq!(width(&cut), 3);
    }

    #[test]
    fn a_zero_limit_yields_nothing() {
        assert_eq!(truncate("abc", 0, "…"), "");
    }

    #[test]
    fn padding_uses_display_width() {
        assert_eq!(pad("ab", 5, false), "ab   ");
        assert_eq!(pad("ab", 5, true), "   ab");
        assert_eq!(pad("日", 5, false), "日   ");
        assert_eq!(width(&pad("日", 5, false)), 5);
    }

    #[test]
    fn padding_never_shrinks() {
        assert_eq!(pad("abcdef", 3, false), "abcdef");
    }
}
