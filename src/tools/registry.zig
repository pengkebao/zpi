//! Tool registry and built-in tools: bash, read, write, edit, grep, find, ls.

const std = @import("std");
const builtin = @import("builtin");
const shell = @import("shell.zig");
const truncate = @import("truncate.zig");
const match = @import("match.zig");
const edit_diff = @import("edit_diff.zig");

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,
    /// Wall time of the execution, for display ("Took 4.2s").
    duration_ms: u64 = 0,
    /// base64-encoded image bytes (owned); set by the read tool for image files.
    /// Ownership moves into the message when the agent builds the tool_result block.
    image_data: ?[]u8 = null,
    /// MIME type for image_data, e.g. "image/png" (owned).
    image_mime: ?[]u8 = null,
};

/// Detect a supported image MIME type from a file path's extension.
fn getImageMimeType(path: []const u8) ?[]const u8 {
    // Only the extension matters; check the last 8 bytes in lowercase.
    var lb: [8]u8 = undefined;
    const n = @min(path.len, @as(usize, 8));
    const tail = path[path.len - n ..];
    for (tail, 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const s = lb[0..n];
    if (std.mem.endsWith(u8, s, ".png")) return "image/png";
    if (std.mem.endsWith(u8, s, ".jpg") or std.mem.endsWith(u8, s, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, s, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, s, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, s, ".bmp")) return "image/bmp";
    return null;
}

/// base64-encode `src` into a freshly allocated slice (owned).
fn base64Encode(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(src.len);
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    const encoded = std.base64.standard.Encoder.encode(buf, src);
    return try alloc.dupe(u8, encoded);
}

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: *const fn (args_json: []const u8, ctx: *ExecutionContext) ToolResult,
};

pub const ExecutionContext = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    /// Returns true when the caller wants the current operation aborted (Ctrl-C).
    abort_check: ?*const fn () bool = null,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    tools: std.array_list.Managed(Tool),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc, .tools = .init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit();
    }

    pub fn register(self: *Registry, tool: Tool) !void {
        try self.tools.append(tool);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Tool {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Keep only the tools whose names are in `selected` (order preserved).
    /// Used by the tool selection engine (Phase E7). Tool fields are comptime
    /// strings, so removing entries frees no owned memory.
    pub fn filterToNames(self: *Registry, selected: []const []const u8) void {
        // In-place compaction: keep tools whose name is in `selected`.
        var w: usize = 0;
        for (self.tools.items) |t| {
            const keep = blk: {
                for (selected) |s| {
                    if (std.mem.eql(u8, t.name, s)) break :blk true;
                }
                break :blk false;
            };
            if (keep) {
                self.tools.items[w] = t;
                w += 1;
            }
        }
        while (self.tools.items.len > w) {
            _ = self.tools.pop();
        }
    }

    /// Return JSON array of function schemas.
    pub fn toolSchemasJson(self: *const Registry, alloc: std.mem.Allocator) ![]u8 {
        var out = std.array_list.Managed(u8).init(alloc);
        defer out.deinit();
        try out.append('[');
        var first = true;
        for (self.tools.items) |tool| {
            if (!first) try out.append(',');
            first = false;
            try out.appendSlice("{\"type\":\"function\",\"function\":{");
            const name_part = std.fmt.allocPrint(alloc, "\"name\":\"{s}\"", .{tool.name}) catch break;
            try out.appendSlice(name_part);
            alloc.free(name_part);
            try out.append(',');
            const desc_part = std.fmt.allocPrint(alloc, "\"description\":\"{s}\"", .{tool.description}) catch break;
            try out.appendSlice(desc_part);
            alloc.free(desc_part);
            try out.appendSlice(",\"parameters\":");
            try out.appendSlice(tool.parameters_json);
            try out.appendSlice("}}");
        }
        try out.append(']');
        return try out.toOwnedSlice();
    }
};


/// All ToolResult.content is heap-owned (or static "") and ownership
/// transfers to the caller (the agent message). free("") is a safe no-op,
/// so OOM fallbacks return "" instead of a static string.
fn err(alloc: std.mem.Allocator, msg: []const u8) ToolResult {
    return .{ .content = alloc.dupe(u8, msg) catch "", .is_error = true };
}

fn ok(alloc: std.mem.Allocator, msg: []const u8) ToolResult {
    return .{ .content = alloc.dupe(u8, msg) catch "", .is_error = false };
}

// ── JSON helpers ────────────────────────────────────────────────────

fn getStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (obj) {
        .object => |o| o,
        else => return null,
    };
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getNum(obj: std.json.Value, key: []const u8) usize {
    const o = switch (obj) {
        .object => |o| o,
        else => return 0,
    };
    return switch (o.get(key) orelse return 0) {
        .float => |n| @as(usize, @intFromFloat(n)),
        .integer => |n| @as(usize, @intCast(n)),
        else => 0,
    };
}

fn getFloat(obj: std.json.Value, key: []const u8) ?f64 {
    const o = switch (obj) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .float => |n| n,
        .integer => |n| @as(f64, @floatFromInt(n)),
        else => null,
    };
}

fn getBool(obj: std.json.Value, key: []const u8) ?bool {
    const o = switch (obj) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// Lowercase a string into a freshly allocated slice (owned).
fn lowerCopy(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Convert path separators to '/' (posix), into a freshly allocated slice.
fn toPosix(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.dupe(u8, s);
    for (out, 0..) |c, i| {
        if (c == '\\') out[i] = '/';
    }
    return out;
}

/// Read a file and split into lines. Returns an owned slice of owned line
/// strings (free with `freeLines`). A single trailing empty line is dropped.
fn readLines(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return error.ReadFailed;
    defer alloc.free(data);
    var out = std.array_list.Managed([]const u8).init(alloc);
    defer out.deinit();
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        try out.append(try alloc.dupe(u8, trimmed));
    }
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) {
        _ = out.pop();
    }
    return try out.toOwnedSlice();
}

