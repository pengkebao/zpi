//! Configuration: native pi (pi.dev) format.
//!
//! Agent dir: `PI_CODING_AGENT_DIR` env var, else `~/.pi/agent`.
//!   <agent-dir>/models.json   — custom providers/models:
//!     { "providers": { "<id>": { "baseUrl", "api", "apiKey", "authHeader",
//!                                "models": [{ "id", "name", "contextWindow",
//!                                             "maxTokens", "reasoning" }] } } }
//!   <agent-dir>/auth.json     — stored credentials:
//!     { "<id>": { "type": "api_key", "key": "..." } }
//!   <agent-dir>/settings.json — { "defaultProvider": "...", "defaultModel": "..." }
//!
//! apiKey values resolve like pi: literal, "$ENV_VAR", or "!command" output.
//! Key fallback order: models.json apiKey → auth.json → built-in env var.
//! Built-in providers (e.g. zai-coding-cn) are known by a small table and get
//! their credentials from auth.json / environment variables.

const std = @import("std");
const compact = @import("compaction.zig");

/// Model thinking/reasoning effort level. Drives the TUI border color (pi's
/// theme maps each level to a color: off=gray, low=blue, medium=indigo,
/// high=purple, xhigh=magenta, max=red) and the reasoning effort sent to the
/// provider.
pub const ThinkingLevel = enum {
    off,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn name(self: ThinkingLevel) []const u8 {
        return switch (self) {
            .off => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
            .max => "max",
        };
    }

    pub fn fromStr(s: []const u8) ?ThinkingLevel {
        return if (std.mem.eql(u8, s, "off")) ThinkingLevel.off
        else if (std.mem.eql(u8, s, "low")) .low
        else if (std.mem.eql(u8, s, "medium")) .medium
        else if (std.mem.eql(u8, s, "high")) .high
        else if (std.mem.eql(u8, s, "xhigh")) .xhigh
        else if (std.mem.eql(u8, s, "max")) .max
        else null;
    }

    /// Default level for a model: explicit `thinkingLevel` field, else high for
    /// reasoning models, else off.
    pub fn defaultFor(reasoning: bool, explicit: ?[]const u8) ThinkingLevel {
        if (explicit) |s| {
            if (ThinkingLevel.fromStr(s)) |tl| return tl;
        }
        return if (reasoning) .high else .off;
    }
};

/// Provider-specific thinking parameter format (pi-ai compat.thinkingFormat):
/// .default → `reasoning_effort`; .zai → `thinking:{type:enabled|disabled}`
/// (GLM series); .qwen → `enable_thinking` (DashScope/Qwen).
pub const ThinkingFormat = enum { default, zai, qwen };

/// Split a trailing `:level` thinking suffix (pi splitThinkingSuffix):
/// `ovf/ovf-mini:high` → base "ovf/ovf-mini", level .high. Returns null
/// when there is no colon or the suffix is not a valid level (strict —
/// the text is then kept whole).
pub fn splitThinkingSuffix(text: []const u8) ?struct { base: []const u8, level: ThinkingLevel } {
    const ci = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const level = ThinkingLevel.fromStr(text[ci + 1 ..]) orelse return null;
    return .{ .base = text[0..ci], .level = level };
}

/// Fullscreen scrollbar visibility (settings.json "fullscreenScrollbar").
pub const ScrollbarMode = enum { auto, always, hidden };

