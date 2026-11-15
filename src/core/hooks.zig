//! Declarative hooks (Phase I2) — `hooks.json` files that run shell
//! scripts around agent events (pi parity: the equivalent of extension
//! event handlers, delivered as declarative config + subprocess scripts
//! since rpi does not embed a JS interpreter).
//!
//! Locations: `<agent-dir>/hooks.json` plus `<cwd>/.pi/hooks.json`
//! (project-trust gated; entries are merged, project last).
//!
//! Shape:
//! {
//!   "pre_tool_call":  [ { "command": "...", "tools": ["bash"], "timeout_ms": 10000 } ],
//!   "post_tool_call": [ ... ],
//!   "input":          [ ... ],
//!   "session_start":  [ ... ],
//!   "compaction":     [ ... ]
//! }
//!
//! Script protocol (Claude Code-style, in JSON on stdin):
//! - exit 0      -> allow (post/observe hooks: output ignored)
//! - exit 2      -> BLOCK (for pre_tool_call: stderr becomes the reason fed
//!                  back to the model as a tool error)
//! - other codes -> non-fatal hook error, execution continues
//! - timeout     -> process killed, treated as a non-fatal error
//!
//! Payloads on stdin:
//! - pre_tool_call/post_tool_call: {"hook":..., "tool":..., "args": <obj>, "cwd": "..."}
//! - input: {"hook":"input", "text": "..."}
//! - session_start/compaction: {"hook":"session_start"} / {"hook":"compaction"}

const std = @import("std");

pub const HookEntry = struct {
    command: []u8,
    /// Restrict to these tool names (pre/post only); empty = all tools.
    tools: [][]u8 = &.{},
    timeout_ms: u32 = 10_000,
};

pub const HooksConfig = struct {
    pre_tool_call: []HookEntry = &.{},
    post_tool_call: []HookEntry = &.{},
    input: []HookEntry = &.{},
    session_start: []HookEntry = &.{},
    compaction: []HookEntry = &.{},

    pub fn total(self: *const HooksConfig) usize {
        return self.pre_tool_call.len + self.post_tool_call.len +
            self.input.len + self.session_start.len + self.compaction.len;
    }
};

pub fn freeConfig(alloc: std.mem.Allocator, cfg: *HooksConfig) void {
    inline for (.{ "pre_tool_call", "post_tool_call", "input", "session_start", "compaction" }) |field| {
        const list = @field(cfg, field);
        for (list) |*e| {
            alloc.free(e.command);
            for (e.tools) |t| alloc.free(t);
            if (e.tools.len > 0) alloc.free(e.tools);
        }
        if (list.len > 0) alloc.free(list);
        @field(cfg, field) = &.{};
    }
}

fn parseEntry(alloc: std.mem.Allocator, v: std.json.Value) ?HookEntry {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const cmd_v = obj.get("command") orelse return null;
    const cmd = switch (cmd_v) {
        .string => |s| s,
        else => return null,
    };
    if (cmd.len == 0) return null;
    var tools: [][]u8 = &.{};
    if (obj.get("tools")) |tv| {
        switch (tv) {
            .array => |a| {
                var list = std.array_list.Managed([]u8).init(alloc);
                for (a.items) |item| {
                    switch (item) {
                        .string => |s| {
                            const c = alloc.dupe(u8, s) catch continue;
                            list.append(c) catch {};
                        },
                        else => {},
                    }
                }
                tools = list.toOwnedSlice() catch &.{};
            },
            else => {},
        }
    }
    var timeout_ms: u32 = 10_000;
    if (obj.get("timeout_ms")) |tv| {
        switch (tv) {
            .integer => |n| {
                if (n >= 100 and n <= 120_000) timeout_ms = @intCast(n);
            },
            else => {},
        }
    }
    return .{
        .command = alloc.dupe(u8, cmd) catch return null,
        .tools = tools,
        .timeout_ms = timeout_ms,
    };
}

fn parseSection(alloc: std.mem.Allocator, root: std.json.ObjectMap, key: []const u8) []HookEntry {
    var list = std.array_list.Managed(HookEntry).init(alloc);
    const v = root.get(key) orelse return list.toOwnedSlice() catch &.{};
    switch (v) {
        .array => |a| {
            for (a.items) |item| {
                if (parseEntry(alloc, item)) |e| list.append(e) catch {};
            }
        },
        else => {},
    }
    return list.toOwnedSlice() catch &.{};
}

