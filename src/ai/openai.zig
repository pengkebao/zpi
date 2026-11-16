//! OpenAI-compatible HTTP provider with SSE streaming.
//! Works with: OpenAI, GLM, DeepSeek, Moonshot, Ollama, vLLM, etc.

const std = @import("std");
const msg = @import("../core/message.zig");
const config = @import("../core/config.zig");
const json = @import("json.zig");

/// Debug: when set (main.zig reads $ZPI_DEBUG_BODY), every outgoing
/// chat-completions body is written to this path for inspection
/// (a .1, .2, ... suffix distinguishes successive requests).
pub var debug_body_path: ?[]const u8 = null;
var debug_body_n: usize = 0;

pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    thinking_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    usage: msg.Usage,
    done: FinishReason,
};

pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8,
    name: ?[]const u8,
    arguments_delta: ?[]const u8,
};

pub const FinishReason = enum { stop, tool_calls, length, content_filter };

pub const OpenAiProvider = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []const u8,
    client: std.http.Client,
    /// Last HTTP error body (truncated) for overflow detection
    /// (pi reads the failed assistant error message; we keep the raw text).
    last_error_buf: [2048]u8 = undefined,
    last_error_len: usize = 0,

    pub fn lastErrorText(self: *const OpenAiProvider) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, api_key: []const u8) !OpenAiProvider {
        return .{
            .alloc = alloc,
            .io = io,
            .base_url = alloc.dupe(u8, base_url) catch return error.OutOfMemory,
            .api_key = api_key,
            .client = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *OpenAiProvider) void {
        std.http.Client.deinit(&self.client);
        self.alloc.free(self.base_url);
    }

    pub const ChatMessage = struct {
        role: msg.Role,
        blocks: []const msg.ContentBlock,
    };

    pub const ChatTool = struct {
        schema_json: []const u8,
    };

    pub const StreamOutcome = enum { ok, transport_error, retryable_status, fatal_status };

    /// Provider-specific thinking parameter shape (pi-ai compat.thinkingFormat
    /// + model.thinkingLevelMap), threaded through streamChat from the model.
    pub const ThinkingInfo = struct {
        format: config.ThinkingFormat = .default,
        /// thinkingLevelMap slots (index = @intFromEnum(level)); null = unset.
        map: ?*const [6]?[]u8 = null,
        reasoning: bool = false,
        /// null = auto-detect from base URL (zai endpoints → false).
        supports_effort: ?bool = null,

        /// pi: mappedEffort ?? level name.
        fn effortFor(self: ThinkingInfo, level: config.ThinkingLevel) []const u8 {
            if (self.map) |m| {
                if (m[@intFromEnum(level)]) |mapped| return mapped;
            }
            return level.name();
        }
    };

    const max_retries: usize = 3;

    fn hasStreamedOutput(self: *OpenAiProvider, session: anytype) bool {
        _ = self;
        return session.stream_text.items.len > 0 or
            session.stream_thinking.items.len > 0 or
            session.stream_tools.items.len > 0;
    }

    /// Send a streaming chat completion request with retry (429/408/5xx and
    /// transport errors) and cooperative abort between chunks.
    pub fn streamChat(
        self: *OpenAiProvider,
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
        tinfo: ThinkingInfo,
        max_tokens: usize,
        session: anytype,
    ) !void {
        // pi detected-compat defaults from the base URL: zai endpoints use
        // the thinking switch without reasoning_effort; other endpoints
        // default to accepting a (mapped) reasoning_effort.
        var info = tinfo;
        const is_zai_url = std.mem.indexOf(u8, self.base_url, "api.z.ai") != null or
            std.mem.indexOf(u8, self.base_url, "open.bigmodel.cn") != null;
        if (info.format == .default and is_zai_url) info.format = .zai;
        if (info.supports_effort == null) info.supports_effort = !is_zai_url;

        // Build JSON body
        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        try self.buildBody(&body, model, messages, tools_json, supports_images, thinking_level, .{
            .format = info.format,
            .map = info.map,
            .reasoning = info.reasoning,
            .supports_effort = info.supports_effort.?,
        }, max_tokens);

        // Build URL
        const url_str = std.fmt.allocPrint(self.alloc, "{s}/chat/completions", .{self.base_url}) catch return error.OutOfMemory;
        defer self.alloc.free(url_str);
        const uri = std.Uri.parse(url_str) catch return error.InvalidUri;

        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const had_output = self.hasStreamedOutput(session);
            const outcome = self.tryStream(uri, body.items, session);
            if (outcome == .ok) return;
            if (session.isAborted()) return error.Aborted;
            if (attempt >= max_retries) return error.HttpError;
            const retryable = outcome == .transport_error or
                (outcome == .retryable_status and !had_output);
            if (!retryable) return error.HttpError;
            // Exponential backoff: 250ms, 500ms (abort-aware)
            const delay_ms: i64 = 250 * @as(i64, @intCast(std.math.pow(u64, 2, attempt - 1)));
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(delay_ms), .real) catch {};
            std.debug.print("[retry {d}/{d}]\n", .{ attempt, max_retries - 1 });
        }
    }

    fn tryStream(self: *OpenAiProvider, uri: std.Uri, body_items: []const u8, session: anytype) StreamOutcome {
        // Build request
        var auth_header: [256]u8 = undefined;
        var extra_headers = std.array_list.Managed(std.http.Header).init(self.alloc);
        defer extra_headers.deinit();
        if (self.api_key.len > 0) {
            const auth_result = std.fmt.bufPrint(&auth_header, "Bearer {s}", .{self.api_key}) catch &[_]u8{};
            extra_headers.append(.{ .name = "Authorization", .value = auth_result }) catch return .transport_error;
        }
        extra_headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch return .transport_error;

        var request = self.client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = extra_headers.items,
            .keep_alive = false,
        }) catch return .transport_error;
        defer request.deinit();

        // Debug: dump the outgoing body for inspection (ZPI_DEBUG_BODY=path,
        // wired from main.zig into `debug_body_path`).
        if (debug_body_path) |base| {
            debug_body_n += 1;
            if (std.fmt.allocPrint(self.alloc, "{s}.{d}", .{ base, debug_body_n }) catch null) |path| {
                defer self.alloc.free(path);
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = body_items }) catch {};
            }
        }
        request.sendBodyComplete(@constCast(body_items)) catch return .transport_error;
        var response = request.receiveHead(&[_]u8{}) catch return .transport_error;

        if (response.head.status != .ok) {
            var rbuf: [4096]u8 = undefined;
            var reader = response.reader(&rbuf);
            // Read to EOF via fixed buffer: readAllocAll can error out on
            // short keep-alive responses (empty bodies break detection).
            var ebuf: [4096]u8 = undefined;
            const elen: usize = reader.readSliceShort(&ebuf) catch 0;
            const err_body: []const u8 = self.alloc.dupe(u8, ebuf[0..elen]) catch &[_]u8{};
            defer if (err_body.len > 0) self.alloc.free(err_body);
            // Keep the body for the agent's overflow detector.
            self.last_error_len = @min(err_body.len, self.last_error_buf.len);
            if (self.last_error_len > 0) {
                @memcpy(self.last_error_buf[0..self.last_error_len], err_body[0..self.last_error_len]);
            }
            std.debug.print("error: HTTP {d}\n", .{@as(u16, @intFromEnum(response.head.status))});
            if (err_body.len > 0) {
                std.debug.print("{s}\n", .{err_body});
            }
            const status = @intFromEnum(response.head.status);
            const retryable = status == 408 or status == 429 or (status >= 500 and status <= 599);
            return if (retryable) .retryable_status else .fatal_status;
        }

        // Parse SSE stream. Line-oriented on purpose: each line is yielded the
        // moment it lands in the read buffer, so deltas flow at packet cadence.
        // (readAllocShort(dest, 4096) filled its whole destination before
        // returning — only EOF returns short — batching ~70-100 ms of deltas
        // into one lump per read; streaming text arrived in visible jumps
        // even though the socket delivered smoothly.)
        // takeDelimiterInclusive consumes the newline; takeDelimiterExclusive
        // leaves it at the head of the buffer, so the next call returns an
        // empty slice forever (busy loop).
        var rbuf: [16384]u8 = undefined;
        var reader = response.reader(&rbuf);
        var done = false;
        while (!done) {
            if (session.isAborted()) return .ok;
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => {
                    // Pathological over-long line: drop the buffered bytes
                    // and resync at the next newline; the garbage tail of the
                    // line is skipped by parseChunk's catch.
                    reader.toss(reader.end - reader.seek);
                    continue;
                },
            };
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed["data:".len..], " \r\n");
            if (std.mem.eql(u8, data, "[DONE]")) {
                done = true;
                break;
            }
            self.parseChunk(data, session) catch continue;
        }
        return .ok;
    }

    fn buildBody(
        self: *const OpenAiProvider,
        body: *std.array_list.Managed(u8),
        model: []const u8,
        messages: []const ChatMessage,
        tools_json: []const u8,
        supports_images: bool,
        thinking_level: config.ThinkingLevel,
        tinfo: ThinkingInfo,
        max_tokens: usize,
    ) !void {
        try body.appendSlice("{");
        const model_part = std.fmt.allocPrint(self.alloc, "\"model\":\"{s}\",", .{model}) catch return error.OutOfMemory;
        try body.appendSlice(model_part);
        self.alloc.free(model_part);
        // pi always caps the completion (model.maxTokens, default 16384):
        // without it, an uncapped reasoning phase can consume the whole
        // response and leave no answer and no tool call.
        if (max_tokens > 0) {
            var mt: [40]u8 = undefined;
            const mt_field: []const u8 = if (std.mem.indexOf(u8, self.base_url, "api.z.ai") != null or
                std.mem.indexOf(u8, self.base_url, "open.bigmodel.cn") != null or
                std.mem.indexOf(u8, self.base_url, "api.deepseek.com") != null or
                std.mem.indexOf(u8, self.base_url, "api.moonshot") != null) "max_tokens" else "max_completion_tokens";
            // model_part above already ends with a comma; this field must
            // close its own comma before the next key.
            const mt_part = std.fmt.bufPrint(&mt, "\"{s}\":{d},", .{ mt_field, max_tokens }) catch "";
            try body.appendSlice(mt_part);
        }
        try body.appendSlice("\"stream\":true,\"stream_options\":{\"include_usage\":true},");
        try body.appendSlice("\"messages\":[");
        for (messages, 0..) |m, i| {
            if (i > 0) try body.append(',');
            try body.append('{');
            const role_part = std.fmt.allocPrint(self.alloc, "\"role\":\"{s}\",", .{@tagName(m.role)}) catch return error.OutOfMemory;
            try body.appendSlice(role_part);
            self.alloc.free(role_part);

            switch (m.role) {
                .bash_execution => {
                    // pi convertToLlm: bashExecution → user text (excluded
                    // messages were already filtered by buildWireMessages).
                    try body.appendSlice("\"role\":\"user\",\"content\":\"");
                    var text_parts2 = std.array_list.Managed([]const u8).init(self.alloc);
                    defer text_parts2.deinit();
                    for (m.blocks) |block| {
                        switch (block) {
                            .text => |t| try text_parts2.append(t),
                            else => {},
                        }
                    }
                    const joined = std.mem.concat(self.alloc, u8, text_parts2.items) catch return error.OutOfMemory;
                    defer self.alloc.free(joined);
                    try writeJsonStr(body, joined);
                    try body.appendSlice("\",\"name\":null}");
                },
                .system, .user => {
                    // Simple text content
                    var text_parts = std.array_list.Managed([]const u8).init(self.alloc);
                    defer text_parts.deinit();
                    for (m.blocks) |block| {
                        switch (block) {
                            .text => |t| try text_parts.append(t),
                            else => {},
                        }
                    }
                    if (text_parts.items.len == 0) {
                        try body.appendSlice("\"content\":\"\",");
                    } else if (text_parts.items.len == 1) {
                        try body.appendSlice("\"content\":");
                        try writeJsonStr(body, text_parts.items[0]);
                        try body.append(',');
                    } else {
                        try body.appendSlice("\"content\":");
                        const joined = std.mem.concat(self.alloc, u8, &.{ text_parts.items[0], " ", text_parts.items[1] }) catch "";
                        defer self.alloc.free(joined);
                        try writeJsonStr(body, joined);
                        try body.append(',');
                    }
                },
                .assistant => {
                    // Check for tool calls
                    var has_tool_calls = false;
                    var text_parts = std.array_list.Managed([]const u8).init(self.alloc);
                    defer text_parts.deinit();
                    for (m.blocks) |block| {
                        switch (block) {
                            .text => |t| try text_parts.append(t),
                            .tool_call => has_tool_calls = true,
                            else => {},
                        }
                    }
                    if (text_parts.items.len > 0) {
                        try body.appendSlice("\"content\":");
                        try writeJsonStr(body, text_parts.items[0]);
                        try body.append(',');
                    } else {
                        try body.appendSlice("\"content\":null,");
                    }
                    if (has_tool_calls) {
                        try body.appendSlice("\"tool_calls\":[");
                        var tc_first = true;
                        for (m.blocks) |block| {
                            switch (block) {
                                .tool_call => |tc| {
                                    if (!tc_first) try body.append(',');
                                    tc_first = false;
                                    try body.appendSlice("{\"id\":");
                                    try writeJsonStr(body, tc.id);
                                    try body.appendSlice(",\"type\":\"function\",\"function\":{\"name\":");
                                    try writeJsonStr(body, tc.name);
                                    try body.appendSlice(",\"arguments\":");
                                    try writeJsonStr(body, tc.arguments);
                                    try body.appendSlice("}}");
                                },
                                else => {},
                            }
                        }
                        try body.appendSlice("],");
                    }
                },
                .tool => {
                    // Tool result
                    for (m.blocks) |block| {
                        switch (block) {
                            .tool_result => |tr| {
                                try body.appendSlice("\"tool_call_id\":");
                                try writeJsonStr(body, tr.tool_call_id);
                                try body.appendSlice(",\"content\":");
                                try writeJsonStr(body, tr.content);
                                try body.append(',');
                            },
                            else => {},
                        }
                    }
                },
            }

            // Remove trailing comma
            if (body.items.len > 0 and body.items[body.items.len - 1] == ',') {
                _ = body.pop();
            }
            try body.append('}');

            // Image follow-up: a tool result carrying image blocks is sent as
            // text only; the images go in a follow-up user message (pi parity).
            if (m.role == .tool and supports_images) {
                var has_image = false;
                for (m.blocks) |b| {
                    if (b == .image) has_image = true;
                }
                if (has_image) {
                    try body.append(',');
                    try body.appendSlice("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Attached image(s) from tool result:\"}");
                    for (m.blocks) |b| {
                        switch (b) {
                            .image => |img| {
                                try body.append(',');
                                try body.appendSlice("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                                try body.appendSlice(img.mime);
                                try body.appendSlice(";base64,");
                                try body.appendSlice(img.data);
                                try body.appendSlice("\"}}");
                            },
                            else => {},
                        }
                    }
                    try body.appendSlice("]}");
                }
            }
        }
        try body.appendSlice("]");

        if (tools_json.len > 0) {
            try body.appendSlice(",\"tools\":");
            try body.appendSlice(tools_json);
        }

        // Thinking parameters (pi openai-completions thinkingFormat semantics).
        // .default sends reasoning_effort; zai sends thinking:{type} (GLM);
        // qwen sends enable_thinking (DashScope). Only sent when a thinking
        // level is active; off sends nothing so non-reasoning models are
        // unaffected (except zai/qwen reasoning models, which get an explicit
        // disabled switch).
        switch (tinfo.format) {
            .default => if (thinking_level != .off and (tinfo.supports_effort orelse true)) {
                // pi: reasoning_effort = thinkingLevelMap[level] ?? level
                // (xhigh/max pass through for models that support them).
                var effort_buf: [64]u8 = undefined;
                const effort = tinfo.effortFor(thinking_level);
                const part = std.fmt.bufPrint(&effort_buf, ",\"reasoning_effort\":\"{s}\"", .{effort}) catch "";
                try body.appendSlice(part);
            },
            .zai => if (tinfo.reasoning) {
                if (thinking_level == .off) {
                    try body.appendSlice(",\"thinking\":{\"type\":\"disabled\"}");
                } else {
                    try body.appendSlice(",\"thinking\":{\"type\":\"enabled\",\"clear_thinking\":false}");
                    if (tinfo.supports_effort orelse false) {
                        var effort_buf: [64]u8 = undefined;
                        const effort = tinfo.effortFor(thinking_level);
                        const part = std.fmt.bufPrint(&effort_buf, ",\"reasoning_effort\":\"{s}\"", .{effort}) catch "";
                        try body.appendSlice(part);
                    }
                }
            },
            .qwen => if (tinfo.reasoning) {
                if (thinking_level == .off) {
                    try body.appendSlice(",\"enable_thinking\":false");
                } else {
                    try body.appendSlice(",\"enable_thinking\":true");
                    if (tinfo.supports_effort orelse false) {
                        var effort_buf: [64]u8 = undefined;
                        const effort = tinfo.effortFor(thinking_level);
                        const part = std.fmt.bufPrint(&effort_buf, ",\"reasoning_effort\":\"{s}\"", .{effort}) catch "";
                        try body.appendSlice(part);
                    }
                }
            },
            .qwen_chat_template => if (tinfo.reasoning) {
                // pi qwen-chat-template: chat_template_kwargs with thinking
                // preserved across turns (local vLLM/SGLang Qwen endpoints).
                if (thinking_level == .off) {
                    try body.appendSlice(",\"chat_template_kwargs\":{\"enable_thinking\":false,\"preserve_thinking\":true}");
                } else {
                    try body.appendSlice(",\"chat_template_kwargs\":{\"enable_thinking\":true,\"preserve_thinking\":true}");
                }
            },
        }

        try body.append('}');
    }

fn parseChunk(self: *OpenAiProvider, data: []const u8, session: anytype) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
        defer parsed.deinit();

        const value = parsed.value;
        switch (value) {
            .object => |obj| {
                // Usage (final chunk with stream_options.include_usage; some
                // providers also send it per-choice)
                if (obj.get("usage")) |uv| {
                    switch (uv) {
                        .object => |uo| {
                            if (parseUsage(uo)) |u| session.onStreamEvent(.{ .usage = u });
                        },
                        else => {},
                    }
                }
                const choices = obj.get("choices") orelse return;
                switch (choices) {
                    .array => |arr| {
                        for (arr.items) |choice| {
                            switch (choice) {
                                .object => |cobj| {
                                    // finish_reason
                                    if (cobj.get("finish_reason")) |fr_val| {
                                        switch (fr_val) {
                                            .string => |s| {
                                                const reason = if (std.mem.eql(u8, s, "tool_calls"))
                                                    FinishReason.tool_calls
                                                else if (std.mem.eql(u8, s, "length"))
                                                    FinishReason.length
                                                else
                                                    FinishReason.stop;
                                                session.onStreamEvent(.{ .done = reason });
                                            },
                                            else => {},
                                        }
                                    }
                                    // delta
                                    if (cobj.get("delta")) |delta_val| {
                                        switch (delta_val) {
                                            .object => |delta| {
                                                // Thinking deltas (deepseek/qwen/openrouter styles)
                                                inline for (.{ "reasoning_content", "reasoning", "reasoning_text" }) |tfield| {
                                                    if (delta.get(tfield)) |tv| {
                                                        switch (tv) {
                                                            .string => |ts| {
                                                                if (ts.len > 0) {
                                                                    const tdup = self.alloc.dupe(u8, ts) catch ts;
                                                                    session.onStreamEvent(.{ .thinking_delta = tdup });
                                                                    self.alloc.free(tdup);
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                }
                                                if (delta.get("content")) |cv| {
                                                    switch (cv) {
                                                        .string => |text| {
                                                            if (text.len > 0) {
                                                                const dup = self.alloc.dupe(u8, text) catch text;
                                                                session.onStreamEvent(.{ .text_delta = dup });
                                                                self.alloc.free(dup);
                                                            }
                                                        },
                                                        else => {},
                                                    }
                                                }
                                                if (delta.get("tool_calls")) |tcs_val| {
                                                    switch (tcs_val) {
                                                        .array => |tcs_arr| {
                                                            for (tcs_arr.items) |tc_val| {
                                                                switch (tc_val) {
                                                                    .object => |tc_obj| {
                                                                        var d = ToolCallDelta{ .index = 0, .id = null, .name = null, .arguments_delta = null };
                                                                        if (tc_obj.get("index")) |idx| {
                                                                            switch (idx) {
                                                                                .integer => |n| d.index = @intCast(n),
                                                                                else => {},
                                                                            }
                                                                        }
                                                                        if (tc_obj.get("id")) |id_v| {
                                                                            switch (id_v) {
                                                                                .string => |s| d.id = s,
                                                                                else => {},
                                                                            }
                                                                        }
                                                                        if (tc_obj.get("function")) |fn_v| {
                                                                            switch (fn_v) {
                                                                                .object => |fn_obj| {
                                                                                    if (fn_obj.get("name")) |n_v| {
                                                                                        switch (n_v) {
                                                                                            .string => |s| d.name = s,
                                                                                            else => {},
                                                                                        }
                                                                                    }
                                                                                    if (fn_obj.get("arguments")) |a_v| {
                                                                                        switch (a_v) {
                                                                                            .string => |s| d.arguments_delta = s,
                                                                                            else => {},
                                                                                        }
                                                                                    }
                                                                                },
                                                                                else => {},
                                                                            }
                                                                        }
                                                                        session.onStreamEvent(.{ .tool_call_delta = d });
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
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

/// Parse an OpenAI-style usage object (prompt/completion tokens, cached
/// details). Tolerates anthropic-style cache fields some gateways emit.
fn parseUsage(o: std.json.ObjectMap) ?msg.Usage {
    var u = msg.Usage{};
    var got = false;
    if (intIn(o, "prompt_tokens")) |n| { u.input = n; got = true; }
    if (intIn(o, "completion_tokens")) |n| { u.output = n; got = true; }
    if (intIn(o, "total_tokens")) |n| {
        u.total = n;
    } else if (got) {
        u.total = u.input + u.output;
    }
    if (o.get("prompt_tokens_details")) |pd| {
        switch (pd) {
            .object => |po| u.cache_read = intIn(po, "cached_tokens") orelse 0,
            else => {},
        }
    }
    if (u.cache_read == 0) u.cache_read = intIn(o, "cache_read_input_tokens") orelse 0;
    if (u.cache_read == 0) u.cache_read = intIn(o, "cache_read_tokens") orelse 0;
    if (o.get("cache_creation_input_tokens")) |cc| {
        switch (cc) {
            .integer => |n| u.cache_write = @intCast(@max(0, n)),
            else => {},
        }
    }
    if (!got and u.total == 0) return null;
    return u;
}

fn intIn(o: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else 0,
        .float => |n| if (n >= 0) @as(u64, @intFromFloat(n)) else 0,
        else => null,
    };
}

fn writeJsonStr(body: *std.array_list.Managed(u8), s: []const u8) !void {
    return json.writeJsonStr(body, s);
}



// ── Tests ────────────────────────────────────────────────────────────────

test "buildBody default format sends reasoning_effort" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    try p.buildBody(&body, "m", &msgs, "", false, .high, .{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"thinking\"") == null);
}

test "buildBody zai format sends thinking switch" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    // reasoning model + thinking on → enabled switch
    try p.buildBody(&body, "m", &msgs, "", false, .high, .{ .format = .zai, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"thinking\":{\"type\":\"enabled\",\"clear_thinking\":false}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "reasoning_effort") == null);
    // off → explicit disabled switch
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .off, .{ .format = .zai, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"thinking\":{\"type\":\"disabled\"}") != null);
    // non-reasoning model → nothing
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .high, .{ .format = .zai, .reasoning = false }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"thinking\"") == null);
}

test "buildBody qwen format sends enable_thinking" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    try p.buildBody(&body, "m", &msgs, "", false, .medium, .{ .format = .qwen, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"enable_thinking\":true") != null);
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .off, .{ .format = .qwen, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"enable_thinking\":false") != null);
}

test "buildBody qwen-chat-template sends chat_template_kwargs" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    try p.buildBody(&body, "m", &msgs, "", false, .medium, .{ .format = .qwen_chat_template, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"chat_template_kwargs\":{\"enable_thinking\":true,\"preserve_thinking\":true}") != null);
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .off, .{ .format = .qwen_chat_template, .reasoning = true }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"chat_template_kwargs\":{\"enable_thinking\":false,\"preserve_thinking\":true}") != null);
    // non-reasoning model → nothing
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .medium, .{ .format = .qwen_chat_template, .reasoning = false }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "chat_template_kwargs") == null);
}

test "buildBody sends max_completion_tokens (max_tokens on zai endpoints)" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    try p.buildBody(&body, "m", &msgs, "", false, .off, .{}, 16384);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"max_completion_tokens\":16384,\"stream\":true") != null);
    // The whole body must be valid JSON (catches comma/quote slips).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try std.json.parseFromSlice(std.json.Value, arena.allocator(), body.items, .{});
    // zai-style endpoint → legacy max_tokens field
    const pz = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("https://open.bigmodel.cn/api/coding/paas/v4"),
        .api_key = "",
        .client = undefined,
    };
    var bodyz = std.array_list.Managed(u8).init(std.testing.allocator);
    defer bodyz.deinit();
    try pz.buildBody(&bodyz, "m", &msgs, "", false, .off, .{}, 16384);
    try std.testing.expect(std.mem.indexOf(u8, bodyz.items, "\"max_tokens\":16384,\"stream\":true") != null);
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    _ = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), bodyz.items, .{});
    // 0 → omitted
    bodyz.clearRetainingCapacity();
    try pz.buildBody(&bodyz, "m", &msgs, "", false, .off, .{}, 0);
    try std.testing.expect(std.mem.indexOf(u8, bodyz.items, "max_tokens") == null);
}

test "buildBody thinkingLevelMap remaps effort" {
    const p = OpenAiProvider{
        .alloc = std.testing.allocator,
        .io = undefined,
        .base_url = @constCast("http://x"),
        .api_key = "",
        .client = undefined,
    };
    var map = [6]?[]u8{ null, null, null, null, std.testing.allocator.dupe(u8, "high_v2") catch unreachable, null };
    defer std.testing.allocator.free(map[4].?);
    var body = std.array_list.Managed(u8).init(std.testing.allocator);
    defer body.deinit();
    var user_blocks = [_]msg.ContentBlock{.{ .text = "hi" }};
    var msgs = [_]OpenAiProvider.ChatMessage{.{ .role = .user, .blocks = &user_blocks }};
    // zai + supports_effort + map[xhigh]="high_v2" → mapped string
    try p.buildBody(&body, "m", &msgs, "", false, .xhigh, .{ .format = .zai, .reasoning = true, .supports_effort = true, .map = &map }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"reasoning_effort\":\"high_v2\"") != null);
    // unmapped level falls back to the level name (pi: mappedEffort ?? level)
    body.clearRetainingCapacity();
    try p.buildBody(&body, "m", &msgs, "", false, .low, .{ .format = .zai, .reasoning = true, .supports_effort = true, .map = &map }, 0);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"reasoning_effort\":\"low\"") != null);
}
