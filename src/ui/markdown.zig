//! Markdown to ANSI renderer for the TUI (pi: pi-tui's Markdown component).
//! Zero dependencies.
//!
//! Blocks: headings, fenced code (light syntax highlighting), lists (ordered,
//! unordered, task, nested), tables, blockquotes, horizontal rules and
//! paragraphs. Inline: code, bold, italic, strikethrough, links.
//!
//! Rows are wrapped to `width` columns at word boundaries. A wide (CJK)
//! character counts as two columns, and the styles in effect at a break are
//! carried onto the next row. Blocks are separated by one blank row, as in pi,
//! however many blank lines the source has. Each returned row is
//! heap-allocated; free the result with `freeLines`.

const std = @import("std");
const width_mod = @import("width.zig");
const latex_mod = @import("latex.zig");

// ---- pi dark theme (okhsl converted to sRGB with pi-tui's color pipeline) ----
const C_RESET = "\x1b[0m";
const C_BOLD = "\x1b[1m";
const C_BOLD_OFF = "\x1b[22m";
const C_ITALIC = "\x1b[3m";
const C_ITALIC_OFF = "\x1b[23m";
const C_STRIKE = "\x1b[9m";
const C_STRIKE_OFF = "\x1b[29m";
const C_UNDER = "\x1b[4m";
const C_UNDER_OFF = "\x1b[24m";
/// Back to the default foreground, leaving bold/italic/underline alone.
const C_FG_OFF = "\x1b[39m";

const C_HEADING = "\x1b[38;2;205;154;34m"; // mdHeading (yellow)
const C_LINK = "\x1b[38;2;105;173;208m"; // mdLink (blue)
const C_LINK_URL = "\x1b[38;2;157;165;169m"; // mdLinkUrl (muted)
const C_CODE = "\x1b[38;2;167;152;215m"; // mdCode (violet)
const C_CODE_BLOCK = "\x1b[38;2;104;183;141m"; // mdCodeBlock (green)
const C_MUTED = "\x1b[38;2;157;165;169m"; // mdCodeBlockBorder, mdQuote, mdQuoteBorder, mdHr
const C_BULLET = "\x1b[38;2;167;152;215m"; // mdListBullet (violet)
const C_SYN_KEYWORD = "\x1b[38;2;105;173;208m"; // syntaxKeyword (blue)
const C_SYN_STRING = "\x1b[38;2;222;141;90m"; // syntaxString
const C_SYN_NUMBER = "\x1b[38;2;104;183;141m"; // syntaxNumber (green)
const C_SYN_COMMENT = "\x1b[38;2;157;165;169m"; // syntaxComment (muted)

/// Indentation of code inside a fenced block (pi: codeBlockIndent).
const CODE_INDENT = "  ";
/// Columns per list nesting level.
const LIST_INDENT = 4;
/// A horizontal rule is at most this wide.
const HR_MAX_WIDTH = 80;
/// Longest word a table column is sized to hold unbroken.
const TABLE_MAX_UNBROKEN_WORD = 30;

pub const Options = struct {
    /// SGR prefix for running text (paragraphs, list items, table cells), such
    /// as a color plus italic for thinking blocks. It is applied again after
    /// every inline style, so an inline code span does not end it.
    base_style: []const u8 = "",
};

/// Free an array of rows returned by `render`.
pub fn freeLines(alloc: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| alloc.free(l);
    alloc.free(lines);
}

/// Render markdown `src` into ANSI-styled rows of at most `width` columns.
/// The caller owns the rows.
pub fn render(alloc: std.mem.Allocator, src: []const u8, width: usize) ![][]u8 {
    return renderWith(alloc, src, width, .{});
}

/// The block kind of a source line (exposed for incremental rendering).
pub const BlockKind = enum { blank, fence, heading, hr, quote, list, table, para, latex };

/// Whether a blank row separates a block of kind `prev` from one of `next`
/// (pi separates blocks by one blank row even when the source has none).
fn blocksNeedGap(prev: BlockKind, next: BlockKind) bool {
    return switch (prev) {
        .heading, .fence, .table, .hr, .quote, .latex => next != .blank,
        // Paragraph lines stay together, and a list may follow directly.
        .para => next != .blank and next != .para and next != .list,
        .list, .blank => false,
    };
}

/// Render one segment of a streamed source, continuing from `prev_kind` —
/// the block kind that ended the previous segment (null at a stream start).
/// Updates `prev_kind` to this segment's last block kind. Splicing segments
/// rendered through this function is byte-identical to rendering the
/// concatenated source, because block gaps depend on the ADJACENT blocks'
/// kinds and therefore cross segment boundaries.
pub fn renderSegment(
    alloc: std.mem.Allocator,
    src: []const u8,
    width: usize,
    opts: Options,
    prev_kind: *?BlockKind,
    strip_trailing: bool,
) ![][]u8 {
    // Tabs render as 3 spaces (pi), carriage returns are dropped.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(alloc);
    for (src) |c| {
        if (c == '\t') {
            try text.appendSlice(alloc, "   ");
        } else if (c != '\r') {
            try text.append(alloc, c);
        }
    }

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, text.items, '\n');
    while (it.next()) |l| try lines.append(alloc, l);

    var r: Renderer = .{ .alloc = alloc, .width = @max(width, 1), .base = opts.base_style };
    errdefer {
        for (r.out.items) |l| alloc.free(l);
        r.out.deinit(alloc);
    }

    var i: usize = 0;
    var last: ?BlockKind = null;
    while (i < lines.items.len) {
        // Display math ($$…$$ / \[…\]) before the regular classifier: the
        // converted unicode block otherwise reads as a plain paragraph.
        if (classify(lines.items, i) != .fence) {
            if (latexBlockEnd(lines.items, i)) |end| {
                const opener = std.mem.trimStart(u8, lines.items[i], " ");
                const closer: []const u8 = if (std.mem.startsWith(u8, opener, "\\")) "\\]" else "$$";
                var body: std.ArrayListUnmanaged(u8) = .empty;
                defer body.deinit(alloc);
                for (lines.items[i..end], i..) |l, li| {
                    var row = l;
                    if (li == i) {
                        row = row[2..];
                    } else {
                        try body.append(alloc, '\n');
                    }
                    if (li == end - 1) {
                        if (std.mem.lastIndexOf(u8, row, closer)) |pos| row = row[0..pos];
                    }
                    try body.appendSlice(alloc, std.mem.trim(u8, row, " "));
                }
                const converted = latex_mod.render(alloc, body.items) catch null;
                r.list_depth = 0;
                if (converted) |conv_text| {
                    defer alloc.free(conv_text);
                    var nl = std.mem.splitScalar(u8, conv_text, '\n');
                    while (nl.next()) |row| {
                        try r.paragraph(row);
                    }
                } else {
                    // Conversion failed: the raw source (pi falls back too).
                    for (lines.items[i..end]) |l| try r.paragraph(l);
                }
                try r.gapAfter(.latex, lines.items, end);
                last = .latex;
                i = end;
                continue;
            }
        }
        const kind = classify(lines.items, i);
        if (i == 0) {
            // Splice boundary: the gap between the previous segment's last
            // block and this one (the renderer's own blank() no-ops when
            // the output is empty, so a stream start adds nothing).
            if (prev_kind.*) |pk| {
                if (blocksNeedGap(pk, kind)) try r.blank();
            }
        }
        switch (kind) {
            .blank => {
                try r.blank();
                i += 1;
            },
            .fence => {
                r.list_depth = 0;
                i = try r.codeBlock(lines.items, i);
            },
            .heading => {
                r.list_depth = 0;
                try r.heading(lines.items[i]);
                i += 1;
            },
            .hr => {
                r.list_depth = 0;
                try r.rule();
                i += 1;
            },
            .quote => {
                r.list_depth = 0;
                i = try r.quote(lines.items, i);
            },
            .table => {
                r.list_depth = 0;
                i = try r.table(lines.items, i);
            },
            .list => {
                try r.listItem(lines.items[i]);
                i += 1;
            },
            .para => {
                try r.paragraph(lines.items[i]);
                i += 1;
            },
            // Intercepted above (before the classifier); unreachable here.
            .latex => unreachable,
        }
        try r.gapAfter(kind, lines.items, i);
        last = kind;
    }

    // No trailing blank rows at the end of a rendered stream. A spliced
    // middle segment (strip_trailing=false) keeps its trailing blank: it is
    // the gap row between the segments, and the renderer's blank() no-ops
    // keep it from ever doubling.
    if (strip_trailing) {
        while (r.out.items.len > 0 and r.out.items[r.out.items.len - 1].len == 0) {
            alloc.free(r.out.pop().?);
        }
    }
    // An empty segment leaves the caller's state untouched.
    if (last) |k| prev_kind.* = k;
    return r.out.toOwnedSlice(alloc);
}

