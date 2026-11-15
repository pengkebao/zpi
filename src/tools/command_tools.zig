//! Phase I1 — Command tools: shell commands declared in settings.json and
//! exposed to the model as callable tools (pi's `customTools` subset —
//! pi's come from TypeScript extensions; zpi's are declarative because
//! there is no embedded interpreter).
//!
//! settings.json / .pi/settings.json (project-trust gated):
//! {
//!   "commandTools": [
//!     { "name": "deploy",
//!       "command": "bash scripts/deploy.sh",
//!       "description": "Deploy the app (args: {target})", 
//!       "schema": { "type": "object", "properties": { "target": { "type": "string" } } } }
//!   ]
//! }
//!
//! Protocol: the tool's JSON arguments are piped to the command's stdin;
//! stdout is the result text (4KB cap); nonzero exit => is_error with
//! stderr appended.

const std = @import("std");
const registry = @import("registry.zig");

pub const CommandTool = struct {
    name: []u8,
    command: []u8,
    description: []u8,
    schema_json: []u8,
};

pub fn freeAll(alloc: std.mem.Allocator, tools: []CommandTool) void {
    for (tools) |*t| {
        alloc.free(t.name);
        alloc.free(t.command);
        alloc.free(t.description);
        alloc.free(t.schema_json);
    }
    if (tools.len > 0) alloc.free(tools);
}

const DEFAULT_SCHEMA = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";

/// Parse the "commandTools" array from a parsed settings object.
pub fn parseSettings(alloc: std.mem.Allocator, root: std.json.ObjectMap) []CommandTool {
    var list = std.array_list.Managed(CommandTool).init(alloc);
    const v = root.get("commandTools") orelse return list.toOwnedSlice() catch &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return list.toOwnedSlice() catch &.{},
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_v = obj.get("name") orelse continue;
        const cmd_v = obj.get("command") orelse continue;
        const name = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        const command = switch (cmd_v) {
            .string => |s| s,
            else => continue,
        };
        // Name must be a valid tool name ([A-Za-z0-9_], like MCP's
        // makeToolName sanitize rule); invalid entries are skipped entirely.
        if (name.len == 0) continue;
        var name_ok = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                name_ok = false;
                break;
            }
        }
        if (!name_ok) continue;
        var description: []const u8 = "";
        if (obj.get("description")) |dv| {
            switch (dv) {
                .string => |s| description = s,
                else => {},
            }
        }
        var schema_json: []const u8 = DEFAULT_SCHEMA;
        if (obj.get("schema")) |sv| {
            schema_json = std.json.Stringify.valueAlloc(alloc, sv, .{}) catch DEFAULT_SCHEMA;
        }
        list.append(.{
            .name = alloc.dupe(u8, name) catch continue,
            .command = alloc.dupe(u8, command) catch {
                alloc.free(list.items[list.items.len - 1].name);
                continue;
            },
            .description = alloc.dupe(u8, description) catch {
                alloc.free(list.items[list.items.len - 1].name);
                alloc.free(list.items[list.items.len - 1].command);
                continue;
            },
            .schema_json = alloc.dupe(u8, schema_json) catch {
                const last = list.items[list.items.len - 1];
                alloc.free(last.name);
                alloc.free(last.command);
                alloc.free(last.description);
                continue;
            },
        }) catch {};
    }
    return list.toOwnedSlice() catch &.{};
}

// ---- global registry (the executor resolves the definition by name) ----

var g_tools: []CommandTool = &.{};

pub fn setGlobal(tools: []CommandTool) void {
    g_tools = tools;
}

pub fn getGlobal() []CommandTool {
    return g_tools;
}

/// Registry `execute` callback: pipe the JSON args to the declared command's
/// stdin; stdout (capped) is the result; nonzero exit => error with stderr.
pub fn execute(tool: *const registry.Tool, args_json: []const u8, ctx: *registry.ExecutionContext) registry.ToolResult {
    const alloc = ctx.alloc;
    const io = ctx.io;
    for (g_tools) |*def| {
        if (!std.mem.eql(u8, def.name, tool.name)) continue;
        var argv = [_][]const u8{ "/bin/sh", "-c", def.command };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = ctx.cwd },
        }) catch {
            return .{ .content = std.fmt.allocPrint(alloc, "command tool '{s}': spawn failed", .{def.name}) catch "", .is_error = true };
        };
        var stdin = child.stdin orelse {
            child.kill(io);
            return .{ .content = "spawn: no stdin", .is_error = true };
        };
        std.Io.File.writeStreamingAll(stdin, io, args_json) catch {};
        stdin.close(io);
        child.stdin = null;
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(alloc, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();
        _ = mr.fill(0, .{ .duration = .{ .raw = .fromSeconds(120), .clock = .real } }) catch {
            child.kill(io);
            mr.fill(0, .none) catch {};
        };
        child.stdout = null;
        child.stderr = null;
        const term = child.wait(io) catch {
            return .{ .content = "command tool: wait failed", .is_error = true };
        };
        const code: i32 = switch (term) {
            .exited => |c| @intCast(c),
            else => -3,
        };
        const out_text = mr.reader(0).buffered();
        const err_text = mr.reader(1).buffered();
        const out_take = @min(out_text.len, 4096);
        const out_slice = alloc.dupe(u8, out_text[0..out_take]) catch "";
        if (code == 0) {
            return .{ .content = out_slice, .is_error = false };
        }
        return .{
            .content = std.fmt.allocPrint(alloc, "command tool '{s}' exited {d}\nstdout: {s}\nstderr: {s}", .{
                def.name, code, out_slice, err_text[0..@min(err_text.len, 1024)],
            }) catch out_slice,
            .is_error = true,
        };
    }
    return .{ .content = "command tool definition vanished", .is_error = true };
}

// ---- tests ----

const testing = std.testing;

test "parseSettings validates names and fills defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\{ "commandTools": [
        \\  { "name": "deploy", "command": "bash deploy.sh", "description": "Deploy the app",
        \\    "schema": { "type": "object", "properties": { "target": { "type": "string" } } } },
        \\  { "name": "bad name", "command": "x" },
        \\  { "name": "no_cmd" }
        \\] }
    ;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch unreachable;
    defer parsed.deinit();
    const root = parsed.value.object;
    const tools = parseSettings(alloc, root);
    // "bad name" (space) and "no_cmd" (no command) are skipped.
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("deploy", tools[0].name);
    try testing.expect(std.mem.indexOf(u8, tools[0].schema_json, "target") != null);
    freeAll(alloc, tools);
}
