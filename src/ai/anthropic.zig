//! Anthropic Messages API adapter (Phase 6: anthropic-messages).
//! POST {base}/v1/messages — x-api-key + anthropic-version headers,
//! system as a top-level array, tool_result blocks in user messages,
//! SSE events: message_start / content_block_start / content_block_delta /
//! content_block_stop / message_delta / message_stop.

const std = @import("std");
const msg = @import("../core/message.zig");
const config = @import("../core/config.zig");
const json = @import("json.zig");
const openai = @import("openai.zig");
const sse = @import("sse.zig");

pub const ChatMessage = openai.OpenAiProvider.ChatMessage;
pub const FinishReason = openai.FinishReason;

pub const AnthropicProvider = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []const u8,
    max_tokens: usize,
    client: std.http.Client,
    last_error_buf: [2048]u8 = undefined,
    last_error_len: usize = 0,

    pub fn lastErrorText(self: *const AnthropicProvider) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, api_key: []const u8, max_tokens: usize) !AnthropicProvider {
        return .{
            .alloc = alloc,
            .io = io,
            .base_url = alloc.dupe(u8, base_url) catch return error.OutOfMemory,
            .api_key = api_key,
            .max_tokens = max_tokens,
            .client = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *AnthropicProvider) void {
        std.http.Client.deinit(&self.client);
        self.alloc.free(self.base_url);
    }

    const max_retries: usize = 3;

    fn hasStreamedOutput(self: *AnthropicProvider, session: anytype) bool {
        _ = self;
        return session.stream_text.items.len > 0 or
            session.stream_thinking.items.len > 0 or
            session.stream_tools.items.len > 0;
    }

    pub fn streamChat(
        self: *AnthropicProvider,
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
        session: anytype,
    ) !void {
        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        try self.buildBody(&body, model, messages, tools_json, supports_images, thinking_level);

        const url_str = std.fmt.allocPrint(self.alloc, "{s}/v1/messages", .{self.base_url}) catch return error.OutOfMemory;
        defer self.alloc.free(url_str);

        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const had_output = self.hasStreamedOutput(session);
            const outcome = sse.postSse(
                &self.client,
                self.alloc,
                url_str,
                "", // auth goes via x-api-key below
                &.{
                    .{ .name = "x-api-key", .value = self.api_key },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                },
                body.items,
                &self.last_error_buf,
                self,
                session,
            );
            if (outcome == .ok) return;
            if (session.isAborted()) return error.Aborted;
            if (attempt >= max_retries) return error.HttpError;
            const retryable = outcome == .transport_error or
                (outcome == .retryable_status and !had_output);
            if (!retryable) return error.HttpError;
            const delay_ms: i64 = 250 * @as(i64, @intCast(std.math.pow(u64, 2, attempt - 1)));
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(delay_ms), .real) catch {};
        }
    }

    fn textOf(blocks: []const msg.ContentBlock) []const u8 {
        for (blocks) |b| switch (b) {
            .text => |t| return t,
            else => {},
        };
        return "";
    }

    fn buildBody(
        self: *const AnthropicProvider,
        body: *std.array_list.Managed(u8),
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
    ) !void {
        _ = supports_images;
        try body.appendSlice("{");
        try writeField(body, "model", model);
        try body.append(',');
        try body.appendSlice("\"stream\":true,");
        const max_part = std.fmt.allocPrint(self.alloc, "\"max_tokens\":{d},", .{self.max_tokens}) catch return error.OutOfMemory;
        try body.appendSlice(max_part);
        self.alloc.free(max_part);

        // System prompt: leading system message(s) become the top-level
        // system array (Anthropic has no system role in messages).
        var wrote_system = false;
        for (messages) |m| {
            if (m.role != .system) continue;
            const text = textOf(m.blocks);
            if (text.len == 0) continue;
            if (!wrote_system) {
                try body.appendSlice("\"system\":[");
                wrote_system = true;
            } else {
                try body.append(',');
            }
            try body.appendSlice("{\"type\":\"text\",\"text\":");
            try writeJsonStr(body, text);
            try body.append('}');
        }
        if (wrote_system) try body.appendSlice("],");

        // Messages
        try body.appendSlice("\"messages\":[");
        var first = true;
        for (messages) |m| {
            if (m.role == .system) continue;
            if (!first) try body.append(',');
            first = false;
            switch (m.role) {
                .user, .bash_execution => {
                    try body.appendSlice("{\"role\":\"user\",\"content\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"text\",\"text\":");
                            try writeJsonStr(body, t);
                            try body.append('}');
                        },
                        .image => |img| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
                            try writeJsonStr(body, img.mime);
                            try body.appendSlice(",\"data\":");
                            try writeJsonStr(body, img.data);
                            try body.appendSlice("}}");
                        },
                        else => {},
                    };
                    if (bfirst) {
                        // Empty user message — a bare space keeps the API happy.
                        try body.appendSlice("{\"type\":\"text\",\"text\":\" \"}");
                    }
                    try body.appendSlice("]}");
                },
                .assistant => {
                    try body.appendSlice("{\"role\":\"assistant\",\"content\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"text\",\"text\":");
                            try writeJsonStr(body, t);
                            try body.append('}');
                        },
                        .thinking => |t| {
                            // zpi does not persist thinking signatures; pi
                            // converts unsigned thinking to plain text for
                            // Anthropic (allowEmptySignature=false path).
                            if (t.len == 0) continue;
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"text\",\"text\":");
                            try writeJsonStr(body, t);
                            try body.append('}');
                        },
                        .tool_call => |tc| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"tool_use\",\"id\":");
                            try writeJsonStr(body, tc.id);
                            try body.appendSlice(",\"name\":");
                            try writeJsonStr(body, tc.name);
                            try body.appendSlice(",\"input\":");
                            if (tc.arguments.len > 0) {
                                try body.appendSlice(tc.arguments);
                            } else {
                                try body.appendSlice("{}");
                            }
                            try body.append('}');
                        },
                        else => {},
                    };
                    if (bfirst) {
                        try body.appendSlice("{\"type\":\"text\",\"text\":\" \"}");
                    }
                    try body.appendSlice("]}");
                },
                .tool => {
                    // tool_result blocks ride in a user message (Anthropic
                    // requires them to immediately follow the tool_use).
                    try body.appendSlice("{\"role\":\"user\",\"content\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .tool_result => |tr| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"type\":\"tool_result\",\"tool_use_id\":");
                            try writeJsonStr(body, tr.tool_call_id);
                            if (tr.is_error) try body.appendSlice(",\"is_error\":true");
                            try body.appendSlice(",\"content\":[{\"type\":\"text\",\"text\":");
                            try writeJsonStr(body, tr.content);
                            try body.appendSlice("}]}");
                        },
                        else => {},
                    };
                    try body.appendSlice("]}");
                },
                else => {},
            }
        }
        try body.appendSlice("]");

        // Tools: openai function schema → input_schema
        if (tools_json.len > 0) {
            try body.appendSlice(",\"tools\":");
            try convertTools(body, tools_json);
        }

        // Thinking (budget-based; level→budget like pi's defaults)
        if (thinking_level != .off) {
            const budget: usize = switch (thinking_level) {
                .low => 2048,
                .medium => 4096,
                .high => 8192,
                .xhigh => 16384,
                .max => 32768,
                else => 0,
            };
            if (budget > 0) {
                const tpart = std.fmt.allocPrint(self.alloc, ",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget}) catch return error.OutOfMemory;
                try body.appendSlice(tpart);
                self.alloc.free(tpart);
            }
        }

        try body.appendSlice("}");
    }

    fn convertTools(body: *std.array_list.Managed(u8), tools_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, body.allocator, tools_json, .{}) catch {
            try body.appendSlice("[]");
            return;
        };
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => {
                try body.appendSlice("[]");
                return;
            },
        };
        try body.append('[');
        var first = true;
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            // openai: {"type":"function","function":{name,description,parameters}}
            // tolerate the flat {type:"function",name,...} form too
            const fobj: std.json.ObjectMap = if (obj.get("function")) |fv| switch (fv) {
                .object => |o| o,
                else => continue,
            } else obj;
            if (!first) try body.append(',');
            first = false;
            try body.appendSlice("{\"name\":");
            try writeJsonStr(body, strOf(fobj, "name") orelse "");
            try body.appendSlice(",\"description\":");
            try writeJsonStr(body, strOf(fobj, "description") orelse "");
            try body.appendSlice(",\"input_schema\":");
            if (fobj.get("parameters")) |pv| {
                const rendered = std.json.Stringify.valueAlloc(body.allocator, pv, .{}) catch "{}";
                defer if (rendered.len > 0) body.allocator.free(@constCast(rendered));
                try body.appendSlice(rendered);
            } else {
                try body.appendSlice("{\"type\":\"object\",\"properties\":{},\"required\":[]}");
            }
            try body.append('}');
        }
        try body.append(']');
    }

    fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// SSE event handler (called by sse.postSse for each data line).
    pub fn parseSseData(self: *AnthropicProvider, data: []const u8, session: anytype) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const etype = strOf(obj, "type") orelse return;
        if (std.mem.eql(u8, etype, "error")) {
            return error.StreamError;
        }

        if (std.mem.eql(u8, etype, "message_start")) {
            // input usage (incl. cache counters)
            if (obj.get("message")) |mv| {
                switch (mv) {
                    .object => |mo| {
                        if (mo.get("usage")) |uv| {
                            switch (uv) {
                                .object => |uo| {
                                    var u = msg.Usage{};
                                    u.input = @max(0, intIn(uo, "input_tokens") orelse 0);
                                    u.cache_read = @max(0, intIn(uo, "cache_read_input_tokens") orelse 0);
                                    u.cache_write = @max(0, intIn(uo, "cache_creation_input_tokens") orelse 0);
                                    u.total = u.input + u.output + u.cache_read + u.cache_write;
                                    session.onStreamEvent(.{ .usage = u });
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            return;
        }

        if (std.mem.eql(u8, etype, "content_block_start")) {
            const idx: usize = @intCast(@max(0, intIn(obj, "index") orelse 0));
            const cb = obj.get("content_block") orelse return;
            switch (cb) {
                .object => |cbo| {
                    const btype = strOf(cbo, "type") orelse return;
                    if (std.mem.eql(u8, btype, "tool_use")) {
                        var d = openai.ToolCallDelta{ .index = idx, .id = strOf(cbo, "id"), .name = strOf(cbo, "name"), .arguments_delta = "{}" };
                        // Anthropic sends `input: {}` up front and the real
                        // object via input_json_delta — don't seed "{}" when
                        // a delta will arrive; agent concatenates deltas, so
                        // start empty unless nothing else comes.
                        d.arguments_delta = "";
                        session.onStreamEvent(.{ .tool_call_delta = d });
                    } else if (std.mem.eql(u8, btype, "thinking")) {
                        if (strOf(cbo, "thinking")) |t| {
                            if (t.len > 0) {
                                const dup = self.alloc.dupe(u8, t) catch t;
                                session.onStreamEvent(.{ .thinking_delta = dup });
                                self.alloc.free(dup);
                            }
                        }
                    } else if (std.mem.eql(u8, btype, "text")) {
                        if (strOf(cbo, "text")) |t| {
                            if (t.len > 0) {
                                const dup = self.alloc.dupe(u8, t) catch t;
                                session.onStreamEvent(.{ .text_delta = dup });
                                self.alloc.free(dup);
                            }
                        }
                    }
                },
                else => {},
            }
            return;
        }

        if (std.mem.eql(u8, etype, "content_block_delta")) {
            const idx: usize = @intCast(@max(0, intIn(obj, "index") orelse 0));
            const dv = obj.get("delta") orelse return;
            switch (dv) {
                .object => |dobj| {
                    const dtype = strOf(dobj, "type") orelse return;
                    if (std.mem.eql(u8, dtype, "text_delta")) {
                        if (strOf(dobj, "text")) |t| {
                            if (t.len > 0) {
                                const dup = self.alloc.dupe(u8, t) catch t;
                                session.onStreamEvent(.{ .text_delta = dup });
                                self.alloc.free(dup);
                            }
                        }
                    } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
                        if (strOf(dobj, "thinking")) |t| {
                            if (t.len > 0) {
                                const dup = self.alloc.dupe(u8, t) catch t;
                                session.onStreamEvent(.{ .thinking_delta = dup });
                                self.alloc.free(dup);
                            }
                        }
                    } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                        if (strOf(dobj, "partial_json")) |pj| {
                            if (pj.len > 0) {
                                const d = openai.ToolCallDelta{ .index = idx, .id = null, .name = null, .arguments_delta = pj };
                                session.onStreamEvent(.{ .tool_call_delta = d });
                            }
                        }
                    }
                },
                else => {},
            }
            return;
        }

        if (std.mem.eql(u8, etype, "message_delta")) {
            // stop_reason + output usage
            if (obj.get("delta")) |dv| {
                switch (dv) {
                    .object => |dobj| {
                        if (strOf(dobj, "stop_reason")) |sr| {
                            const reason: FinishReason = if (std.mem.eql(u8, sr, "tool_use"))
                                .tool_calls
                            else if (std.mem.eql(u8, sr, "max_tokens"))
                                .length
                            else if (std.mem.eql(u8, sr, "refusal"))
                                .content_filter
                            else
                                .stop;
                            session.onStreamEvent(.{ .done = reason });
                        }
                    },
                    else => {},
                }
            }
            if (obj.get("usage")) |uv| {
                switch (uv) {
                    .object => |uo| {
                        var u = msg.Usage{};
                        u.output = @max(0, intIn(uo, "output_tokens") orelse 0);
                        u.total = u.output;
                        session.onStreamEvent(.{ .usage = u });
                    },
                    else => {},
                }
            }
            return;
        }
        // content_block_stop / message_stop / ping: nothing to do
    }
};

fn intIn(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn writeField(body: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try body.append('"');
    try body.appendSlice(key);
    try body.appendSlice("\":");
    try writeJsonStr(body, value);
}

/// Append a JSON-escaped string (with surrounding quotes).
fn writeJsonStr(body: *std.array_list.Managed(u8), s: []const u8) !void {
    return json.writeJsonStr(body, s);
}
