const std = @import("std");
const tui = @import("src/ui/tui.zig");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const aiprovider = @import("src/ai/provider.zig");
const tools = @import("src/tools/registry.zig");
const tool_search = @import("src/tools/tool_search.zig");
const component = @import("src/ui/component.zig");
const keys = @import("src/ui/keys.zig");
const ss = @import("src/core/session_store.zig");
const cmsg = @import("src/core/message.zig");
const editor = @import("src/ui/editor.zig");
const width = @import("src/ui/width.zig");
const markdown = @import("src/ui/markdown.zig");
const tool_block = @import("src/ui/tool_block.zig");
const footer = @import("src/ui/footer.zig");
const overlay = @import("src/ui/overlay.zig");
const ansi = @import("src/ui/ansi.zig");
comptime {
    _ = tool_search;
    _ = tui;
    _ = component;
    _ = editor;
    _ = width;
    _ = markdown;
    _ = tool_block;
    _ = footer;
    _ = overlay;
}

// ---- Kitty keyboard-protocol (CSI-u) parsing ----

test "kitty: plain letter a" {
    const k = keys.parseKey("\x1b[97u") orelse return error.NoKey;
    if (k != .text) return error.WrongType;
    const t = k.text;
    try std.testing.expect(t.len == 1 and t.bytes[0] == 'a');
}

test "kitty: shift letter uses shifted codepoint (A)" {
    const k = keys.parseKey("\x1b[97:65;2u") orelse return error.NoKey;
    if (k != .text) return error.WrongType;
    const t = k.text;
    try std.testing.expect(t.len == 1 and t.bytes[0] == 'A');
}

test "kitty: shift+enter" {
    const k = keys.parseKey("\x1b[13;2u") orelse return error.NoKey;
    try std.testing.expect(k == .shift_enter);
}

test "kitty: plain enter" {
    const k = keys.parseKey("\x1b[13u") orelse return error.NoKey;
    try std.testing.expect(k == .enter);
}

test "kitty: numpad enter with shift" {
    const k = keys.parseKey("\x1b[57414;2u") orelse return error.NoKey;
    try std.testing.expect(k == .shift_enter);
}

test "kitty: CSI-u escape key (27)" {
    const k = keys.parseKey("\x1b[27u") orelse return error.NoKey;
    try std.testing.expect(k == .escape);
}

test "kitty: tab" {
    const k = keys.parseKey("\x1b[9u") orelse return error.NoKey;
    try std.testing.expect(k == .tab);
}

test "kitty: arrow up with mod" {
    const k = keys.parseKey("\x1b[1;1A") orelse return error.NoKey;
    try std.testing.expect(k == .up);
}

test "kitty: arrow down with shift" {
    const k = keys.parseKey("\x1b[1;2B") orelse return error.NoKey;
    try std.testing.expect(k == .down);
}

test "kitty: shift+= produces +" {
    const k = keys.parseKey("\x1b[61:43;2u") orelse return error.NoKey;
    if (k != .text) return error.WrongType;
    const t = k.text;
    try std.testing.expect(t.len == 1 and t.bytes[0] == '+');
}

test "kitty: CJK char U+4F60 (ni)" {
    const k = keys.parseKey("\x1b[20320u") orelse return error.NoKey;
    if (k != .text) return error.WrongType;
    const t = k.text;
    try std.testing.expect(t.len == 3);
    try std.testing.expect(t.bytes[0] == 0xE4 and t.bytes[1] == 0xBD and t.bytes[2] == 0xA0);
}

test "kitty: event type suffix ignored" {
    // codepoint 97 with mod 1 and event 1 (press)
    const k = keys.parseKey("\x1b[97;1:1u") orelse return error.NoKey;
    if (k != .text) return error.WrongType;
    const t = k.text;
    try std.testing.expect(t.len == 1 and t.bytes[0] == 'a');
}

test "live block renders the full streaming markdown (pushes the viewport)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Logic-only test: page allocator, leak tracking lives in leak_g2.
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.stream_thinking.appendSlice("reasoning step one\nreasoning step two") catch {};
    t.stream_text.appendSlice("first line of the answer\nsecond line\nthird line") catch {};
    t.working = true;
    t.render_mutex.lock(t.io) catch {};
    const lines = try t.liveBlockLocked();
    t.render_mutex.unlock(t.io);
    // Full render: EVERY line shows (no tail budget), so the viewport can
    // push up as the stream grows; the second thinking row is present.
    var has_thinking_first = false;
    var has_thinking_second = false;
    var has_text_first = false;
    var has_text_last = false;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "reasoning step one") != null) has_thinking_first = true;
        if (std.mem.indexOf(u8, l, "reasoning step two") != null) has_thinking_second = true;
        if (std.mem.indexOf(u8, l, "first line of the answer") != null) has_text_first = true;
        if (std.mem.indexOf(u8, l, "third line") != null) has_text_last = true;
    }
    try std.testing.expect(has_thinking_first);
    try std.testing.expect(has_thinking_second);
    try std.testing.expect(has_text_first);
    try std.testing.expect(has_text_last);

    // The cache holds: an unchanged buffer returns the same slice.
    t.render_mutex.lock(t.io) catch {};
    const again = try t.liveBlockLocked();
    t.render_mutex.unlock(t.io);
    try std.testing.expectEqual(lines.ptr, again.ptr);
}

fn tui_test_free_lines(alloc: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| alloc.free(l);
    alloc.free(lines);
}

test "tool call: the pending box is repainted in place by its result" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Logic-only test: page allocator, leak tracking lives in leak_g2.
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);

    const pending_bg = "\x1b[48;2;52;56;58m";
    const success_bg = "\x1b[48;2;37;65;49m";
    const error_bg = "\x1b[48;2;91;40;42m";

    // The call starts: a gray box with only the header.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"echo hi\"}"),
    });
    try std.testing.expectEqual(@as(usize, 1), t.scrollback.items.len);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], pending_bg) != null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "$ echo hi") != null);

    // Something else is appended before the result arrives.
    t.addMessage("a later message");
    t.finishTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .content = try alloc.dupe(u8, "hi\n"),
        .is_error = false,
        .duration_ms = 1200,
    });
    // Same slot, now green, with the output and the wall time.
    try std.testing.expectEqual(@as(usize, 2), t.scrollback.items.len);
    const done = t.scrollback.items[0];
    try std.testing.expect(std.mem.indexOf(u8, done, success_bg) != null);
    try std.testing.expect(std.mem.indexOf(u8, done, pending_bg) == null);
    try std.testing.expect(std.mem.indexOf(u8, done, "Took 1.2s") != null);
    try std.testing.expectEqualStrings("a later message", t.scrollback.items[1]);

    // A failed call ends on the error background.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "c2"),
        .name = try alloc.dupe(u8, "read"),
        .arguments = try alloc.dupe(u8, "{\"path\":\"missing.txt\"}"),
    });
    t.finishTool(.{
        .id = try alloc.dupe(u8, "c2"),
        .content = try alloc.dupe(u8, "error: file not found"),
        .is_error = true,
        .duration_ms = 1,
    });
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[2], error_bg) != null);

    // Ctrl+O repaints every tool block without moving it.
    t.setToolsExpanded(true);
    try std.testing.expectEqual(@as(usize, 3), t.scrollback.items.len);
    try std.testing.expectEqualStrings("a later message", t.scrollback.items[1]);

    t.clearTranscript();
    try std.testing.expectEqual(@as(usize, 0), t.scrollback.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.tool_calls.items.len);
}

