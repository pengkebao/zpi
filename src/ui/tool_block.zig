//! Tool execution block renderer (pi: ToolExecutionComponent plus the per-tool
//! renderers in core/tools/renderers/*).
//!
//! One tool call renders as a scrollback block:
//!
//!   <blank row>               Spacer(1), no background
//!   <bg> padding row          Box paddingY = 1
//!   <bg> call header          per tool, e.g. `$ ls -la` or `read src/a.zig:1-50`
//!   <bg> result preview       collapsed by default, following pi's per-tool rules
//!   <bg> padding row
//!
//! The background shows the call state (pending / success / error) and every
//! box row is padded to the full width, so the block reads as one unit.
//!
//! Pure: no IO and no global state. `render` returns an owned string of
//! '\n'-joined rows.

const std = @import("std");
const wmod = @import("width.zig");

// ---- pi dark theme (okhsl converted to sRGB with pi-tui's color pipeline) ----
const RESET = "\x1b[0m";
const BG_PENDING = "\x1b[48;2;52;56;58m"; // toolPendingBg  okhsl(229 5% 24%)
const BG_SUCCESS = "\x1b[48;2;37;65;49m"; // toolSuccessBg  okhsl(158 46% 25%)
const BG_ERROR = "\x1b[48;2;91;40;42m"; // toolErrorBg    okhsl(19 54% 25%)
const FG_OUTPUT = "\x1b[38;2;157;165;169m"; // toolOutput = muted  okhsl(229 6% 67%)
const FG_MUTED = FG_OUTPUT;
const FG_DIM = "\x1b[38;2;126;136;142m"; // dim  okhsl(229 8% 56%)
const FG_ACCENT = "\x1b[38;2;167;152;215m"; // accent (violet)
const FG_WARNING = "\x1b[38;2;205;154;34m"; // warning (yellow)
const FG_ERROR = "\x1b[38;2;234;127;129m"; // error (red)
const FG_DIFF_ADDED = "\x1b[38;2;104;183;141m"; // toolDiffAdded (green)
const FG_DIFF_REMOVED = FG_ERROR; // toolDiffRemoved
const FG_DIFF_CONTEXT = FG_OUTPUT; // toolDiffContext
/// toolTitle (= text) in bold.
const TITLE = "\x1b[1m\x1b[38;2;222;224;225m";

/// Box paddingX (pi: outputPad).
const PAD_X = 1;

// Collapsed preview sizes, as in pi's renderers.
const BASH_PREVIEW_ROWS = 5; // visual rows, kept from the end
const READ_PREVIEW_LINES = 10;
const WRITE_PREVIEW_LINES = 10;
const GREP_PREVIEW_LINES = 15;
const LIST_PREVIEW_LINES = 20; // find, ls
const FALLBACK_PREVIEW_LINES = 10;
const COLLAPSED_ARGS_CHARS = 100;

/// One tool call to display.
pub const ToolView = struct {
    name: []const u8,
    /// Raw JSON arguments, as sent by the model.
    args: []const u8,
    /// Result text; empty while the call is still running.
    result: []const u8 = "",
    is_error: bool = false,
    /// True until the result arrives (pending background, no result rows).
    pending: bool = false,
    /// Wall time of the execution; null when unknown.
    duration_ms: ?u64 = null,
};

pub const Options = struct {
    /// Full row width in terminal columns.
    width: usize,
    /// false: pi's collapsed preview. true: the full output.
    expanded: bool = false,
    /// Home directory, shown as `~` in paths.
    home: ?[]const u8 = null,
    /// Display text of the expand keybinding, for the "to expand" hints.
    expand_key: []const u8 = "ctrl+o",
};

/// Styled run of plain text. `style` is an SGR prefix; the renderer resets
/// after the run, so spans never need to close their own style.
const Span = struct { style: []const u8 = "", text: []const u8 };

/// One visual row inside the box; already fits the inner width.
const Row = []const Span;

