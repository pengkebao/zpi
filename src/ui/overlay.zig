//! ANSI-aware line compositing for the transcript (pi: compositeTuiLine).
//!
//! Overlays styled text onto an already-styled line at a fixed visual column,
//! keeping the base line's content left and right of the overlay. The tricky
//! part is styling: the text after the overlay must look exactly as it would
//! without the overlay, so the SGR attributes the base line had active at the
//! cut point are replayed (pi's AnsiCodeTracker).

const std = @import("std");
const wmod = @import("width.zig");

pub const RESET = "\x1b[0m";

/// SGR attributes currently active while walking a styled line.
pub const SgrState = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    /// Colour parameters without the CSI framing, e.g. "38;2;33;59;73" or
    /// "31". Empty means the terminal default colour is active.
    fg: Buf = .{},
    bg: Buf = .{},

    pub const Buf = struct {
        bytes: [32]u8 = undefined,
        len: u8 = 0,

        fn set(self: *Buf, text: []const u8) void {
            if (text.len > self.bytes.len) return; // unusual form: keep the old value
            @memcpy(self.bytes[0..text.len], text);
            self.len = @intCast(text.len);
        }

        fn clear(self: *Buf) void {
            self.len = 0;
        }

        pub fn slice(self: *const Buf) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn reset(self: *SgrState) void {
        self.* = .{};
    }

    fn put(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, first: *bool, text: []const u8) !void {
        if (!first.*) try out.append(alloc, ';');
        first.* = false;
        try out.appendSlice(alloc, text);
    }

    /// One SGR sequence restoring the active attributes, appended to `out`.
    /// Nothing is appended when everything is already default.
    pub fn writeActive(self: *const SgrState, out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        const plain = !self.bold and !self.dim and !self.italic and !self.underline and
            !self.blink and !self.inverse and !self.hidden and !self.strike;
        if (plain and self.fg.len == 0 and self.bg.len == 0) return;
        try out.appendSlice(alloc, "\x1b[");
        var first = true;
        if (self.bold) try put(out, alloc, &first, "1");
        if (self.dim) try put(out, alloc, &first, "2");
        if (self.italic) try put(out, alloc, &first, "3");
        if (self.underline) try put(out, alloc, &first, "4");
        if (self.blink) try put(out, alloc, &first, "5");
        if (self.inverse) try put(out, alloc, &first, "7");
        if (self.hidden) try put(out, alloc, &first, "8");
        if (self.strike) try put(out, alloc, &first, "9");
        if (self.fg.len > 0) try put(out, alloc, &first, self.fg.slice());
        if (self.bg.len > 0) try put(out, alloc, &first, self.bg.slice());
        try out.appendSlice(alloc, "m");
    }

    /// Apply one complete SGR sequence (`ESC [ ... m`).
    pub fn apply(self: *SgrState, seq: []const u8) void {
        if (seq.len < 3 or seq[0] != 0x1b or seq[1] != '[' or seq[seq.len - 1] != 'm') return;
        const body = seq[2 .. seq.len - 1];
        var it = std.mem.splitScalar(u8, body, ';');
        while (true) {
            const p = it.next() orelse break;
            if (p.len == 0) {
                self.reset();
                continue;
            }
            const code = std.fmt.parseInt(u16, p, 10) catch {
                // Colon sub-parameter form ("4:3", "38:2:R:G:B"): the common
                // cases, everything else ignored.
                if (std.mem.startsWith(u8, p, "4:")) {
                    self.underline = !std.mem.startsWith(u8, p, "4:0");
                } else if (std.mem.startsWith(u8, p, "38:")) {
                    self.fg.set(p);
                } else if (std.mem.startsWith(u8, p, "48:")) {
                    self.bg.set(p);
                }
                continue;
            };
            switch (code) {
                0 => self.reset(),
                1 => self.bold = true,
                2 => self.dim = true,
                3 => self.italic = true,
                4 => self.underline = true,
                5, 6 => self.blink = true,
                7 => self.inverse = true,
                8 => self.hidden = true,
                9 => self.strike = true,
                21 => self.underline = true, // double underline
                22 => {
                    self.bold = false;
                    self.dim = false;
                },
                23 => self.italic = false,
                24 => self.underline = false,
                25 => self.blink = false,
                27 => self.inverse = false,
                28 => self.hidden = false,
                29 => self.strike = false,
                30...37, 90...97 => self.fg.set(p),
                39 => self.fg.clear(),
                40...47, 100...107 => self.bg.set(p),
                49 => self.bg.clear(),
                // Extended colour: "n;5;idx" (256) or "n;2;r;g;b" (RGB).
                // 58 (underline colour) consumes args but is not tracked.
                38, 48, 58 => {
                    var buf: [32]u8 = undefined;
                    const kind = it.next() orelse break;
                    if (std.mem.eql(u8, kind, "5")) {
                        const idx = it.next() orelse break;
                        const s = std.fmt.bufPrint(&buf, "{s};5;{s}", .{ p, idx }) catch break;
                        if (code == 38) self.fg.set(s);
                        if (code == 48) self.bg.set(s);
                    } else if (std.mem.eql(u8, kind, "2")) {
                        const r = it.next() orelse break;
                        const g = it.next() orelse break;
                        const b = it.next() orelse break;
                        const s = std.fmt.bufPrint(&buf, "{s};2;{s};{s};{s}", .{ p, r, g, b }) catch break;
                        if (code == 38) self.fg.set(s);
                        if (code == 48) self.bg.set(s);
                    }
                },
                else => {},
            }
        }
    }
};

