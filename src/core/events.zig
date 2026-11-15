//! Internal event bus (Phase I3) — the single mount point shared by the
//! hooks engine (I2), built-in extension modules (I4) and future features.
//!
//! Semantics mirror the tool-execution flow of pi's extension runner:
//! listeners are synchronous; `pre_tool_call` listeners may BLOCK the call
//! by returning a reason (fed back to the model as an error result);
//! every other event is observe-only. Listeners run on the caller's thread
//! — for tools that means the per-tool worker thread, so listeners must be
//! thread-safe (the hooks engine just spawns short-lived subprocesses).

const std = @import("std");

pub const PreToolPayload = struct {
    name: []const u8,
    args_json: []const u8,
};

pub const PostToolPayload = struct {
    name: []const u8,
    args_json: []const u8,
    result: []const u8,
    is_error: bool,
    duration_ms: u64,
};

pub const Event = union(enum) {
    session_start,
    pre_tool_call: PreToolPayload,
    post_tool_call: PostToolPayload,
    /// User submitted a prompt (text; hook scripts receive it on stdin).
    input: []const u8,
    compaction,
};

pub const Listener = struct {
    ctx: *anyopaque,
    /// Return a block reason for `pre_tool_call` (caller frees with
    /// `bus_alloc`); null = allow / observe-only for other events.
    onEvent: *const fn (ctx: *anyopaque, event: Event, bus_alloc: std.mem.Allocator) ?[]const u8,
};

pub const Bus = struct {
    alloc: std.mem.Allocator,
    listeners: std.ArrayListUnmanaged(Listener) = .empty,

    pub fn init(alloc: std.mem.Allocator) Bus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Bus) void {
        self.listeners.deinit(self.alloc);
    }

    pub fn add(self: *Bus, listener: Listener) !void {
        try self.listeners.append(self.alloc, listener);
    }

    /// Emit an observe-only event (return value is always null).
    pub fn emit(self: *Bus, event: Event) void {
        _ = self.emitBlocking(event);
    }

    /// Emit a blocking-capable event: the first listener returning a reason
    /// blocks (later listeners are skipped, pi's first-error-wins flow).
    /// Returns the reason (allocated with `self.alloc`) or null when every
    /// listener allowed the event. Caller frees the reason.
    pub fn emitBlocking(self: *Bus, event: Event) ?[]const u8 {
        for (self.listeners.items) |l| {
            if (l.onEvent(l.ctx, event, self.alloc)) |reason| {
                return reason;
            }
        }
        return null;
    }
};

/// Global handle (single-process; mirrors mcp.Manager.setGlobal).
var g: ?*Bus = null;

pub fn setGlobal(bus: ?*Bus) void {
    g = bus;
}

pub fn getGlobal() ?*Bus {
    return g;
}

// ---- tests ----

const testing = std.testing;

const TestCtx = struct {
    saw: usize = 0,
    block_on: ?[]const u8 = null,
};

fn testListener(ctx: *anyopaque, event: Event, bus_alloc: std.mem.Allocator) ?[]const u8 {
    const c: *TestCtx = @ptrCast(@alignCast(ctx));
    c.saw += 1;
    if (c.block_on) |b| {
        switch (event) {
            .pre_tool_call => |p| {
                if (std.mem.eql(u8, p.name, b)) {
                    return std.fmt.allocPrint(bus_alloc, "no {s} allowed", .{p.name}) catch null;
                }
            },
            else => {},
        }
    }
    return null;
}

test "bus dispatches and blocks" {
    const alloc = testing.allocator;
    var bus = Bus.init(alloc);
    defer bus.deinit();
    var ctx = TestCtx{ .block_on = "rm" };
    try bus.add(.{ .ctx = &ctx, .onEvent = testListener });

    bus.emit(.session_start);
    bus.emit(.{ .input = "hi" });
    try testing.expectEqual(@as(usize, 2), ctx.saw);

    // allow path
    const r1 = bus.emitBlocking(.{ .pre_tool_call = .{ .name = "read", .args_json = "{}" } });
    try testing.expect(r1 == null);
    // block path
    const r2 = bus.emitBlocking(.{ .pre_tool_call = .{ .name = "rm", .args_json = "{}" } });
    try testing.expect(r2 != null);
    alloc.free(r2.?);
    try testing.expectEqual(@as(usize, 4), ctx.saw);
}