// ---- Streaming tool-call preview order ----

// The streaming tool preview must NOT commit a scrollback card: a round's
// text event lands in the scrollback before the tool's .tool_start, so an
// early commit renders the card ABOVE the text during streaming and flips it
// BELOW once the round commits (the regression this fixes).
test "streaming tool args park in the live block, not the scrollback" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Logic-only test: page allocator, leak tracking lives in leak_g2.
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    const pending_bg = "\x1b[48;2;52;56;58m";
    t.width = 80;

    // Arguments arrive mid-stream (no committed entry yet): no scrollback
    // card, the preview parks under the live block instead.
    t.updatePendingToolArgs(.{
        .id = try alloc.dupe(u8, "s1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"echo hi\""),
    });
    try std.testing.expectEqual(@as(usize, 0), t.scrollback.items.len);
    try std.testing.expect(t.stream_tool != null);

    // The parked preview renders as live rows, below the (empty) text rows.
    t.working = true;
    const live = t.liveBlockLocked() catch return error.NoLive;
    try std.testing.expect(live.len > 0);
    var found_header = false;
    for (live) |row| {
        if (std.mem.indexOf(u8, row, "$ echo hi") != null) found_header = true;
    }
    try std.testing.expect(found_header);

    // A round with text: the text commits ABOVE where the card will appear.
    t.addMessage("Let me run that for you.");

    // The round finishes: .tool_start commits the real card and clears the
    // parked preview. The card lands BELOW the text — no flip.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "s1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"echo hi\"}"),
    });
    try std.testing.expect(t.stream_tool == null);
    try std.testing.expectEqual(@as(usize, 2), t.scrollback.items.len);
    try std.testing.expectEqualStrings("Let me run that for you.", t.scrollback.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[1], pending_bg) != null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[1], "$ echo hi") != null);

    // A parked preview that never gets announced (error/abort) is dropped
    // with the turn.
    t.updatePendingToolArgs(.{
        .id = try alloc.dupe(u8, "s2"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"echo again\""),
    });
    try std.testing.expect(t.stream_tool != null);
    t.dropStreamTool();
    try std.testing.expect(t.stream_tool == null);
    try std.testing.expectEqual(@as(usize, 2), t.scrollback.items.len);
}

// ---- Selection + click-to-toggle ----

test "selection: drag selects doc text, highlight reverses the range" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.width = 40;
    t.height = 24;
    t.addMessage("alpha selected middle omega");
    t.redraw(); // fills the doc cache and transcript_h
    try std.testing.expect(t.transcript_h > 0);

    // Drag from 's' of 'selected' to the 'd' of 'middle'.
    _ = t.handlePress(6, 0, 1);
    _ = t.handleDrag(21, 0);
    const text = t.selectionText().?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("selected middle", text);

    // The frame shows the reverse-video range (applySelectionToFrame runs
    // inside redrawLocked, so just check the helper directly).
    var frame: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame.items) |l| alloc.free(l);
        frame.deinit(alloc);
    }
    try frame.append(alloc, try alloc.dupe(u8, "alpha selected middle omega"));
    t.render_mutex.lock(t.io) catch {};
    t.applySelectionToFrame(&frame);
    t.render_mutex.unlock(t.io);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "\x1b[27m") != null);
    // The text outside the range is untouched.
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "alpha ") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "omega") != null);

    // A release on the press point is a click: it clears the selection.
    _ = t.handleDrag(6, 0);
    _ = t.handleRelease(6, 0);
    try std.testing.expect(t.selBounds() == null);
}

test "streaming: the document size does not depend on the viewport" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.width = 60;
    t.height = 24;
    // Enough scrollback that the document is taller than the viewport
    // (otherwise maxScrollTop stays 0 and following can never disengage).
    var bulk: std.ArrayListUnmanaged(u8) = .empty;
    defer bulk.deinit(alloc);
    for (0..40) |li| {
        var lb: [24]u8 = undefined;
        const ln = std.fmt.bufPrint(&lb, "history row {d}\n", .{li}) catch unreachable;
        bulk.appendSlice(alloc, ln) catch unreachable;
    }
    t.addMessage(bulk.items);
    t.stream_text.appendSlice("streaming answer line one\nline two\nline three") catch {};
    t.working = true;
    t.redraw(); // following the end
    const doc_following = t.doc_len;
    const top_following = t.sv.scroll_top;
    try std.testing.expect(doc_following > 0);

    // Scroll up mid-turn: the streaming tail stays IN the document (pi:
    // the streaming component is a fixed part of the layout) — the doc
    // must not shrink, and the viewport must stay anchored.
    _ = t.sv.scrollBy(-2, ss.nowMs(t.io));
    t.redraw();
    try std.testing.expect(!t.sv.isFollowingEnd());
    try std.testing.expectEqual(doc_following, t.doc_len);
    try std.testing.expectEqual(top_following - 2, t.sv.scroll_top);

    // A second render at the scrolled position: still stable.
    t.redraw();
    try std.testing.expectEqual(doc_following, t.doc_len);

    // Scrolling back to the end re-engages following without the document
    // jumping (no live-tail add/remove discontinuity).
    const moved = t.sv.scrollBy(100, ss.nowMs(t.io));
    try std.testing.expect(moved > 0);
    t.redraw();
    try std.testing.expect(t.sv.isFollowingEnd());
    try std.testing.expectEqual(doc_following, t.doc_len);
}

