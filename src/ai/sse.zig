//! Shared SSE request plumbing for all provider protocols (Phase 6).
//! One attempt = open connection, POST, pump `data:` lines into the
//! provider's parseSseData; retry/backoff lives in each adapter's
//! streamChat (same shape as openai.zig).

const std = @import("std");
const stream_guard = @import("stream_guard.zig");

pub const SseOutcome = enum { ok, transport_error, retryable_status, fatal_status };

pub fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 429 or (status >= 500 and status <= 599);
}

/// POST `body` to `url` and pump SSE `data:` lines to ctx.parseSseData(data,
/// session) — the same line-oriented streaming openai.zig uses (each line is
/// yielded the moment it lands; deltas flow at packet cadence). Non-2xx
/// responses are stored as "<status>: <body>" in err_buf (pi-ai
/// formatProviderError shape; empty bodies keep the bare status).
pub fn postSse(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    url: []const u8,
    bearer_key: []const u8,
    extra_headers: []const std.http.Header,
    body: []const u8,
    /// Receives the formatted error text ("<status>: <body>"); the length is
    /// written to err_len so the provider's lastErrorText() can expose it.
    err_buf: ?[]u8,
    err_len: ?*usize,
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

    // Start the watchdog BEFORE the connection opens, not after receiveHead:
    // sendBodyComplete (a large context upload) and receiveHead (waiting for
    // the response head) are plain blocking socket writes/reads too — a
    // gateway that accepts the body and never answers left the process
    // blocked BEFORE the guard existed (observed 2026-11-19 20:02: tool
    // result logged, then 59 min of silence, no error, no UI change). Both
    // phases also need ESC aborts, which only the guard can deliver while
    // the main thread sits inside a blocking read. One guard now covers
    // connect → send → receiveHead → SSE body; stop() runs at scope end.
    const Guard = stream_guard.Guard(@TypeOf(session));
    var guard: Guard = .{};
    guard.start(session, 0, client.io, stream_guard.idle_timeout_ms, stream_guard.data_timeout_ms);
    defer guard.stop();

    var request = client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers.items,
        .keep_alive = false,
    }) catch return .transport_error;
    // keep_alive=false promises a fresh connection per request — enforce it
    // from the moment the request exists. std only sets closing=true inside
    // receiveHead on success; a failure before head (watchdog shutdown during
    // connect/send/head, gateway reset) leaves closing=false and deinit
    // releases the SHUTDOWN socket back into the client's connection pool,
    // where every later request finds it and fails instantly (observed: one
    // 5-min idle timeout, then HttpError on every turn until restart).
    if (request.connection) |conn| conn.closing = true;
    defer request.deinit();

    // The guard may now shut the socket down on abort/timeout; a tripped
    // shutdown surfaces here as a transport error (retry loop takes over).
    if (request.connection) |conn| guard.fd = conn.stream_reader.stream.socket.handle;

    request.sendBodyComplete(@constCast(body)) catch return .transport_error;
    var response = request.receiveHead(&[_]u8{}) catch return .transport_error;

    if (response.head.status != .ok) {
        var rbuf: [4096]u8 = undefined;
        var reader = response.reader(&rbuf);
        var ebuf: [4096]u8 = undefined;
        const elen: usize = reader.readSliceShort(&ebuf) catch 0;
        const status = @as(u16, @intFromEnum(response.head.status));
        if (err_buf) |eb| {
            const head = if (elen > 0) std.fmt.bufPrint(eb, "{d}: ", .{status}) catch "" else
                std.fmt.bufPrint(eb, "HTTP {d}", .{status}) catch "";
            const n = @min(elen, eb.len - head.len);
            @memcpy(eb[head.len..head.len + n], ebuf[0..n]);
            if (err_len) |len| len.* = head.len + n;
        }
        std.debug.print("error: HTTP {d}\n", .{status});
        if (elen > 0) std.debug.print("{s}\n", .{ebuf[0..elen]});
        return if (isRetryableStatus(status)) .retryable_status else .fatal_status;
    }

    var rbuf: [16384]u8 = undefined;
    var reader = response.reader(&rbuf);
    // Watchdog already running from before the request was sent (covers
    // connect + send + receiveHead + body). fd is refreshed per connection.
    const guard_active = guard.thread != null;
    if (guard_active) {
        if (request.connection) |conn| guard.fd = conn.stream_reader.stream.socket.handle;
    }
    // A clean end is [DONE] / a terminal SSE event; a connection that just
    // drops (EndOfStream/ReadFailed without either) is a TRANSPORT error —
    // returning .ok here made truncated responses look like success and the
    // agent turn silently died mid-task.
    var done_cleanly = false;
    while (!done_cleanly) {
        if (session.isAborted()) break;
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => break,
            error.StreamTooLong => {
                reader.toss(reader.end - reader.seek);
                continue;
            },
        };
        if (guard_active) guard.noteAny(); // bytes arrived: reset byte-idle window
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \r\n");
        if (std.mem.eql(u8, data, "[DONE]")) {
            done_cleanly = true;
            break;
        }
        // Real payload line: reset the DATA-line window (blank lines and SSE
        // comments never reach here — a keep-alive-only stall cannot hide).
        if (guard_active) guard.noteData();
        ctx.parseSseData(data, session) catch continue;
    }
    // (guard.stop() runs via defer — one owner, no double-join)
    if (session.isAborted()) return .ok;
    if (!done_cleanly) {
        // Protocols without [DONE] (anthropic/google/responses) signal the
        // clean end via a terminal event the parser records on the provider.
        const CT = @typeInfo(@TypeOf(ctx)).pointer.child;
        if (@hasDecl(CT, "stream_done") and ctx.stream_done) return .ok;
        // Content streamed then the socket died (retryable continues a
        // partial answer — the provider layer declines when output already
        // streamed) vs nothing at all arrived.
        std.debug.print("error: SSE stream ended without a completion marker\n", .{});
        return .transport_error;
    }
    return .ok;
}
