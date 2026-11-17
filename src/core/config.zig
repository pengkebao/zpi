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
const command_tools = @import("../tools/command_tools.zig");

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
/// (GLM series); .qwen → `enable_thinking` (DashScope/Qwen);
/// .qwen_chat_template → `chat_template_kwargs:{enable_thinking,
/// preserve_thinking}` (local vLLM/SGLang Qwen endpoints).
pub const ThinkingFormat = enum { default, zai, qwen, qwen_chat_template };

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
pub const DefaultProjectTrust = enum { ask, always, never };

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
    /// settings.json "defaultProjectTrust" (pi): "ask" (default) | "always" |
    /// "never" — what to do when a project has trust-gated resources and no
    /// saved decision.
    default_project_trust: DefaultProjectTrust = .ask,
    /// settings.json "defaultThinkingLevel": the · default marker in the
    /// thinking selector (pi defaultThinkingLevel).
    default_thinking_level: ?ThinkingLevel = null,
    /// settings.json "steeringMode" (pi default "one-at-a-time"): "all"
    /// delivers every queued steering message before the next LLM request,
    /// "one-at-a-time" delivers one per round.
    steering_mode_all: bool = false,
    /// settings.json "followUpMode" (pi default "one-at-a-time"): "all"
    /// drains follow-ups as one combined new turn, "one-at-a-time" starts
    /// one follow-up turn per settled round.
    follow_up_mode_all: bool = false,
    /// settings.json "enabledModels": patterns ("provider/id" or
    /// "provider/*") limiting the Ctrl+P model cycle. null = all enabled
    /// (pi enabledModels).
    enabled_models: ?[]const []const u8 = null,
    /// settings.json "commandTools" (Phase I1): shell commands exposed to
    /// the model as tools. Owned; merged across global + project settings.
    command_tools: []command_tools.CommandTool = &.{},

    pub fn deinitCommandTools(self: *Config, alloc: std.mem.Allocator) void {
        command_tools.freeAll(alloc, self.command_tools);
        self.command_tools = &.{};
    }

    pub const Model = struct {
        provider: []u8,
        id: []u8,
        name: []u8, // display name
        base_url: []u8,
        api_key: []u8, // resolved key ("" if none)
        /// Wire protocol: "openai-completions" (default) | "anthropic-messages"
        /// | "openai-responses" | "google-generative-ai" (pi-ai api field).
        api: []u8,
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
        if (self.enabled_models) |pats| {
            for (pats) |pat| alloc.free(pat);
            alloc.free(pats);
        }
        command_tools.freeAll(alloc, self.command_tools);
        for (self.models.items) |m| {
            alloc.free(m.provider);
            alloc.free(m.id);
            alloc.free(m.name);
            alloc.free(m.base_url);
            alloc.free(m.api_key);
            alloc.free(m.api);
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
    /// Resolution outcome for a CLI / --model pattern (pi resolveModelReference):
    /// exact provider/id, exact id, provider-filtered fuzzy (substring),
    /// unfiltered fuzzy with ambiguity reporting, and custom-id fallback.
    pub const ModelResolution = union(enum) {
        resolved: *const Model,
        /// Same id offered by several providers — ask for provider/id.
        ambiguous_id: void,
        /// Fuzzy matched several models — picks the best (shortest id,
        /// alias over dated) but reports the rest.
        fuzzy: struct { model: *const Model, others: []*const Model },
        not_found: void,
    };

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// pi bestFuzzyMatch: alias ids (no -YYYYMMDD date suffix) beat dated
    /// ones; then the lexicographically greatest id wins (latest).
    fn fuzzyBetter(a: *const Model, b: *const Model) bool {
        const a_alias = !hasDateSuffix(a.id);
        const b_alias = !hasDateSuffix(b.id);
        if (a_alias != b_alias) return a_alias;
        return std.mem.order(u8, a.id, b.id) == .gt;
    }

    fn hasDateSuffix(id: []const u8) bool {
        if (id.len < 9) return false;
        const tail = id[id.len - 8 ..];
        for (tail) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return id[id.len - 9] == '-';
    }

    /// Resolve a model pattern (pi resolveModelReference, fuzzy=true):
    /// 1. "provider/id" exact → 2. id exact across providers (ambiguity if
    /// several) → 3. provider-scoped fuzzy substring → 4. global fuzzy
    /// substring with best-match pick.
    pub fn resolveModelPattern(
        self: *const Config,
        text: []const u8,
        provider_filter: ?[]const u8,
        alloc: std.mem.Allocator,
    ) ModelResolution {
        // provider/id exact (+ provider filter must agree)
        if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
            const pid = text[0..slash];
            const mid = text[slash + 1 ..];
            var hit: ?*const Model = null;
            for (self.models.items) |*m| {
                if (std.mem.eql(u8, m.provider, pid) and std.mem.eql(u8, m.id, mid)) {
                    hit = m;
                    break;
                }
            }
            if (hit) |m| return .{ .resolved = m };
            // provider-scoped fuzzy on the id part
            var best: ?*const Model = null;
            for (self.models.items) |*m| {
                if (!std.mem.eql(u8, m.provider, pid)) continue;
                if (containsIgnoreCase(m.id, mid) or containsIgnoreCase(m.name, mid)) {
                    if (best == null or fuzzyBetter(m, best.?)) best = m;
                }
            }
            if (best) |m| return .{ .resolved = m };
            return .not_found;
        }

        // provider filter (case-insensitive match on provider id)
        var scoped: ?[]const u8 = null;
        if (provider_filter) |pf| {
            for (self.models.items) |*m| {
                if (std.ascii.eqlIgnoreCase(m.provider, pf)) {
                    scoped = m.provider;
                    break;
                }
            }
            if (scoped == null) return .not_found;
        }

        // exact id (within provider scope if any)
        var exact: ?*const Model = null;
        var multiple = false;
        for (self.models.items) |*m| {
            if (scoped) |sp| {
                if (!std.mem.eql(u8, m.provider, sp)) continue;
            }
            if (std.mem.eql(u8, m.id, text)) {
                if (exact == null) {
                    exact = m;
                } else {
                    multiple = true;
                }
            }
        }
        if (exact) |m| {
            if (multiple) return .ambiguous_id;
            return .{ .resolved = m };
        }

        // fuzzy substring on id/name
        var best: ?*const Model = null;
        var others = std.array_list.Managed(*const Model).init(alloc);
        for (self.models.items) |*m| {
            if (scoped) |sp| {
                if (!std.mem.eql(u8, m.provider, sp)) continue;
            }
            if (containsIgnoreCase(m.id, text) or containsIgnoreCase(m.name, text)) {
                if (best == null or fuzzyBetter(m, best.?)) {
                    if (best) |b| others.append(b) catch {};
                    best = m;
                } else {
                    others.append(m) catch {};
                }
            }
        }
        if (best) |m| {
            return .{ .fuzzy = .{ .model = m, .others = others.toOwnedSlice() catch &.{} } };
        }
        return .not_found;
    }

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
    /// Apply one settings.json JSON object (shared by the global agent-dir
    /// settings and the project `.pi/settings.json`, which overrides — pi
    /// settings-manager project scope). Fields already set are freed/re-set.
    fn applySettingsValue(self: *Config, alloc: std.mem.Allocator, root: std.json.ObjectMap) void {
        if (strIn(root, "defaultProvider")) |dp| {
            if (self.default_provider) |old| alloc.free(old);
            self.default_provider = alloc.dupe(u8, dp) catch null;
        }
        if (strIn(root, "defaultModel")) |dm| {
            if (self.default_model) |old| alloc.free(old);
            self.default_model = alloc.dupe(u8, dm) catch null;
        }
        // pi steeringMode / followUpMode: "all" | "one-at-a-time".
        if (strIn(root, "steeringMode")) |m| {
            self.steering_mode_all = std.mem.eql(u8, m, "all");
        }
        if (strIn(root, "followUpMode")) |m| {
            self.follow_up_mode_all = std.mem.eql(u8, m, "all");
        }
        // Fullscreen scrollbar: "auto" (pi default) | "always" | "hidden".
        if (strIn(root, "fullscreenScrollbar")) |sb| {
            if (std.mem.eql(u8, sb, "always")) self.fullscreen_scrollbar = .always;
            if (std.mem.eql(u8, sb, "hidden")) self.fullscreen_scrollbar = .hidden;
        }
        // Lines per wheel event; "auto" (or anything else) is velocity-based.
        if (root.get("fullscreenWheelScrollLines")) |wv| {
            if (numIn(root, "fullscreenWheelScrollLines")) |n| {
                if (n >= 1) self.fullscreen_wheel_lines = @intCast(n);
            } else if (wv == .string and std.mem.eql(u8, wv.string, "auto")) {
                self.fullscreen_wheel_lines = null;
            }
        }
        // defaultProjectTrust: "ask" (default) | "always" | "never".
        if (strIn(root, "defaultProjectTrust")) |t| {
            if (std.mem.eql(u8, t, "always")) self.default_project_trust = .always;
            if (std.mem.eql(u8, t, "never")) self.default_project_trust = .never;
            if (std.mem.eql(u8, t, "ask")) self.default_project_trust = .ask;
        }
        // defaultTools: ["read", "+bash", ...] (may contain +name/-name modifiers)
        if (root.get("defaultTools")) |tv| {
            const arr = switch (tv) {
                .array => |a| a,
                else => return,
            };
            if (self.default_tools) |old| freeDefaultTools(alloc, old);
            const names = alloc.alloc([]const u8, arr.items.len) catch return;
            var filled: usize = 0;
            var ok = true;
            for (arr.items, 0..) |item, idx| {
                const str = switch (item) {
                    .string => |str| str,
                    else => {
                        ok = false;
                        break;
                    },
                };
                names[idx] = alloc.dupe(u8, str) catch {
                    ok = false;
                    break;
                };
                filled = idx + 1;
            }
            if (ok) {
                self.default_tools = names;
            } else {
                for (0..filled) |idx| alloc.free(names[idx]);
                alloc.free(names);
            }
        }
        // compaction: { enabled, reserveTokens, keepRecentTokens }
        if (root.get("compaction")) |cv| {
            const obj = switch (cv) {
                .object => |o| o,
                else => return,
            };
            if (numIn(obj, "reserveTokens")) |n| self.compaction.reserve_tokens = @intCast(n);
            if (numIn(obj, "keepRecentTokens")) |n| self.compaction.keep_recent_tokens = @intCast(n);
            self.compaction.enabled = boolIn(obj, "enabled", self.compaction.enabled);
        }
        // defaultThinkingLevel: "off".."max" (pi defaultThinkingLevel).
        if (strIn(root, "defaultThinkingLevel")) |dl| {
            self.default_thinking_level = ThinkingLevel.fromStr(dl);
        }
        // enabledModels: ["provider/id", "provider/*"] patterns.
        if (root.get("enabledModels")) |ev| {
            switch (ev) {
                .array => |arr| {
                    var pats = std.array_list.Managed([]const u8).init(alloc);
                    for (arr.items) |item| {
                        switch (item) {
                            .string => |str| pats.append(alloc.dupe(u8, str) catch continue) catch {},
                            else => {},
                        }
                    }
                    if (self.enabled_models) |old_pats| {
                        for (old_pats) |op| alloc.free(op);
                        alloc.free(old_pats);
                    }
                    self.enabled_models = pats.toOwnedSlice() catch null;
                },
                .null => {
                    if (self.enabled_models) |old_pats| {
                        for (old_pats) |op| alloc.free(op);
                        alloc.free(old_pats);
                    }
                    self.enabled_models = null;
                },
                else => {},
            }
        }
        // commandTools (Phase I1): merged — project entries append to the
        // global ones (names later in the list shadow earlier duplicates).
        if (root.get("commandTools")) |_| {
            const extra = command_tools.parseSettings(alloc, root);
            // NOTE: entries are MOVED into the merged list below — do NOT
            // freeAll(extra) here (the strings now belong to cfg).
            var merged = std.array_list.Managed(command_tools.CommandTool).init(alloc);
            merged.appendSlice(self.command_tools) catch return;
            for (extra) |e| {
                // skip same-name duplicates (later wins — free the old entry)
                var replaced = false;
                for (merged.items) |*m| {
                    if (std.mem.eql(u8, m.name, e.name)) {
                        alloc.free(m.command);
                        alloc.free(m.description);
                        alloc.free(m.schema_json);
                        m.* = e;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) merged.append(e) catch {};
            }
            // entries moved into `merged`; drop the extra shell list
            if (extra.len > 0) alloc.free(extra);
            if (self.command_tools.len > 0) alloc.free(self.command_tools);
            self.command_tools = merged.toOwnedSlice() catch &.{};
        }
    }

    /// Load `<cwd>/.pi/settings.json` (project scope) on top of the global
    /// settings. Project-trust gated: the caller only invokes this when the
    /// project is trusted (pi settings-manager project scope).
    

pub fn loadProjectSettings(self: *Config, alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !void {
        var buf: [1 << 20]u8 = undefined;
        const joined = std.fmt.allocPrint(alloc, "{s}/.pi/settings.json", .{cwd}) catch return error.OutOfMemory;
        defer alloc.free(joined);
        const data = std.Io.Dir.cwd().readFile(io, joined, &buf) catch return error.NotFound;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidJson,
        };
        self.applySettingsValue(alloc, root);
    }

    pub fn persistSettings(self: *Config, alloc: std.mem.Allocator, io: std.Io) !void {
        const path = try std.fmt.allocPrint(alloc, "{s}/settings.json", .{self.base_dir});
        defer alloc.free(path);
        const buf: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch null;
        defer if (buf) |b| alloc.free(b);

        // ONE arena owns parse + mutation + stringify (the setEntryField
        // lesson: an arena-owned ObjectMap must never be grown with another
        // allocator — gpa put on parsed keys/values panicked with
        // "free after resize" as soon as a real settings.json grew the map).
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var root: std.json.Value = if (buf) |b| blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, arena, b, .{}) catch break :blk .{ .object = std.json.ObjectMap.empty };
            // NOT deinit'd: the outer arena frees everything at once.
            break :blk parsed.value;
        } else .{ .object = std.json.ObjectMap.empty };

        var comp = std.json.ObjectMap.empty;
        try comp.put(arena, "enabled", .{ .bool = self.compaction.enabled });
        try comp.put(arena, "reserveTokens", .{ .integer = @intCast(self.compaction.reserve_tokens) });
        try comp.put(arena, "keepRecentTokens", .{ .integer = @intCast(self.compaction.keep_recent_tokens) });
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
                    if (!known) try comp.put(arena, e.key_ptr.*, e.value_ptr.*);
                }
            }
        }
        try root.object.put(arena, "compaction", .{ .object = comp });
        if (self.default_provider) |dp| try root.object.put(arena, "defaultProvider", .{ .string = dp });
        if (self.default_model) |dm| try root.object.put(arena, "defaultModel", .{ .string = dm });
        if (self.default_thinking_level) |dtl| try root.object.put(arena, "defaultThinkingLevel", .{ .string = dtl.name() });
        if (self.enabled_models) |pats| {
            var arr = std.json.Array.init(arena);
            for (pats) |pat| arr.append(.{ .string = pat }) catch {};
            try root.object.put(arena, "enabledModels", .{ .array = arr });
        }

        const json_text = try std.json.Stringify.valueAlloc(arena, root, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json_text });
    }
};

