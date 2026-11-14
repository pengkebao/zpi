//! MCP (Model Context Protocol) client — stdio transport.
//!
//! Reads `mcp.json` (user `<agent-dir>/mcp.json` + project `.pi/mcp.json`,
//! project overrides a user entry with the same name), spawns every enabled
//! stdio server, performs the JSON-RPC handshake
//! (initialize → notifications/initialized → tools/list) and registers each
//! server tool as `mcp__<server>__<tool>`. `tools/call` is invoked
//! synchronously against the server's stdin/stdout (newline-delimited JSON).
//!
//! Scope of this module (PLAN 10): stdio servers + tools. Streamable HTTP +
//! OAuth, resources, and exposure modes are deferred.

const std = @import("std");
const tools = @import("../tools/registry.zig");
const Io = std.Io;
const File = std.Io.File;
const process = std.process;

/// A single key/value pair from a server's `env` config block.
pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const ServerKind = enum { stdio, http };

/// One server entry from mcp.json (after user/project merge).
pub const ServerConfig = struct {
    name: []const u8,
    kind: ServerKind = .stdio,
    command: ?[]const u8 = null,
    args: []const []const u8 = &[_][]const u8{},
    env: []const EnvVar = &[_]EnvVar{},
    cwd: ?[]const u8 = null,
    url: ?[]const u8 = null,
    enabled: bool = true,
    description: ?[]const u8 = null,
    /// "user" or "project" — the file that defined (or overrode) this entry.
    source: []const u8 = "user",
};

/// A tool advertised by a connected server.
pub const McpTool = struct {
    /// Full registry name: `mcp__<server>__<tool>`.
    full_name: []const u8,
    /// The tool name exactly as the server reported it (used in tools/call).
    raw_name: []const u8,
    description: []const u8,
    /// JSON schema object for the tool's arguments.
    input_schema: []const u8,
};

/// A live MCP server (its child process + discovered tools).
pub const Server = struct {
    alloc: std.mem.Allocator,
    io: Io,
    name: []const u8,
    kind: ServerKind,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    description: ?[]const u8 = null,
    source: []const u8 = "user",
    enabled: bool = true,

    child: ?process.Child = null,
    stdin: ?File = null,
    stdout: ?File = null,
    stderr: ?File = null,

    next_id: u64 = 1,
    /// Partial (unterminated) line carry-over; always an owned buffer or null.
    line_buf: ?[]u8 = null,
    stderr_tail: std.array_list.Managed(u8),

    connected: bool = false,
    error_msg: ?[]const u8 = null,
    /// Last MCP `error` response message (transient, replaced per request).
    last_error: ?[]const u8 = null,
    /// "name (version)" from the initialize response, for /mcp display.
    server_info: ?[]const u8 = null,
    tools: []McpTool = &[_]McpTool{},

    fn setLastError(self: *Server, msg: []const u8) void {
        if (self.last_error) |old| self.alloc.free(old);
        self.last_error = msg;
    }

    pub fn deinit(self: *Server) void {
        if (self.stdin) |f| File.close(f, self.io);
        if (self.stdout) |f| File.close(f, self.io);
        if (self.stderr) |f| File.close(f, self.io);
        if (self.child) |*c| c.kill(self.io);
        if (self.line_buf) |b| self.alloc.free(b);
        self.stderr_tail.deinit();
        for (self.tools) |t| {
            self.alloc.free(t.full_name);
            self.alloc.free(t.raw_name);
            self.alloc.free(t.description);
            self.alloc.free(t.input_schema);
        }
        self.alloc.free(self.tools);
        if (self.error_msg) |e| self.alloc.free(e);
        if (self.last_error) |e| self.alloc.free(e);
        if (self.server_info) |s| self.alloc.free(s);
        self.alloc.free(self.name);
    }
};