/// Render `view` as a scrollback block. The caller owns the result.
/// Close an unterminated streaming-JSON prefix so a partial tool-call's
/// preview renders while the arguments are still arriving: append `"` when
/// inside a string value and `}` when the object is still open. Best-effort —
/// the full block re-renders once the arguments complete.
fn closePartialJson(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return arena.dupe(u8, "{}");
    var in_string = false;
    var escaped = false;
    var depth: usize = 0;
    for (s) |c| {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (c) {
            '\\' => {
                if (in_string) escaped = true;
            },
            '"' => in_string = !in_string,
            '{' => {
                if (!in_string) depth += 1;
            },
            '}' => {
                if (!in_string and depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, s);
    if (in_string) try out.append(arena, '"');
    while (depth > 0) : (depth -= 1) try out.append(arena, '}');
    return out.items;
}

pub fn render(alloc: std.mem.Allocator, view: ToolView, opts: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const width = @max(opts.width, 2 * PAD_X + 1);
    var b: Builder = .{ .arena = arena, .inner = width - 2 * PAD_X, .opts = opts };

    const parsed: ?std.json.Parsed(std.json.Value) =
        std.json.parseFromSlice(std.json.Value, arena, view.args, .{}) catch blk: {
            // Arguments still streaming: a JSON prefix is valid enough for a
            // preview if we close the string and the object (pi renders the
            // partial toolCall the same way). Recover the last complete
            // string value by truncating an unterminated one.
            break :blk std.json.parseFromSlice(std.json.Value, arena, try closePartialJson(arena, view.args), .{}) catch null;
        };
    const args: Args = .{ .value = if (parsed) |p| p.value else .null };

    if (eql(view.name, "bash")) {
        try renderBash(&b, view, args);
    } else if (eql(view.name, "read")) {
        try renderRead(&b, view, args);
    } else if (eql(view.name, "edit")) {
        try renderEdit(&b, view, args);
    } else if (eql(view.name, "write")) {
        try renderWrite(&b, view, args);
    } else if (eql(view.name, "grep")) {
        try renderGrep(&b, view, args);
    } else if (eql(view.name, "find")) {
        try renderFind(&b, view, args);
    } else if (eql(view.name, "ls")) {
        try renderLs(&b, view, args);
    } else {
        try renderGeneric(&b, view, args);
    }

    const bg = if (view.pending) BG_PENDING else if (view.is_error) BG_ERROR else BG_SUCCESS;
    return assemble(alloc, b.rows.items, bg, width);
}

// ---- per-tool renderers ----

/// `$ <command> (timeout Ns)`, then the last rows of the output and the wall time.
fn renderBash(b: *Builder, view: ToolView, args: Args) !void {
    const suffix: []const u8 = if (args.int("timeout")) |secs|
        try std.fmt.allocPrint(b.arena, " (timeout {d}s)", .{secs})
    else
        "";

    switch (args.str("command")) {
        .invalid => try b.line(&[_]Span{
            .{ .style = TITLE, .text = "$ " },
            .{ .style = FG_ERROR, .text = "[invalid arg]" },
            .{ .style = FG_MUTED, .text = suffix },
        }),
        .missing => try b.line(&[_]Span{
            .{ .style = TITLE, .text = "$ " },
            .{ .style = FG_OUTPUT, .text = "..." },
            .{ .style = FG_MUTED, .text = suffix },
        }),
        .value => |raw| {
            const command = try sanitize(b.arena, raw);
            if (command.len == 0) {
                try b.line(&[_]Span{
                    .{ .style = TITLE, .text = "$ " },
                    .{ .style = FG_OUTPUT, .text = "..." },
                    .{ .style = FG_MUTED, .text = suffix },
                });
            } else {
                // A multi-line command keeps its lines; the suffix follows the last.
                const lines = try splitLines(b.arena, command);
                for (lines, 0..) |l, i| {
                    const shown = if (i == 0) try std.fmt.allocPrint(b.arena, "$ {s}", .{l}) else l;
                    const tail: []const u8 = if (i + 1 == lines.len) suffix else "";
                    try b.line(&[_]Span{
                        .{ .style = TITLE, .text = shown },
                        .{ .style = FG_MUTED, .text = tail },
                    });
                }
            }
        },
    }
    if (view.pending) return;

    const output = std.mem.trim(u8, try sanitize(b.arena, view.result), " \n");
    if (output.len > 0) {
        try b.blank();
        const lines = try splitLines(b.arena, output);
        if (b.opts.expanded) {
            for (lines) |l| try b.text(FG_OUTPUT, l);
        } else {
            // pi limits visual rows, not logical lines, so one long line (minified
            // JSON) cannot fill the screen; it keeps the end, where results land.
            var preview: Builder = .{ .arena = b.arena, .inner = b.inner, .opts = b.opts };
            for (lines) |l| try preview.text(FG_OUTPUT, l);
            const rows = preview.rows.items;
            if (rows.len > BASH_PREVIEW_ROWS) {
                const skipped = rows.len - BASH_PREVIEW_ROWS;
                try b.hint(try std.fmt.allocPrint(b.arena, "{d} earlier lines", .{skipped}));
                try b.rows.appendSlice(b.arena, rows[skipped..]);
            } else {
                try b.rows.appendSlice(b.arena, rows);
            }
        }
    }
    if (view.duration_ms) |ms| {
        var buf: [32]u8 = undefined;
        try b.blank();
        try b.text(FG_MUTED, try std.fmt.allocPrint(b.arena, "Took {s}", .{formatDuration(&buf, ms)}));
    }
}

/// `read <path>:<range>`. A successful read shows no content until expanded.
fn renderRead(b: *Builder, view: ToolView, args: Args) !void {
    var range_buf: [48]u8 = undefined;
    const range = formatReadLineRange(&range_buf, args.int("offset"), args.int("limit"));
    try b.line(&[_]Span{
        .{ .style = TITLE, .text = "read" },
        .{ .text = " " },
        try b.pathSpan(args.path(), null),
        .{ .style = FG_WARNING, .text = try b.arena.dupe(u8, range) },
    });
    if (view.pending) return;
    if (!b.opts.expanded and !view.is_error) return;

    const lines = trimTrailingEmpty(try splitLines(b.arena, try sanitize(b.arena, view.result)));
    if (lines.len == 0) return;
    try b.blank();
    try b.head(lines, READ_PREVIEW_LINES, FG_OUTPUT, "");
}

/// `edit <path>`, then the diff (or the error).
fn renderEdit(b: *Builder, view: ToolView, args: Args) !void {
    try b.line(&[_]Span{
        .{ .style = TITLE, .text = "edit" },
        .{ .text = " " },
        try b.pathSpan(args.path(), null),
    });
    if (view.pending) return;

    const result = try sanitize(b.arena, view.result);
    if (view.is_error) {
        const lines = trimTrailingEmpty(try splitLines(b.arena, result));
        if (lines.len == 0) return;
        try b.blank();
        for (lines) |l| try b.text(FG_ERROR, l);
        return;
    }

    // The tool reports "Successfully applied N edit(s) to <path>", a blank line,
    // then the diff. pi shows only the diff.
    var diff: []const u8 = result;
    if (std.mem.startsWith(u8, diff, "Successfully applied")) {
        diff = if (std.mem.indexOf(u8, diff, "\n\n")) |sep| diff[sep + 2 ..] else "";
    }
    const lines = trimTrailingEmpty(try splitLines(b.arena, diff));
    if (lines.len == 0) return;
    try b.blank();
    // Group the diff: a hunk of exactly one removed and one added line is a
    // single-line modification — pi highlights the changed WORDS with
    // inverse instead of coloring the whole lines (pi: renderIntraLineDiff).
    var i: usize = 0;
    while (i < lines.len) {
        const kind = diffKind(lines[i]);
        if (kind == .removed) {
            var removed_end = i;
            while (removed_end < lines.len and diffKind(lines[removed_end]) == .removed) removed_end += 1;
            var added_end = removed_end;
            while (added_end < lines.len and diffKind(lines[added_end]) == .added) added_end += 1;
            const removed_count = removed_end - i;
            const added_count = added_end - removed_end;
            if (removed_count == 1 and added_count == 1) {
                const old_line = lineContent(lines[i]);
                const new_line = lineContent(lines[removed_end]);
                if (wordDiffLines(b.arena, old_line, new_line) catch null) |pair| {
                    defer b.arena.free(pair.removed);
                    defer b.arena.free(pair.added);
                    // Keep each row's `-N ` prefix; the word-level inverses
                    // ride on the row color (7m/27m only touch the reverse bit).
                    const rem = try std.fmt.allocPrint(b.arena, FG_DIFF_REMOVED ++ "{s}{s}", .{ lines[i][0 .. lines[i].len - old_line.len], pair.removed });
                    const add = try std.fmt.allocPrint(b.arena, FG_DIFF_ADDED ++ "{s}{s}", .{ lines[removed_end][0 .. lines[removed_end].len - new_line.len], pair.added });
                    try b.text("", rem);
                    try b.text("", add);
                    i = added_end;
                    continue;
                }
            }
            // Fallback: whole-line colors.
            for (lines[i..added_end]) |l| try b.text(diffStyle(l), l);
            i = added_end;
            continue;
        }
        try b.text(diffStyle(lines[i]), lines[i]);
        i += 1;
    }
}

// ---- Intra-line (word) diff (pi: renderIntraLineDiff with jsdiff.diffWords) ----

/// A whitespace-separated word / single punctuation token.
const Token = struct { text: []const u8 };

fn tokenizeWords(arena: std.mem.Allocator, line: []const u8) ![]Token {
    var out: std.ArrayListUnmanaged(Token) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        const start = i;
        if (std.ascii.isAlphanumeric(line[i]) or line[i] == '_') {
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
        } else if (line[i] < 0x80) {
            i += 1; // single-byte punctuation / space
        } else {
            // Multi-byte (CJK etc.): one whole character per token, never a
            // byte slice — inverse-video boundaries between tokens must not
            // split a character (split bytes render as ? diamonds).
            i += charLen(line, i);
        }
        try out.append(arena, .{ .text = line[start..i] });
    }
    return out.toOwnedSlice(arena);
}

const WordPair = struct { removed: []u8, added: []u8 };

const INV_ON = "\x1b[7m";
const INV_OFF = "\x1b[27m";

/// Word-level diff of two lines, rendered with inverse on the changed tokens
/// (pi: jsdiff.diffWords + theme.inverse). Returns null when either line is
/// too long for the DP table — the caller keeps whole-line colors then.
fn wordDiffLines(arena: std.mem.Allocator, old_line: []const u8, new_line: []const u8) !?WordPair {
    const MAX_TOKENS = 400;
    const a = try tokenizeWords(arena, old_line);
    const b = try tokenizeWords(arena, new_line);
    if (a.len > MAX_TOKENS or b.len > MAX_TOKENS) return null;

    // LCS table (tokens compared by content).
    const table = try arena.alloc(u16, (a.len + 1) * (b.len + 1));
    defer arena.free(table);
    @memset(table, 0);
    var ai = a.len;
    while (ai > 0) {
        ai -= 1;
        var bi = b.len;
        while (bi > 0) {
            bi -= 1;
            table[ai * (b.len + 1) + bi] = if (std.mem.eql(u8, a[ai].text, b[bi].text))
                table[(ai + 1) * (b.len + 1) + bi + 1] + 1
            else
                @max(table[(ai + 1) * (b.len + 1) + bi], table[ai * (b.len + 1) + bi + 1]);
        }
    }

    // Walk the LCS path emitting per-side text: same runs plain, changed runs
    // inverse. The leading whitespace of the first changed run stays outside
    // the inverse (pi strips it so indentation is not highlighted).
    var removed: std.ArrayListUnmanaged(u8) = .empty;
    var added: std.ArrayListUnmanaged(u8) = .empty;
    var first_removed = true;
    var first_added = true;
    ai = 0;
    var bi: usize = 0;
    const Ctx = struct {
        fn appendChanged(list: *std.ArrayListUnmanaged(u8), al: std.mem.Allocator, value: []const u8, strip_leading_ws: *bool) !void {
            var value_v = value;
            if (strip_leading_ws.*) {
                var k: usize = 0;
                while (k < value_v.len and (value_v[k] == ' ' or value_v[k] == '\t')) k += 1;
                if (k > 0) try list.appendSlice(al, value_v[0..k]);
                value_v = value_v[k..];
                strip_leading_ws.* = false;
            }
            if (value_v.len > 0) {
                try list.appendSlice(al, INV_ON);
                try list.appendSlice(al, value_v);
                try list.appendSlice(al, INV_OFF);
            }
        }
    };

    while (ai < a.len or bi < b.len) {
        if (ai < a.len and bi < b.len and std.mem.eql(u8, a[ai].text, b[bi].text)) {
            try removed.appendSlice(arena, a[ai].text);
            try added.appendSlice(arena, b[bi].text);
            first_removed = false;
            first_added = false;
            ai += 1;
            bi += 1;
        } else if (bi >= b.len or (ai < a.len and table[(ai + 1) * (b.len + 1) + bi] >= table[ai * (b.len + 1) + bi + 1])) {
            try Ctx.appendChanged(&removed, arena, a[ai].text, &first_removed);
            ai += 1;
        } else {
            try Ctx.appendChanged(&added, arena, b[bi].text, &first_added);
            bi += 1;
        }
    }
    return .{ .removed = try removed.toOwnedSlice(arena), .added = try added.toOwnedSlice(arena) };
}

/// The diff row class (pi: parseDiffLine): `+N `, `-N ` are changes; an
/// optional number after a space prefix is context; anything else "other".
fn diffKind(line: []const u8) enum { removed, added, context, other } {
    if (line.len == 0) return .other;
    const prefix = line[0];
    if (prefix != '+' and prefix != '-') return if (prefix == ' ') .context else .other;
    var j: usize = 1;
    while (j < line.len and line[j] == ' ') j += 1;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
    if (j >= line.len or line[j] != ' ') return .other;
    return if (prefix == '+') .added else .removed;
}

/// The text after `-N `/`+N `/`N ` numbering.
fn lineContent(line: []const u8) []const u8 {
    var j: usize = 1;
    while (j < line.len and line[j] == ' ') j += 1;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
    if (j < line.len and line[j] == ' ') return line[j + 1 ..];
    return line[j..];
}

/// `write <path>`, then a preview of the content being written.
fn renderWrite(b: *Builder, view: ToolView, args: Args) !void {
    try b.line(&[_]Span{
        .{ .style = TITLE, .text = "write" },
        .{ .text = " " },
        try b.pathSpan(args.path(), null),
    });

    switch (args.str("content")) {
        .invalid => {
            try b.blank();
            try b.text(FG_ERROR, "[invalid content arg - expected string]");
        },
        .missing => {},
        .value => |raw| {
            const lines = trimTrailingEmpty(try splitLines(b.arena, try sanitize(b.arena, raw)));
            if (lines.len > 0) {
                try b.blank();
                const total = try std.fmt.allocPrint(b.arena, ", {d} total", .{lines.len});
                try b.head(lines, WRITE_PREVIEW_LINES, FG_OUTPUT, total);
            }
        },
    }
    if (view.pending or !view.is_error) return;

    const lines = trimTrailingEmpty(try splitLines(b.arena, try sanitize(b.arena, view.result)));
    if (lines.len == 0) return;
    try b.blank();
    for (lines) |l| try b.text(FG_ERROR, l);
}

/// `grep /<pattern>/ in <path> (<glob>) limit N`.
fn renderGrep(b: *Builder, view: ToolView, args: Args) !void {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    try spans.append(b.arena, .{ .style = TITLE, .text = "grep" });
    try spans.append(b.arena, .{ .text = " " });
    switch (args.str("pattern")) {
        .invalid => try spans.append(b.arena, .{ .style = FG_ERROR, .text = "[invalid arg]" }),
        .missing => try spans.append(b.arena, .{ .style = FG_ACCENT, .text = "//" }),
        .value => |p| try spans.append(b.arena, .{
            .style = FG_ACCENT,
            .text = try std.fmt.allocPrint(b.arena, "/{s}/", .{try sanitizeLine(b.arena, p)}),
        }),
    }
    try spans.append(b.arena, .{ .style = FG_OUTPUT, .text = " in " });
    try spans.append(b.arena, try b.searchPathSpan(args.str("path")));
    switch (args.str("glob")) {
        .value => |g| if (g.len > 0) try spans.append(b.arena, .{
            .style = FG_OUTPUT,
            .text = try std.fmt.allocPrint(b.arena, " ({s})", .{try sanitizeLine(b.arena, g)}),
        }),
        else => {},
    }
    if (args.int("limit")) |n| try spans.append(b.arena, .{
        .style = FG_OUTPUT,
        .text = try std.fmt.allocPrint(b.arena, " limit {d}", .{n}),
    });
    try b.line(spans.items);
    try b.listResult(view, GREP_PREVIEW_LINES);
}

/// `find <pattern> in <path> (limit N)`.
fn renderFind(b: *Builder, view: ToolView, args: Args) !void {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    try spans.append(b.arena, .{ .style = TITLE, .text = "find" });
    try spans.append(b.arena, .{ .text = " " });
    switch (args.str("pattern")) {
        .invalid => try spans.append(b.arena, .{ .style = FG_ERROR, .text = "[invalid arg]" }),
        .missing => {},
        .value => |p| try spans.append(b.arena, .{ .style = FG_ACCENT, .text = try sanitizeLine(b.arena, p) }),
    }
    try spans.append(b.arena, .{ .style = FG_OUTPUT, .text = " in " });
    try spans.append(b.arena, try b.searchPathSpan(args.str("path")));
    if (args.int("limit")) |n| try spans.append(b.arena, .{
        .style = FG_OUTPUT,
        .text = try std.fmt.allocPrint(b.arena, " (limit {d})", .{n}),
    });
    try b.line(spans.items);
    try b.listResult(view, LIST_PREVIEW_LINES);
}

/// `ls <path> (limit N)`.
fn renderLs(b: *Builder, view: ToolView, args: Args) !void {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    try spans.append(b.arena, .{ .style = TITLE, .text = "ls" });
    try spans.append(b.arena, .{ .text = " " });
    try spans.append(b.arena, try b.pathSpan(args.str("path"), "."));
    if (args.int("limit")) |n| try spans.append(b.arena, .{
        .style = FG_OUTPUT,
        .text = try std.fmt.allocPrint(b.arena, " (limit {d})", .{n}),
    });
    try b.line(spans.items);
    try b.listResult(view, LIST_PREVIEW_LINES);
}

/// A tool without a renderer: the name, its arguments, and the first lines of
/// the output (pi: formatToolCallWithArgs + createResultFallback).
fn renderGeneric(b: *Builder, view: ToolView, args: Args) !void {
    if (b.opts.expanded) {
        try b.text(TITLE, view.name);
        try expandedArgRows(b, args.value);
    } else {
        const pairs = try collapsedArgs(b.arena, args.value);
        try b.line(&[_]Span{
            .{ .style = TITLE, .text = view.name },
            .{ .text = if (pairs.len > 0) " " else "" },
            .{ .style = FG_MUTED, .text = pairs },
        });
    }
    if (view.pending) return;

    const lines = trimTrailingEmpty(try splitLines(b.arena, try sanitize(b.arena, view.result)));
    if (lines.len == 0) return;
    const style: []const u8 = if (view.is_error) FG_ERROR else FG_OUTPUT;
    try b.head(lines, FALLBACK_PREVIEW_LINES, style, "");
}

// ---- row building ----

const Builder = struct {
    arena: std.mem.Allocator,
    /// Content columns between the box padding.
    inner: usize,
    opts: Options,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    fn blank(self: *Builder) !void {
        try self.rows.append(self.arena, &.{});
    }

    /// Append one logical line, wrapped to the inner width.
    fn line(self: *Builder, spans: []const Span) !void {
        try wrapSpans(self.arena, spans, self.inner, &self.rows);
    }

    /// Append one logical line in a single style.
    fn text(self: *Builder, style: []const u8, s: []const u8) !void {
        try self.line(&[_]Span{.{ .style = style, .text = s }});
    }

    /// `... (<what>, <key> to expand)`. pi's keyHint: the key dim, the rest muted.
    fn hint(self: *Builder, what: []const u8) !void {
        try self.line(&[_]Span{
            .{ .style = FG_MUTED, .text = try std.fmt.allocPrint(self.arena, "... ({s},", .{what}) },
            .{ .text = " " },
            .{ .style = FG_DIM, .text = self.opts.expand_key },
            .{ .style = FG_MUTED, .text = " to expand)" },
        });
    }

    /// The first `max` logical lines (all when expanded), then a hint for the
    /// rest. `hint_extra` is appended to the "N more lines" count.
    fn head(self: *Builder, lines: []const []const u8, max: usize, style: []const u8, hint_extra: []const u8) !void {
        const shown = if (self.opts.expanded) lines.len else @min(lines.len, max);
        for (lines[0..shown]) |l| try self.text(style, l);
        if (lines.len > shown) {
            try self.hint(try std.fmt.allocPrint(self.arena, "{d} more lines{s}", .{ lines.len - shown, hint_extra }));
        }
    }

    /// Result of a listing tool (grep, find, ls): a blank row, then the head.
    fn listResult(self: *Builder, view: ToolView, max: usize) !void {
        if (view.pending) return;
        const output = std.mem.trim(u8, try sanitize(self.arena, view.result), " \n");
        if (output.len == 0) return;
        try self.blank();
        try self.head(try splitLines(self.arena, output), max, FG_OUTPUT, "");
    }

    /// A file path in accent color with the home directory shortened. A missing
    /// path shows `fallback`, or "..." while the argument is still streaming.
    fn pathSpan(self: *Builder, arg: ArgStr, fallback: ?[]const u8) !Span {
        const raw: []const u8 = switch (arg) {
            .invalid => return .{ .style = FG_ERROR, .text = "[invalid arg]" },
            .missing => "",
            .value => |v| v,
        };
        const value = if (raw.len > 0) raw else (fallback orelse return .{ .style = FG_OUTPUT, .text = "..." });
        return .{ .style = FG_ACCENT, .text = try shortenHome(self.arena, try sanitizeLine(self.arena, value), self.opts.home) };
    }

    /// The search root of grep/find, in output color; defaults to ".".
    fn searchPathSpan(self: *Builder, arg: ArgStr) !Span {
        const raw: []const u8 = switch (arg) {
            .invalid => return .{ .style = FG_ERROR, .text = "[invalid arg]" },
            .missing => "",
            .value => |v| v,
        };
        const value = if (raw.len > 0) raw else ".";
        return .{ .style = FG_OUTPUT, .text = try shortenHome(self.arena, try sanitizeLine(self.arena, value), self.opts.home) };
    }
};

/// Split `spans` into rows of at most `width` columns. Breaks between
/// characters; a character wider than the row still gets a row of its own.
fn wrapSpans(arena: std.mem.Allocator, spans: []const Span, width: usize, out: *std.ArrayListUnmanaged(Row)) !void {
    var cur: std.ArrayListUnmanaged(Span) = .empty;
    var col: usize = 0;
    for (spans) |sp| {
        var start: usize = 0;
        var i: usize = 0;
        while (i < sp.text.len) {
            // ANSI sequences are atomic and zero-width: jump over them whole.
            // Counting (or breaking inside) them leaked literal "27m"/"[27m"
            // fragments at row starts and left dangling CSIs that swallowed
            // the newline, joining rows into overlong lines.
            if (sp.text[i] == 0x1b) {
                i = escapeEnd(sp.text, i);
                continue;
            }
            const n = charLen(sp.text, i);
            const w = wmod.visualWidth(sp.text[i .. i + n]);
            if (col + w > width and col > 0) {
                if (i > start) try cur.append(arena, .{ .style = sp.style, .text = sp.text[start..i] });
                try out.append(arena, try cur.toOwnedSlice(arena));
                cur = .empty;
                col = 0;
                start = i;
            }
            col += w;
            i += n;
        }
        if (sp.text.len > start) try cur.append(arena, .{ .style = sp.style, .text = sp.text[start..] });
    }
    try out.append(arena, try cur.toOwnedSlice(arena));
}

/// Join the rows into the final block: a blank spacer row, then the box rows
/// between two padding rows, each on `bg` and padded to `width`.
fn assemble(alloc: std.mem.Allocator, rows: []const Row, bg: []const u8, width: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    // The block starts with an empty row: the spacer above the box.
    try out.append(alloc, '\n');
    try appendRow(alloc, &out, &.{}, bg, width);
    for (rows) |row| {
        try out.append(alloc, '\n');
        try appendRow(alloc, &out, row, bg, width);
    }
    try out.append(alloc, '\n');
    try appendRow(alloc, &out, &.{}, bg, width);
    return out.toOwnedSlice(alloc);
}

/// One box row. A styled span ends with a full reset, which also drops the
/// background, so the background is set again after it.
fn appendRow(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), row: Row, bg: []const u8, width: usize) !void {
    try out.appendSlice(alloc, bg);
    try out.appendNTimes(alloc, ' ', PAD_X);
    var used: usize = PAD_X;
    for (row) |sp| {
        if (sp.text.len == 0) continue;
        if (sp.style.len > 0) {
            try out.appendSlice(alloc, sp.style);
            try out.appendSlice(alloc, sp.text);
            try out.appendSlice(alloc, RESET);
            try out.appendSlice(alloc, bg);
        } else {
            try out.appendSlice(alloc, sp.text);
        }
        used += wmod.visualWidth(sp.text);
    }
    if (width > used) try out.appendNTimes(alloc, ' ', width - used);
    try out.appendSlice(alloc, RESET);
}

// ---- arguments ----

/// pi's `str()`: a string value, a missing (or null) one, or a value of
/// another type, which renders as "[invalid arg]".
const ArgStr = union(enum) { missing, invalid, value: []const u8 };

const Args = struct {
    value: std.json.Value,

    fn get(self: Args, key: []const u8) ?std.json.Value {
        return switch (self.value) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    fn str(self: Args, key: []const u8) ArgStr {
        const v = self.get(key) orelse return .missing;
        return switch (v) {
            .string => |s| .{ .value = s },
            .null => .missing,
            else => .invalid,
        };
    }

    /// The file argument: `file_path`, else `path`.
    fn path(self: Args) ArgStr {
        const primary = self.str("file_path");
        return if (primary == .missing) self.str("path") else primary;
    }

    /// An integer argument; numeric strings count, as in pi.
    fn int(self: Args, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .integer => |n| n,
            .float => |f| if (std.math.isFinite(f)) std.math.lossyCast(i64, f) else null,
            .number_string, .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
            else => null,
        };
    }
};

/// Arguments of a generic call on the title row: `key=value` pairs, cut to
/// COLLAPSED_ARGS_CHARS.
fn collapsedArgs(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    switch (value) {
        .null => {},
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (out.items.len > 0) try out.append(arena, ' ');
                try out.appendSlice(arena, entry.key_ptr.*);
                try out.append(arena, '=');
                try appendJson(arena, &out, entry.value_ptr.*);
            }
        },
        else => {
            try out.appendSlice(arena, "args=");
            try appendJson(arena, &out, value);
        },
    }
    if (out.items.len > COLLAPSED_ARGS_CHARS) {
        var cut: usize = COLLAPSED_ARGS_CHARS - 3;
        while (cut > 0 and (out.items[cut] & 0xC0) == 0x80) cut -= 1; // not inside a UTF-8 sequence
        out.shrinkRetainingCapacity(cut);
        try out.appendSlice(arena, "...");
    }
    return out.items;
}

