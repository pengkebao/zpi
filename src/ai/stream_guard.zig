//! Stream watchdog: makes a blocking SSE read interruptible.
//!
//! pi sets an HTTP idle timeout on its fetch dispatcher (core/http-dispatcher.js:
//! bodyTimeout/headersTimeout = httpIdleTimeoutMs, default 300_000): if no bytes
//! arrive for that long, the stream fails and the provider layer retries. zpi's
//! SSE read is a plain blocking `read(2)` on the main thread — with no timeout it
//! blocks forever when a gateway stalls the stream (connected, then silence), and
//! the abort flag is only checked between lines, so ESC cannot interrupt it either.
//!
//! To unblock a blocking read on POSIX the fd must be shut down from ANOTHER
//! thread, so this spawns a watchdog that polls the abort check and the
//! last-data timestamp and calls shutdown(fd, RDWR) when either threshold trips.
//! The blocked read then returns an error (or EOF), the stream loop ends, and the
//! normal retry/abort machinery takes over.
//!
//! `Guard(Sess)` is generic over the session POINTER type (`@TypeOf(session)` at
//! the call site) because Zig 0.17 closures cannot capture `anytype` values; the
//! session pointer is passed as opaque context and cast back here.

const std = @import("std");

/// SSE idle timeout in ms (pi httpIdleTimeoutMs, default 300_000): no bytes for
/// this long → the stream fails and the provider retry loop retries. 0 disables.
/// main.zig reads $ZPI_HTTP_IDLE_TIMEOUT_MS into this (pi: the setting is
/// user-configurable; we keep it env-driven for now).
pub var idle_timeout_ms: i64 = 300_000;

/// DATA-line timeout in ms: no `data:` SSE line for this long → the stream
/// fails and the provider retry loop retries. 0 disables.
///
/// Why this exists alongside idle_timeout_ms: a proxy that stalls UPSTREAM
/// (model stopped generating) often keeps the TCP connection alive with
/// keep-alive bytes (blank lines / SSE comments). pi's undici bodyTimeout —
/// and this guard's any-byte idle window — reset on EVERY byte, so such a
/// stall is invisible to byte-level timeouts and the reader hangs forever
/// (observed: an intranet proxy heartbeating ~1/s while the model output was
/// dead; pi sat stuck for 4.5h with no error and no UI state change).
/// Data-line tracking only resets on real `data:` payload lines, so a
/// heartbeat-only stream trips this timeout and the retry loop takes over.
pub var data_timeout_ms: i64 = 300_000;

/// Build the guard type bound to the concrete session pointer type.
pub fn Guard(Sess: type) type {
    return struct {
        const Self = @This();
        ctx: Sess = undefined,
        fd: std.posix.fd_t = 0,
        io: std.Io = undefined,
        idle_ms: i64 = 0,
        data_ms: i64 = 0,
        /// Last time ANY bytes arrived (epoch ms); the stream loop refreshes
        /// it on every read (keep-alive heartbeats count).
        last_any_ms: std.atomic.Value(i64) = .init(0),
        /// Last time a real `data:` line arrived (epoch ms); heartbeats do
        /// NOT refresh this — that is the point of the two-tier window.
        last_data_ms: std.atomic.Value(i64) = .init(0),
        done: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,

        /// Start the watchdog. `session` is the concrete session pointer; `fd`
        /// must stay open until `stop` is called.
        pub fn start(self: *Self, session: Sess, fd: std.posix.fd_t, io: std.Io, idle_ms: i64, data_ms: i64) void {
            self.* = .{ .ctx = session, .fd = fd, .io = io, .idle_ms = idle_ms, .data_ms = data_ms };
            self.done.store(false, .release);
            self.thread = std.Thread.spawn(.{}, guardMain, .{self, session}) catch return;
        }

        /// Join the watchdog. The fd must still be open (the caller owns the
        /// request/connection until after this call).
        pub fn stop(self: *Self) void {
            self.done.store(true, .release);
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }

        /// Call on the stream thread whenever ANY bytes arrive (every read):
        /// resets the any-byte idle window. Cheap (one atomic store).
        pub fn noteAny(self: *Self) void {
            self.last_any_ms.store(nowMs(self.io), .release);
        }

        /// Call on the stream thread when a real `data:` payload line is
        /// parsed: resets the data-line window. SSE comments / blank lines /
        /// keep-alive bytes must NOT call this.
        pub fn noteData(self: *Self) void {
            self.last_data_ms.store(nowMs(self.io), .release);
        }

        fn guardMain(self: *Self, s: Sess) void {
            const POLL_MS: i64 = 250;
            const t0 = nowMs(self.io);
            self.last_any_ms.store(t0, .release);
            self.last_data_ms.store(t0, .release);
            while (!self.done.load(.acquire)) {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(POLL_MS), .real) catch return;
                if (s.*.isAborted()) {
                    // ESC while the main thread is inside read(): unblock it.
                    // The stream loop then sees isAborted() and returns.
                    shutdownFd(self.fd);
                    return;
                }
                const now = nowMs(self.io);
                switch (checkTimers(now, self.idle_ms, self.data_ms, self.last_any_ms.load(.acquire), self.last_data_ms.load(.acquire))) {
                    .none => {},
                    .stalled => {
                        std.debug.print("error: SSE stream stalled for {d}s (no data lines; keep-alive bytes do not count) — aborting stream\n", .{@divTrunc(self.data_ms, 1000)});
                        shutdownFd(self.fd);
                        return;
                    },
                    .idle => {
                        std.debug.print("error: SSE stream idle for {d}s (no bytes) — aborting stream\n", .{@divTrunc(self.idle_ms, 1000)});
                        shutdownFd(self.fd);
                        return;
                    },
                }
            }
        }

        fn nowMs(io: std.Io) i64 {
            const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            return @intCast(std.math.divTrunc(i96, ns, 1_000_000) catch 0);
        }

        fn shutdownFd(fd: std.posix.fd_t) void {
            // fd 0 = "no socket yet" (the guard starts before the connection
            // opens, the fd is patched in later): shutdown(0) would hit
            // stdin — never do that.
            if (fd == 0) return;
            _ = std.c.shutdown(fd, @intCast(std.posix.SHUT.RDWR));
        }
    };
}