fn freeLines(alloc: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |l| alloc.free(l);
    alloc.free(lines);
}

fn parseArgs(args_json: []const u8, alloc: std.mem.Allocator) ?std.json.Parsed(std.json.Value) {
    // Callers must hold the Parsed handle and deinit() it before returning;
    // tool results must never reference strings inside the parsed value.
    return std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch null;
}

// ── bash ────────────────────────────────────────────────────────────

const bashParams = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"},\"timeout\":{\"type\":\"number\",\"description\":\"Timeout in seconds (optional, no default timeout)\"}},\"required\":[\"command\"]}";

const bashDescription = std.fmt.comptimePrint(
    "Execute a shell command in the current working directory. Returns stdout and stderr. Output is truncated to last {d} lines or {d}KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
    .{ truncate.DEFAULT_MAX_LINES, truncate.DEFAULT_MAX_BYTES / 1024 });

pub fn registerBash(registry: *Registry) !void {
    try registry.register(.{
        .name = "bash",
        .description = bashDescription,
        .parameters_json = bashParams,
        .execute = executeBash,
    });
}

var tmp_file_counter = std.atomic.Value(u64).init(0);

/// Save full (untruncated) output to a temp file; returns the path (owned) or null.
fn saveFullOutput(alloc: std.mem.Allocator, io: std.Io, data: []const u8) ?[]u8 {
    const tmpdir = comptime if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    const sep = comptime if (builtin.os.tag == .windows) "\\" else "/";
    const id = tmp_file_counter.fetchAdd(1, .monotonic);
    const name = std.fmt.allocPrint(alloc, "rpi-bash-{d}.txt", .{id}) catch return null;
    defer alloc.free(name);
    const path = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ tmpdir, sep, name }) catch return null;
    defer alloc.free(path);
    const f = std.Io.Dir.createFileAbsolute(io, path, .{ .read = false, .truncate = true }) catch return null;
    defer std.Io.File.close(f, io);
    std.Io.File.writeStreamingAll(f, io, data) catch return null;
    return alloc.dupe(u8, path) catch null;
}

/// Build the truncation marker message (owned).
fn buildTruncationMarker(alloc: std.mem.Allocator, trunc: truncate.TruncationResult, full_path: ?[]const u8) ?[]u8 {
    const start_line = trunc.total_lines - trunc.output_lines + 1;
    const end_line = trunc.total_lines;
    var size_buf: [24]u8 = undefined;
    const size = truncate.formatSize(&size_buf, trunc.output_bytes);
    if (trunc.last_line_partial) {
        return std.fmt.allocPrint(alloc, "[Showing last {s} of line {d}. Full output: {s}]", .{ size_buf[0..size], end_line, full_path orelse "(not saved)" }) catch null;
    }
    if (full_path) |p| {
        if (trunc.truncated_by == .bytes) {
            return std.fmt.allocPrint(alloc, "[Showing lines {d}-{d} of {d} (50KB limit). Full output: {s}]", .{ start_line, end_line, trunc.total_lines, p }) catch null;
        }
        return std.fmt.allocPrint(alloc, "[Showing lines {d}-{d} of {d}. Full output: {s}]", .{ start_line, end_line, trunc.total_lines, p }) catch null;
    }
    if (trunc.truncated_by == .bytes) {
        return std.fmt.allocPrint(alloc, "[Showing lines {d}-{d} of {d} (50KB limit)]", .{ start_line, end_line, trunc.total_lines }) catch null;
    }
    return std.fmt.allocPrint(alloc, "[Showing lines {d}-{d} of {d}]", .{ start_line, end_line, trunc.total_lines }) catch null;
}

fn executeBash(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const command = getStr(obj, "command") orelse
        return err(ctx.alloc, "error: missing command");
    if (command.len == 0) return err(ctx.alloc, "error: empty command");

    const timeout: ?f64 = getFloat(obj, "timeout");

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();
    const res = shell.exec(ctx.alloc, ctx.io, shell.defaultConfig(), command, .{
        .timeout = timeout,
        .abort_check = ctx.abort_check,
    }, &out) catch |e| {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "error: {s}", .{@errorName(e)}) catch "",
            .is_error = true,
        };
    };

    // Truncate the collected output (keep the tail).
    const trunc = truncate.truncateTail(ctx.alloc, out.items) catch {
        ctx.alloc.free(out.items);
        return err(ctx.alloc, "error: oom");
    };
    defer ctx.alloc.free(trunc.content);

    var text = std.array_list.Managed(u8).init(ctx.alloc);
    defer text.deinit();
    if (trunc.content.len == 0) {
        text.appendSlice("(no output)") catch return err(ctx.alloc, "error: oom");
    } else {
        text.appendSlice(trunc.content) catch return err(ctx.alloc, "error: oom");
    }

    // Truncation marker + temp file.
    var full_path: ?[]u8 = null;
    defer if (full_path) |p| ctx.alloc.free(p);
    if (trunc.truncated) {
        full_path = saveFullOutput(ctx.alloc, ctx.io, out.items);
        const marker = buildTruncationMarker(ctx.alloc, trunc, full_path);
        if (marker) |m| {
            text.appendSlice("\n\n") catch return err(ctx.alloc, "error: oom");
            text.appendSlice(m) catch return err(ctx.alloc, "error: oom");
            ctx.alloc.free(m);
        }
    }

    // Status: timeout / aborted / exit code.
    var is_error = false;
    if (res.timed_out) {
        const t = std.fmt.allocPrint(ctx.alloc, "\n\nCommand timed out after {d} seconds", .{timeout orelse 0}) catch "";
        text.appendSlice(t) catch return err(ctx.alloc, "error: oom");
        ctx.alloc.free(t);
        is_error = true;
    } else if (res.aborted) {
        text.appendSlice("\n\nCommand aborted") catch return err(ctx.alloc, "error: oom");
        is_error = true;
    } else if (res.exit_code) |code| {
        if (code != 0) {
            const t = std.fmt.allocPrint(ctx.alloc, "\n\nCommand exited with code {d}", .{code}) catch "";
            text.appendSlice(t) catch return err(ctx.alloc, "error: oom");
            ctx.alloc.free(t);
            is_error = true;
        }
    }

    return .{ .content = text.toOwnedSlice() catch "", .is_error = is_error };
}

