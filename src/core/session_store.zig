//! Session persistence: pi-compatible JSONL v3 session files.
//!
//! Layout (matches pi 1.5.0 session-format.md):
//!   ~/.pi/agent/sessions/--<cwd-with-separators-dashed>--/<ISO-ts>_<uuid>.jsonl
//!
//! Line 1: {"type":"session","version":3,"id":"<uuid>","timestamp":"<ISO>","cwd":"<abs>"}
//!   (+ "parentSession":"<path>" when forked)
//! Then entry lines:
//!   {"type":"message","id":"<8hex>","parentId":"<8hex>|null","timestamp":"<ISO>","message":{...}}
//!   {"type":"model_change",...,"provider":...,"modelId":...}
//!   {"type":"session_info",...,"name":"..."}
//!   {"type":"custom",...} / {"type":"compaction",...} (passthrough)
//!
//! Entries form a tree via id/parentId; the active branch is the parent chain
//! ending at the last entry (leaf). Persistence currently rewrites the whole
//! file per record (fine for KB-scale sessions; appendFile is a later优化).

const std = @import("std");
const msg = @import("message.zig");
const compact = @import("compaction.zig");

// ── time / id helpers ───────────────────────────────────────────────

pub fn nowMs(io: std.Io) i64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(std.math.divTrunc(i96, ns, 1_000_000) catch 0);
}

/// "YYYY-MM-DDTHH:MM:SS.mmmZ" from unix milliseconds.
pub fn formatIso(ms: i64, buf: []u8) []const u8 {
    const secs = @divFloor(ms, 1000);
    const millis: u32 = @intCast(@mod(ms, 1000));
    const days = @divFloor(secs, 86400);
    var secs_of_day = @mod(secs, 86400);
    const h: u32 = @intCast(@divFloor(secs_of_day, 3600));
    secs_of_day = @mod(secs_of_day, 3600);
    const min: u32 = @intCast(@divFloor(secs_of_day, 60));
    const sec: u32 = @intCast(@mod(secs_of_day, 60));

    // Howard Hinnant's civil_from_days
    var z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    z = 0;
    const year = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(year)), m, d, h, min, sec, millis,
    }) catch "1970-01-01T00:00:00.000Z";
}

/// UUID v4 string (36 chars), owned.
pub fn genUuid(alloc: std.mem.Allocator, io: std.Io) []u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    const hex = "0123456789abcdef";
    var out = alloc.alloc(u8, 36) catch return "";
    var oi: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0xf];
        oi += 2;
    }
    return out;
}

/// 8-hex entry id, owned.
fn genEntryId(alloc: std.mem.Allocator, io: std.Io) []u8 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(alloc, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch "";
}

// ── JSON emit helpers ───────────────────────────────────────────────

fn writeJsonStr(out: *std.array_list.Managed(u8), s: []const u8) !void {
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
                    var hex: [6]u8 = undefined;
                    const h = std.fmt.bufPrint(&hex, "\\u{X:0>4}", .{c}) catch continue;
                    try out.appendSlice(h);
                } else {
                    try out.append(c);
                }
            },
        }
    }
    try out.append('"');
}

fn writeJsonValue(out: *std.array_list.Managed(u8), v: std.json.Value) anyerror!void {
    switch (v) {
        .null => try out.appendSlice("null"),
        .bool => |b| try out.appendSlice(if (b) "true" else "false"),
        .integer => |n| try appendFmt(out, out.allocator, "{d}", .{n}),
        .float => |n| try appendFmt(out, out.allocator, "{d}", .{n}),
        .number_string => |s| try out.appendSlice(s),
        .string => |s| try writeJsonStr(out, s),
        .array => |a| {
            try out.append('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try out.append(',');
                try writeJsonValue(out, item);
            }
            try out.append(']');
        },
        .object => |o| {
            try out.append('{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try out.append(',');
                first = false;
                try writeJsonStr(out, e.key_ptr.*);
                try out.append(':');
                try writeJsonValue(out, e.value_ptr.*);
            }
            try out.append('}');
        },
    }
}


/// Extract a top-level string field from one JSONL entry line without a
/// full parse: scans for "key":"..." and returns an owned copy.
fn jsonStringField(alloc: std.mem.Allocator, line: []const u8, key: []const u8) ?[]u8 {
    var pat_buf: [96]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, line, pat) orelse return null;
    var i = idx + pat.len;
    var out = std.array_list.Managed(u8).init(alloc);
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') return out.toOwnedSlice() catch null;
        if (c == '\\') {
            i += 1;
            if (i >= line.len) break;
            const esc = line[i];
            const rep: u8 = switch (esc) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => esc,
            };
            out.append(rep) catch return null;
            continue;
        }
        out.append(c) catch return null;
        if (out.items.len > 4096) break;
    }
    out.deinit();
    return null;
}

/// Copy text into the ChainItem preview with newlines collapsed to spaces.
fn copyPreview(item: *Store.ChainItem, text: []const u8) void {
    var len: usize = 0;
    for (text) |c| {
        if (len >= item.preview.len) break;
        item.preview[len] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
        len += 1;
    }
    item.preview_len = len;
}

/// Fill a ChainItem's preview and user-message flag from the raw entry line.
fn extractPreview(alloc: std.mem.Allocator, e: EntryRef, item: *Store.ChainItem) void {
    switch (e.kind) {
        .message => {
            if (jsonStringField(alloc, e.line, "role")) |role| {
                defer alloc.free(role);
                item.is_user_message = std.mem.eql(u8, role, "user");
            }
            // Content is either a string or a block array: take the first
            // text block text, falling back to the raw string content.
            if (jsonStringField(alloc, e.line, "text")) |t| {
                defer alloc.free(t);
                copyPreview(item, t);
            } else if (jsonStringField(alloc, e.line, "content")) |t| {
                defer alloc.free(t);
                copyPreview(item, t);
            }
        },
        .session_info => {
            if (jsonStringField(alloc, e.line, "name")) |t| {
                defer alloc.free(t);
                copyPreview(item, t);
            }
        },
        .model_change => {
            const provider = jsonStringField(alloc, e.line, "provider");
            defer if (provider) |p| alloc.free(p);
            const model_id = jsonStringField(alloc, e.line, "modelId");
            defer if (model_id) |m| alloc.free(m);
            if (provider != null and model_id != null) {
                var tmp: [80]u8 = undefined;
                const joined = std.fmt.bufPrint(&tmp, "{s}/{s}", .{ provider.?, model_id.? }) catch "";
                copyPreview(item, joined);
            }
        },
        .thinking_level_change => {
            if (jsonStringField(alloc, e.line, "thinkingLevel")) |t| {
                defer alloc.free(t);
                copyPreview(item, t);
            }
        },
        .compaction, .branch_summary => {
            if (jsonStringField(alloc, e.line, "summary")) |t| {
                defer alloc.free(t);
                copyPreview(item, t);
            }
        },
        else => {},
    }
}

