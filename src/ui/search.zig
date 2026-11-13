//! Transcript search (pi: alt-screen-search.js + components/input.js).
//!
//! A floating three-line box in the top-right corner. The query is matched
//! case-insensitively against a corpus built from the stripped transcript
//! lines; every match is a list of (row, startCol, endCol) segments in
//! content-row coordinates. Enter / Shift+Enter navigate between matches
//! (wrapping) and scroll the selected one into view; the TUI highlights the
//! matches in the visible window, the current one inverted.

const std = @import("std");
const wmod = @import("width.zig");
const overlay = @import("overlay.zig");
const ansi = @import("ansi.zig");
const keys = @import("keys.zig");

const DIM = "\x1b[2m";

/// Match highlighting (pi: theme.underline/bg/fg and theme.bold/inverse over
/// the dark theme's searchMatchBg = okhsl(53 51% 24%) = rgb(78,47,27) and
/// searchMatchText = muted = okhsl(229 6% 67%) = rgb(157,165,169)).
pub const MATCH_STYLE = "\x1b[4;48;2;78;47;27;38;2;157;165;169m";
pub const MATCH_STYLE_RESET = "\x1b[24;39;49m";

/// Append `n` horizontal-rule cells; ─ is multi-byte, so appendNTimes (a
/// single scalar per cell) cannot build it.
fn appendRule(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, n: usize) !void {
    const rule = "─";
    for (0..n) |_| try list.appendSlice(alloc, rule);
}
pub const MATCH_CURRENT_STYLE = "\x1b[1;7;48;2;78;47;27;38;2;157;165;169m";
pub const MATCH_CURRENT_STYLE_RESET = "\x1b[27;39;49;22m";

/// Wrap the plain-text runs of a styled slice in the match style, keeping
/// the ANSI codes inside (pi: applySearchTextHighlight). The result is owned.
pub fn applyMatchStyle(alloc: std.mem.Allocator, text: []const u8, current: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    const style = if (current) MATCH_CURRENT_STYLE else MATCH_STYLE;
    const reset = if (current) MATCH_CURRENT_STYLE_RESET else MATCH_STYLE_RESET;
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            i += 1;
            continue;
        }
        if (i > plain_start) {
            try out.appendSlice(alloc, style);
            try out.appendSlice(alloc, text[plain_start..i]);
            try out.appendSlice(alloc, reset);
        }
        const seq_end = overlay.escapeEnd(text, i);
        try out.appendSlice(alloc, text[i..seq_end]);
        i = seq_end;
        plain_start = i;
    }
    if (plain_start < text.len) {
        try out.appendSlice(alloc, style);
        try out.appendSlice(alloc, text[plain_start..]);
        try out.appendSlice(alloc, reset);
    }
    return out.toOwnedSlice(alloc);
}

test "applyMatchStyle wraps plain runs and keeps codes" {
    const alloc = std.heap.page_allocator;
    const r = try applyMatchStyle(alloc, "ab\x1b[31mcd", false);
    defer alloc.free(r);
    try std.testing.expectEqualStrings(
        MATCH_STYLE ++ "ab" ++ MATCH_STYLE_RESET ++ "\x1b[31m" ++ MATCH_STYLE ++ "cd" ++ MATCH_STYLE_RESET,
        r,
    );
    const r2 = try applyMatchStyle(alloc, "", true);
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

/// One chunk of the corpus: a non-space run of text with its position in the
/// transcript (pi: the spans of buildSearchCorpus).
pub const Span = struct {
    /// Codepoint offsets of this chunk in `Corpus.text`.
    text_start: usize,
    text_end: usize,
    /// Content row (0-based, over the full transcript, not the viewport).
    row: usize,
    start_col: usize,
    end_col: usize,
    /// true: one text unit per column (printable-ASCII run), a match may
    /// split the span. false: one whole character (wide), a match covers it
    /// entirely.
    linear_columns: bool,
};

/// The searchable text of the transcript: every line stripped of escape
/// sequences, whitespace runs collapsed to single spaces (pi:
/// buildSearchCorpus). Text is stored as codepoints so matching needs no
/// grapheme segmenter and stays wide-char aware.
pub const Corpus = struct {
    text: []u21,
    spans: []Span,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Corpus) void {
        self.alloc.free(self.text);
        self.alloc.free(self.spans);
    }
};

/// One visible piece of a match, in content-row coordinates.
pub const Segment = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
};

/// One match of the (normalized) query in the corpus.
pub const Match = struct {
    segments: []Segment,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Match) void {
        self.alloc.free(self.segments);
    }
};

