const std = @import("std");
const tui = @import("src/ui/tui.zig");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const tools = @import("src/tools/registry.zig");
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
comptime {
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);

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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
    defer t.deinit();

    t.width = 40;
    t.height = 24;
    t.addMessage("alpha selected middle omega");
    t.redraw(); // fills the doc cache and transcript_h
    try std.testing.expect(t.transcript_h > 0);

    // Drag from 's' of 'selected' to the 'd' of 'middle'.
    _ = t.handlePress(6, 0);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
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
    _ = t.handlePress(5, think_row);
    _ = t.handleRelease(5, think_row);
    try std.testing.expect(t.thinking_collapsed);
    t.render_mutex.lock(t.io) catch {};
    const live = try t.liveBlockLocked();
    t.render_mutex.unlock(t.io);
    try std.testing.expectEqual(@as(usize, 1), live.len);
    try std.testing.expect(std.mem.indexOf(u8, live[0], "Thinking…") != null);

    // Clicking the "Thinking…" line expands again.
    _ = t.handlePress(5, think_row);
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
    _ = t.handlePress(4, 0);
    _ = t.handleRelease(4, 0);
    try std.testing.expectEqual(@as(usize, 1), t.thinking_shut.items.len);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "finished thought alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[0], "Thinking…") != null);
    // Click again → back to the full markdown.
    _ = t.handlePress(4, 0);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
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
    _ = t.handlePress(3, 1);
    _ = t.handleRelease(3, 1);
    try std.testing.expect(t.tool_calls.items[0].expanded == true);
    try std.testing.expect(!std.mem.eql(u8, before, t.scrollback.items[idx]));
    try std.testing.expect(std.mem.indexOf(u8, t.scrollback.items[idx], "out line 5") != null);

    // Click again → back to the collapsed preview (the global default).
    _ = t.handlePress(3, 1);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);

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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);

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
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);

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
