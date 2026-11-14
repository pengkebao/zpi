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
    /// HTTP headers (kind == .http); e.g. Authorization.
    headers: []const EnvVar = &[_]EnvVar{},
    cwd: ?[]const u8 = null,
    url: ?[]const u8 = null,
    enabled: bool = true,
    description: ?[]const u8 = null,
    /// Tool exposure: "codemode" (pi default), "deferred", "direct", "hidden".
    /// rpi has no codemode, so codemode/deferred register tools directly; only
    /// "hidden" suppresses registration.
    exposure: ?[]const u8 = null,
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
    exposure: ?[]const u8 = null,
    headers: []const EnvVar = &[_]EnvVar{},
    source: []const u8 = "user",
    enabled: bool = true,

    child: ?process.Child = null,
    stdin: ?File = null,
    stdout: ?File = null,
    stderr: ?File = null,

    /// Streamable HTTP transport (used when kind == .http).
    http_client: std.http.Client,
    /// Mcp-Session-Id returned by the server (echoed on subsequent requests).
    session_id: ?[]const u8 = null,
    /// Bearer token for HTTP auth (from config or mcp-auth.json).
    bearer_token: ?[]const u8 = null,
    /// Pre-built "Bearer <token>" value (owned; lives as long as the server).
    auth_header: ?[]u8 = null,

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
        if (self.exposure) |e| self.alloc.free(e);
        if (self.session_id) |s| self.alloc.free(s);
        if (self.bearer_token) |t| self.alloc.free(t);
        if (self.auth_header) |h| self.alloc.free(h);
        for (self.headers) |h| {
            self.alloc.free(h.key);
            self.alloc.free(h.value);
        }
        self.alloc.free(self.headers);
        std.http.Client.deinit(&self.http_client);
        self.alloc.free(self.name);
    }
};

/// Owns all configured servers.
pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: Io,
    servers: std.array_list.Managed(*Server),
    /// Path to mcp-auth.json (stored bearer tokens for HTTP servers).
    auth_path: ?[]const u8 = null,

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
                .exposure = if (cfg.exposure) |e| self.alloc.dupe(u8, e) catch null else null,
                .headers = dupEnvVars(self.alloc, cfg.headers),
                .source = self.alloc.dupe(u8, cfg.source) catch "user",
                .enabled = cfg.enabled,
                .stderr_tail = .init(self.alloc),
                .http_client = .{ .allocator = self.alloc, .io = self.io },
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
                .http => connectHttp(srv, cfg) catch |e| {
                    srv.error_msg = std.fmt.allocPrint(self.alloc, "{s}", .{@errorName(e)}) catch null;
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
            // "hidden" exposure suppresses the server's tools (pi).
            if (srv.exposure) |e| {
                if (std.mem.eql(u8, e, "hidden")) continue;
            }
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

// ── streamable HTTP connection + JSON-RPC ────────────────────────────

fn connectHttp(self: *Server, cfg: ServerConfig) !void {
    _ = cfg;
    if (self.url == null) return error.NoUrl;
    self.http_client = .{ .allocator = self.alloc, .io = self.io };

    // If no Authorization header is configured, use a stored token (mcp login).
    var has_auth = false;
    for (self.headers) |h| {
        if (std.mem.eql(u8, h.key, "Authorization")) has_auth = true;
    }
    if (!has_auth) {
        if (Manager.getGlobal()) |mgr| {
            if (mgr.auth_path) |ap| {
                if (readAuthToken(self.alloc, self.io, ap, self.name)) |tok| {
                    self.bearer_token = tok;
                    self.auth_header = std.fmt.allocPrint(self.alloc, "Bearer {s}", .{tok}) catch {
                        self.alloc.free(tok);
                        return error.OutOfMemory;
                    };
                }
            }
        }
    }

    // 1) initialize
    const init_params = "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"rpi\",\"version\":\"0.1.0\"}}";
    const init_res = httpRequest(self, "initialize", init_params) catch return;
    if (parseServerInfo(self.alloc, init_res)) |info| {
        self.server_info = info;
    }
    self.alloc.free(init_res);

    // 2) notifications/initialized (no id; the server may open an SSE stream).
    httpNotify(self, "notifications/initialized", "{}") catch return error.HandshakeFailed;

    // 3) tools/list
    const list_res = httpRequest(self, "tools/list", "{}") catch return;
    defer self.alloc.free(list_res);
    self.tools = parseTools(self.alloc, self.name, list_res) catch &[_]McpTool{};
    self.connected = true;
}

/// POST a JSON-RPC request to the streamable HTTP endpoint; returns the
/// `result` re-serialized (owned). Handles application/json and SSE bodies.
fn httpRequest(self: *Server, method: []const u8, params_json: []const u8) ![]u8 {
    const url = self.url orelse return error.NoUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUri;
    const id = self.next_id;
    self.next_id += 1;
    const body = std.fmt.allocPrint(self.alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
        .{ id, method, params_json }) catch return error.OutOfMemory;
    defer self.alloc.free(body);
    return doHttpPost(self, uri, body, id);
}

fn httpNotify(self: *Server, method: []const u8, params_json: []const u8) !void {
    const url = self.url orelse return error.NoUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUri;
    const body = std.fmt.allocPrint(self.alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json }) catch return error.OutOfMemory;
    defer self.alloc.free(body);
    _ = doHttpPostRaw(self, uri, body) catch return error.HttpError;
}