/// End (exclusive) of the escape sequence starting at `i` (`line[i]` is ESC):
/// CSI `ESC [ ... final`, a string sequence `ESC ] ...` (OSC; also APC, DCS,
/// PM) ended by BEL or ST, or a two-byte escape.
pub fn escapeEnd(line: []const u8, i: usize) usize {
    if (i + 1 >= line.len) return line.len;
    switch (line[i + 1]) {
        '[' => {
            var k = i + 2;
            while (k < line.len) : (k += 1) {
                if (line[k] >= 0x40 and line[k] <= 0x7E) return k + 1;
            }
            return line.len;
        },
        ']', '_', 'P', '^' => {
            var k = i + 2;
            while (k < line.len) : (k += 1) {
                if (line[k] == 0x07) return k + 1;
                if (line[k] == 0x1b and k + 1 < line.len and line[k + 1] == '\\') return k + 2;
            }
            return line.len;
        },
        else => return i + 2,
    }
}

/// Reverse-video the columns [start_col, end_col) of a styled line (pi:
/// applySelectionHighlight): the segment is wrapped in \x1b[7m …\x1b[27m,
/// with [7m re-applied after every embedded SGR code so inner colors don't
/// cancel the inversion. The result is owned.
pub fn applySelectionHighlight(alloc: std.mem.Allocator, line: []const u8, start_col: usize, end_col: usize) ![]u8 {
    const sel = try sliceByColumn(alloc, line, start_col, end_col -| start_col);
    defer alloc.free(sel);
    const before = try sliceByColumn(alloc, line, 0, start_col);
    defer alloc.free(before);
    const after = try sliceByColumn(alloc, line, end_col, 1 << 30);
    defer alloc.free(after);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, before);
    try out.appendSlice(alloc, "\x1b[7m");
    var i: usize = 0;
    while (i < sel.len) {
        if (sel[i] == 0x1b) {
            const seq_end = escapeEnd(sel, i);
            try out.appendSlice(alloc, sel[i..seq_end]);
            // An SGR code resets attributes; re-assert the inversion.
            if (sel[seq_end - 1] == 'm') try out.appendSlice(alloc, "\x1b[7m");
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(sel, i);
        try out.appendSlice(alloc, sel[i..ce]);
        i = ce;
    }
    try out.appendSlice(alloc, "\x1b[27m");
    try out.appendSlice(alloc, after);
    return out.toOwnedSlice(alloc);
}

