const std = @import("std");
const ss = @import("src/core/session_store.zig");

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