/// Owns all configured servers.
pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: Io,
    servers: std.array_list.Managed(*Server),

    /// Global handle so the shared MCP tool executor (which only receives its
    /// own Tool name) can reach the manager. Single-process, one manager.
    var g: ?*Manager = null;
    pub fn setGlobal(m: ?*Manager) void { g = m; }
    pub fn getGlobal() ?*Manager { return g; }

    pub fn init(alloc: std.mem.Allocator, io: Io) Manager {
        return .{ .alloc = alloc, .io = io, .servers = .init(alloc) };
    }

    pub fn deinit(self: *Manager) void {
        for (self.servers.items) |s| {
            s.deinit();
            self.alloc.destroy(s);
        }
        self.alloc.free(self.servers.items);
        self.servers.deinit();
    }

    /// Connect every enabled stdio server (in background semantics: we do it
    /// synchronously here, which is fine because it happens at startup).
    /// HTTP servers are recorded but not connected (deferred).
    pub fn connectAll(self: *Manager, cfgs: []const ServerConfig) void {
        for (cfgs) |cfg| {
            // Each Server is heap-allocated so the pointers stored in
            // self.servers stay valid for the whole session.
            const srv = self.alloc.create(Server) catch continue;
            srv.* = .{
                .alloc = self.alloc,
                .io = self.io,
                .name = self.alloc.dupe(u8, cfg.name) catch {
                    self.alloc.destroy(srv);
                    continue;
                },
                .kind = cfg.kind,
                .command = if (cfg.command) |c| self.alloc.dupe(u8, c) catch null else null,
                .url = if (cfg.url) |u| self.alloc.dupe(u8, u) catch null else null,
                .description = if (cfg.description) |d| self.alloc.dupe(u8, d) catch null else null,
                .source = self.alloc.dupe(u8, cfg.source) catch "user",
                .enabled = cfg.enabled,
                .stderr_tail = .init(self.alloc),
            };
            self.servers.append(srv) catch {
                srv.deinit();
                self.alloc.destroy(srv);
                continue;
            };
            if (!cfg.enabled) {
                srv.error_msg = self.alloc.dupe(u8, "disabled") catch null;
                continue;
            }
            switch (cfg.kind) {
                .stdio => connectStdio(srv, cfg) catch |e| {
                    srv.error_msg = std.fmt.allocPrint(self.alloc, "{s}", .{@errorName(e)}) catch null;
                },
                .http => {
                    // Deferred: recorded but not connected in this build.
                    srv.error_msg = self.alloc.dupe(u8, "http transport not supported yet") catch null;
                },
            }
        }
    }

    pub fn findByName(self: *Manager, name: []const u8) ?*Server {
        for (self.servers.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Register every connected server's tools into `registry` as
    /// `mcp__<server>__<tool>`. Returns the number registered.
    pub fn registerTools(self: *Manager, registry: *tools.Registry) usize {
        var count: usize = 0;
        for (self.servers.items) |srv| {
            if (!srv.connected) continue;
            for (srv.tools) |t| {
                registry.register(.{
                    .name = t.full_name,
                    .description = t.description,
                    .parameters_json = t.input_schema,
                    .execute = executeMcpTool,
                }) catch continue;
                count += 1;
            }
        }
        return count;
    }
};

// ── stdio connection + JSON-RPC ──────────────────────────────────────

fn connectStdio(self: *Server, cfg: ServerConfig) !void {
    const command = cfg.command orelse return error.NoCommand;

    // argv: [command, ...args]
    var argv = std.array_list.Managed([]const u8).init(self.alloc);
    defer argv.deinit();
    try argv.append(command);
    for (cfg.args) |a| try argv.append(a);

    var child = process.spawn(self.io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // v1: inherit the parent environment. `env` overrides are a follow-up.
        .environ_map = null,
    }) catch return error.SpawnFailed;

    const stdin = child.stdin orelse {
        child.kill(self.io);
        return error.NoStdin;
    };
    const stdout = child.stdout orelse {
        child.kill(self.io);
        return error.NoStdout;
    };
    const stderr = child.stderr orelse {
        child.kill(self.io);
        return error.NoStderr;
    };

    self.child = child;
    self.stdin = stdin;
    self.stdout = stdout;
    self.stderr = stderr;

    // 1) initialize
    const init_params = "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"rpi\",\"version\":\"0.1.0\"}}";
    const init_res = request(self, "initialize", init_params) catch |e| {
        teardownProcess(self);
        return e;
    };
    // Capture serverInfo for /mcp display.
    if (parseServerInfo(self.alloc, init_res)) |info| {
        self.server_info = info;
    }
    self.alloc.free(init_res);

    // 2) notifications/initialized (no id, no response)
    notify(self, "notifications/initialized", "{}") catch {
        teardownProcess(self);
        return error.HandshakeFailed;
    };

    // 3) tools/list
    const list_res = request(self, "tools/list", "{}") catch |e| {
        teardownProcess(self);
        return e;
    };
    defer self.alloc.free(list_res);
    self.tools = parseTools(self.alloc, self.name, list_res) catch &[_]McpTool{};
    self.connected = true;
}

