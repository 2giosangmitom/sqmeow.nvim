//! Measures and truncates text by display width.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Returns how many terminal columns `text` occupies.
pub fn width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// Returns how many columns `text` occupies, stopping once past `cap`.
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

/// Truncates `text` to at most `limit` columns, appending `marker` if truncated.
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

/// Pads `text` to `target` columns.
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
