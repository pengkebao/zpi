//! Shared JSON string writer for provider request bodies.
//!
//! Message content may carry arbitrary bytes (tool output can include
//! binary garbage from bash, file reads, ...), so multi-byte sequences
//! are validated before being copied: ill-formed UTF-8 becomes '?'. The
//! wire body must always be valid UTF-8 — providers reject the whole
//! request otherwise (HTTP 400/500 with a JSON parse error).
//!
//! Session files keep raw bytes (pi-compatible); only the wire body is
//! sanitized.

const std = @import("std");

/// Whether s[i..] begins a well-formed UTF-8 sequence (lead + correct
/// continuation bytes, no overlongs, no surrogates, <= U+10FFFF). Manual on
/// purpose: std.unicode.utf8Decode (0.17) does not handle 4-byte sequences.
fn isWellFormedUtf8At(s: []const u8, i: usize) bool {
    const c = s[i];
    const len = std.unicode.utf8ByteSequenceLength(c) catch return false;
    if (i + len > s.len) return false;
    var cp: u21 = switch (len) {
        2 => @as(u21, c & 0x1f),
        3 => @as(u21, c & 0x0f),
        else => @as(u21, c & 0x07),
    };
    for (s[i + 1 .. i + len]) |cont| {
        if (cont < 0x80 or cont > 0xbf) return false;
        cp = (cp << 6) | @as(u21, cont & 0x3f);
    }
    const min_cp: u21 = switch (len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min_cp or cp > 0x10FFFF) return false;
    if (cp >= 0xD800 and cp <= 0xDFFF) return false; // surrogates
    return true;
}

pub fn writeJsonStr(body: *std.array_list.Managed(u8), s: []const u8) !void {
    try body.append('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try body.appendSlice("\\\""),
            '\\' => try body.appendSlice("\\\\"),
            '\n' => try body.appendSlice("\\n"),
            '\r' => try body.appendSlice("\\r"),
            '\t' => try body.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const w = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try body.appendSlice(w);
                } else if (c < 0x80) {
                    try body.append(c);
                } else if (isWellFormedUtf8At(s, i)) {
                    // utf8ByteSequenceLength is total for lead bytes >= 0xC0;
                    // isWellFormedUtf8At validated the full sequence.
                    const len = std.unicode.utf8ByteSequenceLength(c) catch unreachable;
                    try body.appendSlice(s[i .. i + len]);
                    i += len - 1;
                } else {
                    // Truncated / ill-formed sequence: one '?'. A truncated
                    // lead consumes its (missing) tail in one go.
                    try body.append('?');
                    // Only a sequence truncated at the end consumes its
                    // (missing) tail; a mid-string bad sequence emits one
                    // '?' per offending byte.
                    const tl = std.unicode.utf8ByteSequenceLength(c) catch 0;
                    if (tl != 0 and i + tl > s.len) i = s.len - 1;
                }
            },
        }
    }
    try body.append('"');
}

test "writeJsonStr escapes basics" {
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    try writeJsonStr(&body, "a\"b\\c\nd\te\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u001b\"", body.items);
}

test "writeJsonStr keeps valid utf-8" {
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    try writeJsonStr(&body, "中文 émoji 🚀");
    try std.testing.expectEqualStrings("\"中文 émoji 🚀\"", body.items);
}

test "writeJsonStr replaces ill-formed utf-8" {
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    // 0xe2 without continuation bytes, a lone continuation 0x80, and a
    // truncated 3-byte sequence at the end.
    const raw = [_]u8{ 'a', 0xe2, 'b', 0x80, 'c', 0xe4, 0xb8 };
    try writeJsonStr(&body, &raw);
    try std.testing.expectEqualStrings("\"a?b?c?\"", body.items);
}
