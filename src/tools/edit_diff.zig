const std = @import("std");

/// One targeted replacement. `old` is matched against the original file
/// (LF-normalized), `new` is the replacement. Both are owned by the caller.
pub const Error = error{
    NoEdits,
    EmptyOldText,
    NotFound,
    Duplicate,
    Overlap,
    NoChange,
    OutOfMemory,
};

pub const Edit = struct {
    old: []const u8,
    new: []const u8,
};

/// A matched edit region in the base (match) content.
pub const Match = struct {
    edit_index: usize,
    /// Byte offset of the match in `ApplyResult.base_content`.
    match_index: usize,
    /// Byte length of the matched old text.
    match_length: usize,
    /// The replacement text (LF-normalized).
    new_text: []const u8,
};

/// Result of applying edits. `base_content` is the content the edits were
/// matched against; `new_content` is the result. Both are owned (heap).
pub const ApplyResult = struct {
    base_content: []const u8,
    new_content: []const u8,
    /// Matched regions sorted by position (used for diff rendering).
    matches: []const Match,
};

/// Strip a leading UTF-8 BOM (EF BB BF). The model never includes the invisible
/// BOM in oldText, so it must be removed before matching and restored after.
pub fn splitBom(text: []const u8) struct { bom: []const u8, text: []const u8 } {
    if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) {
        return .{ .bom = text[0..3], .text = text[3..] };
    }
    return .{ .bom = &[_]u8{}, .text = text };
}

/// Detect the dominant line ending. Returns "\r\n" if CRLF appears before the
/// first bare LF, otherwise "\n".
pub fn detectLineEnding(content: []const u8) []const u8 {
    const crlf = std.mem.indexOf(u8, content, "\r\n");
    const lf = std.mem.indexOfScalar(u8, content, '\n');
    if (lf == null) return "\n";
    if (crlf == null) return "\n";
    return if (crlf.? < lf.?) "\r\n" else "\n";
}

/// Replace CRLF and bare CR with LF.
pub fn normalizeToLF(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            out.append('\n') catch return error.OutOfMemory;
        } else {
            out.append(c) catch return error.OutOfMemory;
        }
    }
    return try out.toOwnedSlice();
}

/// If `ending` is CRLF, convert LF back to CRLF; otherwise return a copy.
pub fn restoreLineEndings(alloc: std.mem.Allocator, text: []const u8, ending: []const u8) ![]u8 {
    if (std.mem.eql(u8, ending, "\n")) return try alloc.dupe(u8, text);
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    for (text) |c| {
        if (c == '\n') {
            out.append('\r') catch return error.OutOfMemory;
            out.append('\n') catch return error.OutOfMemory;
        } else {
            out.append(c) catch return error.OutOfMemory;
        }
    }
    return try out.toOwnedSlice();
}

/// Normalize text for fuzzy matching, preserving the line count:
/// - strip trailing whitespace from each line
/// - smart quotes / dashes / special spaces → ASCII equivalents
/// (Full NFKC is approximated by the explicit char mappings below.)
pub fn normalizeForFuzzyMatch(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var line_start: usize = 0;
    while (line_start <= text.len) {
        // Find the end of the current line (next '\n' or end of text).
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') line_end += 1;
        const at_end = line_end == text.len;
        // Find the byte offset where trailing whitespace begins (end of the
        // last non-whitespace codepoint on the line).
        var content_end = line_start;
        var k: usize = line_start;
        while (k < line_end) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[k]) catch 1;
            const cp = std.unicode.utf8Decode(text[k .. k + cp_len]) catch {
                k += 1;
                continue;
            };
            if (!isFuzzyWs(cp)) content_end = k + cp_len;
            k += cp_len;
        }
        // Emit normalized content for [line_start, content_end).
        var j: usize = line_start;
        while (j < content_end) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[j]) catch 1;
            const cp = std.unicode.utf8Decode(text[j .. j + cp_len]) catch {
                out.appendSlice(text[j..j + 1]) catch return error.OutOfMemory;
                j += 1;
                continue;
            };
            const mapped = mapFuzzyChar(cp) orelse text[j .. j + cp_len];
            out.appendSlice(mapped) catch return error.OutOfMemory;
            j += cp_len;
        }
        if (!at_end) out.append('\n') catch return error.OutOfMemory;
        if (at_end) break;
        line_start = line_end + 1;
    }
    return try out.toOwnedSlice();
}

