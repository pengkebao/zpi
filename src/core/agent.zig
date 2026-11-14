//! Agent session: the core loop (prompt → LLM → tools → LLM → ...).

const std = @import("std");
const builtin = @import("builtin");
const msg = @import("message.zig");
const ai = @import("../ai/openai.zig");
const tools = @import("../tools/registry.zig");
const config = @import("config.zig");
const ss = @import("session_store.zig");
const compact = @import("compaction.zig");

/// Global abort flag, set by the SIGINT handler (signal handlers cannot
/// reach session state). Checked between stream chunks and around tool calls.
var g_abort = std.atomic.Value(bool).init(false);

pub fn requestAbort() void {
    g_abort.store(true, .release);
}

pub fn clearAbort() void {
    g_abort.store(false, .release);
}

/// Global abort check (for helper sessions that aren't a *Session, e.g.
/// compaction summarization).
pub fn isAbortedGlobal() bool {
    return g_abort.load(.acquire);
}

/// Output channel kinds for session output. `turn_event` carries no text: it
/// tells the callback that `Session.takeTurnEvents` has something new.
pub const OutputKind = enum { text, thinking, tool_info, turn_event };

pub const OutputContext = struct {
    fn_ptr: *const fn (ctx: *anyopaque, kind: OutputKind, text: []const u8) void,
    user_data: *anyopaque,
};