test "thinking: click collapses streaming and finished thinking blocks" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.width = 60;
    t.height = 24;

    // ---- Streaming thinking: click the live rows → "Thinking…" ----
    t.stream_thinking.appendSlice("deep thought one\ndeep thought two\ndeep thought three") catch {};
    t.working = true;
    t.redraw(); // live cache + doc layout
    try std.testing.expect(!t.thinking_collapsed);
    try std.testing.expect(t.live_cache_think_rows == 3);

    // The live thinking rows sit right after the scrollback doc rows.
    const think_row: usize = t.doc_lines.items.len - t.sv.scroll_top;
    _ = t.handlePress(5, think_row, 1);
    _ = t.handleRelease(5, think_row);
    try std.testing.expect(t.thinking_collapsed);
    t.render_mutex.lock(t.io) catch {};
    const live = try t.liveBlockLocked();
    t.render_mutex.unlock(t.io);
    try std.testing.expectEqual(@as(usize, 1), live.len);
    try std.testing.expect(std.mem.indexOf(u8, live[0], "Thinking…") != null);

    // Clicking the "Thinking…" line expands again.
    _ = t.handlePress(5, think_row, 1);
    _ = t.handleRelease(5, think_row);
    try std.testing.expect(!t.thinking_collapsed);
    t.render_mutex.lock(t.io) catch {};
    const live2 = try t.liveBlockLocked();
    t.render_mutex.unlock(t.io);
    try std.testing.expect(live2.len >= 3);

    // ---- Finished thinking block: click collapses to one line ----
    t.clearTranscript();
    t.thinking_collapsed = false;
    t.addThinkingBlock("finished thought alpha\nfinished thought beta");
    t.redraw();
    const blk = t.scrollback.items[0];
    try std.testing.expect(std.mem.indexOf(u8, blk, "finished thought alpha") != null);
    // The block's first content row is doc row 0 (viewport row 0).
    _ = t.handlePress(4, 0, 1);
    _ = t.handleRelease(4, 0);
    try std.testing.expectEqual(@as(usize, 1), t.thinking_shut.items.len);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "finished thought alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "Thinking…") != null);
    // Click again → back to the full markdown.
    _ = t.handlePress(4, 0, 1);
    _ = t.handleRelease(4, 0);
    try std.testing.expectEqual(@as(usize, 0), t.thinking_shut.items.len);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "finished thought alpha") != null);
}

test "selection: clicking a tool block toggles its expansion" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.width = 80;
    t.height = 24;
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(alloc);
    for (1..13) |i| {
        var buf: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "out line {d}\n", .{i}) catch unreachable;
        content.appendSlice(alloc, line) catch unreachable;
    }
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"seq 12\"}"),
    });
    t.finishTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .content = try content.toOwnedSlice(alloc),
        .is_error = false,
        .duration_ms = 5,
    });
    t.redraw(); // doc cache + transcript_h

    // The collapsed preview (last 5 lines) omits the middle lines.
    const idx = t.tool_calls.items[0].block_idx.?;
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[idx], "out line 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[idx], "out line 5") == null);

    // Click the block (press + release on the same cell) → expanded.
    const before = t.scrollback.items[idx];
    _ = t.handlePress(3, 1, 1);
    _ = t.handleRelease(3, 1);
    try std.testing.expect(t.tool_calls.items[0].expanded == true);
    try std.testing.expect(!std.mem.eql(u8, before, t.scrollback.items[idx]));
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[idx], "out line 5") != null);

    // Click again → back to the collapsed preview (the global default).
    _ = t.handlePress(3, 1, 1);
    _ = t.handleRelease(3, 1);
    try std.testing.expect(t.tool_calls.items[0].expanded == false);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[idx], "out line 5") == null);
}

// ---- Resize reflow ----

test "resize: rerenderAtWidth re-wraps blocks and full-width backgrounds" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Logic-only test: page allocator, leak tracking lives in leak_g2.
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    const user_bg = "\x1b[48;2;33;59;73m"; // userMessageBg
    const long_user = "please summarize this very long sentence so that it certainly wraps into several visual rows at the narrow terminal width";
    t.width = 40;
    t.addUserMessage(long_user);
    try std.testing.expectEqual(@as(usize, 1), t.scrollback.items.len);
    const narrow = t.scrollback.items[0];

    // Every row of the block is padded to the full 40-column width.
    var it = std.mem.splitScalar(u8, narrow, '\n');
    var narrow_rows: usize = 0;
    while (it.next()) |row| {
        if (row.len == 0) continue;
        narrow_rows += 1;
        try std.testing.expect(std.mem.indexOf(u8, row, user_bg) != null);
    }
    try std.testing.expect(narrow_rows >= 4); // wrapped at 40 columns

    // Widen: every block re-renders; rows now pad to 80 columns.
    t.width = 80;
    t.render_mutex.lock(t.io) catch {};
    t.rerenderAtWidth();
    t.render_mutex.unlock(t.io);
    const wide = t.scrollback.items[0];
    var wide_rows: usize = 0;
    it = std.mem.splitScalar(u8, wide, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        wide_rows += 1;
        try std.testing.expect(std.mem.indexOf(u8, row, user_bg) != null);
    }
    // Same message, wider terminal: strictly fewer rows.
    try std.testing.expect(wide_rows < narrow_rows);
    // The narrow block is gone (replaced, not leaked next to the new one).
    try std.testing.expect(!std.mem.eql(u8, narrow, wide));
}

// ---- Scrolling ----

test "scroll: the viewport saturates at both ends instead of wrapping" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);

    t.addMessage("one\ntwo\nthree\nfour\nfive");
    // A 20-row document in a 10-row viewport; the ScrollView is the single
    // source of truth for the window now.
    t.sv.updateLayout(20, 10);
    try std.testing.expect(t.sv.isFollowingEnd());

    // Scrolling up past the start clamps at 0 (the old fetchSub could wrap
    // the usize below zero and the render clamp then jumped the viewport to
    // the very top — endless scroll bug).
    t.scrollBy(-99);
    try std.testing.expectEqual(@as(usize, 0), t.sv.scroll_top);
    t.scrollBy(5);
    try std.testing.expectEqual(@as(usize, 5), t.sv.scroll_top);
    t.scrollBy(-3);
    try std.testing.expectEqual(@as(usize, 2), t.sv.scroll_top);
    t.scrollBy(-99);
    try std.testing.expectEqual(@as(usize, 0), t.sv.scroll_top);
    // Down past the end clamps at the bottom and re-arms following.
    t.scrollBy(99);
    try std.testing.expectEqual(@as(usize, 10), t.sv.scroll_top);
    try std.testing.expect(t.sv.isFollowingEnd());
}