/// `render` with options.
pub fn renderWith(alloc: std.mem.Allocator, src: []const u8, width: usize, opts: Options) ![][]u8 {
    var pk: ?BlockKind = null;
    return renderSegment(alloc, src, width, opts, &pk, true);
}

// ---- blocks ----

const Kind = BlockKind; // (public alias — renderSegment splicing exposes it)

/// The block that starts at `lines[i]`.

/// Whether a display-math block starts at `lines[i]`: up to three spaces,
/// then `$$` or `\[`. Returns the exclusive end line index when closed
/// (and no table starts inside, so a stray `$$` cannot swallow a table).
pub fn latexBlockEnd(lines: []const []const u8, i: usize) ?usize {
    const opener = std.mem.trimStart(u8, lines[i], " ");
    const closer: []const u8 = if (std.mem.startsWith(u8, opener, "$$")) "$$" else if (std.mem.startsWith(u8, opener, "\\")) "\\]" else return null;
    var j = i;
    while (j < lines.len) : (j += 1) {
        const scan = if (j == i) opener[closer.len..] else lines[j];
        if (std.mem.indexOf(u8, scan, closer) != null) return j + 1;
        if (j > i and isTableStart(lines[j - 1], lines[j])) return null;
    }
    return null; // unclosed: paragraph (pi's pending state renders raw too)
}

fn classify(lines: []const []const u8, i: usize) Kind {
    const line = lines[i];
    if (isBlank(line)) return .blank;
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (fenceLen(trimmed) > 0) return .fence;
    if (headingLevel(trimmed) > 0) return .heading;
    if (isHr(trimmed)) return .hr;
    if (trimmed[0] == '>') return .quote;
    if (listMarker(trimmed) != null) return .list;
    if (i + 1 < lines.len and isTableStart(line, lines[i + 1])) return .table;
    return .para;
}