fn appendFmt(out: *std.array_list.Managed(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        const big = try alloc.alloc(u8, 2048);
        defer alloc.free(big);
        return out.appendSlice(try std.fmt.bufPrint(big, fmt, args));
    };
    try out.appendSlice(s);
}

// ── message ↔ JSON (pi AgentMessage shapes) ─────────────────────────

fn writeUsage(out: *std.array_list.Managed(u8), u: msg.Usage) !void {
    try out.appendSlice("\"usage\":{\"input\":");
    try appendFmt(out, out.allocator, "{d},\"output\":{d},\"cacheRead\":{d},\"cacheWrite\":{d},\"reasoning\":{d},\"totalTokens\":{d},\"cost\":{{\"input\":{d},\"output\":{d},\"cacheRead\":{d},\"cacheWrite\":{d},\"total\":{d},\"totalFromProvider\":false}}}}", .{
        u.input, u.output,      u.cache_read,       u.cache_write,
        u.reasoning, u.total, u.cost_input, u.cost_output, u.cost_cache_read, u.cost_cache_write, u.cost,
    });
}

pub fn writeMessageJson(out: *std.array_list.Managed(u8), m: *const msg.Message) !void {
    const ts: i64 = m.timestamp_ms;
    switch (m.role) {
        .user => {
            try out.appendSlice("{\"role\":\"user\",\"content\":[");
            for (m.blocks.items, 0..) |b, i| {
                if (i > 0) try out.append(',');
                switch (b) {
                    .text => |t| {
                        try out.appendSlice("{\"type\":\"text\",\"text\":");
                        try writeJsonStr(out, t);
                        try out.append('}');
                    },
                    else => {},
                }
            }
            try out.appendSlice("],\"timestamp\":");
            try appendFmt(out, out.allocator, "{d}", .{ts});
            try out.append('}');
        },
        .assistant => {
            try out.appendSlice("{\"role\":\"assistant\",\"content\":[");
            for (m.blocks.items, 0..) |b, i| {
                if (i > 0) try out.append(',');
                switch (b) {
                    .text => |t| {
                        try out.appendSlice("{\"type\":\"text\",\"text\":");
                        try writeJsonStr(out, t);
                        try out.append('}');
                    },
                    .thinking => |t| {
                        try out.appendSlice("{\"type\":\"thinking\",\"thinking\":");
                        try writeJsonStr(out, t);
                        try out.appendSlice(",\"thinkingSignature\":\"reasoning_content\"}");
                    },
                    .tool_call => |tc| {
                        try out.appendSlice("{\"type\":\"toolCall\",\"id\":");
                        try writeJsonStr(out, tc.id);
                        try out.appendSlice(",\"name\":");
                        try writeJsonStr(out, tc.name);
                        try out.appendSlice(",\"arguments\":");
                        // pi stores arguments as a JSON object
                        var parsed = std.json.parseFromSlice(std.json.Value, out.allocator, tc.arguments, .{}) catch null;
                        defer if (parsed != null) parsed.?.deinit();
                        if (parsed) |*p| {
                            try writeJsonValue(out, p.value);
                        } else {
                            try writeJsonStr(out, tc.arguments);
                        }
                        try out.append('}');
                    },
                    else => {},
                }
            }
            try out.appendSlice("],\"api\":\"openai-completions\"");
            if (m.provider) |p| {
                try out.appendSlice(",\"provider\":");
                try writeJsonStr(out, p);
            }
            if (m.model_id) |mid| {
                try out.appendSlice(",\"model\":");
                try writeJsonStr(out, mid);
            }
            if (m.usage) |u| {
                try out.append(',');
                try writeUsage(out, u);
            }
            if (m.stop_reason) |sr| {
                try out.appendSlice(",\"stopReason\":");
                try writeJsonStr(out, sr);
            }
            try out.appendSlice(",\"timestamp\":");
            try appendFmt(out, out.allocator, "{d}", .{ts});
            try out.append('}');
        },
        .bash_execution => {
            // pi bashExecution entry: role + command/output/exitCode/exclude
            try out.appendSlice("{\"role\":\"bashExecution\",\"command\":");
            try writeJsonStr(out, m.bash_command orelse "");
            try out.appendSlice(",\"output\":");
            var bout = std.array_list.Managed(u8).init(out.allocator);
            defer bout.deinit();
            for (m.blocks.items) |b| switch (b) {
                .text => |t| bout.appendSlice(t) catch {},
                else => {},
            };
            try writeJsonStr(out, bout.items);
            try out.appendSlice(",\"exitCode\":");
            if (m.bash_exit_code) |c| {
                try appendFmt(out, out.allocator, "{d}", .{c});
            } else {
                try out.appendSlice("null");
            }
            try out.appendSlice(",\"excludeFromContext\":");
            try out.appendSlice(if (m.bash_exclude) "true" else "false");
            try out.appendSlice(",\"timestamp\":");
            try appendFmt(out, out.allocator, "{d}", .{ts});
            try out.append('}');
        },
        .tool => {
            // One entry per tool_result block (pi: one message per result)
            var first = true;
            for (m.blocks.items) |b| {
                switch (b) {
                    .tool_result => |tr| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try out.appendSlice("{\"role\":\"toolResult\",\"toolCallId\":");
                        try writeJsonStr(out, tr.tool_call_id);
                        if (tr.tool_name) |tn| {
                            try out.appendSlice(",\"toolName\":");
                            try writeJsonStr(out, tn);
                        }
                        try out.appendSlice(",\"content\":[{\"type\":\"text\",\"text\":");
                        try writeJsonStr(out, tr.content);
                        try out.appendSlice("}],\"isError\":");
                        try out.appendSlice(if (tr.is_error) "true" else "false");
                        try out.appendSlice(",\"timestamp\":");
                        try appendFmt(out, out.allocator, "{d}", .{ts});
                        try out.append('}');
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn jsonU64(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else 0,
        .float => |n| if (n >= 0) @intFromFloat(n) else 0,
        else => 0,
    };
}

fn usageFromJson(o: std.json.ObjectMap) ?msg.Usage {
    var u = msg.Usage{};
    u.input = if (o.get("input")) |v| jsonU64(v) else 0;
    u.output = if (o.get("output")) |v| jsonU64(v) else 0;
    u.cache_read = if (o.get("cacheRead")) |v| jsonU64(v) else 0;
    u.cache_write = if (o.get("cacheWrite")) |v| jsonU64(v) else 0;
    u.reasoning = if (o.get("reasoning")) |v| jsonU64(v) else 0;
    u.total = if (o.get("totalTokens")) |v| jsonU64(v) else (u.input + u.output);
    if (o.get("cost")) |cv| {
        switch (cv) {
            .object => |co| {
                u.cost = if (co.get("total")) |v| switch (v) {
                    .float => |n| n,
                    .integer => |n| @floatFromInt(n),
                    else => 0,
                } else 0;
                u.cost_input = if (co.get("input")) |v| switch (v) {
                    .float => |n| n,
                    .integer => |n| @floatFromInt(n),
                    else => 0,
                } else 0;
                u.cost_output = if (co.get("output")) |v| switch (v) {
                    .float => |n| n,
                    .integer => |n| @floatFromInt(n),
                    else => 0,
                } else 0;
                u.cost_cache_read = if (co.get("cacheRead")) |v| switch (v) {
                    .float => |n| n,
                    .integer => |n| @floatFromInt(n),
                    else => 0,
                } else 0;
            },
            else => {},
        }
    }
    return u;
}

fn textFromContent(v: std.json.Value, alloc: std.mem.Allocator, m: *msg.Message, want_blocks: enum { text_thinking, text_only }) !void {
    switch (v) {
        .string => |s| try m.blocks.append(.{ .text = try alloc.dupe(u8, s) }),
        .array => |arr| {
            for (arr.items) |item| {
                switch (item) {
                    .object => |o| {
                        const t = if (o.get("type")) |tv| switch (tv) {
                            .string => |ts| ts,
                            else => "",
                        } else "";
                        if (std.mem.eql(u8, t, "text")) {
                            if (o.get("text")) |tv| {
                                switch (tv) {
                                    .string => |ts| try m.blocks.append(.{ .text = try alloc.dupe(u8, ts) }),
                                    else => {},
                                }
                            }
                        } else if (want_blocks == .text_thinking and std.mem.eql(u8, t, "thinking")) {
                            if (o.get("thinking")) |tv| {
                                switch (tv) {
                                    .string => |ts| try m.blocks.append(.{ .thinking = try alloc.dupe(u8, ts) }),
                                    else => {},
                                }
                            }
                        } else if (std.mem.eql(u8, t, "toolCall")) {
                            var tc = msg.ToolCall{ .id = "", .name = "", .arguments = "" };
                            if (o.get("id")) |iv| switch (iv) {
                                .string => |s| tc.id = try alloc.dupe(u8, s),
                                else => {},
                            };
                            if (o.get("name")) |nv| switch (nv) {
                                .string => |s| tc.name = try alloc.dupe(u8, s),
                                else => {},
                            };
                            if (o.get("arguments")) |av| {
                                var buf = std.array_list.Managed(u8).init(alloc);
                                writeJsonValue(&buf, av) catch {
                                    buf.deinit();
                                    continue;
                                };
                                tc.arguments = try buf.toOwnedSlice();
                            }
                            try m.blocks.append(.{ .tool_call = tc });
                        }
                        // image and unknown blocks skipped for now
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

/// Parse one AgentMessage JSON value into our Message model.
pub fn messageFromJson(alloc: std.mem.Allocator, v: std.json.Value) !msg.Message {
    var m = msg.Message.init(alloc);
    errdefer m.deinit();
    const o = switch (v) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const role = if (o.get("role")) |rv| switch (rv) {
        .string => |s| s,
        else => "",
    } else "";

    if (o.get("timestamp")) |tv| {
        m.timestamp_ms = @intCast(jsonU64(tv));
    }

    if (std.mem.eql(u8, role, "user")) {
        m.role = .user;
        if (o.get("content")) |cv| try textFromContent(cv, alloc, &m, .text_only);
    } else if (std.mem.eql(u8, role, "assistant")) {
        m.role = .assistant;
        if (o.get("content")) |cv| try textFromContent(cv, alloc, &m, .text_thinking);
        if (o.get("usage")) |uv| {
            switch (uv) {
                .object => |uo| m.usage = usageFromJson(uo),
                else => {},
            }
        }
        if (o.get("stopReason")) |sv| switch (sv) {
            .string => |s| m.stop_reason = try alloc.dupe(u8, s),
            else => {},
        };
        if (o.get("provider")) |pv| switch (pv) {
            .string => |s| m.provider = try alloc.dupe(u8, s),
            else => {},
        };
        if (o.get("model")) |mv| switch (mv) {
            .string => |s| m.model_id = try alloc.dupe(u8, s),
            else => {},
        };
    } else if (std.mem.eql(u8, role, "bashExecution")) {
        m.role = .bash_execution;
        if (o.get("command")) |cv| switch (cv) {
            .string => |sv| m.bash_command = try alloc.dupe(u8, sv),
            else => {},
        };
        if (o.get("excludeFromContext")) |ev| switch (ev) {
            .bool => |b| m.bash_exclude = b,
            else => {},
        };
        if (o.get("exitCode")) |ev| switch (ev) {
            .integer => |n| m.bash_exit_code = @intCast(n),
            else => {},
        };
        if (o.get("output")) |ov| switch (ov) {
            .string => |sv| {
                const copy = try alloc.dupe(u8, sv);
                try m.blocks.append(.{ .text = copy });
            },
            else => {},
        };
    } else if (std.mem.eql(u8, role, "toolResult")) {
        m.role = .tool;
        var tr = msg.ToolResult{ .tool_call_id = "", .content = "", .is_error = false };
        if (o.get("toolCallId")) |tv| switch (tv) {
            .string => |s| tr.tool_call_id = try alloc.dupe(u8, s),
            else => {},
        };
        if (o.get("toolName")) |tv| switch (tv) {
            .string => |s| tr.tool_name = try alloc.dupe(u8, s),
            else => {},
        };
        if (o.get("isError")) |ev| switch (ev) {
            .bool => |b| tr.is_error = b,
            else => {},
        };
        // Concatenate text blocks into content
        var buf = std.array_list.Managed(u8).init(alloc);
        errdefer buf.deinit();
        if (o.get("content")) |cv| {
            switch (cv) {
                .string => |s| try buf.appendSlice(s),
                .array => |arr| {
                    for (arr.items) |item| {
                        switch (item) {
                            .object => |io| {
                                const t = if (io.get("type")) |tv| switch (tv) {
                                    .string => |ts| ts,
                                    else => "",
                                } else "";
                                if (std.mem.eql(u8, t, "text")) {
                                    if (io.get("text")) |txv| {
                                        switch (txv) {
                                            .string => |ts| {
                                                try buf.appendSlice(ts);
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        tr.content = try buf.toOwnedSlice();
        try m.blocks.append(.{ .tool_result = tr });
    } else {
        return error.UnknownRole;
    }
    return m;
}

// ── Store ───────────────────────────────────────────────────────────

const EntryKind = enum { header, message, session_info, model_change, thinking_level_change, compaction, branch_summary, custom_message, custom, other };

const EntryRef = struct {
    kind: EntryKind,
    id: []u8,
    parent_id: ?[]u8,
    line: []u8, // raw JSON line (owned)
};

pub const SessionInfo = struct {
    path: []u8,
    id: []u8,
    name: ?[]u8,
    timestamp: []u8,
    msg_count: usize,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    id: []u8,
    cwd: []u8,
    name: ?[]u8 = null,
    parent_session: ?[]u8 = null,
    leaf_id: ?[]u8 = null,
    entries: std.array_list.Managed(EntryRef),
    file_buf: std.array_list.Managed(u8),

    fn deinitEntries(self: *Store) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.id);
            if (e.parent_id) |p| self.alloc.free(p);
            self.alloc.free(e.line);
        }
        self.entries.deinit();
    }

    pub fn deinit(self: *Store) void {
        self.deinitEntries();
        self.file_buf.deinit();
        self.alloc.free(self.path);
        self.alloc.free(self.id);
        self.alloc.free(self.cwd);
        if (self.name) |n| self.alloc.free(n);
        if (self.parent_session) |ps| self.alloc.free(ps);
        if (self.leaf_id) |l| self.alloc.free(l);
        self.alloc.destroy(self);
    }

    /// Encode cwd for the sessions subdir: strip leading '/', replace /\: with '-'.
    pub fn encodeCwd(alloc: std.mem.Allocator, cwd: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(alloc);
        errdefer out.deinit();
        var s = cwd;
        while (s.len > 0 and (s[0] == '/' or s[0] == '\\')) s = s[1..];
        for (s) |c| {
            switch (c) {
                '/', '\\', ':' => try out.append('-'),
                else => try out.append(c),
            }
        }
        return out.toOwnedSlice();
    }

    pub fn create(
        alloc: std.mem.Allocator,
        io: std.Io,
        sessions_dir: []const u8,
        cwd_abs: []const u8,
        opts: struct {
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            parent_session: ?[]const u8 = null,
        },
    ) !*Store {
        const enc = try encodeCwd(alloc, cwd_abs);
        defer alloc.free(enc);
        const sub = try std.fmt.allocPrint(alloc, "{s}/--{s}--", .{ sessions_dir, enc });
        defer alloc.free(sub);
        std.Io.Dir.cwd().createDirPath(io, sub) catch {};

        const st = try alloc.create(Store);
        st.* = .{
            .alloc = alloc,
            .io = io,
            .path = "",
            .id = "",
            .cwd = "",
            .name = null,
            .parent_session = null,
            .leaf_id = null,
            .entries = .init(alloc),
            .file_buf = .init(alloc),
        };
        errdefer st.deinit();
        st.cwd = try alloc.dupe(u8, cwd_abs);
        if (opts.name) |n| st.name = try alloc.dupe(u8, n);
        if (opts.parent_session) |p| st.parent_session = try alloc.dupe(u8, p);
        st.id = if (opts.id) |i| try alloc.dupe(u8, i) else genUuid(alloc, io);

        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(io), &ts_buf);
        var fname_buf = std.array_list.Managed(u8).init(alloc);
        defer fname_buf.deinit();
        for (iso) |c| {
            try fname_buf.append(if (c == ':' or c == '.') '-' else c);
        }
        st.path = try std.fmt.allocPrint(alloc, "{s}/{s}_{s}.jsonl", .{ sub, fname_buf.items, st.id });

        // Header
        var line = std.array_list.Managed(u8).init(alloc);
        defer line.deinit();
        try line.appendSlice("{\"type\":\"session\",\"version\":3,\"id\":");
        try writeJsonStr(&line, st.id);
        try line.appendSlice(",\"timestamp\":");
        try writeJsonStr(&line, iso);
        try line.appendSlice(",\"cwd\":");
        try writeJsonStr(&line, cwd_abs);
        if (st.parent_session) |ps| {
            try line.appendSlice(",\"parentSession\":");
            try writeJsonStr(&line, ps);
        }
        try line.appendSlice("}\n");
        try st.file_buf.appendSlice(line.items);
        st.persist();
        return st;
    }

    fn persist(self: *Store) void {
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = self.file_buf.items }) catch {};
    }

    fn appendLine(self: *Store, entry_id: []u8, parent: ?[]u8, kind: EntryKind, line: []const u8) !void {
        try self.file_buf.appendSlice(line);
        if (line.len == 0 or line[line.len - 1] != '\n') try self.file_buf.append('\n');
        try self.entries.append(.{
            .kind = kind,
            .id = try self.alloc.dupe(u8, entry_id),
            .parent_id = if (parent) |p| try self.alloc.dupe(u8, p) else null,
            .line = try self.alloc.dupe(u8, line),
        });
        if (self.leaf_id) |l| self.alloc.free(l);
        self.leaf_id = try self.alloc.dupe(u8, entry_id);
        self.persist();
    }

    /// Record one conversation message as a message entry (parent = leaf).
    pub fn recordMessage(self: *Store, m: *const msg.Message) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);

        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        writeMessageJson(&body, m) catch return;

        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"message\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        if (self.leaf_id) |l| {
            writeJsonStr(&line, l) catch return;
        } else {
            line.appendSlice("null") catch return;
        }
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"message\":") catch return;
        line.appendSlice(body.items) catch return;
        line.appendSlice("}\n") catch return;

        // NOTE: our tool messages carry exactly one tool_result block, so
        // body is a single JSON object; one entry per line holds.
        self.appendLine(id, self.leaf_id, .message, line.items) catch {};
    }

    pub fn recordSessionInfo(self: *Store, name: []const u8) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);
        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"session_info\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        if (self.leaf_id) |l| {
            writeJsonStr(&line, l) catch return;
        } else {
            line.appendSlice("null") catch return;
        }
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"name\":") catch return;
        writeJsonStr(&line, name) catch return;
        line.appendSlice("}\n") catch return;
        if (self.name) |n| self.alloc.free(n);
        self.name = self.alloc.dupe(u8, name) catch null;
        self.appendLine(id, self.leaf_id, .session_info, line.items) catch {};
    }

    pub fn recordModelChange(self: *Store, provider: []const u8, model_id: []const u8) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);
        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"model_change\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        if (self.leaf_id) |l| {
            writeJsonStr(&line, l) catch return;
        } else {
            line.appendSlice("null") catch return;
        }
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"provider\":") catch return;
        writeJsonStr(&line, provider) catch return;
        line.appendSlice(",\"modelId\":") catch return;
        writeJsonStr(&line, model_id) catch return;
        line.appendSlice("}\n") catch return;
        self.appendLine(id, self.leaf_id, .model_change, line.items) catch {};
    }

    /// Record a compaction entry (pi v3: type "compaction"). `summary` is the
    /// structured checkpoint text (with file-op tags appended). `first_kept_id`
    /// is the store entry id of the first retained message.
    pub fn recordCompaction(
        self: *Store,
        summary: []const u8,
        first_kept_id: []const u8,
        tokens_before: u64,
        lists: compact.FileLists,
        usage: ?msg.Usage,
    ) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);

        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"compaction\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        if (self.leaf_id) |l| {
            writeJsonStr(&line, l) catch return;
        } else {
            line.appendSlice("null") catch return;
        }
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"summary\":") catch return;
        writeJsonStr(&line, summary) catch return;
        line.appendSlice(",\"firstKeptEntryId\":") catch return;
        writeJsonStr(&line, first_kept_id) catch return;
        line.appendSlice(",\"tokensBefore\":") catch return;
        const tok = std.fmt.allocPrint(self.alloc, "{d}", .{tokens_before}) catch return;
        defer self.alloc.free(tok);
        line.appendSlice(tok) catch return;
        // details: { readFiles: [...], modifiedFiles: [...] }
        line.appendSlice(",\"details\":{\"readFiles\":[") catch return;
        for (lists.read, 0..) |f, i| {
            if (i > 0) line.appendSlice(",") catch return;
            writeJsonStr(&line, f) catch return;
        }
        line.appendSlice("],\"modifiedFiles\":[") catch return;
        for (lists.modified, 0..) |f, i| {
            if (i > 0) line.appendSlice(",") catch return;
            writeJsonStr(&line, f) catch return;
        }
        line.appendSlice("]}") catch return;
        if (usage) |u| {
            line.appendSlice(",\"usage\":{\"input\":") catch return;
            const a = std.fmt.allocPrint(self.alloc, "{d}", .{u.input}) catch return;
            defer self.alloc.free(a);
            line.appendSlice(a) catch return;
            line.appendSlice(",\"output\":") catch return;
            const b = std.fmt.allocPrint(self.alloc, "{d}", .{u.output}) catch return;
            defer self.alloc.free(b);
            line.appendSlice(b) catch return;
            line.appendSlice("}") catch return;
        }
        line.appendSlice("}\n") catch return;
        self.appendLine(id, self.leaf_id, .compaction, line.items) catch {};
    }

    /// Record a thinking level change (pi v3: type "thinking_level_change").
    pub fn recordThinkingLevel(self: *Store, level: []const u8) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);
        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"thinking_level_change\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        if (self.leaf_id) |l| {
            writeJsonStr(&line, l) catch return;
        } else {
            line.appendSlice("null") catch return;
        }
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"thinkingLevel\":") catch return;
        writeJsonStr(&line, level) catch return;
        line.appendSlice("}\n") catch return;
        self.appendLine(id, self.leaf_id, .thinking_level_change, line.items) catch {};
    }

    /// The latest thinking level on the leaf path (owned), if any.
    pub fn latestThinkingLevel(self: *Store, alloc: std.mem.Allocator) ?[]u8 {
        // leafPath items borrow the store's entries: only the list is freed.
        const path = self.leafPath(alloc) catch return null;
        defer path.deinit();
        var i = path.items.len;
        while (i > 0) {
            i -= 1;
            const e = path.items[i];
            if (e.kind != .thinking_level_change) continue;
            if (jsonStringField(alloc, e.line, "thinkingLevel")) |lv| return lv;
        }
        return null;
    }

    /// The latest model change on the leaf path (owned fields), if any.
    pub const ModelChange = struct { provider: []u8, model_id: []u8 };

    pub fn latestModelChange(self: *Store, alloc: std.mem.Allocator) ?ModelChange {
        const path = self.leafPath(alloc) catch return null;
        defer path.deinit();
        var i = path.items.len;
        while (i > 0) {
            i -= 1;
            const e = path.items[i];
            if (e.kind != .model_change) continue;
            const provider = jsonStringField(alloc, e.line, "provider") orelse continue;
            const model_id = jsonStringField(alloc, e.line, "modelId") orelse {
                alloc.free(provider);
                continue;
            };
            return .{ .provider = provider, .model_id = model_id };
        }
        return null;
    }

    /// Append a branch summary entry whose parent (and thus the new leaf) is
    /// `cut_entry_id`: the tree continues from the cut point with the summary
    /// of the abandoned path (pi: sessionManager.branchWithSummary).
    pub fn branchAt(self: *Store, cut_entry_id: []const u8, from_id: []const u8, summary: []const u8) void {
        const id = genEntryId(self.alloc, self.io);
        defer self.alloc.free(id);
        var ts_buf: [40]u8 = undefined;
        const iso = formatIso(nowMs(self.io), &ts_buf);
        var line = std.array_list.Managed(u8).init(self.alloc);
        defer line.deinit();
        appendFmt(&line, self.alloc, "{{\"type\":\"branch_summary\",\"id\":\"{s}\",\"parentId\":", .{id}) catch return;
        writeJsonStr(&line, cut_entry_id) catch return;
        line.appendSlice(",\"timestamp\":") catch return;
        writeJsonStr(&line, iso) catch return;
        line.appendSlice(",\"fromId\":") catch return;
        writeJsonStr(&line, from_id) catch return;
        line.appendSlice(",\"summary\":") catch return;
        writeJsonStr(&line, summary) catch return;
        line.appendSlice("}\n") catch return;
        const cut_copy = self.alloc.dupe(u8, cut_entry_id) catch return;
        defer self.alloc.free(cut_copy);
        self.appendLine(id, cut_copy, .branch_summary, line.items) catch {};
    }

    /// Fork into a NEW session copying the leaf chain up to (and including)
    /// `cut_entry_id` — pi /fork: create a new session from an earlier user
    /// message. Compaction/branch-summary entries are not copied.
    pub fn forkAt(self: *Store, cut_entry_id: []const u8, sessions_dir: []const u8, new_cwd: []const u8) !*Store {
        const st = try Store.create(self.alloc, self.io, sessions_dir, new_cwd, .{
            .parent_session = self.path,
            .name = self.name,
        });
        errdefer st.deinit();
        // Collect the chain from the cut point back to the root.
        var chain = std.array_list.Managed(EntryRef).init(self.alloc);
        defer chain.deinit();
        var cur: ?[]const u8 = cut_entry_id;
        while (cur) |cid| {
            var found: ?EntryRef = null;
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.id, cid)) {
                    found = e;
                    break;
                }
            }
            const e = found orelse break;
            chain.append(e) catch break;
            cur = e.parent_id;
        }
        var i: usize = chain.items.len;
        while (i > 0) {
            i -= 1;
            const e = chain.items[i];
            if (e.kind == .compaction or e.kind == .branch_summary) continue;
            const eid = genEntryId(self.alloc, self.io);
            defer self.alloc.free(eid);
            try st.appendLine(eid, st.leaf_id, e.kind, e.line);
        }
        return st;
    }

    /// One selectable row along the leaf path: entry id, kind, whether it is
    /// a user message, and a short text preview extracted from the raw line.
    pub const ChainItem = struct {
        kind: EntryKind,
        id: [16]u8,
        id_len: usize,
        is_user_message: bool,
        preview: [72]u8,
        preview_len: usize,
    };

    /// Leaf-path entries in conversation order (for the /tree and /fork
    /// selectors). Returns item count (capped to `out.len`).
    pub fn leafChain(self: *Store, out: []ChainItem) usize {
        const path = self.leafPath(self.alloc) catch return 0;
        defer path.deinit();
        var n: usize = 0;
        for (path.items) |e| {
            if (n >= out.len) break;
            if (e.kind == .header) continue;
            var item: ChainItem = .{
                .kind = e.kind,
                .id = undefined,
                .id_len = 0,
                .is_user_message = false,
                .preview = undefined,
                .preview_len = 0,
            };
            item.id_len = @min(e.id.len, item.id.len);
            @memcpy(item.id[0..item.id_len], e.id[0..item.id_len]);
            extractPreview(self.alloc, e, &item);
            out[n] = item;
            n += 1;
        }
        return n;
    }

    /// Delete a session file from disk (pi: /resume Ctrl+D; uses unlink —
    /// no trash CLI dependency).
    pub fn deleteSessionFile(io: std.Io, path: []const u8) void {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    /// Ids of message entries along the leaf path, in conversation order.
    /// Used to map a context-message index to a store entry id (compaction).
    pub fn branchMessageIds(self: *Store, alloc: std.mem.Allocator) ![][]const u8 {
        const path = try self.leafPath(alloc);
        defer path.deinit();
        var ids = std.array_list.Managed([]const u8).init(alloc);
        errdefer ids.deinit();
        for (path.items) |e| {
            if (e.kind != .message) continue;
            try ids.append(e.id);
        }
        return ids.toOwnedSlice();
    }

    /// Open an existing session file. Returns the active-branch messages in
    /// conversation order (caller owns them).
    pub fn open(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !*Store {
        const st = try alloc.create(Store);
        st.* = .{
            .alloc = alloc,
            .io = io,
            .path = "",
            .id = "",
            .cwd = "",
            .name = null,
            .parent_session = null,
            .leaf_id = null,
            .entries = .init(alloc),
            .file_buf = .init(alloc),
        };
        errdefer st.deinit();
        st.path = try alloc.dupe(u8, path);

        var buf: [8 << 20]u8 = undefined;
        const file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return error.CannotRead
        else
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return error.CannotRead;
        const nbytes = file.readPositionalAll(io, &buf, 0) catch return error.CannotRead;
        const data = buf[0..nbytes];
        try st.file_buf.appendSlice(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const etype = if (root.get("type")) |tv| switch (tv) {
                .string => |s| s,
                else => "",
            } else "";

            var kind: EntryKind = .other;
            if (std.mem.eql(u8, etype, "session")) {
                kind = .header;
                if (root.get("id")) |iv| switch (iv) {
                    .string => |s| st.id = try alloc.dupe(u8, s),
                    else => {},
                };
                if (root.get("cwd")) |cv| switch (cv) {
                    .string => |s| st.cwd = try alloc.dupe(u8, s),
                    else => {},
                };
                if (root.get("parentSession")) |pv| switch (pv) {
                    .string => |s| st.parent_session = try alloc.dupe(u8, s),
                    else => {},
                };
            } else {
                if (std.mem.eql(u8, etype, "message")) {
                    kind = .message;
                } else if (std.mem.eql(u8, etype, "session_info")) {
                    kind = .session_info;
                    if (root.get("name")) |nv| switch (nv) {
                        .string => |s| {
                            if (st.name) |n| alloc.free(n);
                            st.name = try alloc.dupe(u8, s);
                        },
                        else => {},
                    };
                } else if (std.mem.eql(u8, etype, "model_change")) {
                    kind = .model_change;
                } else if (std.mem.eql(u8, etype, "thinking_level_change")) {
                    kind = .thinking_level_change;
                } else if (std.mem.eql(u8, etype, "compaction")) {
                    kind = .compaction;
                } else if (std.mem.eql(u8, etype, "branch_summary")) {
                    kind = .branch_summary;
                } else if (std.mem.eql(u8, etype, "custom_message")) {
                    kind = .custom_message;
                } else if (std.mem.eql(u8, etype, "custom")) {
                    kind = .custom;
                }
                const eid = if (root.get("id")) |iv| switch (iv) {
                    .string => |s| s,
                    else => continue,
                } else continue;
                const parent: ?[]const u8 = if (root.get("parentId")) |pv| switch (pv) {
                    .string => |s| s,
                    else => null,
                } else null;

                try st.entries.append(.{
                    .kind = kind,
                    .id = try alloc.dupe(u8, eid),
                    .parent_id = if (parent) |p| try alloc.dupe(u8, p) else null,
                    .line = try alloc.dupe(u8, line),
                });
                if (st.leaf_id) |l| alloc.free(l);
                st.leaf_id = try alloc.dupe(u8, eid);
            }
        }
        return st;
    }

    /// Active-branch messages (parent chain from leaf to root, reversed).
    /// Leaf path in conversation order (oldest → newest). Caller deinit.
    fn leafPath(self: *Store, alloc: std.mem.Allocator) !std.array_list.Managed(EntryRef) {
        var chain = std.array_list.Managed(EntryRef).init(alloc);
        errdefer chain.deinit();
        var cur: ?[]const u8 = self.leaf_id;
        while (cur) |cid| {
            var found: ?EntryRef = null;
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.id, cid)) {
                    found = e;
                    break;
                }
            }
            const e = found orelse break;
            try chain.append(e);
            cur = e.parent_id;
        }
        // Reverse in place → conversation order.
        var i: usize = 0;
        var j: usize = chain.items.len;
        if (j > 0) j -= 1;
        while (i < j) : ({ i += 1; j -= 1; }) {
            const tmp = chain.items[i];
            chain.items[i] = chain.items[j];
            chain.items[j] = tmp;
        }
        return chain;
    }

    /// Parse one message entry's raw line into a Message (null on error).
    fn parseMessageEntry(alloc: std.mem.Allocator, line: []const u8) ?msg.Message {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const mv = root.get("message") orelse return null;
        return messageFromJson(alloc, mv) catch null;
    }

    /// Active-branch messages in conversation order, compaction-aware (pi:
    /// buildContextEntries). If the leaf path has a compaction entry, the
    /// result is [synthetic summary] + [kept messages from firstKeptEntryId]
    /// + [messages after the compaction]. Caller owns the returned messages.
    pub fn branchMessages(self: *Store, alloc: std.mem.Allocator) ![]msg.Message {
        var out = std.array_list.Managed(msg.Message).init(alloc);
        errdefer {
            for (out.items) |*m| m.deinit();
            out.deinit();
        }
        const path = try self.leafPath(alloc);
        defer path.deinit();

        var compaction_idx: ?usize = null;
        for (path.items, 0..) |e, idx| {
            if (e.kind == .compaction) compaction_idx = idx;
        }

        if (compaction_idx) |cidx| {
            const ce_line = path.items[cidx].line;
            var cparsed = std.json.parseFromSlice(std.json.Value, alloc, ce_line, .{}) catch return out.toOwnedSlice();
            defer cparsed.deinit();
            const croot = switch (cparsed.value) {
                .object => |o| o,
                else => return out.toOwnedSlice(),
            };
            const summary: []const u8 = if (croot.get("summary")) |sv| switch (sv) {
                .string => |s| s,
                else => "",
            } else "";
            const first_kept: []const u8 = if (croot.get("firstKeptEntryId")) |fv| switch (fv) {
                .string => |s| s,
                else => "",
            } else "";

            // Synthetic compaction summary as a user message.
            if (summary.len > 0) {
                var sm = msg.Message.init(alloc);
                errdefer sm.deinit();
                sm.role = .user;
                const owned = try alloc.dupe(u8, summary);
                errdefer alloc.free(owned);
                try sm.blocks.append(.{ .text = owned });
                try out.append(sm);
            }
            // Kept messages before the compaction (from firstKeptEntryId onward).
            var found_first = false;
            for (path.items[0..cidx]) |e| {
                if (std.mem.eql(u8, e.id, first_kept)) found_first = true;
                if (!found_first) continue;
                if (e.kind != .message) continue;
                if (Store.parseMessageEntry(alloc, e.line)) |m| try out.append(m);
            }
            // Messages after the compaction.
            for (path.items[cidx + 1 ..]) |e| {
                if (e.kind != .message) continue;
                if (Store.parseMessageEntry(alloc, e.line)) |m| try out.append(m);
            }
        } else {
            for (path.items) |e| {
                if (e.kind != .message) continue;
                if (Store.parseMessageEntry(alloc, e.line)) |m| try out.append(m);
            }
        }
        return out.toOwnedSlice();
    }

    /// Fork: new session file (new id, parentSession set) containing this
    /// store's active branch entries verbatim (ids/parent links preserved).
    pub fn fork(self: *Store, sessions_dir: []const u8, new_cwd: []const u8) !*Store {
        const st = try Store.create(self.alloc, self.io, sessions_dir, new_cwd, .{
            .parent_session = self.path,
            .name = self.name,
        });
        errdefer st.deinit();
        // Copy branch entry lines
        var chain = std.array_list.Managed(EntryRef).init(self.alloc);
        defer chain.deinit();
        var cur: ?[]const u8 = self.leaf_id;
        while (cur) |cid| {
            var found: ?EntryRef = null;
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.id, cid)) {
                    found = e;
                    break;
                }
            }
            const e = found orelse break;
            chain.append(e) catch break;
            cur = e.parent_id;
        }
        var i: usize = chain.items.len;
        while (i > 0) {
            i -= 1;
            const e = chain.items[i];
            if (e.kind == .compaction or e.kind == .branch_summary) continue;
            const eid = genEntryId(self.alloc, self.io);
            defer self.alloc.free(eid);
            try st.appendLine(eid, st.leaf_id, e.kind, e.line);
        }
        return st;
    }

    /// Write the current file buffer to an export path.
    pub fn exportTo(self: *Store, out_path: []const u8) void {
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out_path, .data = self.file_buf.items }) catch {};
    }

    /// Number of conversation-message entries in this session.
    pub fn msgCount(self: *const Store) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.kind == .message) n += 1;
        }
        return n;
    }

    /// Set (or rename) the session name; persists a session_info entry.
    pub fn setName(self: *Store, name: []const u8) void {
        self.recordSessionInfo(name);
    }

    /// One-line human summary for /session.
    pub fn infoLine(self: *const Store, alloc: std.mem.Allocator) ![]u8 {
        const name = self.name orelse "(unnamed)";
        const parent = self.parent_session orelse "-";
        return std.fmt.allocPrint(alloc,
            "\x1b[90msession {s}\x1b[0m\n  name: {s}\n  path: {s}\n  messages: {d}\n  parent: {s}\x1b[0m", .{
            self.id, name, self.path, self.msgCount(), parent,
        }) catch return error.OutOfMemory;
    }

    /// Render the entry chain as an indented tree (for /tree).
    pub fn renderTree(self: *const Store, alloc: std.mem.Allocator) ![]u8 {
        var out = std.array_list.Managed(u8).init(alloc);
        errdefer out.deinit();
        for (self.entries.items) |e| {
            var depth: usize = 0;
            var cur: ?[]const u8 = e.parent_id;
            var guard: usize = 0;
            while (cur) |cid| : ({
                guard += 1;
                if (guard > self.entries.items.len + 1) break;
            }) {
                depth += 1;
                var found: ?[]const u8 = null;
                for (self.entries.items) |other| {
                    if (std.mem.eql(u8, other.id, cid)) {
                        found = other.parent_id;
                        break;
                    }
                }
                cur = found;
            }
            var indent: [64]u8 = undefined;
            const n = @min(depth * 2, 64);
            for (indent[0..n]) |*c| c.* = ' ';
            const ind = indent[0..n];
            try out.appendSlice(ind);
            try out.appendSlice(if (e.kind == .message) "\x1b[96m" else "\x1b[90m");
            const snippet = treeSnippet(alloc, e.line);
            defer if (snippet) |s| alloc.free(s);
            try out.appendSlice(snippet orelse "");
            try out.appendSlice("\x1b[0m\n");
        }
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Render the active branch as a standalone HTML document.
    pub fn exportHtml(self: *const Store, alloc: std.mem.Allocator, out_path: []const u8) !void {
        var out = std.array_list.Managed(u8).init(alloc);
        defer out.deinit();
        try out.appendSlice("<!doctype html>\n<html><head><meta charset=\"utf-8\">");
        const title = self.name orelse self.id;
        try out.appendSlice("<title>");
        try appendHtmlEscaped(&out, title);
        try out.appendSlice("</title>");
        try out.appendSlice("<style>body{font:14px/1.5 system-ui,sans-serif;max-width:800px;margin:2rem auto;padding:0 1rem}");
        try out.appendSlice(".msg{margin:1rem 0;padding:.6rem 1rem;border-radius:8px}");
        try out.appendSlice(".user{background:#eef2ff}.assistant{background:#f0fdf4}.tool{background:#f8fafc;border-left:3px solid #94a3b8}");
        try out.appendSlice(".role{font-weight:600;font-size:12px;opacity:.6;text-transform:uppercase}");
        try out.appendSlice("pre{white-space:pre-wrap;word-break:break-word;font:13px/1.4 ui-monospace,monospace}");
        try out.appendSlice("</style></head><body>");
        try out.appendSlice("<h1>");
        try appendHtmlEscaped(&out, title);
        try out.appendSlice("</h1>");
        const branch = try @constCast(self).branchMessages(alloc);
        defer {
            for (branch) |m| m.deinit();
            alloc.free(branch);
        }
        for (branch) |m| {
            const cls = switch (m.role) {
                .user => "user",
                .assistant => "assistant",
                else => "tool",
            };
            const role = @tagName(m.role);
            try out.appendSlice("<div class=\"");
            try out.appendSlice(cls);
            try out.appendSlice("\"><div class=\"role\">");
            try appendHtmlEscaped(&out, role);
            try out.appendSlice("</div><pre>");
            // Concatenate text-ish blocks
            var first = true;
            for (m.blocks.items) |b| {
                switch (b) {
                    .text => |t| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try appendHtmlEscaped(&out, t);
                    },
                    .thinking => |t| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try out.appendSlice("[thinking] ");
                        try appendHtmlEscaped(&out, t);
                    },
                    .tool_call => |tc| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try out.appendSlice("[call ");
                        try appendHtmlEscaped(&out, tc.name);
                        try out.appendSlice("] ");
                        try appendHtmlEscaped(&out, tc.arguments);
                    },
                    .tool_result => |tr| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try out.appendSlice("[result ");
                        try appendHtmlEscaped(&out, tr.tool_name orelse "tool");
                        try out.appendSlice("] ");
                        try appendHtmlEscaped(&out, tr.content);
                    },
                    .image => |img| {
                        if (!first) try out.appendSlice("\n");
                        first = false;
                        try out.appendSlice("<img src=\"data:");
                        try appendHtmlEscaped(&out, img.mime);
                        try out.appendSlice(";base64,");
                        try out.appendSlice(img.data);
                        try out.appendSlice("\">");
                    },
                }
            }
            try out.appendSlice("</pre></div>\n");
        }
        try out.appendSlice("</body></html>\n");
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out_path, .data = out.items }) catch return error.CannotWrite;
    }
};

