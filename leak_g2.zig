const std = @import("std");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const tools = @import("src/tools/registry.zig");
const tui = @import("src/ui/tui.zig");

test "TUI batch2 leak" {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const alloc = safe.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Minimal model (no config.load — avoids the HOME/environ dependency).
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
    };

    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test system prompt");
    var t = tui.TUI.init(io, alloc, &session, model.name, "/tmp/sessions", "/tmp", null, null, .empty, null, null);

    // Exercise the new editor + footer + multi-line transcript.
    t.addUserMessage("hello world");
    t.addAssistantMessage("hi there, this is a longer response that should wrap across multiple lines in the transcript area of the fullscreen TUI so we can exercise the wrapping and the differential renderer with a realistic amount of text");
    t.addMessage("some system note line for the transcript");

    // Thinking (dim italic markdown) and a compaction block.
    t.addThinkingBlock("the user says hi; I should answer briefly with **markdown**");
    t.addCompactionBlock(48344);

    // Tool call lifecycle. The events hand their strings to the TUI: a pending
    // box, its result repainted in place, then both Ctrl+O states.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "call_1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"seq 12\"}"),
    });
    t.finishTool(.{
        .id = try alloc.dupe(u8, "call_1"),
        .content = try alloc.dupe(u8, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n"),
        .is_error = false,
        .duration_ms = 1500,
    });
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "call_2"),
        .name = try alloc.dupe(u8, "edit"),
        .arguments = try alloc.dupe(u8, "{\"path\":\"a.txt\"}"),
    });
    t.finishTool(.{
        .id = try alloc.dupe(u8, "call_2"),
        .content = try alloc.dupe(u8, "error: oldText not found"),
        .is_error = true,
        .duration_ms = 3,
    });
    t.setToolsExpanded(true);
    t.setToolsExpanded(false);
    // A result nobody is waiting for is dropped, not leaked.
    t.finishTool(.{
        .id = try alloc.dupe(u8, "call_unknown"),
        .content = try alloc.dupe(u8, "orphan"),
        .is_error = false,
        .duration_ms = 0,
    });
    // A call that never gets its result stays pending until teardown.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "call_3"),
        .name = try alloc.dupe(u8, "read"),
        .arguments = try alloc.dupe(u8, "{\"path\":\"x.zig\",\"offset\":1,\"limit\":20}"),
    });

    // Editor: type a multi-line prompt and submit.
    t.editor.insertChar('a') catch {};
    t.editor.newLine() catch {};
    t.editor.insertChar('b') catch {};
    t.redraw();
    t.editor.clear() catch {};
    t.redraw();

    // Scrolled up: the "Jump to latest" label composites onto the last
    // transcript row (an owned overlay line), then goes away again. The
    // ScrollView needs a measured layout first (content > viewport).
    t.render_mutex.lock(t.io) catch {};
    t.sv.updateLayout(40, 20);
    t.render_mutex.unlock(t.io);
    t.scrollBy(-3);
    t.redraw();
    t.scrollToLatest();
    t.redraw();

    // Deinit in reverse creation order (explicit, before safe.deinit).
    t.deinit();
    session.deinit();
    registry.deinit();
    provider.deinit();
    alloc.free(model.provider);
    alloc.free(model.id);
    alloc.free(model.name);
    alloc.free(model.base_url);
    alloc.free(model.api_key);

    const leaks = safe.deinit();
    try std.testing.expectEqual(@as(usize, 0), leaks);
}