// ── read ────────────────────────────────────────────────────────────

const readParams = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to read\"},\"offset\":{\"type\":\"integer\",\"description\":\"Line number to start from (1-indexed)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum number of lines to read\"}},\"required\":[\"path\"]}";

pub fn registerRead(registry: *Registry) !void {
    try registry.register(.{
        .name = "read",
        .description = "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        .parameters_json = readParams,
        .execute = executeRead,
    });
}

fn executeRead(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const path = getStr(obj, "path") orelse
        return err(ctx.alloc, "error: missing path");
    const offset = getNum(obj, "offset");
    const limit = getNum(obj, "limit");

    // Read the whole file into a heap buffer (owned).
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .unlimited) catch |e| {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "error: {s}: {s}", .{ path, @errorName(e) }) catch "",
            .is_error = true,
        };
    };
    defer ctx.alloc.free(data);

    // ── Image path ───────────────────────────────────────────────
    if (getImageMimeType(path)) |m| {
        const b64 = base64Encode(ctx.alloc, data) catch
            return .{ .content = "error: oom", .is_error = true };
        const note = std.fmt.allocPrint(ctx.alloc, "Read image file [{s}] ({d} bytes)", .{ m, data.len }) catch
            return .{ .content = "error: oom", .is_error = true };
        const mime_copy = ctx.alloc.dupe(u8, m) catch
            return .{ .content = note, .is_error = true, .image_data = b64 };
        return .{ .content = note, .is_error = false, .image_data = b64, .image_mime = mime_copy };
    }

    // ── Text path ────────────────────────────────────────────────
    // Split into lines (owned). Each line string is individually allocated,
    // so free them all before deinit-ing the backing array.
    var lines = std.array_list.Managed([]const u8).init(ctx.alloc);
    defer {
        for (lines.items) |l| ctx.alloc.free(l);
        lines.deinit();
    }
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |line| {
        lines.append(ctx.alloc.dupe(u8, line) catch return .{ .content = "error: oom", .is_error = true }) catch
            return .{ .content = "error: oom", .is_error = true };
    }
    // Drop the trailing empty line produced by a final newline (pi parity).
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    const total = lines.items.len;

    const start = if (offset > 0) offset - 1 else 0;
    const start_display = start + 1;
    if (start >= total) {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "Offset {d} is beyond end of file ({d} lines total)", .{ offset, total }) catch "",
            .is_error = true,
        };
    }

    var user_limited: ?usize = null;
    var selected: []const []const u8 = undefined;
    if (limit > 0) {
        const end = @min(start + limit, total);
        selected = lines.items[start..end];
        user_limited = end - start;
    } else {
        selected = lines.items[start..];
    }

    // Join the selected lines into a single string.
    var sel = std.array_list.Managed(u8).init(ctx.alloc);
    defer sel.deinit();
    for (selected, 0..) |line, i| {
        if (i > 0) sel.append('\n') catch return .{ .content = "error: oom", .is_error = true };
        sel.appendSlice(line) catch return .{ .content = "error: oom", .is_error = true };
    }

    const trunc = truncate.truncateHead(ctx.alloc, sel.items) catch
        return .{ .content = "error: oom", .is_error = true };
    defer ctx.alloc.free(trunc.content);

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();

    if (trunc.truncated and trunc.output_lines == 0) {
        // First line alone exceeds the byte limit: point the model at a bash fallback.
        var size_buf: [16]u8 = undefined;
        const size = truncate.formatSize(&size_buf, selected[0].len);
        var limit_buf: [16]u8 = undefined;
        const limit_size = truncate.formatSize(&limit_buf, truncate.DEFAULT_MAX_BYTES);
        const msg = std.fmt.allocPrint(
            ctx.alloc,
            "[Line {d} is {s}, exceeds {s} limit. Use bash: sed -n '{d}p' {s} | head -c {d}]",
            .{ start_display, size_buf[0..size], limit_buf[0..limit_size], start_display, path, truncate.DEFAULT_MAX_BYTES },
        ) catch return .{ .content = "error: oom", .is_error = true };
        out.appendSlice(msg) catch return .{ .content = "error: oom", .is_error = true };
        ctx.alloc.free(msg);
    } else if (trunc.truncated) {
        const end_display = start_display + trunc.output_lines - 1;
        const next_offset = end_display + 1;
        out.appendSlice(trunc.content) catch return .{ .content = "error: oom", .is_error = true };
        out.appendSlice("\n\n") catch return .{ .content = "error: oom", .is_error = true };
        const msg = if (trunc.truncated_by == .lines)
            std.fmt.allocPrint(ctx.alloc, "[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]", .{ start_display, end_display, total, next_offset })
        else
            std.fmt.allocPrint(ctx.alloc, "[Showing lines {d}-{d} of {d} (50KB limit). Use offset={d} to continue.]", .{ start_display, end_display, total, next_offset });
        const m2 = msg catch return .{ .content = "error: oom", .is_error = true };
        out.appendSlice(m2) catch return .{ .content = "error: oom", .is_error = true };
        ctx.alloc.free(m2);
    } else if (user_limited != null and start + user_limited.? < total) {
        const remaining = total - (start + user_limited.?);
        const next_offset = start + user_limited.? + 1;
        out.appendSlice(trunc.content) catch return .{ .content = "error: oom", .is_error = true };
        const msg = std.fmt.allocPrint(ctx.alloc, "\n\n[{d} more lines in file. Use offset={d} to continue.]", .{ remaining, next_offset }) catch
            return .{ .content = "error: oom", .is_error = true };
        out.appendSlice(msg) catch return .{ .content = "error: oom", .is_error = true };
        ctx.alloc.free(msg);
    } else {
        out.appendSlice(trunc.content) catch return .{ .content = "error: oom", .is_error = true };
    }

    return .{ .content = out.toOwnedSlice() catch "", .is_error = false };
}