/// Short one-line description of an entry for the /tree view.
fn treeSnippet(alloc: std.mem.Allocator, line: []const u8) ?[]u8 {
    const v = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
    defer v.deinit();
    const o = switch (v.value) {
        .object => |obj| obj,
        else => return null,
    };
    const kind = switch (o.get("type") orelse return null) {
        .string => |s| s,
        else => "?",
    };
    if (std.mem.eql(u8, kind, "message")) {
        const mobj = switch (o.get("message") orelse return null) {
            .object => |obj| obj,
            else => return null,
        };
        const role = switch (mobj.get("role") orelse return null) {
            .string => |s| s,
            else => "?",
        };
        var text: []const u8 = "";
        if (mobj.get("content")) |cv| {
            switch (cv) {
                .string => |s| text = s,
                .array => |arr| {
                    for (arr.items) |item| {
                        const obj = switch (item) {
                            .object => |o2| o2,
                            else => continue,
                        };
                        const tv = obj.get("text") orelse continue;
                        const ts = switch (tv) {
                            .string => |s2| s2,
                            else => continue,
                        };
                        text = ts;
                        break;
                    }
                },
                else => {},
            }
        }
        var clip: [64]u8 = undefined;
        const one = std.fmt.bufPrint(&clip, "{s}", .{ if (text.len > 48) text[0..48] else text }) catch "";
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ role, one }) catch null;
    }
    return std.fmt.allocPrint(alloc, "{s}", .{kind}) catch null;
}