/// Build the request headers (Accept, configured headers, session id).
fn buildHeaders(self: *Server) !std.array_list.Managed(std.http.Header) {
    var extra = std.array_list.Managed(std.http.Header).init(self.alloc);
    errdefer extra.deinit();
    extra.append(.{ .name = "Accept", .value = "application/json, text/event-stream" }) catch return error.OutOfMemory;
    for (self.headers) |h| {
        extra.append(.{ .name = h.key, .value = h.value }) catch return error.OutOfMemory;
    }
    if (self.session_id) |sid| {
        extra.append(.{ .name = "Mcp-Session-Id", .value = sid }) catch return error.OutOfMemory;
    }
    if (self.auth_header) |auth| {
        extra.append(.{ .name = "Authorization", .value = auth }) catch return error.OutOfMemory;
    }
    return extra;
}

/// Read a stored bearer token for `server` from an mcp-auth.json file.
pub fn readAuthToken(alloc: std.mem.Allocator, io: Io, path: []const u8, server: []const u8) ?[]u8 {
    const buf = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(buf);
    var p = std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch return null;
    defer p.deinit();
    const root = switch (p.value) {
        .object => |o| o,
        else => return null,
    };
    const entry = switch (root.get(server) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const tok = switch (entry.get("token") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return alloc.dupe(u8, tok) catch null;
}

const AuthEntry = struct {
    key: []u8,
    json: []u8,
};

/// Read existing mcp-auth.json entries as (key, re-serialized value) pairs.
/// Returns null if the file is missing or unparseable (treated as empty).
fn readAuthEntries(alloc: std.mem.Allocator, io: Io, path: []const u8) ?[]AuthEntry {
    const buf = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(buf);
    const p = std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch return null;
    defer p.deinit();
    const root = switch (p.value) {
        .object => |o| o,
        else => return null,
    };
    var list = std.array_list.Managed(AuthEntry).init(alloc);
    for (root.keys()) |k| {
        const v = root.get(k) orelse continue;
        const ej = std.json.Stringify.valueAlloc(alloc, v, .{}) catch continue;
        const kk = alloc.dupe(u8, k) catch continue;
        list.append(.{ .key = kk, .json = ej }) catch {
            alloc.free(kk);
            alloc.free(ej);
            continue;
        };
    }
    return list.toOwnedSlice() catch return null;
}

fn freeAuthEntries(alloc: std.mem.Allocator, entries: []AuthEntry) void {
    for (entries) |e| {
        alloc.free(e.key);
        alloc.free(e.json);
    }
    alloc.free(entries);
}

/// Store a bearer token for `server` in an mcp-auth.json file (creating or
/// merging). Returns true if a token was previously present (replaced).
pub fn storeAuthToken(alloc: std.mem.Allocator, io: Io, path: []const u8, server: []const u8, token: []const u8) !bool {
    const entries = readAuthEntries(alloc, io, path);
    var replaced = false;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    if (entries) |es| {
        for (es) |e| {
            if (std.mem.eql(u8, e.key, server)) {
                replaced = true;
                continue;
            }
            if (out.items.len > 0) out.append(',') catch return error.OutOfMemory;
            const ne = jsonEscape(alloc, e.key);
            defer alloc.free(ne);
            out.appendSlice("\"") catch return error.OutOfMemory;
            out.appendSlice(ne) catch return error.OutOfMemory;
            out.appendSlice("\":") catch return error.OutOfMemory;
            out.appendSlice(e.json) catch return error.OutOfMemory;
        }
        freeAuthEntries(alloc, es);
    }
    const ne = jsonEscape(alloc, server);
    defer alloc.free(ne);
    const te = jsonEscape(alloc, token);
    defer alloc.free(te);
    if (out.items.len > 0) out.append(',') catch return error.OutOfMemory;
    out.appendSlice("\"") catch return error.OutOfMemory;
    out.appendSlice(ne) catch return error.OutOfMemory;
    out.appendSlice("\":{\"token\":\"") catch return error.OutOfMemory;
    out.appendSlice(te) catch return error.OutOfMemory;
    out.appendSlice("\"}") catch return error.OutOfMemory;
    const content = std.fmt.allocPrint(alloc, "{{{s}}}", .{out.items}) catch return error.OutOfMemory;
    defer alloc.free(content);
    try writeConfigFile(io, path, content);
    return replaced;
}

/// Remove a stored token for `server` from an mcp-auth.json file.
pub fn removeAuthToken(alloc: std.mem.Allocator, io: Io, path: []const u8, server: []const u8) !bool {
    const entries = readAuthEntries(alloc, io, path);
    var removed = false;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    if (entries) |es| {
        for (es) |e| {
            if (std.mem.eql(u8, e.key, server)) {
                removed = true;
                continue;
            }
            if (out.items.len > 0) out.append(',') catch return error.OutOfMemory;
            const ne = jsonEscape(alloc, e.key);
            defer alloc.free(ne);
            out.appendSlice("\"") catch return error.OutOfMemory;
            out.appendSlice(ne) catch return error.OutOfMemory;
            out.appendSlice("\":") catch return error.OutOfMemory;
            out.appendSlice(e.json) catch return error.OutOfMemory;
        }
        freeAuthEntries(alloc, es);
    }
    const content = std.fmt.allocPrint(alloc, "{{{s}}}", .{out.items}) catch return error.OutOfMemory;
    defer alloc.free(content);
    try writeConfigFile(io, path, content);
    return removed;
}

/// Do one POST and parse the JSON-RPC response (matching `id`). Returns the
/// `result` re-serialized (owned).
fn doHttpPost(self: *Server, uri: std.Uri, body: []const u8, id: u64) ![]u8 {
    var extra = try buildHeaders(self);
    defer extra.deinit();
    var req = self.http_client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra.items,
        .keep_alive = false,
    }) catch return error.HttpError;
    defer req.deinit();
    req.sendBodyComplete(@constCast(body)) catch return error.HttpError;
    var response = req.receiveHead(&[_]u8{}) catch return error.HttpError;

    // Capture Mcp-Session-Id for subsequent requests.
    var it = response.head.iterateHeaders();
    while (it.next()) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Mcp-Session-Id")) {
            if (self.session_id) |old| self.alloc.free(old);
            self.session_id = self.alloc.dupe(u8, hdr.value) catch return error.OutOfMemory;
        }
    }

    if (response.head.status != .ok) {
        var rbuf: [4096]u8 = undefined;
        var reader = response.reader(&rbuf);
        _ = reader.readSliceShort(&rbuf) catch 0;
        return error.HttpError;
    }

    // Read the whole body.
    const full = try readBody(self, &response);
    defer self.alloc.free(full);
    return parseHttpResponse(self, full, id);
}