fn teardownProcess(self: *Server) void {
    if (self.stdin) |f| File.close(f, self.io);
    if (self.stdout) |f| File.close(f, self.io);
    if (self.stderr) |f| File.close(f, self.io);
    if (self.child) |*c| c.kill(self.io);
    self.stdin = null;
    self.stdout = null;
    self.stderr = null;
    self.child = null;
    self.connected = false;
}

/// Send a JSON-RPC request and block until the matching response arrives.
/// Returns the `result` field re-serialized as a JSON string (owned).
fn request(self: *Server, method: []const u8, params_json: []const u8) ![]u8 {
    const stdin = self.stdin orelse return error.Disconnected;
    const stdout = self.stdout orelse return error.Disconnected;

    const id = self.next_id;
    self.next_id += 1;
    const req = std.fmt.allocPrint(self.alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
        .{ id, method, params_json }) catch return error.OutOfMemory;
    defer self.alloc.free(req);

    File.writeStreamingAll(stdin, self.io, req) catch return error.WriteFailed;
    File.writeStreamingAll(stdin, self.io, "\n") catch return error.WriteFailed;

    // Read lines until we get a response whose id matches.
    while (true) {
        const line = readLine(self, stdout) orelse return error.Eof;
        defer self.alloc.free(line);
        if (line.len == 0) continue;
        var p = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch continue;
        defer p.deinit();
        const obj = switch (p.value) {
            .object => |o| o,
            else => continue,
        };
        const resp_id = switch (obj.get("id") orelse continue) {
            .integer => |n| n,
            .float => |n| @as(i64, @intFromFloat(n)),
            else => continue,
        };
        if (@as(i64, @intCast(id)) != resp_id) continue;
        if (obj.get("error")) |errv| {
            const msg = extractString(errv, "message") orelse "unknown MCP error";
            self.setLastError(self.alloc.dupe(u8, msg) catch "unknown MCP error");
            return error.McpError;
        }
        const result = obj.get("result") orelse return error.NoResult;
        return std.json.Stringify.valueAlloc(self.alloc, result, .{});
    }
}

/// Send a JSON-RPC notification (no id, no response expected).
fn notify(self: *Server, method: []const u8, params_json: []const u8) !void {
    const stdin = self.stdin orelse return error.Disconnected;
    const req = std.fmt.allocPrint(self.alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json }) catch return error.OutOfMemory;
    defer self.alloc.free(req);
    File.writeStreamingAll(stdin, self.io, req) catch return error.WriteFailed;
    File.writeStreamingAll(stdin, self.io, "\n") catch return error.WriteFailed;
}

/// Read the next complete newline-terminated line from `stdout` (without the
/// newline). Returns an owned copy (caller frees) or null at EOF.
fn readLine(self: *Server, stdout: File) ?[]const u8 {
    while (true) {
        const cur = self.line_buf orelse &[_]u8{};
        if (std.mem.indexOfScalar(u8, cur, '\n')) |idx| {
            const line_owned = self.alloc.dupe(u8, cur[0..idx]) catch return null;
            // Compact: free the current buffer, allocate one holding the tail
            // after the newline.
            if (self.line_buf) |b| self.alloc.free(b);
            const tail_len = cur.len - idx - 1;
            self.line_buf = self.alloc.alloc(u8, tail_len) catch {
                self.alloc.free(line_owned);
                return null;
            };
            @memcpy(self.line_buf.?, cur[idx + 1 ..]);
            return line_owned;
        }
        var chunk: [8192]u8 = undefined;
        const n = stdout.readStreaming(self.io, &.{ &chunk }) catch return null;
        if (n == 0) {
            if (cur.len > 0) {
                const line_owned = self.alloc.dupe(u8, cur) catch return null;
                if (self.line_buf) |b| self.alloc.free(b);
                self.line_buf = null;
                return line_owned;
            }
            return null;
        }
        // Grow the carry buffer to hold the existing tail plus the new chunk.
        const newbuf = self.alloc.alloc(u8, cur.len + n) catch return null;
        @memcpy(newbuf[0..cur.len], cur);
        @memcpy(newbuf[cur.len ..], chunk[0..n]);
        if (self.line_buf) |b| self.alloc.free(b);
        self.line_buf = newbuf;
    }
}