/// Arguments of an expanded generic call: one muted `  key: value` row each,
/// strings shown raw with continuation lines indented.
fn expandedArgRows(b: *Builder, value: std.json.Value) !void {
    const o = switch (value) {
        .object => |o| o,
        else => return,
    };
    var it = o.iterator();
    while (it.next()) |entry| {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        switch (entry.value_ptr.*) {
            .string => |s| try text.appendSlice(b.arena, try sanitize(b.arena, s)),
            else => try appendJson(b.arena, &text, entry.value_ptr.*),
        }
        const lines = try splitLines(b.arena, text.items);
        for (lines, 0..) |l, i| {
            const row = if (i == 0)
                try std.fmt.allocPrint(b.arena, "  {s}: {s}", .{ entry.key_ptr.*, l })
            else
                try std.fmt.allocPrint(b.arena, "    {s}", .{l});
            try b.text(FG_MUTED, row);
        }
    }
}

/// Compact JSON text of `value` (JSON.stringify without indentation).
fn appendJson(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    var buf: [64]u8 = undefined;
    switch (value) {
        .null => try out.appendSlice(arena, "null"),
        .bool => |v| try out.appendSlice(arena, if (v) "true" else "false"),
        .integer => |v| try out.appendSlice(arena, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0"),
        .float => |v| try out.appendSlice(arena, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0"),
        .number_string => |s| try out.appendSlice(arena, s),
        .string => |s| {
            try out.append(arena, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try out.appendSlice(arena, "\\\""),
                    '\\' => try out.appendSlice(arena, "\\\\"),
                    '\n' => try out.appendSlice(arena, "\\n"),
                    '\r' => try out.appendSlice(arena, "\\r"),
                    '\t' => try out.appendSlice(arena, "\\t"),
                    else => if (c < 0x20) {
                        try out.appendSlice(arena, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "");
                    } else {
                        try out.append(arena, c);
                    },
                }
            }
            try out.append(arena, '"');
        },
        .array => |a| {
            try out.append(arena, '[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ',');
                try appendJson(arena, out, item);
            }
            try out.append(arena, ']');
        },
        .object => |o| {
            try out.append(arena, '{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(arena, ',');
                first = false;
                try appendJson(arena, out, .{ .string = entry.key_ptr.* });
                try out.append(arena, ':');
                try appendJson(arena, out, entry.value_ptr.*);
            }
            try out.append(arena, '}');
        },
    }
}

// ---- formatting helpers ----

/// Wall time as `4.2s` below a minute, then `1m 30s` and `2h 3m 4s` (pi:
/// formatToolDuration).
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    const seconds = @as(f64, @floatFromInt(ms)) / 1000.0;
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{seconds}) catch "";
    const total = ms / 1000;
    const minutes = total / 60;
    const rest = total % 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, rest }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ minutes / 60, minutes % 60, rest }) catch "";
}