fn isFuzzyWs(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r';
}

/// Map a codepoint to its ASCII fuzzy equivalent, or null if unchanged.
fn mapFuzzyChar(cp: u21) ?[]const u8 {
    return switch (cp) {
        // Smart single quotes → '
        0x2018, 0x2019, 0x201A, 0x201B => "'",
        // Smart double quotes → "
        0x201C, 0x201D, 0x201E, 0x201F => "\"",
        // Dashes / hyphens / minus → -
        0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => "-",
        // Special spaces → space
        0x00A0, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 => " ",
        else => null,
    };
}

pub const FindResult = struct {
    found: bool,
    index: usize,
    match_length: usize,
    used_fuzzy: bool,
    /// The content space the match was found in (original or fuzzy-normalized).
    content_for_replacement: []const u8,
};

/// Find `old_text` in `content`: exact match first, then fuzzy. When fuzzy is
/// used, the offsets are in the fuzzy-normalized space and `content_for_replacement`
/// is that normalized content.
pub fn fuzzyFindText(alloc: std.mem.Allocator, content: []const u8, old_text: []const u8) !FindResult {
    if (std.mem.indexOf(u8, content, old_text)) |idx| {
        return .{ .found = true, .index = idx, .match_length = old_text.len, .used_fuzzy = false, .content_for_replacement = content };
    }
    const fuzzy_content = try normalizeForFuzzyMatch(alloc, content);
    defer alloc.free(fuzzy_content);
    const fuzzy_old = try normalizeForFuzzyMatch(alloc, old_text);
    defer alloc.free(fuzzy_old);
    if (std.mem.indexOf(u8, fuzzy_content, fuzzy_old)) |idx| {
        return .{ .found = true, .index = idx, .match_length = fuzzy_old.len, .used_fuzzy = true, .content_for_replacement = fuzzy_content };
    }
    return .{ .found = false, .index = 0, .match_length = 0, .used_fuzzy = false, .content_for_replacement = content };
}

/// Count occurrences of `old_text` in `content` (in fuzzy-normalized space, so
/// duplicate detection is whitespace/char-insensitive).
pub fn countOccurrences(alloc: std.mem.Allocator, content: []const u8, old_text: []const u8) !usize {
    const fuzzy_content = try normalizeForFuzzyMatch(alloc, content);
    defer alloc.free(fuzzy_content);
    const fuzzy_old = try normalizeForFuzzyMatch(alloc, old_text);
    defer alloc.free(fuzzy_old);
    if (fuzzy_old.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, fuzzy_content, pos, fuzzy_old)) |p| {
        count += 1;
        pos = p + fuzzy_old.len;
    }
    return count;
}

