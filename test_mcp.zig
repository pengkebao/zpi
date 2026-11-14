//! Unit tests for the MCP client (config parsing + tool-name/schema/result
//! parsing). The live stdio handshake is covered by the E2E harness.

const std = @import("std");
const mcp = @import("src/core/mcp.zig");

test "makeToolName sanitizes" {
    const alloc = std.testing.allocator;
    const a = try mcp.makeToolName(alloc, "my-server", "get_weather");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("mcp__my_server__get_weather", a);
    const b = try mcp.makeToolName(alloc, "srv", "a/b.c-d");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("mcp__srv__a_b_c_d", b);
}

test "parseTools builds owned entries" {
    const alloc = std.testing.allocator;
    const result_json =
        "{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo back\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}, {\"name\":\"no-desc\",\"inputSchema\":{\"type\":\"object\"}}]}";
    var tools = try mcp.parseTools(alloc, "mock", result_json);
    defer mcp.freeTools(alloc, &tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("mcp__mock__echo", tools[0].full_name);
    try std.testing.expectEqualStrings("echo", tools[0].raw_name);
    try std.testing.expectEqualStrings("Echo back", tools[0].description);
    try std.testing.expect(std.mem.indexOf(u8, tools[0].input_schema, "text") != null);
    try std.testing.expectEqualStrings("mcp__mock__no_desc", tools[1].full_name);
    try std.testing.expectEqualStrings("", tools[1].description);
    try std.testing.expect(std.mem.indexOf(u8, tools[1].input_schema, "object") != null);
}

test "parseTools empty" {
    const alloc = std.testing.allocator;
    var tools = try mcp.parseTools(alloc, "mock", "{\"tools\":[]}");
    defer mcp.freeTools(alloc, &tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
    // Malformed → empty, no crash.
    var tools2 = try mcp.parseTools(alloc, "mock", "not json");
    defer mcp.freeTools(alloc, &tools2);
    try std.testing.expectEqual(@as(usize, 0), tools2.len);
}

test "parseToolCallResult text + isError" {
    const alloc = std.testing.allocator;
    const ok = mcp.parseToolCallResult(alloc,
        "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\"world\"}],\"isError\":false}" );
    try std.testing.expectEqualStrings("hello\nworld", ok.content);
    try std.testing.expect(!ok.is_error);
    alloc.free(ok.content);

    const err = mcp.parseToolCallResult(alloc,
        "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}" );
    try std.testing.expectEqualStrings("boom", err.content);
    try std.testing.expect(err.is_error);
    alloc.free(err.content);

    const empty = mcp.parseToolCallResult(alloc, "{\"content\":[]}");
    try std.testing.expectEqualStrings("(no output)", empty.content);
    alloc.free(empty.content);
}

test "loadConfig merges user + project (project overrides)" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "/tmp/rpi-mcp-cfg-test";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // user mcp.json: two servers.
    const user_dir = try std.fs.path.join(alloc, &.{ root, "agent" });
    defer alloc.free(user_dir);
    try std.Io.Dir.cwd().createDirPath(io, user_dir);
    const user_path = try std.fs.path.join(alloc, &.{ user_dir, "mcp.json" });
    defer alloc.free(user_path);
    const user_json =
        \\{"mcpServers":{
    \\  "alpha":{"command":"python3","args":["a.py"],"description":"user alpha"},
    \\  "beta":{"command":"python3","args":["b.py"],"enabled":true}
    \\}}
    ;
    try writeStr(io, user_path, user_json);

    // project mcp.json: overrides beta (partial: only enabled=false) + adds gamma.
    const proj_dir = try std.fs.path.join(alloc, &.{ root, "proj", ".pi" });
    defer alloc.free(proj_dir);
    try std.Io.Dir.cwd().createDirPath(io, proj_dir);
    const proj_path = try std.fs.path.join(alloc, &.{ proj_dir, "mcp.json" });
    defer alloc.free(proj_path);
    const proj_json =
        \\{"mcpServers":{
    \\  "beta":{"enabled":false},
    \\  "gamma":{"url":"https://example.com/mcp"}
    \\}}
    ;
    try writeStr(io, proj_path, proj_json);

    const cfgs = try mcp.loadConfig(alloc, io, user_path, proj_path);
    defer mcp.freeConfigs(alloc, cfgs);

    // Expect: alpha (user, stdio), beta (project override → disabled), gamma (project, http).
    try std.testing.expectEqual(@as(usize, 3), cfgs.len);
    const alpha = findCfg(cfgs, "alpha") orelse unreachable;
    try std.testing.expectEqualStrings("python3", alpha.command.?);
    try std.testing.expectEqualStrings("user", alpha.source);
    const beta = findCfg(cfgs, "beta") orelse unreachable;
    try std.testing.expect(!beta.enabled); // overridden by project
    try std.testing.expectEqualStrings("project", beta.source);
    const gamma = findCfg(cfgs, "gamma") orelse unreachable;
    try std.testing.expectEqual(mcp.ServerKind.http, gamma.kind);
    try std.testing.expectEqualStrings("https://example.com/mcp", gamma.url.?);
}

test "loadConfig missing files is empty" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cfgs = try mcp.loadConfig(alloc, io, "/nonexistent/user.json", "/nonexistent/proj.json");
    defer mcp.freeConfigs(alloc, cfgs);
    try std.testing.expectEqual(@as(usize, 0), cfgs.len);
}

// ── helpers ──────────────────────────────────────────────────────────

fn findCfg(cfgs: []const mcp.ServerConfig, name: []const u8) ?mcp.ServerConfig {
    for (cfgs) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

fn writeStr(io: std.Io, path: []const u8, content: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    try f.writePositionalAll(io, content, 0);
    f.close(io);
}
