//! Message types for the agent conversation.

const std = @import("std");

pub const Role = enum { system, user, assistant, tool, bash_execution };

/// Token usage and cost for one assistant response (pi: Usage).
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    reasoning: u64 = 0,
    total: u64 = 0,
    cost_input: f64 = 0,
    cost_output: f64 = 0,
    cost_cache_read: f64 = 0,
    cost_cache_write: f64 = 0,
    cost: f64 = 0, // USD total, computed from model rates

    pub fn add(self: *Usage, other: Usage) void {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
        self.reasoning += other.reasoning;
        self.total += other.total;
        self.cost_input += other.cost_input;
        self.cost_output += other.cost_output;
        self.cost_cache_read += other.cost_cache_read;
        self.cost_cache_write += other.cost_cache_write;
        self.cost += other.cost;
    }

    /// pi formula: (input - cacheRead)*ci + cacheRead*cr + cacheWrite*cw + output*co,
    /// rates in USD per million tokens. Also fills the per-component costs.
    pub fn computeCost(
        self: *Usage,
        cost_input: ?f64,
        cost_output: ?f64,
        cost_cache_read: ?f64,
        cost_cache_write: ?f64,
    ) void {
        const ci = cost_input orelse 0;
        const co = cost_output orelse 0;
        const cr = cost_cache_read orelse cost_input orelse 0;
        const cw = cost_cache_write orelse 0;
        if (ci == 0 and co == 0 and cr == 0 and cw == 0) return;
        const plain_input = @as(f64, @floatFromInt(self.input)) - @as(f64, @floatFromInt(self.cache_read));
        const fin = @as(f64, @floatFromInt(self.input)) / 1_000_000.0;
        const fout = @as(f64, @floatFromInt(self.output)) / 1_000_000.0;
        const fcr = @as(f64, @floatFromInt(self.cache_read)) / 1_000_000.0;
        const fcw = @as(f64, @floatFromInt(self.cache_write)) / 1_000_000.0;
        self.cost_input = fin * ci;
        self.cost_output = fout * co;
        self.cost_cache_read = fcr * cr;
        self.cost_cache_write = fcw * cw;
        self.cost = plain_input * ci / 1_000_000.0 + self.cost_output + self.cost_cache_read + self.cost_cache_write;
    }
};

pub const ImageBlock = struct {
    /// base64-encoded image bytes (owned).
    data: []u8,
    /// MIME type, e.g. "image/png" (owned).
    mime: []u8,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
    image: ImageBlock,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: []u8, // raw JSON
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool,
    /// pi compat: toolName on the wire. Owned, freed by Message.deinit.
    tool_name: ?[]u8 = null,
};

/// Convert a bash execution message to user text for LLM context
/// (pi messages.js bashExecutionToText).
pub fn bashExecutionToText(alloc: std.mem.Allocator, command: []const u8, output: []const u8, exit_code: ?i32, cancelled: bool, truncated_path: ?[]const u8) error{OutOfMemory}![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice("Ran \x60");
    try out.appendSlice(command);
    try out.appendSlice("\x60\n");
    if (output.len > 0) {
        try out.appendSlice("```\n");
        try out.appendSlice(output);
        try out.appendSlice("\n```");
    } else {
        try out.appendSlice("(no output)");
    }
    if (cancelled) {
        try out.appendSlice("\n\n(command cancelled)");
    } else if (exit_code) |code| {
        if (code != 0) {
            var b: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "\n\nCommand exited with code {d}", .{code}) catch "";
            try out.appendSlice(s);
        }
    }
    if (truncated_path) |fp| {
        try out.appendSlice("\n\n[Output truncated. Full output: ");
        try out.appendSlice(fp);
        try out.appendSlice("]");
    }
    return out.toOwnedSlice();
}