const Renderer = struct {
    alloc: std.mem.Allocator,
    width: usize,
    base: []const u8,
    out: std.ArrayListUnmanaged([]u8) = .empty,
    /// Source indentation of each open list level; `list_depth` of them are in use.
    list_indents: [8]usize = undefined,
    list_depth: usize = 0,
    /// Per open level, the column where the item's text starts: in the source
    /// (to tell which item an indented line continues) and in the output.
    list_src_cols: [8]usize = undefined,
    list_out_cols: [8]usize = undefined,

    /// Append a blank row, unless the output is empty or already ends with one.
    fn blank(self: *Renderer) !void {
        if (self.out.items.len == 0) return;
        if (self.out.items[self.out.items.len - 1].len == 0) return;
        try self.push("");
    }

    fn push(self: *Renderer, row: []const u8) !void {
        const copy = try self.alloc.dupe(u8, row);
        errdefer self.alloc.free(copy);
        try self.out.append(self.alloc, copy);
    }

    /// pi separates blocks by one blank row even when the source has none
    /// (a heading directly followed by text). `next` is the line after the block.
    fn gapAfter(self: *Renderer, kind: Kind, lines: []const []const u8, next: usize) !void {
        if (next >= lines.len) return;
        if (blocksNeedGap(kind, classify(lines, next))) try self.blank();
    }

    /// Append `line`, wrapped to the full width.
    fn wrapped(self: *Renderer, line: []const u8) !void {
        try wrapStyled(self.alloc, &self.out, line, self.width);
    }

    /// Append `body` wrapped to the width left after a prefix of `cols`
    /// columns: `first` before the first row, `rest` before the others.
    fn prefixed(self: *Renderer, body: []const u8, first: []const u8, rest: []const u8, cols: usize) !void {
        var rows: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (rows.items) |row| self.alloc.free(row);
            rows.deinit(self.alloc);
        }
        const inner = if (self.width > cols) self.width - cols else 1;
        try wrapStyled(self.alloc, &rows, body, inner);
        for (rows.items, 0..) |row, i| {
            const line = try std.mem.concat(self.alloc, u8, &.{ if (i == 0) first else rest, row });
            errdefer self.alloc.free(line);
            try self.out.append(self.alloc, line);
        }
    }

    /// Running text in the base style: `<base><inline><reset>`.
    fn styledText(self: *Renderer, text: []const u8, base: []const u8) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, base);
        try renderInlineBase(self.alloc, &buf, text, base, false);
        if (base.len > 0) try buf.appendSlice(self.alloc, C_RESET);
        return buf.toOwnedSlice(self.alloc);
    }

    /// `# One` is bold and underlined, `## Two` bold; from level 3 on the
    /// `###` prefix stays visible. All in the heading color.
    fn heading(self: *Renderer, line: []const u8) !void {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const level = headingLevel(trimmed);
        const text = std.mem.trim(u8, trimmed[level..], " ");
        const style = if (level == 1) C_BOLD ++ C_UNDER ++ C_HEADING else C_BOLD ++ C_HEADING;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, style);
        if (level >= 3) {
            try buf.appendNTimes(self.alloc, '#', level);
            try buf.append(self.alloc, ' ');
        }
        try renderInlineBase(self.alloc, &buf, text, style, false);
        try buf.appendSlice(self.alloc, C_RESET);
        try self.wrapped(buf.items);
    }

    fn rule(self: *Renderer) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, C_MUTED);
        for (0..@min(self.width, HR_MAX_WIDTH)) |_| try buf.appendSlice(self.alloc, "─");
        try buf.appendSlice(self.alloc, C_RESET);
        try self.push(buf.items);
    }

    /// A run of `>` lines: muted italic text behind a `│ ` border, which
    /// repeats on wrapped rows. Returns the index after the run.
    fn quote(self: *Renderer, lines: []const []const u8, start: usize) !usize {
        const border = C_MUTED ++ "│ " ++ C_RESET;
        const style = C_MUTED ++ C_ITALIC;
        var i = start;
        while (i < lines.len) : (i += 1) {
            const trimmed = std.mem.trimStart(u8, lines[i], " ");
            if (trimmed.len == 0 or trimmed[0] != '>') break;
            var content = trimmed[1..];
            if (content.len > 0 and content[0] == ' ') content = content[1..];
            const body = try self.styledText(content, style);
            defer self.alloc.free(body);
            try self.prefixed(body, border, border, 2);
        }
        return i;
    }

    /// One list item: `- text`, `3. text`, `- [x] text`, indented by its
    /// nesting level. Wrapped rows line up under the text.
    fn listItem(self: *Renderer, line: []const u8) !void {
        const indent = leadingSpaces(line);
        const trimmed = line[indent..];
        const marker = listMarker(trimmed).?;

        // The nesting level follows the source indentation.
        if (self.list_depth == 0) {
            self.list_depth = 1;
            self.list_indents[0] = indent;
        } else {
            while (self.list_depth > 1 and indent < self.list_indents[self.list_depth - 1]) self.list_depth -= 1;
            if (indent >= self.list_indents[self.list_depth - 1] + 2 and self.list_depth < self.list_indents.len) {
                self.list_indents[self.list_depth] = indent;
                self.list_depth += 1;
            } else {
                self.list_indents[self.list_depth - 1] = indent;
            }
        }
        const level = self.list_depth - 1;

        var content = std.mem.trimStart(u8, trimmed[marker.len..], " ");
        self.list_src_cols[level] = indent + (trimmed.len - content.len);
        var bullet: std.ArrayListUnmanaged(u8) = .empty;
        defer bullet.deinit(self.alloc);
        if (marker.number.len > 0) {
            try bullet.appendSlice(self.alloc, marker.number);
            try bullet.appendSlice(self.alloc, ". ");
        } else {
            try bullet.appendSlice(self.alloc, "- ");
        }
        // Task list: `- [ ] todo`, `- [x] done`.
        if (content.len >= 3 and content[0] == '[' and content[2] == ']' and
            (content[1] == ' ' or content[1] == 'x' or content[1] == 'X') and
            (content.len == 3 or content[3] == ' '))
        {
            try bullet.appendSlice(self.alloc, if (content[1] == ' ') "[ ] " else "[x] ");
            content = std.mem.trimStart(u8, content[3..], " ");
        }

        const pad = LIST_INDENT * level;
        const text_col = pad + bullet.items.len; // the bullet is ASCII
        var first: std.ArrayListUnmanaged(u8) = .empty;
        defer first.deinit(self.alloc);
        try first.appendNTimes(self.alloc, ' ', pad);
        try first.appendSlice(self.alloc, C_BULLET);
        try first.appendSlice(self.alloc, bullet.items);
        try first.appendSlice(self.alloc, C_RESET);
        var rest: std.ArrayListUnmanaged(u8) = .empty;
        defer rest.deinit(self.alloc);
        try rest.appendNTimes(self.alloc, ' ', text_col);

        const body = try self.styledText(content, self.base);
        defer self.alloc.free(body);
        try self.prefixed(body, first.items, rest.items, text_col);
        self.list_out_cols[level] = text_col;
    }

    /// One line of a paragraph. Indented text below a list item continues
    /// that item.
    fn paragraph(self: *Renderer, line: []const u8) !void {
        const indent = leadingSpaces(line);
        const body = try self.styledText(line[indent..], self.base);
        defer self.alloc.free(body);
        if (self.list_depth > 0 and indent >= 2) {
            // The line continues the deepest item whose text starts at or
            // before its indentation.
            var level = self.list_depth - 1;
            while (level > 0 and self.list_src_cols[level] > indent) level -= 1;
            const col = self.list_out_cols[level];
            var pad: std.ArrayListUnmanaged(u8) = .empty;
            defer pad.deinit(self.alloc);
            try pad.appendNTimes(self.alloc, ' ', col);
            try self.prefixed(body, pad.items, pad.items, col);
            return;
        }
        self.list_depth = 0;
        try self.wrapped(body);
    }

    /// A fenced code block: the fence rows with the language, the code
    /// indented between them. Without a language the code is in the code
    /// block color; with one it is highlighted. Returns the index after the
    /// block. A block still being streamed has no closing fence yet.
    fn codeBlock(self: *Renderer, lines: []const []const u8, start: usize) !usize {
        const open = std.mem.trimStart(u8, lines[start], " ");
        const fence_char = open[0];
        const fence_len = fenceLen(open);
        const info = std.mem.trim(u8, open[fence_len..], " ");
        const lang = info[0 .. std.mem.indexOfScalar(u8, info, ' ') orelse info.len];

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, C_MUTED ++ "```");
        try buf.appendSlice(self.alloc, lang);
        try buf.appendSlice(self.alloc, C_RESET);
        try self.push(buf.items);

        var i = start + 1;
        while (i < lines.len) : (i += 1) {
            const line = lines[i];
            const trimmed = std.mem.trim(u8, line, " ");
            if (trimmed.len >= fence_len and fenceLen(trimmed) == trimmed.len and trimmed[0] == fence_char) {
                try self.push(C_MUTED ++ "```" ++ C_RESET);
                return i + 1;
            }
            buf.clearRetainingCapacity();
            try buf.appendSlice(self.alloc, CODE_INDENT);
            if (lang.len == 0) {
                if (line.len > 0) {
                    try buf.appendSlice(self.alloc, C_CODE_BLOCK);
                    try buf.appendSlice(self.alloc, line);
                    try buf.appendSlice(self.alloc, C_RESET);
                }
            } else if (isPlainLang(lang)) {
                try buf.appendSlice(self.alloc, line);
            } else {
                try highlightCode(self.alloc, &buf, line, lang);
            }
            try self.wrapped(buf.items);
        }
        return i;
    }

    /// A pipe table with full borders, a bold header, a separator between all
    /// rows, and cells wrapped to their column (pi: renderTable). Returns the
    /// index after the table.
    fn table(self: *Renderer, lines: []const []const u8, start: usize) !usize {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const header = try splitCells(arena, lines[start]);
        const n = header.len;
        var rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
        var end = start + 2; // past the header and the delimiter row
        while (end < lines.len) : (end += 1) {
            if (isBlank(lines[end]) or std.mem.indexOfScalar(u8, lines[end], '|') == null) break;
            try rows.append(arena, try splitCells(arena, lines[end]));
        }

        // "│ " + (n-1) * " │ " + " │"
        const border_overhead = 3 * n + 1;
        if (self.width < border_overhead + n) {
            // Too narrow for a stable table: show the source.
            for (lines[start..end]) |raw| try self.wrapped(raw);
            return end;
        }
        const available = self.width - border_overhead;

        // Styled cells, and what each column needs.
        const head_cells = try arena.alloc([]const u8, n);
        const natural = try arena.alloc(usize, n);
        const min_word = try arena.alloc(usize, n);
        for (0..n) |c| {
            head_cells[c] = try self.cell(arena, header[c]);
            natural[c] = visibleWidth(head_cells[c]);
            min_word[c] = @max(1, longestWord(head_cells[c]));
        }
        const body_cells = try arena.alloc([]const []const u8, rows.items.len);
        for (rows.items, 0..) |row, ri| {
            const cells = try arena.alloc([]const u8, n);
            for (0..n) |c| {
                cells[c] = try self.cell(arena, if (c < row.len) row[c] else "");
                natural[c] = @max(natural[c], visibleWidth(cells[c]));
                min_word[c] = @max(min_word[c], longestWord(cells[c]));
            }
            body_cells[ri] = cells;
        }

        const widths = try columnWidths(arena, natural, min_word, available);

        try self.tableBorder(arena, widths, "┌─", "─┬─", "─┐");
        try self.tableRow(arena, head_cells, widths, true);
        for (body_cells) |cells| {
            try self.tableBorder(arena, widths, "├─", "─┼─", "─┤");
            try self.tableRow(arena, cells, widths, false);
        }
        try self.tableBorder(arena, widths, "└─", "─┴─", "─┘");
        return end;
    }

    /// A table cell's inline markdown, styled.
    fn cell(self: *Renderer, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(arena, self.base);
        try renderInlineBase(arena, &buf, text, self.base, false);
        if (self.base.len > 0) try buf.appendSlice(arena, C_RESET);
        return buf.items;
    }

    fn tableBorder(self: *Renderer, arena: std.mem.Allocator, widths: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(arena, left);
        for (widths, 0..) |w, c| {
            if (c > 0) try buf.appendSlice(arena, mid);
            for (0..w) |_| try buf.appendSlice(arena, "─");
        }
        try buf.appendSlice(arena, right);
        try self.push(buf.items);
    }

    /// One table row; as many screen rows as its tallest wrapped cell.
    fn tableRow(self: *Renderer, arena: std.mem.Allocator, cells: []const []const u8, widths: []const usize, bold: bool) !void {
        const wrapped_cells = try arena.alloc([]const []u8, cells.len);
        var height: usize = 1;
        for (cells, 0..) |text, c| {
            var parts: std.ArrayListUnmanaged([]u8) = .empty;
            try wrapStyled(arena, &parts, text, widths[c]);
            wrapped_cells[c] = parts.items;
            height = @max(height, parts.items.len);
        }
        for (0..height) |row| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(arena, "│ ");
            for (wrapped_cells, 0..) |parts, c| {
                if (c > 0) try buf.appendSlice(arena, " │ ");
                const part: []const u8 = if (row < parts.len) parts[row] else "";
                if (bold) try buf.appendSlice(arena, C_BOLD);
                try buf.appendSlice(arena, part);
                const used = visibleWidth(part);
                if (widths[c] > used) try buf.appendNTimes(arena, ' ', widths[c] - used);
                if (bold) try buf.appendSlice(arena, C_BOLD_OFF);
            }
            try buf.appendSlice(arena, " │");
            try self.push(buf.items);
        }
    }
};