// ── write ───────────────────────────────────────────────────────────

const writeParams = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to write\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write to the file\"}},\"required\":[\"path\",\"content\"]}";

pub fn registerWrite(registry: *Registry) !void {
    try registry.register(.{
        .name = "write",
        .description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        .parameters_json = writeParams,
        .execute = executeWrite,
    });
}

fn executeWrite(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const path = getStr(obj, "path") orelse
        return err(ctx.alloc, "error: missing path");
    const content = getStr(obj, "content") orelse
        return err(ctx.alloc, "error: missing content");

    // Create parent directories
    createParentDirs(path, ctx) catch {};

    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = content }) catch |e| {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "error: write {s}: {s}", .{ path, @errorName(e) }) catch "",
            .is_error = true,
        };
    };
    return .{
        .content = std.fmt.allocPrint(ctx.alloc, "Successfully wrote {d} bytes to {s}", .{ content.len, path }) catch "",
        .is_error = false,
    };
}

fn createParentDirs(path: []const u8, ctx: *ExecutionContext) !void {
    // std.fs.path.dirname handles both '/' and '\\'; createDirPath builds the
    // whole tree recursively.
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
}

// ── edit ────────────────────────────────────────────────────────────

const editParams = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the text file to edit.\"},\"edits\":{\"type\":\"array\",\"description\":\"One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.\",\"items\":{\"type\":\"object\",\"required\":[\"oldText\",\"newText\"],\"properties\":{\"oldText\":{\"type\":\"string\",\"description\":\"Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call.\"},\"newText\":{\"type\":\"string\",\"description\":\"Replacement text for this targeted edit.\"}}}},\"oldText\":{\"type\":\"string\",\"description\":\"Legacy: exact text to find (use edits for multiple)\"},\"newText\":{\"type\":\"string\",\"description\":\"Legacy: replacement text\"}},\"required\":[\"path\"]}";

pub fn registerEdit(registry: *Registry) !void {
    try registry.register(.{
        .name = "edit",
        .description = "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. Fuzzy matching (whitespace/quote normalization) applies as a fallback. All edits are matched against the same original content, not incrementally.",
        .parameters_json = editParams,
        .execute = executeEdit,
    });
}

