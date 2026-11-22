//! Cross-platform seams (Windows support, Phase 1).
//!
//! The TUI talks to the OS through three seams: terminal raw mode + sizing
//! (`terminal.zig`), key input (`keys.zig` poll/read), and process-level
//! utilities here. Everything below has a POSIX implementation (behavior
//! unchanged) and a Windows console-API implementation that compiles for the
//! windows-gnu target. Runtime validation happens on a real Windows console
//! (CI); on macOS/Linux the POSIX paths are the ones that execute.
//!
//! Zero-dependency: only `std` (std.posix on POSIX, extern "kernel32" on
//! Windows — the same kernel32 the OS links automatically).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const is_windows = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// Environment variables
// ---------------------------------------------------------------------------

/// Read an environment variable (POSIX name).
///
/// NOTE: `std.process.Environ.getPosix` is broken on Windows in Zig 0.17
/// (it unconditionally calls PosixBlock.view(), but Windows uses
/// GlobalBlock) — so the Windows path goes through `getAlloc`, which is
/// cross-platform (WTF-8 on Windows, plain bytes on POSIX). The value is
/// duped; the caller frees it with `freeEnv`.
pub fn envGetAlloc(
    alloc: std.mem.Allocator,
    environ: std.process.Environ,
    name: []const u8,
) ?[]u8 {
    if (is_windows) {
        const v = std.process.Environ.getAlloc(environ, alloc, name) catch return null;
        return v;
    }
    return Posix.envGetAlloc(alloc, environ, name);
}

fn windowsEnvGetAlloc(alloc: std.mem.Allocator, environ: std.process.Environ, name: []const u8) ?[]u8 {
    return std.process.Environ.getAlloc(environ, alloc, name) catch null;
}

/// Free a buffer returned by `envGetAlloc`.
pub fn freeEnv(alloc: std.mem.Allocator, buf: []u8) void {
    alloc.free(buf);
}

/// Is the environment variable set (any value, empty included)? Cross-platform
/// (uses `std.process.Environ.contains`, which is Windows-safe; getPosix is not).
pub fn envContains(environ: std.process.Environ, name: []const u8) bool {
    return std.process.Environ.contains(environ, std.heap.page_allocator, name) catch false;
}

/// Copy every variable in the process environment into `map` (cross-platform).
///
/// Used to build a child process's environment (inherit the parent, then apply
/// overrides). On POSIX this walks `std.c.environ`; on Windows it reads the
/// PEB-backed global block via `std.process.Environ`. Callers own `map`.
pub fn copyEnvironToMap(map: *std.process.Environ.Map) anyerror!void {
    if (is_windows) {
        const global: std.process.Environ = .{ .block = .global };
        var parent = try std.process.Environ.createMap(global, map.allocator);
        defer parent.deinit();
        var it = parent.iterator();
        while (it.next()) |kv| {
            try map.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        return;
    }
    try Posix.copyEnvironToMap(map);
}

/// Process id (for tmp-file names that must not collide across instances).
/// Comptime-dispatched so the POSIX body (std.c.getpid) is never analyzed on
/// Windows and vice versa.
const PidImpl = if (is_windows) struct {
    pub fn get() u32 {
        return Windows.pid();
    }
} else struct {
    pub fn get() u32 {
        return Posix.pid();
    }
};

pub fn pid() u32 {
    return PidImpl.get();
}

/// Borrowed env value (POSIX: pointer into the environ block; Windows: copy
/// into a per-thread stack buffer, valid until the next `envGet` call on this
/// thread). Same usage as `std.process.Environ.getPosix`, which is POSIX-only
/// in 0.17.
pub fn envGet(environ: std.process.Environ, name: []const u8) ?[]const u8 {
    if (is_windows) return windowsEnvGet(environ, name);
    return Posix.envGet(environ, name);
}

fn windowsEnvGet(environ: std.process.Environ, name: []const u8) ?[]const u8 {
    var map = std.process.Environ.createMap(environ, std.heap.page_allocator) catch return null;
    defer map.deinit();
    const val = map.get(name) orelse return null;
    // 0.17 has no thread_local; a single process-wide scratch buffer is fine
    // (env reads are sequential; a second envGet on the same thread
    // invalidates the first — call sites dup when the value outlives the
    // current statement).
    var buf: [2048]u8 = undefined;
    if (val.len > buf.len) return null;
    @memcpy(buf[0..val.len], val);
    return buf[0..val.len];
}

// ---------------------------------------------------------------------------
// Current working directory
// ---------------------------------------------------------------------------

/// Absolute path of the current working directory (allocated; caller frees).
pub fn getCwdAlloc(alloc: std.mem.Allocator) ![]u8 {
    if (is_windows) return Windows.getCwdAlloc(alloc);
    return Posix.getCwdAlloc(alloc);
}

/// Change the process working directory (resolves `path` against the cwd).
pub fn setCwd(path: []const u8) void {
    if (is_windows) {
        Windows.setCwd(path);
        return;
    }
    Posix.setCwd(path);
}

// ---------------------------------------------------------------------------
// Signals (POSIX only; Windows uses a console control handler)
// ---------------------------------------------------------------------------

/// Install a handler for SIGINT + SIGTERM (safety net for external kills;
/// the TUI handles Ctrl+C itself via key bindings).
pub fn installSignalHandler(handler: *const fn (std.c.SIG) callconv(.c) void) void {
    if (is_windows) return;
    Posix.installSignalHandler(@ptrCast(@alignCast(handler)));
}

/// Suspend the process (Ctrl+Z). No-op on Windows (there is no SIGTSTP;
/// Ctrl+Z in a console is EOF in cooked mode and is not delivered here).
pub fn suspendProcess() void {
    if (is_windows) return;
    Posix.suspendProcess();
}

// ---------------------------------------------------------------------------
// Monotonic-ish wall clock (hooks timestamps)
// ---------------------------------------------------------------------------

pub fn nowMillis(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(std.math.divTrunc(i96, ns, 1_000_000) catch 0);
}

// ---------------------------------------------------------------------------
// POSIX implementation (in a struct so it is only analyzed on POSIX targets)
// ---------------------------------------------------------------------------

// Posix is only referenced from the POSIX branch of the comptime-dispatched
// structs above, so its std.c / std.posix bodies are never analyzed on Windows.
const Posix = struct {
    pub fn envGetAlloc(alloc: std.mem.Allocator, environ: std.process.Environ, name: []const u8) ?[]u8 {
        const v = std.process.Environ.getPosix(environ, name) orelse return null;
        return alloc.dupe(u8, v) catch null;
    }

    pub fn envGet(environ: std.process.Environ, name: []const u8) ?[]const u8 {
        return std.process.Environ.getPosix(environ, name);
    }

    /// Walk `std.c.environ` (null-terminated `[*:0]u8` array) and copy each
    /// KEY=VALUE entry into `map`.
    pub fn copyEnvironToMap(map: *std.process.Environ.Map) Allocator.Error!void {
        const env = std.c.environ;
        var i: usize = 0;
        while (env[i] != null) : (i += 1) {
            const entry = env[i].?;
            const s = std.mem.span(entry);
            if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                try map.put(s[0..eq], s[eq + 1 ..]);
            }
        }
    }

    pub fn getCwdAlloc(alloc: std.mem.Allocator) ![]u8 {
        var buf: [4096]u8 = undefined;
        const p = std.c.getcwd(&buf, buf.len) orelse return error.CwdTooLong;
        const end = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
        return alloc.dupe(u8, p[0..end]);
    }

    pub fn setCwd(path: []const u8) void {
        const z = std.mem.sliceTo(path, 0);
        _ = std.c.chdir(@constCast(@ptrCast(z.ptr)));
    }

    pub fn installSignalHandler(handler: *const fn (std.posix.SIG) callconv(.c) void) void {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }

    pub fn suspendProcess() void {
        std.posix.raise(std.posix.SIG.TSTP) catch {};
    }

    pub fn pid() u32 {
        return @intCast(std.c.getpid());
    }
};

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

