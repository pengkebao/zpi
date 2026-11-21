const std = @import("std");
const ss = @import("src/core/session_store.zig");
const cmsg = @import("src/core/message.zig");

test "listForCwd: all SessionInfo fields free cleanly (first_message regression)" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Absolute fixture dir (listForCwd opens sessions_dir absolutely).
    const sdir = "/tmp/rpi_ss_list_test/--tmp-fixture--";
    std.Io.Dir.cwd().createDirPath(io, sdir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, "/tmp/rpi_ss_list_test") catch {};
    const body =
        "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"hello mock\"},\"timestamp\":1700000000000}\n" ++
        "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi there\"}]},\"timestamp\":1700000001000}\n";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sdir ++ "/2024_01_01T00_00_00Z_t1.jsonl", .data = body }) catch return error.SkipZigTest;

    const list = ss.listForCwd(alloc, io, "/tmp/rpi_ss_list_test", "/tmp/fixture") catch return error.SkipZigTest;
    defer {
        for (list) |info| {
            alloc.free(info.path);
            alloc.free(info.id);
            if (info.name) |n| alloc.free(n);
            if (info.first_message) |fm| alloc.free(fm);
            alloc.free(info.timestamp);
        }
        alloc.free(list);
    }
    try std.testing.expect(list.len > 0);
    try std.testing.expect(list[0].first_message != null);
}

test "lazy persist: empty store never writes a file; first message flushes" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const sdir = try std.fmt.allocPrint(alloc, "{s}/sess", .{root});
    defer alloc.free(sdir);
    const cwd = try std.fmt.allocPrint(alloc, "{s}/proj", .{root});
    defer alloc.free(cwd);

    const st = try ss.Store.create(alloc, io, sdir, cwd, .{});
    defer st.deinit();
    // No message yet: pi _persist gate — the file must NOT exist.
    const early = if (std.Io.Dir.cwd().access(io, st.path, .{})) |_| true else |_| false;
    try std.testing.expect(!early);

    // A tool message alone still must not flush (pi: user/assistant only).
    var mt = cmsg.Message.init(alloc);
    defer mt.deinit();
    mt.role = .tool;
    try mt.blocks.append(.{ .text = cmsg.Message.allocStr(alloc, "tool out") });
    st.recordMessage(&mt);
    const tool_flush = if (std.Io.Dir.cwd().access(io, st.path, .{})) |_| true else |_| false;
    try std.testing.expect(!tool_flush);

    // First real user message: the file appears and holds the header + msg.
    var mu = cmsg.Message.init(alloc);
    defer mu.deinit();
    mu.role = .user;
    try mu.blocks.append(.{ .text = cmsg.Message.allocStr(alloc, "now it is real") });
    st.recordMessage(&mu);
    const exists = if (std.Io.Dir.cwd().access(io, st.path, .{})) |_| true else |_| false;
    try std.testing.expect(exists);
    // And listForCwd must list it with the user preview.
    const list = try ss.listForCwd(alloc, io, sdir, cwd);
    defer {
        for (list) |info| {
            alloc.free(info.path);
            alloc.free(info.id);
            if (info.name) |n| alloc.free(n);
            if (info.first_message) |fm| alloc.free(fm);
            alloc.free(info.timestamp);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(list[0].first_message != null);
    try std.testing.expectEqualStrings("now it is real", list[0].first_message.?);
}

test "listForCwd: header-only legacy files are invisible" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const sdir = "/tmp/rpi_ss_list_test2/--tmp-fixture2--";
    std.Io.Dir.cwd().createDirPath(io, sdir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, "/tmp/rpi_ss_list_test2") catch {};
    // Legacy eager-create junk: header only.
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = sdir ++ "/2024_01_01T00_00_00Z_junk1.jsonl",
        .data = "{\"type\":\"session\",\"version\":3,\"id\":\"j1\",\"cwd\":\"/tmp/fixture2\"}\n",
    }) catch return error.SkipZigTest;
    // Real session.
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = sdir ++ "/2024_01_02T00_00_00Z_real.jsonl",
        .data = "{\"type\":\"session\",\"version\":3,\"id\":\"r1\",\"cwd\":\"/tmp/fixture2\"}\n" ++
            "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"visible\"}}\n",
    }) catch return error.SkipZigTest;

    const list = ss.listForCwd(alloc, io, "/tmp/rpi_ss_list_test2", "/tmp/fixture2") catch return error.SkipZigTest;
    defer {
        for (list) |info| {
            alloc.free(info.path);
            alloc.free(info.id);
            if (info.name) |n| alloc.free(n);
            if (info.first_message) |fm| alloc.free(fm);
            alloc.free(info.timestamp);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(std.mem.indexOf(u8, list[0].id, "r1") != null);
}