/// The line range of a read call as a path suffix: `:5` or `:5-14`; empty
/// when neither argument is given (pi: formatReadLineRange).
pub fn formatReadLineRange(buf: []u8, offset: ?i64, limit: ?i64) []const u8 {
    if (offset == null and limit == null) return "";
    const start = offset orelse 1;
    const count = limit orelse return std.fmt.bufPrint(buf, ":{d}", .{start}) catch "";
    const end = start +| count -| 1;
    if (end == 0) return std.fmt.bufPrint(buf, ":{d}", .{start}) catch "";
    return std.fmt.bufPrint(buf, ":{d}-{d}", .{ start, end }) catch "";
}

/// Replace a leading home directory with `~`.
fn shortenHome(arena: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    if (path.len == h.len) return "~";
    if (path[h.len] != '/') return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[h.len..]});
}

/// Color of a diff row. pi's parseDiffLine: a `+`, `-` or space, an optional
/// line number, then whitespace; anything else is context.
fn diffStyle(line: []const u8) []const u8 {
    if (line.len == 0) return FG_DIFF_CONTEXT;
    const prefix = line[0];
    if (prefix != '+' and prefix != '-') return FG_DIFF_CONTEXT;
    var i: usize = 1;
    while (i < line.len and line[i] == ' ') i += 1;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i >= line.len or line[i] != ' ') return FG_DIFF_CONTEXT;
    return if (prefix == '+') FG_DIFF_ADDED else FG_DIFF_REMOVED;
}

