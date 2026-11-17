//! rpi-zig — A coding agent CLI written in Zig.
//! Mirrors the architecture of pi-rust (Rust port of pi coding agent).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const aiprovider = @import("src/ai/provider.zig");
const stream_guard = @import("src/ai/stream_guard.zig");
const tools = @import("src/tools/registry.zig");
const trust = @import("src/core/trust.zig");
const events = @import("src/core/events.zig");
const hooks = @import("src/core/hooks.zig");
const command_tools = @import("src/tools/command_tools.zig");
const selection = @import("src/tools/selection.zig");
const tui = @import("src/ui/tui.zig");
const ss = @import("src/core/session_store.zig");
const sp = @import("src/core/system_prompt.zig");
const msgmod = @import("src/core/message.zig");
const ptmod = @import("src/core/prompt_template.zig");
const skills = @import("src/core/skills.zig");
const mcp = @import("src/core/mcp.zig");
const tool_search = @import("src/tools/tool_search.zig");

fn getCwdAlloc(alloc: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const p = std.c.getcwd(&buf, buf.len) orelse return error.CwdTooLong;
    const end = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return alloc.dupe(u8, p[0..end]);
}

/// Split a comma-separated list into trimmed, non-empty substrings.
/// Substrings point into `s`; the returned outer slice is owned.
/// Append `,"key":"val"` (or `"key":"val"` if first) to a JSON object being
/// built in `entry`.
fn putJsonStr(alloc: std.mem.Allocator, entry: *std.array_list.Managed(u8), first: *bool, key: []const u8, val: []const u8) !void {
    if (!first.*) entry.append(',') catch return error.OutOfMemory;
    const k = try jstr(alloc, key);
    defer alloc.free(k);
    const v = try jstr(alloc, val);
    defer alloc.free(v);
    entry.appendSlice(k) catch return error.OutOfMemory;
    entry.append(':') catch return error.OutOfMemory;
    entry.appendSlice(v) catch return error.OutOfMemory;
    first.* = false;
}

/// `"escaped"` — a JSON string literal (owned).
fn jstr(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    out.append('"') catch return error.OutOfMemory;
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice("\\\"") catch return error.OutOfMemory,
            '\\' => out.appendSlice("\\\\") catch return error.OutOfMemory,
            '\n' => out.appendSlice("\\n") catch return error.OutOfMemory,
            '\r' => out.appendSlice("\\r") catch return error.OutOfMemory,
            '\t' => out.appendSlice("\\t") catch return error.OutOfMemory,
            else => out.append(c) catch return error.OutOfMemory,
        }
    }
    out.append('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `zpi mcp add <name> [options] (-- <command> [args...] | --url <url>)`.
fn mcpAdd(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8) !void {
    const base = try config.baseDir(alloc, environ);
    defer alloc.free(base);
    const cwd = getCwdAlloc(alloc) catch "";
    defer if (cwd.len > 0) alloc.free(cwd);

    var i: usize = 3; // after "mcp add"
    var local = false;
    var url: ?[]const u8 = null;
    var cwd_opt: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    var exposure: ?[]const u8 = null;
    var envs = std.array_list.Managed([]const u8).init(alloc);
    defer envs.deinit();
    var name: ?[]const u8 = null;
    var cmd_args = std.array_list.Managed([]const u8).init(alloc);
    defer cmd_args.deinit();
    var seen_ddash = false;

    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (seen_ddash) {
            cmd_args.append(a) catch return error.OutOfMemory;
            continue;
        }
        if (name == null and !isMcpAddOpt(a)) {
            name = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) { seen_ddash = true; continue; }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--local")) { local = true; continue; }
        if (i + 1 >= argv.len) return error.MissingValue;
        if (std.mem.eql(u8, a, "--url")) { url = argv[i + 1]; i += 1; continue; }
        if (std.mem.eql(u8, a, "--env")) { try envs.append(argv[i + 1]); i += 1; continue; }
        if (std.mem.eql(u8, a, "--cwd")) { cwd_opt = argv[i + 1]; i += 1; continue; }
        if (std.mem.eql(u8, a, "--description")) { desc = argv[i + 1]; i += 1; continue; }
        if (std.mem.eql(u8, a, "--exposure")) { exposure = argv[i + 1]; i += 1; continue; }
        return error.UnknownOption;
    }

    if (name == null) return error.MissingName;
    const n = name.?;
    if ((url != null) == (cmd_args.items.len > 0)) return error.NeedUrlOrCommand;

    // Build the entry JSON object.
    var entry = std.array_list.Managed(u8).init(alloc);
    defer entry.deinit();
    entry.append('{') catch return error.OutOfMemory;
    var first = true;
    if (url) |u| {
        try putJsonStr(alloc, &entry, &first, "url", u);
    } else {
        try putJsonStr(alloc, &entry, &first, "command", cmd_args.items[0]);
        if (cmd_args.items.len > 1) {
            if (!first) entry.append(',') catch return error.OutOfMemory;
            entry.appendSlice("\"args\":[") catch return error.OutOfMemory;
            var af = true;
            for (cmd_args.items[1..]) |arg| {
                if (!af) entry.append(',') catch return error.OutOfMemory;
                const s = try jstr(alloc, arg);
                defer alloc.free(s);
                entry.appendSlice(s) catch return error.OutOfMemory;
                af = false;
            }
            entry.appendSlice("]") catch return error.OutOfMemory;
            first = false;
        }
    }
    if (envs.items.len > 0) {
        if (!first) entry.append(',') catch return error.OutOfMemory;
        entry.appendSlice("\"env\":{") catch return error.OutOfMemory;
        var ef = true;
        for (envs.items) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadEnv;
            const k = pair[0..eq];
            const v = pair[eq + 1 ..];
            if (!ef) entry.append(',') catch return error.OutOfMemory;
            const kj = try jstr(alloc, k);
            defer alloc.free(kj);
            const vj = try jstr(alloc, v);
            defer alloc.free(vj);
            entry.appendSlice(kj) catch return error.OutOfMemory;
            entry.append(':') catch return error.OutOfMemory;
            entry.appendSlice(vj) catch return error.OutOfMemory;
            ef = false;
        }
        entry.appendSlice("}") catch return error.OutOfMemory;
        first = false;
    }
    if (cwd_opt) |c| try putJsonStr(alloc, &entry, &first, "cwd", c);
    if (desc) |d| try putJsonStr(alloc, &entry, &first, "description", d);
    if (exposure) |e| try putJsonStr(alloc, &entry, &first, "exposure", e);
    entry.append('}') catch return error.OutOfMemory;
    const entry_json = entry.toOwnedSlice() catch return error.OutOfMemory;
    defer alloc.free(entry_json);

    const path = if (local)
        try std.fmt.allocPrint(alloc, "{s}/.pi/mcp.json", .{cwd})
    else
        try std.fmt.allocPrint(alloc, "{s}/mcp.json", .{base});
    defer alloc.free(path);
    if (local) {
        _ = std.Io.Dir.cwd().createDirPath(io, ".pi") catch {};
    }
    const replaced = try mcp.addServer(alloc, io, path, n, entry_json);
    const scope = if (local) "project" else "global";
    std.debug.print("{s} {s} MCP server \"{s}\" in {s}.\n", .{ if (replaced) "Replaced" else "Added", scope, n, path });
    std.debug.print("Check it with: zpi mcp list\n", .{});
}