/// Store (or update) an api_key credential in <agent-dir>/auth.json,
/// preserving unrelated fields (pi auth-storage semantics).
pub fn saveAuthEntry(alloc: std.mem.Allocator, io: std.Io, base_dir: []const u8, provider: []const u8, key: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/auth.json", .{base_dir});
    defer alloc.free(path);
    var root: std.json.ObjectMap = .empty;
    var buf: [1 << 16]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, path, &buf)) |data| {
        if (std.json.parseFromSlice(std.json.Value, alloc, data, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) root = parsed.value.object;
        } else |_| {}
    } else |_| {}
    // NOTE: root keys alias the parsed arena; rebuild the object with owned
    // copies via stringify of a fresh value tree instead of mutating in place
    // across allocators (the setEntryField lesson).
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    try out.append('{');
    var wrote = false;
    if (root.count() > 0) {
        var it = root.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, provider)) continue; // replaced below
            if (wrote) try out.append(',');
            wrote = true;
            try appendJsonStringField(&out, e.key_ptr.*, e.value_ptr.*);
        }
    }
    if (wrote) try out.append(',');
    wrote = true;
    try out.append('"');
    try out.appendSlice(provider);
    try out.appendSlice("\":{\"type\":\"api_key\",\"key\":");
    try appendJsonString(&out, key);
    try out.append('}');
    try out.append('}');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Remove a provider's credential from <agent-dir>/auth.json.