/// Overlay the styled text `top` (visual width `top_w`) onto `base` starting
/// at visual column `col` (pi: compositeTuiLine with strict slicing): the
/// base content left of the overlay (space-padded to `col`), a reset, the
/// overlay, a reset, then the base content right of the overlay with the
/// styling the base had active there replayed. Wide characters straddling a
/// boundary are dropped, like pi's strict column slicing.
pub fn overlay(
    alloc: std.mem.Allocator,
    base: []const u8,
    top: []const u8,
    top_w: usize,
    col: usize,
) ![]u8 {
    var before: std.ArrayListUnmanaged(u8) = .empty;
    defer before.deinit(alloc);
    var after: std.ArrayListUnmanaged(u8) = .empty;
    defer after.deinit(alloc);
    // Codes seen left of the overlay are held until a grapheme actually
    // lands in the before segment (pi: pendingAnsiBefore); trailing codes
    // with no following text are dropped.
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(alloc);

    var state = SgrState{};
    const after_start = col + top_w;
    var before_w: usize = 0;
    var cur: usize = 0; // current visual column
    var after_started = false;
    var i: usize = 0;
    while (i < base.len) {
        if (base[i] == 0x1b) {
            const seq_end = escapeEnd(base, i);
            const seq = base[i..seq_end];
            state.apply(seq);
            if (cur < col) {
                try pending.appendSlice(alloc, seq);
            } else if (cur >= after_start and after_started) {
                try after.appendSlice(alloc, seq);
            }
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(base, i);
        const w: usize = wmod.visualWidth(base[i..ce]);
        if (cur < col and cur + w <= col) {
            try before.appendSlice(alloc, pending.items);
            pending.clearRetainingCapacity();
            try before.appendSlice(alloc, base[i..ce]);
            before_w += w;
        } else if (cur >= after_start) {
            if (!after_started) {
                after_started = true;
                try state.writeActive(&after, alloc);
            }
            try after.appendSlice(alloc, base[i..ce]);
        }
        cur += w;
        i = ce;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, before.items);
    if (before_w < col) try out.appendNTimes(alloc, ' ', col - before_w);
    try out.appendSlice(alloc, RESET);
    try out.appendSlice(alloc, top);
    try out.appendSlice(alloc, RESET);
    try out.appendSlice(alloc, after.items);
    return out.toOwnedSlice(alloc);
}

/// Replace the cell at visual column `col` of `base` with `glyph` (a styled
/// string of width 1), keeping everything else (pi: replaceScrollbarCell).
/// With `preserve_bg` the cell keeps the background the base line had there,
/// so a scrollbar drawn over a full-width background row leaves no hole. A
/// wide character under the column is replaced whole and padded with spaces
/// carrying the same background.
pub fn replaceCell(
    alloc: std.mem.Allocator,
    base: []const u8,
    col: usize,
    glyph: []const u8,
    preserve_bg: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var state = SgrState{};
    var cur: usize = 0;
    var i: usize = 0;
    // The grapheme occupying the column (wide characters are replaced whole).
    var target_start = col;
    var target_end = col + 1;
    var found = false;
    while (i < base.len) {
        if (base[i] == 0x1b) {
            const seq_end = escapeEnd(base, i);
            state.apply(base[i..seq_end]);
            try out.appendSlice(alloc, base[i..seq_end]);
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(base, i);
        const w: usize = wmod.visualWidth(base[i..ce]);
        if (cur + w > col and w > 0) {
            target_start = cur;
            target_end = cur + w;
            found = true;
            i = ce;
            cur += w;
            break;
        }
        try out.appendSlice(alloc, base[i..ce]);
        cur += w;
        i = ce;
    }
    if (!found and cur < col) try out.appendNTimes(alloc, ' ', col - cur);
    try out.appendSlice(alloc, RESET);
    // The background the cell had (its grapheme may start left of `col`).
    if (preserve_bg and found and state.bg.len > 0) {
        try out.appendSlice(alloc, "\x1b[");
        try out.appendSlice(alloc, state.bg.slice());
        try out.append(alloc, 'm');
    }
    try out.appendNTimes(alloc, ' ', col - target_start);
    try out.appendSlice(alloc, glyph);
    try out.appendNTimes(alloc, ' ', target_end - col - 1);
    try out.appendSlice(alloc, RESET);
    // The rest of the line, with the styling it had there replayed.
    var after_started = false;
    while (i < base.len) {
        if (base[i] == 0x1b) {
            const seq_end = escapeEnd(base, i);
            state.apply(base[i..seq_end]);
            if (after_started) try out.appendSlice(alloc, base[i..seq_end]);
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(base, i);
        if (!after_started) {
            after_started = true;
            try state.writeActive(&out, alloc);
        }
        try out.appendSlice(alloc, base[i..ce]);
        i = ce;
    }
    return out.toOwnedSlice(alloc);
}

/// The bytes that replace ONLY the cell(s) at `col` — the same replacement
/// `replaceCell` performs, without the surrounding line content. Returns the
/// column the replacement starts at (a wide grapheme may straddle into `col`
/// from the left; the included pad spaces cover the gap). Callers composite
/// onto a screen that already shows the rest of the row (pi:
/// replaceScrollbarCell's middle section).
pub fn cellReplacement(
    alloc: std.mem.Allocator,
    base: []const u8,
    col: usize,
    glyph: []const u8,
    preserve_bg: bool,
) !struct { bytes: []u8, start_col: usize } {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var state = SgrState{};
    var cur: usize = 0;
    var i: usize = 0;
    // The grapheme occupying the column (wide characters are replaced whole).
    var target_start = col;
    var target_end = col + 1;
    var found = false;
    while (i < base.len) {
        if (base[i] == 0x1b) {
            const seq_end = escapeEnd(base, i);
            state.apply(base[i..seq_end]);
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(base, i);
        const w: usize = wmod.visualWidth(base[i..ce]);
        if (cur + w > col and w > 0) {
            target_start = cur;
            target_end = cur + w;
            found = true;
            break;
        }
        cur += w;
        i = ce;
        if (cur > col) break;
    }
    try out.appendSlice(alloc, RESET);
    // The background the cell had (its grapheme may start left of `col`).
    if (preserve_bg and found and state.bg.len > 0) {
        try out.appendSlice(alloc, "\x1b[");
        try out.appendSlice(alloc, state.bg.slice());
        try out.append(alloc, 'm');
    }
    try out.appendNTimes(alloc, ' ', col - target_start);
    try out.appendSlice(alloc, glyph);
    try out.appendNTimes(alloc, ' ', target_end - col - 1);
    try out.appendSlice(alloc, RESET);
    return .{ .bytes = try out.toOwnedSlice(alloc), .start_col = target_start };
}

/// Remove every escape sequence, keeping the visible characters
/// (pi: stripTerminalSequences). The result is owned.
pub fn stripSequences(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, line, 0x1b) == null) return alloc.dupe(u8, line);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            i = escapeEnd(line, i);
            continue;
        }
        const ce = wmod.nextCharEnd(line, i);
        try out.appendSlice(alloc, line[i..ce]);
        i = ce;
    }
    return out.toOwnedSlice(alloc);
}

