//! Google Generative AI adapter (Phase 6: google-generative-ai).
//! POST {base}/models/{model}:streamGenerateContent?alt=sse —
//! x-goog-api-key header, systemInstruction, functionCall/functionResponse
//! parts, SSE `data:` chunks with candidates[0].content.parts.

const std = @import("std");
const msg = @import("../core/message.zig");
const config = @import("../core/config.zig");
const json = @import("json.zig");
const openai = @import("openai.zig");
const sse = @import("sse.zig");

pub const ChatMessage = openai.OpenAiProvider.ChatMessage;
pub const FinishReason = openai.FinishReason;

const IdName = struct { id: []u8, name: []u8 };

pub const GoogleProvider = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []const u8,
    max_tokens: usize,
    client: std.http.Client,
    last_error_buf: [2048]u8 = undefined,
    last_error_len: usize = 0,
    /// tool_call id → function name (needed for functionResponse parts,
    /// which reference the function name rather than a call id).
    id_names: std.array_list.Managed(IdName),
    /// Running tool-call index for the in-flight response (agent accumulates
    /// stream_tools by index — must be contiguous from 0 across chunks).
    next_call_index: usize = 0,

    pub fn lastErrorText(self: *const GoogleProvider) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, api_key: []const u8, max_tokens: usize) !GoogleProvider {
        return .{
            .alloc = alloc,
            .io = io,
            .base_url = alloc.dupe(u8, base_url) catch return error.OutOfMemory,
            .api_key = api_key,
            .max_tokens = max_tokens,
            .client = .{ .allocator = alloc, .io = io },
            .id_names = std.array_list.Managed(IdName).init(alloc),
        };
    }

    pub fn deinit(self: *GoogleProvider) void {
        std.http.Client.deinit(&self.client);
        self.alloc.free(self.base_url);
        for (self.id_names.items) |e| {
            self.alloc.free(e.id);
            self.alloc.free(e.name);
        }
        self.id_names.deinit();
    }

    const max_retries: usize = 3;

    fn hasStreamedOutput(self: *GoogleProvider, session: anytype) bool {
        _ = self;
        return session.stream_text.items.len > 0 or
            session.stream_thinking.items.len > 0 or
            session.stream_tools.items.len > 0;
    }

    pub fn streamChat(
        self: *GoogleProvider,
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
        session: anytype,
    ) !void {
        // Remember tool-call names for functionResponse mapping.
        for (self.id_names.items) |e| {
            self.alloc.free(e.id);
            self.alloc.free(e.name);
        }
        self.id_names.clearRetainingCapacity();
        self.next_call_index = 0;
        for (messages) |m| {
            for (m.blocks) |b| switch (b) {
                .tool_call => |tc| {
                    self.id_names.append(.{
                        .id = self.alloc.dupe(u8, tc.id) catch continue,
                        .name = self.alloc.dupe(u8, tc.name) catch {
                            if (self.id_names.pop()) |last| self.alloc.free(last.id);
                            continue;
                        },
                    }) catch {};
                },
                else => {},
            };
        }

        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        try self.buildBody(&body, messages, tools_json, supports_images, thinking_level);

        const url_str = std.fmt.allocPrint(self.alloc, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ self.base_url, model }) catch return error.OutOfMemory;
        defer self.alloc.free(url_str);

        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const had_output = self.hasStreamedOutput(session);
            const outcome = sse.postSse(
                &self.client,
                self.alloc,
                url_str,
                "", // key goes via x-goog-api-key
                &.{.{ .name = "x-goog-api-key", .value = self.api_key }},
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

    fn buildBody(
        self: *const GoogleProvider,
        body: *std.array_list.Managed(u8),
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
    ) !void {
        _ = supports_images;
        try body.appendSlice("{");

        // systemInstruction from leading system message(s)
        var wrote_sys = false;
        for (messages) |m| {
            if (m.role != .system) continue;
            for (m.blocks) |b| switch (b) {
                .text => |t| {
                    if (t.len == 0) continue;
                    if (!wrote_sys) {
                        try body.appendSlice("\"systemInstruction\":{\"parts\":[");
                        wrote_sys = true;
                    } else {
                        try body.append(',');
                    }
                    try body.appendSlice("{\"text\":");
                    try writeJsonStr(body, t);
                    try body.append('}');
                },
                else => {},
            };
        }
        if (wrote_sys) try body.appendSlice("]},");

        // contents
        try body.appendSlice("\"contents\":[");
        var first = true;
        for (messages) |m| {
            if (m.role == .system) continue;
            if (!first) try body.append(',');
            first = false;
            switch (m.role) {
                .user, .bash_execution => {
                    try body.appendSlice("{\"role\":\"user\",\"parts\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"text\":");
                            try writeJsonStr(body, t);
                            try body.append('}');
                        },
                        .image => |img| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"inlineData\":{\"mimeType\":");
                            try writeJsonStr(body, img.mime);
                            try body.appendSlice(",\"data\":");
                            try writeJsonStr(body, img.data);
                            try body.appendSlice("}}");
                        },
                        else => {},
                    };
                    if (bfirst) try body.appendSlice("{\"text\":\" \"}");
                    try body.appendSlice("]}");
                },
                .assistant => {
                    try body.appendSlice("{\"role\":\"model\",\"parts\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .text => |t| {
                            if (t.len == 0) continue;
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"text\":");
                            try writeJsonStr(body, t);
                            try body.append('}');
                        },
                        .thinking => {},
                        .tool_call => |tc| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            try body.appendSlice("{\"functionCall\":{\"name\":");
                            try writeJsonStr(body, tc.name);
                            try body.appendSlice(",\"args\":");
                            if (tc.arguments.len > 0) {
                                try body.appendSlice(tc.arguments);
                            } else {
                                try body.appendSlice("{}");
                            }
                            try body.appendSlice("}}");
                        },
                        else => {},
                    };
                    if (bfirst) try body.appendSlice("{\"text\":\" \"}");
                    try body.appendSlice("]}");
                },
                .tool => {
                    try body.appendSlice("{\"role\":\"user\",\"parts\":[");
                    var bfirst = true;
                    for (m.blocks) |b| switch (b) {
                        .tool_result => |tr| {
                            if (!bfirst) try body.append(',');
                            bfirst = false;
                            const fname = self.nameFor(tr.tool_call_id);
                            try body.appendSlice("{\"functionResponse\":{\"name\":");
                            try writeJsonStr(body, fname);
                            try body.appendSlice(",\"response\":{\"result\":");
                            if (tr.content.len > 0 and (tr.content[0] == '{' or tr.content[0] == '[' or tr.content[0] == '"')) {
                                try body.appendSlice(tr.content);
                            } else {
                                try writeJsonStr(body, tr.content);
                            }
                            try body.appendSlice("}}}");
                        },
                        else => {},
                    };
                    try body.appendSlice("]}");
                },
                else => {},
            }
        }
        try body.appendSlice("]");

        // tools: functionDeclarations
        if (tools_json.len > 0) {
            try body.appendSlice(",\"tools\":[{\"functionDeclarations\":");
            try convertTools(body, tools_json);
            try body.appendSlice("}]");
        }

        // generationConfig
        try body.appendSlice(",\"generationConfig\":{");
        const max_part = std.fmt.allocPrint(self.alloc, "\"maxOutputTokens\":{d}", .{self.max_tokens}) catch return error.OutOfMemory;
        try body.appendSlice(max_part);
        self.alloc.free(max_part);
        if (thinking_level != .off) {
            try body.appendSlice(",\"thinkingConfig\":{\"includeThoughts\":true}");
        }
        try body.appendSlice("}");

        try body.appendSlice("}");
    }

    fn nameFor(self: *const GoogleProvider, call_id: []const u8) []const u8 {
        for (self.id_names.items) |e| {
            if (std.mem.eql(u8, e.id, call_id)) return e.name;
        }
        return call_id;
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
            try body.appendSlice("{\"name\":");
            try writeJsonStr(body, strOf(fobj, "name") orelse "");
            try body.appendSlice(",\"description\":");
            try writeJsonStr(body, strOf(fobj, "description") orelse "");
            try body.appendSlice(",\"parameters\":");
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

    /// SSE chunk handler. Each chunk:
    /// {candidates:[{content:{parts:[{text}|{functionCall}]},finishReason}],
    ///  usageMetadata:{promptTokenCount,candidatesTokenCount,thoughtsTokenCount}}
    pub fn parseSseData(self: *GoogleProvider, data: []const u8, session: anytype) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        if (obj.get("error")) |ev| {
            _ = ev;
            return error.StreamError;
        }

        if (obj.get("candidates")) |cv| {
            switch (cv) {
                .array => |carr| {
                    if (carr.items.len == 0) return;
                    const cand = switch (carr.items[0]) {
                        .object => |o| o,
                        else => return,
                    };
                    if (cand.get("content")) |contv| {
                        switch (contv) {
                            .object => |cont| {
                                if (cont.get("parts")) |pv| {
                                    switch (pv) {
                                        .array => |parts| {
                                            for (parts.items) |part| {
                                                switch (part) {
                                                    .object => |pobj| {
                                                        if (pobj.get("functionCall")) |fcv| {
                                                            switch (fcv) {
                                                                .object => |fc| {
                                                                    var d = openai.ToolCallDelta{
                                                                        .index = self.next_call_index,
                                                                        .id = null,
                                                                        .name = strOf(fc, "name"),
                                                                        .arguments_delta = null,
                                                                    };
                                                                    self.next_call_index += 1;
                                                                    if (fc.get("args")) |av| {
                                                                        const rendered = std.json.Stringify.valueAlloc(self.alloc, av, .{}) catch "{}";
                                                                        d.arguments_delta = rendered; // freed by agent after appending
                                                                    }
                                                                    session.onStreamEvent(.{ .tool_call_delta = d });
                                                                },
                                                                else => {},
                                                            }
                                                        } else if (strOf(pobj, "text")) |t| {
                                                            if (t.len == 0) continue;
                                                            const dup = self.alloc.dupe(u8, t) catch t;
                                                            if (pobj.get("thought")) |tv| {
                                                                switch (tv) {
                                                                    .bool => |is_thought| {
                                                                        if (is_thought) {
                                                                            session.onStreamEvent(.{ .thinking_delta = dup });
                                                                        } else {
                                                                            session.onStreamEvent(.{ .text_delta = dup });
                                                                        }
                                                                    },
                                                                    else => session.onStreamEvent(.{ .text_delta = dup }),
                                                                }
                                                            } else {
                                                                session.onStreamEvent(.{ .text_delta = dup });
                                                            }
                                                            self.alloc.free(dup);
                                                        }
                                                    },
                                                    else => {},
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
                    if (cand.get("finishReason")) |frv| {
                        switch (frv) {
                            .string => |s| {
                                const reason: FinishReason = if (std.mem.eql(u8, s, "MAX_TOKENS"))
                                    .length
                                else if (std.mem.eql(u8, s, "SAFETY") or std.mem.eql(u8, s, "PROHIBITED_CONTENT"))
                                    .content_filter
                                else
                                    .stop;
                                session.onStreamEvent(.{ .done = reason });
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (obj.get("usageMetadata")) |uv| {
            switch (uv) {
                .object => |uo| {
                    var u = msg.Usage{};
                    u.input = @max(0, intIn(uo, "promptTokenCount") orelse 0);
                    u.output = @max(0, intIn(uo, "candidatesTokenCount") orelse 0);
                    u.reasoning = @max(0, intIn(uo, "thoughtsTokenCount") orelse 0);
                    u.cache_read = @max(0, intIn(uo, "cachedContentTokenCount") orelse 0);
                    u.total = u.input + u.output + u.reasoning;
                    session.onStreamEvent(.{ .usage = u });
                },
                else => {},
            }
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