const Windows = struct {
    const windows = std.os.windows;

    extern "kernel32" fn GetCurrentDirectoryW(
        nBufferLength: u32,
        lpBuffer: [*]u16,
    ) callconv(.winapi) u32;

    extern "kernel32" fn SetCurrentDirectoryW(lpPath: ?[*:0]const u16) callconv(.winapi) c_int;

    /// UTF-8 → null-terminated UTF-16 (0.17's std.unicode has no wtf8
    /// helpers; path strings here are ASCII-dominant, surrogates handled).
    fn utf16FromUtf8(alloc: std.mem.Allocator, s: []const u8) ![:0]const u16 {
        var view = std.unicode.Utf8View.init(s) catch return error.InvalidUtf8;
        var it = view.iterator();
        var units = std.array_list.Managed(u16).init(alloc);
        errdefer units.deinit();
        while (it.nextCodepoint()) |cp| {
            if (cp <= 0xFFFF) {
                try units.append(@as(u16, @intCast(cp)));
            } else {
                const v = cp - 0x10000;
                try units.append(@as(u16, @intCast(0xD800 + ((v >> 10) & 0x3FF))));
                try units.append(@as(u16, @intCast(0xDC00 + (v & 0x3FF))));
            }
        }
        try units.append(0);
        return units.toOwnedSliceSentinel(0);
    }

    pub fn getCwdAlloc(alloc: std.mem.Allocator) ![]u8 {
        var cap: u32 = 8192;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const buf = alloc.alloc(u16, cap) catch return error.OutOfMemory;
            const n = GetCurrentDirectoryW(cap, buf.ptr);
            if (n > 0 and n <= cap) {
                const utf8 = alloc.alloc(u8, n * 4) catch {
                    alloc.free(buf);
                    return error.OutOfMemory;
                };
                // UTF-16 → UTF-8 (surrogate pairs recombined).
                var m: usize = 0;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const unit = buf[i];
                    const cp: u21 = blk: {
                        if (unit >= 0xD800 and unit <= 0xDBFF and i + 1 < n) {
                            const lo = buf[i + 1];
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                i += 1;
                                break :blk 0x10000 + ((@as(u21, @intCast(unit - 0xD800)) << 10) | @as(u21, @intCast(lo - 0xDC00)));
                            }
                        }
                        break :blk unit;
                    };
                    const len = std.unicode.utf8Encode(cp, utf8[m..]) catch {
                        alloc.free(utf8);
                        alloc.free(buf);
                        return error.OutOfMemory;
                    };
                    m += len;
                }
                alloc.free(buf);
                return utf8[0..m];
            }
            alloc.free(buf);
            if (attempt > 2) return error.CwdTooLong;
            cap *= 2;
        }
    }

    pub fn setCwd(path: []const u8) void {
        // Best-effort: resolve relative paths against the current directory.
        const cwd = @This().getCwdAlloc(std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(cwd);
        const joined = std.fs.path.join(std.heap.page_allocator, &.{ cwd, path }) catch return;
        defer std.heap.page_allocator.free(joined);
        const wide = utf16FromUtf8(std.heap.page_allocator, joined) catch return;
        defer std.heap.page_allocator.free(wide);
        _ = SetCurrentDirectoryW(wide.ptr);
    }

    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    pub fn pid() u32 {
        return GetCurrentProcessId();
    }
};
