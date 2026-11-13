//! Scroll-frame benchmark: markdown-heavy vs plain transcript.
//! Redirects stdout to /dev/null so redrawLocked can run silently.
const std = @import("std");
const tui = @import("src/ui/tui.zig");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const tools = @import("src/tools/registry.zig");

const FRAMES = 60;

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

fn runCase(label: []const u8, markdown: bool, io: std.Io, alloc: std.mem.Allocator) !void {
    const fixture = try buildTui(alloc, io);
    const t = &fixture.t;
    defer t.deinit();
    t.width = 110;
    t.height = 30;

    var md_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer md_buf.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &md_buf);
    defer aw.deinit();
    const w = &aw.writer;
    for (0..12) |i| {
        if (markdown) {
            w.print("## 标题 {d}\n\n这是**第 {d}** 段中文内容，包含 `inline code`、[链接](https://example.com) 和 emoji ✅。\n\n", .{ i, i }) catch return error.OutOfMemory;
            w.print("| 列一 | 列二 | 列三 |\n|---|---|---|\n| 数据 {d}a | 数据 {d}b | ✅ |\n| 更长的数据内容 | 短 | ⚠️ |\n\n", .{ i, i }) catch return error.OutOfMemory;
            w.print("```zig\nconst x = {d}; // 代码块内容\nconst y = x + 42;\n```\n\n- 列表项甲 **粗体**\n- 列表项乙 *斜体*\n- 列表项丙 `code`\n\n", .{i}) catch return error.OutOfMemory;
        } else {
            w.print("Plain paragraph {d}: the quick brown fox jumps over the lazy dog repeatedly.\n\nSecond line of plain text content for comparison.\n\n", .{i}) catch return error.OutOfMemory;
        }
    }
    const msg = try aw.toOwnedSlice();
    t.addAssistantMessage(msg);
    t.addMessage("用户消息：测试滚动性能。\n");

    // settle the initial frame
    t.redrawLocked();
    var worst: f64 = 0;
    var sum: f64 = 0;
    var frames: usize = 0;
    for (0..FRAMES) |_| {
        const t0 = std.Io.Timestamp.now(io, .real).nanoseconds;
        t.scrollBy(-2);
        t.redrawLocked();
        const ns: f64 = @floatFromInt(std.Io.Timestamp.now(io, .real).nanoseconds - t0);
        sum += ns;
        frames += 1;
        if (ns > worst) worst = ns;
        if (t.sv.scroll_top == 0) break; // reached the top early
    }
    std.debug.print("{s}: avg {d:.2} ms/frame, worst {d:.2} ms ({d} frames, doc_rows={d})\n", .{
        label, sum / @as(f64, @floatFromInt(frames)) / std.time.ns_per_ms,
        worst / std.time.ns_per_ms, frames, t.doc_len,
    });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    silenceStdout();
    try runCase("markdown", true, io, alloc);
    try runCase("plain   ", false, io, alloc);
}
