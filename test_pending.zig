const std = @import("std");
const tui = @import("src/ui/tui.zig");
const agent = @import("src/core/agent.zig");
const config = @import("src/core/config.zig");
const tools = @import("src/tools/registry.zig");
const aiprovider = @import("src/ai/provider.zig");

test "pending queue rows render (steering + follow-up labels)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    defer session.deinit();
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();
    t.working = true;

    session.queueSteering("STEER-XYZ");
    session.queueFollowUp("FOLLOW-XYZ");
    try std.testing.expectEqual(@as(usize, 2), t.session.queuedPeekLen());

    var frame: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame.items) |l| alloc.free(l);
        frame.deinit(alloc);
    }
    t.renderLiveQueue(&frame);
    try std.testing.expectEqual(@as(usize, 2), frame.items.len);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "Steering: STEER-XYZ") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[1], "Follow-up: FOLLOW-XYZ") != null);
}

test "restoreQueued joins steering+follow-up into the editor" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    defer session.deinit();
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    session.queueSteering("AAA");
    session.queueFollowUp("BBB");
    t.editor.setText("current text") catch {};
    const text = t.session.restoreQueued() orelse return error.ExpectedSome;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("AAA\n\nBBB", text);
    try std.testing.expectEqual(@as(usize, 0), t.session.queuedPeekLen());
    // empty queues → null
    try std.testing.expect(t.session.restoreQueued() == null);
}