/// Tool output as display text (pi: getTextOutput + replaceTabs): escape
/// sequences and control characters removed, tabs widened to 3 spaces.
/// Newlines are kept.
fn sanitize(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i = escapeEnd(s, i);
        } else if (c == '\t') {
            try out.appendSlice(arena, "   ");
            i += 1;
        } else if (c == '\n' or (c >= 0x20 and c != 0x7f)) {
            try out.append(arena, c);
            i += 1;
        } else {
            i += 1; // CR and other control characters
        }
    }
    return out.items;
}

/// `sanitize` for a value that belongs on one row: newlines become spaces.
fn sanitizeLine(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try sanitize(arena, s);
    for (out) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    return out;
}

/// Index just past the escape sequence starting at `s[start]` (an ESC byte).
fn escapeEnd(s: []const u8, start: usize) usize {
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
        else => return i + 1, // two-byte sequence
    }
}

fn splitLines(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(arena, l);
    return out.items;
}

fn trimTrailingEmpty(lines: []const []const u8) []const []const u8 {
    var end = lines.len;
    while (end > 0 and std.mem.trim(u8, lines[end - 1], " ").len == 0) end -= 1;
    return lines[0..end];
}

/// Byte length of the UTF-8 character at `s[i]`, clamped to the string.
fn charLen(s: []const u8, i: usize) usize {
    const b = s[i];
    const n: usize = if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    return @min(n, s.len - i);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- tests ----

const t = std.testing;

/// The block as plain rows: escape sequences removed, trailing spaces trimmed.
/// Rows keep the leading padding column. Free with `freeRows`.
fn plainRows(alloc: std.mem.Allocator, block: []const u8) ![][]u8 {
    var rows: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (rows.items) |r| alloc.free(r);
        rows.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| {
        var row: std.ArrayListUnmanaged(u8) = .empty;
        errdefer row.deinit(alloc);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == 0x1b) {
                i = escapeEnd(raw, i);
            } else {
                try row.append(alloc, raw[i]);
                i += 1;
            }
        }
        const trimmed = std.mem.trimEnd(u8, row.items, " ");
        row.shrinkRetainingCapacity(trimmed.len);
        const owned = try row.toOwnedSlice(alloc);
        errdefer alloc.free(owned);
        try rows.append(alloc, owned);
    }
    return rows.toOwnedSlice(alloc);
}