/// Apply one or more edits to LF-normalized content. All edits are matched
/// against the same base content; if any requires fuzzy matching, the operation
/// runs in fuzzy space and overlays changed lines onto the original so untouched
/// lines keep their original bytes.
pub fn applyEdits(alloc: std.mem.Allocator, normalized_content: []const u8, edits: []const Edit) Error!ApplyResult {
    if (edits.len == 0) return error.NoEdits;
    // Normalize each edit's text to LF. norm_edits owns these strings; they are
    // freed after the match loop (matches keep their own new_text copies).
    var norm_edits = std.array_list.Managed(Edit).init(alloc);
    for (edits) |e| {
        const o = try normalizeToLF(alloc, e.old);
        const n = try normalizeToLF(alloc, e.new);
        if (o.len == 0) {
            alloc.free(o);
            alloc.free(n);
            return error.EmptyOldText;
        }
        if (!appendOwnedEdit(&norm_edits, o, n)) {
            alloc.free(o);
            alloc.free(n);
            return error.OutOfMemory;
        }
    }
    defer {
        for (norm_edits.items) |e| {
            alloc.free(e.old);
            alloc.free(e.new);
        }
        norm_edits.deinit();
    }
    // Determine whether any edit needs fuzzy matching.
    var any_fuzzy = false;
    for (norm_edits.items) |e| {
        if (std.mem.indexOf(u8, normalized_content, e.old) == null) {
            any_fuzzy = true;
            break;
        }
    }
    // The base content for matching.
    const base = if (any_fuzzy) blk: {
        const f = try normalizeForFuzzyMatch(alloc, normalized_content);
        break :blk f;
    } else normalized_content;
    const base_owned = any_fuzzy; // we own `base` only in the fuzzy case
    defer if (base_owned) alloc.free(base);

    // Match every edit against `base`. Each match owns a copy of new_text so it
    // outlives this function (used by the caller for diff rendering).
    var matches = std.array_list.Managed(Match).init(alloc);
    defer matches.deinit();
    for (norm_edits.items, 0..) |e, i| {
        const fr = try fuzzyFindText(alloc, base, e.old);
        if (!fr.found) return error.NotFound;
        const occ = try countOccurrences(alloc, base, e.old);
        if (occ > 1) return error.Duplicate;
        const new_dup = try alloc.dupe(u8, e.new);
        matches.append(.{ .edit_index = i, .match_index = fr.index, .match_length = fr.match_length, .new_text = new_dup }) catch return error.OutOfMemory;
    }
    // Sort by position and check for overlaps.
    std.mem.sort(Match, matches.items, {}, matchLessThan);
    for (matches.items, 0..) |m, i| {
        if (i == 0) continue;
        const prev = matches.items[i - 1];
        if (prev.match_index + prev.match_length > m.match_index) return error.Overlap;
    }

    // Apply.
    var new_content: []u8 = undefined;
    if (any_fuzzy) {
        // Overlay changed line-groups from the fuzzy base onto the original.
        new_content = applyPreservingUnchanged(alloc, normalized_content, base, matches.items) catch |e| {
            // LineCountMismatch is an internal invariant (normalization is
            // line-preserving); surface it as a generic failure.
            return switch (e) {
                error.LineCountMismatch => error.NoChange,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
    } else {
        // Direct byte replacement in reverse order.
        new_content = try applyDirect(alloc, base, matches.items);
    }
    if (std.mem.eql(u8, normalized_content, new_content)) {
        alloc.free(new_content);
        return error.NoChange;
    }
    const matches_owned = try matches.toOwnedSlice();
    return .{ .base_content = normalized_content, .new_content = new_content, .matches = matches_owned };
}

fn matchLessThan(_: void, a: Match, b: Match) bool {
    return a.match_index < b.match_index;
}

fn appendOwnedEdit(al: *std.array_list.Managed(Edit), o: []const u8, n: []const u8) bool {
    al.append(.{ .old = o, .new = n }) catch return false;
    return true;
}

/// Apply replacements directly (byte ranges) in reverse order so offsets stay stable.
fn applyDirect(alloc: std.mem.Allocator, base: []const u8, matches: []const Match) ![]u8 {
    var result = try alloc.dupe(u8, base);
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        const m = matches[i];
        var new_buf = std.array_list.Managed(u8).init(alloc);
        errdefer new_buf.deinit();
        new_buf.appendSlice(result[0..m.match_index]) catch return error.OutOfMemory;
        new_buf.appendSlice(m.new_text) catch return error.OutOfMemory;
        new_buf.appendSlice(result[m.match_index + m.match_length ..]) catch return error.OutOfMemory;
        alloc.free(result);
        result = try new_buf.toOwnedSlice();
    }
    return result;
}

/// Line spans for a piece of content.
const LineSpan = struct { start: usize, end: usize };

fn lineSpans(content: []const u8) []LineSpan {
    var count: usize = if (content.len == 0) 0 else 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    var spans = std.heap.page_allocator.alloc(LineSpan, count) catch @panic("oom");
    var offset: usize = 0;
    var idx: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            spans[idx] = .{ .start = offset, .end = i + 1 };
            offset = i + 1;
            idx += 1;
        }
    }
    // Last line (no trailing newline).
    if (offset < content.len) {
        spans[idx] = .{ .start = offset, .end = content.len };
        idx += 1;
    }
    return spans[0..idx];
}

/// Given a byte offset into `spans`, return the line index containing it.
fn lineIndexAt(spans: []const LineSpan, offset: usize) usize {
    for (spans, 0..) |s, i| {
        if (offset >= s.start and offset < s.end) return i;
    }
    return spans.len - 1;
}

