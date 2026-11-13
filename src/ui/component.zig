//! Component system for the TUI (Phase G1).
//!
//! Mirrors pi-tui's component contract: each component renders itself to an
//! array of text lines (each an owned `[]u8`, may contain ANSI) given a width.
//! Zig has no dynamic dispatch, so `Component` is a vtable wrapper.
//!
//! v1 components: Text, VStack, Spacer, Box. (Loader, Editor, SelectList,
//! ScrollView, Markdown arrive in later G batches.)

const std = @import("std");
const keys = @import("keys.zig");

/// Render context handed to every component.
pub const Ctx = struct {
    alloc: std.mem.Allocator,
    width: usize,
};

/// Rendered output: an array of lines, each an owned `[]u8` (may contain ANSI).
/// The owner frees via `free`.
pub const Rendered = struct {
    lines: []const []u8,
    alloc: std.mem.Allocator,

    pub fn empty(alloc: std.mem.Allocator) Rendered {
        const lines = alloc.alloc([]u8, 0) catch return .{ .lines = &.{}, .alloc = alloc };
        return .{ .lines = lines, .alloc = alloc };
    }

    pub fn free(self: *const Rendered) void {
        for (self.lines) |line| self.alloc.free(line);
        self.alloc.free(@constCast(self.lines));
    }

    /// Total visible height in rows.
    pub fn height(self: *const Rendered) usize {
        return self.lines.len;
    }
};

/// Component interface (vtable-based).
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Render to lines. The returned Rendered's lines are owned by ctx.alloc.
        render: *const fn (self: *anyopaque, ctx: Ctx) Rendered,
        /// Handle a key; return true if consumed.
        handle_key: ?*const fn (self: *anyopaque, key: keys.Key, alloc: std.mem.Allocator) bool,
        /// Release component-owned resources.
        deinit: ?*const fn (self: *anyopaque, alloc: std.mem.Allocator) void,
    };

    pub fn render(self: *const Component, ctx: Ctx) Rendered {
        return self.vtable.render(self.ptr, ctx);
    }

    pub fn handleKey(self: *Component, key: keys.Key, alloc: std.mem.Allocator) bool {
        if (self.vtable.handle_key) |h| return h(self.ptr, key, alloc);
        return false;
    }

    pub fn deinit(self: *Component, alloc: std.mem.Allocator) void {
        if (self.vtable.deinit) |d| d(self.ptr, alloc);
    }
};

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// Renders a (possibly multi-line, ANSI-containing) string, hard-wrapped to
/// the available width. v1 wrap is ANSI-unaware (ANSI-aware wrap is G6).
pub const Text = struct {
    text: []const u8,
    comp: Component,

    /// Initialize in place (vtable self-pointer must point at the live instance).
    pub fn init(self: *Text, text: []const u8) void {
        self.text = text;
        self.comp = .{ .ptr = @ptrCast(self), .vtable = &vt };
    }

    const vt: Component.VTable = .{
        .render = renderImpl,
        .handle_key = null,
        .deinit = null,
    };

    fn renderImpl(self: *anyopaque, ctx: Ctx) Rendered {
        const t: *Text = @alignCast(@ptrCast(self));
        const alloc = ctx.alloc;
        const width = ctx.width;

        // Split into paragraphs on '\n', wrap each, collect lines.
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(alloc);

        var it = std.mem.splitScalar(u8, t.text, '\n');
        while (it.next()) |para| {
            const wrapped = wrapParagraph(alloc, para, width) catch {
                out.deinit(alloc);
                return Rendered.empty(alloc);
            };
            defer alloc.free(wrapped);
            for (wrapped) |line| {
                const dup = alloc.dupe(u8, line) catch continue;
                out.append(alloc, dup) catch {
                    for (out.items) |l| alloc.free(l);
                    out.deinit(alloc);
                    return Rendered.empty(alloc);
                };
            }
        }

        const lines = out.toOwnedSlice(alloc) catch &.{};
        return .{ .lines = lines, .alloc = alloc };
    }
};