pub const Message = struct {
    role: Role,
    blocks: std.array_list.Managed(ContentBlock),
    /// Token usage for this response (assistant messages only).
    usage: ?Usage = null,
    /// Unix milliseconds (session persistence compat).
    timestamp_ms: i64 = 0,
    /// Static "stop"/"toolUse"/... (assistant only).
    stop_reason: ?[]const u8 = null,
    /// Bash execution message (role == .bash_execution): the command line.
    bash_command: ?[]u8 = null,
    /// Exit code; null = cancelled or unknown.
    bash_exit_code: ?i32 = null,
    /// pi `!!` prefix: displayed but excluded from LLM context.
    bash_exclude: bool = false,
    /// pi compat wire fields (assistant); owned.
    provider: ?[]u8 = null,
    model_id: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator) Message {
        return .{ .role = .user, .blocks = .init(alloc) };
    }

    pub fn deinit(self: *const Message) void {
        // Ownership contract: every owned []u8 field and block payload is
        // heap-allocated by the same allocator. Callers must dupe literals
        // before storing (see allocStr helper).
        for (self.blocks.items) |b| {
            switch (b) {
                .text => |t| self.blocks.allocator.free(t),
                .thinking => |t| self.blocks.allocator.free(t),
                .tool_call => |tc| {
                    self.blocks.allocator.free(tc.id);
                    self.blocks.allocator.free(tc.name);
                    self.blocks.allocator.free(tc.arguments);
                },
                .tool_result => |tr| {
                    self.blocks.allocator.free(tr.tool_call_id);
                    self.blocks.allocator.free(tr.content);
                    if (tr.tool_name) |tn| self.blocks.allocator.free(tn);
                },
                .image => |img| {
                    self.blocks.allocator.free(img.data);
                    self.blocks.allocator.free(img.mime);
                },
            }
        }
        self.blocks.deinit();
        if (self.bash_command) |bc| self.blocks.allocator.free(bc);
        if (self.stop_reason) |sr| self.blocks.allocator.free(sr);
        if (self.provider) |p| self.blocks.allocator.free(p);
        if (self.model_id) |mid| self.blocks.allocator.free(mid);
    }

    /// Dupe a string for storage in an owned field; on OOM returns the
    /// original (caller may pass a literal, which then leaks — acceptable
    /// under OOM).
    pub fn allocStr(alloc: std.mem.Allocator, s: []const u8) []const u8 {
        return alloc.dupe(u8, s) catch s;
    }

    /// Deep copy — the result owns all its buffers independently.
    pub fn clone(self: *const Message, alloc: std.mem.Allocator) !Message {
        var out = Message.init(alloc);
        out.role = self.role;
        out.timestamp_ms = self.timestamp_ms;
        for (self.blocks.items) |b| {
            switch (b) {
                .text => |t| try out.blocks.append(.{ .text = try alloc.dupe(u8, t) }),
                .thinking => |t| try out.blocks.append(.{ .thinking = try alloc.dupe(u8, t) }),
                .tool_call => |tc| try out.blocks.append(.{ .tool_call = .{
                    .id = try alloc.dupe(u8, tc.id),
                    .name = try alloc.dupe(u8, tc.name),
                    .arguments = try alloc.dupe(u8, tc.arguments),
                } }),
                .tool_result => |tr| try out.blocks.append(.{ .tool_result = .{
                    .tool_call_id = try alloc.dupe(u8, tr.tool_call_id),
                    .content = try alloc.dupe(u8, tr.content),
                    .is_error = tr.is_error,
                    .tool_name = if (tr.tool_name) |tn| try alloc.dupe(u8, tn) else null,
                } }),
                .image => |img| try out.blocks.append(.{ .image = .{
                    .data = try alloc.dupe(u8, img.data),
                    .mime = try alloc.dupe(u8, img.mime),
                } }),
            }
        }
        if (self.stop_reason) |sr| out.stop_reason = try alloc.dupe(u8, sr);
        if (self.provider) |p| out.provider = try alloc.dupe(u8, p);
        if (self.model_id) |mid| out.model_id = try alloc.dupe(u8, mid);
        if (self.bash_command) |bc| out.bash_command = try alloc.dupe(u8, bc);
        out.bash_exit_code = self.bash_exit_code;
        out.bash_exclude = self.bash_exclude;
        // Usage is a value type (no pointers) → shallow copy.
        out.usage = self.usage;
        return out;
    }
};

/// Conversation: system prompt + history.
pub const Context = struct {
    alloc: std.mem.Allocator,
    system_prompt: []u8,
    messages: std.array_list.Managed(Message),

    pub fn init(alloc: std.mem.Allocator, system_prompt: []const u8) !Context {
        return .{
            .alloc = alloc,
            .system_prompt = alloc.dupe(u8, system_prompt) catch return error.OutOfMemory,
            .messages = .init(alloc),
        };
    }

    pub fn deinit(self: *Context) void {
        for (self.messages.items) |*m| m.deinit();
        self.messages.deinit();
        self.alloc.free(self.system_prompt);
    }

    /// Replace the system prompt (pi: system-prompt section patch on `/reload`).
    /// Takes ownership of `new_prompt` (a fresh allocation).
    pub fn setSystemPrompt(self: *Context, new_prompt: []const u8) !void {
        const copy = self.alloc.dupe(u8, new_prompt) catch return error.OutOfMemory;
        self.alloc.free(self.system_prompt);
        self.system_prompt = copy;
    }

    /// Deep-copy append: the Context owns its own buffers; the caller keeps
    /// ownership of `msg` and must deinit it independently.
    pub fn append(self: *Context, msg: Message) !void {
        const copy = msg.clone(self.alloc) catch return error.OutOfMemory;
        errdefer copy.deinit();
        try self.messages.append(copy);
    }
};