/// Apply replacements matched in `base` (fuzzy space) to `original` (LF space),
/// preserving unchanged line bytes from `original`.
fn applyPreservingUnchanged(alloc: std.mem.Allocator, original: []const u8, base: []const u8, matches: []const Match) ![]u8 {
    const base_spans = lineSpans(base);
    defer std.heap.page_allocator.free(base_spans);
    const orig_spans = lineSpans(original);
    defer std.heap.page_allocator.free(orig_spans);
    if (base_spans.len != orig_spans.len) return error.LineCountMismatch;

    // Build groups of line ranges (merge overlapping/adjacent matches).
    var groups = std.array_list.Managed(struct { start_line: usize, end_line: usize }).init(alloc);
    defer groups.deinit();
    for (matches) |m| {
        const start_line = lineIndexAt(base_spans, m.match_index);
        const end_offset = m.match_index + m.match_length;
        var end_line = start_line;
        while (end_line < base_spans.len and base_spans[end_line].end < end_offset) end_line += 1;
        end_line += 1; // exclusive
        const last = groups.items.len;
        if (last > 0 and start_line < groups.items[last - 1].end_line) {
            groups.items[last - 1].end_line = @max(groups.items[last - 1].end_line, end_line);
        } else {
            groups.append(.{ .start_line = start_line, .end_line = end_line }) catch return error.OutOfMemory;
        }
    }

    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var cursor_line: usize = 0;
    for (groups.items) |g| {
        // Unchanged original lines before this group.
        for (orig_spans[cursor_line..g.start_line]) |s| {
            out.appendSlice(original[s.start..s.end]) catch return error.OutOfMemory;
        }
        // The group's region, taken from the fuzzy base with replacements applied.
        const g_start = base_spans[g.start_line].start;
        const g_end = base_spans[g.end_line - 1].end;
        var replaced: []u8 = try alloc.dupe(u8, base[g_start..g_end]);
        // Apply this group's matches (in reverse), offsets relative to g_start.
        var i = matches.len;
        while (i > 0) {
            i -= 1;
            const m = matches[i];
            if (m.match_index < g_start or m.match_index >= g_end) continue;
            const rel = m.match_index - g_start;
            const nb = buildReplaced(alloc, replaced, rel, m.new_text, m.match_length) catch {
                alloc.free(replaced);
                return error.OutOfMemory;
            };
            alloc.free(replaced);
            replaced = nb;
        }
        out.appendSlice(replaced) catch {
            alloc.free(replaced);
            return error.OutOfMemory;
        };
        alloc.free(replaced);
        cursor_line = g.end_line;
    }
    // Unchanged original lines after the last group.
    for (orig_spans[cursor_line..]) |s| {
        out.appendSlice(original[s.start..s.end]) catch return error.OutOfMemory;
    }
    return try out.toOwnedSlice();
}