/// Do one POST and drain the response (for notifications; no result expected).
fn doHttpPostRaw(self: *Server, uri: std.Uri, body: []const u8) !void {
    var extra = try buildHeaders(self);
    defer extra.deinit();
    var req = self.http_client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra.items,
        .keep_alive = false,
    }) catch return error.HttpError;
    defer req.deinit();
    req.sendBodyComplete(@constCast(body)) catch return error.HttpError;
    var response = req.receiveHead(&[_]u8{}) catch return error.HttpError;
    if (self.session_id == null) {
        var it = response.head.iterateHeaders();
        while (it.next()) |hdr| {
            if (std.mem.eql(u8, hdr.name, "Mcp-Session-Id")) {
                self.session_id = self.alloc.dupe(u8, hdr.value) catch return error.OutOfMemory;
            }
        }
    }
    var rbuf: [8192]u8 = undefined;
    var reader = response.reader(&rbuf);
    _ = reader.readSliceShort(&rbuf) catch 0;
}

/// Read the entire response body into an owned buffer.
fn readBody(self: *Server, response: *std.http.Client.Response) ![]u8 {
    var rbuf: [16384]u8 = undefined;
    var reader = response.reader(&rbuf);
    var full = std.array_list.Managed(u8).init(self.alloc);
    defer full.deinit();
    while (true) {
        const n = reader.readSliceShort(&rbuf) catch break;
        if (n == 0) break;
        full.appendSlice(rbuf[0..n]) catch return error.OutOfMemory;
    }
    return full.toOwnedSlice();
}