/// Escape a string for safe embedding in HTML.
fn appendHtmlEscaped(out: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice("&amp;"),
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            else => try out.append(c),
        }
    }
}

/// List sessions stored under `sessions_dir` for `cwd_abs`, newest first
/// (filename timestamp prefix sorts chronologically).
pub fn listForCwd(alloc: std.mem.Allocator, io: std.Io, sessions_dir: []const u8, cwd_abs: []const u8) ![]SessionInfo {
    const enc = try Store.encodeCwd(alloc, cwd_abs);
    defer alloc.free(enc);
    const sub = try std.fmt.allocPrint(alloc, "{s}/--{s}--", .{ sessions_dir, enc });
    defer alloc.free(sub);

    var paths = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit();
    }
    var sdir = std.Io.Dir.openDirAbsolute(io, sub, .{ .iterate = true }) catch return &.{};
    defer sdir.close(io);
    var it = sdir.iterateAssumeFirstIteration();
    while (true) {
        const e = it.next(io) catch break orelse break;
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".jsonl")) continue;
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ sub, e.name }) catch continue;
        paths.append(p) catch continue;
    }
    // Newest last in dir listing order is not guaranteed; sort by filename desc
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, std.fs.path.basename(a), std.fs.path.basename(b)) == .gt;
        }
    }.lt);

    var out = std.array_list.Managed(SessionInfo).init(alloc);
    errdefer out.deinit();
    for (paths.items) |p| {
        var buf: [1 << 16]u8 = undefined;
        const data = std.Io.Dir.cwd().readFile(io, p, &buf) catch continue;
        // header = first line; name = last session_info with name
        var id: []u8 = "";
        var name: ?[]u8 = null;
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        var first = true;
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            const o = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const t = if (o.get("type")) |tv| switch (tv) {
                .string => |s| s,
                else => "",
            } else "";
            if (first and std.mem.eql(u8, t, "session")) {
                first = false;
                if (o.get("id")) |iv| switch (iv) {
                    .string => |s| id = try alloc.dupe(u8, s),
                    else => {},
                };
                continue;
            }
            first = false;
            if (std.mem.eql(u8, t, "message")) count += 1;
            if (std.mem.eql(u8, t, "session_info")) {
                if (o.get("name")) |nv| switch (nv) {
                    .string => |s| {
                        if (name) |n| alloc.free(n);
                        name = try alloc.dupe(u8, s);
                    },
                    else => {},
                };
            }
        }
        try out.append(.{
            .path = try alloc.dupe(u8, p),
            .id = id,
            .name = name,
            .timestamp = try alloc.dupe(u8, std.fs.path.basename(p)),
            .msg_count = count,
        });
    }
    return out.toOwnedSlice();
}