fn parseFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, cfg: *HooksConfig) void {
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(buf);
    var p = std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch return;
    defer p.deinit();
    const root = switch (p.value) {
        .object => |o| o,
        else => return,
    };
    cfg.pre_tool_call = concatEntries(alloc, cfg.pre_tool_call, parseSection(alloc, root, "pre_tool_call"));
    cfg.post_tool_call = concatEntries(alloc, cfg.post_tool_call, parseSection(alloc, root, "post_tool_call"));
    cfg.input = concatEntries(alloc, cfg.input, parseSection(alloc, root, "input"));
    cfg.session_start = concatEntries(alloc, cfg.session_start, parseSection(alloc, root, "session_start"));
    cfg.compaction = concatEntries(alloc, cfg.compaction, parseSection(alloc, root, "compaction"));
}

fn concatEntries(alloc: std.mem.Allocator, a: []HookEntry, b: []HookEntry) []HookEntry {
    if (b.len == 0) {
        if (b.len != a.len) freeEntries(alloc, b);
        return a;
    }
    if (a.len == 0) return b;
    var out = std.array_list.Managed(HookEntry).init(alloc);
    out.appendSlice(a) catch {};
    out.appendSlice(b) catch {};
    alloc.free(a);
    alloc.free(b);
    return out.toOwnedSlice() catch a;
}

fn freeEntries(alloc: std.mem.Allocator, list: []HookEntry) void {
    for (list) |*e| {
        alloc.free(e.command);
        for (e.tools) |t| alloc.free(t);
        if (e.tools.len > 0) alloc.free(e.tools);
    }
    if (list.len > 0) alloc.free(list);
}

/// Load user-level hooks.json plus the project file (project entries
/// appended; the caller gates `include_project` on project trust).
pub fn loadConfig(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
    cwd: []const u8,
    include_project: bool,
) !HooksConfig {
    var cfg = HooksConfig{};
    errdefer freeConfig(alloc, &cfg);
    const user_path = try std.fmt.allocPrint(alloc, "{s}/hooks.json", .{agent_dir});
    defer alloc.free(user_path);
    parseFile(alloc, io, user_path, &cfg);
    if (include_project) {
        const proj_path = try std.fmt.allocPrint(alloc, "{s}/.pi/hooks.json", .{cwd});
        defer alloc.free(proj_path);
        parseFile(alloc, io, proj_path, &cfg);
    }
    return cfg;
}

pub const Outcome = union(enum) {
    /// All scripts allowed (exit 0).
    allow,
    /// A script exited 2 with this stderr as the blocking reason (owned).
    block: []u8,
    /// Scripts ran; non-fatal errors happened (exit codes other than 0/2 or
    /// timeouts) — `detail` holds the first problem description (owned).
    nonfatal_error: []u8,
};

fn matchesTools(entry: *const HookEntry, tool: []const u8) bool {
    if (entry.tools.len == 0) return true;
    for (entry.tools) |t| {
        if (std.mem.eql(u8, t, tool)) return true;
    }
    return false;
}

/// Run a shell command with `stdin_data` piped in; enforce `timeout_ms`.
/// stdout/stderr drain through `Io.File.MultiReader` (what process.run uses)
/// with a fill timeout; stdout is discarded, stderr is captured (capped by
/// the fixed buffer) as the blocking-reason / error-detail source.
fn runScript(
    alloc: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    stdin_data: []const u8,
    timeout_ms: u32,
    cwd: []const u8,
    stderr_out: *[]u8,
) i32 {
    var argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
    }) catch return -1;
    var stdin = child.stdin orelse {
        child.kill(io);
        return -1;
    };
    var stdout = child.stdout orelse {
        stdin.close(io);
        child.kill(io);
        return -1;
    };
    var stderr = child.stderr orelse {
        stdin.close(io);
        stdout.close(io);
        child.kill(io);
        return -1;
    };
    // Feed stdin (EPIPE if the script didn't read it — fine), close for EOF.
    std.Io.File.writeStreamingAll(stdin, io, stdin_data) catch {};
    stdin.close(io);
    child.stdin = null;

    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(alloc, io, mr_buf.toStreams(), &.{ stdout, stderr });
    defer mr.deinit();
    const stderr_reader = mr.reader(1);

    // Drain with the timeout; on deadline, kill and finish the drain.
    if (mr.fill(0, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .real } })) |_| {
        // EndOfStream: pipes closed (child exited cleanly).
    } else |err| switch (err) {
        error.Timeout => {
            child.kill(io);
            mr.fill(0, .none) catch {};
        },
        else => {},
    }
    // Close our pipe ends and NULL the child's fields: wait →
    // childCleanupPosix re-closes any non-null handles (BADF double-close,
    // the mcp.zig teardown lesson).
    stdout.close(io);
    stderr.close(io);
    child.stdout = null;
    child.stderr = null;
    const term = child.wait(io) catch {
        return -1;
    };
    // Capture stderr (truncate to 4KB for the reason/error detail).
    const buffered = stderr_reader.buffered();
    const take = @min(buffered.len, 4096);
    stderr_out.* = alloc.dupe(u8, buffered[0..take]) catch @constCast(&[_]u8{});
    return switch (term) {
        .exited => |c| @intCast(c),
        else => -3,
    };
}