test "scroll: scrolled-up viewport stays anchored when content grows" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);

    t.addMessage("head");
    // A 20-row document in a 10-row viewport; scroll up 4 rows from the end.
    t.sv.updateLayout(20, 10);
    t.scrollBy(-4);
    try std.testing.expect(!t.sv.isFollowingEnd());
    try std.testing.expectEqual(@as(usize, 6), t.sv.scroll_top);

    // New content arrives below: the top row stays put, so the window does
    // not move (pi: not following the end).
    t.addMessage("one\nline");
    t.sv.updateLayout(22, 10);
    try std.testing.expectEqual(@as(usize, 6), t.sv.scroll_top);
    try std.testing.expect(!t.sv.isFollowingEnd());

    // A pending tool box is new scrollback content as well.
    t.addPendingTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .name = try alloc.dupe(u8, "bash"),
        .arguments = try alloc.dupe(u8, "{\"command\":\"echo hi\"}"),
    });
    const pending_lines = tui.countLines(t.scrollback.items[t.scrollback.items.len - 1]);
    t.sv.updateLayout(22 + pending_lines, 10);
    try std.testing.expectEqual(@as(usize, 6), t.sv.scroll_top);

    // Its result repaints in place; growth anchors the same way.
    t.finishTool(.{
        .id = try alloc.dupe(u8, "c1"),
        .content = try alloc.dupe(u8, "hi\n"),
        .is_error = false,
        .duration_ms = 10,
    });
    const result_lines = tui.countLines(t.scrollback.items[t.scrollback.items.len - 1]);
    try std.testing.expect(result_lines > pending_lines);
    t.sv.updateLayout(22 + result_lines, 10);
    try std.testing.expectEqual(@as(usize, 6), t.sv.scroll_top);

    // Back to the end re-arms following.
    t.scrollToLatest();
    try std.testing.expect(t.sv.isFollowingEnd());
}

test "scroll: jump hint rect is hit only on the label" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);

    // Nothing shown: no hit anywhere.
    try std.testing.expect(!t.jumpHintHit(40, 3));

    t.setJumpHint(3, 31, 37); // centered 37-column label on screen row 3
    try std.testing.expect(t.jumpHintHit(31, 3)); // first label cell
    try std.testing.expect(t.jumpHintHit(49, 3)); // mid label
    try std.testing.expect(t.jumpHintHit(67, 3)); // last label cell
    try std.testing.expect(!t.jumpHintHit(30, 3)); // left of it
    try std.testing.expect(!t.jumpHintHit(68, 3)); // right of it
    try std.testing.expect(!t.jumpHintHit(40, 2)); // other row
    t.clearJumpHint();
    try std.testing.expect(!t.jumpHintHit(40, 3));
}

test "kitty: ctrl+c as letter codepoint (99) + ctrl mod" {
    // Ghostty with Kitty flags=7 reports Ctrl+C as `ESC [ 99 ; 5 u` (c=99, mod=5=ctrl).
    const k = keys.parseKey("\x1b[99;5u") orelse return error.NoKey;
    if (k != .char) return error.WrongType;
    const c = k.char;
    try std.testing.expect(c.c == 'c' and c.ctrl and !c.alt);
}

test "kitty: ctrl+c as control-char codepoint (3) + ctrl mod" {
    const k = keys.parseKey("\x1b[3;5u") orelse return error.NoKey;
    if (k != .char) return error.WrongType;
    const c = k.char;
    try std.testing.expect(c.c == 'c' and c.ctrl);
}

test "kitty: ctrl+shift+enter (mod 6) is still shift_enter" {
    const k = keys.parseKey("\x1b[13;6u") orelse return error.NoKey;
    try std.testing.expect(k == .shift_enter);
}

test "compaction.isOverflowError matches pi OVERFLOW_PATTERNS subset" {
    const c = @import("src/core/compaction.zig");
    // Anthropic / z.ai
    try std.testing.expect(c.isOverflowError("prompt is too long: 213462 tokens > 200000 maximum"));
    try std.testing.expect(c.isOverflowError("{\"code\":\"1261\",\"message\":\"Prompt too long\"}"));
    try std.testing.expect(c.isOverflowError("Prompt exceeds max length"));
    // OpenAI / LiteLLM / OpenRouter
    try std.testing.expect(c.isOverflowError("Your input exceeds the context window of this model"));
    try std.testing.expect(c.isOverflowError("This model's maximum context length is 131072 tokens. However, you requested 537812 tokens"));
    try std.testing.expect(c.isOverflowError("litellm.ContextWindowExceededError: Context Window exceeded"));
    try std.testing.expect(c.isOverflowError("Input length (265330) exceeds model's maximum context length (262144)."));
    // Google / xAI / Groq
    try std.testing.expect(c.isOverflowError("The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)"));
    try std.testing.expect(c.isOverflowError("This model's maximum prompt length is 131072 but the request contains 537812 tokens"));
    try std.testing.expect(c.isOverflowError("Please reduce the length of the messages or completion"));
    // error-type JSON forms
    try std.testing.expect(c.isOverflowError("{\"error\":{\"type\":\"context_length_exceeded\"}}"));
    try std.testing.expect(c.isOverflowError("{\"error\":{\"type\":\"request_too_large\"}}"));
    // non-overflow errors must not match
    try std.testing.expect(!c.isOverflowError("rate limit exceeded, retry later"));
    try std.testing.expect(!c.isOverflowError("connection refused"));
    try std.testing.expect(!c.isOverflowError(""));
}

test "config.splitThinkingSuffix parses provider/model:level" {
    const cfgmod = @import("src/core/config.zig");
    // valid suffix on provider/model form
    const r1 = cfgmod.splitThinkingSuffix("ovf/ovf-mini:high").?;
    try std.testing.expectEqualStrings("ovf/ovf-mini", r1.base);
    try std.testing.expect(r1.level == .high);
    // bare id form
    const r2 = cfgmod.splitThinkingSuffix("glm-5.3:xhigh").?;
    try std.testing.expectEqualStrings("glm-5.3", r2.base);
    try std.testing.expect(r2.level == .xhigh);
    // off is a valid level
    try std.testing.expect(cfgmod.splitThinkingSuffix("m:off") != null);
    // invalid suffix → null (strict: text kept whole)
    try std.testing.expect(cfgmod.splitThinkingSuffix("m:turbo") == null);
    // no colon → null
    try std.testing.expect(cfgmod.splitThinkingSuffix("m") == null);
    // empty suffix → null
    try std.testing.expect(cfgmod.splitThinkingSuffix("m:") == null);
}

// ---- Sessions: leafChain / branchAt / forkAt / thinking level entries ----