/// Word-wrap a paragraph to `width` columns. Returns an owned array of owned
/// line slices (the caller frees the outer array; inner slices point into a
/// single owned buffer that the caller does NOT free separately — see note).
///
/// NOTE: For simplicity the inner slices point into one owned buffer; the
/// caller in Text.renderImpl dupes each line, so this buffer can be freed by
/// the helper's owner. Here we return the outer slice only and the caller
/// dupes. To keep ownership simple, we allocPrint each line independently.
fn wrapParagraph(alloc: std.mem.Allocator, para: []const u8, width: usize) ![]const []const u8 {
    var w = width;
    if (w == 0) w = 1;
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }

    var line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line.deinit(alloc);
    var line_len: usize = 0;

    var it = std.mem.splitScalar(u8, para, ' ');
    var first = true;
    while (it.next()) |word| {
        // Start a new line if the word doesn't fit on the current one.
        if (!first) {
            if (line_len + 1 + word.len > w) {
                const l = line.toOwnedSlice(alloc) catch return error.OutOfMemory;
                lines.append(alloc, l) catch return error.OutOfMemory;
                line.clearRetainingCapacity();
                line_len = 0;
            } else {
                line.append(alloc, ' ') catch return error.OutOfMemory;
                line_len += 1;
            }
        }
        // Hard-split the word if it's longer than the remaining line width.
        var wi: usize = 0;
        while (wi < word.len) {
            const room = w - line_len;
            const take = @min(word[wi..].len, if (room == 0) 1 else room);
            for (word[wi .. wi + take]) |ch| {
                line.append(alloc, ch) catch return error.OutOfMemory;
            }
            line_len += take;
            wi += take;
            if (line_len >= w and wi < word.len) {
                const l = line.toOwnedSlice(alloc) catch return error.OutOfMemory;
                lines.append(alloc, l) catch return error.OutOfMemory;
                line.clearRetainingCapacity();
                line_len = 0;
            }
        }
        first = false;
    }
    // Flush the last line (even if empty, to preserve blank lines).
    const l = line.toOwnedSlice(alloc) catch return error.OutOfMemory;
    lines.append(alloc, l) catch return error.OutOfMemory;

    return lines.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// VStack
// ---------------------------------------------------------------------------

/// Stacks child components vertically, concatenating their rendered lines.
pub const VStack = struct {
    children: std.ArrayListUnmanaged(Component),
    comp: Component,

    /// Initialize in place.
    pub fn init(self: *VStack, alloc: std.mem.Allocator) void {
        self.children = .empty;
        self.comp = .{ .ptr = @ptrCast(self), .vtable = &vt };
        _ = alloc;
    }

    pub fn append(self: *VStack, alloc: std.mem.Allocator, child: Component) !void {
        self.children.append(alloc, child) catch return error.OutOfMemory;
    }

    pub fn deinit(self: *VStack, alloc: std.mem.Allocator) void {
        for (self.children.items) |*c| c.deinit(alloc);
        self.children.deinit(alloc);
    }

    const vt: Component.VTable = .{
        .render = renderImpl,
        .handle_key = null,
        .deinit = null,
    };

    fn renderImpl(self: *anyopaque, ctx: Ctx) Rendered {
        const v: *VStack = @alignCast(@ptrCast(self));
        const alloc = ctx.alloc;
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(alloc);

        for (v.children.items) |*child| {
            const rendered = child.render(ctx);
            defer rendered.free();
            for (rendered.lines) |line| {
                const dup = alloc.dupe(u8, line) catch continue;
                out.append(alloc, dup) catch {
                    for (out.items) |l| alloc.free(l);
                    out.deinit(alloc);
                    return Rendered.empty(alloc);
                };
            }
        }

        const lines = out.toOwnedSlice(alloc) catch &.{};
        return .{ .lines = lines, .alloc = alloc };
    }
};

// ---------------------------------------------------------------------------
// Spacer
// ---------------------------------------------------------------------------

/// Renders `n` blank lines.
pub const Spacer = struct {
    rows: usize,
    comp: Component,

    /// Initialize in place.
    pub fn init(self: *Spacer, rows: usize) void {
        self.rows = rows;
        self.comp = .{ .ptr = @ptrCast(self), .vtable = &vt };
    }

    const vt: Component.VTable = .{
        .render = renderImpl,
        .handle_key = null,
        .deinit = null,
    };

    fn renderImpl(self: *anyopaque, ctx: Ctx) Rendered {
        const s: *Spacer = @alignCast(@ptrCast(self));
        const alloc = ctx.alloc;
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(alloc);
        for (0..s.rows) |_| {
            const line = alloc.dupe(u8, "") catch continue;
            out.append(alloc, line) catch {
                for (out.items) |l| alloc.free(l);
                out.deinit(alloc);
                return Rendered.empty(alloc);
            };
        }
        const lines = out.toOwnedSlice(alloc) catch &.{};
        return .{ .lines = lines, .alloc = alloc };
    }
};