/// Column widths that fit `available` columns in total: the natural widths
/// when they fit, otherwise shrunk towards each column's longest word, the
/// spare columns shared by how much each column still wants (pi: renderTable).
fn columnWidths(arena: std.mem.Allocator, natural: []const usize, min_word: []const usize, available: usize) ![]usize {
    const n = natural.len;
    const minimum = try arena.alloc(usize, n);
    var min_total: usize = 0;
    for (0..n) |c| {
        minimum[c] = min_word[c];
        min_total += minimum[c];
    }
    if (min_total > available) {
        // Even the longest words do not fit: one column each, the rest by weight.
        var weight_total: usize = 0;
        for (min_word) |w| weight_total += w - 1;
        const spare = available - n;
        var given: usize = 0;
        for (0..n) |c| {
            const grow = if (weight_total > 0) (min_word[c] - 1) * spare / weight_total else 0;
            minimum[c] = 1 + grow;
            given += grow;
        }
        var leftover = spare - given;
        var c: usize = 0;
        while (leftover > 0 and c < n) : (c += 1) {
            minimum[c] += 1;
            leftover -= 1;
        }
        min_total = available;
    }

    var natural_total: usize = 0;
    for (natural) |w| natural_total += w;
    const widths = try arena.alloc(usize, n);
    if (natural_total <= available) {
        for (0..n) |c| widths[c] = @max(natural[c], minimum[c]);
        return widths;
    }

    var want_total: usize = 0;
    for (0..n) |c| want_total += natural[c] -| minimum[c];
    const extra = available - min_total;
    var allocated: usize = 0;
    for (0..n) |c| {
        const want = natural[c] -| minimum[c];
        widths[c] = minimum[c] + (if (want_total > 0) want * extra / want_total else 0);
        allocated += widths[c];
    }
    // Hand out what integer division left over.
    var remaining = available - allocated;
    while (remaining > 0) {
        var grew = false;
        for (0..n) |c| {
            if (remaining == 0) break;
            if (widths[c] < natural[c]) {
                widths[c] += 1;
                remaining -= 1;
                grew = true;
            }
        }
        if (!grew) break;
    }
    return widths;
}

/// Width of the longest space-separated word of a styled string, capped at
/// TABLE_MAX_UNBROKEN_WORD.
fn longestWord(styled: []const u8) usize {
    var longest: usize = 0;
    var it = std.mem.tokenizeScalar(u8, styled, ' ');
    while (it.next()) |word| longest = @max(longest, visibleWidth(word));
    return @min(longest, TABLE_MAX_UNBROKEN_WORD);
}

/// The cells of a table row, trimmed. A `\|` is a literal pipe.
fn splitCells(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var s = std.mem.trim(u8, line, " ");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and (s.len < 2 or s[s.len - 2] != '\\')) s = s[0 .. s.len - 1];

    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    var current: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|') {
            try current.append(arena, '|');
            i += 1;
        } else if (s[i] == '|') {
            try cells.append(arena, std.mem.trim(u8, try current.toOwnedSlice(arena), " "));
        } else {
            try current.append(arena, s[i]);
        }
    }
    try cells.append(arena, std.mem.trim(u8, try current.toOwnedSlice(arena), " "));
    return cells.items;
}

fn cellCount(line: []const u8) usize {
    var s = std.mem.trim(u8, line, " ");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and (s.len < 2 or s[s.len - 2] != '\\')) s = s[0 .. s.len - 1];
    var count: usize = 1;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '|') {
            count += 1;
        }
    }
    return count;
}

/// A table starts with a header row followed by a delimiter row such as
/// `|---|:--:|`, with a pipe in at least one of them and as many columns in
/// both. Without a pipe a `---` line is a rule, not a table.
fn isTableStart(header: []const u8, delimiter: []const u8) bool {
    const d = std.mem.trim(u8, delimiter, " ");
    if (d.len == 0) return false;
    var dashes = false;
    for (d) |c| {
        switch (c) {
            '-' => dashes = true,
            '|', ':', ' ' => {},
            else => return false,
        }
    }
    if (!dashes) return false;
    const has_pipe = std.mem.indexOfScalar(u8, header, '|') != null or std.mem.indexOfScalar(u8, d, '|') != null;
    return has_pipe and cellCount(header) == cellCount(d);
}

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ') return false;
    }
    return true;
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Length of the code fence (three or more backticks or tildes) `line` starts
/// with; 0 if it is not one.
fn fenceLen(line: []const u8) usize {
    if (line.len < 3 or (line[0] != '`' and line[0] != '~')) return 0;
    var n: usize = 0;
    while (n < line.len and line[n] == line[0]) n += 1;
    return if (n >= 3) n else 0;
}

/// Heading level (1..6) of `# text`; 0 if the line is not a heading.
fn headingLevel(line: []const u8) usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return 0;
    if (level < line.len and line[level] != ' ') return 0;
    return level;
}

fn isHr(line: []const u8) bool {
    if (line.len < 3) return false;
    const mark = line[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    var count: usize = 0;
    for (line) |c| {
        if (c == mark) {
            count += 1;
        } else if (c != ' ') {
            return false;
        }
    }
    return count >= 3;
}

const ListMarker = struct {
    /// Bytes of the marker in the source.
    len: usize,
    /// The digits of an ordered item; empty for a bullet.
    number: []const u8,
};

/// `- `, `* `, `+ `, or `12. ` / `12) ` at the start of `line`.
fn listMarker(line: []const u8) ?ListMarker {
    if (line.len >= 1 and (line[0] == '-' or line[0] == '*' or line[0] == '+')) {
        if (line.len == 1 or line[1] == ' ') return .{ .len = 1, .number = "" };
        return null;
    }
    var digits: usize = 0;
    while (digits < line.len and digits < 9 and std.ascii.isDigit(line[digits])) digits += 1;
    if (digits == 0 or digits >= line.len) return null;
    if (line[digits] != '.' and line[digits] != ')') return null;
    if (digits + 1 < line.len and line[digits + 1] != ' ') return null;
    return .{ .len = digits + 1, .number = line[0..digits] };
}

// ---- inline ----

/// Terminal hyperlinks (OSC 8) on rendered links and bare URLs. Enabled by
/// default; the TUI turns it off for environments that do not forward OSC 8
/// (tmux without passthrough, dumb terminals) where the raw sequence would
/// leak into the text.
pub var hyperlinks_enabled: bool = true;

fn osc8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, url: []const u8, styled_text: []const u8) !void {
    try out.appendSlice(alloc, "\x1b]8;;");
    try out.appendSlice(alloc, url);
    try out.appendSlice(alloc, "\x1b\\");
    try out.appendSlice(alloc, styled_text);
    try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
}

/// Render inline markdown (code spans, bold, italic, strikethrough, links)
/// into `out`.
pub fn renderInline(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    return renderInlineBase(alloc, out, text, "", false);
}