pub const Config = struct {
    base_dir: []u8,
    models: std.array_list.Managed(Model),
    default_provider: ?[]u8 = null,
    default_model: ?[]u8 = null,
    /// defaultTools from settings.json (owned; each name dup'd). null = unset.
    default_tools: ?[]const []const u8 = null,
    compaction: compact.Settings = compact.DEFAULT_SETTINGS,
    /// settings.json "fullscreenScrollbar" (pi default "auto": shows on
    /// scroll activity, hides after a second).
    fullscreen_scrollbar: ScrollbarMode = .auto,
    /// settings.json "fullscreenWheelScrollLines": a fixed line count per
    /// wheel event; null = "auto" (velocity-based, pi's default).
    fullscreen_wheel_lines: ?u32 = null,

    pub const Model = struct {
        provider: []u8,
        id: []u8,
        name: []u8, // display name
        base_url: []u8,
        api_key: []u8, // resolved key ("" if none)
        auth_header: bool = false,
        context_window: usize = 128000,
        max_tokens: usize = 16384,
        reasoning: bool = false,
        /// Default thinking/reasoning effort for this model (drives border
        /// color + reasoning effort). Can be changed at runtime via /think.
        thinking_level: ThinkingLevel = .off,
        /// Provider-specific thinking parameter shape (models.json
        /// "thinkingFormat", pi-ai compat.thinkingFormat).
        thinking_format: ThinkingFormat = .default,
        /// "supportsReasoningEffort": zai/qwen models may also accept a
        /// (mapped) reasoning_effort alongside their switch field.
        /// null = auto-detect from the base URL (pi detected-compat).
        supports_reasoning_effort: ?bool = null,
        /// "thinkingLevelMap": maps a level name to a provider-specific
        /// effort string sent as reasoning_effort (index = @intFromEnum).
        thinking_level_map: [6]?[]u8 = .{null, null, null, null, null, null},
        /// Whether the model accepts image input (gates image content blocks).
        supports_images: bool = true,
        // USD per million tokens; null = unknown (cost stays 0)
        cost_input: ?f64 = null,
        cost_output: ?f64 = null,
        cost_cache_read: ?f64 = null,
        cost_cache_write: ?f64 = null,
    };

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        for (self.models.items) |m| {
            alloc.free(m.provider);
            alloc.free(m.id);
            alloc.free(m.name);
            alloc.free(m.base_url);
            alloc.free(m.api_key);
            for (m.thinking_level_map) |slot| if (slot) |s| alloc.free(s);
        }
        self.models.deinit();
        if (self.default_provider) |dp| alloc.free(dp);
        if (self.default_model) |dm| alloc.free(dm);
        if (self.default_tools) |dt| {
            for (dt) |n| alloc.free(n);
            alloc.free(dt);
        }
        alloc.free(self.base_dir);
    }

    /// Find a model by "provider/id" or bare "id".
    pub fn findModel(self: *const Config, ref: []const u8) ?*const Model {
        for (self.models.items) |*m| {
            const full = std.fmt.allocPrint(self.models.allocator, "{s}/{s}", .{ m.provider, m.id }) catch continue;
            const match = std.mem.eql(u8, full, ref);
            self.models.allocator.free(full);
            if (match) return m;
        }
        for (self.models.items) |*m| {
            if (std.mem.eql(u8, m.id, ref)) return m;
        }
        return null;
    }

    /// Default model per settings.json: "defaultProvider/defaultModel", else
    /// first model of defaultProvider, else bare "defaultModel", else null.
    pub fn findDefaultModel(self: *const Config) ?*const Model {
        if (self.default_provider) |dp| {
            if (self.default_model) |dm| {
                const full = std.fmt.allocPrint(self.models.allocator, "{s}/{s}", .{ dp, dm }) catch null;
                if (full) |f| {
                    defer self.models.allocator.free(f);
                    if (self.findModel(f)) |m| return m;
                }
            }
            for (self.models.items) |*m| {
                if (std.mem.eql(u8, m.provider, dp)) return m;
            }
        }
        if (self.default_model) |dm| {
            if (self.findModel(dm)) |m| return m;
        }
        return null;
    }

    /// Set the default provider/model (owned copies).
    pub fn setDefaultProviderModel(self: *Config, alloc: std.mem.Allocator, provider: []const u8, model: []const u8) !void {
        if (self.default_provider) |dp| alloc.free(dp);
        if (self.default_model) |dm| alloc.free(dm);
        self.default_provider = try alloc.dupe(u8, provider);
        self.default_model = try alloc.dupe(u8, model);
    }

    /// Persist current settings (compaction, default model) to
    /// <agent-dir>/settings.json, preserving unrelated fields.
    pub fn persistSettings(self: *Config, alloc: std.mem.Allocator, io: std.Io) !void {
        const path = try std.fmt.allocPrint(alloc, "{s}/settings.json", .{self.base_dir});
        defer alloc.free(path);
        const buf: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch null;
        defer if (buf) |b| alloc.free(b);

        var root: std.json.Value = if (buf) |b| blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, b, .{}) catch break :blk .{ .object = std.json.ObjectMap.empty };
            break :blk parsed.value;
        } else .{ .object = std.json.ObjectMap.empty };

        var comp = std.json.ObjectMap.empty;
        try comp.put(alloc, "enabled", .{ .bool = self.compaction.enabled });
        try comp.put(alloc, "reserveTokens", .{ .integer = @intCast(self.compaction.reserve_tokens) });
        try comp.put(alloc, "keepRecentTokens", .{ .integer = @intCast(self.compaction.keep_recent_tokens) });
        // Preserve unknown compaction sub-fields.
        if (root.object.get("compaction")) |old_c| {
            if (old_c == .object) {
                var it = old_c.object.iterator();
                while (it.next()) |e| {
                    const keep = [_][]const u8{ "enabled", "reserveTokens", "keepRecentTokens" };
                    var known = false;
                    for (keep) |k| {
                        if (std.mem.eql(u8, e.key_ptr.*, k)) {
                            known = true;
                            break;
                        }
                    }
                    if (!known) try comp.put(alloc, e.key_ptr.*, e.value_ptr.*);
                }
            }
        }
        try root.object.put(alloc, "compaction", .{ .object = comp });
        if (self.default_provider) |dp| try root.object.put(alloc, "defaultProvider", .{ .string = dp });
        if (self.default_model) |dm| try root.object.put(alloc, "defaultModel", .{ .string = dm });

        const json_text = try std.json.Stringify.valueAlloc(alloc, root, .{});
        defer alloc.free(json_text);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json_text });
    }
};