/// Return `current` with [rel, rel+match_length) replaced by `new_text`.
fn buildReplaced(alloc: std.mem.Allocator, current: []const u8, rel: usize, new_text: []const u8, match_length: usize) ![]u8 {
    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    buf.appendSlice(current[0..rel]) catch return error.OutOfMemory;
    buf.appendSlice(new_text) catch return error.OutOfMemory;
    buf.appendSlice(current[rel + match_length ..]) catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

/// Generate a display-oriented diff with line numbers and limited context
/// (4 lines before/after changes; long unchanged runs collapsed with "...").
pub fn generateDiffString(alloc: std.mem.Allocator, base_content: []const u8, new_content: []const u8, matches: []const Match) ![]u8 {
    const base_spans = lineSpans(base_content);
    defer std.heap.page_allocator.free(base_spans);
    const new_lines = splitLines(new_content);
    defer std.heap.page_allocator.free(new_lines);

    const max_num = @max(base_spans.len, new_lines.len);
    const num_width = digitCount(@max(max_num, 1));

    // Build the sequence of new lines aligned with the matches. For each match,
    // the new_text contributes its own lines. We render segment by segment.
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();

    var old_num: usize = 1;
    var new_num: usize = 1;
    var last_was_change = false;

    // Precompute, for each base line, whether it is "touched" by a match, and
    // the new lines that replace each match.
    var cursor_line: usize = 0;
    for (matches) |m| {
        const start_line = lineIndexAt(base_spans, m.match_index);
        const end_offset = m.match_index + m.match_length;
        var end_line = start_line;
        while (end_line < base_spans.len and base_spans[end_line].end < end_offset) end_line += 1;
        end_line += 1;
        // Context before the change (up to 4 lines).
        const ctx_before_start = @max(start_line, if (start_line > 4) start_line - 4 else 0);
        // Only show leading context if there was a preceding change or it's the first.
        if (last_was_change or cursor_line == 0) {
            const from = if (last_was_change) ctx_before_start else @max(0, if (base_spans.len > 4) base_spans.len - 4 else 0);
            _ = from;
        }
        // Render leading context (last 4 lines before the change).
        const lead_from = if (start_line > 4) start_line - 4 else 0;
        const show_lead = last_was_change or cursor_line == 0;
        if (show_lead) {
            const skip = start_line - lead_from - (if (last_was_change) 0 else @min(4, start_line));
            _ = skip;
            for (base_spans[lead_from..start_line]) |s| {
                const ln = base_content[s.start..s.end];
                const trimmed = std.mem.trimEnd(u8, ln, " \t\r\n");
                appendNumLine(&out, " ", old_num, num_width, trimmed) catch return error.OutOfMemory;
                old_num += 1;
                new_num += 1;
            }
        } else if (start_line > lead_from) {
            // Long gap before change: show "..." then 4 context lines.
            const gap = start_line - lead_from;
            if (gap > 4) {
                appendNumLine(&out, " ", 0, num_width, "...") catch return error.OutOfMemory;
                old_num += gap - 4;
                new_num += gap - 4;
            }
            for (base_spans[start_line - 4 .. start_line]) |s| {
                const ln = base_content[s.start..s.end];
                const trimmed = std.mem.trimEnd(u8, ln, " \t\r\n");
                appendNumLine(&out, " ", old_num, num_width, trimmed) catch return error.OutOfMemory;
                old_num += 1;
                new_num += 1;
            }
        }
        // Removed lines.
        for (base_spans[start_line..end_line]) |s| {
            const ln = base_content[s.start..s.end];
            const trimmed = std.mem.trimEnd(u8, ln, " \t\r\n");
            appendNumLine(&out, "-", old_num, num_width, trimmed) catch return error.OutOfMemory;
            old_num += 1;
        }
        // Added lines.
        for (splitLines(m.new_text)) |nl| {
            appendNumLine(&out, "+", new_num, num_width, nl) catch return error.OutOfMemory;
            new_num += 1;
        }
        last_was_change = true;
        cursor_line = end_line;
    }
    // Trailing context (first 4 lines after the last change).
    if (last_was_change and cursor_line < base_spans.len) {
        const to = @min(base_spans.len, cursor_line + 4);
        for (base_spans[cursor_line..to]) |s| {
            const ln = base_content[s.start..s.end];
            const trimmed = std.mem.trimEnd(u8, ln, " \t\r\n");
            appendNumLine(&out, " ", old_num, num_width, trimmed) catch return error.OutOfMemory;
            old_num += 1;
            new_num += 1;
        }
        if (to < base_spans.len) appendNumLine(&out, " ", 0, num_width, "...") catch return error.OutOfMemory;
    }
    return try out.toOwnedSlice();
}

fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var c: usize = 0;
    var x = n;
    while (x > 0) {
        c += 1;
        x /= 10;
    }
    return c;
}

fn appendNumLine(out: *std.array_list.Managed(u8), marker: []const u8, num: usize, width: usize, line: []const u8) !void {
    out.appendSlice(marker) catch return error.OutOfMemory;
    const num_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{num}) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(num_str);
    // Pad to width.
    var pad: usize = width - num_str.len;
    while (pad > 0) {
        out.append(' ') catch return error.OutOfMemory;
        pad -= 1;
    }
    out.appendSlice(num_str) catch return error.OutOfMemory;
    out.append(' ') catch return error.OutOfMemory;
    out.appendSlice(line) catch return error.OutOfMemory;
    out.append('\n') catch return error.OutOfMemory;
}