test "session: leafChain previews + branchAt/forkAt + thinking entries" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const sdir = try std.fmt.allocPrint(alloc, "{s}/sess", .{root});
    defer alloc.free(sdir);
    const cwd = try std.fmt.allocPrint(alloc, "{s}/proj", .{root});
    defer alloc.free(cwd);
    std.Io.Dir.cwd().createDirPath(io, sdir) catch {};
    std.Io.Dir.cwd().createDirPath(io, cwd) catch {};

    const st = try ss.Store.create(alloc, io, sdir, cwd, .{});
    defer st.deinit();
    var mu = cmsg.Message.init(alloc);
    defer mu.deinit();
    mu.role = .user;
    try mu.blocks.append(.{ .text = cmsg.Message.allocStr(alloc, "first question") });
    st.recordMessage(&mu);
    var ma = cmsg.Message.init(alloc);
    defer ma.deinit();
    ma.role = .assistant;
    try ma.blocks.append(.{ .text = cmsg.Message.allocStr(alloc, "an answer") });
    st.recordMessage(&ma);
    var mu2 = cmsg.Message.init(alloc);
    defer mu2.deinit();
    mu2.role = .user;
    try mu2.blocks.append(.{ .text = cmsg.Message.allocStr(alloc, "second question") });
    st.recordMessage(&mu2);

    // leafChain: 3 message entries, user flag + preview extraction.
    var chain: [8]ss.Store.ChainItem = undefined;
    const cnt = st.leafChain(&chain);
    try std.testing.expectEqual(@as(usize, 3), cnt);
    try std.testing.expect(chain[0].is_user_message);
    try std.testing.expect(!chain[1].is_user_message);
    try std.testing.expect(chain[2].is_user_message);
    try std.testing.expectEqualStrings("first question", chain[0].preview[0..chain[0].preview_len]);

    // recordThinkingLevel + latestThinkingLevel.
    st.recordThinkingLevel("high");
    const lv = st.latestThinkingLevel(alloc).?;
    defer alloc.free(lv);
    try std.testing.expectEqualStrings("high", lv);

    // forkAt the FIRST user message: new store has exactly that entry.
    var id0_buf: [16]u8 = undefined;
    @memcpy(id0_buf[0..chain[0].id_len], chain[0].id[0..chain[0].id_len]);
    const fk = try st.forkAt(id0_buf[0..chain[0].id_len], sdir, cwd);
    defer fk.deinit();
    var chain2: [8]ss.Store.ChainItem = undefined;
    const cnt2 = fk.leafChain(&chain2);
    try std.testing.expectEqual(@as(usize, 1), cnt2);
    try std.testing.expectEqualStrings("first question", chain2[0].preview[0..chain2[0].preview_len]);

    // branchAt: leaf moves to the cut point, summary recorded, recoverable.
    var id0_buf2: [16]u8 = undefined;
    @memcpy(id0_buf2[0..chain[0].id_len], chain[0].id[0..chain[0].id_len]);
    const from_copy = try alloc.dupe(u8, st.leaf_id.?);
    defer alloc.free(from_copy);
    st.branchAt(id0_buf2[0..chain[0].id_len], from_copy, "abandoned path summary");
    // The new leaf is the branch_summary entry itself (children continue
    // from the summary, pi semantics), NOT the cut point.
    // The chain now ends with the branch summary entry.
    var chain3: [8]ss.Store.ChainItem = undefined;
    const cnt3 = st.leafChain(&chain3);
    try std.testing.expectEqual(@as(usize, 2), cnt3);
    try std.testing.expect(chain3[1].kind == .branch_summary);
    try std.testing.expectEqualStrings("abandoned path summary", chain3[1].preview[0..chain3[1].preview_len]);
}

// ---- Editor mouse selection ----

test "editor selection: drag selects, selectionText extracts, insert replaces" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    e.setText("hello world\nsecond line") catch unreachable;

    // No selection → nothing.
    try std.testing.expect(e.selBounds() == null);
    try std.testing.expect(e.selectionText() == null);

    // Select "world" on line 0: logical (0,6) to (0,11).
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 0, .col = 11 };
    const b = e.selBounds().?;
    try std.testing.expectEqual(@as(usize, 0), b.start.line);
    try std.testing.expectEqual(@as(usize, 6), b.start.col);
    try std.testing.expectEqual(@as(usize, 11), b.end.col);
    const text = e.selectionText().?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("world", text);

    // Typing replaces the selection.
    e.insertBytes("z") catch unreachable;
    e.clearSelection();
    const full = try e.getText();
    defer alloc.free(full);
    try std.testing.expectEqualStrings("hello z\nsecond line", full);

    // Multi-line selection: "z\nsecond" (line 0 byte 6 → line 1 byte 6).
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 1, .col = 6 };
    const text2 = e.selectionText().?;
    defer alloc.free(text2);
    try std.testing.expectEqualStrings("z\nsecond", text2);

    // Backward drag: anchor after focus → bounds still ordered.
    e.sel_anchor = .{ .line = 1, .col = 6 };
    e.sel_focus = .{ .line = 0, .col = 6 };
    const bb = e.selBounds().?;
    try std.testing.expectEqual(@as(usize, 0), bb.start.line);
    try std.testing.expectEqual(@as(usize, 1), bb.end.line);

    // placeCursor maps a visual point (rendered at width) to the logical
    // cursor. No wrapping at width 80: visual row == logical line.
    e.clearSelection();
    e.placeCursor(1, 4, 80);
    try std.testing.expectEqual(@as(usize, 1), e.cursor_line);
    try std.testing.expectEqual(@as(usize, 4), e.cursor_col);
    e.placeCursor(5, 0, 80); // past the end → last line's end
    try std.testing.expectEqual(@as(usize, 1), e.cursor_line);
    try std.testing.expectEqual(@as(usize, 11), e.cursor_col);
}

test "editor selection: wrapping is visual-column aware" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    // 36-char line wraps at width 10:
    // "abcdefghij" / " klmnopqrs" / " tuvwx " / "yz012345"
    e.setText("abcdefghij klmnopqrs tuvwx yz012345") catch unreachable;
    // Visual row 1 " klmnopqrs" starts at byte 10.
    e.placeCursor(1, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), e.cursor_line);
    try std.testing.expectEqual(@as(usize, 10), e.cursor_col);
    // Visual col 5 on row 1 → byte 15.
    e.placeCursor(1, 5, 10);
    try std.testing.expectEqual(@as(usize, 15), e.cursor_col);
    // Select visual row 1 entirely: bytes 10..20.
    e.sel_anchor = e.visualToLogical(1, 0, 10);
    e.sel_focus = e.visualToLogical(1, 10, 10);
    const text = e.selectionText().?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings(" klmnopqrs", text);
}