fn freeRows(alloc: std.mem.Allocator, rows: [][]u8) void {
    for (rows) |r| alloc.free(r);
    alloc.free(rows);
}

fn expectRows(expected: []const []const u8, block: []const u8) !void {
    const rows = try plainRows(t.allocator, block);
    defer freeRows(t.allocator, rows);
    try t.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, got| try t.expectEqualStrings(want, got);
}

test "bash: collapsed keeps the last 5 rows below the hint" {
    const block = try render(t.allocator, .{
        .name = "bash",
        .args = "{\"command\":\"seq 12\"}",
        .result = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n",
        .duration_ms = 1500,
    }, .{ .width = 60 });
    defer t.allocator.free(block);
    try expectRows(&.{
        "", // spacer above the box
        "", // padding row
        " $ seq 12",
        "",
        " ... (7 earlier lines, ctrl+o to expand)",
        " 8",
        " 9",
        " 10",
        " 11",
        " 12",
        "",
        " Took 1.5s",
        "", // padding row
    }, block);
}

test "bash: expanded shows every line and the timeout suffix" {
    const block = try render(t.allocator, .{
        .name = "bash",
        .args = "{\"command\":\"seq 7\",\"timeout\":5}",
        .result = "1\n2\n3\n4\n5\n6\n7",
    }, .{ .width = 60, .expanded = true });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " $ seq 7 (timeout 5s)", "", " 1", " 2", " 3", " 4", " 5", " 6", " 7", "" }, block);
}

test "bash: the preview counts wrapped rows, not logical lines" {
    // One 100-column line wraps to 5 rows of 20 at width 22 (inner 20), plus
    // one short line: 6 rows, so one is hidden.
    var result: [104]u8 = undefined;
    @memset(result[0..100], 'a');
    @memcpy(result[100..], "\nend");
    const block = try render(t.allocator, .{
        .name = "bash",
        .args = "{\"command\":\"x\"}",
        .result = &result,
    }, .{ .width = 22 });
    defer t.allocator.free(block);
    const rows = try plainRows(t.allocator, block);
    defer freeRows(t.allocator, rows);
    // The hint wraps at this width; only its first piece matters here.
    try t.expect(std.mem.startsWith(u8, rows[4], " ... (1 earlier lines"));
    try t.expectEqualStrings(" end", rows[rows.len - 2]);
}

test "read: a successful read is one header row with the line range" {
    const block = try render(t.allocator, .{
        .name = "read",
        .args = "{\"file_path\":\"/home/u/p/main.zig\",\"offset\":5,\"limit\":10}",
        .result = "const a = 1;\nconst b = 2;\n",
    }, .{ .width = 60, .home = "/home/u" });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " read ~/p/main.zig:5-14", "" }, block);
    try t.expect(std.mem.indexOf(u8, block, FG_ACCENT ++ "~/p/main.zig") != null);
    try t.expect(std.mem.indexOf(u8, block, FG_WARNING ++ ":5-14") != null);
}

