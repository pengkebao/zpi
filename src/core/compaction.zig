//! Context compaction for long sessions (Phase C).
//!
//! Mirrors pi's core/compaction: pure estimation/serialization/summarization
//! functions. The Store persists the CompactionEntry; the Session triggers
//! compaction at turn boundaries and rebuilds context from it.

const std = @import("std");
const msg = @import("message.zig");
const ai = @import("../ai/openai.zig");
const aiprovider = @import("../ai/provider.zig");
const config = @import("config.zig");

/// pi DEFAULT_COMPACTION_SETTINGS.
pub const Settings = struct {
    enabled: bool = true,
    reserve_tokens: u32 = 16384,
    keep_recent_tokens: u32 = 20000,
};

pub const DEFAULT_SETTINGS = Settings{ .enabled = true, .reserve_tokens = 16384, .keep_recent_tokens = 20000 };

// ── Token estimation ────────────────────────────────────────────────

/// Conservative chars/4 estimate for one message (pi: estimateTokens).
pub fn estimateTokens(m: *const msg.Message) u64 {
    var chars: u64 = 0;
    for (m.blocks.items) |b| {
        switch (b) {
            .text => |t| chars += t.len,
            .thinking => |t| chars += t.len,
            .tool_call => |tc| chars += tc.name.len + tc.arguments.len,
            .tool_result => |tr| chars += tr.content.len,
            .image => |img| chars += img.data.len,
        }
    }
    return (chars + 3) / 4;
}

/// Context tokens: trust the last valid assistant usage, then add a chars/4
/// estimate for any messages after it (pi: estimateContextTokens).
pub fn estimateContextTokens(messages: []const msg.Message) u64 {
    var last_idx: ?usize = null;
    var last_tokens: u64 = 0;
    for (messages, 0..) |m, i| {
        if (m.role != .assistant) continue;
        if (m.usage) |u| {
            const aborted = m.stop_reason != null and
                (std.mem.eql(u8, m.stop_reason.?, "aborted") or std.mem.eql(u8, m.stop_reason.?, "error"));
            const total = if (u.total > 0) u.total else (u.input + u.output + u.cache_read + u.cache_write);
            if (!aborted and total > 0) {
                last_idx = i;
                last_tokens = total;
            }
        }
    }
    if (last_idx) |idx| {
        var trailing: u64 = 0;
        for (messages[idx + 1 ..]) |m| trailing += estimateTokens(&m);
        return last_tokens + trailing;
    }
    var est: u64 = 0;
    for (messages) |m| est += estimateTokens(&m);
    return est;
}

/// pi: shouldCompact.
pub fn shouldCompact(context_tokens: u64, context_window: usize, settings: *const Settings) bool {
    if (!settings.enabled) return false;
    // No subtraction: context_window may be smaller than reserve_tokens
    // (small local models), where window - reserve would underflow.
    return context_tokens + settings.reserve_tokens > context_window;
}

// ── Context overflow detection ──────────────────────────────────────────

/// AND-groups of case-insensitive substrings approximating pi's
/// OVERFLOW_PATTERNS (pi-ai dist/utils/overflow.js). Each group lists
/// substrings that must all appear; a single-substring group is a plain
/// literal match. Covers: Anthropic, z.ai (1261 too long), OpenAI,
/// LiteLLM, Google, xAI, Groq, OpenRouter, Together, Copilot, llama.cpp,
/// LM Studio, MiniMax, Kimi, Mistral, DS4, Qwen/DashScope, llama.cpp.
const OVERFLOW_GROUPS = [_][]const []const u8{
    &.{"prompt too long"}, // z.ai (1261)
    &.{"prompt is too long"}, // Anthropic token overflow
    &.{"prompt exceeds max length"}, // z.ai CN endpoint
    &.{"request_too_large"}, // Anthropic HTTP 413 byte-size
    &.{"input is too long for requested model"}, // Amazon Bedrock
    &.{"exceeds the context window"}, // OpenAI
    &.{"maximum context length"}, // OpenAI-compat / LiteLLM / OpenRouter / Together
    &.{"context window exceeded"}, // LiteLLM pre-call check
    &.{ "input token count", "exceeds the maximum" }, // Google
    &.{"maximum prompt length is"}, // xAI
    &.{"reduce the length of the messages"}, // Groq
    &.{"exceeds the limit of"}, // GitHub Copilot
    &.{"exceeds the available context size"}, // llama.cpp server
    &.{"greater than the context length"}, // LM Studio
    &.{"context window exceeds limit"}, // MiniMax
    &.{"exceeded model token limit"}, // Kimi For Coding
    &.{"too large for model with"}, // Mistral
    &.{"configured context size is"}, // DS4 server
    &.{"model_context_window_exceeded"}, // z.ai non-standard finish_reason
    &.{"range of input length should be"}, // DashScope / Qwen Token Plan
    &.{"context_length_exceeded"}, // OpenAI error type
};