/// One step of a turn, in the order it happened (pi: the agent's message and
/// tool execution events). The loop records these for an interactive front
/// end, which takes them with `Session.takeTurnEvents` to build the transcript.
/// Every payload string is owned by the event.
pub const TurnEvent = union(enum) {
    /// Reasoning of a finished assistant message.
    thinking: []u8,
    /// Text of a finished assistant message.
    text: []u8,
    /// A tool call is about to run.
    tool_start: ToolStart,
    /// A tool call finished.
    tool_result: ToolEnd,
    /// A status line from the loop, such as an auto-compaction.
    note: []u8,
    /// A compaction was recorded; the context had this many tokens before it.
    compaction: u64,

    pub const ToolStart = struct {
        id: []u8,
        name: []u8,
        /// Raw JSON arguments.
        arguments: []u8,
    };

    pub const ToolEnd = struct {
        /// The `id` of the matching `tool_start`.
        id: []u8,
        content: []u8,
        is_error: bool,
        duration_ms: u64,
    };

    pub fn deinit(self: TurnEvent, alloc: std.mem.Allocator) void {
        switch (self) {
            .thinking, .text, .note => |s| alloc.free(s),
            .tool_start => |s| {
                alloc.free(s.id);
                alloc.free(s.name);
                alloc.free(s.arguments);
            },
            .tool_result => |r| {
                alloc.free(r.id);
                alloc.free(r.content);
            },
            .compaction => {},
        }
    }
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    model: *const config.Config.Model,
    registry: *tools.Registry,
    provider: *ai.OpenAiProvider,
    context: msg.Context,
    exec_ctx: tools.ExecutionContext,
    max_tool_rounds: usize = 50,
    compaction: compact.Settings = compact.DEFAULT_SETTINGS,
    /// Optional callback for streamed output. If set (TUI mode), all output
    /// kinds go to the callback; otherwise text goes to stdout and everything
    /// else to stderr (print mode).
    output_cb: ?*OutputContext = null,
    /// Cumulative usage over the whole session (A1).
    totals: msg.Usage = .{},
    /// Session persistence (B); null = --no-session.
    store: ?*ss.Store = null,
    /// Current thinking/reasoning effort (drives the border color + the
    /// reasoning parameter sent to the provider). Changeable via /think.
    thinking_level: config.ThinkingLevel = .off,
    /// Record `TurnEvent`s. Set by an interactive front end; off in print
    /// mode, where nothing would take them.
    record_turn_events: bool = false,
    turn_events: std.ArrayListUnmanaged(TurnEvent) = .empty,

    // Streaming state (shared with provider event handler)
    stream_text: *std.array_list.Managed(u8) = undefined,
    stream_thinking: *std.array_list.Managed(u8) = undefined,
    stream_tools: *std.array_list.Managed(msg.ToolCall) = undefined,
    stream_usage: ?msg.Usage = null,

    /// Stable storage for the system message blocks (a pointer to a temporary
    /// would dangle once buildWireMessages returns).
    system_blocks: [1]msg.ContentBlock = undefined,

    /// Messages submitted while a turn is running (pi: steeringQueue —
    /// injected into the context before the next LLM request, steering the
    /// current run). The TUI watcher thread pushes; the agent thread drains
    /// between tool-call rounds.
    /// CLI @file image attachments for the next user message (not owned).
    pending_images: ?[]const msg.ImageBlock = null,
    steering_queue: std.ArrayListUnmanaged([]u8) = .empty,
    queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Messages queued to start a NEW turn after the current one ends
    /// (pi: followUpQueue, alt+enter).
    followup_queue: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        model: *const config.Config.Model,
        registry: *tools.Registry,
        provider: *ai.OpenAiProvider,
        system_prompt: []const u8,
    ) !Session {
        const cwd: []const u8 = ".";
        var s = Session{
            .alloc = alloc,
            .io = io,
            .model = model,
            .registry = registry,
            .provider = provider,
            .context = try msg.Context.init(alloc, system_prompt),
            .exec_ctx = .{ .alloc = alloc, .io = io, .cwd = cwd, .abort_check = isAbortedGlobal },
            .thinking_level = model.thinking_level,
        };
        s.system_blocks = .{.{ .text = s.context.system_prompt }};
        return s;
    }

    pub fn deinit(self: *Session) void {
        self.clearTurnEvents();
        self.turn_events.deinit(self.alloc);
        self.context.deinit();
        for (self.steering_queue.items) |t| self.alloc.free(t);
        self.steering_queue.deinit(self.alloc);
        for (self.followup_queue.items) |t| self.alloc.free(t);
        self.followup_queue.deinit(self.alloc);
        // cwd is a static string, no need to free
    }

    /// Queue `text` to steer the running turn (watcher thread; copies).
    pub fn queueSteering(self: *Session, text: []const u8) void {
        const copy = self.alloc.dupe(u8, text) catch return;
        self.queue_mutex.lock(self.io) catch {
            self.alloc.free(copy);
            return;
        };
        defer self.queue_mutex.unlock(self.io);
        self.steering_queue.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return;
        };
    }

    /// Queue `text` to run as a new turn after the current one (watcher thread).
    pub fn queueFollowUp(self: *Session, text: []const u8) void {
        const copy = self.alloc.dupe(u8, text) catch return;
        self.queue_mutex.lock(self.io) catch {
            self.alloc.free(copy);
            return;
        };
        defer self.queue_mutex.unlock(self.io);
        self.followup_queue.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return;
        };
    }

    /// Number of queued follow-up messages (steering drains invisibly).
    pub fn followUpCount(self: *Session) usize {
        self.queue_mutex.lock(self.io) catch return 0;
        defer self.queue_mutex.unlock(self.io);
        return self.followup_queue.items.len;
    }

    /// Take all steering messages (agent thread; owns the returned texts).
    fn drainSteering(self: *Session) ![][]u8 {
        self.queue_mutex.lock(self.io) catch return error.LockFailed;
        defer self.queue_mutex.unlock(self.io);
        return self.steering_queue.toOwnedSlice(self.alloc);
    }

    /// Take the oldest follow-up message, or null. Public: the TUI's
    /// alt+up "restore queued messages" pulls it back into the editor.
    pub fn drainFollowUp(self: *Session) ?[]u8 {
        self.queue_mutex.lock(self.io) catch return null;
        defer self.queue_mutex.unlock(self.io);
        if (self.followup_queue.items.len == 0) return null;
        return self.followup_queue.orderedRemove(0);
    }

    /// Append queued steering messages to the context as user messages
    /// (pi: the steering drain before each LLM request). Called on the agent
    /// thread between tool-call rounds. The TUI already rendered them when
    /// they were queued — no turn events here.
    fn drainSteeringIntoContext(self: *Session) !void {
        const texts = try self.drainSteering();
        defer {
            for (texts) |t| self.alloc.free(t);
            self.alloc.free(texts);
        }
        for (texts) |t| {
            var user_msg = msg.Message.init(self.alloc);
            defer user_msg.deinit();
            user_msg.role = .user;
            user_msg.timestamp_ms = ss.nowMs(self.io);
            try user_msg.blocks.append(.{ .text = try self.alloc.dupe(u8, t) });
            try self.appendAndRecord(&user_msg);
        }
    }

    /// Hand the recorded turn events to the caller, oldest first. The caller
    /// owns the slice and every event in it: `deinit` each event, then free
    /// the slice, both with the session allocator.
    pub fn takeTurnEvents(self: *Session) []TurnEvent {
        return self.turn_events.toOwnedSlice(self.alloc) catch {
            // Out of memory: drop the events instead of handing out a part.
            self.clearTurnEvents();
            return &.{};
        };
    }

    fn clearTurnEvents(self: *Session) void {
        for (self.turn_events.items) |ev| ev.deinit(self.alloc);
        self.turn_events.clearRetainingCapacity();
    }

    /// Append `ev` (taking ownership) and tell the front end.
    fn pushTurnEvent(self: *Session, ev: TurnEvent) void {
        self.turn_events.append(self.alloc, ev) catch {
            ev.deinit(self.alloc);
            return;
        };
        self.emit(.turn_event, "");
    }

    /// Record a text-like turn event with a copy of `s`. Empty text is skipped.
    fn recordText(self: *Session, kind: enum { thinking, text, note }, s: []const u8) void {
        if (!self.record_turn_events or s.len == 0) return;
        const copy = self.alloc.dupe(u8, s) catch return;
        self.pushTurnEvent(switch (kind) {
            .thinking => .{ .thinking = copy },
            .text => .{ .text = copy },
            .note => .{ .note = copy },
        });
    }

    fn recordToolStart(self: *Session, tc: msg.ToolCall) void {
        if (!self.record_turn_events) return;
        const id = self.alloc.dupe(u8, tc.id) catch return;
        const name = self.alloc.dupe(u8, tc.name) catch {
            self.alloc.free(id);
            return;
        };
        const arguments = self.alloc.dupe(u8, tc.arguments) catch {
            self.alloc.free(id);
            self.alloc.free(name);
            return;
        };
        self.pushTurnEvent(.{ .tool_start = .{ .id = id, .name = name, .arguments = arguments } });
    }

    fn recordToolResult(self: *Session, id: []const u8, content: []const u8, is_error: bool, duration_ms: u64) void {
        if (!self.record_turn_events) return;
        const id_copy = self.alloc.dupe(u8, id) catch return;
        const content_copy = self.alloc.dupe(u8, content) catch {
            self.alloc.free(id_copy);
            return;
        };
        self.pushTurnEvent(.{ .tool_result = .{
            .id = id_copy,
            .content = content_copy,
            .is_error = is_error,
            .duration_ms = duration_ms,
        } });
    }

    pub fn isAborted(self: *Session) bool {
        _ = self;
        return g_abort.load(.acquire);
    }

    /// Route session output by kind and mode.
    fn emit(self: *Session, kind: OutputKind, text: []const u8) void {
        if (self.output_cb) |oc| {
            oc.fn_ptr(oc.user_data, kind, text);
            return;
        }
        switch (kind) {
            .text => {
                const stdout = std.Io.File.stdout();
                stdout.writeStreamingAll(self.io, text) catch {};
            },
            else => {
                std.debug.print("{s}", .{text});
            },
        }
    }

    /// Rough context size estimate (chars/4 heuristic, pi-quality is not
    /// required for the watermark display).
    pub fn contextTokens(self: *Session) usize {
        var total: usize = self.context.system_prompt.len / 4;
        for (self.context.messages.items) |m| {
            for (m.blocks.items) |b| {
                switch (b) {
                    .text => |t| total += t.len / 4,
                    .thinking => |t| total += t.len / 4,
                    .tool_call => |tc| total += (tc.name.len + tc.arguments.len) / 4,
                    .tool_result => |tr| total += tr.content.len / 4,
                    .image => |img| total += @min(img.data.len / 4, 2000),
                }
            }
        }
        return total;
    }

    /// Context usage as a fraction of the model window (0.0 - 1.0+).
    pub fn contextPressure(self: *Session) f64 {
        if (self.model.context_window == 0) return 0;
        return @as(f64, @floatFromInt(self.contextTokens())) /
            @as(f64, @floatFromInt(self.model.context_window));
    }

    /// Append to context and record to the session file.
    fn appendAndRecord(self: *Session, m: *msg.Message) !void {
        if (m.timestamp_ms == 0) m.timestamp_ms = ss.nowMs(self.io);
        if (self.store) |st| st.recordMessage(m);
        try self.context.append(m.*);
    }

    /// Swap in a (new or reopened) session store: clear the live context and
    /// replay the store's active branch. The previous store, if any, is
    /// deinit'd by the caller (ownership stays with the caller).
    pub fn adoptStore(self: *Session, st: *ss.Store) !void {
        for (self.context.messages.items) |*m| m.deinit();
        self.context.messages.clearRetainingCapacity();
        self.store = st;
        const branch = st.branchMessages(self.alloc) catch return;
        defer {
            for (branch) |m| m.deinit();
            self.alloc.free(branch);
        }
        for (branch) |m| try self.context.append(m);
    }

    /// Rebuild the live context from the current store's active branch
    /// (compaction-aware). Used after a compaction entry is recorded.
    fn rebuildContextFromStore(self: *Session) !void {
        const st = self.store orelse return;
        for (self.context.messages.items) |*m| m.deinit();
        self.context.messages.clearRetainingCapacity();
        const branch = try st.branchMessages(self.alloc);
        defer {
            for (branch) |m| m.deinit();
            self.alloc.free(branch);
        }
        for (branch) |m| try self.context.append(m);
    }

    /// Find the context index where retained messages begin (pi: findCutPoint).
    /// Walks backward from newest accumulating chars/4 estimates until
    /// keep_recent_tokens is reached, then snaps to the closest valid cut point
    /// (a user/assistant message, never a bare tool result).
    fn findCutIndex(self: *Session) usize {
        const msgs = self.context.messages.items;
        const L: usize = msgs.len;
        var cut_points = std.array_list.Managed(usize).init(self.alloc);
        defer cut_points.deinit();
        for (msgs, 0..) |m, i| {
            if (m.role == .user or m.role == .assistant) {
                cut_points.append(i) catch {};
            }
        }
        if (cut_points.items.len == 0) return 0;
        var accumulated: u64 = 0;
        var cut: usize = cut_points.items[0];
        var i: usize = L;
        while (i > 0) {
            i -= 1;
            const tok = compact.estimateTokens(&msgs[i]);
            if (tok == 0) continue;
            accumulated += tok;
            if (accumulated >= self.compaction.keep_recent_tokens) {
                var found = false;
                for (cut_points.items) |cp| {
                    if (cp >= i) {
                        cut = cp;
                        found = true;
                        break;
                    }
                }
                if (!found) cut = cut_points.items[cut_points.items.len - 1];
                break;
            }
        }
        return cut;
    }

    /// Run (or force) a compaction. Returns the context size before it, or
    /// null when nothing was compacted. `custom` optionally focuses the summary.
    pub fn runCompaction(self: *Session, custom: ?[]const u8) !?u64 {
        const st = self.store orelse return null;
        const msgs = self.context.messages.items;
        const L: usize = msgs.len;
        if (L < 2) return null;

        const cut = self.findCutIndex();
        if (cut == 0) return null; // nothing to summarize

        // Map the first kept context message to its store entry id.
        const all_ids = try st.branchMessageIds(self.alloc);
        defer self.alloc.free(all_ids);
        const M: usize = all_ids.len;
        if (M < L or cut > L - 1) return null;
        const offset = M - L;
        const first_kept_id = all_ids[offset + cut];

        // File tracking across the whole conversation.
        var ops = compact.FileOps.init(self.alloc) catch return null;
        defer ops.deinit();
        for (msgs) |m| compact.extractFileOpsFromMessage(&m, &ops);
        const lists = compact.computeFileLists(self.alloc, &ops) catch return null;
        defer {
            self.alloc.free(lists.read);
            self.alloc.free(lists.modified);
        }

        const tokens_before = compact.estimateContextTokens(msgs);

        // Summarize the prefix that will be dropped.
        const summary = compact.generateSummary(
            self.alloc,
            self.io,
            self.provider,
            self.model.id,
            msgs[0..cut],
            null,
            custom,
            isAbortedGlobal,
        ) catch |e| {
            if (e == error.Aborted) return null;
            return e;
        };
        defer self.alloc.free(summary.text);

        var full = std.array_list.Managed(u8).init(self.alloc);
        defer full.deinit();
        try full.appendSlice(summary.text);
        try compact.formatFileOperations(&full, lists.read, lists.modified);
        const summary_owned = try full.toOwnedSlice();
        defer self.alloc.free(summary_owned);

        st.recordCompaction(summary_owned, first_kept_id, tokens_before, lists, summary.usage);
        try self.rebuildContextFromStore();
        if (self.record_turn_events) self.pushTurnEvent(.{ .compaction = @intCast(tokens_before) });
        return @intCast(tokens_before);
    }

    /// Auto-compact at a turn boundary if the context exceeds the budget.
    fn maybeAutoCompact(self: *Session) !void {
        const ctx_tokens = compact.estimateContextTokens(self.context.messages.items);
        if (!compact.shouldCompact(ctx_tokens, self.model.context_window, &self.compaction)) return;
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\n[auto-compact: context ~{d} tokens]\n", .{ctx_tokens}) catch "\n[auto-compact]\n";
        self.emit(.tool_info, s);
        // The compaction itself is shown by its own turn event.
        _ = try self.runCompaction(null);
    }

    /// Run a user prompt through the agent loop.
    /// Run a user prompt with image attachments (CLI @file images).
    /// images are owned by the caller; blocks copy them into the message.
    pub fn runPromptWithImages(self: *Session, prompt: []const u8, images: []const msg.ImageBlock) !void {
        // Stash images for the user-message construction inside runPrompt.
        self.pending_images = images;
        defer self.pending_images = null;
        return self.runPrompt(prompt);
    }

    pub fn runPrompt(self: *Session, prompt: []const u8) !void {
        clearAbort();
        // Events nobody took belong to an earlier turn.
        self.clearTurnEvents();

        // pi: after a turn ends, queued follow-up messages run as new turns
        // (the outer loop below). Steering messages are injected BEFORE each
        // LLM request (drainSteeringIntoContext, between tool-call rounds).
        var current_prompt: []u8 = self.alloc.dupe(u8, prompt) catch return error.OutOfMemory;
        defer self.alloc.free(current_prompt);
        var follow_up = true;
        while (follow_up) {
            follow_up = false;

        // Add user message (context.append deep-copies; we own user_msg)
        var user_msg = msg.Message.init(self.alloc);
        defer user_msg.deinit();
        user_msg.role = .user;
        const prompt_copy = self.alloc.dupe(u8, current_prompt) catch return error.OutOfMemory;
        try user_msg.blocks.append(.{ .text = prompt_copy });
        if (self.pending_images) |imgs| {
            for (imgs) |img| {
                try user_msg.blocks.append(.{ .image = .{
                    .data = self.alloc.dupe(u8, img.data) catch break,
                    .mime = self.alloc.dupe(u8, img.mime) catch break,
                } });
            }
        }
        try self.appendAndRecord(&user_msg);

        var rounds: usize = 0;
        // One overflow-recovery attempt per run (pi _overflowRecoveryAttempted).
        var overflow_recovered = false;
        while (rounds < self.max_tool_rounds) : (rounds += 1) {
            // Auto-compact before building the request if context is large.
            try self.maybeAutoCompact();

            // pi: queued steering messages join the context before the next
            // LLM request, so the user can redirect the run mid-flight.
            try self.drainSteeringIntoContext();

            // Build wire messages
            var wire_msgs = std.array_list.Managed(ai.OpenAiProvider.ChatMessage).init(self.alloc);
            defer wire_msgs.deinit();
            try self.buildWireMessages(&wire_msgs);

            // Build tools
            const tools_json = try self.registry.toolSchemasJson(self.alloc);
            defer self.alloc.free(tools_json);

            // Streaming buffers
            var text_buf = std.array_list.Managed(u8).init(self.alloc);
            var thinking_buf = std.array_list.Managed(u8).init(self.alloc);
            var tool_calls = std.array_list.Managed(msg.ToolCall).init(self.alloc);
            self.stream_text = &text_buf;
            self.stream_thinking = &thinking_buf;
            self.stream_tools = &tool_calls;
            self.stream_usage = null;

            // Call LLM (retries + abort-aware, see openai.zig)
            self.provider.streamChat(
                self.model.id,
                wire_msgs.items,
                tools_json,
                self.model.supports_images,
                self.thinking_level,
                .{
                    .format = self.model.thinking_format,
                    .map = &self.model.thinking_level_map,
                    .reasoning = self.model.reasoning,
                    .supports_effort = self.model.supports_reasoning_effort,
                },
                self,
            ) catch |e| {
                if (e == error.Aborted) {
                    self.finalizeAbortedRound(&text_buf, &thinking_buf, &tool_calls);
                } else if (!overflow_recovered and compact.isOverflowError(self.provider.lastErrorText())) {
                    // Context overflow recovery (pi _checkCompaction →
                    // _runAutoCompaction("overflow", willRetry=true)): the
                    // failed request produced no assistant message (pi omits
                    // it), so compact and retry the same round exactly once.
                    overflow_recovered = true;
                    text_buf.deinit();
                    thinking_buf.deinit();
                    tool_calls.deinit();
                    self.emit(.tool_info, "\n[auto-compact: context overflow — compacting and retrying]\n");
                    _ = self.runCompaction(null) catch {};
                    continue; // rebuild wire messages against the compacted context
                } else {
                    // Keep what streamed before the failure on screen.
                    self.recordText(.thinking, thinking_buf.items);
                    self.recordText(.text, text_buf.items);
                }
                text_buf.deinit();
                thinking_buf.deinit();
                tool_calls.deinit();
                if (e == error.Aborted) return;
                return e;
            };

            // Build assistant message: thinking → text → tool_calls
            var assistant_msg = msg.Message.init(self.alloc);
            defer assistant_msg.deinit();
            assistant_msg.role = .assistant;
            assistant_msg.timestamp_ms = ss.nowMs(self.io);
            assistant_msg.provider = self.alloc.dupe(u8, self.model.provider) catch null;
            assistant_msg.model_id = self.alloc.dupe(u8, self.model.id) catch null;
            if (self.stream_usage) |u| {
                assistant_msg.usage = u;
                self.totals.add(u);
            }
            self.recordText(.thinking, thinking_buf.items);
            self.recordText(.text, text_buf.items);
            if (thinking_buf.items.len > 0) {
                try assistant_msg.blocks.append(.{ .thinking = try thinking_buf.toOwnedSlice() });
            }
            if (text_buf.items.len > 0) {
                try assistant_msg.blocks.append(.{ .text = try text_buf.toOwnedSlice() });
            }
            for (tool_calls.items) |tc| {
                try assistant_msg.blocks.append(.{ .tool_call = tc });
            }
            text_buf.deinit();
            thinking_buf.deinit();
            tool_calls.deinit();

            const aborted = self.isAborted();
            if (assistant_msg.blocks.items.len == 0) break;
            const sr: []const u8 = if (n_tool_calls_pending(&assistant_msg) > 0) "toolUse" else "stop";
            assistant_msg.stop_reason = msg.Message.allocStr(self.alloc, sr);
            try self.appendAndRecord(&assistant_msg);

            // Count tool calls
            const n_tool_calls: usize = n_tool_calls_pending(&assistant_msg);

            if (n_tool_calls == 0) {
                // Turn complete. A queued follow-up message starts a new turn
                // (pi: the outer loop continues with followUpQueue contents).
                if (self.drainFollowUp()) |fu| {
                    self.alloc.free(current_prompt);
                    current_prompt = fu;
                    follow_up = true;
                    rounds = 0;
                }
                break;
            }

            if (aborted) {
                // Keep the conversation wire-valid: every tool call needs a
                // result, unexecuted calls get an "aborted" marker.
                self.appendAbortedToolResults(&assistant_msg);
                break;
            }

            // Announce tool calls in order
            var call_idx: usize = 0;
            for (assistant_msg.blocks.items) |b| {
                switch (b) {
                    .tool_call => |tc| {
                        var buf: [512]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "\n[tool {d}/{d}: {s}] {s}\n", .{ call_idx + 1, n_tool_calls, tc.name, tc.arguments }) catch "";
                        self.emit(.tool_info, s);
                        self.recordToolStart(tc);
                        call_idx += 1;
                    },
                    else => {},
                }
            }

            // Execute tools (parallel when several, results re-ordered by call id)
            const results = try self.alloc.alloc(tools.ToolResult, n_tool_calls);
            defer self.alloc.free(results);
            try self.executeToolsParallel(&assistant_msg, results);

            // Record results in tool-call order
            var res_idx: usize = 0;
            for (assistant_msg.blocks.items) |b| {
                switch (b) {
                    .tool_call => |tc| {
                        const result = results[res_idx];
                        res_idx += 1;
                        self.emit(.tool_info, result.content);
                        self.emit(.tool_info, "\n");
                        // Before the content moves into the message below.
                        self.recordToolResult(tc.id, result.content, result.is_error, result.duration_ms);

                        var tr_msg = msg.Message.init(self.alloc);
                        defer tr_msg.deinit();
                        tr_msg.role = .tool;
                        tr_msg.timestamp_ms = ss.nowMs(self.io);
                        const tc_id_copy = self.alloc.dupe(u8, tc.id) catch return error.OutOfMemory;
                        const tn_copy = self.alloc.dupe(u8, tc.name) catch null;
                        // ToolResult.content ownership moves into the message;
                        // freed by Message.deinit. (Static "" from OOM fallback
                        // is a safe no-op free.)
                        try tr_msg.blocks.append(.{ .tool_result = .{
                            .tool_call_id = tc_id_copy,
                            .content = result.content,
                            .is_error = result.is_error,
                            .tool_name = tn_copy,
                        } });
                        // Image block (from the read tool). Ownership of
                        // image_data/image_mime moves into the message block.
                        if (result.image_data) |img_data| {
                            if (result.image_mime) |img_mime| {
                                try tr_msg.blocks.append(.{ .image = .{
                                    .data = img_data,
                                    .mime = img_mime,
                                } });
                            } else {
                                self.alloc.free(img_data);
                            }
                        }
                        try self.appendAndRecord(&tr_msg);
                    },
                    else => {},
                }
            }

            if (self.isAborted()) break;
        }
        }
    }

    fn countToolCalls(m: *const msg.Message) usize {
        var n: usize = 0;
        for (m.blocks.items) |b| {
            switch (b) {
                .tool_call => n += 1,
                else => {},
            }
        }
        return n;
    }

    fn n_tool_calls_pending(m: *const msg.Message) usize {
        return countToolCalls(m);
    }

    /// Persist whatever was streamed before an abort so nothing is lost.
    fn finalizeAbortedRound(
        self: *Session,
        text_buf: *std.array_list.Managed(u8),
        thinking_buf: *std.array_list.Managed(u8),
        tool_calls: *std.array_list.Managed(msg.ToolCall),
    ) void {
        var assistant_msg = msg.Message.init(self.alloc);
        defer assistant_msg.deinit();
        assistant_msg.role = .assistant;
        assistant_msg.timestamp_ms = ss.nowMs(self.io);
        assistant_msg.stop_reason = msg.Message.allocStr(self.alloc, "aborted");
        if (self.stream_usage) |u| {
            assistant_msg.usage = u;
            self.totals.add(u);
        }
        self.recordText(.thinking, thinking_buf.items);
        self.recordText(.text, text_buf.items);
        if (thinking_buf.items.len > 0) {
            const t = thinking_buf.toOwnedSlice() catch return;
            assistant_msg.blocks.append(.{ .thinking = t }) catch return;
        }
        if (text_buf.items.len > 0) {
            const t = text_buf.toOwnedSlice() catch return;
            assistant_msg.blocks.append(.{ .text = t }) catch return;
        }
        for (tool_calls.items) |tc| {
            assistant_msg.blocks.append(.{ .tool_call = tc }) catch return;
        }
        if (assistant_msg.blocks.items.len > 0) {
            self.appendAndRecord(&assistant_msg) catch return;
            self.appendAbortedToolResults(&assistant_msg);
        }
        self.emit(.tool_info, "\n[interrupted]\n");
    }

    /// Record a user-initiated `!cmd` execution (pi recordBashResult):
    /// role=.bash_execution message with command/output/exit metadata.
    /// The text block carries the raw output; wire conversion renders it.
    pub fn appendBashExecution(self: *Session, command: []const u8, output: []const u8, exit_code: ?i32, exclude: bool) void {
        var bm = msg.Message.init(self.alloc);
        defer bm.deinit();
        bm.role = .bash_execution;
        bm.timestamp_ms = ss.nowMs(self.io);
        bm.bash_command = self.alloc.dupe(u8, command) catch return;
        bm.bash_exclude = exclude;
        bm.bash_exit_code = exit_code;
        if (output.len > 0) {
            const copy = self.alloc.dupe(u8, output) catch return;
            bm.blocks.append(.{ .text = copy }) catch return;
        }
        self.appendAndRecord(&bm) catch return;
    }

    /// Append is_error tool results for every tool call of the message.
    fn appendAbortedToolResults(self: *Session, assistant_msg: *msg.Message) void {
        for (assistant_msg.blocks.items) |b| {
            switch (b) {
                .tool_call => |tc| {
                    // These calls were never announced: show them as failed.
                    self.recordToolStart(tc);
                    self.recordToolResult(tc.id, "aborted by user", true, 0);

                    var tr_msg = msg.Message.init(self.alloc);
                    defer tr_msg.deinit();
                    tr_msg.role = .tool;
                    tr_msg.timestamp_ms = ss.nowMs(self.io);
                    const tc_id_copy = self.alloc.dupe(u8, tc.id) catch continue;
                    const content_copy = self.alloc.dupe(u8, "aborted by user") catch continue;
                    const tn_copy = self.alloc.dupe(u8, tc.name) catch null;
                    tr_msg.blocks.append(.{ .tool_result = .{
                        .tool_call_id = tc_id_copy,
                        .content = content_copy,
                        .is_error = true,
                        .tool_name = tn_copy,
                    } }) catch continue;
                    self.appendAndRecord(&tr_msg) catch continue;
                },
                else => {},
            }
        }
    }

    /// Execute all tool calls of the message. Multiple calls run in parallel
    /// threads; results are stored by call index. Single calls stay inline.
    fn executeToolsParallel(
        self: *Session,
        assistant_msg: *msg.Message,
        results: []tools.ToolResult,
    ) !void {
        var idx: usize = 0;
        var threads = std.array_list.Managed(struct { t: ?std.Thread, i: usize, tc: msg.ToolCall }).init(self.alloc);
        defer threads.deinit();

        for (assistant_msg.blocks.items) |b| {
            switch (b) {
                .tool_call => |tc| {
                    if (idx == 0) {
                        // First call inline: warms nothing, keeps the common
                        // single-tool path thread-free.
                        results[0] = self.execToolTimed(tc.name, tc.arguments);
                    } else {
                        const t = std.Thread.spawn(.{}, toolThreadMain, .{ self, tc, &results[idx] }) catch {
                            results[idx] = self.execToolTimed(tc.name, tc.arguments);
                            try threads.append(.{ .t = null, .i = idx, .tc = tc });
                            idx += 1;
                            continue;
                        };
                        try threads.append(.{ .t = t, .i = idx, .tc = tc });
                    }
                    idx += 1;
                },
                else => {},
            }
        }
        for (threads.items) |entry| {
            if (entry.t) |t| t.join();
        }
    }

    fn toolThreadMain(self: *Session, tc: msg.ToolCall, out: *tools.ToolResult) void {
        out.* = self.execToolTimed(tc.name, tc.arguments);
    }

    /// execTool with the wall time filled in.
    fn execToolTimed(self: *Session, name: []const u8, args_json: []const u8) tools.ToolResult {
        const start = ss.nowMs(self.io);
        var result = self.execTool(name, args_json);
        const elapsed = ss.nowMs(self.io) - start;
        result.duration_ms = if (elapsed > 0) @intCast(elapsed) else 0;
        return result;
    }

    fn buildWireMessages(self: *Session, out: *std.array_list.Managed(ai.OpenAiProvider.ChatMessage)) !void {
        try out.append(.{ .role = .system, .blocks = &self.system_blocks });
        for (self.context.messages.items) |*m| {
            if (m.role == .bash_execution) {
                // pi convertToLlm: `!!` executions stay out of the context;
                // others become user text (bashExecutionToText format).
                if (m.bash_exclude) continue;
                const text = msg.bashExecutionToText(self.alloc, m.bash_command orelse "", if (m.blocks.items.len > 0) blk: {
                    for (m.blocks.items) |b| switch (b) {
                        .text => |t| break :blk t,
                        else => {},
                    };
                    break :blk "";
                } else "", m.bash_exit_code, false, null) catch continue;
                // The wire messages live until the request completes, longer
                // than this loop iteration — intentionally not freed here.
                var blocks = std.array_list.Managed(msg.ContentBlock).init(self.alloc);
                blocks.append(.{ .text = text }) catch continue;
                try out.append(.{ .role = .user, .blocks = blocks.toOwnedSlice() catch continue });
                continue;
            }
            try out.append(.{ .role = m.role, .blocks = m.blocks.items });
        }
    }

    fn execTool(self: *Session, name: []const u8, args_json: []const u8) tools.ToolResult {
        const tool = self.registry.find(name) orelse
            return .{ .content = std.fmt.allocPrint(self.alloc, "unknown tool: {s}", .{name}) catch "", .is_error = true };
        return tool.execute(args_json, &self.exec_ctx);
    }

    pub fn onStreamEvent(self: *Session, event: ai.StreamEvent) void {
        switch (event) {
            .text_delta => |text| {
                self.stream_text.appendSlice(text) catch return;
                self.emit(.text, text);
            },
            .thinking_delta => |text| {
                self.stream_thinking.appendSlice(text) catch return;
                self.emit(.thinking, text);
            },
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
            .usage => |u| {
                var usage_val = u;
                usage_val.computeCost(
                    self.model.cost_input,
                    self.model.cost_output,
                    self.model.cost_cache_read,
                    self.model.cost_cache_write,
                );
                self.stream_usage = usage_val;
            },
            .done => {},
        }
    }
};
