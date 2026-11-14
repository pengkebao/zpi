//! Editor - Multi-line text input with cursor, history, and @ completion.
//!
//! Behavior aligned with pi's editor:
//!   - Enter = submit, Shift+Enter / Ctrl+J / `\`+Enter = newline
//!   - Up/Down = history (single line) or cursor movement (multi-line)
//!   - Home/End / Ctrl+A / Ctrl+E = line start/end
//!   - Ctrl+W / Alt+Backspace = delete word backward
//!   - Ctrl+K = delete to line end, Ctrl+U = delete to line start
//!   - Tab = @ file-path completion (common prefix)
//!
//! The editor renders plain lines (no fake cursor); the TUI positions the
//! hardware cursor at `cursorPos()`.

const std = @import("std");
const keys = @import("keys.zig");
const wmod = @import("width.zig");

pub const EditorAction = enum { none, submit };

pub const Editor = struct {
    alloc: std.mem.Allocator,
    lines: std.array_list.Managed([]u8), // owned, one element per logical line
    cursor_line: usize = 0,
    cursor_col: usize = 0,
    history: std.array_list.Managed([]u8), // owned, most recent first
    history_index: isize = -1, // -1 = not browsing
    draft_lines: std.array_list.Managed([]u8), // state before history browsing
    draft_cursor_line: usize = 0,
    draft_cursor_col: usize = 0,
    draft_valid: bool = false,

    pub fn init(alloc: std.mem.Allocator) Editor {
        var e: Editor = .{
            .alloc = alloc,
            .lines = std.array_list.Managed([]u8).init(alloc),
            .history = std.array_list.Managed([]u8).init(alloc),
            .draft_lines = std.array_list.Managed([]u8).init(alloc),
        };
        e.lines.append(alloc.dupe(u8, "") catch unreachable) catch unreachable;
        return e;
    }

    pub fn deinit(self: *Editor) void {
        self.freeLines(&self.lines);
        self.lines.deinit();
        for (self.history.items) |h| self.alloc.free(h);
        self.history.deinit();
        self.freeLines(&self.draft_lines);
        self.draft_lines.deinit();
    }

    fn freeLines(self: *Editor, lines: *std.array_list.Managed([]u8)) void {
        for (lines.items) |l| self.alloc.free(l);
        lines.clearRetainingCapacity();
    }

    /// The full text (lines joined with '\n'). Owned.
    pub fn getText(self: *const Editor) ![]u8 {
        var total: usize = 0;
        for (self.lines.items) |l| total += l.len + 1;
        if (self.lines.items.len > 0) total -= 1;
        const out = self.alloc.alloc(u8, total) catch return error.OutOfMemory;
        var i: usize = 0;
        for (self.lines.items) |l| {
            @memcpy(out[i .. i + l.len], l);
            i += l.len;
            if (i < total) {
                out[i] = '\n';
                i += 1;
            }
        }
        return out;
    }

    pub fn getTextLen(self: *const Editor) usize {
        var total: usize = 0;
        for (self.lines.items) |l| total += l.len + 1;
        if (self.lines.items.len > 0) total -= 1;
        return total;
    }

    pub fn isEmpty(self: *const Editor) bool {
        return self.lines.items.len == 1 and self.lines.items[0].len == 0;
    }

    /// Reset the editor to a single empty line (and exit history browsing).
    pub fn clear(self: *Editor) !void {
        self.freeLines(&self.lines);
        self.lines.clearRetainingCapacity();
        const empty = self.alloc.dupe(u8, "") catch return error.OutOfMemory;
        self.lines.append(empty) catch return error.OutOfMemory;
        self.cursor_line = 0;
        self.cursor_col = 0;
        self.history_index = -1;
    }

    /// Visual cursor position within the editor (0-based line and column).
    pub fn cursorPos(self: *const Editor) struct { row: usize, col: usize } {
        return .{ .row = self.cursor_line, .col = self.cursor_col };
    }

    /// Borrow the text on the cursor's line before the cursor column
    /// (null when the cursor column is out of range for that line).
    pub fn lineBeforeCursor(self: *const Editor) ?[]const u8 {
        const line = self.lines.items[self.cursor_line];
        if (self.cursor_col > line.len) return null;
        return line[0..self.cursor_col];
    }

    /// Replace range [start, end) of the cursor's line with `insertion`
    /// and park the cursor after it (file-completion application).
    pub fn replaceRange(self: *Editor, start: usize, end: usize, insertion: []const u8) !void {
        const line = self.lines.items[self.cursor_line];
        if (end > line.len or start > end) return error.BadRange;
        const new_line = try std.fmt.allocPrint(self.lines.allocator, "{s}{s}{s}", .{ line[0..start], insertion, line[end..] });
        self.lines.allocator.free(line);
        self.lines.items[self.cursor_line] = new_line;
        self.cursor_col = start + insertion.len;
    }

    /// Visual column of the cursor (wide-char aware). `cursor_col` is a byte
    /// offset, but CJK chars occupy 2 columns, so the hardware cursor must be
    /// positioned by the visual width of the line prefix, not the byte count.
    pub fn cursorVisualCol(self: *const Editor) u32 {
        const line = self.lines.items[self.cursor_line];
        const end = if (self.cursor_col < line.len) self.cursor_col else line.len;
        return wmod.visualWidth(line[0..end]);
    }

    pub fn lineCount(self: *const Editor) usize {
        return self.lines.items.len;
    }

    /// Render the editor as wrapped visual lines (each ≤ `width` visual columns).
    /// Owned: every returned line must be freed by the caller.
    pub fn render(self: *const Editor, width: usize) !std.ArrayListUnmanaged([]u8) {
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |l| self.alloc.free(l);
            out.deinit(self.alloc);
        }
        const w: u32 = @intCast(width);
        for (self.lines.items) |line| {
            const wrapped = wrapLine(self.alloc, line, w) catch return error.OutOfMemory;
            for (wrapped) |vl| out.append(self.alloc, vl) catch return error.OutOfMemory;
            self.alloc.free(wrapped);
        }
        return out;
    }

    /// The cursor's position in VISUAL (wrapped) coordinates: (row, col).
    /// row = the visual line the cursor is on; col = visual column within it.
    pub fn cursorVisualPos(self: *const Editor, width: usize) struct { row: u32, col: u32 } {
        const w: u32 = @intCast(width);
        // Visual lines before the cursor's logical line.
        var row: u32 = 0;
        var i: usize = 0;
        while (i < self.cursor_line) : (i += 1) {
            const wrapped = wrapLine(self.alloc, self.lines.items[i], w) catch return .{ .row = 0, .col = 0 };
            row += @intCast(wrapped.len);
            for (wrapped) |vl| self.alloc.free(vl);
            self.alloc.free(wrapped);
        }
        // Wrap the cursor's line and locate the cursor byte within it.
        const line = self.lines.items[self.cursor_line];
        const wrapped = wrapLine(self.alloc, line, w) catch return .{ .row = 0, .col = 0 };
        defer {
            for (wrapped) |vl| self.alloc.free(vl);
            self.alloc.free(wrapped);
        }
        var byte_offset: usize = 0;
        var vline: u32 = 0;
        while (vline < wrapped.len) : (vline += 1) {
            const vl = wrapped[vline];
            if (self.cursor_col <= byte_offset + vl.len) {
                const col_in_vl = self.cursor_col - byte_offset;
                const col = wmod.visualWidth(vl[0..col_in_vl]);
                return .{ .row = row + vline, .col = col };
            }
            byte_offset += vl.len;
        }
        // Cursor at the very end; place at the end of the last visual line.
        const last = wrapped[wrapped.len - 1];
        return .{ .row = row + @as(u32, @intCast(wrapped.len - 1)), .col = wmod.visualWidth(last) };
    }

    /// Handle a key. Returns `.submit` if the user pressed Enter to submit.
    pub fn handleKey(self: *Editor, key: keys.Key, io: std.Io) !EditorAction {
        switch (key) {
            .char => |c| {
                if (c.ctrl and !c.alt) {
                    switch (c.c) {
                        'a' => self.moveLineStart(),
                        'e' => self.moveLineEnd(),
                        'w' => self.deleteWordBackward(),
                        'k' => self.deleteToLineEnd(),
                        'u' => self.deleteToLineStart(),
                        'j' => self.newLine() catch return .none, // Ctrl+J = newline
                        else => {},
                    }
                } else if (c.alt and !c.ctrl) {
                    switch (c.c) {
                        'b' => self.moveCursor(0, -1),
                        'f' => self.moveCursor(0, 1),
                        else => {},
                    }
                } else if (!c.ctrl and !c.alt) {
                    self.insertChar(c.c) catch return .none;
                }
            },
            .space => self.insertChar(' ') catch return .none,
            .text => |t| self.insertBytes(t.bytes[0..t.len]) catch return .none,
            .backspace => self.backspace(),
            .delete => self.deleteForward(),
            .enter => {
                // Backslash+Enter = newline (terminal without Shift+Enter).
                const line = self.lines.items[self.cursor_line];
                if (self.cursor_col > 0 and line[self.cursor_col - 1] == '\\') {
                    self.backspace();
                    self.newLine() catch return .none;
                } else {
                    return .submit;
                }
            },
            .shift_enter => self.newLine() catch return .none,
            .tab => self.completeAt(io) catch {},
            .up => {
                if (self.isSingleLine() and (self.isEmpty() or self.history_index > -1 or self.cursor_col == 0)) {
                    self.navigateHistory(-1) catch {};
                } else if (self.cursor_line == 0) {
                    self.moveLineStart();
                } else {
                    self.moveCursor(-1, 0);
                }
            },
            .down => {
                if (self.history_index > -1 and self.cursor_line == self.lines.items.len - 1) {
                    self.navigateHistory(1) catch {};
                } else if (self.cursor_line == self.lines.items.len - 1) {
                    self.moveLineEnd();
                } else {
                    self.moveCursor(1, 0);
                }
            },
            .left => self.moveCursor(0, -1),
            .right => self.moveCursor(0, 1),
            .home => self.moveLineStart(),
            .end => self.moveLineEnd(),
            else => {},
        }
        return .none;
    }

    fn isSingleLine(self: *const Editor) bool {
        return self.lines.items.len == 1;
    }

    /// Add a submitted prompt to history (most recent first, no consecutive dups).
    pub fn addToHistory(self: *Editor, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\n");
        if (trimmed.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[0], trimmed)) return;
        const owned = self.alloc.dupe(u8, trimmed) catch return;
        self.history.insert(0, owned) catch {
            self.alloc.free(owned);
            return;
        };
        if (self.history.items.len > 100) {
            if (self.history.pop()) |last| self.alloc.free(last);
        }
    }

    fn navigateHistory(self: *Editor, direction: isize) !void {
        if (self.history.items.len == 0) return;
        const new_index = self.history_index - direction;
        if (new_index < -1) return;
        const hist_len: isize = @intCast(self.history.items.len);
        if (new_index >= hist_len) return;
        if (self.history_index == -1 and new_index >= 0) {
            self.saveDraft() catch return error.OutOfMemory;
        }
        self.history_index = new_index;
        if (self.history_index == -1) {
            self.restoreDraft() catch return error.OutOfMemory;
        } else {
            const text = self.history.items[@intCast(self.history_index)];
            self.setText(text) catch return error.OutOfMemory;
            // pi: up (-1) → cursor at start, down (1) → cursor at end.
            self.cursor_col = if (direction == -1) 0 else self.lines.items[self.cursor_line].len;
        }
    }

    fn saveDraft(self: *Editor) !void {
        self.freeLines(&self.draft_lines);
        self.draft_lines.clearRetainingCapacity();
        for (self.lines.items) |l| {
            const copy = self.alloc.dupe(u8, l) catch return error.OutOfMemory;
            self.draft_lines.append(copy) catch return error.OutOfMemory;
        }
        self.draft_cursor_line = self.cursor_line;
        self.draft_cursor_col = self.cursor_col;
        self.draft_valid = true;
    }

    fn restoreDraft(self: *Editor) !void {
        self.freeLines(&self.lines);
        self.lines.clearRetainingCapacity();
        if (self.draft_valid) {
            for (self.draft_lines.items) |l| {
                const copy = self.alloc.dupe(u8, l) catch return error.OutOfMemory;
                self.lines.append(copy) catch return error.OutOfMemory;
            }
            self.cursor_line = self.draft_cursor_line;
            self.cursor_col = self.draft_cursor_col;
        } else {
            const empty = self.alloc.dupe(u8, "") catch return error.OutOfMemory;
            self.lines.append(empty) catch return error.OutOfMemory;
            self.cursor_line = 0;
            self.cursor_col = 0;
        }
    }

    pub fn setText(self: *Editor, text: []const u8) !void {
        self.freeLines(&self.lines);
        self.lines.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const owned = self.alloc.dupe(u8, line) catch return error.OutOfMemory;
            self.lines.append(owned) catch return error.OutOfMemory;
        }
        self.cursor_line = 0;
        self.cursor_col = if (self.lines.items.len > 0) self.lines.items[0].len else 0;
    }

    pub fn insertChar(self: *Editor, c: u8) !void {
        // Defensive: never let control characters (ESC, CSI fragments from torn
        // mouse sequences, etc.) into the buffer.
        if (c < 0x20 and c != '\n') return;
        if (c == 0x7f) return;
        const line = self.lines.items[self.cursor_line];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        errdefer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return error.OutOfMemory;
        nl.append(self.alloc, c) catch return error.OutOfMemory;
        nl.appendSlice(self.alloc, line[self.cursor_col..]) catch return error.OutOfMemory;
        const owned = nl.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
        self.cursor_col += 1;
    }

    /// Insert a multi-byte UTF-8 sequence (CJK, emoji) at the cursor.
    pub fn insertBytes(self: *Editor, bytes: []const u8) !void {
        for (bytes) |b| {
            if (b < 0x20 and b != '\n') return;
            if (b == 0x7f) return;
        }
        const line = self.lines.items[self.cursor_line];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        errdefer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return error.OutOfMemory;
        nl.appendSlice(self.alloc, bytes) catch return error.OutOfMemory;
        nl.appendSlice(self.alloc, line[self.cursor_col..]) catch return error.OutOfMemory;
        const owned = nl.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
        self.cursor_col += bytes.len;
    }

    fn backspace(self: *Editor) void {
        if (self.cursor_col > 0) {
            const line = self.lines.items[self.cursor_line];
            // Delete a whole character (CJK = 3 bytes), not just one byte.
            const start = wmod.prevCharStart(line, self.cursor_col);
            var nl: std.ArrayListUnmanaged(u8) = .empty;
            defer nl.deinit(self.alloc);
            nl.appendSlice(self.alloc, line[0..start]) catch return;
            nl.appendSlice(self.alloc, line[self.cursor_col..]) catch return;
            const owned = nl.toOwnedSlice(self.alloc) catch return;
            self.alloc.free(line);
            self.lines.items[self.cursor_line] = owned;
            self.cursor_col = start;
        } else if (self.cursor_line > 0) {
            const prev = self.lines.items[self.cursor_line - 1];
            const cur = self.lines.items[self.cursor_line];
            var nl: std.ArrayListUnmanaged(u8) = .empty;
            defer nl.deinit(self.alloc);
            nl.appendSlice(self.alloc, prev) catch return;
            nl.appendSlice(self.alloc, cur) catch return;
            const owned = nl.toOwnedSlice(self.alloc) catch return;
            self.alloc.free(prev);
            self.alloc.free(cur);
            self.lines.items[self.cursor_line - 1] = owned;
            if (self.cursor_line == self.lines.items.len - 1) {
                _ = self.lines.pop();
            } else {
                self.lines.items[self.cursor_line] = self.lines.items[self.lines.items.len - 1];
                _ = self.lines.pop();
            }
            self.cursor_line -= 1;
            self.cursor_col = prev.len;
        }
    }

    fn deleteForward(self: *Editor) void {
        const line = self.lines.items[self.cursor_line];
        if (self.cursor_col < line.len) {
            // Delete a whole character (CJK = 3 bytes), not just one byte.
            const end = wmod.nextCharEnd(line, self.cursor_col);
            var nl: std.ArrayListUnmanaged(u8) = .empty;
            defer nl.deinit(self.alloc);
            nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return;
            nl.appendSlice(self.alloc, line[end..]) catch return;
            const owned = nl.toOwnedSlice(self.alloc) catch return;
            self.alloc.free(line);
            self.lines.items[self.cursor_line] = owned;
        } else if (self.cursor_line < self.lines.items.len - 1) {
            const cur = self.lines.items[self.cursor_line];
            const next = self.lines.items[self.cursor_line + 1];
            var nl: std.ArrayListUnmanaged(u8) = .empty;
            defer nl.deinit(self.alloc);
            nl.appendSlice(self.alloc, cur) catch return;
            nl.appendSlice(self.alloc, next) catch return;
            const owned = nl.toOwnedSlice(self.alloc) catch return;
            self.alloc.free(cur);
            self.alloc.free(next);
            self.lines.items[self.cursor_line] = owned;
            if (self.cursor_line + 1 == self.lines.items.len - 1) {
                _ = self.lines.pop();
            } else {
                self.lines.items[self.cursor_line + 1] = self.lines.items[self.lines.items.len - 1];
                _ = self.lines.pop();
            }
        }
    }

    pub fn newLine(self: *Editor) !void {
        const line = self.lines.items[self.cursor_line];
        const after = line[self.cursor_col..];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        errdefer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return error.OutOfMemory;
        const before = nl.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = before;
        const after_copy = self.alloc.dupe(u8, after) catch return error.OutOfMemory;
        self.lines.insert(self.cursor_line + 1, after_copy) catch return error.OutOfMemory;
        self.cursor_line += 1;
        self.cursor_col = 0;
    }

    fn moveCursor(self: *Editor, dline: isize, dcol: isize) void {
        var line = @as(isize, @intCast(self.cursor_line)) + dline;
        if (line < 0) line = 0;
        const max_line: isize = @intCast(self.lines.items.len - 1);
        if (line > max_line) line = max_line;
        self.cursor_line = @intCast(line);
        const cur_line = self.lines.items[self.cursor_line];
        // A single-column step moves a whole character (CJK = 3 bytes), so the
        // cursor never lands in the middle of a multi-byte sequence.
        var col: isize = 0;
        if (dcol == 1) {
            col = @as(isize, @intCast(wmod.nextCharEnd(cur_line, self.cursor_col)));
        } else if (dcol == -1) {
            col = @as(isize, @intCast(wmod.prevCharStart(cur_line, self.cursor_col)));
        } else {
            col = @as(isize, @intCast(self.cursor_col)) + dcol;
        }
        if (col < 0) col = 0;
        const max_col: isize = @intCast(cur_line.len);
        if (col > max_col) col = max_col;
        self.cursor_col = @intCast(col);
    }

    fn moveLineStart(self: *Editor) void {
        self.cursor_col = 0;
    }

    fn moveLineEnd(self: *Editor) void {
        self.cursor_col = self.lines.items[self.cursor_line].len;
    }

    fn deleteWordBackward(self: *Editor) void {
        if (self.cursor_col == 0) {
            self.backspace();
            return;
        }
        const line = self.lines.items[self.cursor_line];
        var col = self.cursor_col;
        while (col > 0 and line[col - 1] == ' ') col -= 1;
        // Multi-byte (non-ASCII) bytes count as word chars so a whole CJK char
        // is deleted in one Ctrl+W.
        while (col > 0 and (isWordChar(line[col - 1]) or line[col - 1] >= 0x80)) col -= 1;
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        defer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..col]) catch return;
        nl.appendSlice(self.alloc, line[self.cursor_col..]) catch return;
        const owned = nl.toOwnedSlice(self.alloc) catch return;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
        self.cursor_col = col;
    }

    fn deleteToLineStart(self: *Editor) void {
        const line = self.lines.items[self.cursor_line];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        defer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[self.cursor_col..]) catch return;
        const owned = nl.toOwnedSlice(self.alloc) catch return;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
        self.cursor_col = 0;
    }

    fn deleteToLineEnd(self: *Editor) void {
        const line = self.lines.items[self.cursor_line];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        defer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return;
        const owned = nl.toOwnedSlice(self.alloc) catch return;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
    }

    /// Tab: complete the `@path` on the current line (common prefix of matches).
    fn completeAt(self: *Editor, io: std.Io) !void {
        const line = self.lines.items[self.cursor_line];
        const before = line[0..self.cursor_col];
        // Find the last '@' on this line before the cursor.
        var at_pos: ?usize = null;
        for (before, 0..) |ch, i| {
            if (ch == '@') at_pos = i;
        }
        if (at_pos) |ap| {
            const partial = before[ap + 1 ..];
            const match = commonFilePrefix(self.alloc, io, partial) catch return;
            defer self.alloc.free(match);
            if (std.mem.eql(u8, match, partial)) return; // no change
            const new_line = std.fmt.allocPrint(self.alloc, "{s}@{s}{s}", .{ before[0..ap], match, line[self.cursor_col..] }) catch return;
            self.alloc.free(line);
            self.lines.items[self.cursor_line] = new_line;
            self.cursor_col = ap + 1 + match.len;
        }
    }

    /// The longest common prefix among files in the cwd matching `partial`.
    /// Returns `partial` itself if no match. Owned.
    fn commonFilePrefix(alloc: std.mem.Allocator, io: std.Io, partial: []const u8) ![]u8 {
        var matches: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (matches.items) |m| alloc.free(m);
            matches.deinit(alloc);
        }
        const dir = std.Io.Dir.cwd();
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const name = entry.name;
            if (std.mem.startsWith(u8, name, partial)) {
                const owned = alloc.dupe(u8, name) catch return error.OutOfMemory;
                matches.append(alloc, owned) catch return error.OutOfMemory;
            }
        }
        if (matches.items.len == 0) return alloc.dupe(u8, partial);
        if (matches.items.len == 1) return alloc.dupe(u8, matches.items[0]);
        // Common prefix of all matches.
        var prefix_len = if (matches.items[0].len < matches.items[1].len) matches.items[0].len else matches.items[1].len;
        for (matches.items[2..]) |m| {
            prefix_len = if (prefix_len < m.len) prefix_len else m.len;
        }
        var i: usize = 0;
        while (i < prefix_len) : (i += 1) {
            const c = matches.items[0][i];
            for (matches.items[1..]) |m| {
                if (m[i] != c) return alloc.dupe(u8, partial[0..0]);
            }
        }
        return alloc.dupe(u8, matches.items[0][0..i]);
    }
};

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Truncate a line to at most `width` columns (ANSI-unaware; editor lines are plain).
fn truncateLine(alloc: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
    if (line.len <= width) return alloc.dupe(u8, line);
    return alloc.dupe(u8, line[0..width]);
}

