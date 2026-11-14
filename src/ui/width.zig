//! Wide-char-aware visual width for the TUI.
//!
//! CJK and other wide characters occupy 2 columns; ASCII and most other
//! characters occupy 1; control characters occupy 0. Used to position the
//! hardware cursor and (later) to soft-wrap lines, where a byte offset is not
//! the same as a visual column.

const std = @import("std");

/// Visual width (columns) of a UTF-8 string, counting wide chars as 2.
pub fn visualWidth(s: []const u8) u32 {
    var w: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (b >= 32) w += 1;
            i += 1;
            continue;
        }
        const n = utf8Len(b);
        var r: u21 = 0;
        if (b >= 0xF0) {
            r = @as(u21, b) & 0x07;
        } else if (b >= 0xE0) {
            r = @as(u21, b) & 0x0F;
        } else {
            r = @as(u21, b) & 0x1F;
        }
        var ok = true;
        var j: usize = 1;
        while (j < n) : (j += 1) {
            if (i + j >= s.len) {
                ok = false;
                break;
            }
            r = (r << 6) | (@as(u21, s[i + j]) & 0x3F);
        }
        w += if (ok) runeWidth(r) else 1;
        i += n;
    }
    return w;
}

/// Number of bytes in a UTF-8 sequence given its leading byte (0xC0..0xF7).
pub fn utf8Len(lead: u8) usize {
    return if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
}