/// Parse an HTTP response body (application/json or text/event-stream) and
/// return the JSON-RPC `result` re-serialized (owned).
fn parseHttpResponse(self: *Server, body: []const u8, id: u64) ![]u8 {
    // If it's an SSE stream, extract the data: payloads.
    var candidates = std.array_list.Managed([]const u8).init(self.alloc);
    defer candidates.deinit();
    if (std.mem.indexOfScalar(u8, body, 'd') != null and std.mem.indexOf(u8, body, "data:") != null) {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const payload = std.mem.trim(u8, trimmed[5..], " ");
            if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
            const owned = self.alloc.dupe(u8, payload) catch continue;
            candidates.append(owned) catch {
                self.alloc.free(owned);
                continue;
            };
        }
    }
    // Try the whole body first (application/json), then each SSE candidate.
    if (body.len > 0 and (body[0] == '{' or body[0] == '[')) {
        const r = parseMcpResponse(self, body, id) catch return error.McpError;
        if (r) |v| return v;
    }
    for (candidates.items) |c| {
        const r = parseMcpResponse(self, c, id) catch return error.McpError;
        if (r) |v| return v;
    }
    if (body.len > 0) {
        const r = parseMcpResponse(self, body, id) catch return error.McpError;
        if (r) |v| return v;
    }
    return error.NoResult;
}

/// Parse one JSON-RPC response candidate; returns the `result` re-serialized
/// (owned), null if it's not a matching response, or error.McpError.
fn parseMcpResponse(self: *Server, candidate: []const u8, id: u64) !?[]u8 {
    var p = std.json.parseFromSlice(std.json.Value, self.alloc, candidate, .{}) catch return null;
    const obj = switch (p.value) {
        .object => |o| o,
        else => {
            p.deinit();
            return null;
        },
    };
    const resp_id = switch (obj.get("id") orelse {
        p.deinit();
        return null;
    }) {
        .integer => |n| n,
        .float => |n| @as(i64, @intFromFloat(n)),
        else => {
            p.deinit();
            return null;
        },
    };
    if (@as(i64, @intCast(id)) != resp_id) {
        p.deinit();
        return null;
    }
    if (obj.get("error")) |errv| {
        const msg = extractString(errv, "message") orelse "unknown MCP error";
        self.setLastError(self.alloc.dupe(u8, msg) catch "unknown MCP error");
        p.deinit();
        return error.McpError;
    }
    const result = obj.get("result") orelse {
        p.deinit();
        return null;
    };
    const out = std.json.Stringify.valueAlloc(self.alloc, result, .{}) catch {
        p.deinit();
        return null;
    };
    p.deinit();
    return out;
}

