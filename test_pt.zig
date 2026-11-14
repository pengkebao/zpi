const std = @import("std");
const pt = @import("src/core/prompt_template.zig");

test "stripFrontmatter" {
    try std.testing.expectEqualStrings("body", pt.stripFrontmatter("---\ndescription: x\n---\nbody"));
    try std.testing.expectEqualStrings("plain", pt.stripFrontmatter("plain"));
    try std.testing.expectEqualStrings("line1\nline2", pt.stripFrontmatter("---\nd: y\n---\n\nline1\nline2"));
}

test "parseCommandArgs bash quoting" {
    const a = std.testing.allocator;
    const args = pt.parseCommandArgs(a, "hello 'two words' \"quoted arg\" \"\" tail");
    defer pt.freeArgs(a, @constCast(args));
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("hello", args[0]);
    try std.testing.expectEqualStrings("two words", args[1]);
    try std.testing.expectEqualStrings("quoted arg", args[2]);
    try std.testing.expectEqualStrings("", args[3]);
    try std.testing.expectEqualStrings("tail", args[4]);
}

test "substituteArgs placeholders" {
    const a = std.testing.allocator;
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();
    const args = [_][]const u8{ "one", "two", "three" };
    try pt.substituteArgs(&out, a, "first=$1 all=$@ last-default=${5:-fallback} from2=${@:2} two-only=${@:2:1} args=$ARGUMENTS", &args);
    try std.testing.expectEqualStrings("first=one all=one two three last-default=fallback from2=two three two-only=two args=one two three", out.items);
    // missing positional → empty
    out.clearRetainingCapacity();
    try pt.substituteArgs(&out, a, "[$4]", &args);
    try std.testing.expectEqualStrings("[]", out.items);
    // missing positional expands empty (bash/pi convention); unknown $x kept
    out.clearRetainingCapacity();
    try pt.substituteArgs(&out, a, "cost $5 and $x", &args);
    try std.testing.expectEqualStrings("cost  and $x", out.items);
}

test "expand matches template by name" {
    const a = std.testing.allocator;
    const templates = [_]pt.Template{
        .{ .name = @constCast("review"), .content = @constCast("Review $1 carefully:\n$@"), .description = @constCast("") },
    };
    const out = try pt.expand(a, "/review src/main.zig extra", &templates);
    defer a.free(out);
    try std.testing.expectEqualStrings("Review src/main.zig carefully:\nsrc/main.zig extra", out);
    // unknown → unchanged
    const out2 = try pt.expand(a, "/unknown x", &templates);
    defer a.free(out2);
    try std.testing.expectEqualStrings("/unknown x", out2);
    // non-slash → unchanged
    const out3 = try pt.expand(a, "plain text", &templates);
    defer a.free(out3);
    try std.testing.expectEqualStrings("plain text", out3);
}