/// Case-insensitive substring search (Zig 0.17 std has no indexOfIgnoreCase).
fn indexOfNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return i;
    }
    return null;
}

/// True if the provider error text matches any known context-overflow
/// pattern (pi: isContextOverflow on the assistant error message).
pub fn isOverflowError(text: []const u8) bool {
    if (text.len == 0) return false;
    for (OVERFLOW_GROUPS) |group| {
        var all = true;
        for (group) |pat| {
            if (indexOfNoCase(text, pat) == null) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

// ── File tracking ───────────────────────────────────────────────────

pub const FileOps = struct {
    alloc: std.mem.Allocator,
    read: std.StringArrayHashMapUnmanaged(void),
    written: std.StringArrayHashMapUnmanaged(void),
    edited: std.StringArrayHashMapUnmanaged(void),

    pub fn init(alloc: std.mem.Allocator) !FileOps {
        return .{
            .alloc = alloc,
            .read = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{}),
            .written = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{}),
            .edited = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{}),
        };
    }

    pub fn deinit(self: *FileOps) void {
        self.read.deinit(self.alloc);
        self.written.deinit(self.alloc);
        self.edited.deinit(self.alloc);
    }
};

/// Extract read/write/edit file paths from tool calls (pi: extractFileOpsFromMessage).
pub fn extractFileOpsFromMessage(m: *const msg.Message, ops: *FileOps) void {
    if (m.role != .assistant) return;
    for (m.blocks.items) |b| {
        switch (b) {
            .tool_call => |tc| addFileOp(tc.name, tc.arguments, ops),
            else => {},
        }
    }
}

fn addFileOp(name: []const u8, args_json: []const u8, ops: *FileOps) void {
    // Pull the "path" argument out of the raw JSON without a full parse.
    const path = extractJsonStringField(args_json, "path") orelse return;
    if (std.mem.eql(u8, name, "read")) {
        ops.read.put(ops.alloc, path, {}) catch {};
    } else if (std.mem.eql(u8, name, "write")) {
        ops.written.put(ops.alloc, path, {}) catch {};
    } else if (std.mem.eql(u8, name, "edit")) {
        ops.edited.put(ops.alloc, path, {}) catch {};
    }
}

/// Naive extraction of a top-level string field value from a flat JSON object.
fn extractJsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.mem.concat(scratch_alloc, u8, &.{ "\"", key, "\":" }) catch return null;
    defer scratch_alloc.free(needle);
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    // skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[start..i];
    }
    return null;
}

const scratch_alloc = std.heap.page_allocator;

pub const FileLists = struct { read: []const []const u8, modified: []const []const u8 };

fn strLessThan(ctx: void, a: []const u8, b: []const u8) bool {
    _ = ctx;
    return std.mem.lessThan(u8, a, b);
}

/// pi: computeFileLists — readFiles (read-only) + modifiedFiles (edited|written).
/// Returned outer slices are allocated with `alloc`; inner pointers point into `ops`.
pub fn computeFileLists(alloc: std.mem.Allocator, ops: *const FileOps) !FileLists {
    var modified_set = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{});
    defer modified_set.deinit(alloc);
    for (ops.edited.keys()) |p| try modified_set.put(alloc, p, {});
    for (ops.written.keys()) |p| try modified_set.put(alloc, p, {});

    var read_list = std.array_list.Managed([]const u8).init(alloc);
    defer read_list.deinit();
    var modified_list = std.array_list.Managed([]const u8).init(alloc);
    defer modified_list.deinit();

    for (ops.read.keys()) |p| {
        if (modified_set.contains(p)) continue;
        try read_list.append(p);
    }
    for (modified_set.keys()) |p| {
        try modified_list.append(p);
    }
    std.mem.sort([]const u8, read_list.items, {}, strLessThan);
    std.mem.sort([]const u8, modified_list.items, {}, strLessThan);
    return .{
        .read = try read_list.toOwnedSlice(),
        .modified = try modified_list.toOwnedSlice(),
    };
}

/// pi: formatFileOperations — append <read-files>/<modified-files> to the summary.
pub fn formatFileOperations(out: *std.array_list.Managed(u8), read_files: []const []const u8, modified_files: []const []const u8) !void {
    if (read_files.len == 0 and modified_files.len == 0) return;
    try out.appendSlice("\n\n");
    if (read_files.len > 0) {
        try out.appendSlice("<read-files>\n");
        for (read_files) |f| {
            try out.appendSlice(f);
            try out.append('\n');
        }
        try out.appendSlice("</read-files>");
    }
    if (modified_files.len > 0) {
        if (read_files.len > 0) try out.appendSlice("\n\n");
        try out.appendSlice("<modified-files>\n");
        for (modified_files) |f| {
            try out.appendSlice(f);
            try out.append('\n');
        }
        try out.appendSlice("</modified-files>");
    }
}