test "read: expanded shows the content, an error shows its first lines" {
    const expanded = try render(t.allocator, .{
        .name = "read",
        .args = "{\"path\":\"a.txt\"}",
        .result = "one\ntwo\n",
    }, .{ .width = 40, .expanded = true });
    defer t.allocator.free(expanded);
    try expectRows(&.{ "", "", " read a.txt", "", " one", " two", "" }, expanded);

    const failed = try render(t.allocator, .{
        .name = "read",
        .args = "{\"path\":\"missing.txt\"}",
        .result = "error: file not found",
        .is_error = true,
    }, .{ .width = 40 });
    defer t.allocator.free(failed);
    try expectRows(&.{ "", "", " read missing.txt", "", " error: file not found", "" }, failed);
}

test "background follows the call state" {
    const ok = try render(t.allocator, .{ .name = "ls", .args = "{}", .result = "a" }, .{ .width = 20 });
    defer t.allocator.free(ok);
    try t.expect(std.mem.indexOf(u8, ok, BG_SUCCESS) != null);
    try t.expect(std.mem.indexOf(u8, ok, BG_ERROR) == null);

    const failed = try render(t.allocator, .{ .name = "ls", .args = "{}", .result = "x", .is_error = true }, .{ .width = 20 });
    defer t.allocator.free(failed);
    try t.expect(std.mem.indexOf(u8, failed, BG_ERROR) != null);

    const pending = try render(t.allocator, .{ .name = "ls", .args = "{}", .pending = true }, .{ .width = 20 });
    defer t.allocator.free(pending);
    try t.expect(std.mem.indexOf(u8, pending, BG_PENDING) != null);
    try expectRows(&.{ "", "", " ls .", "" }, pending);
}

test "every box row spans the full width" {
    // Wide characters, a short line, and a line long enough to wrap.
    const head = "\xE4\xBD\xA0\xE5\xA5\xBD\nplain\n";
    var result: [head.len + 90]u8 = undefined;
    @memcpy(result[0..head.len], head);
    @memset(result[head.len..], 'x');
    const block = try render(t.allocator, .{
        .name = "bash",
        .args = "{\"command\":\"echo \xE4\xBD\xA0\xE5\xA5\xBD\"}",
        .result = &result,
        .duration_ms = 20,
    }, .{ .width = 40, .expanded = true });
    defer t.allocator.free(block);
    var it = std.mem.splitScalar(u8, block, '\n');
    try t.expectEqualStrings("", it.next().?); // the spacer has no background
    var count: usize = 0;
    while (it.next()) |raw| {
        var plain: std.ArrayListUnmanaged(u8) = .empty;
        defer plain.deinit(t.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == 0x1b) {
                i = escapeEnd(raw, i);
            } else {
                try plain.append(t.allocator, raw[i]);
                i += 1;
            }
        }
        try t.expectEqual(@as(u32, 40), wmod.visualWidth(plain.items));
        count += 1;
    }
    try t.expect(count > 6);
}

test "edit: shows the colored diff without the success line" {
    const block = try render(t.allocator, .{
        .name = "edit",
        .args = "{\"path\":\"a.txt\"}",
        .result = "Successfully applied 1 edit(s) to a.txt\n\n 1 keep\n-2 old\n+2 new\n",
    }, .{ .width = 40 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " edit a.txt", "", "  1 keep", " -2 old", " +2 new", "" }, block);
    // A 1:1 modification pair gets word-level inverse on the changed token.
    try t.expect(std.mem.indexOf(u8, block, FG_DIFF_REMOVED ++ "-2 " ++ INV_ON ++ "old" ++ INV_OFF) != null);
    try t.expect(std.mem.indexOf(u8, block, FG_DIFF_ADDED ++ "+2 " ++ INV_ON ++ "new" ++ INV_OFF) != null);
    try t.expect(std.mem.indexOf(u8, block, FG_DIFF_CONTEXT ++ " 1 keep") != null);
}

test "edit: an error is shown in the error color" {
    const block = try render(t.allocator, .{
        .name = "edit",
        .args = "{\"path\":\"a.txt\"}",
        .result = "error: oldText not found",
        .is_error = true,
    }, .{ .width = 40 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " edit a.txt", "", " error: oldText not found", "" }, block);
    try t.expect(std.mem.indexOf(u8, block, FG_ERROR ++ "error: oldText not found") != null);
}

test "write: previews the content, not the success line" {
    const block = try render(t.allocator, .{
        .name = "write",
        .args = "{\"path\":\"n.txt\",\"content\":\"1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n\"}",
        .result = "Successfully wrote 27 bytes to n.txt",
    }, .{ .width = 60 });
    defer t.allocator.free(block);
    try expectRows(&.{
        "", "", " write n.txt", "", " 1", " 2", " 3", " 4", " 5", " 6", " 7", " 8", " 9", " 10",
        " ... (2 more lines, 12 total, ctrl+o to expand)", "",
    }, block);
}

test "grep, find and ls headers" {
    const grep = try render(t.allocator, .{
        .name = "grep",
        .args = "{\"pattern\":\"foo\",\"path\":\"src\",\"glob\":\"*.zig\",\"limit\":50}",
        .result = "src/a.zig:1: foo\n",
    }, .{ .width = 60 });
    defer t.allocator.free(grep);
    try expectRows(&.{ "", "", " grep /foo/ in src (*.zig) limit 50", "", " src/a.zig:1: foo", "" }, grep);

    const find = try render(t.allocator, .{ .name = "find", .args = "{\"pattern\":\"*.md\"}", .result = "" }, .{ .width = 60 });
    defer t.allocator.free(find);
    try expectRows(&.{ "", "", " find *.md in .", "" }, find);

    const ls = try render(t.allocator, .{ .name = "ls", .args = "{\"path\":\"src\",\"limit\":5}", .result = "a\nb" }, .{ .width = 60 });
    defer t.allocator.free(ls);
    try expectRows(&.{ "", "", " ls src (limit 5)", "", " a", " b", "" }, ls);
}

test "listing tools show the head and count the rest" {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(t.allocator);
    for (0..25) |i| {
        var buf: [16]u8 = undefined;
        try result.appendSlice(t.allocator, try std.fmt.bufPrint(&buf, "f{d}\n", .{i}));
    }
    const block = try render(t.allocator, .{ .name = "ls", .args = "{}", .result = result.items }, .{ .width = 60 });
    defer t.allocator.free(block);
    const rows = try plainRows(t.allocator, block);
    defer freeRows(t.allocator, rows);
    // spacer, padding, header, blank, 20 entries, hint, padding
    try t.expectEqual(@as(usize, 26), rows.len);
    try t.expectEqualStrings(" f19", rows[23]);
    try t.expectEqualStrings(" ... (5 more lines, ctrl+o to expand)", rows[24]);
}