/// Extract the visible columns `[start_col, start_col+length)` of a styled
/// line, keeping the ANSI codes inside the range (pi: sliceWithWidth with
/// strict = true: a wide character straddling a boundary is dropped). The
/// result is owned.
pub fn sliceByColumn(alloc: std.mem.Allocator, line: []const u8, start_col: usize, length: usize) ![]u8 {
    if (length <= 0) return alloc.dupe(u8, "");
    const end_col = start_col + length;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(alloc);

    var cur: usize = 0; // current visual column
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            const seq_end = escapeEnd(line, i);
            if (cur >= start_col and cur < end_col) {
                try out.appendSlice(alloc, pending.items);
                pending.clearRetainingCapacity();
                try out.appendSlice(alloc, line[i..seq_end]);
            } else if (cur < start_col) {
                try pending.appendSlice(alloc, line[i..seq_end]);
            }
            i = seq_end;
            continue;
        }
        const ce = wmod.nextCharEnd(line, i);
        const w: usize = wmod.visualWidth(line[i..ce]);
        const fits = w != 2 or cur + w <= end_col; // strict: drop straddling wide chars
        if (cur >= start_col and cur < end_col and fits) {
            try out.appendSlice(alloc, pending.items);
            pending.clearRetainingCapacity();
            try out.appendSlice(alloc, line[i..ce]);
        }
        cur += w;
        i = ce;
        if (cur >= end_col) break;
    }
    return out.toOwnedSlice(alloc);
}

