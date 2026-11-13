//! Output truncation utilities (Phase E2/E3), aligned with pi's truncate.js.
//!
//! Two independent limits — whichever is hit first wins:
//!   - line limit (default 2000)
//!   - byte limit (default 50KB)
//!
//! `truncateTail` keeps the END (bash output: errors, final results).
//! `truncateHead` keeps the START (file reads: you want the beginning).

const std = @import("std");

pub const DEFAULT_MAX_LINES = 2000;
pub const DEFAULT_MAX_BYTES = 50 * 1024; // 50KB
pub const GREP_MAX_LINE_LENGTH = 500;

pub const TruncatedBy = enum { lines, bytes };

pub const TruncationResult = struct {
    /// Truncated content (owned by caller).
    content: []u8,
    truncated: bool,
    truncated_by: ?TruncatedBy = null,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool = false,
};

/// Write a human-readable byte size into `buf`; returns the number of bytes written.
pub fn formatSize(buf: []u8, bytes: usize) usize {
    if (bytes < 1024) {
        return (std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch return 0).len;
    } else if (bytes < 1024 * 1024) {
        return (std.fmt.bufPrint(buf, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024}) catch return 0).len;
    } else {
        return (std.fmt.bufPrint(buf, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch return 0).len;
    }
}

/// Split `content` into lines (by \n), dropping a single trailing empty element.
fn splitLines(alloc: std.mem.Allocator, content: []const u8) !std.array_list.Managed([]const u8) {
    var lines = std.array_list.Managed([]const u8).init(alloc);
    errdefer lines.deinit();
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        try lines.append(line);
    }
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines;
}

/// Keep the LAST maxLines/maxBytes of content (bash output).
pub fn truncateTail(alloc: std.mem.Allocator, content: []const u8) !TruncationResult {
    return truncateTailWith(alloc, content, DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES);
}

pub fn truncateTailWith(alloc: std.mem.Allocator, content: []const u8, max_lines: usize, max_bytes: usize) !TruncationResult {
    const total_bytes = content.len;
    var lines = try splitLines(alloc, content);
    defer lines.deinit();
    const total_lines = lines.items.len;

    if (total_lines <= max_lines and total_bytes <= max_bytes) {
        const out = try alloc.dupe(u8, content);
        return .{
            .content = out,
            .truncated = false,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
        };
    }

    // Count how many lines to keep from the end, and whether the first kept line
    // is partial (its tail only). Build directly from the original lines (no dupes).
    var count: usize = 0;
    var bytes: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    var partial = false;
    var partial_take: usize = 0;

    var i: usize = total_lines;
    while (i > 0 and count < max_lines) {
        i -= 1;
        const line = lines.items[i];
        const sep = if (count > 0) @as(usize, 1) else 0;
        if (bytes + line.len + sep > max_bytes) {
            if (count == 0) {
                // No lines kept yet; the last line alone exceeds max_bytes: keep its tail.
                partial = true;
                partial_take = @min(line.len, max_bytes);
                bytes = partial_take;
                count = 1;
            }
            truncated_by = .bytes;
            break;
        }
        bytes += line.len + sep;
        count += 1;
    }
    if (count >= max_lines and bytes <= max_bytes) truncated_by = .lines;

    const start = total_lines - count;
    var joined = std.array_list.Managed(u8).init(alloc);
    defer joined.deinit();
    var first = true;
    for (lines.items[start..total_lines], 0..) |line, offset| {
        var slice = line;
        if (offset == 0 and partial) slice = line[line.len - partial_take ..];
        if (!first) try joined.append('\n');
        first = false;
        try joined.appendSlice(slice);
    }
    const out = try alloc.dupe(u8, joined.items);

    return .{
        .content = out,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = count,
        .output_bytes = out.len,
        .last_line_partial = partial,
    };
}

/// Keep the FIRST maxLines/maxBytes of content (file reads).
pub fn truncateHead(alloc: std.mem.Allocator, content: []const u8) !TruncationResult {
    return truncateHeadWith(alloc, content, DEFAULT_MAX_LINES, DEFAULT_MAX_BYTES);
}

pub fn truncateHeadWith(alloc: std.mem.Allocator, content: []const u8, max_lines: usize, max_bytes: usize) !TruncationResult {
    const total_bytes = content.len;
    var lines = try splitLines(alloc, content);
    defer lines.deinit();
    const total_lines = lines.items.len;

    if (total_lines <= max_lines and total_bytes <= max_bytes) {
        const out = try alloc.dupe(u8, content);
        return .{
            .content = out,
            .truncated = false,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = total_bytes,
        };
    }

    // Count how many lines to keep from the start. Build directly from the original.
    var count: usize = 0;
    var bytes: usize = 0;
    var truncated_by: TruncatedBy = .lines;

    for (lines.items, 0..) |line, idx| {
        if (idx >= max_lines) {
            truncated_by = .lines;
            break;
        }
        const sep = if (count > 0) @as(usize, 1) else 0;
        if (bytes + line.len + sep > max_bytes) {
            truncated_by = .bytes;
            break;
        }
        bytes += line.len + sep;
        count += 1;
    }

    var joined = std.array_list.Managed(u8).init(alloc);
    defer joined.deinit();
    var first = true;
    for (lines.items[0..count]) |line| {
        if (!first) try joined.append('\n');
        first = false;
        try joined.appendSlice(line);
    }
    const out = try alloc.dupe(u8, joined.items);

    return .{
        .content = out,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = count,
        .output_bytes = out.len,
    };
}

test "truncateTail small" {
    const alloc = std.testing.allocator;
    const res = try truncateTail(alloc, "a\nb\nc");
    defer alloc.free(res.content);
    try std.testing.expect(!res.truncated);
    try std.testing.expectEqualStrings("a\nb\nc", res.content);
    try std.testing.expectEqual(@as(usize, 3), res.total_lines);
}

test "truncateTail lines" {
    const alloc = std.testing.allocator;
    // 5 lines, keep last 2
    const res = try truncateTailWith(alloc, "l1\nl2\nl3\nl4\nl5", 2, 1000);
    defer alloc.free(res.content);
    try std.testing.expect(res.truncated);
    try std.testing.expectEqualStrings("l4\nl5", res.content);
    try std.testing.expectEqual(@as(usize, 5), res.total_lines);
    try std.testing.expectEqual(@as(usize, 2), res.output_lines);
}

test "truncateTail bytes" {
    const alloc = std.testing.allocator;
    // Each line is 10 bytes + newline. Keep last 25 bytes worth.
    var content = std.array_list.Managed(u8).init(alloc);
    defer content.deinit();
    for (0..100) |_| {
        try content.appendSlice("123456789\n");
    }
    const res = try truncateTailWith(alloc, content.items, 1000, 25);
    defer alloc.free(res.content);
    try std.testing.expect(res.truncated);
    try std.testing.expectEqual(@as(usize, 100), res.total_lines);
    try std.testing.expect(res.output_bytes <= 25);
}