/// Start byte offset of the character immediately before `col` in `line`.
/// Backspace should delete from this offset to `col` (a whole character), not
/// just one byte — otherwise a 3-byte CJK char needs three backspaces.
pub fn prevCharStart(line: []const u8, col: usize) usize {
    if (col == 0) return 0;
    var i = col - 1;
    while (i > 0 and (line[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// End byte offset (exclusive) of the character starting at `col` in `line`.
/// Delete-forward should remove from `col` to this offset (a whole character).
pub fn nextCharEnd(line: []const u8, col: usize) usize {
    if (col >= line.len) return line.len;
    const b = line[col];
    if (b < 0x80) return col + 1;
    const n = utf8Len(b);
    return if (col + n <= line.len) col + n else line.len;
}

/// Column width of a single Unicode code point (2 for wide, 1 for narrow,
/// 0 for control chars / combining marks / variation selectors).
fn runeWidth(r: u21) u32 {
    if (r < 32) return 0;
    if (r == 0x7F) return 0;
    // Variation selectors and combining marks take no cell of their own,
    // except FE0F (emoji presentation): ⚠ + FE0F renders as one wide cell,
    // so the selector carries the extra column (works for per-character
    // callers like markdown's visibleWidth too).
    if (r >= 0x0300 and r <= 0x036F) return 0;
    if (r == 0xFE0E) return 0;
    if (r == 0xFE0F) return 1;
    if (r >= 0x200B and r <= 0x200F) return 0;
    if (r >= 0x1100 and r <= 0x115F) return 2; // Hangul Jamo
    if (r >= 0x2E80 and r <= 0x303E) return 2; // CJK radicals / Kangxi
    if (r >= 0x3041 and r <= 0x33FF) return 2; // CJK (kana, symbols)
    if (r >= 0x3400 and r <= 0x4DBF) return 2; // CJK ext A
    if (r >= 0x4E00 and r <= 0x9FFF) return 2; // CJK unified
    if (r >= 0xA000 and r <= 0xA4CF) return 2; // Yi
    if (r >= 0xAC00 and r <= 0xD7A3) return 2; // Hangul syllables
    if (r >= 0xF900 and r <= 0xFAFF) return 2; // CJK compat
    if (r >= 0xFE10 and r <= 0xFE19) return 2; // vertical forms
    if (r >= 0xFE30 and r <= 0xFE4F) return 2; // CJK compat forms
    if (r >= 0xFF00 and r <= 0xFF60) return 2; // fullwidth
    if (r >= 0xFFE0 and r <= 0xFFE6) return 2;
    if (r >= 0x20000 and r <= 0x3FFFD) return 2; // CJK ext B+
    // Emoji rendered as two cells (Unicode East Asian Width = Wide; pi's
    // visibleWidth gives RGI emoji 2 columns as well). Terminals draw these
    // wide even though some are EAW Neutral, so a plain base followed by
    // FE0F is measured below instead of here.
    if (r >= 0x1F1E6 and r <= 0x1F1FF) return 2; // regional indicators
    if (emojiWide(r)) return 2;
    return 1;
}

/// Emoji ranges terminals render two cells wide.
fn emojiWide(r: u21) bool {
    if (r >= 0x231A and r <= 0x231B) return true; // ⌚ ⌛
    if (r >= 0x2329 and r <= 0x232A) return true;
    if (r >= 0x23E9 and r <= 0x23EC) return true;
    if (r == 0x23F0 or r == 0x23F3) return true;
    if (r >= 0x25FD and r <= 0x25FE) return true;
    if (r >= 0x2614 and r <= 0x2615) return true;
    if (r >= 0x2648 and r <= 0x2653) return true;
    if (r == 0x267F or r == 0x2693 or r == 0x26A1) return true;
    if (r >= 0x26AA and r <= 0x26AB) return true;
    if (r >= 0x26BD and r <= 0x26BE) return true;
    if (r >= 0x26C4 and r <= 0x26C5) return true;
    if (r == 0x26CE or r == 0x26D4 or r == 0x26EA) return true;
    if (r >= 0x26F2 and r <= 0x26F3) return true;
    if (r == 0x26F5 or r == 0x26FA or r == 0x26FD) return true;
    if (r == 0x2705) return true; // ✅
    if (r >= 0x270A and r <= 0x270B) return true;
    if (r == 0x2728) return true;
    if (r == 0x274C or r == 0x274E) return true; // ❌
    if (r >= 0x2753 and r <= 0x2755) return true;
    if (r == 0x2757) return true;
    if (r >= 0x2795 and r <= 0x2797) return true;
    if (r == 0x27B0 or r == 0x27BF) return true;
    if (r >= 0x2B1B and r <= 0x2B1C) return true;
    if (r == 0x2B50 or r == 0x2B55) return true;
    if (r == 0x1F004 or r == 0x1F0CF) return true;
    if (r >= 0x1F18E and r <= 0x1F191) return true;
    if (r >= 0x1F192 and r <= 0x1F19A) return true;
    if (r >= 0x1F200 and r <= 0x1F320) return true;
    if (r >= 0x1F32D and r <= 0x1F335) return true;
    if (r >= 0x1F337 and r <= 0x1F37C) return true;
    if (r >= 0x1F37E and r <= 0x1F393) return true;
    if (r >= 0x1F3A0 and r <= 0x1F3CA) return true;
    if (r >= 0x1F3CF and r <= 0x1F3D3) return true;
    if (r >= 0x1F3E0 and r <= 0x1F3F0) return true;
    if (r == 0x1F3F4) return true;
    if (r >= 0x1F3F8 and r <= 0x1F43E) return true;
    if (r == 0x1F440) return true;
    if (r >= 0x1F442 and r <= 0x1F4FC) return true;
    if (r >= 0x1F4FF and r <= 0x1F53D) return true;
    if (r >= 0x1F54B and r <= 0x1F54E) return true;
    if (r >= 0x1F550 and r <= 0x1F567) return true;
    if (r == 0x1F57A or r == 0x1F5A4) return true;
    if (r >= 0x1F595 and r <= 0x1F596) return true;
    if (r >= 0x1F5FB and r <= 0x1F64F) return true;
    if (r >= 0x1F680 and r <= 0x1F6C5) return true;
    if (r == 0x1F6CC) return true;
    if (r >= 0x1F6D0 and r <= 0x1F6D2) return true;
    if (r >= 0x1F6D5 and r <= 0x1F6D7) return true;
    if (r >= 0x1F6DD and r <= 0x1F6DF) return true;
    if (r >= 0x1F6EB and r <= 0x1F6EC) return true;
    if (r >= 0x1F6F4 and r <= 0x1F6FC) return true;
    if (r >= 0x1F7E0 and r <= 0x1F7EB) return true;
    if (r >= 0x1F90C and r <= 0x1F93A) return true;
    if (r >= 0x1F93C and r <= 0x1F945) return true;
    if (r >= 0x1F947 and r <= 0x1F9FF) return true;
    if (r >= 0x1FA70 and r <= 0x1FA7C) return true;
    if (r >= 0x1FA80 and r <= 0x1FA88) return true;
    if (r >= 0x1FA90 and r <= 0x1FABD) return true;
    if (r >= 0x1FABF and r <= 0x1FAC5) return true;
    if (r >= 0x1FACE and r <= 0x1FADB) return true;
    if (r >= 0x1FAE0 and r <= 0x1FAE8) return true;
    if (r >= 0x1FAF0 and r <= 0x1FAF8) return true;
    return false;
}

test "visualWidth ascii" {
    try std.testing.expectEqual(@as(u32, 5), visualWidth("hello"));
    try std.testing.expectEqual(@as(u32, 0), visualWidth(""));
    try std.testing.expectEqual(@as(u32, 3), visualWidth("a b"));
}

test "visualWidth cjk" {
    // 中 = E4 B8 AD (1 wide char = 2 cols).
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xE4\xB8\xAD"));
    // 你好 = 2 wide chars = 4 cols (6 bytes).
    try std.testing.expectEqual(@as(u32, 4), visualWidth("\xE4\xBD\xA0\xE5\xA5\xBD"));
    // Mixed: "a中" = 1 + 2 = 3 cols.
    try std.testing.expectEqual(@as(u32, 3), visualWidth("a\xE4\xB8\xAD"));
    // 3 中 chars = 6 cols (9 bytes).
    try std.testing.expectEqual(@as(u32, 6), visualWidth("\xE4\xB8\xAD\xE4\xB8\xAD\xE4\xB8\xAD"));
}

test "visualWidth emoji" {
    // 🚀 (F0 9F 9A 80) renders two cells wide in terminals.
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xF0\x9F\x9A\x80"));
    // ✅ / ❌ (EAW Wide).
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xE2\x9C\x85"));
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xE2\x9D\x8C"));
    // ⚠️ = ⚠ (narrow) + FE0F → one wide emoji cell.
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xE2\x9A\xA0\xEF\xB8\x8F"));
    // ⚠ without FE0F stays narrow.
    try std.testing.expectEqual(@as(u32, 1), visualWidth("\xE2\x9A\xA0"));
    // 🎉 (U+1F389).
    try std.testing.expectEqual(@as(u32, 2), visualWidth("\xF0\x9F\x8E\x89"));
}

test "prevCharStart / nextCharEnd" {
    const cjk = "\xE4\xB8\xAD"; // 中 (3 bytes)
    // Backspace at the end of 中 → start 0.
    try std.testing.expectEqual(@as(usize, 0), prevCharStart(cjk, 3));
    // Delete-forward at the start of 中 → end 3.
    try std.testing.expectEqual(@as(usize, 3), nextCharEnd(cjk, 0));
    // Mixed "a中": backspace after 中 → start 1; after a → start 0.
    const mixed = "a\xE4\xB8\xAD";
    try std.testing.expectEqual(@as(usize, 1), prevCharStart(mixed, 4));
    try std.testing.expectEqual(@as(usize, 0), prevCharStart(mixed, 1));
    // ASCII: backspace after 'b' → start 1.
    try std.testing.expectEqual(@as(usize, 1), prevCharStart("ab", 2));
    try std.testing.expectEqual(@as(usize, 1), nextCharEnd("ab", 0));
    // nextCharEnd on ASCII single byte at col 1 → end 2.
    try std.testing.expectEqual(@as(usize, 2), nextCharEnd("ab", 1));
}

/// Visual width of a string that contains ANSI escape sequences: escapes
/// occupy zero columns, everything else counts via `visualWidth`. The plain
/// `visualWidth` above counts escape bytes as printable characters — use
/// this for styled rows (search box content, caret markers).
pub fn visibleWidthEsc(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7E)) i += 1;
                i = @min(i + 1, s.len);
            } else if (s[i] == ']') {
                i += 1;
                while (i < s.len) : (i += 1) {
                    if (s[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else {
                i += 1;
            }
            continue;
        }
        const end = nextCharEnd(s, i);
        total += visualWidth(s[i..end]);
        i = end;
    }
    return total;
}
