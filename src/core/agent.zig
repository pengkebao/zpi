//! Agent session: the core loop (prompt → LLM → tools → LLM → ...).

const std = @import("std");
const builtin = @import("builtin");
const msg = @import("message.zig");
const ai = @import("../ai/openai.zig");
const aiprovider = @import("../ai/provider.zig");
const events = @import("events.zig");
const tools = @import("../tools/registry.zig");
const config = @import("config.zig");
const ss = @import("session_store.zig");
const compact = @import("compaction.zig");
const wmod = @import("../ui/width.zig");

/// Global abort flag, set by the SIGINT handler (signal handlers cannot
/// reach session state). Checked between stream chunks and around tool calls.
var g_abort = std.atomic.Value(bool).init(false);

pub fn requestAbort() void {
    g_abort.store(true, .release);
}

pub fn clearAbort() void {
    g_abort.store(false, .release);
}

/// Verbose diagnostics to stderr (pi --verbose): retry details, transport
/// diagnostics. Off by default.
pub var verbose = false;

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
    /// A compaction was recorded (tokens before it + the summarization
    /// request's usage) — the "✂ Context compacted" transcript line.
    compaction: ss.CompactionInfo,
    /// A streaming tool call grew its arguments (pi: the tool block renders
    /// while the model is still writing it — write's path appears first,
    /// then the content preview grows line by line with the "N more lines"
    /// counter). Replaces the pending entry with the same id.
    tool_args: ToolStart,
    /// A running tool produced output (pi: tool_execution_update with
    /// partialResult — the card shows streaming output while the command
    /// runs). `output` is the FULL output so far, not a delta.
    tool_update: ToolUpdate,

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

    pub const ToolUpdate = struct {
        /// The `id` of the matching `tool_start`.
        id: []u8,
        /// Full output so far (owned).
        output: []u8,
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
            .tool_args => |s| {
                alloc.free(s.id);
                alloc.free(s.name);
                alloc.free(s.arguments);
            },
            .tool_update => |u| {
                alloc.free(u.id);
                alloc.free(u.output);
            },
        }
    }
};

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    model: *const config.Config.Model,
    registry: *tools.Registry,
    provider: aiprovider.AnyProvider,
    context: msg.Context,
    exec_ctx: tools.ExecutionContext,
    /// Live output of the running tool (bash streaming, pi: partialResult).
    /// One per parallel call; owned slices, freed on reset. Throttled
    /// tool_update events are pushed from the shell reader threads.
    live_tool_outputs: [4]?std.array_list.Managed(u8) = .{ null, null, null, null },
    live_tool_last_ms: [4]i64 = .{ 0, 0, 0, 0 },
    /// Tool call id per slot (borrowed from the round's assistant message,
    /// valid while the tool runs; reader threads read it).
    live_tool_ids: [4]?[]const u8 = .{ null, null, null, null },
    /// Guards the live_tool_outputs buffers (reader threads vs teardown).
    live_tool_mutex: std.Io.Mutex = std.Io.Mutex.init,
    compaction: compact.Settings = compact.DEFAULT_SETTINGS,
    /// Optional callback for streamed output. If set (TUI mode), all output
    /// kinds go to the callback; otherwise text goes to stdout and everything
    /// else to stderr (print mode).
    output_cb: ?*OutputContext = null,
    /// Print mode (pi -p): suppress streamed output entirely (stdout gets
    /// the final assistant text once the round completes — pi print-mode).
    quiet: bool = false,
    /// Monotonic turn index for --mode json turn_start events.
    turn_counter: u64 = 0,
    /// Last round failure text (print mode reports it on stderr + exit 1,
    /// pi print-mode errorMessage semantics).
    last_error_message: ?[]u8 = null,
    /// --mode json: when set, structured session events are written here
    /// as one JSON object per line (pi json-event protocol shape).
    json_out: ?std.Io.File = null,
    /// Cumulative usage over the whole session (A1).
    totals: msg.Usage = .{},
    /// pi getContextUsage: after a compaction the last assistant usage
    /// reflects the PRE-compaction context, so the context token count is
    /// unknown (footer shows `?/window`) until the next assistant response
    /// with usage arrives.
    context_unknown: bool = false,
    /// Session persistence (B); null = --no-session.
    store: ?*ss.Store = null,
    /// Current thinking/reasoning effort (drives the border color + the
    /// reasoning parameter sent to the provider). Changeable via /think.
    thinking_level: config.ThinkingLevel = .off,
    /// Record `TurnEvent`s. Set by an interactive front end; off in print
    /// mode, where nothing would take them.
    record_turn_events: bool = false,
    turn_events: std.ArrayListUnmanaged(TurnEvent) = .empty,
    /// Guards turn_events: pushTurnEvent runs on shell reader threads
    /// (live tool output) as well as the provider/agent threads, while the
    /// front end takes the queue from its own thread.
    turn_events_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // Streaming state (shared with provider event handler)
    stream_text: *std.array_list.Managed(u8) = undefined,
    stream_thinking: *std.array_list.Managed(u8) = undefined,
    stream_tools: *std.array_list.Managed(msg.ToolCall) = undefined,
    stream_usage: ?msg.Usage = null,
    /// Finish reason of the round currently streaming (null = none yet).
    stream_finish: ?ai.FinishReason = null,
    /// pi retry budget: auto-retry a round that failed with a transient
    /// provider error (EmptyResponse / stream drop) — exponential backoff.
    retry_attempt: usize = 0,
    /// Streaming tool-call preview throttle (pi: toolCall updates repaint
    /// the block as arguments grow). A turn_event per delta would flood the
    /// queue at token cadence; push at most every `tool_args_throttle_ms`
    /// or when the args length doubled since the last push.
    tool_args_last_ms: i64 = 0,
    tool_args_last_len: usize = 0,
    /// Max auto-retries per round (pi settings.retry.maxRetries default 3).
    retry_max: usize = 3,
    /// pi isRecoverableLength: one compact-and-retry when a round is cut by
    /// `finish_reason=length` below the model's output limit (context
    /// pressure / provider-side truncation).
    length_recovered: bool = false,
    /// A pure-thinking round (no text, no tool call) already triggered one
    /// automatic "continue" nudge (P2): avoids a silent stall where the model
    /// burns its output budget on reasoning and ends without acting.
    thinking_nudged: bool = false,

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
    /// pi steeringMode: "all" (default) delivers every queued steering
    /// message before the next LLM request; "one-at-a-time" delivers one
    /// and waits for the response.
    steering_mode_all: bool = true,
    /// pi followUpMode: "all" drains follow-ups as consecutive new turns;
    /// "one-at-a-time" starts one follow-up turn per settled round.
    follow_up_mode_all: bool = true,
    queue_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Messages queued to start a NEW turn after the current one ends
    /// (pi: followUpQueue, alt+enter).
    followup_queue: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        model: *const config.Config.Model,
        registry: *tools.Registry,
        provider: aiprovider.AnyProvider,
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

    /// Replace the system prompt (pi: `/reload` section patch). Updates both the
    /// context and the stable system_blocks pointer (which borrows the context
    /// buffer). Takes ownership of `new_prompt`.
    pub fn setSystemPrompt(self: *Session, new_prompt: []const u8) !void {
        try self.context.setSystemPrompt(new_prompt);
        self.system_blocks[0].text = self.context.system_prompt;
    }

    pub fn deinit(self: *Session) void {
        self.resetLiveToolOutputs();
        self.clearTurnEvents();
        self.turn_events.deinit(self.alloc);
        self.context.deinit();
        for (self.steering_queue.items) |t| self.alloc.free(t);
        self.steering_queue.deinit(self.alloc);
        for (self.followup_queue.items) |t| self.alloc.free(t);
        self.followup_queue.deinit(self.alloc);
        // cwd is a static string, no need to free
    }

    /// pi restoreQueuedMessagesToEditor: take EVERY queued message
    /// (steering first, then follow-up) and return them joined with "\n\n".
    /// The TUI's ESC (while working) and alt+up restore the queues into the
    /// editor instead of losing them.
    pub fn restoreQueued(self: *Session) ?[]u8 {
        self.queue_mutex.lock(self.io) catch return null;
        defer self.queue_mutex.unlock(self.io);
        var texts = std.ArrayListUnmanaged([]u8).empty;
        defer texts.deinit(self.alloc);
        for (self.steering_queue.items) |t| texts.append(self.alloc, t) catch return null;
        for (self.followup_queue.items) |t| texts.append(self.alloc, t) catch return null;
        const n = texts.items.len;
        self.steering_queue.clearRetainingCapacity();
        self.followup_queue.clearRetainingCapacity();
        if (n == 0) return null;
        var joined = std.ArrayListUnmanaged(u8).empty;
        defer joined.deinit(self.alloc);
        for (texts.items, 0..) |t, i| {
            if (i > 0) joined.appendSlice(self.alloc, "\n\n") catch return null;
            joined.appendSlice(self.alloc, t) catch return null;
        }
        return joined.toOwnedSlice(self.alloc) catch null;
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

    /// One queued message with its queue kind (pi pendingMessage display).
    pub const QueuedMessage = struct {
        text: []u8,
        mode: enum { steer, followUp },
    };

    /// Peek at every queued message (steering first, then follow-up)
    /// WITHOUT draining: the TUI renders the dim "Steering: ..." /
    /// "Follow-up: ..." pending rows (pi updatePendingMessagesDisplay).
    /// Caller owns every text and the slice.
    pub fn queuedPeek(self: *Session) []QueuedMessage {
        self.queue_mutex.lock(self.io) catch return &.{};
        defer self.queue_mutex.unlock(self.io);
        var out = std.ArrayListUnmanaged(QueuedMessage).empty;
        defer out.deinit(self.alloc);
        for (self.steering_queue.items) |t| {
            out.append(self.alloc, .{ .text = self.alloc.dupe(u8, t) catch break, .mode = .steer }) catch break;
        }
        for (self.followup_queue.items) |t| {
            out.append(self.alloc, .{ .text = self.alloc.dupe(u8, t) catch break, .mode = .followUp }) catch break;
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    /// Drop every queued steering/follow-up message (pi clearQueue, RPC
    /// mode `clear_queue` command). Returns the number removed.
    pub fn clearQueue(self: *Session) usize {
        self.queue_mutex.lock(self.io) catch return 0;
        defer self.queue_mutex.unlock(self.io);
        const n = self.steering_queue.items.len + self.followup_queue.items.len;
        for (self.steering_queue.items) |t| self.alloc.free(t);
        self.steering_queue.clearRetainingCapacity();
        for (self.followup_queue.items) |t| self.alloc.free(t);
        self.followup_queue.clearRetainingCapacity();
        return n;
    }

    /// Total queued message count (steering + follow-up).
    pub fn queuedPeekLen(self: *Session) usize {
        self.queue_mutex.lock(self.io) catch return 0;
        defer self.queue_mutex.unlock(self.io);
        return self.steering_queue.items.len + self.followup_queue.items.len;
    }

    /// Number of DISPLAY rows the queued messages will occupy above the
    /// editor at `width`: each queued text is wrapped to the width, so a
    /// long (or multi-line) message takes more than one row. The TUI
    /// reserves this many layout rows; wrapping to one row would clip the
    /// message and the layout would push the bottom off-screen.
    pub fn queuedPeekRows(self: *Session, width: usize) usize {
        self.queue_mutex.lock(self.io) catch return 0;
        defer self.queue_mutex.unlock(self.io);
        const wrap = struct {
            fn count(s: []const u8, w: usize) usize {
                if (w == 0) return 1;
                var rows: usize = 0;
                var start: usize = 0;
                while (start < s.len) {
                    rows += 1;
                    var end = start;
                    var cw_sum: usize = 0;
                    var last_space: ?usize = null;
                    while (end < s.len) {
                        if (s[end] == '\n') break; // explicit newline always breaks
                        const ce = wmod.nextCharEnd(s, end);
                        const cw = wmod.visualWidth(s[end..ce]);
                        if (cw_sum + cw > w) break;
                        if (s[end] == ' ') last_space = end;
                        cw_sum += cw;
                        end = ce;
                    }
                    var brk: usize = 0;
                    if (end < s.len and s[end] == '\n') {
                        brk = end + 1; // consume the newline
                    } else if (end < s.len and last_space != null and last_space.? > start) {
                        brk = last_space.? + 1;
                    } else {
                        brk = end;
                    }
                    if (brk <= start) brk = wmod.nextCharEnd(s, start);
                    start = brk;
                }
                return if (rows == 0) 1 else rows;
            }
        }.count;
        var total: usize = 0;
        for (self.steering_queue.items) |t| {
            const w: usize = if (width > 10) width - 10 else 1; // "Steering: "
            total += wrap(t, w);
        }
        for (self.followup_queue.items) |t| {
            const w: usize = if (width > 11) width - 11 else 1; // "Follow-up: "
            total += wrap(t, w);
        }
        return total;
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

    /// All follow-up messages (mode "all") or just the oldest one
    /// (mode "one-at-a-time" — the rest stay queued).
    fn drainFollowUpAll(self: *Session) ![][]u8 {
        self.queue_mutex.lock(self.io) catch return error.LockFailed;
        defer self.queue_mutex.unlock(self.io);
        if (self.follow_up_mode_all) {
            return self.followup_queue.toOwnedSlice(self.alloc);
        }
        if (self.followup_queue.items.len == 0) return &.{};
        const one = self.followup_queue.orderedRemove(0);
        const out = try self.alloc.alloc([]u8, 1);
        out[0] = one;
        return out;
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
        // pi steeringMode "one-at-a-time": deliver the first message now and
        // put the rest back (they go out after the next response).
        var usable = texts;
        if (!self.steering_mode_all and texts.len > 1) {
            self.queue_mutex.lock(self.io) catch {};
            defer self.queue_mutex.unlock(self.io);
            var i = texts.len;
            while (i > 1) : (i -= 1) {
                self.steering_queue.insert(self.alloc, 0, texts[i - 1]) catch {};
            }
            usable = texts[0..1];
        }
        for (usable) |t| {
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
        self.turn_events_mutex.lock(self.io) catch return &.{};
        defer self.turn_events_mutex.unlock(self.io);
        return self.turn_events.toOwnedSlice(self.alloc) catch {
            // Out of memory: drop the events instead of handing out a part.
            self.clearTurnEvents();
            return &.{};
        };
    }

    fn clearTurnEvents(self: *Session) void {
        self.turn_events_mutex.lock(self.io) catch {};
        defer self.turn_events_mutex.unlock(self.io);
        for (self.turn_events.items) |ev| ev.deinit(self.alloc);
        self.turn_events.clearRetainingCapacity();
    }

    /// Append `ev` (taking ownership) and tell the front end.
    fn pushTurnEvent(self: *Session, ev: TurnEvent) void {
        self.turn_events_mutex.lock(self.io) catch {
            ev.deinit(self.alloc);
            return;
        };
        var ok = true;
        self.turn_events.append(self.alloc, ev) catch {
            ev.deinit(self.alloc);
            ok = false;
        };
        self.turn_events_mutex.unlock(self.io);
        if (!ok) return;
        // Outside the lock: emit runs the front-end callback, which takes
        // the queue again (drainTurnEvents → takeTurnEvents).
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

    /// Provider-layer retry hook: discard everything the failed attempt
    /// streamed so the retry starts from a clean slate. Without this, a
    /// mid-stream transport failure followed by a retry would APPEND the
    /// retry's deltas to the truncated attempt's output (duplicated text,
    /// misaligned tool-call argument JSON). The TUI's live preview resets
    /// with the buffers (streamHasContent goes false, the next delta
    /// repaints from zero).
    pub fn resetStream(self: *Session) void {
        self.stream_text.clearRetainingCapacity();
        self.stream_thinking.clearRetainingCapacity();
        for (self.stream_tools.items) |*tc| {
            self.alloc.free(tc.id);
            self.alloc.free(tc.name);
            self.alloc.free(tc.arguments);
        }
        self.stream_tools.clearRetainingCapacity();
        self.stream_usage = null;
        self.stream_finish = null;
        self.tool_args_last_ms = 0;
        self.tool_args_last_len = 0;
    }

    /// Free any live tool output buffers (session teardown).
    pub fn resetLiveToolOutputs(self: *Session) void {
        self.live_tool_mutex.lock(self.io) catch {};
        defer self.live_tool_mutex.unlock(self.io);
        for (&self.live_tool_outputs) |*buf| {
            if (buf.*) |b| {
                b.deinit();
                buf.* = null;
            }
        }
    }

    /// Shell reader-thread callback (pi: tool_execution_update with
    /// partialResult). Appends the chunk to this call's live buffer and,
    /// throttled to 100 ms, pushes a tool_update turn event carrying the
    /// FULL output so far — the TUI paints it into the pending card. The
    /// final result still arrives via tool_result (the card repaints from
    /// the authoritative content).
    /// Carried in the shell callback ctx: which session slot this call's
    /// reader threads belong to (parallel calls share the session, so the
    /// slot cannot live on the session itself).
    const LiveToolCtx = struct {
        session: *Session,
        slot: usize,
    };

    fn onToolOutput(data: []const u8, ctx: *anyopaque) void {
        const ltc: *LiveToolCtx = @alignCast(@ptrCast(ctx));
        const s = ltc.session;
        // Plain print mode: nobody consumes live output; skip accumulation.
        if (!s.record_turn_events and s.json_out == null) return;
        const i: usize = ltc.slot;
        s.live_tool_mutex.lock(s.io) catch return;
        defer s.live_tool_mutex.unlock(s.io);
        if (s.live_tool_outputs[i] == null) {
            const new_buf = std.array_list.Managed(u8).init(s.alloc);
            s.live_tool_outputs[i] = new_buf;
        }
        s.live_tool_outputs[i].?.appendSlice(data) catch return;
        const now_ms = ss.nowMs(s.io);
        if (now_ms - s.live_tool_last_ms[i] < 100) return;
        const id = s.live_tool_ids[i] orelse return;
        s.live_tool_last_ms[i] = now_ms;
        // --mode json: pi emits tool_execution_update with partialResult.
        if (s.json_out != null) {
            const esc_id = s.jsonEscaped(id) catch return;
            defer s.alloc.free(esc_id);
            const esc_out = s.jsonEscaped(s.live_tool_outputs[i].?.items) catch return;
            defer s.alloc.free(esc_out);
            s.jsonEvent("{{\"type\":\"tool_execution_update\",\"toolCallId\":\"{s}\",\"partialResult\":\"{s}\"}}", .{ esc_id, esc_out });
        }
        if (!s.record_turn_events) return;
        const id_copy = s.alloc.dupe(u8, id) catch return;
        const out_copy = s.alloc.dupe(u8, s.live_tool_outputs[i].?.items) catch {
            s.alloc.free(id_copy);
            return;
        };
        s.pushTurnEvent(.{ .tool_update = .{ .id = id_copy, .output = out_copy } });
    }

    pub fn isAborted(self: *Session) bool {
        _ = self;
        return g_abort.load(.acquire);
    }

    /// Route session output by kind and mode.
    pub fn emit(self: *Session, kind: OutputKind, text: []const u8) void {
        if (self.output_cb) |oc| {
            oc.fn_ptr(oc.user_data, kind, text);
            return;
        }
        if (self.quiet) return; // print mode: no streamed output at all
        switch (kind) {
            .text => {
                const stdout = std.Io.File.stdout();
                stdout.writeStreamingAll(self.io, text) catch {};
            },
            else => {},
        }
    }

    /// --mode json: write one structured event line to stdout (pi
    /// AgentSessionEvent / assistantMessageEvent shapes). Best-effort:
    /// output errors are ignored (broken pipe exits via SIGPIPE/EPIPE).
    fn jsonEvent(self: *Session, comptime fmt: []const u8, args: anytype) void {
        if (self.json_out) |out| {
            const line = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
            defer self.alloc.free(line);
            out.writeStreamingAll(self.io, line) catch {};
            out.writeStreamingAll(self.io, "\n") catch {};
        }
    }

    fn jsonEscaped(self: *Session, text: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.alloc);
        errdefer out.deinit();
        for (text) |c| {
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
        return out.toOwnedSlice();
    }

    fn jsonUsage(self: *Session) []const u8 {
        const u = self.stream_usage orelse return "null";
        return std.fmt.allocPrint(self.alloc,
            "{{\"input\":{d},\"output\":{d},\"cacheRead\":{d},\"cacheWrite\":{d},\"total\":{d},\"cost\":{{\"total\":{d:.6}}}}}",
            .{ u.input, u.output, u.cache_read, u.cache_write, u.total, u.cost },
        ) catch return "null";
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
        defer branch.deinit(self.alloc);
        for (branch.messages) |m| try self.context.append(m);
    }

    /// Rebuild the live context from the current store's active branch
    /// (compaction-aware). Used after a compaction entry is recorded.
    fn rebuildContextFromStore(self: *Session) !void {
        const st = self.store orelse return;
        for (self.context.messages.items) |*m| m.deinit();
        self.context.messages.clearRetainingCapacity();
        const branch = try st.branchMessages(self.alloc);
        defer branch.deinit(self.alloc);
        for (branch.messages) |m| try self.context.append(m);
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

    /// Run (or force) a compaction. Returns its display data (tokens before
    /// it + the summarization usage), or null when nothing was compacted.
    /// `custom` optionally focuses the summary.
    pub fn runCompaction(self: *Session, custom: ?[]const u8) !?ss.CompactionInfo {
        return self.runCompactionReasoned(custom, "threshold");
    }

    pub fn runCompactionReasoned(self: *Session, custom: ?[]const u8, reason: []const u8) !?ss.CompactionInfo {
        self.jsonEvent("{{\"type\":\"compaction_start\",\"reason\":\"{s}\"}}", .{reason});
        defer self.jsonEvent("{{\"type\":\"compaction_end\",\"reason\":\"{s}\"}}", .{reason});
        if (events.getGlobal()) |bus| bus.emit(.compaction);
        const st = self.store orelse return null;
        const msgs = self.context.messages.items;
        const L: usize = msgs.len;
        if (L < 2) return null;

        // Iterative compaction (pi prepareCompaction): if the branch already
        // has a compaction entry, the context starts with its synthetic
        // summary message (index 0). The summary is passed as
        // `previous_summary` so the new one merges with it, and the summary
        // message itself is excluded from what gets re-summarized
        // (pi: boundaryStart = prevCompactionIndex + 1).
        const previous_summary: ?[]u8 = st.lastCompactionSummary(self.alloc);
        defer if (previous_summary) |ps| self.alloc.free(ps);
        const boundary: usize = if (previous_summary != null) 1 else 0;

        const cut = self.findCutIndex();
        if (cut <= boundary) return null; // nothing to summarize

        // Map the first kept context message to its store entry id. The
        // live context is built from branchMessages in order, so its ids
        // (null for synthetic summary messages) are index-aligned.
        const branch = try st.branchMessages(self.alloc);
        defer branch.deinit(self.alloc);
        const ids = branch.ids;
        const M: usize = ids.len;
        if (M < L or cut > L - 1) return null;
        // Walk back from the cut point to the nearest real entry id (the
        // synthetic summary message has no store entry of its own).
        var first_kept_idx = cut;
        while (first_kept_idx > 0 and ids[first_kept_idx] == null) first_kept_idx -= 1;
        const first_kept_id = ids[first_kept_idx] orelse return null;

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

        // Summarize the prefix that will be dropped (excluding the
        // previous synthetic summary, which is merged instead).
        const summary = compact.generateSummary(
            self.alloc,
            self.io,
            self.provider,
            self.model.id,
            msgs[boundary..cut],
            previous_summary,
            custom,
            isAbortedGlobal,
            self.model.max_tokens,
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
        // pi getContextUsage: until the next assistant response, the context
        // size is unknown (the footer shows `?/window`).
        self.context_unknown = true;
        const info = ss.CompactionInfo{ .tokens_before = tokens_before, .usage = summary.usage };
        if (self.record_turn_events) self.pushTurnEvent(.{ .compaction = info });
        return info;
    }

    /// pi isRecoverableLength: the round was cut by finish_reason=length while
    /// the model's output budget (max_tokens) still had room — the truncation
    /// came from context pressure or a provider-side cap, not from the model
    /// choosing to stop. True exactly once per turn (the `length_recovered`
    /// flag is set by the caller before re-entering the loop).
    pub fn isRecoverableLength(self: *Session) bool {
        if (self.stream_finish != .length) return false;
        if (self.length_recovered) return false;
        const out_tokens = self.stream_usage orelse msg.Usage{};
        return out_tokens.output < self.model.max_tokens;
    }

    /// Backoff for the Nth empty-response retry (1-indexed): 1s, 2s, 4s.
    /// Exponential, matching pi's retry schedule. Factored out so it is
    /// unit-testable without driving a full runPrompt.
    pub fn emptyRetryDelayMs(attempt: usize) i64 {
        return 1000 * @as(i64, @intCast(std.math.pow(u64, 2, @max(attempt, 1) - 1)));
    }

    /// Auto-compact at a turn boundary if the context exceeds the budget.
    fn maybeAutoCompact(self: *Session) !void {
        const ctx_tokens = compact.estimateContextTokens(self.context.messages.items);
        if (!compact.shouldCompact(ctx_tokens, self.model.context_window, &self.compaction)) return;
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\n[auto-compact: context ~{d} tokens]\n", .{ctx_tokens}) catch "\n[auto-compact]\n";
        self.emit(.tool_info, s);
        // The compaction itself is shown by its own turn event.
        _ = try self.runCompactionReasoned(null, "threshold");
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
        self.jsonEvent("{{\"type\":\"agent_start\"}}", .{});
        self.jsonEvent("{{\"type\":\"turn_start\",\"index\":{d}}}", .{self.turn_counter});
        self.turn_counter += 1;
        defer {
            self.jsonEvent("{{\"type\":\"turn_end\"}}", .{});
            self.jsonEvent("{{\"type\":\"agent_end\"}}", .{});
            self.jsonEvent("{{\"type\":\"agent_settled\",\"aborted\":{}}}", .{self.isAborted()});
        }

        // pi: after a turn ends, queued follow-up messages run as new turns
        // (the outer loop below). Steering messages are injected BEFORE each
        // LLM request (drainSteeringIntoContext, between tool-call rounds).
        var current_prompt: []u8 = self.alloc.dupe(u8, prompt) catch return error.OutOfMemory;
        defer self.alloc.free(current_prompt);
        var follow_up = true;
        while (follow_up) {
            follow_up = false;
            // Per-turn recovery budgets (reset on every new turn, not every
            // tool round: a stall nudge is at most one per user turn, and the
            // empty-retry budget must not be carried over from a turn that
            // ended in a provider failure).
            self.thinking_nudged = false;
            self.length_recovered = false;
            self.retry_attempt = 0;

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

        // One overflow-recovery attempt per run (pi _overflowRecoveryAttempted).
        var overflow_recovered = false;
        // pi agent-loop: unbounded — the round loop runs until the model
        // stops calling tools (or the user aborts). There is NO round limit:
        // a model that keeps making progress must never be cut off.
        while (true) {
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
            self.stream_finish = null;
            self.tool_args_last_ms = 0;
            self.tool_args_last_len = 0;

            self.jsonEvent("{{\"type\":\"message_start\",\"message\":{{\"role\":\"assistant\"}}}}", .{});

            // Fresh error text per round: a transport failure never fills the
            // provider buffer, so clear any stale detail from a prior round.
            self.provider.setLastError(null);

            // Call LLM (retries + abort-aware, see openai.zig)
            aiprovider.streamDispatch(
                self.provider,
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
                self.model.max_tokens,
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
                    _ = self.runCompactionReasoned(null, "overflow") catch {};
                    continue; // rebuild wire messages against the compacted context
                } else {
                    // Keep what streamed before the failure on screen.
                    self.recordText(.thinking, thinking_buf.items);
                    self.recordText(.text, text_buf.items);
                    // Transport failure (no HTTP response at all): the
                    // provider buffer is empty, so store a readable reason.
                    var tb: [128]u8 = undefined;
                    const tmsg = std.fmt.bufPrint(&tb, "transport error: {s}", .{@errorName(e)}) catch "transport error";
                    if (verbose) std.debug.print("[verbose] transport error: {s}\n", .{tmsg});
                    self.provider.setLastErrorIfEmpty(tmsg);
                    const le = self.provider.lastErrorText();
                    if (le.len > 0) {
                        if (self.last_error_message) |old| self.alloc.free(old);
                        self.last_error_message = self.alloc.dupe(u8, le) catch null;
                    }
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
                // A real response arrived: the context size is known again.
                self.context_unknown = false;
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
            if (assistant_msg.blocks.items.len == 0) {
                // The provider "succeeded" but produced nothing (truncated
                // stream, gateway hiccup). pi auto-retries transient provider
                // failures (settings.retry, default 3, exponential backoff);
                // the failed round left no assistant message in the context,
                // so the same round is simply rebuilt and re-requested.
                if (self.retry_attempt < self.retry_max) {
                    self.retry_attempt += 1;
                    const delay_ms = Session.emptyRetryDelayMs(self.retry_attempt);
                    var rb: [64]u8 = undefined;
                    const rmsg = std.fmt.bufPrint(&rb, "\n[empty response — retrying ({d}/{d})]\n", .{ self.retry_attempt, self.retry_max }) catch "\n[empty response — retrying]\n";
                    self.emit(.tool_info, rmsg);
                    var slept: i64 = 0;
                    while (slept < delay_ms) {
                        if (self.isAborted()) break;
                        const step: i64 = @min(200, delay_ms - slept);
                        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(step), .real) catch break;
                        slept += step;
                    }
                    if (self.isAborted()) return;
                    continue;
                }
                return error.EmptyResponse;
            }
            // A real response arrived: the transient-failure budget resets.
            self.retry_attempt = 0;
            // pi isRecoverableLength: the round was cut by
            // finish_reason=length below the model's output limit — usually
            // context pressure or provider-side truncation. One bounded
            // compact-and-retry, like the overflow path above.
            if (self.isRecoverableLength()) {
                self.length_recovered = true;
                self.emit(.tool_info, "\n[length-truncated response — compacting and retrying]\n");
                _ = self.runCompactionReasoned(null, "length") catch {};
                continue;
            }
            const sr: []const u8 = if (n_tool_calls_pending(&assistant_msg) > 0) "toolUse" else "stop";
            assistant_msg.stop_reason = msg.Message.allocStr(self.alloc, sr);
            try self.appendAndRecord(&assistant_msg);
            self.jsonAssistantEnd(&assistant_msg);

            // Count tool calls
            const n_tool_calls: usize = n_tool_calls_pending(&assistant_msg);

            if (n_tool_calls == 0) {
                // P2: a round that produced ONLY thinking (no text, no tool
                // call) ends the turn silently — the model burned its output
                // budget reasoning about the work instead of doing it. Nudge
                // once per turn so the user sees a note and gets an answer.
                if (msg.blocksAreAllThinking(assistant_msg.blocks.items) and !self.thinking_nudged) {
                    self.thinking_nudged = true;
                    self.emit(.tool_info, "\n[round produced reasoning only — continuing]\n");
                    var nudge = msg.Message.init(self.alloc);
                    defer nudge.deinit();
                    nudge.role = .user;
                    const nudge_text = self.alloc.dupe(u8, "Continue. Your previous response contained only reasoning — now perform the work (call the tools / write the files).") catch "Continue.";
                    try nudge.blocks.append(.{ .text = nudge_text });
                    try self.appendAndRecord(&nudge);
                    self.alloc.free(nudge_text);
                    continue;
                }
                // Turn complete. Queued follow-up messages start new turns
                // (pi: the outer loop continues with followUpQueue.drain();
                // mode "all" takes them all at once, "one-at-a-time" the
                // oldest).
                const fus = self.drainFollowUpAll() catch &.{};
                defer {
                    for (fus) |fu| self.alloc.free(fu);
                    self.alloc.free(fus);
                }
                if (fus.len > 0) {
                    // More than one (mode "all"): join like a steering drain.
                    var prompt2: []u8 = fus[0];
                    if (fus.len > 1) {
                        var joined = std.ArrayListUnmanaged(u8).empty;
                        for (fus, 0..) |fu, i| {
                            if (i > 0) joined.appendSlice(self.alloc, "\n\n") catch break;
                            joined.appendSlice(self.alloc, fu) catch break;
                        }
                        if (joined.items.len > 0) {
                            prompt2 = joined.toOwnedSlice(self.alloc) catch prompt2;
                        } else {
                            joined.deinit(self.alloc);
                        }
                    }
                    self.alloc.free(current_prompt);
                    current_prompt = prompt2;
                    follow_up = true;
                }
                break;
            }

            if (aborted) {
                // Keep the conversation wire-valid: every tool call needs a
                // result, unexecuted calls get an "aborted" marker.
                self.appendAbortedToolResults(&assistant_msg);
                break;
            }

            // Announce tool calls via the structured turn events only — the
            // TUI renders the pending card (name + args) from tool_start.
            // The old text announce ([tool 1/1: bash] {...}) duplicated the
            // card as a muted scrollback line (pi: ToolExecutionComponent
            // only, no text echo).
            for (assistant_msg.blocks.items) |b| {
                switch (b) {
                    .tool_call => |tc| self.recordToolStart(tc),
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
                        // The structured tool_result event paints the output
                        // into the card (expanded: full, collapsed: preview).
                        // The raw-content echo here duplicated the card as a
                        // muted scrollback line (pi: updateResult only).
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
                        self.jsonEvent("{{\"type\":\"message_start\",\"message\":{{\"role\":\"toolResult\"}}}}", .{});
                        try self.appendAndRecord(&tr_msg);
                        self.jsonToolResultEnd(&tr_msg);
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
                        results[0] = self.execToolTimed(0, tc.name, tc.id, tc.arguments);
                    } else {
                        const slot = @min(idx, @as(usize, 3));
                        const t = std.Thread.spawn(.{}, toolThreadMain, .{ self, tc, &results[idx], slot }) catch {
                            results[idx] = self.execToolTimed(slot, tc.name, tc.id, tc.arguments);
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

    fn toolThreadMain(self: *Session, tc: msg.ToolCall, out: *tools.ToolResult, slot: usize) void {
        out.* = self.execToolTimed(slot, tc.name, tc.id, tc.arguments);
    }

    /// execTool with the wall time filled in. The pre_tool_call hook (Phase
    /// I2) may BLOCK the call — the model then receives the hook's reason as
    /// a tool error; post_tool_call runs observe-only. `slot` + `id` wire up
    /// the live output stream (bash streaming, pi tool_execution_update).
    fn execToolTimed(self: *Session, slot: usize, name: []const u8, id: []const u8, args_json: []const u8) tools.ToolResult {
        const start = ss.nowMs(self.io);
        if (events.getGlobal()) |bus| {
            if (bus.emitBlocking(.{ .pre_tool_call = .{ .name = name, .args_json = args_json } })) |reason| {
                // The hook's reason (hook stderr) is fed back to the model
                // (Claude Code semantics: exit 2 stderr becomes the error).
                const blocked = std.fmt.allocPrint(
                    self.alloc,
                    "blocked by hook: {s}",
                    .{reason},
                ) catch std.fmt.allocPrint(self.alloc, "blocked by hook", .{}) catch "";
                bus.alloc.free(reason);
                return .{ .content = blocked, .is_error = true, .duration_ms = 0 };
            }
        }
        // Arm the live output stream for this slot: clear any stale buffer
        // from a previous round, point the reader threads at it.
        self.live_tool_mutex.lock(self.io) catch {};
        if (self.live_tool_outputs[slot]) |old| old.deinit();
        self.live_tool_outputs[slot] = null;
        self.live_tool_last_ms[slot] = 0;
        self.live_tool_ids[slot] = id;
        self.live_tool_mutex.unlock(self.io);
        var result = self.execTool(slot, name, args_json);
        if (events.getGlobal()) |bus| {
            bus.emit(.{ .post_tool_call = .{
                .name = name,
                .args_json = args_json,
                .result = result.content,
                .is_error = result.is_error,
                .duration_ms = @intCast(ss.nowMs(self.io) - start),
            } });
        }
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

    fn execTool(self: *Session, slot: usize, name: []const u8, args_json: []const u8) tools.ToolResult {
        const tool = self.registry.find(name) orelse
            return .{ .content = std.fmt.allocPrint(self.alloc, "unknown tool: {s}", .{name}) catch "", .is_error = true };
        // Per-call context: the shared exec_ctx is borrowed by the tools,
        // but the live-output callback must be armed per slot. A stack copy
        // keeps the shared one untouched for non-streaming callers.
        var ctx = self.exec_ctx;
        var ltc = LiveToolCtx{ .session = self, .slot = slot };
        ctx.on_output = onToolOutput;
        ctx.on_output_ctx = &ltc;
        return tool.execute(tool, args_json, &ctx);
    }

    /// --mode json: block count before the first tool call slot.
    fn contentBaseIndex(has_thinking: bool, has_text: bool) usize {
        return @as(usize, if (has_thinking) 1 else 0) + @as(usize, if (has_text) 1 else 0);
    }

    /// --mode json: full assistant message object (pi message_end shape).
    fn jsonAssistantEnd(self: *Session, m: *const msg.Message) void {
        if (self.json_out == null) return;
        var content = std.array_list.Managed(u8).init(self.alloc);
        defer content.deinit();
        content.append('[') catch return;
        var first = true;
        var idx: usize = 0;
        for (m.blocks.items) |b| {
            if (!first) content.append(',') catch return;
            first = false;
            switch (b) {
                .thinking => |t| {
                    const esc = self.jsonEscaped(t) catch return;
                    defer self.alloc.free(esc);
                    const seg = std.fmt.allocPrint(self.alloc, "{{\"type\":\"thinking\",\"contentIndex\":{d},\"thinking\":\"{s}\"}}", .{ idx, esc }) catch return;
                    defer self.alloc.free(seg);
                    content.appendSlice(seg) catch return;
                },
                .text => |t| {
                    const esc = self.jsonEscaped(t) catch return;
                    defer self.alloc.free(esc);
                    const seg = std.fmt.allocPrint(self.alloc, "{{\"type\":\"text\",\"contentIndex\":{d},\"text\":\"{s}\"}}", .{ idx, esc }) catch return;
                    defer self.alloc.free(seg);
                    content.appendSlice(seg) catch return;
                },
                .tool_call => |tc| {
                    const id_esc = self.jsonEscaped(tc.id) catch return;
                    defer self.alloc.free(id_esc);
                    const name_esc = self.jsonEscaped(tc.name) catch return;
                    defer self.alloc.free(name_esc);
                    const args_esc = self.jsonEscaped(tc.arguments) catch return;
                    defer self.alloc.free(args_esc);
                    const seg = std.fmt.allocPrint(self.alloc, "{{\"type\":\"toolCall\",\"contentIndex\":{d},\"id\":\"{s}\",\"name\":\"{s}\",\"arguments\":\"{s}\"}}", .{ idx, id_esc, name_esc, args_esc }) catch return;
                    defer self.alloc.free(seg);
                    content.appendSlice(seg) catch return;
                },
                else => {},
            }
            idx += 1;
        }
        content.append(']') catch return;
        const usage = self.jsonUsage();
        defer if (!std.mem.eql(u8, usage, "null")) self.alloc.free(@constCast(usage));
        const prov_esc = self.jsonEscaped(m.provider orelse "") catch return;
        defer self.alloc.free(prov_esc);
        const model_esc = self.jsonEscaped(m.model_id orelse "") catch return;
        defer self.alloc.free(model_esc);
        const sr_esc = self.jsonEscaped(m.stop_reason orelse "") catch return;
        defer self.alloc.free(sr_esc);
        self.jsonEvent("{{\"type\":\"message_end\",\"message\":{{\"role\":\"assistant\",\"content\":{s},\"stopReason\":\"{s}\",\"model\":\"{s}\",\"provider\":\"{s}\",\"usage\":{s}}}}}", .{ content.items, sr_esc, model_esc, prov_esc, usage });
    }

    /// --mode json: toolResult message object.
    fn jsonToolResultEnd(self: *Session, m: *const msg.Message) void {
        if (self.json_out == null) return;
        for (m.blocks.items) |b| switch (b) {
            .tool_result => |tr| {
                const id_esc = self.jsonEscaped(tr.tool_call_id) catch return;
                defer self.alloc.free(id_esc);
                const content_esc = self.jsonEscaped(tr.content) catch return;
                defer self.alloc.free(content_esc);
                self.jsonEvent("{{\"type\":\"message_end\",\"message\":{{\"role\":\"toolResult\",\"toolCallId\":\"{s}\",\"content\":\"{s}\",\"isError\":{}}}}}", .{ id_esc, content_esc, tr.is_error });
                return;
            },
            else => {},
        };
    }

    pub fn onStreamEvent(self: *Session, event: ai.StreamEvent) void {
        switch (event) {
            .text_delta => |text| {
                self.stream_text.appendSlice(text) catch return;
                self.emit(.text, text);
                if (self.json_out != null) {
                    const esc = self.jsonEscaped(text) catch return;
                    defer self.alloc.free(esc);
                    // contentIndex: thinking (when present) occupies 0, text follows.
                    const ci: usize = if (self.stream_thinking.items.len > 0) 1 else 0;
                    self.jsonEvent("{{\"type\":\"message_update\",\"usage\":null,\"assistantMessageEvent\":{{\"type\":\"text_delta\",\"contentIndex\":{d},\"delta\":\"{s}\"}}}}", .{ ci, esc });
                }
            },
            .thinking_delta => |text| {
                self.stream_thinking.appendSlice(text) catch return;
                self.emit(.thinking, text);
                if (self.json_out != null) {
                    const esc = self.jsonEscaped(text) catch return;
                    defer self.alloc.free(esc);
                    self.jsonEvent("{{\"type\":\"message_update\",\"usage\":null,\"assistantMessageEvent\":{{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"{s}\"}}}}", .{esc});
                }
            },
            .tool_call_delta => |d| {
                const is_new = d.index >= self.stream_tools.items.len;
                while (d.index >= self.stream_tools.items.len) {
                    self.stream_tools.append(.{ .id = "", .name = "", .arguments = "" }) catch return;
                }
                if (is_new and self.json_out != null) {
                    // toolcall_start: id/name arrive with the first event
                    // (openai) or content_block_start (anthropic).
                    const id_esc = self.jsonEscaped(d.id orelse "") catch return;
                    defer self.alloc.free(id_esc);
                    const name_esc = self.jsonEscaped(d.name orelse "") catch return;
                    defer self.alloc.free(name_esc);
                    const base: usize = contentBaseIndex(self.stream_thinking.items.len > 0, self.stream_text.items.len > 0);
                    self.jsonEvent("{{\"type\":\"message_update\",\"usage\":null,\"assistantMessageEvent\":{{\"type\":\"toolcall_start\",\"contentIndex\":{d},\"id\":\"{s}\",\"toolName\":\"{s}\"}}}}", .{ base + d.index, id_esc, name_esc });
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
                    if (self.json_out != null and !is_new and delta.len > 0) {
                        const esc = self.jsonEscaped(delta) catch return;
                        defer self.alloc.free(esc);
                        const base = contentBaseIndex(self.stream_thinking.items.len > 0, self.stream_text.items.len > 0);
                        self.jsonEvent("{{\"type\":\"message_update\",\"usage\":null,\"assistantMessageEvent\":{{\"type\":\"toolcall_delta\",\"contentIndex\":{d},\"delta\":\"{s}\"}}}}", .{ base + d.index, esc });
                    }
                }
                // Live tool preview (pi: the tool block renders while the
                // model writes its arguments — write's path first, then the
                // content preview grows). Throttled: at most one event per
                // 250 ms, or immediately when the args length doubled (so
                // fast bursts still show visible progress).
                if (self.record_turn_events) {
                    const now_ms = ss.nowMs(self.io);
                    const cur_len = self.stream_tools.items[d.index].arguments.len;
                    if (cur_len > 0 and (now_ms - self.tool_args_last_ms >= 250 or cur_len >= self.tool_args_last_len * 2)) {
                        self.tool_args_last_ms = now_ms;
                        self.tool_args_last_len = cur_len;
                        const tc = self.stream_tools.items[d.index];
                        const id_c = self.alloc.dupe(u8, tc.id) catch return;
                        const name_c = self.alloc.dupe(u8, tc.name) catch {
                            self.alloc.free(id_c);
                            return;
                        };
                        const args_c = self.alloc.dupe(u8, tc.arguments) catch {
                            self.alloc.free(id_c);
                            self.alloc.free(name_c);
                            return;
                        };
                        self.pushTurnEvent(.{ .tool_args = .{ .id = id_c, .name = name_c, .arguments = args_c } });
                    }
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
            .done => |reason| self.stream_finish = reason,
        }
    }
};