/// `renderInline` inside text styled with `base`: every inline style ends
/// with its own off-code and then `base` again, so the surrounding style
/// (a heading's color, a thinking block's italic) continues after it.
/// `in_link` suppresses links inside a link's label, which do not nest.
fn renderInlineBase(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8, base: []const u8, in_link: bool) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // `\*` is a literal asterisk.
        if (c == '\\' and i + 1 < text.len and std.ascii.isPunctuation(text[i + 1])) {
            try out.append(alloc, text[i + 1]);
            i += 2;
            continue;
        }

        if (c == '`') {
            var ticks: usize = 0;
            while (i + ticks < text.len and text[i + ticks] == '`') ticks += 1;
            if (findRun(text, i + ticks, '`', ticks)) |close| {
                var code = text[i + ticks .. close];
                // `` `a` `` : one space of padding on both sides is not content.
                if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and std.mem.trim(u8, code, " ").len > 0) {
                    code = code[1 .. code.len - 1];
                }
                try out.appendSlice(alloc, C_CODE);
                try out.appendSlice(alloc, code);
                try out.appendSlice(alloc, C_FG_OFF);
                try out.appendSlice(alloc, base);
                i = close + ticks;
                continue;
            }
            try out.appendSlice(alloc, text[i .. i + ticks]);
            i += ticks;
            continue;
        }

        if (isDelimiter(text, i, "**") or isDelimiter(text, i, "__")) {
            if (closingDelimiter(text, i, 2)) |close| {
                try out.appendSlice(alloc, C_BOLD);
                try renderInlineBase(alloc, out, text[i + 2 .. close], base, in_link);
                try out.appendSlice(alloc, C_BOLD_OFF);
                try out.appendSlice(alloc, base);
                i = close + 2;
                continue;
            }
        }

        if (isDelimiter(text, i, "~~")) {
            if (closingDelimiter(text, i, 2)) |close| {
                try out.appendSlice(alloc, C_STRIKE);
                try renderInlineBase(alloc, out, text[i + 2 .. close], base, in_link);
                try out.appendSlice(alloc, C_STRIKE_OFF);
                try out.appendSlice(alloc, base);
                i = close + 2;
                continue;
            }
        }

        if (c == '[' and !in_link) {
            if (parseLink(text, i)) |link| {
                const label = text[i + 1 .. link.text_end];
                const url = text[link.url_start..link.url_end];
                var link_body: std.ArrayListUnmanaged(u8) = .empty;
                defer link_body.deinit(alloc);
                try link_body.appendSlice(alloc, C_LINK ++ C_UNDER);
                try renderInlineBase(alloc, &link_body, label, C_LINK ++ C_UNDER, true);
                try link_body.appendSlice(alloc, C_UNDER_OFF ++ C_FG_OFF);
                if (hyperlinks_enabled) {
                    // OSC 8 wraps the whole styled label (pi: hyperlink of the
                    // themed link); the URL stays out of the text.
                    try osc8(out, alloc, url, link_body.items);
                } else {
                    try out.appendSlice(alloc, link_body.items);
                    // The target is shown unless the label already is the target.
                    const shown = if (std.mem.startsWith(u8, url, "mailto:")) url["mailto:".len..] else url;
                    if (!std.mem.eql(u8, label, url) and !std.mem.eql(u8, label, shown)) {
                        try out.appendSlice(alloc, C_LINK_URL ++ " (");
                        try out.appendSlice(alloc, url);
                        try out.appendSlice(alloc, ")" ++ C_FG_OFF);
                    }
                }
                try out.appendSlice(alloc, base);
                i = link.url_end + 1;
                continue;
            }
        }

        // A bare URL is a link to itself.
        if (!in_link and c == 'h' and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]))) {
            if (bareUrlEnd(text, i)) |end| {
                const url_text = text[i..end];
                var body: std.ArrayListUnmanaged(u8) = .empty;
                defer body.deinit(alloc);
                try body.appendSlice(alloc, C_LINK ++ C_UNDER);
                try body.appendSlice(alloc, url_text);
                try body.appendSlice(alloc, C_UNDER_OFF ++ C_FG_OFF);
                if (hyperlinks_enabled) {
                    try osc8(out, alloc, url_text, body.items);
                } else {
                    try out.appendSlice(alloc, body.items);
                }
                try out.appendSlice(alloc, base);
                i = end;
                continue;
            }
        }

        if ((c == '*' or c == '_') and isDelimiter(text, i, text[i .. i + 1])) {
            if (closingDelimiter(text, i, 1)) |close| {
                try out.appendSlice(alloc, C_ITALIC);
                try renderInlineBase(alloc, out, text[i + 1 .. close], base, in_link);
                try out.appendSlice(alloc, C_ITALIC_OFF);
                try out.appendSlice(alloc, base);
                i = close + 1;
                continue;
            }
        }

        try out.append(alloc, c);
        i += 1;
    }
}

/// Whether `text[i..]` starts with `delim` as an opening delimiter: text
/// follows it directly, and an underscore is not inside a word (so
/// `snake_case` stays as it is).
fn isDelimiter(text: []const u8, i: usize, delim: []const u8) bool {
    if (!std.mem.startsWith(u8, text[i..], delim)) return false;
    const after = i + delim.len;
    if (after >= text.len or text[after] == ' ') return false;
    // A longer run of the same character is a different delimiter.
    if (delim.len == 1 and text[after] == delim[0]) return false;
    if (delim[0] == '_' and i > 0 and std.ascii.isAlphanumeric(text[i - 1])) return false;
    return true;
}

/// The closing delimiter matching the one of `len` characters at `open`.
/// Text precedes it directly, and an underscore is not inside a word.
fn closingDelimiter(text: []const u8, open: usize, len: usize) ?usize {
    const mark = text[open];
    var j = open + len;
    while (j + len <= text.len) : (j += 1) {
        if (text[j] == '\\') {
            j += 1;
            continue;
        }
        if (text[j] != mark) continue;
        var run: usize = 0;
        while (j + run < text.len and text[j + run] == mark) run += 1;
        if (run < len) {
            j += run - 1;
            continue;
        }
        // In a longer run the delimiter is its end: `***a***`.
        const at = j + run - len;
        if (text[at - 1] != ' ' and at > open + len - 1 and
            !(mark == '_' and at + len < text.len and std.ascii.isAlphanumeric(text[at + len])))
        {
            if (len == 1 and run > 1) {
                // A single delimiter does not close on a double one.
                j += run - 1;
                continue;
            }
            return at;
        }
        j += run - 1;
    }
    return null;
}

/// The next run of exactly `len` `mark` characters at or after `from`.
fn findRun(text: []const u8, from: usize, mark: u8, len: usize) ?usize {
    var j = from;
    while (j < text.len) {
        if (text[j] != mark) {
            j += 1;
            continue;
        }
        var run: usize = 0;
        while (j + run < text.len and text[j + run] == mark) run += 1;
        if (run == len) return j;
        j += run;
    }
    return null;
}

const Link = struct { text_end: usize, url_start: usize, url_end: usize };

/// Parse `[text](url)` starting at `start` (text[start] == '[').
fn parseLink(text: []const u8, start: usize) ?Link {
    const text_end = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (text_end + 1 >= text.len or text[text_end + 1] != '(') return null;
    const url_start = text_end + 2;
    const url_end = std.mem.indexOfScalarPos(u8, text, url_start, ')') orelse return null;
    if (url_end == url_start) return null;
    return .{ .text_end = text_end, .url_start = url_start, .url_end = url_end };
}

/// End of the bare `http://` or `https://` URL starting at `start`. It stops
/// at whitespace and at a non-ASCII character (so CJK punctuation right after
/// a URL is not swallowed), and leaves sentence punctuation outside.
fn bareUrlEnd(text: []const u8, start: usize) ?usize {
    const rest = text[start..];
    const scheme_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        8
    else if (std.mem.startsWith(u8, rest, "http://"))
        7
    else
        return null;
    var end = start + scheme_len;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (c <= ' ' or c >= 0x80 or c == '<' or c == '>' or c == '"' or c == '`') break;
    }
    while (end > start + scheme_len and std.mem.indexOfScalar(u8, ".,;:!?)'*_", text[end - 1]) != null) end -= 1;
    return if (end > start + scheme_len) end else null;
}

// ---- code highlighting ----