pub fn executeEdit(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const obj_map = switch (obj) {
        .object => |o| o,
        else => return err(ctx.alloc, "error: expected object"),
    };
    const path = getStr(obj, "path") orelse
        return err(ctx.alloc, "error: missing path");

    // Parse edits: an array of {oldText,newText}, a JSON string of such an array,
    // or legacy top-level oldText/newText. All edits are matched against the
    // ORIGINAL file content (not incrementally).
    var edits = std.array_list.Managed(edit_diff.Edit).init(ctx.alloc);
    defer edits.deinit();
    if (obj_map.get("edits")) |v| {
        switch (v) {
            .array => |a| {
                for (a.items) |item| {
                    const o = switch (item) {
                        .object => |o| o,
                        else => return err(ctx.alloc, "error: each edit must be an object"),
                    };
                    const old_t = getStr(std.json.Value{ .object = o }, "oldText") orelse return err(ctx.alloc, "error: edit missing oldText");
                    const new_t = getStr(std.json.Value{ .object = o }, "newText") orelse return err(ctx.alloc, "error: edit missing newText");
                    appendEdit(&edits, old_t, new_t) catch return err(ctx.alloc, "error: oom");
                }
            },
            .string => |s| {
                var inner = parseArgs(s, ctx.alloc) orelse return err(ctx.alloc, "error: edits string is not valid JSON");
                defer inner.deinit();
                const arr = switch (inner.value) {
                    .array => |a| a,
                    else => return err(ctx.alloc, "error: edits string must be a JSON array"),
                };
                for (arr.items) |item| {
                    const o = switch (item) {
                        .object => |o| o,
                        else => return err(ctx.alloc, "error: each edit must be an object"),
                    };
                    const old_t = getStr(std.json.Value{ .object = o }, "oldText") orelse return err(ctx.alloc, "error: edit missing oldText");
                    const new_t = getStr(std.json.Value{ .object = o }, "newText") orelse return err(ctx.alloc, "error: edit missing newText");
                    appendEdit(&edits, old_t, new_t) catch return err(ctx.alloc, "error: oom");
                }
            },
            else => return err(ctx.alloc, "error: edits must be an array"),
        }
    } else {
        const old_t = getStr(obj, "oldText") orelse return err(ctx.alloc, "error: missing oldText or edits");
        const new_t = getStr(obj, "newText") orelse return err(ctx.alloc, "error: missing newText");
        appendEdit(&edits, old_t, new_t) catch return err(ctx.alloc, "error: oom");
    }
    if (edits.items.len == 0) return err(ctx.alloc, "error: no edits specified");

    // Read the file (heap-allocated).
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .unlimited) catch |e| {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "error: read {s}: {s}", .{ path, @errorName(e) }) catch "",
            .is_error = true,
        };
    };
    defer ctx.alloc.free(raw);
    if (raw.len == 0) return err(ctx.alloc, "error: file is empty");

    // Strip BOM, detect the dominant line ending, normalize to LF for matching.
    const split = edit_diff.splitBom(raw);
    const line_ending = edit_diff.detectLineEnding(split.text);
    const lf = edit_diff.normalizeToLF(ctx.alloc, split.text) catch return err(ctx.alloc, "error: oom");
    defer ctx.alloc.free(lf);

    // Apply all edits against the original content.
    const applied = edit_diff.applyEdits(ctx.alloc, lf, edits.items) catch |code| {
        return .{
            .content = editErrorMessage(ctx.alloc, path, code),
            .is_error = true,
        };
    };
    defer {
        for (applied.matches) |m| ctx.alloc.free(m.new_text);
        ctx.alloc.free(applied.matches);
        ctx.alloc.free(applied.new_content);
    }

    // Restore line endings (and BOM), then write back.
    const restored = edit_diff.restoreLineEndings(ctx.alloc, applied.new_content, line_ending) catch return err(ctx.alloc, "error: oom");
    defer ctx.alloc.free(restored);
    var final = std.array_list.Managed(u8).init(ctx.alloc);
    defer final.deinit();
    if (split.bom.len > 0) final.appendSlice(split.bom) catch return err(ctx.alloc, "error: oom");
    final.appendSlice(restored) catch return err(ctx.alloc, "error: oom");
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = final.items }) catch |e| {
        return .{
            .content = std.fmt.allocPrint(ctx.alloc, "error: write {s}: {s}", .{ path, @errorName(e) }) catch "",
            .is_error = true,
        };
    };

    // Render the diff for the model / transcript.
    const diff = edit_diff.generateDiffString(ctx.alloc, lf, applied.new_content, applied.matches) catch "";
    defer ctx.alloc.free(diff);
    return .{
        .content = std.fmt.allocPrint(ctx.alloc, "Successfully applied {d} edit(s) to {s}\n\n{s}", .{ applied.matches.len, path, diff }) catch "edited",
        .is_error = false,
    };
}

// ── grep ────────────────────────────────────────────────────────────

const grepParams = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Search pattern (basic regex or literal string)\"},\"path\":{\"type\":\"string\",\"description\":\"Directory or file to search (default: current directory)\"},\"glob\":{\"type\":\"string\",\"description\":\"Filter files by glob pattern, e.g. '*.ts'\"},\"ignore_case\":{\"type\":\"boolean\",\"description\":\"Case-insensitive search (default: false)\"},\"literal\":{\"type\":\"boolean\",\"description\":\"Treat pattern as literal string instead of regex (default: false)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of matches to return (default: 100)\"}},\"required\":[\"pattern\"]}";

const grepDescription = std.fmt.comptimePrint(
    "Search file contents for a pattern (basic regex: . * + ? [...] ^ $, or literal). Returns matching lines as path:line: text. Skips node_modules/.git/etc. Truncated to {d} matches or {d}KB (whichever first); long lines cut to {d} chars.",
    .{ 100, truncate.DEFAULT_MAX_BYTES / 1024, truncate.GREP_MAX_LINE_LENGTH });

const GREP_DEFAULT_LIMIT = 100;

pub fn registerGrep(registry: *Registry) !void {
    try registry.register(.{
        .name = "grep",
        .description = grepDescription,
        .parameters_json = grepParams,
        .execute = executeGrep,
    });
}

/// Append a notice to `final` inside a `[...]` wrapper. `first` tracks whether
/// this is the first notice (to emit the opening "["). `text` is copied into
/// `final`, so the caller may free it immediately after.
fn appendNotice(
    final: *std.array_list.Managed(u8),
    alloc: std.mem.Allocator,
    first: *bool,
    text: []const u8,
) void {
    _ = alloc;
    if (first.*) {
        final.appendSlice("\n\n[") catch {};
        first.* = false;
    } else {
        final.appendSlice(". ") catch {};
    }
    final.appendSlice(text) catch {};
}

/// True if any path component is a noise directory we skip by default.
fn shouldSkipPath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "node_modules") or
            std.mem.eql(u8, comp, ".git") or
            std.mem.eql(u8, comp, "target") or
            std.mem.eql(u8, comp, "dist") or
            std.mem.eql(u8, comp, ".zig-cache") or
            std.mem.eql(u8, comp, "build") or
            std.mem.eql(u8, comp, "vendor"))
        {
            return true;
        }
    }
    return false;
}

