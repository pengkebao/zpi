const std = @import("std");
const rpcmod = @import("src/core/rpc.zig");

test "escape: quotes, backslashes, control chars" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try rpcmod.Rpc.escape(&out, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u000Ad\\u0009e\"", out.items);
}

test "escape: unicode passthrough" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try rpcmod.Rpc.escape(&out, "中文 ok");
    try std.testing.expectEqualStrings("\"中文 ok\"", out.items);
}

test "cmdEnum: known vs unknown mapping" {
    const E = @TypeOf(rpcmod.Rpc.cmdEnum("x"));
    const unknown: E = rpcmod.Rpc.cmdEnum("nope");
    const bogus: E = rpcmod.Rpc.cmdEnum("totally-bogus");
    try std.testing.expect(unknown == bogus);
    const prompt: E = rpcmod.Rpc.cmdEnum("prompt");
    try std.testing.expect(prompt != unknown);
}