// ── Built-in providers (subset of pi's catalog, verified values) ────

const BuiltinProvider = struct {
    id: []const u8,
    base_url: []const u8,
    env_var: []const u8,
};

const builtins = [_]BuiltinProvider{
    .{ .id = "zai-coding-cn", .base_url = "https://open.bigmodel.cn/api/coding/paas/v4", .env_var = "ZAI_CODING_CN_API_KEY" },
    .{ .id = "zai", .base_url = "https://api.z.ai/api/coding/paas/v4", .env_var = "ZAI_API_KEY" },
};

const BuiltinModel = struct {
    provider: []const u8,
    id: []const u8,
    name: []const u8,
    ctx: usize,
    max: usize,
    reasoning: bool,
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
};

const builtin_models = [_]BuiltinModel{
    .{ .provider = "zai-coding-cn", .id = "glm-4.6v", .name = "GLM-4.6V", .ctx = 128000, .max = 32768, .reasoning = true, .cost_input = 0.3, .cost_output = 0.9, .cost_cache_read = 0.05 },
    .{ .provider = "zai-coding-cn", .id = "glm-5.3", .name = "GLM-5.3", .ctx = 1000000, .max = 131072, .reasoning = true, .cost_input = 1.4, .cost_output = 4.4, .cost_cache_read = 0.26 },
    .{ .provider = "zai-coding-cn", .id = "glm-5.3-flash", .name = "GLM-5.3-Flash", .ctx = 1000000, .max = 131072, .reasoning = true, .cost_input = 0.15, .cost_output = 0.5, .cost_cache_read = 0.03 },
};

fn builtinEnv(provider_id: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.id, provider_id)) return b.env_var;
    }
    return null;
}

fn builtinBaseUrl(provider_id: []const u8) ?[]const u8 {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.id, provider_id)) return b.base_url;
    }
    return null;
}

// ── JSON helpers ────────────────────────────────────────────────────

