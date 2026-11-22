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
/// A 429/5xx body describing an exhausted QUOTA or BILLING limit
/// (weekly/monthly caps, insufficient credits) rather than a transient
/// rate blip: retrying cannot help until the window resets, so both the
/// provider and the agent retry loops must stop immediately. CN and EN
/// keywords; ASCII is lowercased before matching.
pub fn isQuotaExhausted(detail: []const u8) bool {
    const lower = blk: {
        var b: [1024]u8 = undefined;
        var w: usize = 0;
        for (detail) |c| {
            if (w >= b.len) break;
            b[w] = switch (c) {
                'A'...'Z' => 'a' + (c - 'A'),
                else => c,
            };
            w += 1;
        }
        break :blk b[0..w];
    };
    const needles = [_][]const u8{
        "quota", "usage limit", "insufficient",
        "weekly", "monthly",
        "\xe4\xb8\x8a\xe9\x99\x90", // 上限
        "\xe9\x99\x90\xe9\x87\x8f", // 限额
        "\xe9\x85\x8d\xe9\x80\x9d", // 配额
        "\xe6\xaf\x8f\xe5\x91\xa8", // 每周
        "\xe6\xaf\x8f\xe6\x9c\x88", // 每月
        "\xe4\xbd\x99\xe9\x83\xbd", // 余额
        "\xe5\x85\x85\xe5\x80\xbc", // 充值
    };
    for (needles) |n| {
        if (std.mem.indexOf(u8, lower, n) != null) return true;
    }
    return false;
}

/// Collapse a stored error detail into a single truncated line for the
/// retry notice: trim, newlines → spaces, cap at `max` chars. Server
/// bodies can be multi-KB JSON with newlines; the notice is one line.
pub fn formatDetail(detail: []const u8, buf: []u8, max: usize) []const u8 {
    var out: []u8 = buf;
    var w: usize = 0;
    for (std.mem.trim(u8, detail, " \t\r\n")) |c| {
        if (w >= max) break;
        if (c == '\n' or c == '\r') {
            if (w > 0 and out[w - 1] != ' ') {
                out[w] = ' ';
                w += 1;
            }
        } else {
            out[w] = c;
            w += 1;
        }
    }
    return out[0..w];
}

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
    // Every failure path records a human-readable reason so the retry
    // notice can show WHAT happened, not just that the stream died. HTTP
    // status failures fill the richer "<status>: <body>" form below;
    // transport failures get the error name.
    const store = struct {
        fn put(eb: ?[]u8, len: ?*usize, comptime fmt: []const u8, args: anytype) void {
            const buf = eb orelse return;
            const s = std.fmt.bufPrint(buf, fmt, args) catch return;
            if (len) |l| l.* = s.len;
        }
    };
    const uri = std.Uri.parse(url) catch {
        store.put(err_buf, err_len, "bad url: {s}", .{@errorName(error.UriParse)});
        return .transport_error;
    };

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

    request.sendBodyComplete(@constCast(body)) catch |err| {
        store.put(err_buf, err_len, "send failed: {s}", .{@errorName(err)});
        return .transport_error;
    };
    var response = request.receiveHead(&[_]u8{}) catch |err| {
        store.put(err_buf, err_len, "no response: {s}", .{@errorName(err)});
        return .transport_error;
    };

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
    var read_err_name: ?[]const u8 = null;
    while (!done_cleanly) {
        if (session.isAborted()) break;
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => {
                read_err_name = @errorName(err);
                break;
            },
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
        if (read_err_name) |name| store.put(err_buf, err_len, "stream ended without a completion marker: {s}", .{name})
        else store.put(err_buf, err_len, "stream ended without a completion marker (connection dropped or watchdog timeout)", .{});
        return .transport_error;
    }
    return .ok;
}

test "isQuotaExhausted: quota/billing bodies yes, transient 429/5xx no" {
    // The real-world trigger: CN weekly/monthly cap with a reset time.
    try std.testing.expect(isQuotaExhausted(
        "429: {\"error\":{\"code\":\"1310\",\"message\":\"您已达到每周/每月使用上限，您的限额将在 2026-11-23 16:39:42 重置。\"}}",
    ));
    // EN variants.
    try std.testing.expect(isQuotaExhausted("429: {\"error\":{\"message\":\"You have exceeded your monthly quota\"}}"));
    try std.testing.expect(isQuotaExhausted("insufficient credits, please top up"));
    try std.testing.expect(isQuotaExhausted("429: 配额已用完，请充值"));
    // Transient rate blips / server hiccups are NOT quota exhaustion.
    try std.testing.expect(!isQuotaExhausted("429: {\"error\":{\"message\":\"Rate limit exceeded, retry after 5s\"}}"));
    try std.testing.expect(!isQuotaExhausted("502: Bad Gateway"));
    try std.testing.expect(!isQuotaExhausted("no response: ReadFailed"));
    try std.testing.expect(!isQuotaExhausted(""));
    // ASCII case-insensitive.
    try std.testing.expect(isQuotaExhausted("QUOTA EXHAUSTED FOR THIS SUBSCRIPTION PERIOD"));
}

test "formatDetail: trims, flattens newlines, caps length" {
    var buf: [512]u8 = undefined;
    // Multi-line JSON body → one line, no newlines (\n becomes one space,
    // the body's own indentation spaces are preserved).
    try std.testing.expectEqualStrings(
        "429: {\"type\":\"error\",   \"error\":{\"message\":\"rate limited\"}}",
        formatDetail("429: {\"type\":\"error\",\n  \"error\":{\"message\":\"rate limited\"}}\n", &buf, 300),
    );
    // Truncated at the cap.
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    const capped = formatDetail(long[0..], &buf, 300);
    try std.testing.expectEqual(@as(usize, 300), capped.len);
    // Empty / whitespace-only → empty.
    try std.testing.expectEqual(@as(usize, 0), formatDetail("", &buf, 300).len);
    try std.testing.expectEqual(@as(usize, 0), formatDetail("  \n \t ", &buf, 300).len);
    // Consecutive newlines collapse to a single space.
    try std.testing.expectEqualStrings("a b", formatDetail("a\n\n\nb", &buf, 300));
}