pub fn removeAuthEntry(alloc: std.mem.Allocator, io: std.Io, base_dir: []const u8, provider: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/auth.json", .{base_dir});
    defer alloc.free(path);
    var buf: [1 << 16]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, path, &buf) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    try out.append('{');
    var wrote = false;
    var it = root.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, provider)) continue;
        if (wrote) try out.append(',');
        wrote = true;
        try appendJsonStringField(&out, e.key_ptr.*, e.value_ptr.*);
    }
    try out.append('}');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Copy a JSON value (from a parsed arena) into `out` as `"key":value`.
fn appendJsonStringField(out: *std.array_list.Managed(u8), key: []const u8, value: std.json.Value) !void {
    try out.append('"');
    try out.appendSlice(key);
    try out.appendSlice("\":");
    const rendered = std.json.Stringify.valueAlloc(out.allocator, value, .{}) catch "null";
    defer if (rendered.len > 0) out.allocator.free(@constCast(rendered));
    try out.appendSlice(rendered);
}

fn appendJsonString(out: *std.array_list.Managed(u8), s: []const u8) !void {
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
                    var buf: [8]u8 = undefined;
                    const w = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(w);
                } else {
                    try out.append(c);
                }
            },
        }
    }
    try out.append('"');
}


// ── Built-in provider catalog (generated from pi-ai's model catalog) ──
// tools/gen_catalog.py regenerates src/ai/catalog.json from pi 1.5.0:
// chat models on the four wire protocols zpi implements, from providers
// that authenticate with a plain API-key env var (~23 providers, ~700
// models: openai-completions / anthropic-messages / openai-responses /
// google-generative-ai).