test "editor selection: CJK visual columns map to byte offsets" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    // "ab中文": a=1 b=1 中=2 文=2 → visual cols 0,1,2,4,6
    e.setText("ab中文") catch unreachable;
    // Visual col 4 = start of 文 (byte 5).
    const p = e.visualToLogical(0, 4, 80);
    try std.testing.expectEqual(@as(usize, 5), p.col);
    // Select 中文: logical bytes 2..8.
    e.sel_anchor = .{ .line = 0, .col = 2 };
    e.sel_focus = .{ .line = 0, .col = 8 };
    const text = e.selectionText().?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("中文", text);
}

test "editor selection: highlightSelection inverts the selected range" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    e.setText("hello world") catch unreachable;
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 0, .col = 11 };
    var frame: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame.items) |l| alloc.free(l);
        frame.deinit(alloc);
    }
    const row = try alloc.dupe(u8, "hello world");
    try frame.append(alloc, row);
    e.highlightSelection(&frame, 0, 1, 0, 80, alloc);
    // The selected range is wrapped in reverse-video escapes.
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "\x1b[7mworld\x1b[27m") != null);
}

test "editor selection: highlight respects the visible window" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    e.setText("line one\nline two\nline three") catch unreachable;
    // Select all of logical line 1.
    e.sel_anchor = .{ .line = 1, .col = 0 };
    e.sel_focus = .{ .line = 1, .col = 8 };
    var frame: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (frame.items) |l| alloc.free(l);
        frame.deinit(alloc);
    }
    // Rendered window: only visual rows 1..2 visible (vis_top=1, count=2).
    const r1 = try alloc.dupe(u8, "line two");
    const r2 = try alloc.dupe(u8, "line three");
    try frame.append(alloc, r1);
    try frame.append(alloc, r2);
    e.highlightSelection(&frame, 0, 2, 1, 80, alloc);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[0], "\x1b[7mline two\x1b[27m") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.items[1], "\x1b[7m") == null);
}

test "editor selection: typing replaces, arrows keep, backspace deletes, escape clears" {
    const alloc = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    e.setText("hello world") catch unreachable;
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 0, .col = 11 };

    // Plain cursor moves keep the selection (no surprise reset mid-drag).
    _ = e.handleKey(.{ .left = {} }, io) catch unreachable;
    try std.testing.expect(e.selBounds() != null);
    _ = e.handleKey(.{ .right = {} }, io) catch unreachable;
    try std.testing.expect(e.selBounds() != null);

    // Typing replaces the selection (insertBytes path).
    _ = e.handleKey(.{ .char = .{ .c = 'X', .ctrl = false, .alt = false } }, io) catch unreachable;
    try std.testing.expect(e.selBounds() == null);
    const full = try e.getText();
    defer alloc.free(full);
    try std.testing.expectEqualStrings("hello X", full);

    // Select + backspace deletes the whole selection.
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 0, .col = 7 };
    _ = e.handleKey(.{ .backspace = {} }, io) catch unreachable;
    const full2 = try e.getText();
    defer alloc.free(full2);
    try std.testing.expectEqualStrings("hello ", full2);

    // ESC clears an existing selection.
    e.sel_anchor = .{ .line = 0, .col = 0 };
    e.sel_focus = .{ .line = 0, .col = 3 };
    _ = e.handleKey(.escape, io) catch unreachable;
    try std.testing.expect(e.selBounds() == null);
    try std.testing.expectEqualStrings("hello ", try e.getText());
}

test "editor selection: multi-line selection replace keeps the tail" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    e.setText("alpha one\nbeta two\ngamma three") catch unreachable;
    // Select from line 0 "one" through line 2 "three": replace with "X".
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 2, .col = 5 };
    e.insertBytes("X") catch unreachable;
    const full = try e.getText();
    defer alloc.free(full);
    try std.testing.expectEqualStrings("alpha X three", full);
    try std.testing.expectEqual(@as(usize, 0), e.cursor_line);
    try std.testing.expectEqual(@as(usize, 7), e.cursor_col);
}

test "editor pasteText: multi-line splits, CRLF trimmed, selection replaced" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();

    // Multi-line paste at the cursor.
    e.setText("ab") catch unreachable;
    e.placeCursor(0, 1, 80); // between 'a' and 'b'
    e.pasteText("x\r\ny\n") catch unreachable;
    const t1 = try e.getText();
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("ax\nyb", t1);
    try std.testing.expectEqual(@as(usize, 1), e.cursor_line);

    // Paste over a multi-line selection replaces it.
    e.setText("alpha one\nbeta two\ngamma three") catch unreachable;
    e.sel_anchor = .{ .line = 0, .col = 6 };
    e.sel_focus = .{ .line = 2, .col = 5 };
    e.pasteText("P1\nP2\nP3") catch unreachable;
    const t2 = try e.getText();
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("alpha P1\nP2\nP3 three", t2);
    try std.testing.expectEqual(@as(usize, 2), e.cursor_line);
    try std.testing.expectEqual(@as(usize, 2), e.cursor_col);
}

test "editor visualToLogical maps every visual row of wrapped lines" {
    const alloc = std.heap.page_allocator;
    var e = editor.Editor.init(alloc);
    defer e.deinit();
    // Width 10: three logical lines, "aaaa|bbbb" splits into 2 rows.
    e.setText("aaaaaaaaaabbbbbbbbbb\ncc") catch unreachable;
    const p0 = e.visualToLogical(0, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), p0.line);
    try std.testing.expectEqual(@as(usize, 0), p0.col);
    const p1 = e.visualToLogical(1, 2, 10);
    try std.testing.expectEqual(@as(usize, 0), p1.line);
    try std.testing.expectEqual(@as(usize, 12), p1.col);
    const p2 = e.visualToLogical(2, 1, 10);
    try std.testing.expectEqual(@as(usize, 1), p2.line);
    try std.testing.expectEqual(@as(usize, 1), p2.col);
    try std.testing.expectEqual(@as(usize, 3), e.visualLineCount(10));
}

// ---- Skill invocation block (pi SkillInvocationMessageComponent) ----