// ── JSON helpers ─────────────────────────────────────────────────────

fn strVal(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolVal(v: ?std.json.Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn extractString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn parseServerInfo(alloc: std.mem.Allocator, result_json: []const u8) ?[]u8 {
    var p = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch return null;
    defer p.deinit();
    const obj = switch (p.value) {
        .object => |o| o,
        else => return null,
    };
    const info = switch (obj.get("serverInfo") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const name = switch (info.get("name") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const version = switch (info.get("version") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return std.fmt.allocPrint(alloc, "{s} ({s})", .{ name, version }) catch return null;
}

/// Parse the `tools/list` result into owned McpTool entries.
pub fn parseTools(alloc: std.mem.Allocator, server_name: []const u8, result_json: []const u8) ![]McpTool {
    var p = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch return &[_]McpTool{};
    defer p.deinit();
    const obj = switch (p.value) {
        .object => |o| o,
        else => return &[_]McpTool{},
    };
    const tools_arr = switch (obj.get("tools") orelse return &[_]McpTool{}) {
        .array => |a| a,
        else => return &[_]McpTool{},
    };
    var out = std.array_list.Managed(McpTool).init(alloc);
    defer out.deinit();
    for (tools_arr.items) |tv| {
        const to = switch (tv) {
            .object => |o| o,
            else => continue,
        };
        const raw = switch (to.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const desc = strVal(to.get("description")) orelse "";
        // Re-serialize the schema to a JSON object string (default {}). Always
        // owned: valueAlloc on success, else a duped "{}".
        var schema_owned: ?[]u8 = null;
        if (to.get("inputSchema")) |sv| {
            schema_owned = std.json.Stringify.valueAlloc(alloc, sv, .{}) catch null;
        }
        if (schema_owned == null) {
            schema_owned = alloc.dupe(u8, "{}") catch continue;
        }

        const full_name = makeToolName(alloc, server_name, raw) catch continue;
        const raw_name = alloc.dupe(u8, raw) catch continue;
        const desc_owned = alloc.dupe(u8, desc) catch continue;
        out.append(McpTool{
            .full_name = full_name,
            .raw_name = raw_name,
            .description = desc_owned,
            .input_schema = schema_owned.?,
        }) catch continue;
    }
    return try out.toOwnedSlice();
}

/// Build `mcp__<server>__<tool>`, sanitizing non [A-Za-z0-9_] to `_`.
pub fn makeToolName(alloc: std.mem.Allocator, server: []const u8, tool: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    out.appendSlice("mcp__") catch return error.OutOfMemory;
    try appendSanitized(&out, server);
    out.appendSlice("__") catch return error.OutOfMemory;
    try appendSanitized(&out, tool);
    return out.toOwnedSlice();
}

fn appendSanitized(out: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        out.append(if (ok) c else '_') catch return error.OutOfMemory;
    }
}

// ── tool execution ───────────────────────────────────────────────────

/// Shared executor for every MCP tool. `tool.name` is `mcp__<server>__<tool>`;
/// the server name is the segment between the first two `__`.
fn executeMcpTool(tool: *const tools.Tool, args_json: []const u8, ctx: *tools.ExecutionContext) tools.ToolResult {
    const mgr = Manager.getGlobal() orelse
        return err0(ctx.alloc, "error: MCP not available");
    // Parse server name: mcp__<server>__<tool>
    const n = tool.name;
    if (std.mem.indexOfScalar(u8, n, '_') == null) return err0(ctx.alloc, "error: bad MCP tool name");
    const after_prefix = n[5..]; // strip "mcp__"
    const second = std.mem.indexOfScalar(u8, after_prefix, '_') orelse return err0(ctx.alloc, "error: bad MCP tool name");
    const server_name = after_prefix[0..second];
    const srv = mgr.findByName(server_name) orelse
        return err0(ctx.alloc, "error: unknown MCP server");
    if (!srv.connected)
        return err0(ctx.alloc, "error: MCP server not connected");

    // The raw tool name is the sanitized tail; but the server expects the
    // ORIGINAL name. We stored it per tool — look it up by full_name.
    var raw: ?[]const u8 = null;
    for (srv.tools) |t| {
        if (std.mem.eql(u8, t.full_name, tool.name)) {
            raw = t.raw_name;
            break;
        }
    }
    const raw_name = raw orelse return err0(ctx.alloc, "error: unknown MCP tool");

    // Build tools/call params: {"name":<raw>,"arguments":<args_json>}.
    const escaped = jsonEscape(ctx.alloc, raw_name);
    defer ctx.alloc.free(escaped);
    const params = std.fmt.allocPrint(ctx.alloc,
        "{{\"name\":\"{s}\",\"arguments\":{s}}}",
        .{ escaped, args_json }) catch return err0(ctx.alloc, "error: oom");
    defer ctx.alloc.free(params);

    const result_json = request(srv, "tools/call", params) catch |e| {
        const detail = if (e == error.McpError) srv.last_error orelse "tool error" else @errorName(e);
        return err(ctx.alloc, "error: MCP call failed: {s}", .{detail});
    };
    defer ctx.alloc.free(result_json);

    return parseToolCallResult(ctx.alloc, result_json);
}

/// Escape a string for embedding inside a JSON string literal (returns owned).
fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) []u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice("\\\"") catch {},
            '\\' => out.appendSlice("\\\\") catch {},
            '\n' => out.appendSlice("\\n") catch {},
            '\r' => out.appendSlice("\\r") catch {},
            '\t' => out.appendSlice("\\t") catch {},
            else => out.append(c) catch {},
        }
    }
    return out.toOwnedSlice() catch alloc.dupe(u8, s) catch "";
}

/// Parse a tools/call result into a ToolResult. MCP result:
/// `{"content":[{"type":"text","text":"..."},...],"isError":bool}`.
pub fn parseToolCallResult(alloc: std.mem.Allocator, result_json: []const u8) tools.ToolResult {
    var p = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch
        return err0(alloc, "error: invalid MCP result");
    defer p.deinit();
    const obj = switch (p.value) {
        .object => |o| o,
        else => return err0(alloc, "error: invalid MCP result"),
    };
    const is_error = switch (obj.get("isError") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    var text = std.array_list.Managed(u8).init(alloc);
    defer text.deinit();
    const content_val = obj.get("content") orelse return err0(alloc, "error: no MCP content");
    const content = switch (content_val) {
        .array => |a| a,
        else => return err0(alloc, "error: no MCP content"),
    };
    var first = true;
    for (content.items) |cv| {
        const co = switch (cv) {
            .object => |o| o,
            else => continue,
        };
        const typ = switch (co.get("type") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, typ, "text")) continue;
        const t = switch (co.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!first) text.append('\n') catch return err0(alloc, "error: oom");
        text.appendSlice(t) catch return err0(alloc, "error: oom");
        first = false;
    }
    const out = text.toOwnedSlice() catch return err0(alloc, "error: oom");
    if (out.len == 0) {
        alloc.free(out);
        return .{ .content = alloc.dupe(u8, "(no output)") catch "", .is_error = is_error };
    }
    return .{ .content = out, .is_error = is_error };
}

fn err(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) tools.ToolResult {
    return .{ .content = std.fmt.allocPrint(alloc, fmt, args) catch "", .is_error = true };
}

fn err0(alloc: std.mem.Allocator, msg: []const u8) tools.ToolResult {
    return .{ .content = alloc.dupe(u8, msg) catch "", .is_error = true };
}

// ── config loading ───────────────────────────────────────────────────

/// Load and merge mcp.json (user then project). Project entries with the same
/// name replace user entries (a partial project entry keeps the user's
/// command/url and only overrides enabled/description).
pub fn loadConfig(
    alloc: std.mem.Allocator,
    io: Io,
    user_path: []const u8,
    project_path: []const u8,
) ![]ServerConfig {
    var list = std.array_list.Managed(ServerConfig).init(alloc);
    defer list.deinit();

    parseFile(alloc, io, user_path, "user", &list) catch {};
    parseFile(alloc, io, project_path, "project", &list) catch {};

    return try list.toOwnedSlice();
}

fn parseFile(
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    source: []const u8,
    list: *std.array_list.Managed(ServerConfig),
) !void {
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(data);
    var p = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return;
    defer p.deinit();
    const root = switch (p.value) {
        .object => |o| o,
        else => return,
    };
    const servers = switch (root.get("mcpServers") orelse return) {
        .object => |o| o,
        else => return,
    };
    const names = servers.keys();
    for (names) |name| {
        const entry = servers.get(name) orelse continue;
        const cfg = parseEntry(alloc, name, entry, source) catch continue;
        // Project override: if a same-name entry already exists (from user),
        // replace it.
        var replaced = false;
        for (list.items) |*existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                freeConfig(alloc, existing.*);
                existing.* = cfg;
                replaced = true;
                break;
            }
        }
        if (!replaced) list.append(cfg) catch return;
    }
}