test "generic tool: key=value arguments and the first output lines" {
    const block = try render(t.allocator, .{
        .name = "mcp_tool",
        .args = "{\"a\":1,\"b\":\"x y\",\"c\":[true,null]}",
        .result = "done",
    }, .{ .width = 60 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " mcp_tool a=1 b=\"x y\" c=[true,null]", " done", "" }, block);
}

test "generic tool: long arguments are cut" {
    const pre = "{\"q\":\"";
    const post = "\"}";
    var args: [pre.len + 200 + post.len]u8 = undefined;
    @memcpy(args[0..pre.len], pre);
    @memset(args[pre.len..][0..200], 'z');
    @memcpy(args[pre.len + 200 ..], post);
    const block = try render(t.allocator, .{ .name = "t", .args = &args }, .{ .width = 200 });
    defer t.allocator.free(block);
    const rows = try plainRows(t.allocator, block);
    defer freeRows(t.allocator, rows);
    // " t " + 97 characters + "..."
    try t.expectEqual(@as(usize, 3 + 100), rows[2].len);
    try t.expect(std.mem.endsWith(u8, rows[2], "..."));
}

test "invalid arguments do not break the header" {
    const block = try render(t.allocator, .{ .name = "read", .args = "not json" }, .{ .width = 40 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " read ...", "" }, block);

    const typed = try render(t.allocator, .{ .name = "bash", .args = "{\"command\":42}" }, .{ .width = 40 });
    defer t.allocator.free(typed);
    try expectRows(&.{ "", "", " $ [invalid arg]", "" }, typed);
}

test "tool output is sanitized" {
    const block = try render(t.allocator, .{
        .name = "bash",
        .args = "{\"command\":\"ls --color\"}",
        .result = "a\tb\r\n\x1b[31mred\x1b[0m\x1b]8;;http://x\x07link\x1b]8;;\x07\n",
    }, .{ .width = 40 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " $ ls --color", "", " a   b", " redlink", "" }, block);
}

test "formatDuration" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("0.0s", formatDuration(&buf, 0));
    try t.expectEqualStrings("4.2s", formatDuration(&buf, 4200));
    try t.expectEqualStrings("1m 30s", formatDuration(&buf, 90_000));
    try t.expectEqualStrings("1h 2m 5s", formatDuration(&buf, 3_725_000));
}

test "formatReadLineRange" {
    var buf: [48]u8 = undefined;
    try t.expectEqualStrings("", formatReadLineRange(&buf, null, null));
    try t.expectEqualStrings(":5", formatReadLineRange(&buf, 5, null));
    try t.expectEqualStrings(":5-14", formatReadLineRange(&buf, 5, 10));
    try t.expectEqualStrings(":1-10", formatReadLineRange(&buf, null, 10));
}

test "diffStyle follows the diff line format" {
    try t.expectEqualStrings(FG_DIFF_ADDED, diffStyle("+12 new"));
    try t.expectEqualStrings(FG_DIFF_REMOVED, diffStyle("- 3 old"));
    try t.expectEqualStrings(FG_DIFF_CONTEXT, diffStyle(" 12 same"));
    try t.expectEqualStrings(FG_DIFF_CONTEXT, diffStyle("+++ b/file")); // not a numbered diff row
    try t.expectEqualStrings(FG_DIFF_CONTEXT, diffStyle("   ..."));
}

test "edit diff: wrap never breaks inside ANSI sequences or CJK chars" {
    // A long removed line with CJK + an inverse word-diff span. The wrap must
    // keep every escape sequence whole (no literal "27m"/"[27m" fragments at
    // row starts) and never split a multi-byte character (split bytes render
    // as ? diamonds).
    const block = try render(t.allocator, .{
        .name = "edit",
        .args = "{\"path\":\"x.md\"}",
        .result = "Successfully applied the edit.\n\n- 5 技能（Skills）与提示模板：pi 同款发现机制与 SKILL.md 格式说明文字很长需要折行测试\n+ 5 技能（Skills）与提示模板：pi 同款发现机制与 SKILL.md 格式说明文字很长需要折行测试二",
    }, .{ .width = 60 });
    defer t.allocator.free(block);
    const rows = try plainRows(t.allocator, block);
    defer freeRows(t.allocator, rows);
    for (rows) |r| {
        try t.expect(std.mem.indexOf(u8, r, "27m") == null);
        try t.expect(std.mem.indexOf(u8, r, "[27m") == null);
        try t.expect(std.mem.indexOf(u8, r, "[7m") == null);
        try t.expect(std.mem.indexOfScalar(u8, r, '?') == null);
    }
    // All the content survived the wrap.
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(t.allocator);
    for (rows) |r| try all.appendSlice(t.allocator, r);
    try t.expect(std.mem.indexOf(u8, all.items, "同款发现机制") != null);
    try t.expect(std.mem.indexOf(u8, all.items, "折行测试二") != null);
}

test "wrapSpans: escape sequences count zero columns and stay whole" {
    const spans = [_]Span{.{ .style = "", .text = "\x1b[7m高亮文本\x1b[27m普通文本继续延续到很长的位置需要折行才可以看到结尾" }};
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer {
        for (rows.items) |r| t.allocator.free(r);
        rows.deinit(t.allocator);
    }
    try wrapSpans(t.allocator, &spans, 20, &rows);
    try t.expect(rows.items.len > 1);
    // Strip complete escape sequences; whatever remains must have no debris
    // (a sequence cut in half would leave a literal "[7m"/"[27m" fragment).
    const strip = struct {
        fn go(al: std.mem.Allocator, s: []const u8) ![]u8 {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var k: usize = 0;
            while (k < s.len) {
                if (s[k] == 0x1b) {
                    k = escapeEnd(s, k);
                } else {
                    try out.append(al, s[k]);
                    k += 1;
                }
            }
            return try out.toOwnedSlice(al);
        }
    }.go;
    for (rows.items) |r| {
        for (r) |sp| {
            const plain = try strip(t.allocator, sp.text);
            defer t.allocator.free(plain);
            try t.expect(std.mem.indexOf(u8, plain, "27m") == null);
            try t.expect(std.mem.indexOf(u8, plain, "[7m") == null);
            try t.expect(wmod.visualWidth(plain) <= 20);
        }
    }
}

test "partial streaming JSON args render a preview (closePartialJson)" {
    // Arguments mid-stream: the content string is unterminated. The write
    // block must still render path + a partial preview (pi renders the
    // partial toolCall), not "[invalid arg]".
    const block = try render(t.allocator, .{
        .name = "write",
        .args = "{\"path\": \"tasks/prd.md\", \"content\": \"first line\\nsecond li",
        .pending = true,
    }, .{ .width = 60 });
    defer t.allocator.free(block);
    try expectRows(&.{ "", "", " write tasks/prd.md", "", " first line", " second li", "" }, block);
}