const catalog_text = @embedFile("../ai/catalog.json");

/// Parsed catalog handle (valid while `parsed` is alive).
const Catalog = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn providers(self: *const Catalog) ?std.json.Array {
        return switch (self.parsed.value) {
            .object => |o| switch (o.get("providers") orelse return null) {
                .array => |a| a,
                else => null,
            },
            else => null,
        };
    }

    fn find(self: *const Catalog, provider_id: []const u8) ?std.json.ObjectMap {
        const arr = self.providers() orelse return null;
        for (arr.items) |item| {
            switch (item) {
                .object => |o| {
                    const id = o.get("id") orelse continue;
                    switch (id) {
                        .string => |sid| if (std.mem.eql(u8, sid, provider_id)) return o,
                        else => {},
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .string => |x| x,
            else => null,
        };
    }

    fn envVar(self: *const Catalog, provider_id: []const u8) ?[]const u8 {
        const o = self.find(provider_id) orelse return null;
        return str(o, "env");
    }

    fn baseUrl(self: *const Catalog, provider_id: []const u8) ?[]const u8 {
        const o = self.find(provider_id) orelse return null;
        return str(o, "baseUrl");
    }
};

fn parseCatalog(alloc: std.mem.Allocator) ?Catalog {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, catalog_text, .{}) catch return null;
    return .{ .parsed = parsed };
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
        cfg.applySettingsValue(alloc, root);
    }

    // Catalog handle for env-var fallbacks in models.json providers.
    var cat_for_env_holder: ?Catalog = parseCatalog(alloc);
    defer if (cat_for_env_holder) |*c| c.parsed.deinit();
    const cat_for_env: *const Catalog = &(cat_for_env_holder.?);

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
                if (cat_for_env.envVar(pid)) |env_name| {
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
                    .api = blk_api: {
                        const a = strIn(mo, "api") orelse strIn(p, "api") orelse "openai-completions";
                        break :blk_api try alloc.dupe(u8, a);
                    },
                    .api_key = try alloc.dupe(u8, key),
                    .auth_header = strIn(mo, "authHeader") != null or p_auth_header,
                    .context_window = numIn(mo, "contextWindow") orelse 128000,
                    .max_tokens = numIn(mo, "maxTokens") orelse 16384,
                    .reasoning = boolIn(mo, "reasoning", false),
                    .thinking_level = ThinkingLevel.defaultFor(boolIn(mo, "reasoning", false), strIn(mo, "thinkingLevel")),
                    .thinking_format = blk_tf: {
                        // pi models.json nests this under compat.thinkingFormat.
                        const compat = if (mo.get("compat")) |c| blk_c: {
                            switch (c) {
                                .object => |o| break :blk_c o,
                                else => break :blk_c null,
                            }
                        } else null;
                        const tf = strIn(mo, "thinkingFormat") orelse (if (compat) |c| strIn(c, "thinkingFormat") else null) orelse break :blk_tf .default;
                        if (std.mem.eql(u8, tf, "zai")) break :blk_tf .zai;
                        if (std.mem.eql(u8, tf, "qwen")) break :blk_tf .qwen;
                        if (std.mem.eql(u8, tf, "qwen-chat-template")) break :blk_tf .qwen_chat_template;
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

    // 5. Built-in catalog providers (auth.json / env credentials), not
    // overridden in models.json. The full generated catalog (~23 providers,
    // ~700 models across the four wire protocols) is embedded.
    if (parseCatalog(alloc)) |*cat| {
        defer cat.parsed.deinit();
        if (cat.providers()) |cat_providers| {
            for (cat_providers.items) |item| {
                const po = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const pid = Catalog.str(po, "id") orelse continue;

                var defined = false;
                for (provider_infos.items) |pi| {
                    if (std.mem.eql(u8, pi.id, pid)) {
                        defined = true;
                        break;
                    }
                }
                if (defined) continue;

                var key: []u8 = "";
                for (auth.items) |a| {
                    if (std.mem.eql(u8, a.provider, pid)) {
                        key = try alloc.dupe(u8, a.key);
                        break;
                    }
                }
                if (key.len == 0) {
                    if (Catalog.str(po, "env")) |env_name| {
                        if (std.process.Environ.getPosix(environ, env_name)) |v| {
                            key = try alloc.dupe(u8, std.mem.sliceTo(v, 0));
                        }
                    }
                }
                const is_default = cfg.default_provider != null and
                    std.mem.eql(u8, cfg.default_provider.?, pid);
                if (key.len == 0 and !is_default) {
                    if (key.len > 0) alloc.free(key);
                    continue;
                }

                const prov_base = Catalog.str(po, "baseUrl") orelse "";
                var added = false;
                if (po.get("models")) |mv| {
                    switch (mv) {
                        .array => |marr| {
                            for (marr.items) |mi| {
                                const mo = switch (mi) {
                                    .object => |o| o,
                                    else => continue,
                                };
                                const mid = Catalog.str(mo, "id") orelse continue;
                                const m_api = Catalog.str(mo, "api") orelse "openai-completions";
                                const m_base = Catalog.str(mo, "baseUrl") orelse prov_base;
                                if (m_base.len == 0) continue;
                                try cfg.models.append(.{
                                    .provider = try alloc.dupe(u8, pid),
                                    .id = try alloc.dupe(u8, mid),
                                    .name = try alloc.dupe(u8, Catalog.str(mo, "name") orelse mid),
                                    .base_url = try alloc.dupe(u8, m_base),
                                    .api = try alloc.dupe(u8, m_api),
                                    .api_key = try alloc.dupe(u8, key),
                                    .context_window = @intCast(numIn(mo, "ctx") orelse 128000),
                                    .max_tokens = @intCast(numIn(mo, "max") orelse 16384),
                                    .reasoning = boolIn(mo, "reasoning", false),
                                    .thinking_level = if (boolIn(mo, "reasoning", false)) ThinkingLevel.high else .off,
                                    .thinking_format = blk_ctf: {
                                        const tf = Catalog.str(mo, "tf") orelse break :blk_ctf .default;
                                        if (std.mem.eql(u8, tf, "zai")) break :blk_ctf .zai;
                                        if (std.mem.eql(u8, tf, "qwen")) break :blk_ctf .qwen;
                                        if (std.mem.eql(u8, tf, "qwen-chat-template")) break :blk_ctf .qwen_chat_template;
                                        break :blk_ctf .default;
                                    },
                                    .supports_images = boolIn(mo, "images", true),
                                    .thinking_level_map = blk_cmap: {
                                        var map = [6]?[]u8{null, null, null, null, null, null};
                                        if (mo.get("map")) |tm| {
                                            if (tm == .object) {
                                                for (&map, 0..) |*slot, li| {
                                                    const lv_name = @as(ThinkingLevel, @enumFromInt(li)).name();
                                                    if (tm.object.get(lv_name)) |v| {
                                                        if (v == .string) slot.* = alloc.dupe(u8, v.string) catch null;
                                                    }
                                                }
                                            }
                                        }
                                        break :blk_cmap map;
                                    },
                                    // catalog.json stores rates flat (USD per
                                    // million), unlike models.json's nested cost
                                    // object.
                                    .cost_input = floatIn(mo, "ci"),
                                    .cost_output = floatIn(mo, "co"),
                                    .cost_cache_read = floatIn(mo, "cr"),
                                    .cost_cache_write = floatIn(mo, "cw"),
                                });
                                added = true;
                            }
                        },
                        else => {},
                    }
                }
                if (!added and is_default) {
                    if (cfg.default_model) |dm| {
                        try cfg.models.append(.{
                            .provider = try alloc.dupe(u8, pid),
                            .id = try alloc.dupe(u8, dm),
                            .name = try alloc.dupe(u8, dm),
                            .base_url = try alloc.dupe(u8, prov_base),
                            .api = try alloc.dupe(u8, "openai-completions"),
                            .api_key = try alloc.dupe(u8, key),
                        });
                    }
                }
                if (key.len > 0) alloc.free(key);
            }
        }
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
            var cat_holder: ?Catalog = null;
            defer if (cat_holder) |*c| c.parsed.deinit();
            cat_holder = parseCatalog(alloc);
            if (base.len == 0) {
                if (cat_holder) |*c| {
                    if (c.baseUrl(cfg.default_provider.?)) |bb| {
                        base = bb;
                        if (c.envVar(cfg.default_provider.?)) |env_name| {
                            if (std.process.Environ.getPosix(environ, env_name)) |v| {
                                key = std.mem.sliceTo(v, 0);
                            }
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
                    .api = try alloc.dupe(u8, "openai-completions"),
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

fn freeDefaultTools(alloc: std.mem.Allocator, tools_list: []const []const u8) void {
    for (tools_list) |t| alloc.free(t);
    alloc.free(tools_list);
}