fn parseEntry(alloc: std.mem.Allocator, name: []const u8, entry: std.json.Value, source: []const u8) !ServerConfig {
    const o = switch (entry) {
        .object => |o| o,
        else => return error.InvalidEntry,
    };
    var cfg = ServerConfig{ .name = alloc.dupe(u8, name) catch return error.OutOfMemory };
    errdefer freeConfig(alloc, cfg);

    if (strVal(o.get("command"))) |s| {
        cfg.kind = .stdio;
        cfg.command = alloc.dupe(u8, s) catch return error.OutOfMemory;
    }
    if (strVal(o.get("url"))) |s| {
        cfg.kind = .http;
        cfg.url = alloc.dupe(u8, s) catch return error.OutOfMemory;
    }
    if (strVal(o.get("cwd"))) |s| cfg.cwd = alloc.dupe(u8, s) catch return error.OutOfMemory;
    if (strVal(o.get("description"))) |s| cfg.description = alloc.dupe(u8, s) catch return error.OutOfMemory;
    if (boolVal(o.get("enabled"))) |b| cfg.enabled = b;
    if (o.get("args")) |v| {
        const arr = switch (v) {
            .array => |a| a,
            else => null,
        };
        if (arr) |a| {
            var out = std.array_list.Managed([]const u8).init(alloc);
            for (a.items) |item| {
                const s = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                out.append(alloc.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
            }
            cfg.args = out.toOwnedSlice() catch return error.OutOfMemory;
        }
    }
    if (o.get("env")) |v| {
        const eo = switch (v) {
            .object => |o2| o2,
            else => null,
        };
        if (eo) |env_obj| {
            var envs = std.array_list.Managed(EnvVar).init(alloc);
            for (env_obj.keys()) |k| {
                const val = switch (env_obj.get(k) orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                envs.append(.{
                    .key = alloc.dupe(u8, k) catch return error.OutOfMemory,
                    .value = alloc.dupe(u8, val) catch return error.OutOfMemory,
                }) catch return error.OutOfMemory;
            }
            cfg.env = envs.toOwnedSlice() catch return error.OutOfMemory;
        }
    }
    cfg.source = alloc.dupe(u8, source) catch return error.OutOfMemory;
    return cfg;
}

/// Free a `[]McpTool` returned by `parseTools`.
pub fn freeTools(alloc: std.mem.Allocator, tools_list: *[]McpTool) void {
    for (tools_list.*) |t| {
        alloc.free(t.full_name);
        alloc.free(t.raw_name);
        alloc.free(t.description);
        alloc.free(t.input_schema);
    }
    alloc.free(tools_list.*);
}

/// Free a config list (and each entry) returned by `loadConfig`.
pub fn freeConfigs(alloc: std.mem.Allocator, cfgs: []const ServerConfig) void {
    for (cfgs) |c| freeConfig(alloc, c);
    alloc.free(cfgs);
}

fn freeConfig(alloc: std.mem.Allocator, cfg: ServerConfig) void {
    alloc.free(cfg.name);
    if (cfg.command) |c| alloc.free(c);
    for (cfg.args) |a| alloc.free(a);
    alloc.free(cfg.args);
    for (cfg.env) |e| {
        alloc.free(e.key);
        alloc.free(e.value);
    }
    alloc.free(cfg.env);
    if (cfg.cwd) |c| alloc.free(c);
    if (cfg.url) |u| alloc.free(u);
    if (cfg.description) |d| alloc.free(d);
    alloc.free(cfg.source);
}