// ---------------------------------------------------------------------------
// Box
// ---------------------------------------------------------------------------

/// Renders a Text with a single-line top/bottom border and left/right padding.
pub const Box = struct {
    text: []const u8,
    title: []const u8,
    comp: Component,

    /// Initialize in place.
    pub fn init(self: *Box, text: []const u8, title: []const u8) void {
        self.text = text;
        self.title = title;
        self.comp = .{ .ptr = @ptrCast(self), .vtable = &vt };
    }

    const vt: Component.VTable = .{
        .render = renderImpl,
        .handle_key = null,
        .deinit = null,
    };

    fn renderImpl(self: *anyopaque, ctx: Ctx) Rendered {
        const b: *Box = @alignCast(@ptrCast(self));
        const alloc = ctx.alloc;
        const width = ctx.width;

        var inner: Text = undefined;
        inner.init(b.text);
        const body = inner.comp.render(ctx);
        defer body.free();

        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(alloc);

        // Top border with title (fixed, not full-width — v1 keeps it simple).
        const top = std.fmt.allocPrint(alloc, "\x1b[90m┌─ {s} ─\x1b[0m", .{b.title}) catch return Rendered.empty(alloc);
        out.append(alloc, top) catch return Rendered.empty(alloc);
        // Body lines with a left gutter.
        for (body.lines) |line| {
            const padded = std.fmt.allocPrint(alloc, "\x1b[90m│\x1b[0m {s}", .{line}) catch continue;
            out.append(alloc, padded) catch {
                for (out.items) |l| alloc.free(l);
                out.deinit(alloc);
                return Rendered.empty(alloc);
            };
        }
        // Bottom border.
        const bottom = std.fmt.allocPrint(alloc, "\x1b[90m└──────\x1b[0m", .{}) catch return Rendered.empty(alloc);
        out.append(alloc, bottom) catch return Rendered.empty(alloc);
        _ = width;

        const lines = out.toOwnedSlice(alloc) catch &.{};
        return .{ .lines = lines, .alloc = alloc };
    }
};

test "Text renders single line" {
    const alloc = std.heap.page_allocator;

    var t: Text = undefined;
    t.init("hello");
    const ctx = Ctx{ .alloc = alloc, .width = 80 };
    const r = t.comp.render(ctx);
    defer r.free();
    try std.testing.expectEqual(@as(usize, 1), r.lines.len);
    try std.testing.expectEqualStrings("hello", r.lines[0]);
}

test "Text wraps long paragraph" {
    const alloc = std.heap.page_allocator;

    var t: Text = undefined;
    t.init("aaaa bbbb cccc dddd");
    const ctx = Ctx{ .alloc = alloc, .width = 11 };
    const r = t.comp.render(ctx);
    defer r.free();
    // "aaaa bbbb" (9) then "cccc dddd" (9) — each fits in 11.
    try std.testing.expectEqual(@as(usize, 2), r.lines.len);
    try std.testing.expectEqualStrings("aaaa bbbb", r.lines[0]);
    try std.testing.expectEqualStrings("cccc dddd", r.lines[1]);
}

test "VStack concatenates children" {
    const alloc = std.heap.page_allocator;

    var stack: VStack = undefined;
    stack.init(alloc);
    defer stack.deinit(alloc);
    var t1: Text = undefined;
    t1.init("line1");
    var t2: Text = undefined;
    t2.init("line2");
    _ = stack.append(alloc, t1.comp) catch {};
    _ = stack.append(alloc, t2.comp) catch {};
    const ctx = Ctx{ .alloc = alloc, .width = 80 };
    const r = stack.comp.render(ctx);
    defer r.free();
    try std.testing.expectEqual(@as(usize, 2), r.lines.len);
    try std.testing.expectEqualStrings("line1", r.lines[0]);
    try std.testing.expectEqualStrings("line2", r.lines[1]);
}

test "Spacer produces blank lines" {
    const alloc = std.heap.page_allocator;

    var s: Spacer = undefined;
    s.init(3);
    const ctx = Ctx{ .alloc = alloc, .width = 80 };
    const r = s.comp.render(ctx);
    defer r.free();
    try std.testing.expectEqual(@as(usize, 3), r.lines.len);
}