/// Search `lines` for `pat` (regex or literal), appending `rel:line: text`
/// matches to `out`. Updates the counters. Returns the number added.
fn grepLines(
    ctx: *ExecutionContext,
    pat: []const u8,
    literal: bool,
    ignore_case: bool,
    rel: []const u8,
    lines: []const []const u8,
    out: *std.array_list.Managed(u8),
    match_count: *usize,
    limit: usize,
    limit_reached: *bool,
    lines_truncated: *bool,
) usize {
    var added: usize = 0;
    for (lines, 0..) |line, idx| {
        if (ctx.abort_check != null and ctx.abort_check.?()) break;
        var hay = line;
        var hay_owned: ?[]u8 = null;
        if (ignore_case) {
            hay_owned = lowerCopy(ctx.alloc, line) catch break;
            hay = hay_owned.?;
        }
        const found = if (literal) std.mem.indexOf(u8, hay, pat) != null
            else match.regexMatch(pat, hay);
        if (!found) {
            if (hay_owned) |h| ctx.alloc.free(h);
            continue;
        }
        var text = hay;
        if (text.len > truncate.GREP_MAX_LINE_LENGTH) {
            text = text[0..truncate.GREP_MAX_LINE_LENGTH];
            lines_truncated.* = true;
        }
        const line_no: u32 = @intCast(idx + 1);
        if (out.items.len > 0) out.append('\n') catch break;
        out.appendSlice(rel) catch break;
        out.append(':') catch break;
        blk: {
            const num = std.fmt.allocPrint(ctx.alloc, "{d}", .{line_no}) catch break :blk;
            defer ctx.alloc.free(num);
            out.appendSlice(num) catch break :blk;
        }
        out.appendSlice(": ") catch break;
        out.appendSlice(text) catch break;
        // Free the lowercased copy only after `text` (a sub-slice of it) has
        // been copied into `out`; the arena reuses freed memory immediately.
        if (hay_owned) |h| ctx.alloc.free(h);
        match_count.* += 1;
        added += 1;
        if (match_count.* >= limit) {
            limit_reached.* = true;
            break;
        }
    }
    return added;
}

fn appendEdit(al: *std.array_list.Managed(edit_diff.Edit), old_t: []const u8, new_t: []const u8) !void {
    al.append(.{ .old = old_t, .new = new_t }) catch return error.OutOfMemory;
}

fn editErrorMessage(alloc: std.mem.Allocator, path: []const u8, code: edit_diff.Error) []const u8 {
    const name = switch (code) {
        edit_diff.Error.NoEdits => "no edits specified",
        edit_diff.Error.EmptyOldText => "oldText is empty",
        edit_diff.Error.NotFound => "oldText not found",
        edit_diff.Error.Duplicate => "oldText not unique (multiple occurrences)",
        edit_diff.Error.Overlap => "edits overlap",
        edit_diff.Error.NoChange => "no changes made (oldText == newText)",
        edit_diff.Error.OutOfMemory => "out of memory",
    };
    return std.fmt.allocPrint(alloc, "error: {s} in {s}", .{ name, path }) catch name;
}