/// Find a session by partial/full id across all dirs under sessions_dir.
pub fn findById(alloc: std.mem.Allocator, io: std.Io, sessions_dir: []const u8, id_ref: []const u8) ?[]u8 {
    var dirs = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit();
    }
    var sdir = std.Io.Dir.openDirAbsolute(io, sessions_dir, .{ .iterate = true }) catch return null;
    defer sdir.close(io);
    var it = sdir.iterateAssumeFirstIteration();
    while (true) {
        const e = it.next(io) catch break orelse break;
        if (e.kind != .directory) continue;
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ sessions_dir, e.name }) catch continue;
        dirs.append(p) catch continue;
    }
    for (dirs.items) |d| {
        var fdir = std.Io.Dir.openDirAbsolute(io, d, .{ .iterate = true }) catch continue;
        defer fdir.close(io);
        var fit = fdir.iterateAssumeFirstIteration();
        while (true) {
            const fe = fit.next(io) catch break orelse break;
            if (fe.kind != .file or !std.mem.endsWith(u8, fe.name, ".jsonl")) continue;
            // filename: <ts>_<uuid>.jsonl → uuid part
            const base = fe.name[0 .. fe.name.len - 6];
            const underscore = std.mem.lastIndexOfScalar(u8, base, '_') orelse continue;
            const uuid = base[underscore + 1 ..];
            if (std.mem.indexOf(u8, uuid, id_ref) == null) continue;
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ d, fe.name }) catch null;
        }
    }
    return null;
}