const KEYWORDS = [_][]const u8{
    // zig / c / go / rust / js / ts / python shared set
    "fn",       "const",     "var",    "pub",     "return", "if",        "else",     "while",
    "for",      "struct",    "enum",   "union",   "switch", "defer",     "errdefer", "try",
    "catch",    "error",     "true",   "false",   "null",   "undefined", "async",    "await",
    "function", "class",     "let",    "import",  "export", "from",      "new",      "this",
    "self",     "def",       "lambda", "pass",    "elif",   "raise",     "with",     "in",
    "is",       "not",       "and",    "or",      "break",  "continue",  "package",  "func",
    "type",     "interface", "map",    "chan",    "go",     "select",    "range",    "impl",
    "trait",    "match",     "use",    "mut",     "static", "void",      "int",      "float",
    "double",   "char",      "bool",   "string",  "public", "private",   "extends",  "super",
};

fn isKeywordIdent(ident: []const u8) bool {
    for (KEYWORDS) |kw| {
        if (std.mem.eql(u8, kw, ident)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Highlight one line of code (strings, comments, numbers, keywords). Text
/// outside those keeps the default color, as with pi's highlighter.
fn highlightCode(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: []const u8, lang: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        // Line comments
        const comment_start = if (c == '/' and i + 1 < line.len and line[i + 1] == '/')
            true
        else if (c == '#' and isHashLang(lang))
            true
        else
            false;
        if (comment_start) {
            try out.appendSlice(alloc, C_SYN_COMMENT);
            try out.appendSlice(alloc, line[i..]);
            try out.appendSlice(alloc, C_RESET);
            return;
        }
        // Strings
        if (c == '"' or c == '\'' or c == '`') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (line[j] == c) break;
            }
            const end = @min(j + 1, line.len);
            try out.appendSlice(alloc, C_SYN_STRING);
            try out.appendSlice(alloc, line[i..end]);
            try out.appendSlice(alloc, C_RESET);
            i = end;
            continue;
        }
        // Numbers
        if (c >= '0' and c <= '9') {
            var j = i;
            while (j < line.len and (isIdentChar(line[j]) or line[j] == '.')) j += 1;
            try out.appendSlice(alloc, C_SYN_NUMBER);
            try out.appendSlice(alloc, line[i..j]);
            try out.appendSlice(alloc, C_RESET);
            i = j;
            continue;
        }
        // Identifiers / keywords
        if (isIdentChar(c)) {
            var j = i;
            while (j < line.len and isIdentChar(line[j])) j += 1;
            if (isKeywordIdent(line[i..j])) {
                try out.appendSlice(alloc, C_SYN_KEYWORD);
                try out.appendSlice(alloc, line[i..j]);
                try out.appendSlice(alloc, C_RESET);
            } else {
                try out.appendSlice(alloc, line[i..j]);
            }
            i = j;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
}

fn isHashLang(lang: []const u8) bool {
    const langs = [_][]const u8{ "py", "python", "sh", "bash", "shell", "zsh", "yaml", "yml", "rb", "ruby", "conf", "toml" };
    for (langs) |l| {
        if (std.mem.eql(u8, lang, l)) return true;
    }
    return false;
}

/// Languages that are just text: no highlighting and no code block color.
fn isPlainLang(lang: []const u8) bool {
    const langs = [_][]const u8{ "text", "txt", "plaintext", "plain" };
    for (langs) |l| {
        if (std.mem.eql(u8, lang, l)) return true;
    }
    return false;
}

// ---- ANSI-aware wrapping ----

/// Break a styled line into rows of at most `width` columns and append them
/// to `out`. Rows break at spaces; a word longer than a row is split between
/// characters, and a wide character can start a row (CJK text has no spaces).
/// Escape sequences take no columns. The SGR state at a break is closed on
/// that row and opened again on the next.
fn wrapStyled(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]u8), line: []const u8, width_in: usize) !void {
    const width = @max(width_in, 1);
    if (visibleWidth(line) <= width) {
        const copy = try alloc.dupe(u8, line);
        errdefer alloc.free(copy);
        try out.append(alloc, copy);
        return;
    }

    var cur: std.ArrayListUnmanaged(u8) = .empty;
    errdefer cur.deinit(alloc);
    // SGR sequences since the last reset: replaying them restores the style.
    var active: std.ArrayListUnmanaged([]const u8) = .empty;
    defer active.deinit(alloc);
    // Open OSC 8 hyperlink (its URL), if a break happens mid-link: close it
    // at the end of the row and re-open at the head of the next one.
    var active_link_url: ?[]const u8 = null;
    var col: usize = 0;
    var continuation = false;

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            const end = escapeEnd(line, i);
            const seq = line[i..end];
            try cur.appendSlice(alloc, seq);
            if (isSgr(seq)) {
                if (isSgrReset(seq)) active.clearRetainingCapacity() else try active.append(alloc, seq);
            } else if (seq.len > 5 and seq[1] == ']' and std.mem.startsWith(u8, seq[2..], "8;")) {
                // OSC 8: the payload after "8;;" up to the terminator is the
                // URL; an empty URL closes the link.
                const term = std.mem.lastIndexOf(u8, seq, "\x1b\\") orelse seq.len;
                const payload = if (term >= 4 and term <= seq.len) seq[4..term] else "";
                if (payload.len == 0) {
                    if (active_link_url) |u| alloc.free(u);
                    active_link_url = null;
                } else {
                    if (active_link_url) |u| alloc.free(u);
                    active_link_url = try alloc.dupe(u8, payload);
                }
            }
            i = end;
            continue;
        }
        if (c == ' ') {
            if (col + 1 > width) {
                try breakRow(alloc, out, &cur, active.items, active_link_url);
                col = 0;
                continuation = true;
            } else if (!(continuation and col == 0)) {
                // A row that continues a broken line does not start with the
                // space the break happened at.
                try cur.append(alloc, ' ');
                col += 1;
            }
            i += 1;
            continue;
        }

        const word_end = wordEnd(line, i);
        const w = width_mod.visualWidth(line[i..word_end]);
        if (col + w > width and col > 0 and w <= width) {
            try breakRow(alloc, out, &cur, active.items, active_link_url);
            col = 0;
            continuation = true;
        }
        if (col + w <= width) {
            try cur.appendSlice(alloc, line[i..word_end]);
            col += w;
        } else {
            // Longer than a whole row: fill rows character by character.
            var j = i;
            while (j < word_end) {
                const char_end = width_mod.nextCharEnd(line, j);
                const cw = width_mod.visualWidth(line[j..char_end]);
                if (col + cw > width and col > 0) {
                    try breakRow(alloc, out, &cur, active.items, active_link_url);
                    col = 0;
                    continuation = true;
                }
                try cur.appendSlice(alloc, line[j..char_end]);
                col += cw;
                j = char_end;
            }
        }
        i = word_end;
    }
    const last = try cur.toOwnedSlice(alloc);
    errdefer alloc.free(last);
    try out.append(alloc, last);
}

/// End the current row: drop its trailing spaces, close the open styles, and
/// start the next row with them reopened.
fn breakRow(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]u8), cur: *std.ArrayListUnmanaged(u8), active: []const []const u8, active_link_url: ?[]const u8) !void {
    while (cur.items.len > 0 and cur.items[cur.items.len - 1] == ' ') cur.shrinkRetainingCapacity(cur.items.len - 1);
    if (active_link_url != null) try cur.appendSlice(alloc, "\x1b]8;;\x1b\\");
    if (active.len > 0) try cur.appendSlice(alloc, C_RESET);
    const row = try cur.toOwnedSlice(alloc);
    errdefer alloc.free(row);
    try out.append(alloc, row);
    cur.* = .empty;
    for (active) |sgr| try cur.appendSlice(alloc, sgr);
    if (active_link_url) |url| {
        try cur.appendSlice(alloc, "\x1b]8;;");
        try cur.appendSlice(alloc, url);
        try cur.appendSlice(alloc, "\x1b\\");
    }
}