fn ssNowMs(io: std.Io) u64 {
    var ts: std.posix.timespec = undefined;
    _ = io;
    std.posix.clock_gettime(.REALTIME, &ts) catch return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Run every matching entry for a section. Returns the Outcome; blocking
/// reasons / error details are allocated with `alloc` (caller frees).
pub fn runSection(
    alloc: std.mem.Allocator,
    io: std.Io,
    entries: []const HookEntry,
    tool: ?[]const u8,
    stdin_payload: []const u8,
    cwd: []const u8,
) Outcome {
    var first_error: ?[]u8 = null;
    for (entries) |*entry| {
        if (tool) |t| {
            if (!matchesTools(entry, t)) continue;
        }
        var stderr_cap: []u8 = "";
        const code = runScript(alloc, io, entry.command, stdin_payload, entry.timeout_ms, cwd, &stderr_cap);
        if (code == 0) {
            if (stderr_cap.len > 0) alloc.free(stderr_cap);
            continue;
        }
        if (code == 2) {
            // BLOCK: stderr is the reason (trim to a sane size).
            var reason = stderr_cap;
            if (reason.len > 2000) {
                const trimmed = alloc.dupe(u8, reason[0..2000]) catch {
                    // OOM: keep the untrimmed buffer (still the caller's memory).
                    return .{ .block = reason };
                };
                alloc.free(reason);
                reason = trimmed;
            } else if (reason.len == 0) {
                reason = alloc.dupe(u8, "blocked by hook") catch {
                    return .{ .block = stderr_cap };
                };
            }
            if (first_error) |fe| alloc.free(fe);
            return .{ .block = reason };
        }
        // non-fatal: keep the first problem description
        if (first_error == null) {
            const head = if (stderr_cap.len > 0)
                stderr_cap[0..@min(stderr_cap.len, 500)]
            else if (code == -2)
                "timeout"
            else
                "spawn failed";
            first_error = std.fmt.allocPrint(alloc, "hook '{s}' failed: {s}", .{ entry.command, head }) catch null;
        }
        alloc.free(stderr_cap);
    }
    if (first_error) |fe| return .{ .nonfatal_error = fe };
    return .allow;
}

/// Convenience: run the pre_tool_call section. Returns a block reason
/// (owned by `alloc`) or null when allowed.
pub fn preToolCall(
    cfg: *const HooksConfig,
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: []const u8,
    args_json: []const u8,
    cwd: []const u8,
) ?[]u8 {
    if (cfg.pre_tool_call.len == 0) return null;
    const payload = std.fmt.allocPrint(alloc, "{{\"hook\":\"pre_tool_call\",\"tool\":{s},\"args\":{s},\"cwd\":{s}}}", .{
        jsonStringish(alloc, tool) catch return null,
        if (args_json.len > 0) args_json else "{}",
        jsonStringish(alloc, cwd) catch return null,
    }) catch return null;
    defer alloc.free(payload);
    switch (runSection(alloc, io, cfg.pre_tool_call, tool, payload, cwd)) {
        .allow => return null,
        .block => |reason| return reason,
        .nonfatal_error => |detail| {
            alloc.free(detail);
            return null;
        },
    }
}

/// Convenience: run the post_tool_call section (observe-only).
pub fn postToolCall(
    cfg: *const HooksConfig,
    alloc: std.mem.Allocator,
    io: std.Io,
    tool: []const u8,
    args_json: []const u8,
    result: []const u8,
    cwd: []const u8,
) void {
    if (cfg.post_tool_call.len == 0) return;
    const result_escaped = jsonStringish(alloc, result) catch return;
    defer alloc.free(result_escaped);
    const payload = std.fmt.allocPrint(alloc, "{{\"hook\":\"post_tool_call\",\"tool\":{s},\"args\":{s},\"result\":{s},\"cwd\":{s}}}", .{
        jsonStringish(alloc, tool) catch return,
        if (args_json.len > 0) args_json else "{}",
        result_escaped,
        jsonStringish(alloc, cwd) catch return,
    }) catch return;
    defer alloc.free(payload);
    switch (runSection(alloc, io, cfg.post_tool_call, tool, payload, cwd)) {
        .allow => {},
        .block => |reason| alloc.free(reason),
        .nonfatal_error => |detail| alloc.free(detail),
    }
}

/// Convenience: run a payload-only section (input / session_start /
/// compaction). Returns a block reason for `input` (owned) or null.
pub fn runPayloadSection(
    section: []const HookEntry,
    alloc: std.mem.Allocator,
    io: std.Io,
    hook_name: []const u8,
    text: []const u8,
    cwd: []const u8,
) ?[]u8 {
    if (section.len == 0) return null;
    const text_escaped = jsonStringish(alloc, text) catch return null;
    defer alloc.free(text_escaped);
    const payload = std.fmt.allocPrint(alloc, "{{\"hook\":{s},\"text\":{s}}}", .{
        jsonStringish(alloc, hook_name) catch return null,
        text_escaped,
    }) catch return null;
    defer alloc.free(payload);
    switch (runSection(alloc, io, section, null, payload, cwd)) {
        .allow => return null,
        .block => |reason| return reason,
        .nonfatal_error => |detail| {
            alloc.free(detail);
            return null;
        },
    }
}

/// Render `s` as a JSON string literal (quotes included).
fn jsonStringish(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    try out.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    var b: [8]u8 = undefined;
                    try out.appendSlice(std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch continue);
                } else {
                    try out.append(c);
                }
            },
        }
    }
    try out.append('"');
    return out.toOwnedSlice();
}