/// `zpi mcp login <server>` — store a bearer token (pure-std approximation of
/// pi's browser OAuth flow: the user pastes the token).
fn mcpLogin(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8) !void {
    const base = try config.baseDir(alloc, environ);
    defer alloc.free(base);
    const auth_path = try std.fmt.allocPrint(alloc, "{s}/mcp-auth.json", .{base});
    defer alloc.free(auth_path);
    var i: usize = 3;
    var name: ?[]const u8 = null;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--local")) continue;
        if (name == null) { name = a; continue; }
        return error.ExtraArgs;
    }
    if (name == null) return error.MissingName;
    std.debug.print("Paste the bearer token for MCP server \"{s}\" (empty to cancel): ", .{name.?});
    const stdin = std.Io.File.stdin();
    var line = std.array_list.Managed(u8).init(alloc);
    defer line.deinit();
    var b: [1]u8 = undefined;
    while (true) {
        const n = stdin.readStreaming(io, &.{&b}) catch break;
        if (n == 0) break;
        if (b[0] == '\n') break;
        line.append(b[0]) catch return error.OutOfMemory;
    }
    const token = std.mem.trim(u8, line.items, " \r\n\t");
    if (token.len == 0) {
        std.debug.print("\ncancelled\n", .{});
        return;
    }
    const token_owned = alloc.dupe(u8, token) catch return error.OutOfMemory;
    defer alloc.free(token_owned);
    const replaced = try mcp.storeAuthToken(alloc, io, auth_path, name.?, token_owned);
    std.debug.print("{s} token for MCP server \"{s}\".\n", .{ if (replaced) "Replaced" else "Stored", name.? });
}

/// `zpi mcp logout <server>` — remove a stored bearer token.
fn mcpLogout(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8) !void {
    const base = try config.baseDir(alloc, environ);
    defer alloc.free(base);
    const auth_path = try std.fmt.allocPrint(alloc, "{s}/mcp-auth.json", .{base});
    defer alloc.free(auth_path);
    var i: usize = 3;
    var name: ?[]const u8 = null;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--local")) continue;
        if (name == null) { name = a; continue; }
        return error.ExtraArgs;
    }
    if (name == null) return error.MissingName;
    const removed = try mcp.removeAuthToken(alloc, io, auth_path, name.?);
    if (removed) {
        std.debug.print("Removed token for MCP server \"{s}\".\n", .{name.?});
    } else {
        std.debug.print("No stored token for MCP server \"{s}\".\n", .{name.?});
    }
}

/// `zpi mcp remove <name> [-l]`.
fn mcpRemove(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8) !void {
    const base = try config.baseDir(alloc, environ);
    defer alloc.free(base);
    const cwd = getCwdAlloc(alloc) catch "";
    defer if (cwd.len > 0) alloc.free(cwd);
    var i: usize = 3;
    var local = false;
    var name: ?[]const u8 = null;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--local")) { local = true; continue; }
        if (name == null) { name = a; continue; }
        return error.ExtraArgs;
    }
    if (name == null) return error.MissingName;
    const path = if (local)
        try std.fmt.allocPrint(alloc, "{s}/.pi/mcp.json", .{cwd})
    else
        try std.fmt.allocPrint(alloc, "{s}/mcp.json", .{base});
    defer alloc.free(path);
    const removed = try mcp.removeServer(alloc, io, path, name.?);
    const scope = if (local) "project" else "global";
    if (removed) {
        std.debug.print("Removed {s} MCP server \"{s}\" from {s}.\n", .{ scope, name.?, path });
    } else {
        std.debug.print("No {s} MCP server named \"{s}\" in {s}.\n", .{ scope, name.?, path });
    }
}

fn isMcpAddOpt(a: []const u8) bool {
    return std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--local") or
        std.mem.eql(u8, a, "--url") or std.mem.eql(u8, a, "--env") or
        std.mem.eql(u8, a, "--cwd") or std.mem.eql(u8, a, "--description") or
        std.mem.eql(u8, a, "--exposure") or std.mem.eql(u8, a, "--");
}

fn splitComma(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(alloc);
    errdefer list.deinit();
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) try list.append(trimmed);
    }
    return list.toOwnedSlice();
}

/// Detect a supported image MIME type from magic bytes (png/jpeg/gif/webp).
fn detectImageMime(data: []const u8) ?[]const u8 {
    if (data.len >= 8 and data[0] == 0x89 and std.mem.eql(u8, data[1..4], "PNG")) return "image/png";
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return "image/jpeg";
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return "image/gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    return null;
}

/// SIGINT/SIGTERM: request a graceful agent abort instead of dying.
fn handleSignal(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    agent.requestAbort();
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return; // Phase K: Win32 console handler
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}


/// State the trust reload hook needs: everything main used to wire MCP up,
/// kept alive on main's stack for the whole session.
const TrustReloadCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    cwd_abs: []const u8,
    user_mcp: []const u8,
    proj_mcp: []const u8,
    registry: *tools.Registry,
    mcp_mgr: *?*mcp.Manager,
    exclude_list: ?[]const []const u8,
    mcp_allowlist: ?[]const []const u8,
    hooks_cfg: *hooks.HooksConfig,
    bus: *events.Bus,
};

fn trustReloadCb(ctx_ptr: *anyopaque, t: *tui.TUI, trusted: bool) void {
    const ctx: *TrustReloadCtx = @ptrCast(@alignCast(ctx_ptr));
    const alloc = ctx.alloc;
    if (!trusted) {
        t.note("Project resources are not loaded (untrusted)", .{});
        return;
    }
    // Rebuild the MCP manager with the project file included (pi loads
    // project mcp.json only for trusted projects).
    // Drop previously registered MCP tools FIRST (their name/desc slices
    // live inside the manager; it must not be freed while we still match
    // against them), then tear the manager down.
    const PrefixMatch = struct {
        fn pred(patterns: []const []const u8, name: []const u8) bool {
            return std.mem.startsWith(u8, name, patterns[0]);
        }
    };
    const ResourceMatch = struct {
        fn pred(patterns: []const []const u8, name: []const u8) bool {
            _ = patterns;
            return mcp.isMcpToolName(name) and !std.mem.startsWith(u8, name, "mcp__");
        }
    };
    const mcp_prefix: []const u8 = "mcp__";
    ctx.registry.removeMatchingOn(&.{mcp_prefix}, PrefixMatch.pred);
    ctx.registry.removeMatchingOn(&.{"resource"}, ResourceMatch.pred);
    if (ctx.mcp_mgr.*) |old| {
        mcp.Manager.setGlobal(null);
        old.deinit();
        alloc.destroy(old);
        ctx.mcp_mgr.* = null;
    }
    blk: {
        const mgr = alloc.create(mcp.Manager) catch break :blk;
        mgr.* = mcp.Manager.init(alloc, ctx.io);
        mgr.auth_path = std.fmt.allocPrint(alloc, "{s}/mcp-auth.json", .{ctx.cfg.base_dir}) catch break :blk;
        mcp.Manager.setGlobal(mgr);
        const cfgs = mcp.loadConfig(alloc, ctx.io, ctx.user_mcp, ctx.proj_mcp) catch break :blk;
        defer mcp.freeConfigs(alloc, cfgs); // rememberConfigs keeps its own dupe
        mgr.rememberConfigs(cfgs);
        mgr.connectAll(cfgs);
        _ = mgr.registerTools(ctx.registry);
        _ = mcp.registerResourceTools(mgr, ctx.registry);
        ctx.mcp_mgr.* = mgr;
        t.note("MCP: {d} server(s) after trust reload", .{mgr.servers.items.len});
    }
    // Replay the tool-selection filters over the fresh MCP tools.
    if (ctx.exclude_list) |ex| {
        ctx.registry.removeMatchingOn(ex, struct {
            fn pred(patterns: []const []const u8, name: []const u8) bool {
                return mcp.isMcpToolName(name) and selection.matchesAny(name, patterns);
            }
        }.pred);
    }
    if (ctx.mcp_allowlist) |allow| {
        ctx.registry.removeMatchingOn(allow, struct {
            fn pred(patterns: []const []const u8, name: []const u8) bool {
                return mcp.isMcpToolName(name) and !selection.matchesAny(name, patterns);
            }
        }.pred);
    }
    // Project MCP tools may be searchable — keep tool_search available.
    _ = ctx.registry.setActive("tool_search", true);

    // Reload hooks (project hooks.json now included) and re-register the
    // command tools (project settings may add more).
    hooks.freeConfig(alloc, ctx.hooks_cfg);
    ctx.hooks_cfg.* = hooks.loadConfig(alloc, ctx.io, ctx.cfg.base_dir, ctx.cwd_abs, true) catch ctx.hooks_cfg.*;
    for (ctx.cfg.command_tools) |*ct| {
        ctx.registry.register(.{
            .name = ct.name,
            .description = ct.description,
            .parameters_json = ct.schema_json,
            .execute = command_tools.execute,
            .exposure = "direct",
            .active = true,
        }) catch continue;
    }
    command_tools.setGlobal(ctx.cfg.command_tools);
}