/// Stable identity of a match for selection tracking across corpus changes
/// (pi: getAltScreenSearchMatchKey).
pub const MatchKey = struct {
    first_row: usize,
    first_col: usize,
    last_row: usize,
    last_col: usize,

    pub fn eql(a: MatchKey, b: MatchKey) bool {
        return a.first_row == b.first_row and a.first_col == b.first_col and
            a.last_row == b.last_row and a.last_col == b.last_col;
    }

    pub fn of(m: *const Match) MatchKey {
        return .{
            .first_row = m.segments[0].row,
            .first_col = m.segments[0].start_col,
            .last_row = m.segments[m.segments.len - 1].row,
            .last_col = m.segments[m.segments.len - 1].end_col,
        };
    }
};

/// Case-fold one codepoint (ASCII folding; enough for transcript content).
fn fold(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isWhitespaceCp(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        (c >= 0x0B and c <= 0x0C) or (c >= 0x1C and c <= 0x1F) or
        c == 0x85 or c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or
        c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F or c == 0x3000;
}

fn isPrintableAscii(s: []const u8) bool {
    for (s) |b| if (b < 0x20 or b > 0x7E) return false;
    return true;
}

/// One codepoint of a UTF-8 slice at byte offset `i`; null when truncated.
fn decodeCp(s: []const u8, i: usize) ?struct { u21, usize } {
    const b = s[i];
    if (b < 0x80) return .{ b, 1 };
    const n: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    if (i + n > s.len) return null;
    var r: u21 = if (b >= 0xF0) b & 0x07 else if (b >= 0xE0) b & 0x0F else b & 0x1F;
    var j: usize = 1;
    while (j < n) : (j += 1) {
        const cont = s[i + j];
        if ((cont & 0xC0) != 0x80) return null;
        r = (r << 6) | (cont & 0x3F);
    }
    return .{ r, n };
}

/// Build the searchable corpus of `lines` (pi: buildSearchCorpus). Every
/// line is stripped of escape sequences; non-space runs become chunks with
/// column spans, and whitespace runs collapse to a single space in the text.
pub fn buildSearchCorpus(alloc: std.mem.Allocator, lines: []const []const u8) !Corpus {
    var text: std.ArrayListUnmanaged(u21) = .empty;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer {
        text.deinit(alloc);
        spans.deinit(alloc);
    }
    var pending_separator = false;
    for (lines, 0..) |line, row| {
        const plain = try overlay.stripSequences(alloc, line);
        defer alloc.free(plain);
        var column: usize = 0;
        if (isPrintableAscii(plain)) {
            var i: usize = 0;
            while (i < plain.len) {
                if (plain[i] == ' ') {
                    if (text.items.len > 0) pending_separator = true;
                    column += 1;
                    i += 1;
                    continue;
                }
                var end = i + 1;
                while (end < plain.len and plain[end] != ' ') end += 1;
                if (pending_separator) {
                    try text.append(alloc, ' ');
                    pending_separator = false;
                }
                const start = text.items.len;
                try appendAsciiCps(&text, alloc, plain[i..end]);
                try spans.append(alloc, .{
                    .text_start = start,
                    .text_end = text.items.len,
                    .row = row,
                    .start_col = column,
                    .end_col = column + (end - i),
                    .linear_columns = true,
                });
                column += end - i;
                i = end;
            }
        } else {
            var i: usize = 0;
            while (i < plain.len) {
                const cp = decodeCp(plain, i) orelse break;
                const chunk_w: usize = @intCast(wmod.visualWidth(plain[i .. i + cp[1]]));
                if (isWhitespaceCp(cp[0])) {
                    if (text.items.len > 0) pending_separator = true;
                    column += chunk_w;
                    i += cp[1];
                    continue;
                }
                if (pending_separator) {
                    try text.append(alloc, ' ');
                    pending_separator = false;
                }
                const start = text.items.len;
                try text.append(alloc, cp[0]);
                try spans.append(alloc, .{
                    .text_start = start,
                    .text_end = text.items.len,
                    .row = row,
                    .start_col = column,
                    .end_col = column + chunk_w,
                    .linear_columns = false,
                });
                column += chunk_w;
                i += cp[1];
            }
        }
        if (text.items.len > 0) pending_separator = true;
    }
    return .{
        .text = try text.toOwnedSlice(alloc),
        .spans = try spans.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

fn appendAsciiCps(list: *std.ArrayListUnmanaged(u21), alloc: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |b| try list.append(alloc, b);
}

/// Visual width as usize (a convenience for arithmetic sites).
fn vw(s: []const u8) usize {
    return @intCast(wmod.visualWidth(s));
}

/// Collapse whitespace runs to single spaces and trim (pi: normalizeQuery,
/// `query.replace(/\s+/gu, " ").trim()`).
pub fn normalizeQuery(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < query.len) {
        const cp = decodeCp(query, i) orelse break;
        if (isWhitespaceCp(cp[0])) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(alloc, ' ');
        } else {
            try out.appendSlice(alloc, query[i .. i + cp[1]]);
        }
        i += cp[1];
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

/// All case-insensitive occurrences of `query` (already normalized,
/// non-empty) in `corpus` (pi: findSearchCorpusMatches with an escaped
/// literal pattern).
pub fn findMatches(alloc: std.mem.Allocator, corpus: *const Corpus, query: []const u8) ![]Match {
    var qcps: std.ArrayListUnmanaged(u21) = .empty;
    defer qcps.deinit(alloc);
    var qi: usize = 0;
    while (qi < query.len) {
        const cp = decodeCp(query, qi) orelse break;
        try qcps.append(alloc, fold(cp[0]));
        qi += cp[1];
    }
    const q = qcps.items;
    if (q.len == 0) return &.{};

    var matches: std.ArrayListUnmanaged(Match) = .empty;
    errdefer {
        for (matches.items) |*m| m.deinit();
        matches.deinit(alloc);
    }

    var span_index: usize = 0;
    var start: usize = 0;
    while (start + q.len <= corpus.text.len) {
        // Find the next occurrence at or after `start`.
        var s = start;
        var found = false;
        while (s + q.len <= corpus.text.len) {
            var k: usize = 0;
            while (k < q.len) : (k += 1) {
                if (fold(corpus.text[s + k]) != q[k]) break;
            }
            if (k == q.len) {
                found = true;
                break;
            }
            s += 1;
        }
        if (!found) break;
        const m_start = s;
        const m_end = s + q.len;

        while (span_index < corpus.spans.len and corpus.spans[span_index].text_end <= m_start) span_index += 1;
        var segments: std.ArrayListUnmanaged(Segment) = .empty;
        defer segments.deinit(alloc);
        var index = span_index;
        while (index < corpus.spans.len) : (index += 1) {
            const span = corpus.spans[index];
            if (span.text_start >= m_end) break;
            if (span.text_end <= m_start) continue;
            const sc: usize = if (span.linear_columns)
                span.start_col + @max(m_start, span.text_start) - span.text_start
            else
                span.start_col;
            const ec: usize = if (span.linear_columns)
                span.start_col + @min(m_end, span.text_end) - span.text_start
            else
                span.end_col;
            if (segments.items.len > 0) {
                const p = &segments.items[segments.items.len - 1];
                if (p.row == span.row and sc <= p.end_col) {
                    p.end_col = @max(p.end_col, ec);
                    continue;
                }
            }
            try segments.append(alloc, .{ .row = span.row, .start_col = sc, .end_col = ec });
        }
        while (span_index < corpus.spans.len and corpus.spans[span_index].text_end <= m_end) span_index += 1;
        if (segments.items.len > 0) {
            try matches.append(alloc, .{ .segments = try segments.toOwnedSlice(alloc), .alloc = alloc });
        }
        // Non-overlapping, like pi's matchAll: continue after this match.
        start = m_end;
    }
    return matches.toOwnedSlice(alloc);
}

/// The search state while the box is open (pi: activeSearch + its
/// AltScreenSearchComponent). Owned by the TUI.
pub const Search = struct {
    const Mode = enum { query, next, previous, retain };

    alloc: std.mem.Allocator,
    query: []u8,
    /// Byte offset of the caret in `query`.
    caret: usize,
    matches: []Match,
    /// Selected match index; usize.max when none.
    selected: usize,
    /// Why the selection was last set (pi: selectionMode).
    mode: Mode = .retain,
    /// The content row the "query" selection anchors at (pi: anchorRow).
    anchor_row: usize = 0,
    /// Identity of the selected match, kept across corpus changes (pi:
    /// selectedKey).
    selected_key: ?MatchKey = null,
    /// Corpus cache (pi: AltScreenSearchIndex), keyed by (gen, query).
    corpus: ?Corpus = null,
    corpus_gen: usize = 0,
    corpus_query: []u8 = &.{},
    /// Navigation button hover (pi: hoveredNavigationDirection): -1 up,
    /// +1 down, 0 none.
    hover_dir: i8 = 0,
    /// Navigation button hit-rect, packed for hit-testing: bit 63 set when
    /// shown, bits 48..62 prev start, 32..47 prev end, 16..31 next start,
    /// 0..15 next end (box-relative columns). Rewritten by `render`.
    buttons: u64 = 0,
    /// Box origin (0-based screen column); the row is always BOX_ROW.
    box_col: usize = 0,
    box_width: usize = 0,
    /// Visual column of the caret inside the input line (for the hardware
    /// cursor), recomputed by `render`.
    caret_col: usize = 0,
    /// Set by `refresh` when it returns true: the scrollTop the TUI must
    /// apply (disableFollow) to reveal the selection.
    reveal_scroll_top: usize = 0,

    /// Screen row of the box (pi: top-right overlay with margin 1).
    pub const BOX_ROW: usize = 1;

    pub fn init(alloc: std.mem.Allocator) !Search {
        return .{
            .alloc = alloc,
            .query = try alloc.dupe(u8, ""),
            .caret = 0,
            .matches = &.{},
            .selected = std.math.maxInt(usize),
            .mode = .query,
        };
    }

    pub fn deinit(self: *Search) void {
        self.alloc.free(self.query);
        for (self.matches) |*m| m.deinit();
        self.alloc.free(self.matches);
        if (self.corpus) |*c| c.deinit();
        self.alloc.free(self.corpus_query);
    }

    /// The query changed (typing). Re-anchors the selection at the current
    /// one's first row (pi: updateSearchQuery).
    pub fn setQueryAnchor(self: *Search, scroll_top: usize) void {
        if (self.selected < self.matches.len) {
            self.anchor_row = self.matches[self.selected].segments[0].row;
        } else {
            self.anchor_row = scroll_top;
        }
        self.mode = .query;
    }

    /// Enter / Shift+Enter: next / previous match (pi: navigateSearch).
    pub fn navigate(self: *Search, dir: i8) void {
        self.mode = if (dir < 0) .previous else .next;
    }

    /// Rebuild the corpus/matches when the transcript or the query changed
    /// and pick the selected match (pi: refreshSearch). Returns true when
    /// the selection changed and should be revealed.
    pub fn refresh(
        self: *Search,
        lines: []const []const u8,
        gen: usize,
        scroll_top: usize,
        viewport_h: usize,
    ) bool {
        const q = normalizeQuery(self.alloc, self.query) catch return false;
        // `q` is owned by the caller of this function until the `changed`
        // branch below transfers it to self.corpus_query.
        var q_owned = true;
        defer {
            if (q_owned) self.alloc.free(q);
        }
        if (q.len == 0) {
            self.freeMatches();
            self.selected = std.math.maxInt(usize);
            self.selected_key = null;
            self.mode = .retain;
            return false;
        }
        const source_changed = self.corpus == null or self.corpus_gen != gen;
        const changed = source_changed or !std.mem.eql(u8, self.corpus_query, q);
        if (changed) {
            if (self.corpus) |*c| c.deinit();
            const corpus = buildSearchCorpus(self.alloc, lines) catch return false;
            self.corpus = corpus;
            self.corpus_gen = gen;
            if (self.corpus_query.len > 0) self.alloc.free(self.corpus_query);
            self.corpus_query = q;
            q_owned = false;
            self.freeMatches();
            self.matches = findMatches(self.alloc, &self.corpus.?, q) catch &.{};
        }
        const matches = self.matches;
        const should_reveal = self.mode != .retain;
        if (!changed and self.mode == .retain) return false;

        // Where the previous selection is in the (possibly new) list.
        var exact: isize = -1;
        if (changed) {
            if (self.selected_key) |k| {
                for (matches, 0..) |m, i| {
                    if (MatchKey.eql(MatchKey.of(&m), k)) {
                        exact = @intCast(i);
                        break;
                    }
                }
            }
        } else {
            exact = if (self.selected < matches.len) @as(isize, @intCast(self.selected)) else -1;
        }

        var selected: isize = -1;
        if (matches.len > 0) {
            switch (self.mode) {
                .query => {
                    // First match at or after the anchor (pi: binary search).
                    var low: usize = 0;
                    var high: usize = matches.len;
                    while (low < high) {
                        const mid = low + (high - low) / 2;
                        if (matches[mid].segments[0].row < self.anchor_row) {
                            low = mid + 1;
                        } else {
                            high = mid;
                        }
                    }
                    selected = if (low < matches.len) @as(isize, @intCast(low)) else 0;
                },
                .next => {
                    const base: isize = if (exact >= 0) exact else @as(isize, @intCast(@min(self.selected, @max(0, matches.len - 1))));
                    const m = @as(isize, @intCast(matches.len));
                    selected = if (base < 0) 0 else @mod(base + 1, m);
                },
                .previous => {
                    const base: isize = if (exact >= 0) exact else @as(isize, @intCast(@min(self.selected, @max(0, matches.len - 1))));
                    const n = @as(isize, @intCast(matches.len));
                    selected = if (base < 0) n - 1 else @mod(base - 1 + n, n);
                },
                .retain => {
                    selected = if (exact >= 0) exact else @min(@max(0, @as(isize, @intCast(self.selected))), @as(isize, @intCast(matches.len - 1)));
                },
            }
        }
        self.selected = if (selected >= 0) @intCast(selected) else std.math.maxInt(usize);
        self.selected_key = if (selected >= 0) MatchKey.of(&matches[@intCast(selected)]) else null;
        self.mode = .retain;
        if (!should_reveal) return false;

        // Reveal the selection (pi: the selected match's first row lands a
        // third of the viewport down when it was out of view).
        if (self.selected >= matches.len) return false;
        const first_row = matches[self.selected].segments[0].row;
        const last_row = matches[self.selected].segments[matches[self.selected].segments.len - 1].row;
        if (viewport_h == 0) return false;
        const visible_bottom = scroll_top + viewport_h - 1;
        if (first_row < scroll_top or last_row > visible_bottom) {
            self.reveal_scroll_top = if (first_row > viewport_h / 3) first_row - viewport_h / 3 else 0;
            return true;
        }
        return false;
    }

    fn freeMatches(self: *Search) void {
        for (self.matches) |*m| m.deinit();
        self.alloc.free(self.matches);
        self.matches = &.{};
    }

    /// One keystroke for the input line (pi: Input.handleInput, reduced to
    /// what a search box needs). Returns true when the query changed.
    pub fn handleKey(self: *Search, key: keys.Key) bool {
        switch (key) {
            .backspace => {
                if (self.caret == 0) return false;
                const start = wmod.prevCharStart(self.query, self.caret);
                const next = std.mem.concat(self.alloc, u8, &.{ self.query[0..start], self.query[self.caret..] }) catch return false;
                self.alloc.free(self.query);
                self.query = next;
                self.caret = start;
                return true;
            },
            .left => {
                if (self.caret > 0) self.caret = wmod.prevCharStart(self.query, self.caret);
                return false;
            },
            .right => {
                if (self.caret < self.query.len) self.caret = wmod.nextCharEnd(self.query, self.caret);
                return false;
            },
            .home => {
                self.caret = 0;
                return false;
            },
            .end => {
                self.caret = self.query.len;
                return false;
            },
            .char => |ch| {
                if (ch.ctrl and !ch.alt and ch.c == 'd') {
                    // Ctrl+D: delete the character under the caret (pi:
                    // tui.editor.deleteCharForward).
                    if (self.caret >= self.query.len) return false;
                    const end = wmod.nextCharEnd(self.query, self.caret);
                    const next = std.mem.concat(self.alloc, u8, &.{ self.query[0..self.caret], self.query[end..] }) catch return false;
                    self.alloc.free(self.query);
                    self.query = next;
                    return true;
                }
                // The other modified keys are the TUI's (it intercepts them
                // before routing here); reject control characters (pi:
                // Input's C0/DEL filter).
                if (ch.ctrl or ch.alt) return false;
                if (ch.c < 32 or ch.c == 0x7F) return false;
                const byte = [_]u8{ch.c};
                const next = std.mem.concat(self.alloc, u8, &.{ self.query[0..self.caret], &byte, self.query[self.caret..] }) catch return false;
                self.alloc.free(self.query);
                self.query = next;
                self.caret += 1;
                return true;
            },
            .text => |t| {
                const bytes = t.bytes[0..t.len];
                const cp = decodeCp(bytes, 0) orelse return false;
                // Reject C1 control characters (pi: Input's C1 filter).
                if (cp[0] >= 0x80 and cp[0] <= 0x9F) return false;
                const next = std.mem.concat(self.alloc, u8, &.{ self.query[0..self.caret], bytes, self.query[self.caret..] }) catch return false;
                self.alloc.free(self.query);
                self.query = next;
                self.caret += bytes.len;
                return true;
            },
            else => return false, // navigation keys are intercepted by the TUI
        }
    }

    /// The three box lines at `box_width` (pi: AltScreenSearchComponent
    /// render). `lines[1]` is the input line. The button hit-rect and the
    /// caret column are recorded for the TUI.
    pub const Lines = struct {
        lines: [3][]u8,
        alloc: std.mem.Allocator,

        pub fn deinit(self: *Lines) void {
            for (self.lines) |l| self.alloc.free(l);
        }
    };

    pub fn render(self: *Search, alloc: std.mem.Allocator, width: usize) !Lines {
        const safe = @max(1, width);
        const inner = @max(0, safe - 2);
        var prev_btn: []const u8 = "↑ shift+enter";
        var next_btn: []const u8 = "↓ enter";
        var separator: []const u8 = " · ";
        const outer_gap: usize = 1;
        const available = if (inner > outer_gap * 2 + 1) inner - outer_gap * 2 - 1 else 0;
        var controls_w: usize = @intCast(wmod.visualWidth(prev_btn) + wmod.visualWidth(separator) + wmod.visualWidth(next_btn));
        if (controls_w > available) {
            prev_btn = "↑";
            next_btn = "↓";
            separator = " ";
            controls_w = @intCast(wmod.visualWidth(prev_btn) + wmod.visualWidth(separator) + wmod.visualWidth(next_btn));
        }
        const show_buttons = controls_w <= available;

        // Result counter (right of the input).
        var result_buf: [32]u8 = undefined;
        const result: []const u8 = if (self.query.len == 0)
            ""
        else if (self.matches.len == 0)
            "No matches"
        else
            std.fmt.bufPrint(&result_buf, "{d}/{d}", .{ self.selected + 1, self.matches.len }) catch "";
        var styled_buf: [96]u8 = undefined;
        const result_text: []const u8 = if (result.len > 0)
            std.fmt.bufPrint(&styled_buf, DIM ++ " {s} " ++ ansi.RESET, .{result}) catch ""
        else
            "";
        const result_w: usize = @intCast(wmod.visualWidth(result_text));
        const input_width = if (inner > result_w) inner - result_w else 0;

        // Input line: the query with the caret rendered as an inverted cell.
        var input: std.ArrayListUnmanaged(u8) = .empty;
        defer input.deinit(alloc);
        if (self.query.len == 0) {
            try input.appendSlice(alloc, DIM ++ "Find in transcript" ++ ansi.RESET);
        } else {
            try input.appendSlice(alloc, self.query[0..self.caret]);
            try input.appendSlice(alloc, "\x1b[7m");
            const after = wmod.nextCharEnd(self.query, self.caret);
            const at_caret: []const u8 = if (self.caret < self.query.len) self.query[self.caret..after] else " ";
            try input.appendSlice(alloc, at_caret);
            try input.appendSlice(alloc, "\x1b[27m");
            try input.appendSlice(alloc, self.query[after..]);
        }
        const input_line = try overlay.sliceByColumn(alloc, input.items, 0, input_width);
        defer alloc.free(input_line);
        const input_w: usize = @intCast(wmod.visualWidth(input_line));
        const pad = if (input_width > input_w) input_width - input_w else 0;
        var content: std.ArrayListUnmanaged(u8) = .empty;
        defer content.deinit(alloc);
        try content.appendSlice(alloc, input_line);
        if (pad > 0) try content.appendNTimes(alloc, ' ', pad);
        try content.appendSlice(alloc, result_text);

        // Bottom line: buttons or a plain rule.
        var bottom_inner: std.ArrayListUnmanaged(u8) = .empty;
        defer bottom_inner.deinit(alloc);
        var prev_start: usize = 0;
        var prev_end: usize = 0;
        var next_start: usize = 0;
        var next_end: usize = 0;
        if (show_buttons) {
            const right_rule: usize = if (inner > controls_w + outer_gap * 2) 1 else 0;
            const left_rule = inner - controls_w - outer_gap * 2 - right_rule;
            prev_start = 1 + left_rule + outer_gap;
            prev_end = prev_start + vw(prev_btn);
            next_start = prev_end + vw(separator);
            next_end = next_start + vw(next_btn);
            try appendRule(&bottom_inner, alloc, left_rule);
            if (self.hover_dir == -1) try bottom_inner.appendSlice(alloc, "\x1b[4m");
            try bottom_inner.appendSlice(alloc, prev_btn);
            if (self.hover_dir == -1) try bottom_inner.appendSlice(alloc, ansi.RESET);
            try bottom_inner.appendSlice(alloc, separator);
            if (self.hover_dir == 1) try bottom_inner.appendSlice(alloc, "\x1b[4m");
            try bottom_inner.appendSlice(alloc, next_btn);
            if (self.hover_dir == 1) try bottom_inner.appendSlice(alloc, ansi.RESET);
            if (right_rule > 0) try appendRule(&bottom_inner, alloc, right_rule);
        } else {
            try appendRule(&bottom_inner, alloc, inner);
        }

        var out: [3][]u8 = undefined;
        var top: std.ArrayListUnmanaged(u8) = .empty;
        defer top.deinit(alloc);
        try top.appendSlice(alloc, "┌");
        try appendRule(&top, alloc, inner);
        try top.appendSlice(alloc, "┐");
        out[0] = try top.toOwnedSlice(alloc);

        var mid: std.ArrayListUnmanaged(u8) = .empty;
        defer mid.deinit(alloc);
        try mid.appendSlice(alloc, "│");
        try mid.appendSlice(alloc, content.items);
        try mid.appendSlice(alloc, "│");
        out[1] = try mid.toOwnedSlice(alloc);

        var bot: std.ArrayListUnmanaged(u8) = .empty;
        defer bot.deinit(alloc);
        try bot.appendSlice(alloc, "└");
        try bot.appendSlice(alloc, bottom_inner.items);
        try bot.appendSlice(alloc, "┘");
        out[2] = try bot.toOwnedSlice(alloc);

        if (show_buttons) {
            self.buttons = (@as(u64, 1) << 63) |
                (@as(u64, prev_start) << 48) |
                (@as(u64, prev_end) << 32) |
                (@as(u64, next_start) << 16) |
                @as(u64, next_end);
        } else {
            self.buttons = 0;
        }
        self.caret_col = @intCast(wmod.visualWidth(self.query[0..self.caret]));
        return .{ .lines = out, .alloc = alloc };
    }

    /// Navigation button under a box-relative (row, col): -1 up, +1 down,
    /// 0 none (pi: getNavigationDirectionAt).
    pub fn navDirectionAt(self: *const Search, row: usize, col: usize) i8 {
        if (row != 2 or (self.buttons >> 63) == 0) return 0;
        if (col >= (self.buttons >> 48) & 0xFFFF and col < (self.buttons >> 32) & 0xFFFF) return -1;
        if (col >= (self.buttons >> 16) & 0xFFFF and col < self.buttons & 0xFFFF) return 1;
        return 0;
    }

    /// Is this screen cell inside the box? (For mouse routing.)
    pub fn contains(self: *const Search, col: usize, row: usize) bool {
        return row >= BOX_ROW and row < BOX_ROW + 3 and
            col >= self.box_col and col < self.box_col + self.box_width;
    }
};

/// A visible column range to highlight on one screen line.
pub const Range = struct {
    start: usize,
    end: usize,
    current: bool,
};

/// Rebuild one screen line with the match ranges highlighted (pi: the
/// per-row loop of applySearchHighlights). Ranges are applied from the
/// right so the visible columns of the earlier ones stay valid; the
/// rebuild preserves the visible width. The result is owned.
pub fn highlightLine(alloc: std.mem.Allocator, line: []const u8, ranges: []const Range) ![]u8 {
    if (ranges.len == 0) return alloc.dupe(u8, line);
    const line_w: usize = @intCast(wmod.visualWidth(line));
    var order: std.ArrayListUnmanaged(usize) = .empty;
    defer order.deinit(alloc);
    for (ranges, 0..) |r, i| {
        const start = @min(r.start, line_w);
        const end = @min(r.end, line_w);
        if (end > start) try order.append(alloc, i);
    }
    if (order.items.len == 0) return alloc.dupe(u8, line);

    const ctx = struct {
        fn startDesc(r: []const Range, a: usize, b: usize) bool {
            return r[a].start > r[b].start;
        }
    };
    std.mem.sort(usize, order.items, ranges, ctx.startDesc);

    var result: []const u8 = line;
    var owned: ?[]u8 = null;
    errdefer if (owned) |s| alloc.free(s);
    for (order.items) |i| {
        const r = ranges[i];
        const start = @min(r.start, line_w);
        const end = @min(r.end, line_w);
        const before = try overlay.sliceByColumn(alloc, result, 0, start);
        errdefer alloc.free(before);
        const mid = try overlay.sliceByColumn(alloc, result, start, end - start);
        errdefer alloc.free(mid);
        const after = try overlay.sliceByColumn(alloc, result, end, @max(0, line_w - end));
        errdefer alloc.free(after);
        const styled = try applyMatchStyle(alloc, mid, r.current);
        errdefer alloc.free(styled);
        const rebuilt = try std.mem.concat(alloc, u8, &.{ before, styled, after });
        alloc.free(before);
        alloc.free(mid);
        alloc.free(after);
        alloc.free(styled);
        if (owned) |s| alloc.free(s);
        owned = rebuilt;
        result = rebuilt;
    }
    if (owned) |s| return s;
    return alloc.dupe(u8, line);
}

test "highlightLine styles ranges right-to-left" {
    const alloc = std.heap.page_allocator;
    const line = "hello world";
    const r = try highlightLine(alloc, line, &.{
        .{ .start = 0, .end = 5, .current = false },
        .{ .start = 6, .end = 11, .current = true },
    });
    defer alloc.free(r);
    // The current match runs to the end of the line: its reset is dropped
    // with the trailing codes, as in pi (the TUI appends a line reset).
    try std.testing.expectEqualStrings(
        MATCH_STYLE ++ "hello" ++ MATCH_STYLE_RESET ++
            " " ++ MATCH_CURRENT_STYLE ++ "world",
        r,
    );
    // Ranges beyond the line width are clamped, not an error.
    const r2 = try highlightLine(alloc, "ab", &.{ .{ .start = 1, .end = 99, .current = false } });
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("a" ++ MATCH_STYLE ++ "b" ++ MATCH_STYLE_RESET, r2);
}

test "normalizeQuery collapses whitespace" {
    const alloc = std.heap.page_allocator;
    const q1 = try normalizeQuery(alloc, "  hello   world ");
    defer alloc.free(q1);
    try std.testing.expectEqualStrings("hello world", q1);
    const q2 = try normalizeQuery(alloc, "   ");
    defer alloc.free(q2);
    try std.testing.expectEqualStrings("", q2);
}

/// Encode the corpus codepoints to a UTF-8 string (test helper).
fn corpusText(alloc: std.mem.Allocator, corpus: *const Corpus) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (corpus.text) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.Overflow;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

test "corpus: ascii runs and column spans" {
    const alloc = std.heap.page_allocator;
    var corpus = try buildSearchCorpus(alloc, &.{ "hello world", "  foo bar" });
    defer corpus.deinit();
    // "hello world foo bar": at most one separator between runs (pi).
    const text = try corpusText(alloc, &corpus);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hello world foo bar", text);
    try std.testing.expectEqual(@as(usize, 4), corpus.spans.len);
    try std.testing.expectEqual(@as(usize, 0), corpus.spans[0].start_col);
    try std.testing.expectEqual(@as(usize, 5), corpus.spans[0].end_col);
    try std.testing.expectEqual(@as(usize, 1), corpus.spans[2].row); // "foo"
    try std.testing.expectEqual(@as(usize, 2), corpus.spans[2].start_col);
}

test "corpus: escapes stripped, wide chars keep column width" {
    const alloc = std.heap.page_allocator;
    var corpus = try buildSearchCorpus(alloc, &.{"\x1b[31mred\x1b[0m \xE4\xB8\xAD"});
    defer corpus.deinit();
    // Non-ASCII line: every codepoint is its own span (pi: the grapheme
    // path), so "red" is three linear spans and 中 the wide one.
    try std.testing.expectEqual(@as(usize, 4), corpus.spans.len);
    try std.testing.expectEqual(@as(usize, 0), corpus.spans[0].start_col);
    try std.testing.expectEqual(@as(usize, 1), corpus.spans[0].end_col);
    const wide = corpus.spans[3];
    try std.testing.expectEqual(@as(usize, 4), wide.start_col);
    try std.testing.expectEqual(@as(usize, 6), wide.end_col);
    try std.testing.expect(!wide.linear_columns);
}

test "findMatches: case-insensitive, per line" {
    const alloc = std.heap.page_allocator;
    var corpus = try buildSearchCorpus(alloc, &.{ "Hello World", "hello again" });
    defer corpus.deinit();
    const matches = try findMatches(alloc, &corpus, "hello");
    defer for (matches) |*m| m.deinit();
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].segments[0].row);
    try std.testing.expectEqual(@as(usize, 0), matches[0].segments[0].start_col);
    try std.testing.expectEqual(@as(usize, 5), matches[0].segments[0].end_col);
    try std.testing.expectEqual(@as(usize, 1), matches[1].segments[0].row);
}

test "findMatches: query spanning the row separator" {
    const alloc = std.heap.page_allocator;
    var corpus = try buildSearchCorpus(alloc, &.{ "foo bar", "baz foo" });
    defer corpus.deinit();
    const matches = try findMatches(alloc, &corpus, "bar baz");
    defer for (matches) |*m| m.deinit();
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 2), matches[0].segments.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].segments[0].row);
    try std.testing.expectEqual(@as(usize, 1), matches[0].segments[1].row);
}