fn strIn(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// tri-state bool from a JSON object field: true/false/null (absent).
fn triBoolIn(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn numIn(o: std.json.ObjectMap, key: []const u8) ?usize {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => |n| @as(usize, @intFromFloat(n)),
        .integer => |n| @as(usize, @intCast(n)),
        else => null,
    };
}

fn floatIn(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn costIn(mo: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = mo.get("cost") orelse return null;
    const co = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return floatIn(co, key);
}

fn boolIn(o: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

const AuthEntry = struct {
    provider: []const u8,
    key: []const u8,
};

const ProviderInfo = struct {
    id: []u8,
    base_url: []u8,
    api_key: []u8,
    auth_header: bool,
};

/// Read a file under the agent dir into buf. Returns null if missing/unreadable.
fn readAgentFile(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const path = std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFile(io, path, buf) catch null;
}

/// Resolve an apiKey-style config value: literal, "$ENV", or "!command".
fn resolveValue(alloc: std.mem.Allocator, io: std.Io, raw: []const u8, environ: std.process.Environ) ![]u8 {
    if (raw.len == 0) return "";
    if (raw[0] == '!') {
        const result = std.process.run(alloc, io, .{
            .argv = &.{ "/bin/sh", "-c", raw[1..] },
            .stdout_limit = .limited(1 << 16),
            .stderr_limit = .limited(1 << 12),
        }) catch return "";
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        return alloc.dupe(u8, trimmed);
    }
    if (raw[0] == '$') {
        if (std.process.Environ.getPosix(environ, raw[1..])) |v| {
            return alloc.dupe(u8, std.mem.sliceTo(v, 0));
        }
        return "";
    }
    return alloc.dupe(u8, raw);
}

// ── Load ────────────────────────────────────────────────────────────

/// Load config from the pi agent dir (PI_CODING_AGENT_DIR or ~/.pi/agent).
/// Compute the base dir without loading models (for CLI subcommands like
/// `mcp list` that don't need a model configured).
pub fn baseDir(alloc: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const env_dir = std.process.Environ.getPosix(environ, "PI_CODING_AGENT_DIR") orelse
        std.process.Environ.getPosix(environ, "RPI_CODING_AGENT_DIR");
    if (env_dir) |dir| return alloc.dupe(u8, std.mem.sliceTo(dir, 0));
    const home = std.process.Environ.getPosix(environ, "HOME") orelse
        std.process.Environ.getPosix(environ, "USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ std.mem.sliceTo(home, 0), ".pi", "agent" });
}

pub fn load(io: std.Io, alloc: std.mem.Allocator, environ: std.process.Environ) !Config {
    var cfg = Config{
        .base_dir = "",
        .models = .init(alloc),
    };
    errdefer cfg.deinit(alloc);

    // 1. Determine base dir
    const env_dir = std.process.Environ.getPosix(environ, "PI_CODING_AGENT_DIR") orelse
        std.process.Environ.getPosix(environ, "RPI_CODING_AGENT_DIR");
    if (env_dir) |dir| {
        cfg.base_dir = try alloc.dupe(u8, std.mem.sliceTo(dir, 0));
    } else {
        // Windows has no HOME; USERPROFILE is the equivalent.
        const home = std.process.Environ.getPosix(environ, "HOME") orelse
            std.process.Environ.getPosix(environ, "USERPROFILE") orelse return error.NoHome;
        cfg.base_dir = try std.fs.path.join(alloc, &.{ std.mem.sliceTo(home, 0), ".pi", "agent" });
    }

    var buf: [1 << 20]u8 = undefined;

    // 2. auth.json — stored credentials per provider
    var auth = std.array_list.Managed(AuthEntry).init(alloc);
    defer {
        for (auth.items) |a| {
            alloc.free(a.provider);
            alloc.free(a.key);
        }
        auth.deinit();
    }
    if (readAgentFile(alloc, io, cfg.base_dir, "auth.json", &buf)) |data| blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch break :blk;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => break :blk,
        };
        var it = root.iterator();
        while (it.next()) |e| {
            const cred = switch (e.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const ctype = strIn(cred, "type") orelse continue;
            if (!std.mem.eql(u8, ctype, "api_key")) continue;
            const key = strIn(cred, "key") orelse continue;
            // Dupe: the parsed arena is freed at the end of this block.
            const pid_copy = alloc.dupe(u8, e.key_ptr.*) catch continue;
            const key_copy = alloc.dupe(u8, key) catch {
                alloc.free(pid_copy);
                continue;
            };
            auth.append(.{ .provider = pid_copy, .key = key_copy }) catch {
                alloc.free(pid_copy);
                alloc.free(key_copy);
            };
        }
    }

    // 3. settings.json — defaultProvider / defaultModel
    if (readAgentFile(alloc, io, cfg.base_dir, "settings.json", &buf)) |data| blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch break :blk;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => break :blk,
        };
        if (strIn(root, "defaultProvider")) |dp| {
            cfg.default_provider = try alloc.dupe(u8, dp);
        }
        if (strIn(root, "defaultModel")) |dm| {
            cfg.default_model = try alloc.dupe(u8, dm);
        }
        // Fullscreen scrollbar: "auto" (pi default) | "always" | "hidden".
        if (strIn(root, "fullscreenScrollbar")) |sb| {
            if (std.mem.eql(u8, sb, "always")) cfg.fullscreen_scrollbar = .always;
            if (std.mem.eql(u8, sb, "hidden")) cfg.fullscreen_scrollbar = .hidden;
        }
        // Lines per wheel event; "auto" (or anything else) is velocity-based.
        if (root.get("fullscreenWheelScrollLines")) |wv| {
            if (numIn(root, "fullscreenWheelScrollLines")) |n| {
                if (n >= 1) cfg.fullscreen_wheel_lines = @intCast(n);
            } else if (wv == .string and std.mem.eql(u8, wv.string, "auto")) {
                cfg.fullscreen_wheel_lines = null;
            }
        }
        // defaultTools: ["read", "+bash", ...] (may contain +name/-name modifiers)
        if (root.get("defaultTools")) |tv| {
            const arr = switch (tv) {
                .array => |a| a,
                else => break :blk,
            };
            const names = try alloc.alloc([]const u8, arr.items.len);
            var filled: usize = 0;
            var ok = true;
            for (arr.items, 0..) |item, idx| {
                const s = switch (item) {
                    .string => |str| str,
                    else => {
                        ok = false;
                        break;
                    },
                };
                names[idx] = try alloc.dupe(u8, s);
                filled = idx + 1;
            }
            if (ok) {
                cfg.default_tools = names;
            } else {
                for (0..filled) |idx| alloc.free(names[idx]);
                alloc.free(names);
            }
        }
        // compaction: { enabled, reserveTokens, keepRecentTokens }
        if (root.get("compaction")) |cv| {
            const obj = switch (cv) {
                .object => |o| o,
                else => break :blk,
            };
            if (numIn(obj, "reserveTokens")) |n| cfg.compaction.reserve_tokens = @intCast(n);
            if (numIn(obj, "keepRecentTokens")) |n| cfg.compaction.keep_recent_tokens = @intCast(n);
            cfg.compaction.enabled = boolIn(obj, "enabled", cfg.compaction.enabled);
        }
    }

    // 4. models.json — custom providers
    var provider_infos = std.array_list.Managed(ProviderInfo).init(alloc);
    defer {
        for (provider_infos.items) |pi| {
            alloc.free(pi.id);
            alloc.free(pi.base_url);
            alloc.free(pi.api_key);
        }
        provider_infos.deinit();
    }

    if (readAgentFile(alloc, io, cfg.base_dir, "models.json", &buf)) |data| blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch {
            std.debug.print("warning: invalid JSON in {s}/models.json\n", .{cfg.base_dir});
            break :blk;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => break :blk,
        };
        const providers = switch (root.get("providers") orelse break :blk) {
            .object => |o| o,
            else => break :blk,
        };

        var it = providers.iterator();
        while (it.next()) |e| {
            const pid = e.key_ptr.*;
            const p = switch (e.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };

            const p_base = strIn(p, "baseUrl") orelse "";
            const p_auth_header = boolIn(p, "authHeader", false);

            // Resolve provider API key: apiKey → auth.json → built-in env
            var key: []u8 = "";
            if (strIn(p, "apiKey")) |raw| {
                key = resolveValue(alloc, io, raw, environ) catch "";
            }
            if (key.len == 0) {
                for (auth.items) |a| {
                    if (std.mem.eql(u8, a.provider, pid)) {
                        key = try alloc.dupe(u8, a.key);
                        break;
                    }
                }
            }
            if (key.len == 0) {
                if (builtinEnv(pid)) |env_name| {
                    if (std.process.Environ.getPosix(environ, env_name)) |v| {
                        key = try alloc.dupe(u8, std.mem.sliceTo(v, 0));
                    }
                }
            }

            // Remember provider info for default-model synthesis
            provider_infos.append(.{
                .id = try alloc.dupe(u8, pid),
                .base_url = try alloc.dupe(u8, p_base),
                .api_key = try alloc.dupe(u8, key),
                .auth_header = p_auth_header,
            }) catch {};

            const models_v = p.get("models") orelse {
                if (key.len > 0) alloc.free(key);
                continue;
            };
            const arr = switch (models_v) {
                .array => |a| a,
                else => {
                    if (key.len > 0) alloc.free(key);
                    continue;
                },
            };

            for (arr.items) |item| {
                const mo = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const mid = strIn(mo, "id") orelse continue;
                const m_base = strIn(mo, "baseUrl") orelse p_base;
                if (m_base.len == 0) continue; // no endpoint → unusable
                try cfg.models.append(.{
                    .provider = try alloc.dupe(u8, pid),
                    .id = try alloc.dupe(u8, mid),
                    .name = try alloc.dupe(u8, strIn(mo, "name") orelse mid),
                    .base_url = try alloc.dupe(u8, m_base),
                    .api_key = try alloc.dupe(u8, key),
                    .auth_header = strIn(mo, "authHeader") != null or p_auth_header,
                    .context_window = numIn(mo, "contextWindow") orelse 128000,
                    .max_tokens = numIn(mo, "maxTokens") orelse 16384,
                    .reasoning = boolIn(mo, "reasoning", false),
                    .thinking_level = ThinkingLevel.defaultFor(boolIn(mo, "reasoning", false), strIn(mo, "thinkingLevel")),
                    .thinking_format = blk_tf: {
                        const tf = strIn(mo, "thinkingFormat") orelse break :blk_tf .default;
                        if (std.mem.eql(u8, tf, "zai")) break :blk_tf .zai;
                        if (std.mem.eql(u8, tf, "qwen")) break :blk_tf .qwen;
                        break :blk_tf .default;
                    },
                    .supports_reasoning_effort = triBoolIn(mo, "supportsReasoningEffort"),
                    .thinking_level_map = blk_tm: {
                        var map = [6]?[]u8{null, null, null, null, null, null};
                        if (mo.get("thinkingLevelMap")) |tm| {
                            if (tm == .object) {
                                for (&map, 0..) |*slot, li| {
                                    const lv_name = @as(ThinkingLevel, @enumFromInt(li)).name();
                                    if (tm.object.get(lv_name)) |v| {
                                        if (v == .string) slot.* = alloc.dupe(u8, v.string) catch null;
                                    }
                                }
                            }
                        }
                        break :blk_tm map;
                    },
                    .cost_input = costIn(mo, "input"),
                    .cost_output = costIn(mo, "output"),
                    .cost_cache_read = costIn(mo, "cacheRead"),
                    .cost_cache_write = costIn(mo, "cacheWrite"),
                });
            }
            if (key.len > 0) alloc.free(key);
        }
    }

    // 5. Built-in providers (auth.json / env credentials), not overridden in models.json
    for (builtins) |b| {
        var defined = false;
        for (provider_infos.items) |pi| {
            if (std.mem.eql(u8, pi.id, b.id)) {
                defined = true;
                break;
            }
        }
        if (defined) continue;

        var key: []u8 = "";
        for (auth.items) |a| {
            if (std.mem.eql(u8, a.provider, b.id)) {
                key = try alloc.dupe(u8, a.key);
                break;
            }
        }
        if (key.len == 0) {
            if (std.process.Environ.getPosix(environ, b.env_var)) |v| {
                key = try alloc.dupe(u8, std.mem.sliceTo(v, 0));
            }
        }
        const is_default = cfg.default_provider != null and
            std.mem.eql(u8, cfg.default_provider.?, b.id);
        if (key.len == 0 and !is_default) {
            if (key.len > 0) alloc.free(key);
            continue;
        }

        var added = false;
        for (builtin_models) |bm| {
            if (!std.mem.eql(u8, bm.provider, b.id)) continue;
            try cfg.models.append(.{
                .provider = try alloc.dupe(u8, b.id),
                .id = try alloc.dupe(u8, bm.id),
                .name = try alloc.dupe(u8, bm.name),
                .base_url = try alloc.dupe(u8, b.base_url),
                .api_key = try alloc.dupe(u8, key),
                .context_window = bm.ctx,
                .max_tokens = bm.max,
                .reasoning = bm.reasoning,
                .thinking_level = if (bm.reasoning) ThinkingLevel.high else .off,
                .cost_input = bm.cost_input,
                .cost_output = bm.cost_output,
                .cost_cache_read = bm.cost_cache_read,
                .cost_cache_write = 0,
            });
            added = true;
        }
        if (!added and is_default) {
            if (cfg.default_model) |dm| {
                try cfg.models.append(.{
                    .provider = try alloc.dupe(u8, b.id),
                    .id = try alloc.dupe(u8, dm),
                    .name = try alloc.dupe(u8, dm),
                    .base_url = try alloc.dupe(u8, b.base_url),
                    .api_key = try alloc.dupe(u8, key),
                });
            }
        }
        if (key.len > 0) alloc.free(key);
    }

    // 6. Synthesize settings default model if still missing
    if (cfg.default_provider != null and cfg.default_model != null) {
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cfg.default_provider.?, cfg.default_model.? });
        defer alloc.free(full);
        if (cfg.findModel(full) == null) {
            var base: []const u8 = "";
            var key: []const u8 = "";
            var auth_header = false;
            for (provider_infos.items) |pi| {
                if (std.mem.eql(u8, pi.id, cfg.default_provider.?)) {
                    base = pi.base_url;
                    key = pi.api_key;
                    auth_header = pi.auth_header;
                    break;
                }
            }
            if (base.len == 0) {
                if (builtinBaseUrl(cfg.default_provider.?)) |bb| {
                    base = bb;
                    if (builtinEnv(cfg.default_provider.?)) |env_name| {
                        if (std.process.Environ.getPosix(environ, env_name)) |v| {
                            key = std.mem.sliceTo(v, 0);
                        }
                    }
                }
            }
            if (key.len == 0) {
                for (auth.items) |a| {
                    if (std.mem.eql(u8, a.provider, cfg.default_provider.?)) {
                        key = a.key;
                        break;
                    }
                }
            }
            if (base.len > 0) {
                try cfg.models.append(.{
                    .provider = try alloc.dupe(u8, cfg.default_provider.?),
                    .id = try alloc.dupe(u8, cfg.default_model.?),
                    .name = try alloc.dupe(u8, cfg.default_model.?),
                    .base_url = try alloc.dupe(u8, base),
                    .api_key = try alloc.dupe(u8, key),
                    .auth_header = auth_header,
                });
            }
        }
    }

    if (cfg.models.items.len == 0) {
        std.debug.print("error: no models configured in {s} (models.json / auth.json)\n", .{cfg.base_dir});
        return error.NoModels;
    }

    return cfg;
}