test "overlay splits a plain line" {
    const alloc = std.heap.page_allocator;
    const r = try overlay(alloc, "hello world", "XY", 2, 3);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("hel\x1b[0mXY\x1b[0m world", r);
}

test "overlay replays the active colour after the overlay" {
    const alloc = std.heap.page_allocator;
    const base = "\x1b[31mredgreen\x1b[0m";
    const r = try overlay(alloc, base, "XY", 2, 3);
    defer alloc.free(r);
    // Columns 3-4 ("gr") sit under the overlay; "een" keeps the red colour.
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[0mXY\x1b[0m\x1b[31meen\x1b[0m", r);
}

test "overlay pads when the base line is shorter than the column" {
    const alloc = std.heap.page_allocator;
    const r = try overlay(alloc, "ab", "XY", 2, 5);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("ab   \x1b[0mXY\x1b[0m", r);
}

test "overlay drops a wide character straddling the boundary" {
    const alloc = std.heap.page_allocator;
    // 中 occupies columns 0-1 and straddles the cut at column 1; the 'a' at
    // column 2 lies under the two-column overlay. Both are dropped.
    const r = try overlay(alloc, "\xE4\xB8\xADa", "XY", 2, 1);
    defer alloc.free(r);
    try std.testing.expectEqualStrings(" \x1b[0mXY\x1b[0m", r);
}

test "overlay keeps a background row's right padding painted" {
    const alloc = std.heap.page_allocator;
    const bg = "\x1b[48;2;33;59;73m";
    var buf: [64]u8 = undefined;
    // A full-width background row: " ab" plus trailing padded spaces.
    const base = try std.fmt.bufPrint(&buf, "{s} ab    {s}", .{ bg, "\x1b[0m" });
    const r = try overlay(alloc, base, "XY", 2, 3);
    defer alloc.free(r);
    // Columns 3-4 sit under the overlay; the padded spaces at columns 5-6
    // remain and must get the background back.
    try std.testing.expectEqualStrings(
        bg ++ " ab\x1b[0mXY\x1b[0m" ++ bg ++ "  \x1b[0m",
        r,
    );
}

test "overlay drops trailing base codes without following text" {
    const alloc = std.heap.page_allocator;
    const r = try overlay(alloc, "ab\x1b[31m", "XY", 2, 2);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("ab\x1b[0mXY\x1b[0m", r);
}

test "escapeEnd finds the end of CSI, OSC and two-byte escapes" {
    try std.testing.expectEqual(@as(usize, 5), escapeEnd("\x1b[31mx", 0));
    try std.testing.expectEqual(@as(usize, 18), escapeEnd("\x1b[38;2;33;59;73;1mx", 0));
    // OSC 8 hyperlink, BEL- and ST-terminated.
    try std.testing.expectEqual(@as(usize, 6), escapeEnd("\x1b]8;;\x07x", 0));
    try std.testing.expectEqual(@as(usize, 7), escapeEnd("\x1b]8;;\x1b\\x", 0));
    try std.testing.expectEqual(@as(usize, 2), escapeEnd("\x1b7x", 0));
    // Truncated sequences end with the line.
    try std.testing.expectEqual(@as(usize, 4), escapeEnd("\x1b[31", 0));
    try std.testing.expectEqual(@as(usize, 1), escapeEnd("\x1b", 0));
    try std.testing.expectEqual(@as(usize, 5), escapeEnd("a\x1b[1mb", 1));
}

test "replaceCell swaps one cell and keeps the rest" {
    const alloc = std.heap.page_allocator;
    const mid = try replaceCell(alloc, "hello", 2, "X", false);
    defer alloc.free(mid);
    try std.testing.expectEqualStrings("he\x1b[0mX\x1b[0mlo", mid);
    const last = try replaceCell(alloc, "abc", 2, "X", false);
    defer alloc.free(last);
    try std.testing.expectEqualStrings("ab\x1b[0mX\x1b[0m", last);
    // A line that ends before the column is padded up to it.
    const short = try replaceCell(alloc, "ab", 5, "X", true);
    defer alloc.free(short);
    try std.testing.expectEqualStrings("ab   \x1b[0mX\x1b[0m", short);
    // Styling right of the cell is replayed.
    const styled = try replaceCell(alloc, "\x1b[31mabc\x1b[0m", 1, "X", false);
    defer alloc.free(styled);
    try std.testing.expectEqualStrings("\x1b[31ma\x1b[0mX\x1b[0m\x1b[31mc\x1b[0m", styled);
}

test "replaceCell keeps the cell's background when asked" {
    const alloc = std.heap.page_allocator;
    const bg = "\x1b[48;2;33;59;73m";
    const base = bg ++ "ab  \x1b[0m"; // a full-width background row, 4 columns
    // An overlaid scrollbar (auto) leaves no hole in the row's background.
    const kept = try replaceCell(alloc, base, 3, "X", true);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings(bg ++ "ab \x1b[0m" ++ bg ++ "X\x1b[0m", kept);
    // A reserved column (always) owns its cell outright.
    const owned = try replaceCell(alloc, base, 3, "X", false);
    defer alloc.free(owned);
    try std.testing.expectEqualStrings(bg ++ "ab \x1b[0mX\x1b[0m", owned);
}

test "replaceCell replaces a wide character whole" {
    const alloc = std.heap.page_allocator;
    const zhong = "\xE4\xB8\xAD"; // 中: columns 1-2 of "a中b"
    const right_half = try replaceCell(alloc, "a" ++ zhong ++ "b", 2, "X", false);
    defer alloc.free(right_half);
    try std.testing.expectEqualStrings("a\x1b[0m X\x1b[0mb", right_half);
    const left_half = try replaceCell(alloc, "a" ++ zhong ++ "b", 1, "X", false);
    defer alloc.free(left_half);
    try std.testing.expectEqualStrings("a\x1b[0mX \x1b[0mb", left_half);
}

test "SgrState tracks bold and colours independently" {
    var s = SgrState{};
    s.apply("\x1b[1m");
    s.apply("\x1b[38;2;33;59;73m");
    try std.testing.expect(s.bold);
    try std.testing.expectEqualStrings("38;2;33;59;73", s.fg.slice());
    s.apply("\x1b[22m"); // bold off, colour stays
    try std.testing.expect(!s.bold);
    try std.testing.expectEqualStrings("38;2;33;59;73", s.fg.slice());
    s.apply("\x1b[48;5;9m");
    try std.testing.expectEqualStrings("48;5;9", s.bg.slice());
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    try s.writeActive(&out, std.heap.page_allocator);
    try std.testing.expectEqualStrings("\x1b[38;2;33;59;73;48;5;9m", out.items);
    s.apply("\x1b[0m");
    try std.testing.expect(!s.bold);
    try std.testing.expectEqual(@as(usize, 0), s.fg.len);
}

test "SgrState clears on empty sequence and basic colours" {
    var s = SgrState{};
    s.apply("\x1b[1;31;44m");
    try std.testing.expect(s.bold);
    try std.testing.expectEqualStrings("31", s.fg.slice());
    try std.testing.expectEqualStrings("44", s.bg.slice());
    s.apply("\x1b[m");
    try std.testing.expect(!s.bold);
    try std.testing.expectEqual(@as(usize, 0), s.fg.len);
    try std.testing.expectEqual(@as(usize, 0), s.bg.len);
    s.apply("\x1b[39m"); // clearing an already-default colour is a no-op
    try std.testing.expectEqual(@as(usize, 0), s.fg.len);
}
