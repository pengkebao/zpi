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
    /// Streaming callback invoked for each output chunk (stdout+stderr, in
    /// arrival order, from a reader thread). `ctx` is passed through.
    on_data: ?*const fn (data: []const u8, ctx: *anyopaque) void = null,
    on_data_ctx: *anyopaque = undefined,
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
    on_data: ?*const fn (data: []const u8, ctx: *anyopaque) void,
    on_data_ctx: *anyopaque,
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
        if (ctx.on_data) |cb| cb(buf[0..n], ctx.on_data_ctx);
    }
    ctx.done.store(true, .unordered);
}

fn isAborted(opts: ExecOptions) bool {
    if (opts.abort_check) |f| return f();
    return false;
}

// kernel32 pieces std.os.windows lacks in 0.17. Comptime-selected so the
// externs are only declared on Windows (same pattern as platform.zig).
const Win = if (builtin.os.tag == .windows) struct {
    const DETACHED_PROCESS: u32 = 0x00000008;
    const PROCESS_INFORMATION = extern struct {
        hProcess: std.os.windows.HANDLE,
        hThread: std.os.windows.HANDLE,
        dwProcessId: u32,
        dwThreadId: u32,
    };
    extern "kernel32" fn GetProcessId(hProcess: std.os.windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*]u16,
        lpProcessAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        bInheritHandles: i32,
        dwCreationFlags: u32,
        lpEnvironment: ?*std.os.windows.LPVOID,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *std.os.windows.STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) i32;

    fn taskkillTree(pid: u32) void {
        // CreateProcessW needs a mutable, NUL-terminated command line.
        // The command is pure ASCII, so format into u8 and widen to u16.
        var buf8: [64]u8 = undefined;
        const line8 = std.fmt.bufPrint(&buf8, "taskkill /F /T /PID {d}", .{pid}) catch return;
        var cmdline: [65]u16 = undefined;
        for (line8, 0..) |c, i| cmdline[i] = c;
        cmdline[line8.len] = 0;
        var si: std.os.windows.STARTUPINFOW = undefined;
        si.cb = @sizeOf(std.os.windows.STARTUPINFOW);
        var info: PROCESS_INFORMATION = undefined;
        if (CreateProcessW(null, &cmdline, null, null, 0, DETACHED_PROCESS, null, null, &si, &info) != 0) {
            _ = CloseHandle(info.hProcess);
            _ = CloseHandle(info.hThread);
        }
    }
} else struct {};

/// Kill the whole process tree, then reap the shell itself (which unblocks
/// the reader threads on pipe EOF). POSIX: SIGKILL to the child's process
/// group (set up at spawn), with a single-process fallback. Windows:
/// `taskkill /F /T` (pi killProcessTree uses the same).
fn killTree(io: Io, child: *process.Child, group_pid: ?std.posix.pid_t) void {
    if (builtin.os.tag == .windows) {
        if (child.id) |handle| {
            const pid = Win.GetProcessId(handle);
            if (pid != 0) Win.taskkillTree(pid);
        }
        child.kill(io);
        return;
    }
    if (group_pid) |pg| {
        std.posix.kill(-pg, .KILL) catch {
            if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        };
    }
    child.kill(io); // reaps child, unblocks readers
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

    // POSIX: put the shell in its OWN process group (setpgid(0,0) in the
    // child before exec) so abort/timeout can kill the whole tree,
    // pi killProcessTree: kill(-pid). Without this, killing the shell
    // leaves grandchildren (e.g. `python script.py` -> python) alive,
    // still holding the stdout pipes open — the readers then block on
    // EOF and the tool call hangs until the user kills things by hand.
    // Windows has no process groups (taskkill /T handles the tree) and its
    // posix.pid_t has a different shape, so the option is comptime-selected.
    const spawn_opts: process.SpawnOptions = if (builtin.os.tag == .windows) .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = opts.env_map,
    } else .{
        .argv = argv,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = opts.env_map,
    };
    var child = process.spawn(io, spawn_opts) catch return error.SpawnFailed;
    // On Windows the process-group concept is unused (taskkill /T handles
    // the tree) and std.posix.pid_t is void, so the whole branch is
    // comptime-selected (same pattern as platform.zig).
    const GroupPid = if (builtin.os.tag == .windows) struct {
        fn get(_: *process.Child) ?std.posix.pid_t { return null; }
    } else struct {
        fn get(c: *process.Child) ?std.posix.pid_t { return c.id; }
    };
    const group_pid = GroupPid.get(&child);

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
        ReaderCtx{ .file = stdout_file, .io = io, .out = out, .mutex = &mutex, .on_data = opts.on_data, .on_data_ctx = opts.on_data_ctx, .done = &state.stdout_done },
    }) catch {
        child.kill(io);
        return error.SpawnFailed;
    };
    var stderr_thread = std.Thread.spawn(.{}, readerMain, .{
        ReaderCtx{ .file = stderr_file, .io = io, .out = out, .mutex = &mutex, .on_data = opts.on_data, .on_data_ctx = opts.on_data_ctx, .done = &state.stderr_done },
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
            killTree(io, &child, group_pid); // reaps child, unblocks readers
            killed = true;
            break;
        }
        if (timeout_ns != null and elapsed_ns >= timeout_ns.?) {
            killTree(io, &child, group_pid);
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

const OnDataTest = struct {
    chunks: std.array_list.Managed([]const u8),
    joined: std.array_list.Managed(u8),
};

fn onDataCb(data: []const u8, c: *anyopaque) void {
    const t: *OnDataTest = @alignCast(@ptrCast(c));
    t.chunks.append(data) catch return;
    t.joined.appendSlice(data) catch return;
}

test "on_data callback receives every chunk in order" {
    if (builtin.os.tag == .windows) return; // /bin/sh -c only on posix
    const alloc = std.testing.allocator;
    var t = OnDataTest{
        .chunks = std.array_list.Managed([]const u8).init(alloc),
        .joined = std.array_list.Managed(u8).init(alloc),
    };
    defer t.chunks.deinit();
    defer t.joined.deinit();
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const res = exec(alloc, std.Io.Threaded.global_single_threaded.io(), defaultConfig(), "seq 1 5", .{
        .on_data = onDataCb,
        .on_data_ctx = &t,
    }, &out) catch |err| switch (err) {
        error.SpawnFailed => return, // sandboxed test env: no child processes
        else => unreachable,
    };
    try std.testing.expectEqual(@as(?u8, 0), res.exit_code);
    // The callback saw the same bytes the buffer collected.
    try std.testing.expectEqualStrings(out.items, t.joined.items);
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n", out.items);
    // At least one chunk arrived via the callback.
    try std.testing.expect(t.chunks.items.len >= 1);
}