fn executeGrep(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const pattern = getStr(obj, "pattern") orelse
        return err(ctx.alloc, "error: missing pattern");
    const search_path = getStr(obj, "path") orelse ".";
    const glob = getStr(obj, "glob");
    const ignore_case = getBool(obj, "ignore_case") orelse false;
    const literal = getBool(obj, "literal") orelse false;
    const limit_n = getNum(obj, "limit");
    const effective_limit: usize = if (limit_n == 0) GREP_DEFAULT_LIMIT else limit_n;

    var pat = pattern;
    var pat_owned: ?[]u8 = null;
    if (ignore_case) {
        pat_owned = lowerCopy(ctx.alloc, pattern) catch return err(ctx.alloc, "error: oom");
        pat = pat_owned.?;
    }
    defer if (pat_owned) |p| ctx.alloc.free(p);

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();
    var match_count: usize = 0;
    var limit_reached = false;
    var lines_truncated = false;

    const is_file = blk: {
        const st = std.Io.Dir.cwd().statFile(ctx.io, search_path, .{}) catch break :blk false;
        break :blk st.kind == .file;
    };

    if (is_file) {
        const lines = readLines(ctx.alloc, ctx.io, search_path) catch
            return .{ .content = std.fmt.allocPrint(ctx.alloc, "No matches found", .{}) catch "", .is_error = false };
        defer freeLines(ctx.alloc, lines);
        const rel = std.fs.path.basename(search_path);
        _ = grepLines(ctx, pat, literal, ignore_case, rel, lines, &out, &match_count, effective_limit, &limit_reached, &lines_truncated);
    } else {
        const dir = std.Io.Dir.cwd().openDir(ctx.io, search_path, .{ .iterate = true }) catch |e| {
            return .{ .content = std.fmt.allocPrint(ctx.alloc, "error: {s}", .{@errorName(e)}) catch "", .is_error = true };
        };
        var walker = std.Io.Dir.walk(dir, ctx.alloc) catch {
            dir.close(ctx.io);
            return err(ctx.alloc, "error: oom");
        };
        defer walker.deinit();
        defer dir.close(ctx.io);

        while (true) {
            if (limit_reached) break;
            const entry = walker.next(ctx.io) catch break;
            if (entry == null) break;
            const e = entry.?;
            if (e.kind != .file) continue;
            if (shouldSkipPath(e.path)) continue;
            if (glob) |g| {
                const target = if (std.mem.indexOfScalar(u8, g, '/') == null) e.basename else e.path;
                if (!match.globMatch(g, target)) continue;
            }
            if (ctx.abort_check != null and ctx.abort_check.?()) {
                return .{ .content = std.fmt.allocPrint(ctx.alloc, "Operation aborted", .{}) catch "", .is_error = true };
            }
            blk: {
                const lines = readLines(ctx.alloc, ctx.io, e.path) catch break :blk;
                defer freeLines(ctx.alloc, lines);
                const rel = toPosix(ctx.alloc, e.path) catch break :blk;
                defer ctx.alloc.free(rel);
                _ = grepLines(ctx, pat, literal, ignore_case, rel, lines, &out, &match_count, effective_limit, &limit_reached, &lines_truncated);
            }
        }
    }

    if (match_count == 0) {
        return .{ .content = std.fmt.allocPrint(ctx.alloc, "No matches found", .{}) catch "", .is_error = false };
    }

    // Byte truncation (no separate line limit: the match limit already caps rows).
    const trunc = truncate.truncateHeadWith(ctx.alloc, out.items, std.math.maxInt(usize), truncate.DEFAULT_MAX_BYTES) catch
        return err(ctx.alloc, "error: oom");
    var final = std.array_list.Managed(u8).init(ctx.alloc);
    defer final.deinit();
    final.appendSlice(trunc.content) catch return err(ctx.alloc, "error: oom");
    ctx.alloc.free(trunc.content);

    var first_notice = true;
    if (limit_reached) {
        const n = std.fmt.allocPrint(ctx.alloc, "{d} matches limit reached. Use limit={d} for more, or refine pattern", .{ effective_limit, effective_limit * 2 }) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (trunc.truncated) {
        var size_buf: [16]u8 = undefined;
        const size_len = truncate.formatSize(&size_buf, trunc.total_bytes);
        const n = std.fmt.allocPrint(ctx.alloc, "{s} limit reached", .{size_buf[0..size_len]}) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (lines_truncated) {
        const n = std.fmt.allocPrint(ctx.alloc, "Some lines truncated to {d} chars. Use read tool to see full lines", .{truncate.GREP_MAX_LINE_LENGTH}) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (!first_notice) final.appendSlice("]") catch return err(ctx.alloc, "error: oom");
    const content = final.toOwnedSlice() catch return err(ctx.alloc, "error: oom");
    return .{ .content = content, .is_error = false };
}

const FIND_DEFAULT_LIMIT = 1000;

fn executeFind(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;

    const pattern = getStr(obj, "pattern") orelse
        return err(ctx.alloc, "error: missing pattern");
    const search_path = getStr(obj, "path") orelse ".";
    const limit_n = getNum(obj, "limit");
    const effective_limit: usize = if (limit_n == 0) FIND_DEFAULT_LIMIT else limit_n;

    // A pattern without '/' matches the basename; with '/', the full path.
    const match_full = std.mem.indexOfScalar(u8, pattern, '/') != null;

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();
    var count: usize = 0;
    var limit_reached = false;

    const dir = std.Io.Dir.cwd().openDir(ctx.io, search_path, .{ .iterate = true }) catch |e| {
        return .{ .content = std.fmt.allocPrint(ctx.alloc, "error: {s}", .{@errorName(e)}) catch "", .is_error = true };
    };
    var walker = std.Io.Dir.walk(dir, ctx.alloc) catch {
        dir.close(ctx.io);
        return err(ctx.alloc, "error: oom");
    };
    defer walker.deinit();
    defer dir.close(ctx.io);

    while (true) {
        if (limit_reached) break;
        const entry = walker.next(ctx.io) catch break;
        if (entry == null) break;
        const e = entry.?;
        if (e.kind != .file) continue;
        if (shouldSkipPath(e.path)) continue;
        if (ctx.abort_check != null and ctx.abort_check.?()) {
            return .{ .content = std.fmt.allocPrint(ctx.alloc, "Operation aborted", .{}) catch "", .is_error = true };
        }
        const target = if (match_full) e.path else e.basename;
        if (!match.globMatch(pattern, target)) continue;
        blk: {
            const rel = toPosix(ctx.alloc, e.path) catch break :blk;
            defer ctx.alloc.free(rel);
            if (out.items.len > 0) out.append('\n') catch break :blk;
            out.appendSlice(rel) catch break :blk;
        }
        count += 1;
        if (count >= effective_limit) limit_reached = true;
    }

    if (count == 0) {
        return .{ .content = std.fmt.allocPrint(ctx.alloc, "No files found matching pattern", .{}) catch "", .is_error = false };
    }

    const trunc = truncate.truncateHeadWith(ctx.alloc, out.items, std.math.maxInt(usize), truncate.DEFAULT_MAX_BYTES) catch
        return err(ctx.alloc, "error: oom");
    var final = std.array_list.Managed(u8).init(ctx.alloc);
    defer final.deinit();
    final.appendSlice(trunc.content) catch return err(ctx.alloc, "error: oom");
    ctx.alloc.free(trunc.content);

    var first_notice = true;
    if (limit_reached) {
        const n = std.fmt.allocPrint(ctx.alloc, "{d} results limit reached. Use limit={d} for more, or refine pattern", .{ effective_limit, effective_limit * 2 }) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (trunc.truncated) {
        var size_buf: [16]u8 = undefined;
        const size_len = truncate.formatSize(&size_buf, trunc.total_bytes);
        const n = std.fmt.allocPrint(ctx.alloc, "{s} limit reached", .{size_buf[0..size_len]}) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (!first_notice) final.appendSlice("]") catch return err(ctx.alloc, "error: oom");
    const content = final.toOwnedSlice() catch return err(ctx.alloc, "error: oom");
    return .{ .content = content, .is_error = false };
}

// ── ls ──────────────────────────────────────────────────────────────

const LS_DEFAULT_LIMIT = 500;

const lsParams = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory to list (default: current directory)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of entries to return (default: 500)\"}},\"required\":[]}";

const lsDescription = std.fmt.comptimePrint(
    "List directory contents, sorted alphabetically (case-insensitive), with '/' suffix for directories. Includes dotfiles. Truncated to {d} entries or {d}KB (whichever first).",
    .{ 500, truncate.DEFAULT_MAX_BYTES / 1024 });

pub fn registerLs(registry: *Registry) !void {
    try registry.register(.{
        .name = "ls",
        .description = lsDescription,
        .parameters_json = lsParams,
        .execute = executeLs,
    });
}

const LsEntry = struct {
    name: []const u8,
    is_dir: bool,
};

fn lsLessThan(ctx: void, a: LsEntry, b: LsEntry) bool {
    _ = ctx;
    const n = @min(a.name.len, b.name.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a.name[i]);
        const cb = std.ascii.toLower(b.name[i]);
        if (ca != cb) return ca < cb;
    }
    return a.name.len < b.name.len;
}

fn executeLs(args_json: []const u8, ctx: *ExecutionContext) ToolResult {
    var parsed_args = parseArgs(args_json, ctx.alloc) orelse
        return err(ctx.alloc, "error: invalid JSON");
    defer parsed_args.deinit();
    const obj = parsed_args.value;
    const path = getStr(obj, "path") orelse ".";
    const limit_n = getNum(obj, "limit");
    const effective_limit: usize = if (limit_n == 0) LS_DEFAULT_LIMIT else limit_n;

    const dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |e| {
        return .{ .content = std.fmt.allocPrint(ctx.alloc, "error: {s}", .{@errorName(e)}) catch "", .is_error = true };
    };
    defer dir.close(ctx.io);

    var entries = std.array_list.Managed(LsEntry).init(ctx.alloc);
    defer entries.deinit();
    var it = std.Io.Dir.iterate(dir);
    while (true) {
        const entry = it.next(ctx.io) catch break;
        if (entry == null) break;
        const e = entry.?;
        const name = ctx.alloc.dupe(u8, e.name) catch return err(ctx.alloc, "error: oom");
        entries.append(.{ .name = name, .is_dir = e.kind == .directory }) catch {
            ctx.alloc.free(name);
            return err(ctx.alloc, "error: oom");
        };
    }

    std.mem.sort(LsEntry, entries.items, {}, lsLessThan);

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();
    var count: usize = 0;
    var limit_reached = false;
    for (entries.items) |e| {
        if (count >= effective_limit) {
            limit_reached = true;
            break;
        }
        if (out.items.len > 0) out.append('\n') catch return err(ctx.alloc, "error: oom");
        out.appendSlice(e.name) catch return err(ctx.alloc, "error: oom");
        if (e.is_dir) out.append('/') catch return err(ctx.alloc, "error: oom");
        count += 1;
    }
    // `out` now owns copies of every name we emitted; free the entry names.
    for (entries.items) |e| ctx.alloc.free(e.name);

    if (count == 0) {
        return .{ .content = std.fmt.allocPrint(ctx.alloc, "(empty directory)", .{}) catch "", .is_error = false };
    }

    const trunc = truncate.truncateHeadWith(ctx.alloc, out.items, std.math.maxInt(usize), truncate.DEFAULT_MAX_BYTES) catch
        return err(ctx.alloc, "error: oom");
    var final = std.array_list.Managed(u8).init(ctx.alloc);
    defer final.deinit();
    final.appendSlice(trunc.content) catch return err(ctx.alloc, "error: oom");
    ctx.alloc.free(trunc.content);

    var first_notice = true;
    if (limit_reached) {
        const n = std.fmt.allocPrint(ctx.alloc, "{d} entries limit reached. Use limit={d} for more", .{ effective_limit, effective_limit * 2 }) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (trunc.truncated) {
        var size_buf: [16]u8 = undefined;
        const size_len = truncate.formatSize(&size_buf, trunc.total_bytes);
        const n = std.fmt.allocPrint(ctx.alloc, "{s} limit reached", .{size_buf[0..size_len]}) catch "";
        appendNotice(&final, ctx.alloc, &first_notice, n);
        ctx.alloc.free(n);
    }
    if (!first_notice) final.appendSlice("]") catch return err(ctx.alloc, "error: oom");
    const content = final.toOwnedSlice() catch return err(ctx.alloc, "error: oom");
    return .{ .content = content, .is_error = false };
}

// ── Register all ────────────────────────────────────────────────────

const findParams = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'\"},\"path\":{\"type\":\"string\",\"description\":\"Directory to search in (default: current directory)\"},\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of results (default: 1000)\"}},\"required\":[\"pattern\"]}";

const findDescription = std.fmt.comptimePrint(
    "Find files by glob pattern (*, **, ?, [...]). Returns matching file paths relative to the search directory (skips node_modules/.git/etc). Truncated to {d} results or {d}KB (whichever first).",
    .{ 1000, truncate.DEFAULT_MAX_BYTES / 1024 });

pub fn registerFind(registry: *Registry) !void {
    try registry.register(.{
        .name = "find",
        .description = findDescription,
        .parameters_json = findParams,
        .execute = executeFind,
    });
}

pub fn registerAll(registry: *Registry) !void {
    try registerBash(registry);
    try registerRead(registry);
    try registerWrite(registry);
    try registerEdit(registry);
    try registerGrep(registry);
    try registerFind(registry);
    try registerLs(registry);
}
