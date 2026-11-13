//! Shell abstraction layer (Phase E1).
//!
//! Spawns a shell command with piped stdout/stderr, streams output into a shared
//! buffer (and optional callback), and enforces a real timeout and abort.
//!
//! Thread model:
//!   - two reader threads drain stdout/stderr with blocking reads (avoids pipe
//!     deadlock) and set a done flag when each pipe hits EOF
//!   - the main thread polls timeout/abort every 10ms; on trigger it kills the
//!     child (which reaps it and unblocks the readers)
//!   - if the child exits on its own (both pipes hit EOF), the main thread waits
//!     to reap it and capture the exit code
//!
//! Cross-platform: unix uses `/bin/sh -c`, windows uses PowerShell.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = std.Io.File;
const process = std.process;
const Mutex = std.Io.Mutex;

/// Truncation limits (aligned with pi).
pub const MAX_LINES = 2000;
pub const MAX_BYTES = 50 * 1024; // 50KB
pub const GREP_MAX_LINE_LENGTH = 500;

/// Shell configuration. The command is appended as the final argv element.
pub const ShellConfig = struct {
    shell: []const u8,
    args: []const []const u8,
};

/// Default shell for the current platform.
pub fn defaultConfig() ShellConfig {
    return comptime if (builtin.os.tag == .windows)
        .{ .shell = "powershell", .args = &.{"-NoProfile", "-Command"} }
    else
        .{ .shell = "/bin/sh", .args = &.{"-c"} };
}

pub const ExecOptions = struct {
    /// Timeout in seconds (null = no timeout).
    timeout: ?f64 = null,
    /// Streaming callback invoked for each output chunk (stdout+stderr, in arrival order).
    on_data: ?*const fn (data: []const u8) void = null,
    /// Returns true when the caller wants the command aborted (Ctrl-C).
    abort_check: ?*const fn () bool = null,
    /// Environment map override (null = inherit).
    env_map: ?*const process.Environ.Map = null,
};

pub const ExecResult = struct {
    /// Exit code, or null when the child was killed by timeout/abort (or no code).
    exit_code: ?u8,
    timed_out: bool = false,
    aborted: bool = false,
};

pub const ExecError = error{ SpawnFailed, NoStdout, NoStderr, OutOfMemory };

/// Per-exec mutable state shared with the reader threads.
const ExecState = struct {
    stdout_done: std.atomic.Value(bool) = .init(false),
    stderr_done: std.atomic.Value(bool) = .init(false),
};

/// Context passed to a reader thread.
const ReaderCtx = struct {
    file: File,
    io: Io,
    out: *std.array_list.Managed(u8),
    mutex: *Mutex,
    on_data: ?*const fn (data: []const u8) void,
    done: *std.atomic.Value(bool),
};

fn readerMain(ctx: ReaderCtx) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = ctx.file.readStreaming(ctx.io, &.{ &buf }) catch break;
        if (n == 0) continue;
        ctx.mutex.lock(ctx.io) catch {};
        ctx.out.appendSlice(buf[0..n]) catch {};
        ctx.mutex.unlock(ctx.io);
        if (ctx.on_data) |cb| cb(buf[0..n]);
    }
    ctx.done.store(true, .unordered);
}

fn isAborted(opts: ExecOptions) bool {
    if (opts.abort_check) |f| return f();
    return false;
}

/// Execute a shell command. Appends combined stdout+stderr to `out` (reset on
/// entry; caller owns and frees). Returns status flags.
pub fn exec(alloc: std.mem.Allocator, io: Io, config: ShellConfig, command: []const u8, opts: ExecOptions, out: *std.array_list.Managed(u8)) ExecError!ExecResult {
    // Build argv: [shell, ...args, command]
    var argv_list = std.array_list.Managed([]const u8).init(alloc);
    defer argv_list.deinit();
    try argv_list.append(config.shell);
    for (config.args) |a| try argv_list.append(a);
    try argv_list.append(command);
    const argv = argv_list.items;

    var child = process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = opts.env_map,
    }) catch return error.SpawnFailed;

    const stdout_file = child.stdout orelse {
        child.kill(io);
        return error.NoStdout;
    };
    const stderr_file = child.stderr orelse {
        child.kill(io);
        return error.NoStderr;
    };

    var mutex = Mutex.init;
    var state = ExecState{};
    out.* = std.array_list.Managed(u8).init(alloc);

    var killed = false;

    var stdout_thread = std.Thread.spawn(.{}, readerMain, .{
        ReaderCtx{ .file = stdout_file, .io = io, .out = out, .mutex = &mutex, .on_data = opts.on_data, .done = &state.stdout_done },
    }) catch {
        child.kill(io);
        return error.SpawnFailed;
    };
    var stderr_thread = std.Thread.spawn(.{}, readerMain, .{
        ReaderCtx{ .file = stderr_file, .io = io, .out = out, .mutex = &mutex, .on_data = opts.on_data, .done = &state.stderr_done },
    }) catch {
        stdout_thread.join();
        child.kill(io);
        return error.SpawnFailed;
    };

    // Poll timeout / abort. Sleep in small increments.
    const poll_interval = std.Io.Duration.fromMilliseconds(10);
    var elapsed_ns: i96 = 0;
    const timeout_ns: ?i96 = if (opts.timeout) |s| @as(i96, @intFromFloat(s * 1e9)) else null;

    while (true) {
        std.Io.sleep(io, poll_interval, .real) catch {};
        elapsed_ns += poll_interval.nanoseconds;

        if (isAborted(opts)) {
            child.kill(io); // reaps child, unblocks readers
            killed = true;
            break;
        }
        if (timeout_ns != null and elapsed_ns >= timeout_ns.?) {
            child.kill(io);
            killed = true;
            break;
        }
        if (state.stdout_done.load(.unordered) and state.stderr_done.load(.unordered)) {
            break; // child closed both pipes; exited on its own
        }
    }

    // Join reader threads. They finish when the child closes its write ends
    // (EOF) or when kill/wait closes the read ends (BADF -> break).
    stdout_thread.join();
    stderr_thread.join();

    var result: ExecResult = .{ .exit_code = null };
    if (killed) {
        if (timeout_ns != null and elapsed_ns >= timeout_ns.?) result.timed_out = true;
        if (isAborted(opts)) result.aborted = true;
    } else {
        // Child exited on its own; wait to reap and capture exit code.
        const term: process.Child.Term = child.wait(io) catch .{ .unknown = 0 };
        result.exit_code = switch (term) {
            .exited => |c| c,
            else => null,
        };
    }

    return result;
}

test "defaultConfig" {
    const cfg = defaultConfig();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("powershell", cfg.shell);
    } else {
        try std.testing.expectEqualStrings("/bin/sh", cfg.shell);
    }
}