test "sliceByColumn keeps inner styling" {
    const alloc = std.heap.page_allocator;
    // Columns: a(0) b(1) c(2) d(3) e(4) f(5), red over "cd".
    const line = "ab\x1b[31mcd\x1b[0mef";
    const r = try overlay.sliceByColumn(alloc, line, 0, 2);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("ab", r);
    const r2 = try overlay.sliceByColumn(alloc, line, 2, 2);
    defer alloc.free(r2);
    // pi's sliceWithWidth keeps codes inside the range and adds no reset.
    try std.testing.expectEqualStrings("\x1b[31mcd", r2);
    const r3 = try overlay.sliceByColumn(alloc, line, 4, 2);
    defer alloc.free(r3);
    // The pending red code is replayed at the cut, then reset (as in pi).
    try std.testing.expectEqualStrings("\x1b[31m\x1b[0mef", r3);
    // A style that started before the cut is replayed on the slice.
    const r4 = try overlay.sliceByColumn(alloc, line, 3, 3);
    defer alloc.free(r4);
    try std.testing.expectEqualStrings("\x1b[31md\x1b[0mef", r4);
}

test "search input: insert, backspace, caret" {
    const alloc = std.heap.page_allocator;
    var s = try Search.init(alloc);
    defer s.deinit();
    const ch = keys.Key{ .char = .{ .c = 'a', .ctrl = false, .alt = false } };
    try std.testing.expect(s.handleKey(ch));
    const ch2 = keys.Key{ .char = .{ .c = 'b', .ctrl = false, .alt = false } };
    try std.testing.expect(s.handleKey(ch2));
    try std.testing.expectEqualStrings("ab", s.query);
    try std.testing.expect(!s.handleKey(.left));
    try std.testing.expect(s.handleKey(.backspace));
    try std.testing.expectEqualStrings("b", s.query);
    const ctrl = keys.Key{ .char = .{ .c = 0x03, .ctrl = true, .alt = false } };
    try std.testing.expect(!s.handleKey(ctrl)); // modified keys rejected
    try std.testing.expectEqualStrings("b", s.query);
    // Multibyte UTF-8 insertion (the caret is at 0 after the backspace).
    const cjk = keys.Key{ .text = .{ .bytes = [_]u8{ 0xE4, 0xB8, 0xAD, 0 }, .len = 3 } };
    try std.testing.expect(s.handleKey(cjk));
    try std.testing.expectEqualStrings("\xE4\xB8\xADb", s.query);
}