fn splitLines(content: []const u8) [][]const u8 {
    // Count lines.
    var count: usize = if (content.len == 0) 0 else 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    var arr = std.heap.page_allocator.alloc([]const u8, count) catch @panic("oom");
    var idx: usize = 0;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            arr[idx] = content[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    if (start < content.len) {
        arr[idx] = content[start..];
        idx += 1;
    }
    return arr[0..idx];
}

test "splitBom" {
    const r = splitBom("\xEF\xBB\xBFhello");
    try std.testing.expectEqualStrings("hello", r.text);
    try std.testing.expectEqual(@as(usize, 3), r.bom.len);
    const r2 = splitBom("hello");
    try std.testing.expectEqualStrings("hello", r2.text);
}

test "normalizeToLF" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = try normalizeToLF(alloc, "a\r\nb\rc\nd");
    try std.testing.expectEqualStrings("a\nb\nc\nd", r);
}

test "fuzzyMatch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Trailing whitespace difference.
    const content = try normalizeToLF(alloc, "foo   \nbar\nbaz");
    const r = try fuzzyFindText(alloc, content, "foo\nbar");
    try std.testing.expect(r.found);
    try std.testing.expect(r.used_fuzzy);
    // Smart quote difference.
    const content2 = try normalizeToLF(alloc, "say \u{201C}hi\u{201D}");
    const r2 = try fuzzyFindText(alloc, content2, "say \"hi\"");
    try std.testing.expect(r2.found);
}

test "applyEditsExact" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "line1\nline2\nline3\n";
    const edits = [_]Edit{.{ .old = "line2", .new = "LINE-TWO" }};
    const r = try applyEdits(alloc, content, &edits);
    try std.testing.expectEqualStrings("line1\nLINE-TWO\nline3\n", r.new_content);
    alloc.free(r.new_content);
    alloc.free(r.matches);
}

test "applyEditsDuplicate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "x\nx\n";
    const edits = [_]Edit{.{ .old = "x", .new = "y" }};
    try std.testing.expectError(error.Duplicate, applyEdits(alloc, content, &edits));
}

test "diffString" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = "a\nb\nc\nd\n";
    const edits = [_]Edit{.{ .old = "b", .new = "B2\nB3" }};
    const r = try applyEdits(alloc, base, &edits);
    const diff = try generateDiffString(alloc, r.base_content, r.new_content, r.matches);
    // The rows are '\n'-joined: a leading context row, the removal, the two
    // additions, then trailing context. No blank rows between them (line spans
    // include their newline; the renderer and the model both see one row each).
    try std.testing.expectEqualStrings(" 1 a\n-2 b\n+2 B2\n+3 B3\n 3 c\n 4 d\n", diff);
    alloc.free(r.new_content);
    alloc.free(r.matches);
    alloc.free(diff);
}

test "applyEditsFuzzySmartQuotes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // File has smart quotes; oldText uses straight quotes. Exact fails, fuzzy succeeds.
    const content = "alpha\nsay \u{201C}hi\u{201D}\ngamma\n";
    const edits = [_]Edit{.{ .old = "say \"hi\"", .new = "say BYE" }};
    const r = try applyEdits(alloc, content, &edits);
    // Changed line is rewritten; untouched lines keep original bytes.
    try std.testing.expectEqualStrings("alpha\nsay BYE\ngamma\n", r.new_content);
    alloc.free(r.new_content);
    alloc.free(r.matches);
}

test "applyEditsMultiple" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "one\ntwo\nthree\nfour\n";
    const edits = [_]Edit{
        .{ .old = "one", .new = "ONE" },
        .{ .old = "four", .new = "FOUR" },
    };
    const r = try applyEdits(alloc, content, &edits);
    try std.testing.expectEqualStrings("ONE\ntwo\nthree\nFOUR\n", r.new_content);
    alloc.free(r.new_content);
    alloc.free(r.matches);
}

test "crlfRoundTrip" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const crlf = "a\r\nb\r\nc\r\n";
    try std.testing.expectEqualStrings("\r\n", detectLineEnding(crlf));
    const lf = try normalizeToLF(alloc, crlf);
    try std.testing.expectEqualStrings("a\nb\nc\n", lf);
    const restored = try restoreLineEndings(alloc, lf, "\r\n");
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\n", restored);
    alloc.free(lf);
    alloc.free(restored);
}

test "applyEditsNotFound" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = "a\nb\n";
    const edits = [_]Edit{.{ .old = "zzz", .new = "y" }};
    try std.testing.expectError(error.NotFound, applyEdits(alloc, content, &edits));
}