/// End of the unbreakable unit starting at `line[start]`: a run of narrow
/// characters up to the next space or escape sequence, or one wide character.
fn wordEnd(line: []const u8, start: usize) usize {
    var j = start;
    while (j < line.len and line[j] != ' ' and line[j] != 0x1b) {
        const char_end = width_mod.nextCharEnd(line, j);
        if (width_mod.visualWidth(line[j..char_end]) >= 2) {
            // A wide character is a unit of its own, and ends the run before it.
            return if (j == start) char_end else j;
        }
        j = char_end;
    }
    return j;
}

/// Columns `styled` takes on screen: escape sequences take none.
fn visibleWidth(styled: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < styled.len) {
        if (styled[i] == 0x1b) {
            i = escapeEnd(styled, i);
            continue;
        }
        const end = width_mod.nextCharEnd(styled, i);
        total += width_mod.visualWidth(styled[i..end]);
        i = end;
    }
    return total;
}

/// Index just past the escape sequence starting at `s[start]` (an ESC byte).
pub fn escapeEnd(s: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= s.len) return s.len;
    switch (s[i]) {
        '[' => { // CSI: parameters, then a final byte 0x40..0x7E
            i += 1;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7E)) i += 1;
            return @min(i + 1, s.len);
        },
        ']' => { // OSC: terminated by BEL or ESC \
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == 0x07) return i + 1;
                if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') return i + 2;
            }
            return s.len;
        },
        else => return i + 1,
    }
}

fn isSgr(seq: []const u8) bool {
    return seq.len >= 3 and seq[1] == '[' and seq[seq.len - 1] == 'm';
}

fn isSgrReset(seq: []const u8) bool {
    const params = seq[2 .. seq.len - 1];
    return params.len == 0 or std.mem.eql(u8, params, "0");
}

// ---- tests ----

const t = std.testing;

/// `row` without its escape sequences. Free with the testing allocator.
fn plain(row: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(t.allocator);
    var i: usize = 0;
    while (i < row.len) {
        if (row[i] == 0x1b) {
            i = escapeEnd(row, i);
        } else {
            try out.append(t.allocator, row[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(t.allocator);
}

/// Render `src` and compare the rows, without styling, to `expected`.
fn expectRows(expected: []const []const u8, src: []const u8, width: usize) !void {
    const rows = try render(t.allocator, src, width);
    defer freeLines(t.allocator, rows);
    try expectPlainRows(expected, rows);
}

fn expectPlainRows(expected: []const []const u8, rows: []const []u8) !void {
    for (rows, 0..) |row, i| {
        const got = try plain(row);
        defer t.allocator.free(got);
        if (i >= expected.len) {
            std.debug.print("unexpected row {d}: '{s}'\n", .{ i, got });
            return error.TestUnexpectedResult;
        }
        try t.expectEqualStrings(expected[i], got);
    }
    try t.expectEqual(expected.len, rows.len);
}

fn findLine(lines: anytype, needle: []const u8) bool {
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) return true;
    }
    return false;
}

test "headings: level 1 underlined, level 3 keeps its prefix" {
    const rows = try render(t.allocator, "# One\n## Two\n### Three", 80);
    defer freeLines(t.allocator, rows);
    // A blank row separates blocks even though the source has none.
    try expectPlainRows(&.{ "One", "", "Two", "", "### Three" }, rows);
    try t.expectEqualStrings(C_BOLD ++ C_UNDER ++ C_HEADING ++ "One" ++ C_RESET, rows[0]);
    try t.expectEqualStrings(C_BOLD ++ C_HEADING ++ "Two" ++ C_RESET, rows[2]);
    try t.expectEqualStrings(C_BOLD ++ C_HEADING ++ "### Three" ++ C_RESET, rows[4]);
}

test "heading and bold" {
    const lines = try render(t.allocator, "# Title\n\nhello **world**", 80);
    defer freeLines(t.allocator, lines);
    try expectPlainRows(&.{ "Title", "", "hello world" }, lines);
    try t.expect(findLine(lines, C_BOLD ++ "world" ++ C_BOLD_OFF));
}

test "blocks are one blank row apart" {
    // Several blank source lines collapse; a heading gets a gap before text.
    try expectRows(&.{ "a", "", "b" }, "a\n\n\n\nb\n\n", 80);
    try expectRows(&.{ "T", "", "text", "more" }, "# T\ntext\nmore", 80);
    // A list may follow a paragraph directly.
    try expectRows(&.{ "intro:", "- one" }, "intro:\n- one", 80);
}

test "inline code keeps the surrounding style" {
    const lines = try render(t.allocator, "use `foo()` now", 80);
    defer freeLines(t.allocator, lines);
    try t.expectEqualStrings("use " ++ C_CODE ++ "foo()" ++ C_FG_OFF ++ " now", lines[0]);

    // In a heading the heading style resumes after the code span.
    const head = try render(t.allocator, "## a `b` c", 80);
    defer freeLines(t.allocator, head);
    const style = C_BOLD ++ C_HEADING;
    try t.expectEqualStrings(style ++ "a " ++ C_CODE ++ "b" ++ C_FG_OFF ++ style ++ " c" ++ C_RESET, head[0]);
}

test "base style is applied to running text and resumes after inline styles" {
    const base = "\x1b[38;2;150;160;164m" ++ C_ITALIC;
    const rows = try renderWith(t.allocator, "a **b** c\n\n- item", 80, .{ .base_style = base });
    defer freeLines(t.allocator, rows);
    try t.expectEqualStrings(base ++ "a " ++ C_BOLD ++ "b" ++ C_BOLD_OFF ++ base ++ " c" ++ C_RESET, rows[0]);
    try t.expectEqualStrings(C_BULLET ++ "- " ++ C_RESET ++ base ++ "item" ++ C_RESET, rows[2]);
}

test "emphasis, strikethrough and escapes" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);

    try renderInline(t.allocator, &out, "*it* _too_ ***both*** ~~gone~~");
    try t.expectEqualStrings(
        C_ITALIC ++ "it" ++ C_ITALIC_OFF ++ " " ++ C_ITALIC ++ "too" ++ C_ITALIC_OFF ++ " " ++
            C_BOLD ++ C_ITALIC ++ "both" ++ C_ITALIC_OFF ++ C_BOLD_OFF ++ " " ++
            C_STRIKE ++ "gone" ++ C_STRIKE_OFF,
        out.items,
    );

    // Underscores inside words, spaced asterisks and escapes are literal.
    out.clearRetainingCapacity();
    try renderInline(t.allocator, &out, "snake_case_name 2 * 3 * 4 \\*not\\* __init__.py a_b");
    try t.expectEqualStrings("snake_case_name 2 * 3 * 4 *not* " ++ C_BOLD ++ "init" ++ C_BOLD_OFF ++ ".py a_b", out.items);
}

test "links: label with target, bare target once" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    const link = C_LINK ++ C_UNDER;
    const end = C_UNDER_OFF ++ C_FG_OFF;

    // OSC 8 hyperlinks are on by default: the label is wrapped, the URL is
    // not printed inline (pi parity).
    try renderInline(t.allocator, &out, "see [docs](https://x.y) ok");
    try t.expectEqualStrings("see " ++ "\x1b]8;;https://x.y\x1b\\" ++ link ++ "docs" ++ end ++ "\x1b]8;;\x1b\\" ++ " ok", out.items);

    // The label is the target: it is not repeated.
    out.clearRetainingCapacity();
    try renderInline(t.allocator, &out, "[https://x.y](https://x.y)");
    try t.expectEqualStrings("\x1b]8;;https://x.y\x1b\\" ++ link ++ "https://x.y" ++ end ++ "\x1b]8;;\x1b\\", out.items);

    // A bare URL is a link; the sentence's full stop stays outside.
    out.clearRetainingCapacity();
    try renderInline(t.allocator, &out, "at https://x.y/a?b=1. Done");
    try t.expectEqualStrings("at " ++ "\x1b]8;;https://x.y/a?b=1\x1b\\" ++ link ++ "https://x.y/a?b=1" ++ end ++ "\x1b]8;;\x1b\\" ++ ". Done", out.items);

    // Disabled (tmux/dumb terminals): the legacy "(url)" fallback.
    hyperlinks_enabled = false;
    defer hyperlinks_enabled = true;
    out.clearRetainingCapacity();
    try renderInline(t.allocator, &out, "see [docs](https://x.y) ok");
    try t.expectEqualStrings("see " ++ link ++ "docs" ++ end ++ C_LINK_URL ++ " (https://x.y)" ++ C_FG_OFF ++ " ok", out.items);
}

