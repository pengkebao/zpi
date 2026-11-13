//! Streaming-frame benchmark: liveBlockLocked (full markdown re-render) cost
//! vs stream length, plus the full spinner-frame cost while working.
const std = @import("std");
const tui = @import("src/ui/tui.zig");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const tools = @import("src/tools/registry.zig");

fn silenceStdout() void {
    const fd = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), "/dev/null", .{ .mode = .write_only }) catch return;
    _ = std.c.dup2(fd.handle, 1);
}

const Fixture = struct {
    model: config.Config.Model,
    provider: ai.OpenAiProvider,
    registry: tools.Registry,
    session: agent.Session,
    t: tui.TUI,
};

fn buildTui(alloc: std.mem.Allocator, io: std.Io) !*Fixture {
    const f = try alloc.create(Fixture);
    f.model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
    };
    f.provider = try ai.OpenAiProvider.init(alloc, io, f.model.base_url, f.model.api_key);
    f.registry = tools.Registry.init(alloc);
    try tools.registerAll(&f.registry);
    f.session = try agent.Session.init(alloc, io, &f.model, &f.registry, &f.provider, "test");
    f.t = tui.TUI.init(io, alloc, &f.session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
    return f;
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

fn benchStream(alloc: std.mem.Allocator, io: std.Io, target_kb: usize) !void {
    const fixture = try buildTui(alloc, io);
    const t = &fixture.t;
    defer t.deinit();
    t.width = 110;
    t.height = 30;

    // 12 finished markdown turns in the scrollback (the "rendered markdown"
    // transcript), then simulate an in-flight markdown stream of target size.
    var md_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer md_buf.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &md_buf);
    defer aw.deinit();
    const w = &aw.writer;
    for (0..12) |i| {
        w.print("## 标题 {d}\n\n这是**第 {d}** 段中文内容，包含 `inline code` 和 emoji ✅。\n\n| 列一 | 列二 |\n|---|---|\n| 数据 {d} | ✅ |\n\n```zig\nconst x = {d};\n```\n\n", .{ i, i, i, i }) catch {};
    }
    const msg = try aw.toOwnedSlice();
    t.addAssistantMessage(msg);

    // streaming state: working + a markdown stream of ~target_kb bytes
    t.render_mutex.lock(io) catch return;
    t.working = true;
    const chunk = "这是**流式**第 x 段中文内容，带 `code` 与表格：\n\n| a | b |\n|---|---|\n| 1 | ✅ |\n\n";
    var fed: usize = 0;
    while (fed < target_kb * 1024) : (fed += chunk.len) {
        try t.stream_text.appendSlice(chunk);
    }
    t.render_mutex.unlock(io);

    // Cold live render (cache miss), then 10 spinner-style frames each with a
    // small append (cache invalidated every chunk like real streaming).
    var worst_live: f64 = 0;
    var sum_live: f64 = 0;
    const reps = 10;
    for (0..reps) |i| {
        t.render_mutex.lock(io) catch return;
        try t.stream_text.appendSlice(chunk);
        const t0 = nowNs(io);
        const live = t.liveBlockLocked() catch unreachable;
        _ = live;
        const ns: f64 = @floatFromInt(nowNs(io) - t0);
        sum_live += ns;
        if (ns > worst_live) worst_live = ns;
        t.render_mutex.unlock(io);
        std.debug.print("  rep {d}: {d:.2} ms\n", .{ i, ns / std.time.ns_per_ms });
    }
    const stream_kb = fed / 1024;
    std.debug.print("stream≈{d}KB: liveBlockLocked avg {d:.2} ms, worst {d:.2} ms (re-render every chunk)\n", .{
        stream_kb, sum_live / reps / std.time.ns_per_ms, worst_live / std.time.ns_per_ms,
    });

    // full spinner frame (redrawLocked with working=true, live tail in doc)
    t.render_mutex.lock(io) catch return;
    var worst_frame: f64 = 0;
    var sum_frame: f64 = 0;
    for (0..reps) |_| {
        try t.stream_text.appendSlice(chunk); // invalidate live cache per frame
        const t0 = nowNs(io);
        t.redrawLocked();
        const ns: f64 = @floatFromInt(nowNs(io) - t0);
        sum_frame += ns;
        if (ns > worst_frame) worst_frame = ns;
    }
    t.render_mutex.unlock(io);
    std.debug.print("stream≈{d}KB: spinner frame avg {d:.2} ms, worst {d:.2} ms\n\n", .{
        stream_kb, sum_frame / reps / std.time.ns_per_ms, worst_frame / std.time.ns_per_ms,
    });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    silenceStdout();
    try benchStream(alloc, io, 4);
    try benchStream(alloc, io, 16);
    try benchStream(alloc, io, 48);
}