/// Which timeout (if any) has tripped, given the current time and the two
/// last-activity timestamps. Pure — the watchdog thread polls this each tick.
pub const TimerVerdict = enum { none, stalled, idle };

pub fn checkTimers(
    now_ms: i64,
    idle_ms: i64,
    data_ms: i64,
    last_any_ms: i64,
    last_data_ms: i64,
) TimerVerdict {
    // Tier 1: no real `data:` lines for data_ms. This is the one a keep-alive
    // proxy cannot hide: heartbeats refresh last_any_ms but NOT last_data_ms,
    // so a stalled upstream (bytes flowing, no payload) still trips here.
    if (data_ms > 0 and now_ms - last_data_ms >= data_ms) return .stalled;
    // Tier 2: no bytes at all for idle_ms (pi bodyTimeout parity).
    if (idle_ms > 0 and now_ms - last_any_ms >= idle_ms) return .idle;
    return .none;
}

test "checkTimers: fresh stream trips nothing" {
    try std.testing.expectEqual(
        @as(TimerVerdict, .none),
        checkTimers(1000, 300_000, 300_000, 900, 900),
    );
}

test "checkTimers: heartbeat-only stall trips the DATA tier" {
    // The reported failure mode: a proxy heartbeats ~1/s (blank lines / SSE
    // comments) while the upstream model is dead. noteAny keeps last_any_ms
    // current, so the byte-idle tier never fires — but last_data_ms is frozen
    // and the data tier must trip regardless of the heartbeats.
    const now: i64 = 300_000; // 5 min in
    // last_any_ms = now (a heartbeat JUST arrived), last_data_ms = start.
    try std.testing.expectEqual(
        @as(TimerVerdict, .stalled),
        checkTimers(now, 300_000, 300_000, now, 0),
    );
    // Same shape with heartbeats every second: last_any 1s old, data 5min old.
    try std.testing.expectEqual(
        @as(TimerVerdict, .stalled),
        checkTimers(now, 300_000, 300_000, now - 1000, 0),
    );
}

test "checkTimers: full silence trips (data tier reported first)" {
    // No bytes at all: both tiers are overdue. The data tier is checked first
    // and reported (it is the stricter, more specific diagnosis).
    try std.testing.expectEqual(
        @as(TimerVerdict, .stalled),
        checkTimers(400_000, 300_000, 300_000, 0, 0),
    );
}

test "checkTimers: data tier disabled falls back to byte-idle" {
    // data_ms == 0 disables tier 1 (operator opt-out); a heartbeat-only stall
    // then only trips once byte-idle also expires — documented degradation.
    const now: i64 = 400_000;
    try std.testing.expectEqual(
        @as(TimerVerdict, .none),
        checkTimers(now, 300_000, 0, now, 0),
    );
    // ...and once the bytes themselves stop, the idle tier catches it.
    try std.testing.expectEqual(
        @as(TimerVerdict, .idle),
        checkTimers(now, 300_000, 0, 0, 0),
    );
}

test "checkTimers: steady data keeps both tiers alive" {
    // A healthy stream: data lines every ~1s, bytes every ~1s. Nothing trips.
    const now: i64 = 300_000;
    try std.testing.expectEqual(
        @as(TimerVerdict, .none),
        checkTimers(now, 300_000, 300_000, now - 500, now - 500),
    );
}