// ---- tests ----

const testing = std.testing;

// The global single-threaded Threaded has a `.failing` internal allocator;
// process spawn allocates through it and OOMs. Spin up a real one lazily
// (container-level init would evaluate getCpuCount at comptime).
var t_threaded: ?std.Io.Threaded = null;
fn tIo() std.Io {
    if (t_threaded == null) {
        t_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return t_threaded.?.io();
}

test "parse hooks.json shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const io = tIo();
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const path = try std.fmt.allocPrint(alloc, "{s}/hooks.json", .{root});
    const body =
        \\{
        \\  "pre_tool_call": [
        \\    { "command": "bash gate.sh", "tools": ["bash", "edit"], "timeout_ms": 2000 },
        \\    { "command": "echo all" }
        \\  ],
        \\  "input": [ { "command": "log.sh" } ]
        \\}
    ;
    try tmp.dir.writeFile(tIo(), .{ .sub_path = "hooks.json", .data = body });
    var cfg = HooksConfig{};
    parseFile(alloc, io, path, &cfg);
    try testing.expectEqual(@as(usize, 2), cfg.pre_tool_call.len);
    try testing.expectEqualStrings("bash gate.sh", cfg.pre_tool_call[0].command);
    try testing.expectEqual(@as(usize, 2), cfg.pre_tool_call[0].tools.len);
    try testing.expectEqual(@as(u32, 2000), cfg.pre_tool_call[0].timeout_ms);
    try testing.expectEqual(@as(usize, 0), cfg.pre_tool_call[1].tools.len);
    try testing.expectEqual(@as(usize, 1), cfg.input.len);
    freeConfig(alloc, &cfg);
}

test "runSection block on exit 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var entries = [_]HookEntry{.{ .command = @constCast("sh -c 'cat >/dev/null; echo no-way >&2; exit 2'"), .timeout_ms = 5000 }};
    const out = runSection(alloc, tIo(), entries[0..], "bash", "{\"tool\":\"bash\"}", "/tmp");
    try testing.expect(out == .block);
    try testing.expect(std.mem.indexOf(u8, out.block, "no-way") != null);
    alloc.free(out.block);
}

test "runSection allow on exit 0 and nonfatal on other codes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ok = [_]HookEntry{.{ .command = @constCast("sh -c 'exit 0'"), .timeout_ms = 5000 }};
    const a = runSection(alloc, tIo(), ok[0..], null, "{}", "/tmp");
    try testing.expect(a == .allow);
    var bad = [_]HookEntry{.{ .command = @constCast("sh -c 'exit 1'"), .timeout_ms = 5000 }};
    const b = runSection(alloc, tIo(), bad[0..], null, "{}", "/tmp");
    try testing.expect(b == .nonfatal_error);
    alloc.free(b.nonfatal_error);
}