/// Send a JSON-RPC request and block until the matching response arrives.
/// Returns the `result` field re-serialized as a JSON string (owned).
fn request(self: *Server, method: []const u8, params_json: []const u8) ![]u8 {
    if (self.kind == .http) return httpRequest(self, method, params_json);
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
    if (self.kind == .http) return httpNotify(self, method, params_json);
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

// ── MCP resources (list / templates / read) ───────────────────────────
//
// Global tools that reach every connected server (pi exposes the same three,
// which is what Codex/opencode models are trained on). They take a `server`
// argument to route to the right server.

const LIST_RESOURCES_SCHEMA = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\",\"description\":\"MCP server name. Omit to list every server with resources.\"},\"cursor\":{\"type\":\"string\",\"description\":\"Opaque cursor from a previous call with the same server; omit for the first page.\"}},\"additionalProperties\":false}";
const LIST_TEMPLATES_SCHEMA = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\",\"description\":\"MCP server name. Omit to list every server.\"},\"cursor\":{\"type\":\"string\",\"description\":\"Opaque cursor from a previous call.\"}},\"additionalProperties\":false}";
const READ_RESOURCE_SCHEMA = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\",\"description\":\"MCP server name exactly as configured.\"},\"uri\":{\"type\":\"string\",\"description\":\"Resource URI to read, as returned by list_mcp_resources.\"}},\"required\":[\"server\",\"uri\"],\"additionalProperties\":false}";

/// Register the three resource tools (pi: always present when any server can
/// have resources). Returns the number registered.
pub fn registerResourceTools(self: *Manager, registry: *tools.Registry) usize {
    var any_connected = false;
    for (self.servers.items) |s| {
        if (s.connected) any_connected = true;
    }
    if (!any_connected) return 0;
    var count: usize = 0;
    if (registry.register(.{
        .name = "list_mcp_resources",
        .description = "List MCP resources across one or every connected server.",
        .parameters_json = LIST_RESOURCES_SCHEMA,
        .execute = executeListResources,
    })) {
        count += 1;
    } else |_| {}
    if (registry.register(.{
        .name = "list_mcp_resource_templates",
        .description = "List MCP resource templates across one or every connected server.",
        .parameters_json = LIST_TEMPLATES_SCHEMA,
        .execute = executeListResourceTemplates,
    })) {
        count += 1;
    } else |_| {}
    if (registry.register(.{
        .name = "read_mcp_resource",
        .description = "Read an MCP resource by server and URI.",
        .parameters_json = READ_RESOURCE_SCHEMA,
        .execute = executeReadResource,
    })) {
        count += 1;
    } else |_| {}
    return count;
}

fn executeListResources(_: *const tools.Tool, args_json: []const u8, ctx: *tools.ExecutionContext) tools.ToolResult {
    return resourceListHelper(args_json, ctx, "resources/list", "resources");
}

fn executeListResourceTemplates(_: *const tools.Tool, args_json: []const u8, ctx: *tools.ExecutionContext) tools.ToolResult {
    return resourceListHelper(args_json, ctx, "resources/templates/list", "resourceTemplates");
}

/// Shared lister: for each connected server (or the one named in `server`),
/// call `method` and aggregate the `key` arrays, tagging each item with its
/// `server`. Servers that fail are reported in `errors`.
fn resourceListHelper(args_json: []const u8, ctx: *tools.ExecutionContext, method: []const u8, key: []const u8) tools.ToolResult {
    const mgr = Manager.getGlobal() orelse return err0(ctx.alloc, "error: MCP not available");
    var p = std.json.parseFromSlice(std.json.Value, ctx.alloc, args_json, .{}) catch return err0(ctx.alloc, "error: bad arguments");
    defer p.deinit();
    const obj = switch (p.value) {
        .object => |o| o,
        else => return err0(ctx.alloc, "error: bad arguments"),
    };
    const only = strVal(obj.get("server"));
    const cursor = strVal(obj.get("cursor"));

    var out = std.array_list.Managed(u8).init(ctx.alloc);
    defer out.deinit();
    var errors = std.array_list.Managed(u8).init(ctx.alloc);
    defer errors.deinit();
    var next_cursor: ?[]const u8 = null;

    for (mgr.servers.items) |srv| {
        if (!srv.connected) continue;
        if (only) |os| {
            if (!std.mem.eql(u8, srv.name, os)) continue;
        }
        const params = blk: {
            if (cursor) |c| {
                const e = jsonEscape(ctx.alloc, c);
                defer ctx.alloc.free(e);
                break :blk std.fmt.allocPrint(ctx.alloc, "{{\"cursor\":\"{s}\"}}", .{e}) catch break :blk "{}";
            }
            break :blk ctx.alloc.dupe(u8, "{}") catch return err0(ctx.alloc, "error: oom");
        };
        defer ctx.alloc.free(params);
        const res = request(srv, method, params) catch {
            appendError(&errors, ctx.alloc, srv.name, srv.last_error orelse @errorName(error.McpError)) catch {};
            continue;
        };
        defer ctx.alloc.free(res);
        var rp = std.json.parseFromSlice(std.json.Value, ctx.alloc, res, .{}) catch continue;
        defer rp.deinit();
        const ro = switch (rp.value) {
            .object => |o| o,
            else => continue,
        };
        if (ro.get("nextCursor")) |nc| {
            if (strVal(nc)) |s| next_cursor = s;
        }
        const arr = switch (ro.get(key) orelse continue) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |item| {
            const io = switch (item) {
                .object => |o| o,
                else => continue,
            };
            if (!firstItem(&out)) continue;
            appendTaggedObject(&out, ctx.alloc, srv.name, io) catch continue;
        }
    }

    // Assemble {"resources":[...],"nextCursor"?,"errors"?}
    var final = std.array_list.Managed(u8).init(ctx.alloc);
    defer final.deinit();
    final.appendSlice("{\"") catch return err0(ctx.alloc, "error: oom");
    final.appendSlice(key) catch return err0(ctx.alloc, "error: oom");
    final.appendSlice("\":[") catch return err0(ctx.alloc, "error: oom");
    final.appendSlice(out.items) catch return err0(ctx.alloc, "error: oom");
    final.appendSlice("]") catch return err0(ctx.alloc, "error: oom");
    if (next_cursor) |nc| {
        const e = jsonEscape(ctx.alloc, nc);
        defer ctx.alloc.free(e);
        final.appendSlice(",\"nextCursor\":\"") catch return err0(ctx.alloc, "error: oom");
        final.appendSlice(e) catch return err0(ctx.alloc, "error: oom");
        final.appendSlice("\"") catch return err0(ctx.alloc, "error: oom");
    }
    if (errors.items.len > 0) {
        final.appendSlice(",\"errors\":[") catch return err0(ctx.alloc, "error: oom");
        final.appendSlice(errors.items) catch return err0(ctx.alloc, "error: oom");
        final.appendSlice("]") catch return err0(ctx.alloc, "error: oom");
    }
    final.append('}') catch return err0(ctx.alloc, "error: oom");
    const content = final.toOwnedSlice() catch return err0(ctx.alloc, "error: oom");
    return .{ .content = content, .is_error = false };
}

/// Append a JSON object `{"server":"<name>", ...orig}` (skipping an existing
/// `server` key in orig) to `out`, comma-separated. `out` must not yet contain
/// a trailing comma; this appends the item and a following comma.
fn appendTaggedObject(out: *std.array_list.Managed(u8), alloc: std.mem.Allocator, server: []const u8, orig: std.json.ObjectMap) !void {
    out.append('{' ) catch return;
    const se = jsonEscape(alloc, server);
    defer alloc.free(se);
    out.appendSlice("\"server\":\"") catch return;
    out.appendSlice(se) catch return;
    out.appendSlice("\"") catch return;
    for (orig.keys()) |k| {
        if (std.mem.eql(u8, k, "server")) continue;
        const v = orig.get(k) orelse continue;
        const ke = jsonEscape(alloc, k);
        defer alloc.free(ke);
        out.append(',') catch return;
        out.appendSlice("\"") catch return;
        out.appendSlice(ke) catch return;
        out.appendSlice("\":") catch return;
        const vs = std.json.Stringify.valueAlloc(alloc, v, .{}) catch return;
        defer alloc.free(vs);
        out.appendSlice(vs) catch return;
    }
    out.appendSlice("},") catch return;
}

fn firstItem(out: *std.array_list.Managed(u8)) bool {
    return out.items.len == 0;
}

fn appendError(errors: *std.array_list.Managed(u8), alloc: std.mem.Allocator, server: []const u8, msg: []const u8) !void {
    if (errors.items.len > 0) errors.append(',') catch return;
    const se = jsonEscape(alloc, server);
    defer alloc.free(se);
    const me = jsonEscape(alloc, msg);
    defer alloc.free(me);
    errors.appendSlice("{\"server\":\"") catch return;
    errors.appendSlice(se) catch return;
    errors.appendSlice("\",\"error\":\"") catch return;
    errors.appendSlice(me) catch return;
    errors.appendSlice("\"}") catch return;
}

fn executeReadResource(_: *const tools.Tool, args_json: []const u8, ctx: *tools.ExecutionContext) tools.ToolResult {
    const mgr = Manager.getGlobal() orelse return err0(ctx.alloc, "error: MCP not available");
    var p = std.json.parseFromSlice(std.json.Value, ctx.alloc, args_json, .{}) catch return err0(ctx.alloc, "error: bad arguments");
    defer p.deinit();
    const obj = switch (p.value) {
        .object => |o| o,
        else => return err0(ctx.alloc, "error: bad arguments"),
    };
    const server = strVal(obj.get("server")) orelse return err0(ctx.alloc, "error: missing 'server'");
    const uri = strVal(obj.get("uri")) orelse return err0(ctx.alloc, "error: missing 'uri'");
    const srv = mgr.findByName(server) orelse return err0(ctx.alloc, "error: unknown MCP server");
    if (!srv.connected) return err0(ctx.alloc, "error: MCP server not connected");

    const ue = jsonEscape(ctx.alloc, uri);
    defer ctx.alloc.free(ue);
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"uri\":\"{s}\"}}", .{ue}) catch return err0(ctx.alloc, "error: oom");
    defer ctx.alloc.free(params);
    const res = request(srv, "resources/read", params) catch |e| {
        const detail = if (e == error.McpError) srv.last_error orelse "read failed" else @errorName(e);
        return err(ctx.alloc, "error: MCP resource read failed: {s}", .{detail});
    };
    defer ctx.alloc.free(res);

    // result: {contents: [{uri, mimeType, text? / blob?}]}
    var rp = std.json.parseFromSlice(std.json.Value, ctx.alloc, res, .{}) catch return err0(ctx.alloc, "error: invalid result");
    defer rp.deinit();
    const ro = switch (rp.value) {
        .object => |o| o,
        else => return err0(ctx.alloc, "error: invalid result"),
    };
    var text = std.array_list.Managed(u8).init(ctx.alloc);
    defer text.deinit();
    var first = true;
    const contents = switch (ro.get("contents") orelse return err0(ctx.alloc, "error: no contents")) {
        .array => |a| a,
        else => return err0(ctx.alloc, "error: no contents"),
    };
    for (contents.items) |cv| {
        const co = switch (cv) {
            .object => |o| o,
            else => continue,
        };
        if (strVal(co.get("text"))) |t| {
            if (!first) text.append('\n') catch return err0(ctx.alloc, "error: oom");
            text.appendSlice(t) catch return err0(ctx.alloc, "error: oom");
            first = false;
        } else if (co.get("blob")) |b| {
            const mime = strVal(co.get("mimeType")) orelse "application/octet-stream";
            if (!first) text.append('\n') catch return err0(ctx.alloc, "error: oom");
            text.appendSlice("[binary resource: ") catch return err0(ctx.alloc, "error: oom");
            text.appendSlice(mime) catch return err0(ctx.alloc, "error: oom");
            text.appendSlice("]") catch return err0(ctx.alloc, "error: oom");
            first = false;
            _ = b;
        }
    }
    const out = text.toOwnedSlice() catch return err0(ctx.alloc, "error: oom");
    if (out.len == 0) {
        ctx.alloc.free(out);
        return .{ .content = ctx.alloc.dupe(u8, "(empty resource)") catch "", .is_error = false };
    }
    return .{ .content = out, .is_error = false };
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

pub fn parseEntry(alloc: std.mem.Allocator, name: []const u8, entry: std.json.Value, source: []const u8) !ServerConfig {
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
    if (strVal(o.get("exposure"))) |s| cfg.exposure = alloc.dupe(u8, s) catch return error.OutOfMemory;
    if (o.get("headers")) |hv| {
        const ho = switch (hv) {
            .object => |o2| o2,
            else => null,
        };
        if (ho) |headers_obj| {
            var hs = std.array_list.Managed(EnvVar).init(alloc);
            for (headers_obj.keys()) |k| {
                const val = switch (headers_obj.get(k) orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                hs.append(.{
                    .key = alloc.dupe(u8, k) catch return error.OutOfMemory,
                    .value = alloc.dupe(u8, val) catch return error.OutOfMemory,
                }) catch return error.OutOfMemory;
            }
            cfg.headers = hs.toOwnedSlice() catch return error.OutOfMemory;
        }
    }
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

/// A server entry from an mcp.json file, with its entry re-serialized to a
/// valid JSON object string (so we can rebuild the file without juggling
/// dynamic-Value ownership).
pub const ConfigEntry = struct {
    name: []const u8,
    entry_json: []const u8,
};

fn freeEntryList(alloc: std.mem.Allocator, entries: []const ConfigEntry) void {
    for (entries) |e| {
        alloc.free(e.name);
        alloc.free(e.entry_json);
    }
    alloc.free(entries);
}

/// Read the `mcpServers` entries of an mcp.json file (missing file → empty).
/// Each entry is re-serialized to a valid JSON object string.
pub fn readServerEntries(alloc: std.mem.Allocator, io: Io, path: []const u8) ![]ConfigEntry {
    var out = std.array_list.Managed(ConfigEntry).init(alloc);
    defer out.deinit();
    const buf = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return try out.toOwnedSlice();
    defer alloc.free(buf);
    var p = std.json.parseFromSlice(std.json.Value, alloc, buf, .{}) catch return try out.toOwnedSlice();
    const root = switch (p.value) {
        .object => |o| o,
        else => return try out.toOwnedSlice(),
    };
    const servers = switch (root.get("mcpServers") orelse return try out.toOwnedSlice()) {
        .object => |o| o,
        else => return try out.toOwnedSlice(),
    };
    for (servers.keys()) |k| {
        const v = servers.get(k) orelse continue;
        const ej = std.json.Stringify.valueAlloc(alloc, v, .{}) catch continue;
        const nm = alloc.dupe(u8, k) catch {
            alloc.free(ej);
            continue;
        };
        out.append(.{ .name = nm, .entry_json = ej }) catch {
            alloc.free(nm);
            alloc.free(ej);
            continue;
        };
    }
    p.deinit();
    return try out.toOwnedSlice();
}

fn writeConfigFile(io: Io, path: []const u8, content: []const u8) !void {
    // Ensure the parent directory exists (e.g. <agent-dir>/ or <cwd>/.pi/).
    if (std.fs.path.dirname(path)) |parent| {
        _ = Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch return error.WriteFailed;
}

/// Add or replace a server in an mcp.json file. `entry_json` must be a valid
/// JSON object string. Returns true if an entry was replaced.
pub fn addServer(alloc: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, entry_json: []const u8) !bool {
    const entries = try readServerEntries(alloc, io, path);
    defer freeEntryList(alloc, entries);
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    out.appendSlice("{\"mcpServers\":{") catch return error.OutOfMemory;
    var replaced = false;
    var first = true;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            replaced = true;
            continue;
        }
        if (!first) out.append(',') catch return error.OutOfMemory;
        const ne = jsonEscape(alloc, e.name);
        defer alloc.free(ne);
        out.appendSlice("\"") catch return error.OutOfMemory;
        out.appendSlice(ne) catch return error.OutOfMemory;
        out.appendSlice("\":") catch return error.OutOfMemory;
        out.appendSlice(e.entry_json) catch return error.OutOfMemory;
        first = false;
    }
    if (!first) out.append(',') catch return error.OutOfMemory;
    const nn = jsonEscape(alloc, name);
    defer alloc.free(nn);
    out.appendSlice("\"") catch return error.OutOfMemory;
    out.appendSlice(nn) catch return error.OutOfMemory;
    out.appendSlice("\":") catch return error.OutOfMemory;
    out.appendSlice(entry_json) catch return error.OutOfMemory;
    out.appendSlice("}}") catch return error.OutOfMemory;
    const content = out.toOwnedSlice() catch return error.OutOfMemory;
    defer alloc.free(content);
    try writeConfigFile(io, path, content);
    return replaced;
}

/// Remove a server from an mcp.json file. Returns true if it was present.
pub fn removeServer(alloc: std.mem.Allocator, io: Io, path: []const u8, name: []const u8) !bool {
    const entries = try readServerEntries(alloc, io, path);
    defer freeEntryList(alloc, entries);
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    out.appendSlice("{\"mcpServers\":{") catch return error.OutOfMemory;
    var removed = false;
    var first = true;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            removed = true;
            continue;
        }
        if (!first) out.append(',') catch return error.OutOfMemory;
        const ne = jsonEscape(alloc, e.name);
        defer alloc.free(ne);
        out.appendSlice("\"") catch return error.OutOfMemory;
        out.appendSlice(ne) catch return error.OutOfMemory;
        out.appendSlice("\":") catch return error.OutOfMemory;
        out.appendSlice(e.entry_json) catch return error.OutOfMemory;
        first = false;
    }
    out.appendSlice("}}") catch return error.OutOfMemory;
    const content = out.toOwnedSlice() catch return error.OutOfMemory;
    defer alloc.free(content);
    try writeConfigFile(io, path, content);
    return removed;
}

/// Free a config list (and each entry) returned by `loadConfig`.
pub fn freeConfigs(alloc: std.mem.Allocator, cfgs: []const ServerConfig) void {
    for (cfgs) |c| freeConfig(alloc, c);
    alloc.free(cfgs);
}

pub fn freeConfig(alloc: std.mem.Allocator, cfg: ServerConfig) void {
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
    if (cfg.exposure) |e| alloc.free(e);
    for (cfg.headers) |h| {
        alloc.free(h.key);
        alloc.free(h.value);
    }
    alloc.free(cfg.headers);
    alloc.free(cfg.source);
}

/// Owned copy of an EnvVar list (empty list → empty slice, no alloc).
fn dupEnvVars(alloc: std.mem.Allocator, src: []const EnvVar) []EnvVar {
    if (src.len == 0) return &[_]EnvVar{};
    var out = std.array_list.Managed(EnvVar).init(alloc);
    for (src) |e| {
        out.append(.{ .key = alloc.dupe(u8, e.key) catch return &[_]EnvVar{}, .value = alloc.dupe(u8, e.value) catch return &[_]EnvVar{} }) catch return &[_]EnvVar{};
    }
    return out.toOwnedSlice() catch &[_]EnvVar{};
}