test "skill: /skill:name renders a single collapsed line, click expands the body" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    const body = "Use the xlsx skill.\n\n- step one\n- step two";
    t.addSkillInvocation("xlsx", "/tmp/skills/xlsx/SKILL.md", body, "");

    // One collapsed block: a single line with the name + expand hint, on the
    // custom message background — the body is NOT in the transcript.
    try std.testing.expectEqual(@as(usize, 1), t.scrollback.items.len);
    const collapsed = t.scrollback.items[0];
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "xlsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "ctrl+o") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "\n") == null); // single line
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "step one") == null);

    // Click toggle: the block expands in place (same slot, body visible).
    try std.testing.expectEqual(@as(usize, 1), t.skill_invocations.items.len);
    t.skill_invocations.items[0].expanded = true;
    t.renderSkillBlockAt(0);
    try std.testing.expectEqual(@as(usize, 1), t.scrollback.items.len);
    const expanded = t.scrollback.items[0];
    try std.testing.expect(std.mem.indexOf(u8, expanded, "[skill]") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "step one") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "step two") != null);

    // Toggle back collapses again.
    t.skill_invocations.items[0].expanded = false;
    t.renderSkillBlockAt(0);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "step one") == null);

    // Ctrl+O (setToolsExpanded) expands skill blocks too (pi setToolsExpanded
    // walks every expandable chat child), and the next toggle collapses them.
    t.setToolsExpanded(true);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "step one") != null);
    t.setToolsExpanded(false);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "step one") == null);
}

test "skill: trailing args render as a separate user message below the block" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    // pi _expandSkillCommand output: <skill> block + blank line + args.
    const expanded =
        "<skill name=\"xlsx\" location=\"/tmp/skills/xlsx/SKILL.md\">\n" ++
        "References are relative to /tmp/skills/xlsx.\n\n" ++
        "Body text here.\n" ++
        "</skill>\n\n" ++
        "make me a report";
    t.addSubmittedMessage(expanded);

    // Two blocks: the collapsed skill line, then the args as a user message.
    try std.testing.expectEqual(@as(usize, 2), t.scrollback.items.len);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "xlsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "Body text here.") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[1], "make me a report") != null);
}

test "frame: the painted frame always fills the full terminal height" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.width = 60;
    t.height = 24;
    t.addMessage("hello world");
    // A multi-line queued message while compacting: the layout budget must
    // count every wrapped row, and the frame must still fill the terminal.
    const qtext = "first line\nsecond line that is long enough to wrap around the width of the box";
    try t.compact_queue.append(.{ .text = try alloc.dupe(u8, qtext), .mode = .steer });
    t.compacting = true;
    t.redraw();

    // The diff base is exactly one row per screen row: a short frame would
    // leave the previous frame's last row (a stale footer line) stranded at
    // the bottom of the screen.
    try std.testing.expectEqual(t.height, t.prev_lines.items.len);

    // Direct diffRender check: a frame SHORTER than the terminal (a stale
    // height or a mis-counted layout budget) must still clear every row it
    // does not reach — a previous frame's bottom row (a stale footer line)
    // may never survive. With an empty previous frame the byte stream is
    // exactly n frame paints + (height - n) tail clears, so the tail clears
    // are counted precisely. The old shrink-clear ran only to
    // prev_lines.len (0 here) and left the bottom rows untouched.
    const n: usize = t.height - 2; // new frame: 22 of 24 rows
    for (t.prev_lines.items) |l| alloc.free(l);
    t.prev_lines.clearRetainingCapacity();
    var short: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (short.items) |l| alloc.free(l);
        short.deinit(alloc);
    }
    for (0..n) |_| try short.append(alloc, try alloc.dupe(u8, "x"));
    // Disable the scrollbar post-pass so the byte stream is exactly the
    // content diff (it repaints cells in the transcript region too).
    const saved_th = t.transcript_h;
    t.transcript_h = 0;
    if (t.last_frame_bytes.len > 0) alloc.free(t.last_frame_bytes);
    t.last_frame_bytes = &[_]u8{};
    t.render_mutex.lock(t.io) catch {};
    t.diffRender(&short, 0, 1, false);
    t.render_mutex.unlock(t.io);
    t.transcript_h = saved_th;
    try std.testing.expectEqual(n, t.prev_lines.items.len);
    // The two rows the frame does not reach must carry a clear-to-end-of-line
    // on top of the n frame paints — the tail clears.
    const lf = t.last_frame_bytes;
    try std.testing.expect(lf.len > 0);
    var clears: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, lf, i, ansi.CLEAR_EOL)) |p| {
        clears += 1;
        i = p + ansi.CLEAR_EOL.len;
    }
    try std.testing.expectEqual(n + (t.height - n), clears);
}

// ---- Regression: the 2026-11 "squeezed borders / missing bottom border /
// stranded stale row" corruption ----

/// Largest CUP row (`ESC[<row>;<col>H`) referenced by a frame's byte stream.
/// Painting past the terminal's last row clamps onto it and chained \r\n
/// from there scrolls the whole screen — the diff model desyncs permanently.
fn maxCupRow(bytes: []const u8) usize {
    var max_row: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, i, 0x1b)) |p| {
        i = p + 1;
        if (i >= bytes.len or bytes[i] != '[') continue;
        i += 1;
        var row: usize = 0;
        var saw_digit = false;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
            row = row * 10 + (bytes[i] - '0');
            saw_digit = true;
        }
        if (saw_digit and i < bytes.len and bytes[i] == ';') max_row = @max(max_row, row);
    }
    return max_row;
}

fn frameRowWidth(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7E)) i += 1;
                i = @min(i + 1, s.len);
            } else if (s[i] == ']') {
                i += 1;
                while (i < s.len) : (i += 1) {
                    if (s[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else i += 1;
            continue;
        }
        const end = width.nextCharEnd(s, i);
        total += width.visualWidth(s[i..end]);
        i = end;
    }
    return total;
}

test "frame: every row fits the width in every layout state (no terminal autowrap)" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    t.editor.setText("你好世界 hello\n\n这是一段比较长的中文输入用来测试自动换行在编辑器宽度边界附近的行为是否正确") catch unreachable;
    t.addMessage("# 中文标题\n\n---\n\n- 列表项一 带有很长的中文描述文字用来测试换行行为\n");
    try t.compact_queue.append(.{ .text = try alloc.dupe(u8, "压缩中的长消息\n第二行"), .mode = .steer });

    var w: u16 = 12;
    while (w <= 130) : (w += 1) {
        t.width = w;
        t.height = 24;

        t.redraw();
        for (t.prev_lines.items, 0..) |l, i| {
            const fw = frameRowWidth(l);
            if (fw > w) {
                std.debug.print("\nwidth {d} row {d}: {d} > {d}: {s}", .{ w, i, fw, w, l[0..@min(l.len, 120)] });
                return error.FrameRowTooWide;
            }
        }

        t.working = true;
        const q1 = try alloc.dupe(u8, "继续 修复一下 TUI 的 BUG");
        try session.steering_queue.append(alloc, q1);
        t.redraw();
        for (t.prev_lines.items) |l| {
            if (frameRowWidth(l) > w) return error.FrameRowTooWide;
        }
        session.steering_queue.clearRetainingCapacity();

        const q2 = try alloc.dupe(u8, "压缩中的长消息\n第二行");
        try t.compact_queue.append(.{ .text = q2, .mode = .steer });
        t.compacting = true;
        t.redraw();
        for (t.prev_lines.items) |l| {
            if (frameRowWidth(l) > w) return error.FrameRowTooWide;
        }
        t.compacting = false;
        t.compact_queue.clearRetainingCapacity();
        t.working = false;
    }
}

