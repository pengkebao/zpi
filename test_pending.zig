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

// ---- P1/P2 recovery helpers (empty-retry backoff, isRecoverableLength,
//      all-thinking detection) -------------------------------------------

fn makeSession(alloc: std.mem.Allocator, io: std.Io, model: *config.Config.Model) !agent.Session {
    const provider = try aiprovider.buildFromModel(alloc, io, model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    return agent.Session.init(alloc, io, model, &registry, provider, "test");
}

test "emptyRetryDelayMs is exponential 1s,2s,4s" {
    try std.testing.expectEqual(@as(i64, 1000), agent.Session.emptyRetryDelayMs(1));
    try std.testing.expectEqual(@as(i64, 2000), agent.Session.emptyRetryDelayMs(2));
    try std.testing.expectEqual(@as(i64, 4000), agent.Session.emptyRetryDelayMs(3));
    // attempt 0 is clamped to 1 (never negative exponent)
    try std.testing.expectEqual(@as(i64, 1000), agent.Session.emptyRetryDelayMs(0));
}

test "blocksAreAllThinking detects thinking-only rounds" {
    const msg = @import("src/core/message.zig");
    const alloc = std.heap.page_allocator;
    const only = [_]msg.ContentBlock{.{ .thinking = "hmm" }};
    try std.testing.expect(msg.blocksAreAllThinking(&only));

    const mixed = [_]msg.ContentBlock{
        .{ .thinking = "hmm" },
        .{ .text = "answer" },
    };
    try std.testing.expect(!msg.blocksAreAllThinking(&mixed));

    const empty = [_]msg.ContentBlock{};
    try std.testing.expect(!msg.blocksAreAllThinking(&empty));

    const tid = try alloc.dupe(u8, "t1");
    defer alloc.free(tid);
    const tname = try alloc.dupe(u8, "bash");
    defer alloc.free(tname);
    const targs = try alloc.dupe(u8, "{}");
    defer alloc.free(targs);
    const tool = [_]msg.ContentBlock{.{ .tool_call = .{ .id = tid, .name = tname, .arguments = targs } }};
    try std.testing.expect(!msg.blocksAreAllThinking(&tool));
}

test "isRecoverableLength matches pi overflow heuristic" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
        .max_tokens = 1000,
    };
    var session = try makeSession(alloc, io, &model);
    defer session.deinit();

    const ai = @import("src/ai/openai.zig");

    // finish != length → not recoverable
    session.stream_finish = .stop;
    session.stream_usage = .{ .output = 10 };
    try std.testing.expect(!session.isRecoverableLength());

    // finish == length, output < max_tokens → recoverable
    session.stream_finish = .length;
    session.stream_usage = .{ .output = 10 };
    try std.testing.expect(session.isRecoverableLength());

    // recoverable only once (flag set)
    session.length_recovered = true;
    try std.testing.expect(!session.isRecoverableLength());

    // output reached max_tokens → NOT recoverable (model used its full budget)
    session.length_recovered = false;
    session.stream_usage = .{ .output = 1000 };
    try std.testing.expect(!session.isRecoverableLength());

    // no usage → treated as 0 output → recoverable under length
    session.stream_usage = null;
    try std.testing.expect(session.isRecoverableLength());
    _ = ai.FinishReason.stop; // keep import referenced
}

test "pending rows wrap long text and budget counts the same wraps" {
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
    t.width = 40;

    // A long steering message that must wrap at width 40 (label "Steering: "
    // is 10 cols, so the text wraps at 30).
    const long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda";
    session.queueSteering(long);

    // The render must produce MORE than one row (it used to be one, clipped).
    var frame: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame.items) |l| alloc.free(l);
        frame.deinit(alloc);
    }
    t.renderLiveQueue(&frame);
    try std.testing.expect(frame.items.len > 1);
    // First row carries the label; continuation rows align under the text.
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "Steering: alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[1], "Steering:") == null);
    // The whole message survived the wrap (nothing clipped).
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(alloc);
    for (frame.items) |r| all.appendSlice(alloc, r) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, all.items, "lambda") != null);

    // The layout budget matches the rendered row count exactly.
    try std.testing.expectEqual(frame.items.len, session.queuedPeekRows(40));

    // A multi-line message keeps its explicit newlines (fresh session).
    var model2: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    var registry2 = tools.Registry.init(alloc);
    try tools.registerAll(&registry2);
    var session2 = try agent.Session.init(alloc, io, &model2, &registry2, provider, "test");
    defer session2.deinit();
    var t2 = tui.TUI.init(io, alloc, &session2, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t2.deinit();
    t2.working = true;
    t2.width = 40;
    session2.queueSteering("line one\nline two");
    var frame2: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame2.items) |l| alloc.free(l);
        frame2.deinit(alloc);
    }
    t2.renderLiveQueue(&frame2);
    try std.testing.expect(std.mem.indexOf(u8, frame2.items[0], "Steering: line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame2.items[1], "line two") != null);
}
