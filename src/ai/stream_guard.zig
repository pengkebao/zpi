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

/// Build the guard type bound to the concrete session pointer type.
pub fn Guard(Sess: type) type {
    return struct {
        const Self = @This();
        ctx: Sess = undefined,
        fd: std.posix.fd_t = 0,
        io: std.Io = undefined,
        idle_ms: i64 = 0,
        /// Last time data arrived (epoch ms); the stream loop refreshes it on
        /// every line.
        last_data_ms: std.atomic.Value(i64) = .init(0),
        done: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,

        /// Start the watchdog. `session` is the concrete session pointer; `fd`
        /// must stay open until `stop` is called.
        pub fn start(self: *Self, session: Sess, fd: std.posix.fd_t, io: std.Io, idle_ms: i64) void {
            self.* = .{ .ctx = session, .fd = fd, .io = io, .idle_ms = idle_ms };
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

        /// Call on the stream thread whenever data arrives: resets the idle
        /// window. Cheap (one atomic store).
        pub fn noteData(self: *Self) void {
            self.last_data_ms.store(nowMs(self.io), .release);
        }

        fn guardMain(self: *Self, s: Sess) void {
            const POLL_MS: i64 = 250;
            self.last_data_ms.store(nowMs(self.io), .release);
            while (!self.done.load(.acquire)) {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(POLL_MS), .real) catch return;
                if (s.*.isAborted()) {
                    // ESC while the main thread is inside read(): unblock it.
                    // The stream loop then sees isAborted() and returns.
                    shutdownFd(self.fd);
                    return;
                }
                const idle = nowMs(self.io) - self.last_data_ms.load(.acquire);
                if (self.idle_ms > 0 and idle >= self.idle_ms) {
                    // pi bodyTimeout: no bytes for the idle window → fail the
                    // stream; the provider retry loop retries (transport_error).
                    std.debug.print("error: SSE stream idle for {d}s (no data) — aborting stream\n", .{@divTrunc(self.idle_ms, 1000)});
                    shutdownFd(self.fd);
                    return;
                }
            }
        }

        fn nowMs(io: std.Io) i64 {
            const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            return @intCast(std.math.divTrunc(i96, ns, 1_000_000) catch 0);
        }

        fn shutdownFd(fd: std.posix.fd_t) void {
            _ = std.c.shutdown(fd, @intCast(std.posix.SHUT.RDWR));
        }
    };
}