test "code fence: language on the fence row, highlighted code" {
    const src = "```zig\nconst x = 1; // hey\n```";
    const lines = try render(t.allocator, src, 80);
    defer freeLines(t.allocator, lines);
    try expectPlainRows(&.{ "```zig", "  const x = 1; // hey", "```" }, lines);
    try t.expectEqualStrings(C_MUTED ++ "```zig" ++ C_RESET, lines[0]);
    try t.expect(findLine(lines, C_SYN_KEYWORD ++ "const"));
    try t.expect(findLine(lines, C_SYN_NUMBER ++ "1"));
    try t.expect(findLine(lines, C_SYN_COMMENT ++ "// hey"));
}

test "code fence: no language is plain code block color; unterminated still shows" {
    const lines = try render(t.allocator, "```\nconst x = 1;\n```", 80);
    defer freeLines(t.allocator, lines);
    try t.expectEqualStrings(CODE_INDENT ++ C_CODE_BLOCK ++ "const x = 1;" ++ C_RESET, lines[1]);

    // Markdown inside a fence is not interpreted, and a block that is still
    // streaming has no closing fence.
    try expectRows(&.{ "```md", "  # not a heading", "  - not a list" }, "```md\n# not a heading\n- not a list", 80);
}

test "lists: bullets, numbers, tasks, nesting" {
    try expectRows(&.{
        "- one",
        "- two",
        "    - nested",
        "        - deeper",
        "    - back",
        "1. first",
        "2. second",
        "- [ ] todo",
        "- [x] done",
    }, "- one\n* two\n  - nested\n    - deeper\n  - back\n1. first\n2) second\n- [ ] todo\n- [X] done", 80);

    const rows = try render(t.allocator, "- item\n3. third", 80);
    defer freeLines(t.allocator, rows);
    try t.expectEqualStrings(C_BULLET ++ "- " ++ C_RESET ++ "item", rows[0]);
    try t.expectEqualStrings(C_BULLET ++ "3. " ++ C_RESET ++ "third", rows[1]);
}

test "list items wrap under their text" {
    try expectRows(&.{
        "- alpha beta gamma",
        "  delta epsilon",
        "    - nested item that",
        "      wraps too",
        "  continued text",
    }, "- alpha beta gamma delta epsilon\n  - nested item that wraps too\n  continued text", 22);
}

test "an indented line continues the item whose text it lines up with" {
    // The source nests by 2 columns, the output by 4: ownership is decided in
    // source columns, the position in output columns.
    try expectRows(&.{
        "- a",
        "    - b",
        "      under b",
        "  under a",
        "back to a paragraph",
    }, "- a\n  - b\n    under b\n  under a\nback to a paragraph", 40);
}

test "blockquote: border on every row, muted italic text" {
    const rows = try render(t.allocator, "> quoted **text** that is long enough to wrap\n> second", 24);
    defer freeLines(t.allocator, rows);
    try expectPlainRows(&.{ "│ quoted text that is", "│ long enough to wrap", "│ second" }, rows);
    try t.expect(std.mem.startsWith(u8, rows[0], C_MUTED ++ "│ " ++ C_RESET ++ C_MUTED ++ C_ITALIC));
    // The style carries onto the wrapped row.
    try t.expect(std.mem.startsWith(u8, rows[1], C_MUTED ++ "│ " ++ C_RESET ++ C_MUTED ++ C_ITALIC));
}

test "horizontal rule is at most 80 columns" {
    const wide = try render(t.allocator, "---", 120);
    defer freeLines(t.allocator, wide);
    try t.expectEqual(@as(usize, 80), visibleWidth(wide[0]));
    const narrow = try render(t.allocator, "***", 30);
    defer freeLines(t.allocator, narrow);
    try t.expectEqual(@as(usize, 30), visibleWidth(narrow[0]));
}

test "table: full borders, bold header, a separator between rows" {
    const src = "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 5 |";
    const rows = try render(t.allocator, src, 80);
    defer freeLines(t.allocator, rows);
    try expectPlainRows(&.{
        "┌───────┬─────┐",
        "│ Name  │ Age │",
        "├───────┼─────┤",
        "│ Alice │ 30  │",
        "├───────┼─────┤",
        "│ Bob   │ 5   │",
        "└───────┴─────┘",
    }, rows);
    try t.expectEqualStrings("│ " ++ C_BOLD ++ "Name " ++ C_BOLD_OFF ++ " │ " ++ C_BOLD ++ "Age" ++ C_BOLD_OFF ++ " │", rows[1]);
}

test "table: cells wrap when the table is too wide" {
    const src = "| Key | Description |\n|---|---|\n| a | one two three four five six |";
    const rows = try render(t.allocator, src, 24);
    defer freeLines(t.allocator, rows);
    try expectPlainRows(&.{
        "┌─────┬────────────────┐",
        "│ Key │ Description    │",
        "├─────┼────────────────┤",
        "│ a   │ one two three  │",
        "│     │ four five six  │",
        "└─────┴────────────────┘",
    }, rows);
    for (rows) |row| try t.expectEqual(@as(usize, 24), visibleWidth(row));
}

test "table: inline styles in cells, missing cells, no leading pipe" {
    const src = "Name | Note\n--- | ---\n`a` | **b**\nonly";
    try expectRows(&.{
        "┌──────┬──────┐",
        "│ Name │ Note │",
        "├──────┼──────┤",
        "│ a    │ b    │",
        "└──────┴──────┘",
        "",
        "only",
    }, src, 80);
    // A rule under a line of text is not a table.
    try expectRows(&.{ "a | b", "", "──────────" }, "a | b\n---", 10);
}

test "wrapping breaks at spaces" {
    try expectRows(&.{ "aaa bbb", "ccc ddd" }, "aaa bbb ccc ddd", 7);
    // The space at the break is dropped; indentation of the first row stays.
    try expectRows(&.{ "one two", "three" }, "one two   three", 9);
}

test "a word longer than the row is split" {
    var src: [200]u8 = undefined;
    @memset(&src, 'x');
    const lines = try render(t.allocator, &src, 40);
    defer freeLines(t.allocator, lines);
    try t.expectEqual(@as(usize, 5), lines.len);
    for (lines) |l| try t.expectEqual(@as(usize, 40), visibleWidth(l));
}

test "wide characters wrap by column, and can start a row" {
    // Eight CJK characters are 16 columns: five fit in 10, three follow.
    const nihao = "\xE4\xBD\xA0\xE5\xA5\xBD\xE4\xB8\x96\xE7\x95\x8C";
    const rows = try render(t.allocator, nihao ++ nihao, 10);
    defer freeLines(t.allocator, rows);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqual(@as(usize, 10), visibleWidth(rows[0]));
    try t.expectEqual(@as(usize, 6), visibleWidth(rows[1]));
}

test "styles carry over a wrapped row" {
    const rows = try render(t.allocator, "**bold words here**", 10);
    defer freeLines(t.allocator, rows);
    try t.expectEqualStrings(C_BOLD ++ "bold words" ++ C_RESET, rows[0]);
    try t.expectEqualStrings(C_BOLD ++ "here" ++ C_BOLD_OFF, rows[1]);
}

test "box-drawing characters are one column wide" {
    try t.expectEqual(@as(usize, 3), visibleWidth("│─•"));
    try t.expectEqual(@as(usize, 2), visibleWidth(C_BOLD ++ "ab" ++ C_RESET));
}
