//! Shared SSE request plumbing for all provider protocols (Phase 6).
//! One attempt = open connection, POST, pump `data:` lines into the
//! provider's parseSseData; retry/backoff lives in each adapter's
//! streamChat (same shape as openai.zig).

const std = @import("std");

pub const SseOutcome = enum { ok, transport_error, retryable_status, fatal_status };

pub fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 429 or (status >= 500 and status <= 599);
}

/// POST `body` to `url` and pump SSE `data:` lines to ctx.parseSseData(data,
/// session) — the same line-oriented streaming openai.zig uses (each line is
/// yielded the moment it lands; deltas flow at packet cadence).
pub fn postSse(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    url: []const u8,
    bearer_key: []const u8,
    extra_headers: []const std.http.Header,
    body: []const u8,
    err_buf: ?[]u8,
    ctx: anytype,
    session: anytype,
) SseOutcome {
    const uri = std.Uri.parse(url) catch return .transport_error;

    var auth_header: [512]u8 = undefined;
    var headers = std.array_list.Managed(std.http.Header).init(alloc);
    defer headers.deinit();
    if (bearer_key.len > 0) {
        const auth = std.fmt.bufPrint(&auth_header, "Bearer {s}", .{bearer_key}) catch return .transport_error;
        headers.append(.{ .name = "Authorization", .value = auth }) catch return .transport_error;
    }
    headers.appendSlice(extra_headers) catch return .transport_error;
    headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch return .transport_error;

    var request = client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers.items,
        .keep_alive = false,
    }) catch return .transport_error;
    defer request.deinit();

    request.sendBodyComplete(@constCast(body)) catch return .transport_error;
    var response = request.receiveHead(&[_]u8{}) catch return .transport_error;

    if (response.head.status != .ok) {
        var rbuf: [4096]u8 = undefined;
        var reader = response.reader(&rbuf);
        var ebuf: [4096]u8 = undefined;
        const elen: usize = reader.readSliceShort(&ebuf) catch 0;
        if (err_buf) |eb| {
            const n = @min(elen, eb.len);
            @memcpy(eb[0..n], ebuf[0..n]);
        }
        std.debug.print("error: HTTP {d}\n", .{@as(u16, @intFromEnum(response.head.status))});
        if (elen > 0) std.debug.print("{s}\n", .{ebuf[0..elen]});
        return if (isRetryableStatus(@intFromEnum(response.head.status))) .retryable_status else .fatal_status;
    }

    var rbuf: [16384]u8 = undefined;
    var reader = response.reader(&rbuf);
    while (true) {
        if (session.isAborted()) return .ok;
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => break,
            error.StreamTooLong => {
                reader.toss(reader.end - reader.seek);
                continue;
            },
        };
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \r\n");
        ctx.parseSseData(data, session) catch continue;
    }
    return .ok;
}