test "diffRender: an over-tall frame is clamped, never painted past the last screen row" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();
    t.width = 60;
    t.height = 10;
    t.redraw();

    // A frame taller than the terminal (the queued-row race made these):
    // the overflow rows must NOT be painted (a CUP onto the last row plus a
    // chained \r\n would scroll the screen) and NOT adopted into the base.
    var tall: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (tall.items) |l| alloc.free(l);
        tall.deinit(alloc);
    }
    for (0..t.height + 3) |i| {
        var buf: [16]u8 = undefined;
        const l = try std.fmt.bufPrint(&buf, "row{d}", .{i});
        try tall.append(alloc, try alloc.dupe(u8, l));
    }
    if (t.last_frame_bytes.len > 0) alloc.free(t.last_frame_bytes);
    t.last_frame_bytes = &[_]u8{};
    t.render_mutex.lock(t.io) catch {};
    t.diffRender(&tall, 0, 1, false);
    t.render_mutex.unlock(t.io);
    try std.testing.expect(t.prev_lines.items.len <= t.height);
    const over = maxCupRow(t.last_frame_bytes);
    try std.testing.expect(over <= t.height);

    // A normal frame afterwards repaints cleanly at legal rows.
    var normal: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (normal.items) |l| alloc.free(l);
        normal.deinit(alloc);
    }
    for (0..t.height) |i| {
        var buf: [16]u8 = undefined;
        const l = try std.fmt.bufPrint(&buf, "new{d}", .{i});
        try normal.append(alloc, try alloc.dupe(u8, l));
    }
    if (t.last_frame_bytes.len > 0) alloc.free(t.last_frame_bytes);
    t.last_frame_bytes = &[_]u8{};
    t.render_mutex.lock(t.io) catch {};
    t.diffRender(&normal, 0, 1, false);
    t.render_mutex.unlock(t.io);
    try std.testing.expectEqual(t.height, t.prev_lines.items.len);
    try std.testing.expect(maxCupRow(t.last_frame_bytes) <= t.height);
}

test "editor geometry: the live queue shifts the editor rows and the cursor park" {
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
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();
    t.width = 80;
    t.height = 24;
    t.working = true;
    t.editor.setText("typed text") catch unreachable;
    session.queueSteering("queued steering message");
    t.redraw();
    const qrows = t.session.queuedPeekRows(t.width);
    try std.testing.expect(qrows >= 1);
    // The editor's first row sits AFTER the live queue rows and the border.
    try std.testing.expectEqual(t.transcript_h + qrows + 1, t.editor_frame_row);
}

test "frame: selector chrome rows never exceed the width (desync regression)" {
    // The user-reported desync ("a line above the editor gets squeezed into
    // the content, a re-refresh heals it") comes from a frame row wider than
    // the terminal: the row autowraps, every chained row below shifts one
    // screen row, and the diff model never learns. Several chrome branches
    // formatted without a width cap (trust cwd, model-selector id/provider,
    // MCP item rows, settings/login/scoped hint lines, welcome-header
    // resource paths). The frame-level clamp in redrawLocked must keep every
    // row within the width in every view.
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "a-very-long-provider-name-that-alone-fills-rows"),
        .id = try alloc.dupe(u8, "an-extremely-long-model-identifier-qwen3.8-27b-instruct-thinking-max"),
        .name = try alloc.dupe(u8, "An Extremely Long Model Name For Clamping Tests"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();

    // Transcript content with CJK + emoji (width math stress), plus a tool
    // card and a queued steering row, so every layer is on screen at once.
    t.addMessage("# 压力测试标题\n\n```zig\nconst s = \"很长的中文字符串用来测试折行行为是否正确🚀🚀\";\n```\n");
    try t.compact_queue.append(.{ .text = try alloc.dupe(u8, "压缩队列里的一条很长的消息，包含中文与 emoji 🚀，用来撑满队列行的折行预算"), .mode = .steer });

    // Drive every selector UI (the previously uncapped generators).
    const commands = [_][]const u8{
        "/model",
        "/settings",
        "/scoped-models",
        "/login",
        "/mcp",
    };
    var w: u16 = 12;
    while (w <= 130) : (w += 1) {
        t.width = w;
        t.height = 20;

        // Baseline chrome + transcript + queues.
        t.redraw();
        try expectFrameFits(&t, w);

        for (commands) |cmd| {
            _ = t.handleCommand(cmd);
            t.redraw();
            try expectFrameFits(&t, w);
            // Escape closes the selector back to the plain chrome.
            _ = try t.editor.setText("");
            t.menu_mode = .hidden;
            t.menu_len = 0;
        }

        // Trust prompt (public entry; long cwd used to overflow l2).
        const long_cwd = try std.fmt.allocPrint(alloc, "/very/deeply/nested/path/structure/中文目录名/{d}/end", .{w});
        defer alloc.free(long_cwd);
        t.beginTrustPrompt(long_cwd, null, true);
        t.redraw();
        try expectFrameFits(&t, w);
        t.menu_mode = .hidden;
        t.freeTrustPrompt();
        t.menu_len = 0;

        // Welcome header (resource paths) at this width.
        t.refreshWelcomeHeader();
        t.redraw();
        try expectFrameFits(&t, w);
    }
}

fn expectFrameFits(t: *tui.TUI, w: u16) !void {
    for (t.prev_lines.items, 0..) |l, i| {
        const fw = frameRowWidth(l);
        if (fw > w) {
            std.debug.print("\nwidth {d} row {d}: {d} > {d}: {s}", .{ w, i, fw, w, l[0..@min(l.len, 120)] });
            return error.FrameRowTooWide;
        }
    }
    // The frame invariant: exactly one screen worth of rows.
    if (t.prev_lines.items.len > t.height) return error.FrameTooTall;
}