/// Events -> hooks.json scripts (Phase I2 bridge). Synchronous; runs on the
/// caller's thread (tool worker threads for tool events — safe, hooks are
/// short-lived subprocesses).
const HooksListener = struct {
    cfg: *hooks.HooksConfig,
    io: std.Io,
    cwd: []const u8,

    fn onEvent(ctx: *anyopaque, event: events.Event, bus_alloc: std.mem.Allocator) ?[]const u8 {
        const self: *HooksListener = @ptrCast(@alignCast(ctx));
        switch (event) {
            .pre_tool_call => |p| {
                return hooks.preToolCall(self.cfg, bus_alloc, self.io, p.name, p.args_json, self.cwd);
            },
            .post_tool_call => |p| {
                hooks.postToolCall(self.cfg, bus_alloc, self.io, p.name, p.args_json, p.result, self.cwd);
                return null;
            },
            .input => |text| {
                return hooks.runPayloadSection(self.cfg.input, bus_alloc, self.io, "input", text, self.cwd);
            },
            else => return null,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    installSignalHandlers();


    var argv = std.array_list.Managed([]const u8).init(alloc);
    var prompt_from_argv: ?usize = null; // positional prompt owns this slot
    defer {
        for (argv.items, 0..) |arg, slot| {
            if (prompt_from_argv == slot) continue; // ownership moved to `prompt`
            alloc.free(arg);
        }
        argv.deinit();
    }
    var arg_it = try init.minimal.args.iterateAllocator(alloc);
    while (arg_it.next()) |arg| {
        try argv.append(alloc.dupe(u8, arg) catch break);
    }

    // Parse args
    var print_mode = false;
    var prompt: ?[]const u8 = null;
    var file_args = std.array_list.Managed([]const u8).init(alloc);
    defer file_args.deinit();
    var image_attachments = std.array_list.Managed(msgmod.ImageBlock).init(alloc);
    defer {
        for (image_attachments.items) |img| {
            alloc.free(img.data);
            alloc.free(img.mime);
        }
        image_attachments.deinit();
    }
    var model_name: ?[]const u8 = null;
    var cli_thinking: ?config.ThinkingLevel = null;
    var model_id: ?[]const u8 = null;
    var cli_provider: ?[]const u8 = null;
    var cli_api_key: ?[]const u8 = null;
    var cli_models_scope: ?[]const u8 = null;
    var mode_json = false; // --mode json (K1: JSONL event stream on stdout)
    var mode_rpc = false; // --mode rpc (K2, not yet implemented)
    var cwd: ?[]const u8 = null;
    var no_tui = false;
    var list_models = false;
    // Session persistence (B)
    var no_session = false;
    var continue_last = false;
    var resume_mode = false;
    var session_path: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var fork_from: ?[]const u8 = null; // path or id of session to fork
    var session_name: ?[]const u8 = null;
    var session_dir: ?[]const u8 = null;
    var list_sessions = false;
    // Tool selection (Phase E7)
    var tools_arg: ?[]const u8 = null;
    // Project-trust override (--approve/-a trusts, --no-approve/-na distrusts;
    // pi projectTrustOverride). null = resolve from the store / interactively.
    var trust_override: ?bool = null;
    var exclude_tools_arg: ?[]const u8 = null;
    var no_tools = false;
    var no_builtin_tools = false;
    // System prompt (Phase D5)
    var append_system_prompt: ?[]const u8 = null;
    var system_prompt_override: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.items.len) : (i += 1) {
        const arg = argv.items[i];
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            // pi: -p takes no value; the message text is a positional arg.
            print_mode = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            if (i + 1 < argv.items.len) model_name = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            if (i + 1 < argv.items.len) {
                const lv = argv.items[i + 1];
                if (config.ThinkingLevel.fromStr(lv)) |tl| {
                    cli_thinking = tl;
                } else {
                    std.debug.print("warning: invalid thinking level \"{s}\" (valid: off, low, medium, high, xhigh, max)\n", .{lv});
                }
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--model-id")) {
            if (i + 1 < argv.items.len) model_id = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            if (i + 1 < argv.items.len) cli_provider = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (i + 1 < argv.items.len) cli_api_key = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--models")) {
            if (i + 1 < argv.items.len) cli_models_scope = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (i + 1 < argv.items.len) {
                const m = argv.items[i + 1];
                if (std.mem.eql(u8, m, "json")) {
                    mode_json = true;
                    print_mode = true;
                } else if (std.mem.eql(u8, m, "rpc")) {
                    mode_rpc = true;
                    print_mode = true;
                } else if (!std.mem.eql(u8, m, "text")) {
                    std.debug.print("error: unknown --mode '{s}' (text|json|rpc)\n", .{m});
                    return error.BadUsage;
                }
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            if (i + 1 < argv.items.len) cwd = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-tui")) {
            no_tui = true;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            list_models = true;
        } else if (std.mem.eql(u8, arg, "--approve") or std.mem.eql(u8, arg, "-a")) {
            trust_override = true;
        } else if (std.mem.eql(u8, arg, "--no-approve") or std.mem.eql(u8, arg, "-na")) {
            trust_override = false;
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            no_session = true;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            continue_last = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            resume_mode = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (i + 1 < argv.items.len) session_path = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            if (i + 1 < argv.items.len) session_id = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fork")) {
            if (i + 1 < argv.items.len) fork_from = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 < argv.items.len) session_name = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            if (i + 1 < argv.items.len) session_dir = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--list-sessions")) {
            list_sessions = true;
        } else if (std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < argv.items.len) tools_arg = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt")) {
            if (i + 1 < argv.items.len) exclude_tools_arg = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            no_tools = true;
        } else if (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt")) {
            no_builtin_tools = true;
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            if (i + 1 < argv.items.len) append_system_prompt = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            if (i + 1 < argv.items.len) system_prompt_override = argv.items[i + 1];
            i += 1;
        } else {
            // pi positional args: @files and message text.
            if (arg.len > 1 and arg[0] == '@') {
                file_args.append(arg[1..]) catch {};
            } else if (prompt == null) {
                prompt = arg;
                prompt_from_argv = argv.items.len - 1;
            }
        }
    }

    // `zpi mcp <subcommand>` (pi `pi mcp …`). Handled before config load —
    // it only needs the base dir, not a model.
    if (argv.items.len >= 2 and std.mem.eql(u8, argv.items[1], "mcp")) {
        const sub = if (argv.items.len >= 3) argv.items[2] else "";
        if (std.mem.eql(u8, sub, "list")) {
            const base = try config.baseDir(alloc, init.minimal.environ);
            defer alloc.free(base);
            const user_mcp = try std.fmt.allocPrint(alloc, "{s}/mcp.json", .{base});
            defer alloc.free(user_mcp);
            const proj_cwd: []const u8 = getCwdAlloc(alloc) catch "";
            defer {
                if (proj_cwd.len > 0) alloc.free(proj_cwd);
            }
            const proj_mcp = try std.fmt.allocPrint(alloc, "{s}/.pi/mcp.json", .{proj_cwd});
            defer alloc.free(proj_mcp);
            // Trust-gated (pi): without a saved decision this listing shows
            // the user-level file only when the project is not yet trusted.
            var early_store = trust.Store.init(alloc, io, base) catch null;
            defer if (early_store) |*st| st.deinit();
            const early_trusted = if (early_store) |*st| (st.get(proj_cwd) orelse false) else false;
            const cfgs = mcp.loadConfig(alloc, io, user_mcp, if (early_trusted) proj_mcp else "/nonexistent/.pi/mcp.json") catch &[_]mcp.ServerConfig{};
            defer mcp.freeConfigs(alloc, cfgs);
            if (cfgs.len == 0) {
                std.debug.print("no MCP servers configured\n", .{});
            } else {
                std.debug.print("MCP servers:\n", .{});
                for (cfgs) |c| {
                    const kind = switch (c.kind) {
                        .stdio => "stdio",
                        .http => "http",
                    };
                    const en = if (c.enabled) "" else " (disabled)";
                    std.debug.print("  {s} [{s}]{s}\n", .{ c.name, kind, en });
                    if (c.description) |d| std.debug.print("    {s}\n", .{d});
                }
            }
            return;
        }
        if (std.mem.eql(u8, sub, "add")) {
            return mcpAdd(alloc, io, init.minimal.environ, argv.items) catch |e| {
                std.debug.print("error: {s}\n", .{@errorName(e)});
                return error.McpCli;
            };
        }
        if (std.mem.eql(u8, sub, "remove")) {
            return mcpRemove(alloc, io, init.minimal.environ, argv.items) catch |e| {
                std.debug.print("error: {s}\n", .{@errorName(e)});
                return error.McpCli;
            };
        }
        if (std.mem.eql(u8, sub, "login")) {
            return mcpLogin(alloc, io, init.minimal.environ, argv.items) catch |e| {
                std.debug.print("error: {s}\n", .{@errorName(e)});
                return error.McpCli;
            };
        }
        if (std.mem.eql(u8, sub, "logout")) {
            return mcpLogout(alloc, io, init.minimal.environ, argv.items) catch |e| {
                std.debug.print("error: {s}\n", .{@errorName(e)});
                return error.McpCli;
            };
        }
        std.debug.print("usage: zpi mcp <list|add|remove|login|logout>\n", .{});
        return;
    }

    // Load config
    var cfg = try config.load(io, alloc, init.minimal.environ);

    // ---- Project trust (H4, pi project-trust.js) ----
    // Non-interactive resolution happens here (CLI override -> saved
    // decision -> no gated resources -> defaultProjectTrust setting); the
    // interactive ask runs in the TUI right before the main loop.
    var trust_store_var: ?trust.Store = null;
    trust_store_var = trust.Store.init(alloc, io, cfg.base_dir) catch null;
    defer if (trust_store_var) |*ts| ts.deinit();
    var project_trusted: bool = true;
    var trust_needs_prompt = false;
    var trust_saved_decision: ?bool = null;
    // Home dir (user-level skill discovery ~/.agents/skills + trust checks).
    const home_dir_early = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse
        std.process.Environ.getPosix(init.minimal.environ, "USERPROFILE");
    if (std.process.Environ.getPosix(init.minimal.environ, "ZPI_DEBUG_BODY")) |p| {
        ai.debug_body_path = p;
    }
    // SSE idle timeout (pi httpIdleTimeoutMs, default 300s): no bytes for this
    // long fails the stream and the provider retry loop retries. "0" disables.
    if (std.process.Environ.getPosix(init.minimal.environ, "ZPI_HTTP_IDLE_TIMEOUT_MS")) |raw| {
        if (std.fmt.parseInt(i64, raw, 10)) |ms| {
            if (ms >= 0) stream_guard.idle_timeout_ms = ms;
        } else |_| {}
    }
    defer cfg.deinit(alloc);

    // Resolve cwd EARLY: the trust decision gates project settings (which
    // feed defaultTools) and project resource loading.
    var cwd_alloc: ?[]u8 = null;
    defer if (cwd_alloc) |c| alloc.free(c);
    const cwd_abs = blk2: {
        if (cwd) |c| {
            break :blk2 c;
        }
        cwd_alloc = try getCwdAlloc(alloc);
        break :blk2 cwd_alloc.?;
    };

    // chdir so tools (read/bash/edit) resolve relative paths against --cwd.
    if (builtin.os.tag != .windows) {
        if (std.mem.indexOfScalar(u8, cwd_abs, 0) == null) {
            const cwd_z = alloc.alloc(u8, cwd_abs.len + 1) catch null;
            if (cwd_z) |z| {
                @memcpy(z[0..cwd_abs.len], cwd_abs);
                z[cwd_abs.len] = 0;
                _ = std.c.chdir(@ptrCast(z.ptr));
                alloc.free(z);
            }
        }
    }

    // pi resolveProjectTrusted, non-interactive part: CLI override wins;
    // without gated resources everything is trusted by default; otherwise a
    // saved decision (nearest ancestor) applies; defaultProjectTrust
    // always/never short-circuits; "ask" (the default) defers to the TUI
    // prompt (untrusted until confirmed; print mode stays untrusted).
    const trust_store: ?*trust.Store = if (trust_store_var) |*ts| ts else null;
    project_trusted = blk2: {
        if (trust_override) |t| break :blk2 t;
        if (trust_store) |ts| {
            if (ts.getEntry(cwd_abs) catch null) |entry| {
                defer alloc.free(entry.path);
                trust_saved_decision = entry.decision;
            }
        }
        const gated = trust.hasTrustRequiringResources(alloc, io, cwd_abs, home_dir_early);
        if (!gated) {
            // pi: trustStore.get(cwd) ?? true — no gated resources at all.
            if (trust_saved_decision == null) break :blk2 true;
        }
        if (trust_saved_decision) |d| break :blk2 d;
        switch (cfg.default_project_trust) {
            .always => break :blk2 true,
            .never => break :blk2 false,
            .ask => {},
        }
        trust_needs_prompt = true;
        break :blk2 false; // conservative until the prompt confirms
    };

    // Trusted projects may override settings via .pi/settings.json (pi
    // settings-manager project scope): merged here so defaultTools and the
    // default model resolution below see the effective values.
    if (project_trusted) {
        cfg.loadProjectSettings(alloc, io, cwd_abs) catch {};
    }

    const home_dir = home_dir_early;

    if (list_models) {
        std.debug.print("models ({s}):\n", .{cfg.base_dir});
        for (cfg.models.items) |*m| {
            const default = cfg.findDefaultModel();
            const mark = if (default == m) " *" else "";
            const ci = m.cost_input orelse -1;
            const co = m.cost_output orelse -1;
            if (ci >= 0 and co >= 0) {
                std.debug.print("  {s}/{s}  {s}  ctx={d} maxTokens={d} ${d:.2}/${d:.2} per M{s}\n", .{ m.provider, m.id, m.name, m.context_window, m.max_tokens, ci, co, mark });
            } else {
                std.debug.print("  {s}/{s}  {s}  ctx={d} maxTokens={d}{s}\n", .{
                    m.provider, m.id, m.name, m.context_window, m.max_tokens, mark,
                });
            }
        }
        return;
    }

    // --models scope: restrict/reorder cfg.models to the matching patterns
    // (pi resolveModelScope; comma-separated patterns, "provider/*" globs
    // match by prefix segments, ":level" suffix sets a per-model thinking).
    if (cli_models_scope) |scope| {
        var scoped = std.array_list.Managed(config.Config.Model).init(alloc);
        var it = std.mem.splitScalar(u8, scope, ',');
        while (it.next()) |raw_pat| {
            const pat = std.mem.trim(u8, raw_pat, " \t");
            if (pat.len == 0) continue;
            var base = pat;
            var pat_thinking: ?config.ThinkingLevel = null;
            if (config.splitThinkingSuffix(pat)) |suf| {
                base = suf.base;
                pat_thinking = suf.level;
            }
            var matched_any = false;
            for (cfg.models.items) |m| {
                const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ m.provider, m.id }) catch continue;
                defer alloc.free(full);
                const hit = if (std.mem.endsWith(u8, base, "*"))
                    (std.mem.startsWith(u8, full, base[0 .. base.len - 1]) or
                        std.mem.startsWith(u8, m.id, base[0 .. base.len - 1]))
                else
                    (std.mem.eql(u8, full, base) or std.mem.eql(u8, m.id, base) or
                        std.mem.eql(u8, m.name, base));
                if (hit) {
                    var mm = m;
                    if (pat_thinking) |tl| mm.thinking_level = tl;
                    scoped.append(mm) catch {};
                    matched_any = true;
                }
            }
            if (!matched_any) {
                std.debug.print("warning: no models match pattern \"{s}\"\n", .{pat});
            }
        }
        if (scoped.items.len > 0) {
            cfg.models.deinit();
            cfg.models = scoped;
        } else {
            for (scoped.items) |_| {}
            scoped.deinit();
            std.debug.print("warning: --models matched nothing; keeping full catalog\n", .{});
        }
    }

    // Select model: -m/--model-id > settings.json default > first
    // (pi resolveCliModel: provider/id > id (ambiguity-checked) > fuzzy
    // substring with alias-over-dated tie-break; custom-id fallback for an
    // unknown id on a known provider.)
    var model: config.Config.Model = blk: {
        if (model_name) |name| {
            var pattern = name;
            var suffix_level: ?config.ThinkingLevel = null;
            if (config.splitThinkingSuffix(name)) |suffix| {
                pattern = suffix.base;
                suffix_level = suffix.level;
            }
            switch (cfg.resolveModelPattern(pattern, cli_provider, alloc)) {
                .resolved => |m| {
                    var mm = m.*;
                    if (cli_api_key) |k| {
                        alloc.free(mm.api_key);
                        mm.api_key = try alloc.dupe(u8, k);
                    }
                    mm.thinking_level = cli_thinking orelse suffix_level orelse mm.thinking_level;
                    break :blk mm;
                },
                .ambiguous_id => {
                    std.debug.print("error: model '{s}' is ambiguous across providers. Use provider/id.\n", .{pattern});
                    return error.UnknownModel;
                },
                .fuzzy => |f| {
                    var mm = f.model.*;
                    if (cli_api_key) |k| {
                        alloc.free(mm.api_key);
                        mm.api_key = try alloc.dupe(u8, k);
                    }
                    mm.thinking_level = cli_thinking orelse suffix_level orelse mm.thinking_level;
                    std.debug.print("note: '{s}' matched {s}/{s}", .{ pattern, mm.provider, mm.id });
                    if (f.others.len > 0) {
                        std.debug.print(" ({d} other candidates)", .{f.others.len});
                    }
                    std.debug.print("\n", .{});
                    break :blk mm;
                },
                .not_found => {
                    // pi fallback: custom model id on the requested (or
                    // scoped) provider, reusing its default model's settings.
                    if (cli_provider != null or cli_api_key != null) {
                        for (cfg.models.items) |m| {
                            if (cli_provider) |pf| {
                                if (!std.ascii.eqlIgnoreCase(m.provider, pf)) continue;
                            }
                            var mm = m;
                            mm.id = try alloc.dupe(u8, pattern);
                            mm.name = mm.id;
                            if (cli_api_key) |k| {
                                alloc.free(mm.api_key);
                                mm.api_key = try alloc.dupe(u8, k);
                            }
                            mm.thinking_level = cli_thinking orelse suffix_level orelse mm.thinking_level;
                            std.debug.print("warning: model '{s}' not found for provider '{s}'. Using custom model id.\n", .{ pattern, mm.provider });
                            break :blk mm;
                        }
                    }
                    std.debug.print("error: unknown model '{s}' (use --list-models)\n", .{pattern});
                    return error.UnknownModel;
                },
            }
        }
        if (model_id) |id| {
            if (cfg.findModel(id)) |m| {
                var mm = m.*;
                if (cli_thinking) |tl| mm.thinking_level = tl;
                break :blk mm;
            }
            std.debug.print("error: unknown model id '{s}' (use --list-models)\n", .{id});
            return error.UnknownModel;
        }
        if (cfg.findDefaultModel()) |m| {
            var mm = m.*;
            if (cli_thinking) |tl| mm.thinking_level = tl;
            break :blk mm;
        }
        var mm = cfg.models.items[0];
        if (cli_thinking) |tl| mm.thinking_level = tl;
        break :blk mm;
    };

    // Init provider (wire protocol selected by the model's api field)
    var provider = try aiprovider.buildFromModel(alloc, io, &model);
    defer provider.deinit();

    // Init tools
    var registry = tools.Registry.init(alloc);
    defer {
        tool_search.setGlobal(null);
        registry.deinit();
    }
    try tools.registerAll(&registry);

    // ---- Tool selection (Phase E7) ----
    // Resolve --tools / --exclude-tools / --no-tools against the default set
    // (settings defaultTools if set, else the built-in default).
    var cli_tools_list: ?[]const []const u8 = null;
    var exclude_list: ?[]const []const u8 = null;
    // MCP-tool allowlist (null = MCP tools bypass the tool filter). See the
    // selection block below for how it is derived.
    var mcp_allowlist: ?[]const []const u8 = null;
    // Whether the tool_search tool registers at all (resolved with the
    // selection, applied after MCP registration).
    var register_tool_search = true;
    if (tools_arg) |t| cli_tools_list = try splitComma(alloc, t);
    if (exclude_tools_arg) |e| exclude_list = try splitComma(alloc, e);
    defer if (cli_tools_list) |l| alloc.free(l);
    defer if (exclude_list) |l| alloc.free(l);

    // Validate --tools (plain vs modifier, no wildcards in modifiers).
    if (cli_tools_list) |list| {
        const tool_err = try selection.getToolListError(alloc, list);
        if (tool_err) |msg| {
            std.debug.print("error: --tools: {s}\n", .{msg});
            alloc.free(msg);
            return error.BadTools;
        }
    }

    // Base set: --no-tools / --no-builtin-tools -> empty; else defaultTools
    // (resolved) or built-in (pi: noTools="all" and noTools="builtin" both
    // empty the default set; they differ in how MCP tools are filtered).
    var base_owned: ?[]const []const u8 = null;
    const base: []const []const u8 = if (no_tools or no_builtin_tools) blk: {
        break :blk &[_][]const u8{};
    } else if (cfg.default_tools) |dt| blk: {
        base_owned = try selection.resolveDefaultTools(alloc, dt);
        break :blk base_owned.?;
    } else blk: {
        break :blk &selection.DEFAULT_TOOL_NAMES;
    };
    defer if (base_owned) |b| alloc.free(b);

    const selected = try selection.select(alloc, base, cli_tools_list, exclude_list orelse &[_][]const u8{});
    defer alloc.free(selected);
    // Inactive tools stay registered (tool_search can load them later); they
    // are just not declared to the model.
    registry.activateOnly(selected);

    // MCP filtering (pi sdk.js):
    //   - `--exclude-tools` reaches MCP tools: they are never registered.
    //   - A plain `--tools` list filters MCP tools only when one of its
    //     entries starts with `mcp__` (exact names or `*` globs); unmatched
    //     MCP tools are not registered either.
    //   - `--no-tools` ("all") registers no MCP tools at all;
    //     `--no-builtin-tools` leaves MCP tools untouched.
    //   - A modifiers-only `--tools` list does not filter MCP tools.
    mcp_allowlist = if (no_tools)
        try alloc.alloc([]const u8, 0)
    else blk: {
        const list = cli_tools_list orelse break :blk null;
        var has_mcp = false;
        for (list) |e| {
            if (std.mem.startsWith(u8, e, "mcp__")) has_mcp = true;
        }
        break :blk if (has_mcp) list else null;
    };

    // ---- MCP (PLAN 10): load mcp.json, connect stdio servers, register tools ----
    // The manager is heap-allocated so the shared MCP tool executor (which only
    // sees its own Tool name) can reach it via the global. It outlives the
    // session (servers are long-lived) and is retired at the end of main.
    var mcp_mgr: ?*mcp.Manager = null;
    blk: {
        const user_mcp = std.fmt.allocPrint(alloc, "{s}/mcp.json", .{cfg.base_dir}) catch break :blk;
        defer alloc.free(user_mcp);
        const proj_mcp = std.fmt.allocPrint(alloc, "{s}/.pi/mcp.json", .{cwd_abs}) catch break :blk;
        defer alloc.free(proj_mcp);
        // Untrusted projects keep only the user-level file (pi gates
        // .pi/mcp.json behind project trust); a sentinel empty path reads
        // as an absent file.
        const effective_proj: []const u8 = if (project_trusted) proj_mcp else "/nonexistent/.pi/mcp.json";
        const cfgs = mcp.loadConfig(alloc, io, user_mcp, effective_proj) catch break :blk;
        defer mcp.freeConfigs(alloc, cfgs);
        const mgr = alloc.create(mcp.Manager) catch break :blk;
        mgr.* = mcp.Manager.init(alloc, io);
        const auth_path = std.fmt.allocPrint(alloc, "{s}/mcp-auth.json", .{cfg.base_dir}) catch break :blk;
        // Owned by the manager (freed in Manager.deinit); freeing here would
        // leave a dangling path behind HTTP 401 reconnects.
        mgr.auth_path = auth_path;
        mcp.Manager.setGlobal(mgr);
        mgr.rememberConfigs(cfgs);
        mgr.connectAll(cfgs);
        _ = mgr.registerTools(&registry);
        _ = mcp.registerResourceTools(mgr, &registry);
        mcp_mgr = mgr;
    }
    // Apply the tool-selection filters to MCP tools (they register above so
    // the manager stays the executor; filtering happens here because the
    // selection state lives in main).
    if (mcp_mgr != null) {
        if (exclude_list) |ex| {
            registry.removeMatchingOn(ex, struct {
                fn pred(patterns: []const []const u8, name: []const u8) bool {
                    return mcp.isMcpToolName(name) and selection.matchesAny(name, patterns);
                }
            }.pred);
        }
        if (mcp_allowlist) |allow| {
            // Not registered: pi drops MCP tools the `mcp__` allowlist does
            // not match (they cannot even be searched).
            registry.removeMatchingOn(allow, struct {
                fn pred(patterns: []const []const u8, name: []const u8) bool {
                    return mcp.isMcpToolName(name) and !selection.matchesAny(name, patterns);
                }
            }.pred);
        }
    }
    // `tool_search` (pi parity): registered INACTIVE; activated when the
    // selection includes it (`--tools tool_search`, `--tools +tool_search`,
    // the defaultTools setting) or automatically when a server with
    // codemode/deferred exposure connected (pi activates the codemode script
    // runner for codemode servers; zpi has no codemode yet, so tool_search is
    // the access path for those tools). Registration follows the selection:
    // excluded tools never register, and a `mcp__`-prefixed plain allowlist
    // that does not list tool_search drops it (pi _isAllowedTool).
    register_tool_search = blk: {
        if (exclude_list) |ex| {
            if (selection.matchesAny("tool_search", ex)) break :blk false;
        }
        if (mcp_allowlist) |allow| {
            var listed = false;
            for (allow) |a| {
                if (std.mem.eql(u8, a, "tool_search")) listed = true;
            }
            if (!listed) break :blk false;
        }
        break :blk true;
    };
    if (register_tool_search) {
        tool_search.registerToolSearch(&registry) catch {};
    }
    if (registry.find("tool_search") != null) {
        var want_active = false;
        for (selected) |n| {
            if (std.mem.eql(u8, n, "tool_search")) want_active = true;
        }
        if (!want_active) {
            // Auto-activate when searchable (codemode/deferred) tools are
            // registered but not declared — tool_search is their access path
            // (pi activates codemode/tool_search per server exposure).
            for (registry.tools.items) |*t| {
                if (!t.active and tool_search.isSearchable(t.exposure)) {
                    want_active = true;
                    break;
                }
            }
        }
        _ = registry.setActive("tool_search", want_active);
        tool_search.setGlobal(&registry);
    }
    defer if (mcp_mgr) |m| {
        mcp.Manager.setGlobal(null);
        m.deinit();
        alloc.destroy(m);
    };

    // ---- Phase I: event bus + hooks.json + command tools ----
    var ev_bus = events.Bus.init(alloc);
    defer ev_bus.deinit();
    var hooks_cfg = hooks.loadConfig(
        alloc,
        io,
        cfg.base_dir,
        cwd_abs,
        project_trusted,
    ) catch hooks.HooksConfig{};
    defer hooks.freeConfig(alloc, &hooks_cfg);
    var hooks_listener = HooksListener{ .cfg = &hooks_cfg, .io = io, .cwd = cwd_abs };
    ev_bus.add(.{ .ctx = &hooks_listener, .onEvent = HooksListener.onEvent }) catch {};
    events.setGlobal(&ev_bus);

    // Command tools (Phase I1): register each declared shell command.
    for (cfg.command_tools) |*ct| {
        registry.register(.{
            .name = ct.name,
            .description = ct.description,
            .parameters_json = ct.schema_json,
            .execute = command_tools.execute,
            .exposure = "direct",
            .active = true,
        }) catch continue;
    }
    command_tools.setGlobal(cfg.command_tools);

    ev_bus.emit(.session_start);

    // Trust reload hook state (kept on main's stack; the TUI prompt calls it
    // when the user trusts a project at startup or via /trust).
    var trust_reload = TrustReloadCtx{
        .alloc = alloc,
        .io = io,
        .cfg = &cfg,
        .cwd_abs = cwd_abs,
        .user_mcp = std.fmt.allocPrint(alloc, "{s}/mcp.json", .{cfg.base_dir}) catch "",
        .proj_mcp = std.fmt.allocPrint(alloc, "{s}/.pi/mcp.json", .{cwd_abs}) catch "",
        .registry = &registry,
        .mcp_mgr = &mcp_mgr,
        .exclude_list = exclude_list,
        .mcp_allowlist = mcp_allowlist,
        .hooks_cfg = &hooks_cfg,
        .bus = &ev_bus,
    };

    // ---- Initial prompt assembly (pi buildInitialMessage) ----
    // piped stdin (non-TTY); stdin presence downgrades interactive → print.
    var stdin_content: ?[]u8 = null;
    {
        const stdin_file = std.Io.File.stdin();
        const is_tty = stdin_file.isTty(io) catch false;
        if (!is_tty) {
            var buf = std.array_list.Managed(u8).init(alloc);
            var rbuf: [4096]u8 = undefined;
            var fr = stdin_file.reader(io, &rbuf);
            while (true) {
                const n = fr.interface.readSliceShort(&rbuf) catch break;
                if (n == 0) break;
                buf.appendSlice(rbuf[0..n]) catch break;
            }
            const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
            if (trimmed.len > 0) {
                stdin_content = alloc.dupe(u8, trimmed) catch null;
            }
            buf.deinit();
            if (stdin_content != null and !print_mode) print_mode = true;
        }
    }

    // @file arguments → <file name> text wrap + image attachments
    var file_text: ?[]u8 = null;
    if (file_args.items.len > 0) {
        var fbuf = std.array_list.Managed(u8).init(alloc);
        for (file_args.items) |fa| {
            const abs = if (std.mem.startsWith(u8, fa, "/")) try alloc.dupe(u8, fa) else try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd_abs, fa });
            defer alloc.free(abs);
            const raw = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .limited(64 * 1024 * 1024)) catch {
                std.debug.print("error: file not found: {s}\n", .{abs});
                return error.FileNotFound;
            };
            defer alloc.free(raw);
            if (raw.len == 0) continue;
            if (detectImageMime(raw)) |mime| {
                const enc = std.base64.standard.Encoder;
                const b64 = try alloc.alloc(u8, enc.calcSize(raw.len));
                defer alloc.free(b64);
                _ = enc.encode(b64, raw);
                image_attachments.append(.{
                    .data = try alloc.dupe(u8, b64),
                    .mime = try alloc.dupe(u8, mime),
                }) catch {};
                try fbuf.appendSlice("<file name=\"");
                try fbuf.appendSlice(abs);
                try fbuf.appendSlice("\"></file>\n");
            } else {
                try fbuf.appendSlice("<file name=\"");
                try fbuf.appendSlice(abs);
                try fbuf.appendSlice("\">\n");
                const content = std.mem.trimStart(u8, raw, "\xef\xbb\xbf");
                try fbuf.appendSlice(content);
                try fbuf.appendSlice("\n</file>\n");
            }
        }
        if (fbuf.items.len > 0) file_text = try fbuf.toOwnedSlice() else fbuf.deinit();
    }

    // Combine [stdin, @file text, prompt] (pi order), then expand templates.
    {
        const templates = ptmod.discover(alloc, io, cfg.base_dir, cwd_abs, project_trusted);
        defer ptmod.freeAll(alloc, templates);
        var combined = std.array_list.Managed(u8).init(alloc);
        defer combined.deinit();
        if (stdin_content) |sc| {
            combined.appendSlice(sc) catch {};
            combined.append('\n') catch {};
        }
        if (file_text) |ft| {
            combined.appendSlice(ft) catch {};
        }
        if (prompt) |pp| {
            combined.appendSlice(pp) catch {};
        }
        if (combined.items.len > 0) {
            // expand always returns a fresh allocation (or propagates OOM);
            // the original positional prompt is absorbed — free it.
            if (prompt) |pp| alloc.free(pp);
            prompt = try ptmod.expand(alloc, combined.items, templates);
        } else if (prompt) |pp| {
            alloc.free(pp);
            prompt = null;
        }
    }



    // Build the sectioned system prompt (Phase D) + advertise skills (Phase H1).
    const skills_list = try skills.discover(alloc, io, cfg.base_dir, cwd_abs, home_dir, project_trusted);
    defer skills.freeAll(alloc, skills_list);
    var skills_block: ?[]u8 = null;
    defer {
        if (skills_block) |b| alloc.free(b);
    }
    skills_block = try skills.formatForPrompt(alloc, skills_list);
    var tool_snippets = std.array_list.Managed(sp.ToolSnippet).init(alloc);
    defer tool_snippets.deinit();
    for (registry.tools.items) |t| {
        // Only active tools are declared to the model (pi).
        if (!t.active) continue;
        try tool_snippets.append(.{ .name = t.name, .snippet = t.description });
    }
    const system_prompt = try sp.buildFromSnippets(alloc, io, tool_snippets.items, cwd_abs, cfg.base_dir, append_system_prompt, system_prompt_override, skills_block);

    // Create session
    const model_ptr = &model;
    var session = try agent.Session.init(alloc, io, model_ptr, &registry, provider, system_prompt);
    defer session.deinit();
    alloc.free(system_prompt);
    session.compaction = cfg.compaction;

    // Session store (B)
    var sessions_dir_alloc: ?[]u8 = null;
    const sessions_dir = blk: {
        if (session_dir) |d| break :blk d;
        sessions_dir_alloc = try std.fmt.allocPrint(alloc, "{s}/sessions", .{cfg.base_dir});
        break :blk sessions_dir_alloc.?;
    };

    if (list_sessions) {
        const list = try ss.listForCwd(alloc, io, sessions_dir, cwd_abs);
        defer {
            for (list) |info| {
                alloc.free(info.path);
                alloc.free(info.id);
                if (info.name) |n| alloc.free(n);
                if (info.first_message) |fm| alloc.free(fm);
                alloc.free(info.timestamp);
            }
            alloc.free(list);
        }
        std.debug.print("sessions for {s} ({d}):\n", .{ cwd_abs, list.len });
        for (list) |info| {
            const label = info.name orelse "(unnamed)";
            std.debug.print("  {s}  {d} msgs  {s}\n", .{ label, info.msg_count, info.path });
        }
        if (cwd_alloc) |c| alloc.free(c);
        if (sessions_dir_alloc) |d| alloc.free(d);
        return;
    }

    var store: ?*ss.Store = null;
    if (!no_session) {
        store = blk: {
            if (session_id) |sid| {
                const found = ss.findById(alloc, io, sessions_dir, sid);
                if (found) |f| {
                    const st = ss.Store.open(alloc, io, f) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{f});
                        alloc.free(f);
                        break :blk null;
                    };
                    alloc.free(f);
                    break :blk st;
                }
                std.debug.print("[session: no session matching id '{s}']\n", .{sid});
            }
            if (session_path) |sp_arg| {
                // pi: --session accepts a file path or a full/partial id
                var spath_owned = false;
                const spath = blk2: {
                    std.Io.Dir.cwd().access(io, sp_arg, .{}) catch {
                        const found = ss.findById(alloc, io, sessions_dir, sp_arg);
                        if (found) |f| {
                            spath_owned = true;
                            break :blk2 f;
                        }
                        std.debug.print("[session: cannot find '{s}'\n", .{sp_arg});
                        break :blk null;
                    };
                    break :blk2 sp_arg;
                };
                const st = ss.Store.open(alloc, io, spath) catch {
                    std.debug.print("[session: cannot open {s}]\n", .{spath});
                    if (spath_owned) alloc.free(spath);
                    break :blk null;
                };
                if (spath_owned) alloc.free(spath);
                break :blk st;
            }
            if (fork_from) |fref| {
                const fpath = fpblk: {
                    if (std.fs.path.isAbsolute(fref)) {
                        const fpath = fref;
                        break :fpblk fpath;
                    }
                    const found = ss.findById(alloc, io, sessions_dir, fref);
                    if (found) |f| break :fpblk f;
                    std.debug.print("[session: no session matching '{s}']\n", .{fref});
                    break :fpblk null;
                };
                if (fpath) |fp| {
                    const src = ss.Store.open(alloc, io, fp) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{fp});
                        break :blk null;
                    };
                    defer if (!std.mem.eql(u8, fp, fref)) alloc.free(fp);
                    const st = src.fork(sessions_dir, cwd_abs) catch {
                        std.debug.print("[session: fork failed]\n", .{});
                        src.deinit();
                        break :blk null;
                    };
                    src.deinit();
                    break :blk st;
                }
            }
            if (continue_last or resume_mode) {
                const list = ss.listForCwd(alloc, io, sessions_dir, cwd_abs) catch &.{};
                defer {
                    for (list) |info| {
                        alloc.free(info.path);
                        alloc.free(info.id);
                        if (info.name) |n| alloc.free(n);
                        if (info.first_message) |fm| alloc.free(fm);
                        alloc.free(info.timestamp);
                    }
                    alloc.free(list);
                }
                if (list.len > 0) {
                    const st = ss.Store.open(alloc, io, list[0].path) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{list[0].path});
                        break :blk null;
                    };
                    std.debug.print("[session: {s} ({s})]\n", .{
                        if (st.name) |n| n else "unnamed", st.id,
                    });
                    break :blk st;
                }
                std.debug.print("[session: no previous session for {s}]\n", .{cwd_abs});
            }
            const st = ss.Store.create(alloc, io, sessions_dir, cwd_abs, .{
                .name = session_name,
            }) catch {
                std.debug.print("[session: create failed]\n", .{});
                break :blk null;
            };
            if (resume_mode) {
                // replayed context is empty; messages will follow
            }
            break :blk st;
        };
        if (store) |st| {
            session.store = st;
            // B3: replay the active branch into context
            const branch = st.branchMessages(alloc) catch &.{};
            defer {
                for (branch) |m| m.deinit();
                alloc.free(branch);
            }
            for (branch) |m| session.context.append(m) catch {};
            // Seed the footer's running totals from the replayed messages
            // (totals only accumulates live streams; without this a -c/
            // resume session starts at 0 tokens/$0 even though the store
            // holds the prior consumption).
            for (branch) |m| {
                if (m.role != .assistant) continue;
                if (m.usage) |u| session.totals.add(u);
            }
            if (session_name) |n| st.recordSessionInfo(n);
            // pi: restore the session's model and thinking level (last
            // model_change / thinking_level_change on the leaf path), unless
            // the CLI pinned one. Struct copies share cfg-owned strings, so
            // swapping is pointer-free.
            if (model_name == null and model_id == null) {
                if (st.latestModelChange(alloc)) |mc| {
                    defer {
                        alloc.free(mc.provider);
                        alloc.free(mc.model_id);
                    }
                    const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ mc.provider, mc.model_id }) catch null;
                    if (full) |f| {
                        defer alloc.free(f);
                        if (cfg.findModel(f)) |m| {
                            // The provider was built from the DEFAULT model
                            // above; a restored session model on another
                            // provider must rebind it, or requests carry the
                            // restored model id to the default provider's
                            // gateway ("model not found").
                            if (!std.mem.eql(u8, m.id, model.id) or
                                !std.mem.eql(u8, m.provider, model.provider)) {
                                model = m.*;
                                provider.deinit();
                                provider = try aiprovider.buildFromModel(alloc, io, m);
                                session.provider = provider;
                            }
                        }
                    }
                }
                if (st.latestThinkingLevel(alloc)) |tl| {
                    defer alloc.free(tl);
                    if (config.ThinkingLevel.fromStr(tl)) |lvl| {
                        model.thinking_level = lvl;
                        session.thinking_level = lvl;
                    }
                }
            }
        }
    }

    // Run
    if (print_mode) {
        if (mode_rpc) {
            std.debug.print("error: --mode rpc is not implemented yet\n", .{});
            return error.BadUsage;
        }
        const stdout = std.Io.File.stdout();
        // Both modes suppress the streamed echo (print-mode semantics);
        // json mode's output is the event stream itself.
        session.quiet = true;
        if (mode_json) {
            // K1: JSONL event stream (pi json-event shape). Session header
            // first (the store file's first line), then live events.
            if (session.store) |st| {
                st.emitHeader(stdout, io) catch {};
            }
            session.json_out = stdout;
        }
        var run_failed = false;
        if (prompt) |p| {
            session.runPromptWithImages(p, image_attachments.items) catch |e| {
                run_failed = (e != error.Aborted);
                if (run_failed) {
                    std.debug.print("[error: {s}]\n", .{@errorName(e)});
                }
            };
        }
        if (mode_json) {
            session.json_out = null;
        } else {
            // Final text from the last assistant message (pi print-mode).
            var last_text: ?[]u8 = null;
            for (session.context.messages.items) |m| {
                if (m.role == .assistant) {
                    for (m.blocks.items) |b| switch (b) {
                        .text => |t| last_text = @constCast(t),
                        else => {},
                    };
                }
            }
            if (last_text) |t| {
                stdout.writeStreamingAll(io, t) catch {};
                stdout.writeStreamingAll(io, "\n") catch {};
            }
            if (session.last_error_message) |em| {
                std.debug.print("{s}\n", .{em});
                run_failed = true;
            }
        }
        if (run_failed) {
            // pi print-mode: console.error + exit 1 (no error-return trace).
            std.process.exit(1);
        }
    } else {
        // TUI mode
        var t = tui.TUI.init(io, alloc, &session, model.name, sessions_dir, cwd_abs, home_dir, &cfg, init.minimal.environ, append_system_prompt, system_prompt_override);
        // Gate project discovery BEFORE the first dynamic-slash refresh.
        t.project_trusted = project_trusted;
        t.initLate();
        defer t.deinit();
        // Project trust ask (H4): pi TrustSelectorComponent runs before any
        // other interaction; choosing Trust hot-loads project resources via
        // the reload hook below.
        if (trust_needs_prompt) {
            t.trust_reload_ctx = @ptrCast(&trust_reload);
            t.trust_reload_fn = &trustReloadCb;
            t.beginTrustPrompt(cwd_abs, trust_saved_decision, false);
        }
        // Persisted history → visible transcript (pi: renderInitialMessages
        // runs whenever the session has messages — continue/resume/--session).
        t.replaySession();
        t.run() catch |e| {
            std.debug.print("[TUI error: {s}]\n", .{@errorName(e)});
        };
    }

    if (prompt) |pp| alloc.free(pp);
    // The session may have swapped stores (/clone, /fork, /resume, /import):
    // retire whatever store is current (the initial one moved into
    // session.store at startup and swap paths retire the ones they replace).
    if (session.store) |st| st.deinit();
    // cwd_alloc freed by the defer at its declaration site (no double free).
    if (sessions_dir_alloc) |d| alloc.free(d);
    if (stdin_content) |sc| alloc.free(sc);
    if (file_text) |ft| alloc.free(ft);
    // TrustReloadCtx path strings (allocated at ctx construction).
    if (trust_reload.user_mcp.len > 0) alloc.free(trust_reload.user_mcp);
    if (trust_reload.proj_mcp.len > 0) alloc.free(trust_reload.proj_mcp);
}
