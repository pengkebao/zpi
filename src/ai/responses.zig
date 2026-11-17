//! OpenAI Responses API adapter (Phase 6: openai-responses).
//! POST {base}/responses — Bearer auth, `instructions` for the system
//! prompt, input items (message / function_call / function_call_output),
//! SSE events: response.output_text.delta, response.output_item.added,
//! response.function_call_arguments.delta, response.completed.

const std = @import("std");
const msg = @import("../core/message.zig");
const config = @import("../core/config.zig");
const json = @import("json.zig");
const openai = @import("openai.zig");
const sse = @import("sse.zig");

pub const ChatMessage = openai.OpenAiProvider.ChatMessage;
pub const FinishReason = openai.FinishReason;

pub const ResponsesProvider = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []const u8,
    max_tokens: usize,
    client: std.http.Client,
    last_error_buf: [2048]u8 = undefined,
    last_error_len: usize = 0,
    /// Terminal SSE event marker (see anthropic.stream_done).
    stream_done: bool = false,
    /// Contiguous tool-call index across chunks (agent accumulates by index).
    next_call_index: usize = 0,

    pub fn lastErrorText(self: *const ResponsesProvider) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, api_key: []const u8, max_tokens: usize) !ResponsesProvider {
        return .{
            .alloc = alloc,
            .io = io,
            .base_url = alloc.dupe(u8, base_url) catch return error.OutOfMemory,
            .api_key = api_key,
            .max_tokens = max_tokens,
            .client = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *ResponsesProvider) void {
        std.http.Client.deinit(&self.client);
        self.alloc.free(self.base_url);
    }

    const max_retries: usize = 3;

    fn hasStreamedOutput(self: *ResponsesProvider, session: anytype) bool {
        _ = self;
        return session.stream_text.items.len > 0 or
            session.stream_thinking.items.len > 0 or
            session.stream_tools.items.len > 0;
    }

    pub fn streamChat(
        self: *ResponsesProvider,
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
        session: anytype,
    ) !void {
        self.next_call_index = 0;
        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        try self.buildBody(&body, model, messages, tools_json, supports_images, thinking_level);

        const url_str = std.fmt.allocPrint(self.alloc, "{s}/responses", .{self.base_url}) catch return error.OutOfMemory;
        defer self.alloc.free(url_str);

        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const had_output = self.hasStreamedOutput(session);
            self.stream_done = false;
            const outcome = sse.postSse(
                &self.client,
                self.alloc,
                url_str,
                self.api_key,
                &.{},
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
        self: *const ResponsesProvider,
        body: *std.array_list.Managed(u8),
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
    ) !void {
        _ = supports_images;
        try body.appendSlice("{");
        try body.appendSlice("\"model\":");
        try writeJsonStr(body, model);
        try body.appendSlice(",\"stream\":true");

        // instructions = system prompt (leading system messages)
        for (messages) |m| {
            if (m.role != .system) continue;
            const text = textOf(m.blocks);
            if (text.len == 0) continue;
            try body.appendSlice(",\"instructions\":");
            try writeJsonStr(body, text);
            break;
        }

        // input items
        try body.appendSlice(",\"input\":[");
        var first = true;
        for (messages) |m| {
            if (m.role == .system) continue;
            switch (m.role) {
                .user, .bash_execution => {
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (!first) try body.append(',');
                            first = false;
                            try body.appendSlice("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
                            try writeJsonStr(body, t);
                            try body.appendSlice("}]}");
                        },
                        .image => |img| {
                            if (!first) try body.append(',');
                            first = false;
                            try body.appendSlice("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:");
                            try body.appendSlice(img.mime);
                            try body.appendSlice(";base64,");
                            try body.appendSlice(img.data);
                            try body.appendSlice("\"}]}");
                        },
                        else => {},
                    };
                },
                .assistant => {
                    // text → message(output_text); tool_call → function_call
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (t.len == 0) continue;
                            if (!first) try body.append(',');
                            first = false;
                            try body.appendSlice("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                            try writeJsonStr(body, t);
                            try body.appendSlice("}]}");
                        },
                        .tool_call => |tc| {
                            if (!first) try body.append(',');
                            first = false;
                            try body.appendSlice("{\"type\":\"function_call\",\"call_id\":");
                            try writeJsonStr(body, tc.id);
                            try body.appendSlice(",\"name\":");
                            try writeJsonStr(body, tc.name);
                            try body.appendSlice(",\"arguments\":");
                            if (tc.arguments.len > 0) {
                                try body.appendSlice(tc.arguments);
                            } else {
                                try body.appendSlice("{}");
                            }
                            try body.append('}');
                        },
                        else => {},
                    };
                },
                .tool => {
                    for (m.blocks) |b| switch (b) {
                        .tool_result => |tr| {
                            if (!first) try body.append(',');
                            first = false;
                            try body.appendSlice("{\"type\":\"function_call_output\",\"call_id\":");
                            try writeJsonStr(body, tr.tool_call_id);
                            try body.appendSlice(",\"output\":");
                            try writeJsonStr(body, tr.content);
                            try body.append('}');
                        },
                        else => {},
                    };
                },
                else => {},
            }
        }
        try body.appendSlice("]");

        // tools: flat function form {type,name,description,parameters}
        if (tools_json.len > 0) {
            try body.appendSlice(",\"tools\":");
            try convertTools(body, tools_json);
        }

        // reasoning effort
        if (thinking_level != .off) {
            const effort = switch (thinking_level) {
                .low => "low",
                .medium => "medium",
                .high => "high",
                else => "high",
            };
            try body.appendSlice(",\"reasoning\":{\"effort\":");
            try writeJsonStr(body, effort);
            try body.append('}');
        }

        if (self.max_tokens > 0) {
            const mp = std.fmt.allocPrint(self.alloc, ",\"max_output_tokens\":{d}", .{self.max_tokens}) catch return error.OutOfMemory;
            try body.appendSlice(mp);
            self.alloc.free(mp);
        }

        try body.append('}');
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
            // tolerate the flat {type:"function",name,...} form too
            const fobj: std.json.ObjectMap = if (obj.get("function")) |fv| switch (fv) {
                .object => |o| o,
                else => continue,
            } else obj;
            if (!first) try body.append(',');
            first = false;
            try body.appendSlice("{\"type\":\"function\",\"name\":");
            try writeJsonStr(body, strOf(fobj, "name") orelse "");
            try body.appendSlice(",\"description\":");
            try writeJsonStr(body, strOf(fobj, "description") orelse "");
            try body.appendSlice(",\"strict\":false,\"parameters\":");
            if (fobj.get("parameters")) |pv| {
                const rendered = std.json.Stringify.valueAlloc(body.allocator, pv, .{}) catch "{}";
                defer if (rendered.len > 0) body.allocator.free(@constCast(rendered));
                try body.appendSlice(rendered);
            } else {
                try body.appendSlice("{\"type\":\"object\",\"properties\":{}}");
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

    pub fn parseSseData(self: *ResponsesProvider, data: []const u8, session: anytype) !void {
        self.stream_done = false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const etype = strOf(obj, "type") orelse return;

        if (std.mem.eql(u8, etype, "error") or std.mem.eql(u8, etype, "response.error")) {
            return error.StreamError;
        }

        if (std.mem.eql(u8, etype, "response.output_text.delta")) {
            if (strOf(obj, "delta")) |t| {
                if (t.len > 0) {
                    const dup = self.alloc.dupe(u8, t) catch t;
                    session.onStreamEvent(.{ .text_delta = dup });
                    self.alloc.free(dup);
                }
            }
            return;
        }

        // reasoning deltas (reasoning items / summary text)
        if (std.mem.eql(u8, etype, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, etype, "response.reasoning_text.delta"))
        {
            if (strOf(obj, "delta")) |t| {
                if (t.len > 0) {
                    const dup = self.alloc.dupe(u8, t) catch t;
                    session.onStreamEvent(.{ .thinking_delta = dup });
                    self.alloc.free(dup);
                }
            }
            return;
        }

        if (std.mem.eql(u8, etype, "response.output_item.added")) {
            const item = obj.get("item") orelse return;
            switch (item) {
                .object => |io_| {
                    const itype = strOf(io_, "type") orelse return;
                    if (std.mem.eql(u8, itype, "function_call")) {
                        const d = openai.ToolCallDelta{
                            .index = self.next_call_index,
                            .id = strOf(io_, "call_id") orelse strOf(io_, "id"),
                            .name = strOf(io_, "name"),
                            .arguments_delta = "",
                        };
                        self.next_call_index += 1;
                        session.onStreamEvent(.{ .tool_call_delta = d });
                    }
                },
                else => {},
            }
            return;
        }

        if (std.mem.eql(u8, etype, "response.function_call_arguments.delta")) {
            if (strOf(obj, "delta")) |t| {
                if (t.len > 0) {
                    const d = openai.ToolCallDelta{
                        .index = self.next_call_index -| 1,
                        .id = null,
                        .name = null,
                        .arguments_delta = t,
                    };
                    session.onStreamEvent(.{ .tool_call_delta = d });
                }
            }
            return;
        }

        if (std.mem.eql(u8, etype, "response.completed") or std.mem.eql(u8, etype, "response.incomplete")) {
            self.stream_done = true;
            if (obj.get("response")) |rv| {
                switch (rv) {
                    .object => |ro| {
                        if (ro.get("usage")) |uv| {
                            switch (uv) {
                                .object => |uo| {
                                    var u = msg.Usage{};
                                    u.input = @max(0, intIn(uo, "input_tokens") orelse 0);
                                    u.output = @max(0, intIn(uo, "output_tokens") orelse 0);
                                    if (uo.get("input_tokens_details")) |pd| {
                                        switch (pd) {
                                            .object => |po| u.cache_read = @max(0, intIn(po, "cached_tokens") orelse 0),
                                            else => {},
                                        }
                                    }
                                    u.total = u.input + u.output;
                                    session.onStreamEvent(.{ .usage = u });
                                },
                                else => {},
                            }
                        }
                        if (ro.get("incomplete_details")) |iv| {
                            switch (iv) {
                                .object => |io_| {
                                    if (strOf(io_, "reason")) |r| {
                                        const reason: FinishReason = if (std.mem.eql(u8, r, "max_output_tokens"))
                                            .length
                                        else
                                            .stop;
                                        session.onStreamEvent(.{ .done = reason });
                                    }
                                },
                                else => session.onStreamEvent(.{ .done = .stop }),
                            }
                        } else {
                            session.onStreamEvent(.{ .done = .stop });
                        }
                    },
                    else => session.onStreamEvent(.{ .done = .stop }),
                }
            }
            return;
        }
        if (std.mem.eql(u8, etype, "response.failed")) {
            return error.StreamError;
        }
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

fn writeJsonStr(body: *std.array_list.Managed(u8), s: []const u8) !void {
    return json.writeJsonStr(body, s);
}