// ── Serialization ───────────────────────────────────────────────────

const TOOL_RESULT_MAX_CHARS: usize = 2000;

/// pi: serializeConversation — flatten messages into plain text so the model
/// summarizes rather than continues. Tool results truncated; thinking omitted.
pub fn serializeConversation(alloc: std.mem.Allocator, messages: []const msg.Message) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var first = true;
    for (messages) |m| {
        var part: [4096]u8 = undefined;
        var rendered: ?[]const u8 = null;
        switch (m.role) {
            .user => {
                const text = firstText(&m) orelse continue;
                rendered = std.fmt.bufPrint(&part, "[User]: {s}", .{text}) catch null;
            },
            .bash_execution => {
                const text = firstText(&m) orelse continue;
                rendered = std.fmt.bufPrint(&part, "[Bash]: {s}", .{text}) catch null;
            },
            .assistant => {
                // text block
                if (firstText(&m)) |t| {
                    rendered = std.fmt.bufPrint(&part, "[Assistant]: {s}", .{t}) catch null;
                }
                // tool calls
                var calls = std.array_list.Managed([]const u8).init(alloc);
                defer calls.deinit();
                for (m.blocks.items) |b| {
                    switch (b) {
                        .tool_call => |tc| {
                            var cb: [512]u8 = undefined;
                            const s = std.fmt.bufPrint(&cb, "{s}({s})", .{ tc.name, tc.arguments }) catch continue;
                            calls.append(s) catch {};
                        },
                        else => {},
                    }
                }
                if (calls.items.len > 0) {
                    var joined = std.array_list.Managed(u8).init(alloc);
                    defer joined.deinit();
                    for (calls.items, 0..) |c, i| {
                        if (i > 0) try joined.appendSlice("; ");
                        try joined.appendSlice(c);
                    }
                    if (rendered == null) {
                        rendered = std.fmt.allocPrint(alloc, "[Assistant tool calls]: {s}", .{joined.items}) catch return error.OutOfMemory;
                    } else {
                        const both = std.fmt.allocPrint(alloc, "[Assistant]: {s}\n[Assistant tool calls]: {s}", .{ rendered.?, joined.items }) catch return error.OutOfMemory;
                        rendered = both;
                    }
                }
            },
            .tool => {
                for (m.blocks.items) |b| {
                    switch (b) {
                        .tool_result => |tr| {
                            const text = truncateForSummary(tr.content, TOOL_RESULT_MAX_CHARS);
                            rendered = std.fmt.allocPrint(alloc, "[Tool result]: {s}", .{text}) catch return error.OutOfMemory;
                        },
                        else => {},
                    }
                }
            },
            .system => {},
        }
        if (rendered) |r| {
            if (!first) try out.appendSlice("\n\n");
            first = false;
            try out.appendSlice(r);
        }
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn firstText(m: *const msg.Message) ?[]const u8 {
    for (m.blocks.items) |b| {
        switch (b) {
            .text => |t| return t,
            else => {},
        }
    }
    return null;
}

fn truncateForSummary(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    // Keep prefix; the marker is cosmetic, so a plain slice is fine here.
    return text[0..max];
}

// ── Prompts (pi verbatim) ───────────────────────────────────────────

pub const SUMMARIZATION_SYSTEM_PROMPT =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

const SUMMARIZATION_PROMPT =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

const UPDATE_SUMMARIZATION_PROMPT =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

// ── Summarization LLM call ──────────────────────────────────────────

/// Minimal streaming session that captures the summary text (no TUI output).
const SummarySession = struct {
    alloc: std.mem.Allocator,
    stream_text: std.array_list.Managed(u8),
    stream_thinking: std.array_list.Managed(u8),
    stream_tools: std.array_list.Managed(msg.ToolCall),
    stream_usage: ?msg.Usage = null,
    abort_check: ?*const fn () bool = null,

    pub fn init(alloc: std.mem.Allocator, abort_check: ?*const fn () bool) SummarySession {
        return .{
            .alloc = alloc,
            .stream_text = std.array_list.Managed(u8).init(alloc),
            .stream_thinking = std.array_list.Managed(u8).init(alloc),
            .stream_tools = std.array_list.Managed(msg.ToolCall).init(alloc),
            .stream_usage = null,
            .abort_check = abort_check,
        };
    }

    pub fn deinit(self: *SummarySession) void {
        self.stream_text.deinit();
        self.stream_thinking.deinit();
        for (self.stream_tools.items) |*tc| {
            self.alloc.free(tc.id);
            self.alloc.free(tc.name);
            self.alloc.free(tc.arguments);
        }
        self.stream_tools.deinit();
    }

    pub fn isAborted(self: *SummarySession) bool {
        return if (self.abort_check) |c| c() else false;
    }

    pub fn onStreamEvent(self: *SummarySession, event: ai.StreamEvent) void {
        switch (event) {
            .text_delta => |t| self.stream_text.appendSlice(t) catch {},
            .thinking_delta => |t| self.stream_thinking.appendSlice(t) catch {},
            .tool_call_delta => |d| {
                while (d.index >= self.stream_tools.items.len) {
                    self.stream_tools.append(.{ .id = "", .name = "", .arguments = "" }) catch return;
                }
                if (d.id) |id| {
                    self.alloc.free(self.stream_tools.items[d.index].id);
                    self.stream_tools.items[d.index].id = self.alloc.dupe(u8, id) catch return;
                }
                if (d.name) |n| {
                    self.alloc.free(self.stream_tools.items[d.index].name);
                    self.stream_tools.items[d.index].name = self.alloc.dupe(u8, n) catch return;
                }
                if (d.arguments_delta) |delta| {
                    const merged: []u8 = std.mem.concat(self.alloc, u8, &.{ self.stream_tools.items[d.index].arguments, delta }) catch return;
                    self.alloc.free(self.stream_tools.items[d.index].arguments);
                    self.stream_tools.items[d.index].arguments = merged;
                }
            },
            .usage => |u| self.stream_usage = u,
            .done => {},
        }
    }
};

pub const SummaryResult = struct {
    text: []u8,
    usage: ?msg.Usage,
};

/// Generate (or iteratively update) a structured summary of the given messages.
pub fn generateSummary(
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: aiprovider.AnyProvider,
    model_id: []const u8,
    messages_to_summarize: []const msg.Message,
    previous_summary: ?[]const u8,
    custom_instructions: ?[]const u8,
    abort_check: ?*const fn () bool,
    max_tokens: usize,
) !SummaryResult {
    _ = io; // reserved for abort-aware sleeps; provider handles retries
    const convo = try serializeConversation(alloc, messages_to_summarize);
    defer alloc.free(convo);

    var prompt = std.array_list.Managed(u8).init(alloc);
    defer prompt.deinit();
    try prompt.appendSlice("<conversation>\n");
    try prompt.appendSlice(convo);
    try prompt.appendSlice("\n</conversation>\n\n");
    if (previous_summary) |ps| {
        try prompt.appendSlice("<previous-summary>\n");
        try prompt.appendSlice(ps);
        try prompt.appendSlice("\n</previous-summary>\n\n");
    }
    try prompt.appendSlice(if (previous_summary != null) UPDATE_SUMMARIZATION_PROMPT else SUMMARIZATION_PROMPT);
    if (custom_instructions) |ci| {
        try prompt.appendSlice("\n\nAdditional focus: ");
        try prompt.appendSlice(ci);
    }

    // Wire messages: system + single user prompt.
    var sys_blocks = std.array_list.Managed(msg.ContentBlock).init(alloc);
    defer sys_blocks.deinit();
    const sys_text = alloc.dupe(u8, SUMMARIZATION_SYSTEM_PROMPT) catch return error.OutOfMemory;
    defer alloc.free(sys_text);
    try sys_blocks.append(.{ .text = sys_text });

    var user_blocks = std.array_list.Managed(msg.ContentBlock).init(alloc);
    defer user_blocks.deinit();
    const prompt_owned = try prompt.toOwnedSlice();
    defer alloc.free(prompt_owned);
    try user_blocks.append(.{ .text = prompt_owned });

    var wire = std.array_list.Managed(ai.OpenAiProvider.ChatMessage).init(alloc);
    defer wire.deinit();
    try wire.append(.{ .role = .system, .blocks = sys_blocks.items });
    try wire.append(.{ .role = .user, .blocks = user_blocks.items });

    var sess = SummarySession.init(alloc, abort_check);
    defer sess.deinit();
    // Compaction is a cheap summarization call: no reasoning effort.
    aiprovider.streamDispatch(provider, model_id, wire.items, "[]", true, config.ThinkingLevel.off, .{}, max_tokens, &sess) catch |e| {
        if (e == error.Aborted) return e;
        return e;
    };

    const text = try sess.stream_text.toOwnedSlice();
    return .{ .text = text, .usage = sess.stream_usage };
}