/// Wrap a logical line into visual lines of at most `width` visual columns
/// (wide-char aware). Breaks at the last space before the limit when possible,
/// else hard-breaks. Returns an owned slice of owned visual lines; the lines are
/// contiguous byte slices of `line` (they tile it exactly).
fn wrapLine(alloc: std.mem.Allocator, line: []const u8, width: u32) ![]const []u8 {
    var result: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer result.deinit(alloc);
    var start: usize = 0;
    while (start < line.len) {
        // Fill this visual line until adding the next char would exceed width.
        var end = start;
        var w: u32 = 0;
        var last_space: ?usize = null;
        while (end < line.len) {
            const ce = wmod.nextCharEnd(line, end);
            const cw = wmod.visualWidth(line[end..ce]);
            if (w + cw > width) break;
            if (line[end] == ' ') last_space = end;
            w += cw;
            end = ce;
        }
        // Choose the break point: after the last space if there is one, else hard-break.
        var brk: usize = 0;
        if (end < line.len and last_space != null and last_space.? > start) {
            brk = last_space.? + 1; // include the trailing space
        } else {
            brk = end;
        }
        if (brk <= start) brk = wmod.nextCharEnd(line, start); // a single char wider than width
        const vl = alloc.dupe(u8, line[start..brk]) catch return error.OutOfMemory;
        result.append(alloc, vl) catch return error.OutOfMemory;
        start = brk;
    }
    if (result.items.len == 0) {
        const vl = alloc.dupe(u8, "") catch return error.OutOfMemory;
        result.append(alloc, vl) catch return error.OutOfMemory;
    }
    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

test "editor insert and getText" {
    const alloc = std.heap.page_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.insertChar('h') catch unreachable;
    e.insertChar('i') catch unreachable;
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hi", text);
}

test "editor newline and multi-line" {
    const alloc = std.heap.page_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.insertChar('a') catch unreachable;
    e.newLine() catch unreachable;
    e.insertChar('b') catch unreachable;
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a\nb", text);
    try std.testing.expectEqual(@as(usize, 1), e.cursor_line);
}

test "editor backspace merges lines" {
    const alloc = std.heap.page_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.insertChar('a') catch unreachable;
    e.newLine() catch unreachable;
    e.insertChar('b') catch unreachable; // "a\nb", cursor(1,1)
    e.backspace(); // delete 'b' → "a\n", cursor(1,0)
    e.backspace(); // merge → "a", cursor(0,1)
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a", text);
}

test "editor history navigation" {
    const alloc = std.heap.page_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.addToHistory("first");
    e.addToHistory("second");
    // Up → most recent ("second").
    e.navigateHistory(-1) catch unreachable;
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("second", text);
    // Up again → "first".
    e.navigateHistory(-1) catch unreachable;
    const text2 = e.getText() catch unreachable;
    defer alloc.free(text2);
    try std.testing.expectEqualStrings("first", text2);
    // Down → back to "second".
    e.navigateHistory(1) catch unreachable;
    const text3 = e.getText() catch unreachable;
    defer alloc.free(text3);
    try std.testing.expectEqualStrings("second", text3);
}

test "editor deleteToLineEnd" {
    const alloc = std.heap.page_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.insertChar('a') catch unreachable;
    e.insertChar('b') catch unreachable;
    e.insertChar('c') catch unreachable;
    e.moveLineStart();
    e.moveCursor(0, 1); // cursor after 'a'
    e.deleteToLineEnd();
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a", text);
}
