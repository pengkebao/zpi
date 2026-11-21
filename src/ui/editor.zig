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
const overlay = @import("overlay.zig");
const keys = @import("keys.zig");
const wmod = @import("width.zig");

pub const EditorAction = enum { none, submit };

// Whether the CURRENT thread already holds the editor mutex. The editor is
// mutated by the main loop (key dispatch, no render_mutex) while the spinner
// thread renders it (render/cursorVisualPos → wrappedView, under render_mutex).
// wrappedView's non-atomic read-check-free-rebuild raced a concurrent mutation
// and double-freed (crash during compaction, when the main loop is unblocked
// polling compact_done). This flag makes the guard reentrant so a public
// method may call another (handleKey → insertChar) without deadlocking.
threadlocal var editor_guard_held: bool = false;

/// A LOGICAL point in the editor: line = logical line index, col = byte
/// offset within that line. Selections are stored in logical coordinates so
/// they stay correct regardless of the wrap width used for rendering; the
/// visual↔logical mapping happens only at input (visualToLogical) and
/// render (highlightSelection) time, with the actual render width.
pub const EditorSelPt = struct { line: usize, col: usize };

/// Ordered selection bounds in logical coordinates.
pub const EditorSelBounds = struct { start: EditorSelPt, end: EditorSelPt };

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

    // Mouse text selection (logical coordinates). Anchor/focus set by TUI
    // drag gestures; empty (null anchor) = no selection.
    sel_anchor: ?EditorSelPt = null,
    sel_focus: ?EditorSelPt = null,

    // Wrapped-visual-line cache (pi: editor cache). Keyed by (buffer
    // generation, render width): highlightSelection, cursorVisualPos and
    // visualToLogical all wrap the same buffer at the same width, so wrap
    // once per generation instead of per mouse-move frame.
    wrap_cache: ?[]const []u8 = null,
    wrap_cache_rows: ?[]const u32 = null, // visual rows per logical line
    wrap_cache_width: usize = 0,
    wrap_cache_gen: u64 = 0,
    wrap_gen: u64 = 0,
    /// Serializes every access to the buffer + wrap cache + selection (see
    /// the file-top comment for the race this closes). A spinlock (atomic
    /// CAS) rather than std.Io.Mutex: a mutex needs the CALLING thread's io
    /// for its futex, but the editor is touched from several threads (main
    /// loop + spinner) that each own a different io — a spinlock has no io
    /// dependency, and the critical sections are short (wrap rebuild / line
    /// splice). Lock order: render_mutex → this lock.
    lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Clear any active mouse selection.
    pub fn clearSelection(self: *Editor) void {
        const lk = self.guard();
        defer lk.unlock();
        self.sel_anchor = null;
        self.sel_focus = null;
    }

    /// Drop the wrap cache (call after any buffer mutation and on width
    /// change; render() bumps the generation itself).
    fn invalidateWrapCache(self: *Editor) void {
        self.wrap_gen += 1;
        if (self.wrap_cache) |c| {
            for (c) |vl| self.alloc.free(vl);
            self.alloc.free(c);
            self.wrap_cache = null;
        }
        if (self.wrap_cache_rows) |r| {
            self.alloc.free(r);
            self.wrap_cache_rows = null;
        }
    }

    /// The buffer wrapped at `width`, from the cache when possible.
    fn wrappedView(self: *Editor, width: usize) ![]const []u8 {
        if (self.wrap_cache) |c| {
            if (self.wrap_cache_width == width and self.wrap_cache_gen == self.wrap_gen) return c;
            for (c) |vl| self.alloc.free(vl);
            self.alloc.free(c);
            self.wrap_cache = null;
        }
        if (self.wrap_cache_rows) |r| {
            self.alloc.free(r);
            self.wrap_cache_rows = null;
        }
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |l| self.alloc.free(l);
            out.deinit(self.alloc);
        }
        var counts: std.ArrayListUnmanaged(u32) = .empty;
        errdefer counts.deinit(self.alloc);
        const w: u32 = @intCast(width);
        for (self.lines.items) |line| {
            const wrapped = try wrapLine(self.alloc, line, w);
            counts.append(self.alloc, @intCast(wrapped.len)) catch {
                for (wrapped) |vl| self.alloc.free(vl);
                return error.OutOfMemory;
            };
            for (wrapped) |vl| out.append(self.alloc, vl) catch {
                self.alloc.free(vl);
                return error.OutOfMemory;
            };
            self.alloc.free(wrapped);
        }
        const owned_rows = try counts.toOwnedSlice(self.alloc);
        const owned = try out.toOwnedSlice(self.alloc);
        self.wrap_cache = owned;
        self.wrap_cache_rows = owned_rows;
        self.wrap_cache_width = width;
        self.wrap_cache_gen = self.wrap_gen;
        return owned;
    }

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

    /// RAII guard for the editor lock.
    const Guard = struct {
        e: *Editor,
        acquired: bool,
        fn unlock(g: Guard) void {
            if (g.acquired) {
                editor_guard_held = false;
                g.e.lock.store(0, .release);
            }
        }
    };

    /// Take the editor lock for the duration of a public method. Reentrant
    /// (a public method may call another, e.g. handleKey → insertChar) via
    /// the threadlocal flag. Returns a guard; call `.unlock()` in a `defer`.
    fn guard(self: *Editor) Guard {
        if (editor_guard_held) return .{ .e = self, .acquired = false };
        // Spin: the critical sections are short (a wrap rebuild or a line
        // splice), so a brief spin is cheaper than a futex and needs no io.
        while (self.lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        editor_guard_held = true;
        return .{ .e = self, .acquired = true };
    }

    pub fn deinit(self: *Editor) void {
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
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
    pub fn getText(self: *Editor) ![]u8 {
        const lk = self.guard();
        defer lk.unlock();
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

    pub fn getTextLen(self: *Editor) usize {
        const lk = self.guard();
        defer lk.unlock();
        var total: usize = 0;
        for (self.lines.items) |l| total += l.len + 1;
        if (self.lines.items.len > 0) total -= 1;
        return total;
    }

    pub fn isEmpty(self: *Editor) bool {
        const lk = self.guard();
        defer lk.unlock();
        return self.lines.items.len == 1 and self.lines.items[0].len == 0;
    }

    /// Reset the editor to a single empty line (and exit history browsing).
    pub fn clear(self: *Editor) !void {
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
        self.freeLines(&self.lines);
        self.lines.clearRetainingCapacity();
        const empty = self.alloc.dupe(u8, "") catch return error.OutOfMemory;
        self.lines.append(empty) catch return error.OutOfMemory;
        self.cursor_line = 0;
        self.cursor_col = 0;
        self.history_index = -1;
        self.clearSelection();
    }

    /// Visual cursor position within the editor (0-based line and column).
    pub fn cursorPos(self: *Editor) struct { row: usize, col: usize } {
        const lk = self.guard();
        defer lk.unlock();
        return .{ .row = self.cursor_line, .col = self.cursor_col };
    }

    /// Borrow the text on the cursor's line before the cursor column
    /// (null when the cursor column is out of range for that line).
    pub fn lineBeforeCursor(self: *Editor) ?[]const u8 {
        const lk = self.guard();
        defer lk.unlock();
        const line = self.lines.items[self.cursor_line];
        if (self.cursor_col > line.len) return null;
        return line[0..self.cursor_col];
    }

    /// Replace range [start, end) of the cursor's line with `insertion`
    /// and park the cursor after it (file-completion application).
    pub fn replaceRange(self: *Editor, start: usize, end: usize, insertion: []const u8) !void {
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
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
    pub fn cursorVisualCol(self: *Editor) u32 {
        const lk = self.guard();
        defer lk.unlock();
        const line = self.lines.items[self.cursor_line];
        const end = if (self.cursor_col < line.len) self.cursor_col else line.len;
        return wmod.visualWidth(line[0..end]);
    }

    pub fn lineCount(self: *Editor) usize {
        const lk = self.guard();
        defer lk.unlock();
        return self.lines.items.len;
    }

    /// Render the editor as wrapped visual lines (each ≤ `width` visual
    /// columns). Owned: every returned line must be freed by the caller.
    /// Populates the wrap cache (render runs before every mouse gesture,
    /// so the gesture handlers hit the warm cache).
    pub fn render(self: *Editor, width: usize) !std.ArrayListUnmanaged([]u8) {
        const lk = self.guard();
        defer lk.unlock();
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |l| self.alloc.free(l);
            out.deinit(self.alloc);
        }
        const view = try self.wrappedView(width);
        for (view) |vl| {
            const copy = try self.alloc.dupe(u8, vl);
            out.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                return error.OutOfMemory;
            };
        }
        return out;
    }

    /// The ordered selection bounds in logical coordinates, or null when
    /// empty.
    pub fn selBounds(self: *Editor) ?EditorSelBounds {
        const lk = self.guard();
        defer lk.unlock();
        const a = self.sel_anchor orelse return null;
        const f = self.sel_focus orelse return null;
        if (a.line == f.line and a.col == f.col) return null;
        const a_first = a.line < f.line or (a.line == f.line and a.col < f.col);
        return if (a_first) .{ .start = a, .end = f } else .{ .start = f, .end = a };
    }

    /// Map a visual column (within a plain text slice) to a byte offset.
    /// vcol is a position BETWEEN characters (0 = before the first, the
    /// total width = after the last); a CJK char spans two visual columns.
    /// When vcol lands exactly on a character's right edge (w+cw == vcol) we
    /// advance past it, so the cursor sits AFTER that character.
    fn visualColToByte(line: []const u8, vcol: u32) usize {
        var w: u32 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const ce = wmod.nextCharEnd(line, i);
            const cw = wmod.visualWidth(line[i..ce]);
            if (w + cw > vcol) return i;
            w += cw;
            i = ce;
        }
        return line.len;
    }

    /// Map a (visual row, visual col) point — as rendered at `width` — to a
    /// logical (line, byte col), clamped into the buffer. Used by mouse
    /// placement/selection; `width` MUST match the width the TUI rendered
    /// the editor at (the wrap boundary depends on it).
    pub fn visualToLogical(self: *Editor, vrow: usize, vcol: u32, width: usize) EditorSelPt {
        const lk = self.guard();
        defer lk.unlock();
        const wrapped = self.wrappedView(width) catch return .{ .line = 0, .col = 0 };
        if (vrow >= wrapped.len) {
            // Past the last visual line: park at the last line's end.
            const last = self.lines.items.len -| 1;
            return .{ .line = last, .col = self.lines.items[last].len };
        }
        const rows = self.wrap_cache_rows orelse return .{ .line = 0, .col = 0 };
        // The logical line owning visual row `vrow`: walk the per-line
        // visual row counts.
        var acc: usize = 0;
        var l: usize = rows.len - 1;
        var first: usize = 0;
        for (rows, 0..) |n, li| {
            if (vrow < acc + n) {
                l = li;
                first = acc;
                break;
            }
            acc += n;
        }
        // Byte offset of this visual line within the logical line
        // (wrapped lines tile the line exactly).
        const wr = vrow - first;
        var off: usize = 0;
        for (wrapped[first..first + wr]) |vl| off += vl.len;
        const seg = wrapped[first + wr];
        const seg_w = wmod.visualWidth(seg);
        const c = if (vcol <= seg_w) visualColToByte(seg, vcol) else seg.len;
        return .{ .line = l, .col = off + c };
    }

    /// Double/triple click on a visual point: select the word (or whole
    /// logical line) under the pointer. Word = [A-Za-z0-9_] run, or any
    /// multi-byte (CJK etc.) character run. `line` = true for triple click.
    pub fn selectWordOrLine(self: *Editor, vrow: usize, vcol: u32, width: usize, line: bool) void {
        const lk = self.guard();
        defer lk.unlock();
        const p = self.visualToLogical(vrow, vcol, width);
        if (p.line >= self.lines.items.len) return;
        if (line) {
            self.sel_anchor = .{ .line = p.line, .col = 0 };
            self.sel_focus = .{ .line = p.line, .col = self.lines.items[p.line].len };
            return;
        }
        const text = self.lines.items[p.line];
        if (p.col >= text.len) {
            // Clicked past the last char: select the whole line.
            self.sel_anchor = .{ .line = p.line, .col = 0 };
            self.sel_focus = .{ .line = p.line, .col = text.len };
            return;
        }
        const isWord = struct {
            fn f(bytes: []const u8) bool {
                if (bytes.len == 0) return false;
                if (bytes.len > 1) return true; // multibyte (CJK etc.) = word char
                const c = bytes[0];
                return std.ascii.isAlphanumeric(c) or c == '_';
            }
        }.f;
        var s0 = p.col;
        while (s0 > 0) {
            const prev = wmod.prevCharStart(text, s0);
            if (!isWord(text[prev..s0])) break;
            s0 = prev;
        }
        var e0 = p.col;
        while (e0 < text.len) {
            const nxt = wmod.nextCharEnd(text, e0);
            if (!isWord(text[e0..nxt])) break;
            e0 = nxt;
        }
        if (e0 <= s0) return;
        self.sel_anchor = .{ .line = p.line, .col = s0 };
        self.sel_focus = .{ .line = p.line, .col = e0 };
    }

    /// Total wrapped visual line count at `width` (cache warm-up).
    pub fn visualLineCount(self: *Editor, width: usize) usize {
        const lk = self.guard();
        defer lk.unlock();
        const view = self.wrappedView(width) catch return 1;
        return @max(view.len, 1);
    }

    /// Place the cursor at a visual point (see visualToLogical).
    pub fn placeCursor(self: *Editor, vrow: usize, vcol: u32, width: usize) void {
        const lk = self.guard();
        defer lk.unlock();
        const p = self.visualToLogical(vrow, vcol, width);
        self.cursor_line = p.line;
        self.cursor_col = p.col;
    }

    /// Plain text of the current selection (logical lines joined with \n),
    /// or null when empty. Owned.
    pub fn selectionText(self: *Editor) ?[]u8 {
        const lk = self.guard();
        defer lk.unlock();
        const b = self.selBounds() orelse return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.alloc);
        var l: usize = b.start.line;
        while (true) : (l += 1) {
            if (l > b.end.line) break;
            if (l >= self.lines.items.len) break;
            const line = self.lines.items[l];
            const start = if (l == b.start.line) b.start.col else 0;
            const end = if (l == b.end.line) @min(b.end.col, line.len) else line.len;
            if (end > start) {
                if (out.items.len > 0) out.append(self.alloc, '\n') catch return null;
                out.appendSlice(self.alloc, line[start..end]) catch return null;
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// Reverse-video the selected ranges into the rendered editor window
    /// (`frame` is the whole frame, `base` the first visible editor row,
    /// `count` the visible rows, `vis_top` the first visible VISUAL line,
    /// `width` the render width). Editor lines are plain text, so a simple
    /// per-row splice is safe.
    /// Index of the first visual row of logical line `l`, from the cached
    /// per-line visual row counts.
    fn firstVisualRow(rows: []const u32, l: usize) usize {
        var v: usize = 0;
        for (rows[0..@min(l, rows.len)]) |n| v += n;
        return v;
    }

    pub fn highlightSelection(self: *Editor, frame: *std.ArrayListUnmanaged([]u8), base: usize, count: usize, vis_top: usize, width: usize, alloc: std.mem.Allocator) void {
        const lk = self.guard();
        defer lk.unlock();
        const b = self.selBounds() orelse return;
        const wrapped = self.wrappedView(width) catch return;
        const rows = self.wrap_cache_rows orelse return;
        var l: usize = b.start.line;
        while (l <= b.end.line) : (l += 1) {
            if (l >= rows.len) break;
            const first = firstVisualRow(rows, l);
            const last = if (l + 1 < rows.len) firstVisualRow(rows, l + 1) else wrapped.len;
            for (wrapped[first..last], 0..) |seg, wr| {
                const av = first + wr; // absolute visual row
                if (av < vis_top or av >= vis_top + count) continue;
                const fr = av - vis_top;
                var off: usize = 0;
                for (wrapped[first..first + wr]) |vl| off += vl.len;
                const s = if (l == b.start.line) @max(b.start.col, off) else off;
                const is_end = (l == b.end.line);
                const e = if (is_end) @min(b.end.col, off + seg.len) else off + seg.len;
                if (e <= s) continue;
                const col = wmod.visualWidth(seg[0..(s - off)]);
                // pi parity: middle rows highlight to full editor width
                // (endCol = line.length after padding); end row highlights
                // to the selection end column (endCol = end.col).
                const end_col: usize = if (is_end)
                    col + wmod.visualWidth(seg[(s - off)..(e - off)])
                else
                    width;
                var row = frame.items[base + fr];
                var padded: ?[]u8 = null;
                const rw = wmod.visualWidth(row);
                if (rw < end_col) {
                    const p = alloc.alloc(u8, row.len + (end_col - rw)) catch continue;
                    @memcpy(p[0..row.len], row);
                    @memset(p[row.len..], ' ');
                    padded = p;
                    row = p;
                }
                const hl = overlay.applySelectionHighlight(alloc, row, col, end_col) catch {
                    if (padded) |p| alloc.free(p);
                    continue;
                };
                alloc.free(frame.items[base + fr]);
                if (padded) |p| alloc.free(p);
                frame.items[base + fr] = hl;
            }
        }
    }

    /// The cursor's position in VISUAL (wrapped) coordinates: (row, col).
    /// row = the visual line the cursor is on; col = visual column within it.
    pub fn cursorVisualPos(self: *Editor, width: usize) struct { row: u32, col: u32 } {
        const lk = self.guard();
        defer lk.unlock();
        const wrapped = self.wrappedView(width) catch return .{ .row = 0, .col = 0 };
        const rows = self.wrap_cache_rows orelse return .{ .row = 0, .col = 0 };
        if (self.cursor_line >= rows.len) return .{ .row = 0, .col = 0 };
        const first = firstVisualRow(rows, self.cursor_line);
        const last = if (self.cursor_line + 1 < rows.len) firstVisualRow(rows, self.cursor_line + 1) else wrapped.len;
        var byte_offset: usize = 0;
        var vline: usize = first;
        while (vline < last) : (vline += 1) {
            const vl = wrapped[vline];
            if (self.cursor_col <= byte_offset + vl.len) {
                const col_in_vl = self.cursor_col - byte_offset;
                const col = wmod.visualWidth(vl[0..col_in_vl]);
                return .{ .row = @intCast(vline), .col = col };
            }
            byte_offset += vl.len;
        }
        // Cursor at the very end: last visual line, its full width.
        const vl = wrapped[last - 1];
        return .{ .row = @intCast(last - 1), .col = wmod.visualWidth(vl) };
    }

    /// Handle a key. Returns `.submit` if the user pressed Enter to submit.
    pub fn handleKey(self: *Editor, key: keys.Key, io: std.Io) !EditorAction {
        const lk = self.guard();
        defer lk.unlock();
        _ = io; // file completion lives in the TUI's file menu now
        // NB: no blanket clearSelection() here — only TEXT-CHANGING actions
        // drop the selection (standard editor behavior: typing/backspace
        // replaces it; plain cursor moves keep it). `insertBytes` replaces
        // the selection when one exists.
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
            .escape => self.clearSelection(),
            // Tab is handled by the TUI layer (file menu trigger/application).
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
        const lk = self.guard();
        defer lk.unlock();
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
        self.invalidateWrapCache();
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

    pub fn clearSelectionAndSetText(self: *Editor, text: []const u8) !void {
        const lk = self.guard();
        defer lk.unlock();
        self.clearSelection();
        return self.setText(text);
    }

    pub fn setText(self: *Editor, text: []const u8) !void {
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
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
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
        // Defensive: never let control characters (ESC, CSI fragments from torn
        // mouse sequences, etc.) into the buffer.
        if (c < 0x20 and c != '\n') return;
        if (c == 0x7f) return;
        // Typing over a selection replaces it (standard editor behavior).
        if (self.selBounds() != null) {
            const bytes = [1]u8{c};
            self.replaceSelection(&bytes) catch return;
            self.clearSelection();
            return;
        }
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
        const lk = self.guard();
        defer lk.unlock();
        for (bytes) |b| {
            if (b < 0x20 and b != '\n') return;
            if (b == 0x7f) return;
        }
        // A mouse selection is replaced by the inserted text (standard
        // editor behavior); otherwise insert at the cursor.
        if (self.selBounds() != null) {
            self.replaceSelection(bytes) catch return;
            self.clearSelection();
            return;
        }
        self.invalidateWrapCache();
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

    /// Paste (possibly multi-line) clipboard text: a selection is replaced,
    /// single-line text inserts at the cursor, multi-line text is split on
    /// \n and spliced into the buffer. Trailing \r (CRLF paste) is dropped.
    pub fn pasteText(self: *Editor, text: []const u8) !void {
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
        const body = if (std.mem.endsWith(u8, text, "\n") and text.len > 0) text[0 .. text.len - 1] else text;
        var count: usize = 1;
        for (body) |ch| {
            if (ch == '\n') count += 1;
        }
        if (count == 1) {
            if (self.selBounds() != null) {
                self.replaceSelection(body) catch return;
            } else {
                try self.insertBytes(body);
            }
            return;
        }
        const b = self.selBounds();
        var anchor_line: usize = 0;
        var anchor_col: usize = 0;
        if (b) |sb| {
            anchor_line = sb.start.line;
            anchor_col = @min(sb.start.col, self.lines.items[sb.start.line].len);
        } else {
            anchor_line = self.cursor_line;
            anchor_col = self.cursor_col;
        }
        // Split into owned parts; \r is stripped (CRLF paste).
        var parts: std.ArrayListUnmanaged([]u8) = .empty;
        defer parts.deinit(self.alloc);
        errdefer for (parts.items) |p| self.alloc.free(p);
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |seg0| {
            const seg = if (seg0.len > 0 and seg0[seg0.len - 1] == '\r') seg0[0 .. seg0.len - 1] else seg0;
            const owned = try self.alloc.dupe(u8, seg);
            parts.append(self.alloc, owned) catch {
                self.alloc.free(owned);
                return error.OutOfMemory;
            };
        }
        const first = self.lines.items[anchor_line];
        if (b != null and anchor_line != b.?.end.line) {
            // Multi-line paste over a multi-line selection: the first line
            // keeps [0, start) and gains parts[0]; the last part merges
            // with the tail of the selection's last line; everything
            // between dies.
            const end_line = b.?.end.line;
            const last_line = self.lines.items[end_line];
            const end_b = @min(b.?.end.col, last_line.len);
            var head: std.ArrayListUnmanaged(u8) = .empty;
            defer head.deinit(self.alloc);
            head.appendSlice(self.alloc, first[0..anchor_col]) catch return error.OutOfMemory;
            head.appendSlice(self.alloc, parts.items[0]) catch return error.OutOfMemory;
            const head_owned = head.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            defer joined.deinit(self.alloc);
            joined.appendSlice(self.alloc, parts.items[parts.items.len - 1]) catch return error.OutOfMemory;
            joined.appendSlice(self.alloc, last_line[end_b..]) catch return error.OutOfMemory;
            const joined_owned = joined.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
            self.alloc.free(first);
            self.lines.items[anchor_line] = head_owned;
            var i: usize = anchor_line + 1;
            while (i <= end_line) : (i += 1) self.alloc.free(self.lines.items[i]);
            var j: usize = anchor_line + 1;
            var k: usize = end_line + 1;
            while (k < self.lines.items.len) : (k += 1) {
                self.lines.items[j] = self.lines.items[k];
                j += 1;
            }
            self.lines.shrinkRetainingCapacity(self.lines.items.len - (end_line - anchor_line));
            // Insert the middle parts, then the joined last line.
            for (parts.items[1 .. parts.items.len - 1], 0..) |p, pi| {
                self.lines.insert(anchor_line + 1 + pi, p) catch return error.OutOfMemory;
            }
            self.lines.insert(anchor_line + parts.items.len - 1, joined_owned) catch return error.OutOfMemory;
            self.cursor_line = anchor_line + parts.items.len - 1;
            self.cursor_col = parts.items[parts.items.len - 1].len;
            self.clearSelection();
            return;
        }
        // No selection (or same-line selection): split the anchor line at
        // the insert point and splice the parts in between.
        const tail = self.alloc.dupe(u8, first[anchor_col..]) catch return error.OutOfMemory;
        const head = self.alloc.dupe(u8, first[0..anchor_col]) catch {
            self.alloc.free(tail);
            return error.OutOfMemory;
        };
        self.alloc.free(first);
        self.lines.items[anchor_line] = head;
        for (parts.items, 0..) |p, pi| {
            if (pi == 0) {
                var joined: std.ArrayListUnmanaged(u8) = .empty;
                joined.appendSlice(self.alloc, head) catch return error.OutOfMemory;
                joined.appendSlice(self.alloc, p) catch return error.OutOfMemory;
                const joined_owned = joined.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
                self.alloc.free(head);
                self.alloc.free(p);
                self.lines.items[anchor_line] = joined_owned;
            } else {
                self.lines.insert(anchor_line + pi, p) catch return error.OutOfMemory;
            }
        }
        const last_idx = anchor_line + parts.items.len - 1;
        if (tail.len > 0) {
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            joined.appendSlice(self.alloc, self.lines.items[last_idx]) catch return error.OutOfMemory;
            joined.appendSlice(self.alloc, tail) catch return error.OutOfMemory;
            const joined_owned = joined.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
            self.alloc.free(self.lines.items[last_idx]);
            self.alloc.free(tail);
            self.lines.items[last_idx] = joined_owned;
        }
        self.cursor_line = last_idx;
        self.cursor_col = self.lines.items[last_idx].len - tail.len;
        if (b != null) self.clearSelection();
    }

    /// Replace the current selection's byte range with `text`, parking the
    /// cursor after the insertion.
    fn replaceSelection(self: *Editor, text: []const u8) !void {
        self.invalidateWrapCache();
        const b = self.selBounds() orelse return error.NoSelection;
        const first = self.lines.items[b.start.line];
        const start_b = @min(b.start.col, first.len);
        // Tail: everything after the selection's end point.
        var tail: std.ArrayListUnmanaged(u8) = .empty;
        errdefer tail.deinit(self.alloc);
        const last_line = self.lines.items[b.end.line];
        const end_b = @min(b.end.col, last_line.len);
        tail.appendSlice(self.alloc, last_line[end_b..]) catch return error.OutOfMemory;
        // Splice the first line: [0,start_b) + text + tail.
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        errdefer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, first[0..start_b]) catch return error.OutOfMemory;
        nl.appendSlice(self.alloc, text) catch return error.OutOfMemory;
        nl.appendSlice(self.alloc, tail.items) catch return error.OutOfMemory;
        const owned = nl.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
        self.alloc.free(first);
        self.lines.items[b.start.line] = owned;
        // Drop the fully-consumed lines between (and the emptied last
        // line) — the exact survivors list, no shrinkRetainingCapacity
        // (which would truncate the buffer: the list was not empty, and
        // the emptied line index may not be the last element).
        const removed = b.end.line - b.start.line;
        if (removed > 0) {
            // Free exactly the consumed lines (start.line, end.line]; the
            // emptied tail was already merged into the first line, so
            // every one of these slots dies.
            var i: usize = b.start.line + 1;
            while (i <= b.end.line) : (i += 1) {
                self.alloc.free(self.lines.items[i]);
            }
            // Left-shift the untouched tail by `removed` slots.
            var j: usize = b.start.line + 1;
            var k: usize = b.end.line + 1;
            while (k < self.lines.items.len) : (k += 1) {
                self.lines.items[j] = self.lines.items[k];
                j += 1;
            }
            self.lines.shrinkRetainingCapacity(self.lines.items.len - removed);
        }
        self.cursor_line = b.start.line;
        self.cursor_col = start_b + text.len;
        // Selection points lived INSIDE the replaced range: clear.
        self.clearSelection();
    }

    fn backspace(self: *Editor) void {
        self.invalidateWrapCache();
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
        self.invalidateWrapCache();
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
        const lk = self.guard();
        defer lk.unlock();
        self.invalidateWrapCache();
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
        self.invalidateWrapCache();
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
        self.invalidateWrapCache();
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
        self.invalidateWrapCache();
        const line = self.lines.items[self.cursor_line];
        var nl: std.ArrayListUnmanaged(u8) = .empty;
        defer nl.deinit(self.alloc);
        nl.appendSlice(self.alloc, line[0..self.cursor_col]) catch return;
        const owned = nl.toOwnedSlice(self.alloc) catch return;
        self.alloc.free(line);
        self.lines.items[self.cursor_line] = owned;
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

// The compaction crash: the spinner thread rendered the editor (render /
// cursorVisualPos → wrappedView, which frees and rebuilds the wrap cache)
// while the main loop mutated the buffer from key dispatch. Without the
// internal mutex the two raced on wrap_cache and double-freed
// (malloc: POINTER BEING FREED WAS NOT ALLOCATED). This test reproduces the
// exact thread topology and must stay crash-free under the allocator.
fn renderHammer(e: *Editor, stop: *std.atomic.Value(bool)) void {
    var w: usize = 20;
    while (!stop.load(.acquire)) {
        var v = e.render(w) catch continue;
        _ = e.cursorVisualPos(w);
        for (v.items) |l| e.alloc.free(l);
        v.deinit(e.alloc);
        w += 1; // force a cache rebuild on nearly every frame
        if (w > 60) w = 20;
    }
}

test "editor: concurrent render and mutation do not corrupt the wrap cache" {
    // smp_allocator is thread-safe (SafeAllocator is not: two threads
    // allocating/freing concurrently would corrupt its bookkeeping).
    const alloc = std.heap.smp_allocator;
    var e = Editor.init(alloc);
    defer e.deinit();
    e.setText("the quick brown fox jumps over the lazy dog") catch unreachable;
    var stop = std.atomic.Value(bool).init(false);
    const t = std.Thread.spawn(.{}, renderHammer, .{ &e, &stop }) catch return;
    // The main thread types, backspaces and clears — the exact key-dispatch
    // mutations that raced the spinner's wrappedView during compaction. Only
    // PUBLIC methods are used (they take the lock); handleKey is the entry
    // point the TUI's key dispatch uses.
    const io = std.Io.Threaded.global_single_threaded.io();
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        _ = e.handleKey(.{ .char = .{ .ctrl = false, .alt = false, .c = 'x' } }, io) catch break;
        if (i % 7 == 0) _ = e.handleKey(.backspace, io) catch break;
        if (i % 50 == 0) {
            e.clear() catch break;
            e.setText("line one\nline two is a bit longer") catch break;
        }
    }
    stop.store(true, .release);
    t.join();
    // The buffer must still be intact (no torn reads / double frees).
    const text = e.getText() catch unreachable;
    defer alloc.free(text);
    try std.testing.expect(text.len > 0);
}
