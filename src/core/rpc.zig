//! K2: --mode rpc — headless operation over a JSONL stdin/stdout protocol
//! (pi modes/rpc/rpc-mode.js).
//!
//! Protocol (one JSON object per line, LF framing — pi jsonl.js semantics:
//! records split on '\n' only, a trailing '\r' is stripped):
//!
//!   stdin  : {"type":"<command>","id":"<corr>", ...}
//!   stdout : {"type":"response","id":...,"command":...,"success":true,"data":...}
//!            {"type":"response",...,"success":false,"error":"..."}
//!            + the K1 json-event stream (agent_start / turn_* / message_* /
//!              tool_* / compaction_* / agent_settled) as it occurs.
//!
//! Commands (pi rpc-mode.js handleCommand): prompt, steer, follow_up, abort,
//! clear_queue, new_session, get_state, set_model, cycle_model,
//! get_available_models, set_thinking_level, cycle_thinking_level,
//! get_available_thinking_levels, set_steering_mode, set_follow_up_mode,
//! compact, set_auto_compaction, bash, get_session_stats, export_html,
//! switch_session, clone, get_entries, get_tree, get_last_assistant_text,
//! set_session_name, get_messages, get_commands.
//!
//! Threading: the stdin reader thread parses lines and calls handleCommand,
//! which enqueues a job; the agent thread (run) owns the Session and executes
//! jobs sequentially (prompt runs the whole turn inline, like the TUI's
//! submitText). Responses and events are written under out_mutex. The K1
//! json_out writer (agent thread) is the same file, so every stdout line is
//! serialized either by out_mutex (responses/headers) or by the agent thread
//! itself (events) — no interleaving.

const std = @import("std");
const agent = @import("agent.zig");
const msg = @import("message.zig");
const ss = @import("session_store.zig");
const config = @import("config.zig");
const aiprovider = @import("../ai/provider.zig");
const shell = @import("../tools/shell.zig");

pub const Rpc = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    session: *agent.Session,
    cfg: *config.Config,
    sessions_dir: []const u8,
    cwd_abs: []const u8,
    stdout: std.Io.File,
    /// Owned by the Rpc until the session outlives it (the TUI-free path):
    /// set_model builds a fresh provider the way TUI.switchModel does.
    owned_provider: ?aiprovider.AnyProvider = null,

    out_mutex: std.Io.Mutex = std.Io.Mutex.init,
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    job_mutex: std.Io.Mutex = std.Io.Mutex.init,
    stdin_thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),

    /// One queued command. `text` is owned (freed after execution).
    pub const Job = struct {
        type: []const u8,
        id: ?[]const u8 = null, // owned when non-null
        text: ?[]const u8 = null, // prompt/steer/follow_up/bash command/custom instructions
        name: ?[]const u8 = null, // set_model model id / set_session_name / switch_session path / export path
        provider: ?[]const u8 = null,
        mode: ?[]const u8 = null, // steering/follow-up mode
        level: ?[]const u8 = null, // thinking level
        enabled: ?bool = null, // set_auto_compaction
        exclude: bool = false, // bash excludeFromContext
    };

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        session: *agent.Session,
        cfg: *config.Config,
        sessions_dir: []const u8,
        cwd_abs: []const u8,
        stdout: std.Io.File,
    ) Rpc {
        return .{
            .alloc = alloc,
            .io = io,
            .session = session,
            .cfg = cfg,
            .sessions_dir = sessions_dir,
            .cwd_abs = cwd_abs,
            .stdout = stdout,
        };
    }

    pub fn deinit(self: *Rpc) void {
        if (self.owned_provider) |p| p.deinit();
        self.owned_provider = null;
    }

    // ---------------------------------------------------------------- output

    fn emit(self: *Rpc, line: []const u8) void {
        self.out_mutex.lock(self.io) catch return;
        defer self.out_mutex.unlock(self.io);
        self.stdout.writeStreamingAll(self.io, line) catch {};
        self.stdout.writeStreamingAll(self.io, "\n") catch {};
    }

    /// JSON-escape a string into `out`.
    pub fn escape(out: *std.array_list.Managed(u8), s: []const u8) !void {
        try out.append('"');
        for (s) |c| {
            if (c < 0x20) {
                // Control chars (incl. \n \r \t) as \uXXXX — always valid JSON.
                const h = std.fmt.allocPrint(out.allocator, "\\u{X:0>4}", .{c}) catch return;
                defer out.allocator.free(h);
                try out.appendSlice(h);
            } else if (c == '"' or c == '\\') {
                try out.append('\\');
                try out.append(c);
            } else {
                try out.append(c);
            }
        }
        try out.append('"');
    }

    fn ok(self: *Rpc, id: ?[]const u8, command: []const u8) !void {
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"type\":\"response\"");
        if (id) |i| {
            try o.appendSlice(",\"id\":");
            try escape(&o, i);
        }
        try o.appendSlice(",\"command\":");
        try escape(&o, command);
        try o.appendSlice(",\"success\":true}");
        self.emit(o.items);
    }

    fn okData(self: *Rpc, id: ?[]const u8, command: []const u8, data: []const u8) !void {
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"type\":\"response\"");
        if (id) |i| {
            try o.appendSlice(",\"id\":");
            try escape(&o, i);
        }
        try o.appendSlice(",\"command\":");
        try escape(&o, command);
        try o.appendSlice(",\"success\":true,\"data\":");
        try o.appendSlice(data);
        try o.append('}');
        self.emit(o.items);
    }

    fn fail(self: *Rpc, id: ?[]const u8, command: []const u8, message: []const u8) !void {
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"type\":\"response\"");
        if (id) |i| {
            try o.appendSlice(",\"id\":");
            try escape(&o, i);
        }
        try o.appendSlice(",\"command\":");
        try escape(&o, command);
        try o.appendSlice(",\"success\":false,\"error\":");
        try escape(&o, message);
        try o.append('}');
        self.emit(o.items);
    }

    // ----------------------------------------------------------------- input

    /// Main entry: emit the session header, serve commands until stdin EOF.
    /// Returns when stdin closes; the caller retires the session.
    pub fn run(self: *Rpc) void {
        if (self.session.store) |st| {
            st.emitHeader(self.stdout, self.io) catch {};
        }
        self.stdin_thread = std.Thread.spawn(.{}, stdinMain, .{self}) catch {
            self.fail(null, "init", "failed to spawn stdin reader") catch {};
            return;
        };
        // Drain until stdin closed (quit) AND no jobs remain: a command
        // queued in the same instant as EOF must still execute.
        while (true) {
            // Only probe under the lock; execJob takes the job itself
            // (double-removal here would drop the head job).
            self.job_mutex.lock(self.io) catch break;
            const have = self.jobs.items.len > 0;
            self.job_mutex.unlock(self.io);
            if (have) {
                self.execJob();
                continue;
            }
            if (self.quit.load(.acquire)) break;
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
        }
        if (self.stdin_thread) |t| t.join();
    }

    fn stdinMain(rpc: *Rpc) void {
        const stdin = std.Io.File.stdin();
        var line = std.array_list.Managed(u8).init(rpc.alloc);
        defer line.deinit();
        // Byte-by-byte: a 1-byte destination makes readStreaming return on
        // the first available byte, so commands are never batched unread.
        var one: [1]u8 = undefined;
        while (!rpc.quit.load(.acquire)) {
            const n = stdin.readStreaming(rpc.io, &.{&one}) catch {
                    break;
            };
            if (n == 0) break;
            const c = one[0];
            if (c == 0x0A) {
                rpc.handleLine(line.items);
                line.clearRetainingCapacity();
            } else if (c != 0x0D) {
                line.append(c) catch break;
            }
        }
        if (line.items.len > 0) rpc.handleLine(line.items);
        rpc.quit.store(true, .release);
    }

    /// Copy a string field out of the parsed command (the parsed tree is
    /// freed before the job executes, so the job owns its own copy).
    fn strField(self: *Rpc, obj: std.json.Value, key: []const u8) ?[]const u8 {
        const o = switch (obj) {
            .object => |o| o,
            else => return null,
        };
        const v = o.get(key) orelse return null;
        const s = v.string;
        if (s.len == 0) return null;
        return self.alloc.dupe(u8, s) catch null;
    }

    /// Parse one JSONL command line and enqueue a job (pi handleInputLine).
    fn handleLine(self: *Rpc, line: []const u8) void {
        const v = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch {
            self.fail(null, "parse", "failed to parse command (invalid JSON)") catch {};
            return;
        };
        defer v.deinit();
        const obj = switch (v.value) {
            .object => |o| o,
            else => {
                self.fail(null, "parse", "command must be a JSON object") catch {};
                return;
            },
        };
        const tv = obj.get("type") orelse {
            self.fail(null, "parse", "command is missing \"type\"") catch {};
            return;
        };
        const type_raw: []const u8 = tv.string;
        const type_s = self.alloc.dupe(u8, type_raw) catch return;
        const idv = obj.get("id");
        const id: ?[]const u8 = if (idv) |iv| self.alloc.dupe(u8, iv.string) catch null else null;
        var job: Job = .{ .type = type_s };
        job.id = id;
        job.text = self.strField(v.value, "message") orelse self.strField(v.value, "command") orelse self.strField(v.value, "customInstructions") orelse self.strField(v.value, "name") orelse self.strField(v.value, "outputPath");
        job.provider = self.strField(v.value, "provider");
        job.name = self.strField(v.value, "modelId") orelse job.name;
        job.mode = self.strField(v.value, "mode");
        job.level = self.strField(v.value, "level");
        if (obj.get("enabled")) |e| job.enabled = switch (e) {
            .bool => |b| b,
            else => false,
        };
        if (obj.get("excludeFromContext")) |x| job.exclude = switch (x) {
            .bool => |b| b,
            else => false,
        };
        self.job_mutex.lock(self.io) catch return;
        defer self.job_mutex.unlock(self.io);
        self.jobs.append(self.alloc, job) catch return;
    }

    // ------------------------------------------------------------------ jobs

    /// Command name → enum (Zig has no string switch).
    pub fn cmdEnum(t: []const u8) enum {
        prompt, steer, follow_up, abort, clear_queue, new_session, get_state,
        set_model, cycle_model, get_available_models, set_thinking_level,
        cycle_thinking_level, get_available_thinking_levels, set_steering_mode,
        set_follow_up_mode, compact, set_auto_compaction, bash,
        get_session_stats, export_html, switch_session, clone, get_entries,
        get_tree, get_last_assistant_text, set_session_name, get_messages,
        get_commands, unknown,
    } {
        return if (std.mem.eql(u8, t, "prompt")) .prompt
        else if (std.mem.eql(u8, t, "steer")) .steer
        else if (std.mem.eql(u8, t, "follow_up")) .follow_up
        else if (std.mem.eql(u8, t, "abort")) .abort
        else if (std.mem.eql(u8, t, "clear_queue")) .clear_queue
        else if (std.mem.eql(u8, t, "new_session")) .new_session
        else if (std.mem.eql(u8, t, "get_state")) .get_state
        else if (std.mem.eql(u8, t, "set_model")) .set_model
        else if (std.mem.eql(u8, t, "cycle_model")) .cycle_model
        else if (std.mem.eql(u8, t, "get_available_models")) .get_available_models
        else if (std.mem.eql(u8, t, "set_thinking_level")) .set_thinking_level
        else if (std.mem.eql(u8, t, "cycle_thinking_level")) .cycle_thinking_level
        else if (std.mem.eql(u8, t, "get_available_thinking_levels")) .get_available_thinking_levels
        else if (std.mem.eql(u8, t, "set_steering_mode")) .set_steering_mode
        else if (std.mem.eql(u8, t, "set_follow_up_mode")) .set_follow_up_mode
        else if (std.mem.eql(u8, t, "compact")) .compact
        else if (std.mem.eql(u8, t, "set_auto_compaction")) .set_auto_compaction
        else if (std.mem.eql(u8, t, "bash")) .bash
        else if (std.mem.eql(u8, t, "get_session_stats")) .get_session_stats
        else if (std.mem.eql(u8, t, "export_html")) .export_html
        else if (std.mem.eql(u8, t, "switch_session")) .switch_session
        else if (std.mem.eql(u8, t, "clone")) .clone
        else if (std.mem.eql(u8, t, "get_entries")) .get_entries
        else if (std.mem.eql(u8, t, "get_tree")) .get_tree
        else if (std.mem.eql(u8, t, "get_last_assistant_text")) .get_last_assistant_text
        else if (std.mem.eql(u8, t, "set_session_name")) .set_session_name
        else if (std.mem.eql(u8, t, "get_messages")) .get_messages
        else if (std.mem.eql(u8, t, "get_commands")) .get_commands
        else .unknown;
    }

    fn execJob(self: *Rpc) void {
        const s = self.session;
        self.job_mutex.lock(self.io) catch return;
        const job = self.jobs.items[0];
        _ = self.jobs.orderedRemove(0);
        self.job_mutex.unlock(self.io);
        defer {
            self.alloc.free(job.type);
            if (job.id) |i| self.alloc.free(i);
            if (job.text) |t| self.alloc.free(t);
            if (job.name) |n| self.alloc.free(n);
            if (job.provider) |p| self.alloc.free(p);
            if (job.mode) |m| self.alloc.free(m);
            if (job.level) |l| self.alloc.free(l);
        }
        switch (cmdEnum(job.type)) {
            .prompt => {

                self.cmdPrompt(&job) catch {};

            },
            .steer => {

                self.cmdQueue(&job, true) catch {};

            },
            .follow_up => {

                self.cmdQueue(&job, false) catch {};

            },
            .abort => {
                agent.requestAbort();
                self.ok(job.id, "abort") catch {};
            },
            .clear_queue => {
                const n = s.clearQueue();
                self.okData(job.id, "clear_queue", self.alloc.dupe(u8, std.fmt.allocPrint(self.alloc, "{d}", .{n}) catch "0") catch "0") catch {};
            },
            .new_session => {

                self.cmdNewSession(&job) catch {};

            },
            .get_state => {

                self.cmdGetState(&job) catch {};

            },
            .set_model => {

                self.cmdSetModel(&job) catch {};

            },
            .cycle_model => {

                self.cmdCycleModel(&job) catch {};

            },
            .get_available_models => {

                self.cmdAvailableModels(&job) catch {};

            },
            .set_thinking_level => {

                self.cmdSetThinking(&job) catch {};

            },
            .cycle_thinking_level => {

                self.cmdCycleThinking(&job) catch {};

            },
            .get_available_thinking_levels => {

                self.cmdAvailableThinking(&job) catch {};

            },
            .set_steering_mode => {

                self.cmdSetSteeringMode(&job) catch {};

            },
            .set_follow_up_mode => {

                self.cmdSetFollowUpMode(&job) catch {};

            },
            .compact => {

                self.cmdCompact(&job) catch {};

            },
            .set_auto_compaction => {

                self.cmdSetAutoCompaction(&job) catch {};

            },
            .bash => {

                self.cmdBash(&job) catch {};

            },
            .get_session_stats => {

                self.cmdSessionStats(&job) catch {};

            },
            .export_html => {

                self.cmdExportHtml(&job) catch {};

            },
            .switch_session => {

                self.cmdSwitchSession(&job) catch {};

            },
            .clone => {

                self.cmdClone(&job) catch {};

            },
            .get_entries => {

                self.cmdGetEntries(&job) catch {};

            },
            .get_tree => {

                self.cmdGetTree(&job) catch {};

            },
            .get_last_assistant_text => {

                self.cmdLastAssistantText(&job) catch {};

            },
            .set_session_name => {

                self.cmdSetSessionName(&job) catch {};

            },
            .get_messages => {

                self.cmdGetMessages(&job) catch {};

            },
            .get_commands => {

                self.cmdGetCommands(&job) catch {};

            },
            .unknown => {
                self.fail(job.id, job.type, "unknown command") catch {};
            },
        }
    }

    fn cmdPrompt(self: *Rpc, job: *const Job) !void {
        const text = job.text orelse {
            self.fail(job.id, "prompt", "missing \"message\"") catch {};
            return;
        };
        // Run the whole turn inline on the agent thread (TUI submitText
        // equivalent). The K1 event stream carries the round's progress;
        // agent_settled is the completion marker. The response comes AFTER
        // the turn: the caller may immediately issue the next command, and
        // its data (e.g. the last assistant text) must be stable by then.
        _ = self.session.runPrompt(text) catch |e| {
            if (e != error.Aborted) {
                var eb: [64]u8 = undefined;
                const em = std.fmt.bufPrint(&eb, "prompt failed: {s}", .{@errorName(e)}) catch "prompt failed";
                self.fail(job.id, "prompt", em) catch {};
            }
            return;
        };
        self.ok(job.id, "prompt") catch {};
    }

    fn cmdQueue(self: *Rpc, job: *const Job, steering: bool) !void {
        const text = job.text orelse {
            self.fail(job.id, if (steering) "steer" else "follow_up", "missing \"message\"") catch {};
            return;
        };
        if (steering) {
            self.session.queueSteering(text);
        } else {
            self.session.queueFollowUp(text);
        }
        self.ok(job.id, if (steering) "steer" else "follow_up") catch {};
    }

    fn cmdNewSession(self: *Rpc, job: *const Job) !void {
        const st = ss.Store.create(self.alloc, self.io, self.sessions_dir, self.cwd_abs, .{}) catch {
            self.fail(job.id, "new_session", "create failed") catch {};
            return;
        };
        const old = self.session.store;
        self.session.adoptStore(st) catch {
            self.fail(job.id, "new_session", "adopt failed") catch {};
            return;
        };
        if (old) |o| o.deinit();
        st.emitHeader(self.stdout, self.io) catch {};
        self.ok(job.id, "new_session") catch {};
    }

    fn cmdGetState(self: *Rpc, job: *const Job) !void {
        const s = self.session;
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"model\":");
        try escape(&o, s.model.id);
        try o.appendSlice(",\"thinkingLevel\":\"");
        try o.appendSlice(s.thinking_level.name());
        try o.appendSlice("\",\"isStreaming\":false,\"isCompacting\":false,\"steeringMode\":\"");
        try o.appendSlice(if (s.steering_mode_all) "all" else "one-at-a-time");
        try o.appendSlice("\",\"followUpMode\":\"");
        try o.appendSlice(if (s.follow_up_mode_all) "all" else "one-at-a-time");
        try o.append('"');
        if (s.store) |st| {
            try o.appendSlice(",\"sessionFile\":");
            try escape(&o, st.path);
            try o.appendSlice(",\"sessionId\":");
            try escape(&o, st.id);
            if (st.name) |n| {
                try o.appendSlice(",\"sessionName\":");
                try escape(&o, n);
            }
        }
        try o.appendSlice(",\"autoCompactionEnabled\":");
        try o.appendSlice(if (s.compaction.enabled) "true" else "false");
        const p1 = std.fmt.allocPrint(self.alloc, ",\"messageCount\":{d}", .{s.context.messages.items.len}) catch return;
        defer self.alloc.free(p1);
        try o.appendSlice(p1);
        const p2 = std.fmt.allocPrint(self.alloc, ",\"pendingMessageCount\":{d}{s}", .{ s.queuedPeekLen() + s.followUpCount(), "}" }) catch return;
        defer self.alloc.free(p2);
        try o.appendSlice(p2);
        self.okData(job.id, "get_state", o.items) catch {};
    }

    fn findModel(self: *Rpc, provider: ?[]const u8, id: []const u8) ?*const config.Config.Model {
        for (self.cfg.models.items) |*m| {
            if (std.mem.eql(u8, m.id, id) and (provider == null or std.mem.eql(u8, m.provider, provider.?))) return m;
        }
        return null;
    }

    fn cmdSetModel(self: *Rpc, job: *const Job) !void {
        const id = job.name orelse {
            self.fail(job.id, "set_model", "missing \"modelId\"") catch {};
            return;
        };
        const m = self.findModel(job.provider, id) orelse {
            var mb: [128]u8 = undefined;
            const mm = std.fmt.bufPrint(&mb, "model not found: {s}", .{id}) catch "model not found";
            self.fail(job.id, "set_model", mm) catch {};
            return;
        };
        const p = aiprovider.buildFromModel(self.alloc, self.io, m) catch {
            self.fail(job.id, "set_model", "failed to build provider") catch {};
            return;
        };
        if (self.owned_provider) |old| old.deinit();
        self.owned_provider = p;
        self.session.provider = p;
        self.session.model = m;
        self.session.thinking_level = m.thinking_level;
        if (self.session.store) |st| st.recordModelChange(m.provider, m.id);
        self.ok(job.id, "set_model") catch {};
    }

    fn cmdCycleModel(self: *Rpc, job: *const Job) !void {
        const models = self.cfg.models.items;
        if (models.len == 0) {
            self.ok(job.id, "cycle_model") catch {};
            return;
        }
        var idx: usize = 0;
        for (models, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, self.session.model.id) and std.mem.eql(u8, m.provider, self.session.model.provider)) {
                idx = i;
                break;
            }
        }
        const m = models[(idx + 1) % models.len];
        const p = aiprovider.buildFromModel(self.alloc, self.io, &m) catch {
            self.fail(job.id, "cycle_model", "failed to build provider") catch {};
            return;
        };
        if (self.owned_provider) |old| old.deinit();
        self.owned_provider = p;
        self.session.provider = p;
        self.session.model = &m;
        self.session.thinking_level = m.thinking_level;
        if (self.session.store) |st| st.recordModelChange(m.provider, m.id);
        self.ok(job.id, "cycle_model") catch {};
    }

    fn cmdAvailableModels(self: *Rpc, job: *const Job) !void {
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"models\":[");
        for (self.cfg.models.items, 0..) |m, i| {
            if (i > 0) try o.append(',');
            try o.appendSlice("{\"provider\":");
            try escape(&o, m.provider);
            try o.appendSlice(",\"id\":");
            try escape(&o, m.id);
            try o.appendSlice(",\"name\":");
            try escape(&o, m.name);
            try o.append('}');
        }
        try o.appendSlice("]}");
        self.okData(job.id, "get_available_models", o.items) catch {};
    }

    fn cmdSetThinking(self: *Rpc, job: *const Job) !void {
        const l = job.level orelse {
            self.fail(job.id, "set_thinking_level", "missing \"level\"") catch {};
            return;
        };
        const lvl = config.ThinkingLevel.fromStr(l) orelse {
            var lb: [128]u8 = undefined;
            const lm = std.fmt.bufPrint(&lb, "unknown level: {s}", .{l}) catch "unknown level";
            self.fail(job.id, "set_thinking_level", lm) catch {};
            return;
        };
        self.session.thinking_level = lvl;
        self.ok(job.id, "set_thinking_level") catch {};
    }

    fn cmdCycleThinking(self: *Rpc, job: *const Job) !void {
        const levels = [_]config.ThinkingLevel{ .off, .low, .medium, .high, .xhigh, .max };
        var idx: usize = 0;
        for (levels, 0..) |l, i| {
            if (l == self.session.thinking_level) idx = i;
        }
        self.session.thinking_level = levels[(idx + 1) % levels.len];
        self.ok(job.id, "cycle_thinking_level") catch {};
    }

    fn cmdAvailableThinking(self: *Rpc, job: *const Job) !void {
        self.okData(job.id, "get_available_thinking_levels",
            "{\"levels\":[\"off\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}") catch {};
    }

    fn parseMode(v: []const u8) bool {
        return std.mem.eql(u8, v, "all") or std.mem.eql(u8, v, "one-at-a-time");
    }

    fn cmdSetSteeringMode(self: *Rpc, job: *const Job) !void {
        const m = job.mode orelse {
            self.fail(job.id, "set_steering_mode", "missing \"mode\"") catch {};
            return;
        };
        if (!parseMode(m)) {
            self.fail(job.id, "set_steering_mode", "mode must be all or one-at-a-time") catch {};
            return;
        }
        self.session.steering_mode_all = std.mem.eql(u8, m, "all");
        self.ok(job.id, "set_steering_mode") catch {};
    }

    fn cmdSetFollowUpMode(self: *Rpc, job: *const Job) !void {
        const m = job.mode orelse {
            self.fail(job.id, "set_follow_up_mode", "missing \"mode\"") catch {};
            return;
        };
        if (!parseMode(m)) {
            self.fail(job.id, "set_follow_up_mode", "mode must be all or one-at-a-time") catch {};
            return;
        }
        self.session.follow_up_mode_all = std.mem.eql(u8, m, "all");
        self.ok(job.id, "set_follow_up_mode") catch {};
    }

    fn cmdCompact(self: *Rpc, job: *const Job) !void {
        const custom = job.text; // customInstructions
        const info = self.session.runCompaction(custom) catch {
            self.fail(job.id, "compact", "compaction failed") catch {};
            return;
        };
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        if (info) |i| {
            const tb = std.fmt.allocPrint(self.alloc, "{s}{d}{s}", .{ "{\"tokensBefore\":", i.tokens_before, "}" }) catch return;
            defer self.alloc.free(tb);
            try o.appendSlice(tb);
        } else {
            try o.appendSlice("{}");
        }
        self.okData(job.id, "compact", o.items) catch {};
    }

    fn cmdSetAutoCompaction(self: *Rpc, job: *const Job) !void {
        self.session.compaction.enabled = job.enabled orelse true;
        self.ok(job.id, "set_auto_compaction") catch {};
    }

    fn cmdBash(self: *Rpc, job: *const Job) !void {
        const command = job.text orelse {
            self.fail(job.id, "bash", "missing \"command\"") catch {};
            return;
        };
        var out = std.array_list.Managed(u8).init(self.alloc);
        defer out.deinit();
        const res = shell.exec(self.alloc, self.io, shell.defaultConfig(), command, .{
            .timeout = 30,
        }, &out) catch {
            self.fail(job.id, "bash", "failed to spawn shell") catch {};
            return;
        };
        const exit_code: ?i32 = if (res.exit_code) |c| @as(i32, c) else null;
        self.session.appendBashExecution(command, out.items, exit_code, job.exclude);
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"exitCode\":");
        if (exit_code) |c| {
            const ec = std.fmt.allocPrint(self.alloc, "{d}", .{c}) catch return;
            defer self.alloc.free(ec);
            try o.appendSlice(ec);
        } else {
            try o.appendSlice("null");
        }
        try o.appendSlice(",\"timedOut\":");
        try o.appendSlice(if (res.timed_out) "true" else "false");
        try o.append('}');
        self.okData(job.id, "bash", o.items) catch {};
    }

    fn cmdSessionStats(self: *Rpc, job: *const Job) !void {
        const st = self.session.store orelse {
            self.okData(job.id, "get_session_stats", "{}") catch {};
            return;
        };
        var stats = st.collectStats(self.alloc);
        defer stats.deinit(self.alloc);
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        var sj = std.array_list.Managed(u8).init(self.alloc);
        defer sj.deinit();
        const n1 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.messages_total}) catch return;
        defer self.alloc.free(n1);
        try sj.appendSlice("{\"messages\":{\"total\":");
        try sj.appendSlice(n1);
        const n2 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.messages_user}) catch return;
        defer self.alloc.free(n2);
        try sj.appendSlice(",\"user\":");
        try sj.appendSlice(n2);
        const n3 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.messages_assistant}) catch return;
        defer self.alloc.free(n3);
        try sj.appendSlice(",\"assistant\":");
        try sj.appendSlice(n3);
        const n4 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tool_calls}) catch return;
        defer self.alloc.free(n4);
        try sj.appendSlice(",\"toolCalls\":");
        try sj.appendSlice(n4);
        const n5 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tool_results}) catch return;
        defer self.alloc.free(n5);
        try sj.appendSlice(",\"toolResults\":");
        try sj.appendSlice(n5);
        try sj.appendSlice("},\"tokens\":{\"input\":");
        const n6 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tokens_input}) catch return;
        defer self.alloc.free(n6);
        try sj.appendSlice(n6);
        const n7 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tokens_cached}) catch return;
        defer self.alloc.free(n7);
        try sj.appendSlice(",\"cached\":");
        try sj.appendSlice(n7);
        const n8 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tokens_output}) catch return;
        defer self.alloc.free(n8);
        try sj.appendSlice(",\"output\":");
        try sj.appendSlice(n8);
        const n9 = std.fmt.allocPrint(self.alloc, "{d}", .{stats.tokens_total}) catch return;
        defer self.alloc.free(n9);
        try sj.appendSlice(",\"total\":");
        try sj.appendSlice(n9);
        try sj.appendSlice("},\"cost\":");
        const cs = std.fmt.allocPrint(self.alloc, "{d:.3}", .{stats.cost_total}) catch return;
        defer self.alloc.free(cs);
        try sj.appendSlice(cs);
        try sj.append('}');
        try o.appendSlice(sj.items);
        self.okData(job.id, "get_session_stats", o.items) catch {};
    }

    fn cmdExportHtml(self: *Rpc, job: *const Job) !void {
        const st = self.session.store orelse {
            self.fail(job.id, "export_html", "no session active") catch {};
            return;
        };
        var def: [512]u8 = undefined;
        // outputPath arrives in job.text (handleLine's fallback chain).
        const out_path: []const u8 = job.text orelse std.fmt.bufPrint(&def, "{s}.html", .{st.path}) catch {
            self.fail(job.id, "export_html", "bad path") catch {};
            return;
        };
        st.exportHtml(self.alloc, out_path) catch {
            self.fail(job.id, "export_html", "export failed") catch {};
            return;
        };
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"path\":");
        try escape(&o, out_path);
        try o.append('}');
        self.okData(job.id, "export_html", o.items) catch {};
    }

    fn cmdSwitchSession(self: *Rpc, job: *const Job) !void {
        const path = job.name orelse {
            self.fail(job.id, "switch_session", "missing \"name\" (session path)") catch {};
            return;
        };
        const new_st = ss.Store.open(self.alloc, self.io, path) catch {
            self.fail(job.id, "switch_session", "cannot open session") catch {};
            return;
        };
        const old = self.session.store;
        self.session.adoptStore(new_st) catch {
            self.fail(job.id, "switch_session", "adopt failed") catch {};
            return;
        };
        if (old) |o| o.deinit();
        new_st.emitHeader(self.stdout, self.io) catch {};
        self.ok(job.id, "switch_session") catch {};
    }

    fn cmdClone(self: *Rpc, job: *const Job) !void {
        const st = self.session.store orelse {
            self.fail(job.id, "clone", "no session active") catch {};
            return;
        };
        const cloned = st.fork(self.sessions_dir, self.cwd_abs) catch {
            self.fail(job.id, "clone", "clone failed") catch {};
            return;
        };
        const old = self.session.store;
        self.session.adoptStore(cloned) catch {
            self.fail(job.id, "clone", "adopt failed") catch {};
            return;
        };
        if (old) |o| o.deinit();
        cloned.emitHeader(self.stdout, self.io) catch {};
        self.ok(job.id, "clone") catch {};
    }

    fn cmdGetEntries(self: *Rpc, job: *const Job) !void {
        const st = self.session.store orelse {
            self.okData(job.id, "get_entries", "{\"entries\":[],\"leafId\":null}") catch {};
            return;
        };
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"entries\":[");
        var first = true;
        for (st.entries.items) |e| {
            if (!first) try o.append(',');
            first = false;
            // The raw line already IS one JSON object: embed verbatim.
            try o.appendSlice(e.line);
        }
        try o.appendSlice("],\"leafId\":");
        if (st.leaf_id) |l| {
            try escape(&o, l);
        } else {
            try o.appendSlice("null");
        }
        try o.append('}');
        self.okData(job.id, "get_entries", o.items) catch {};
    }

    fn cmdGetTree(self: *Rpc, job: *const Job) !void {
        const st = self.session.store orelse {
            self.okData(job.id, "get_tree", "{\"tree\":\"\",\"leafId\":null}") catch {};
            return;
        };
        const tree = st.renderTree(self.alloc) catch {
            self.fail(job.id, "get_tree", "render failed") catch {};
            return;
        };
        defer self.alloc.free(tree);
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"tree\":");
        try escape(&o, tree);
        try o.appendSlice(",\"leafId\":");
        if (st.leaf_id) |l| {
            try escape(&o, l);
        } else {
            try o.appendSlice("null");
        }
        try o.append('}');
        self.okData(job.id, "get_tree", o.items) catch {};
    }

    fn cmdLastAssistantText(self: *Rpc, job: *const Job) !void {
        // Owned copy: a pointer into a per-iteration buffer would dangle
        // once the loop frees it.
        var last: ?[]u8 = null;
        defer {
            if (last) |l| self.alloc.free(l);
        }
        for (self.session.context.messages.items) |m| {
            if (m.role != .assistant) continue;
            var parts = std.array_list.Managed(u8).init(self.alloc);
            defer parts.deinit();
            for (m.blocks.items) |b| switch (b) {
                .text => |t| parts.appendSlice(t) catch {},
                else => {},
            };
            if (parts.items.len > 0) {
                if (last) |l| self.alloc.free(l);
                last = parts.toOwnedSlice() catch null;
            }
        }
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"text\":");
        if (last) |t| {
            try escape(&o, t);
        } else {
            try o.appendSlice("null");
        }
        try o.append('}');
        self.okData(job.id, "get_last_assistant_text", o.items) catch {};
    }

    fn cmdSetSessionName(self: *Rpc, job: *const Job) !void {
        const name = job.text orelse {
            self.fail(job.id, "set_session_name", "missing \"name\"") catch {};
            return;
        };
        if (name.len == 0) {
            self.fail(job.id, "set_session_name", "session name cannot be empty") catch {};
            return;
        }
        const st = self.session.store orelse {
            self.fail(job.id, "set_session_name", "no session active") catch {};
            return;
        };
        st.setName(name);
        self.ok(job.id, "set_session_name") catch {};
    }

    fn cmdGetMessages(self: *Rpc, job: *const Job) !void {
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"messages\":[");
        for (self.session.context.messages.items, 0..) |m, i| {
            if (i > 0) try o.append(',');
            try o.appendSlice("{\"role\":\"");
            try o.appendSlice(@tagName(m.role));
            try o.appendSlice("\",\"blocks\":[");
            for (m.blocks.items, 0..) |b, j| {
                if (j > 0) try o.append(',');
                switch (b) {
                    .text => |t| {
                        try o.appendSlice("{\"type\":\"text\",\"text\":");
                        try escape(&o, t);
                        try o.append('}');
                    },
                    .thinking => |t| {
                        try o.appendSlice("{\"type\":\"thinking\",\"text\":");
                        try escape(&o, t);
                        try o.append('}');
                    },
                    .tool_call => |tc| {
                        try o.appendSlice("{\"type\":\"toolCall\",\"id\":");
                        try escape(&o, tc.id);
                        try o.appendSlice(",\"name\":");
                        try escape(&o, tc.name);
                        try o.appendSlice(",\"arguments\":");
                        // arguments is (nearly) always valid JSON; fall back
                        // to escaping when a streaming prefix slipped in.
                        if (std.json.parseFromSlice(std.json.Value, self.alloc, tc.arguments, .{})) |_| {} else |_| {
                            try escape(&o, tc.arguments);
                        }
                        try o.append('}');
                    },
                    .tool_result => |tr| {
                        try o.appendSlice("{\"type\":\"toolResult\",\"toolCallId\":");
                        try escape(&o, tr.tool_call_id);
                        try o.appendSlice(",\"content\":");
                        try escape(&o, tr.content);
                        try o.appendSlice(",\"isError\":");
                        try o.appendSlice(if (tr.is_error) "true" else "false");
                        try o.append('}');
                    },
                    .image => |img| {
                        try o.appendSlice("{\"type\":\"image\",\"mime\":");
                        try escape(&o, img.mime);
                        try o.append('}');
                    },
                }
            }
            try o.appendSlice("]}");
        }
        try o.appendSlice("]}");
        self.okData(job.id, "get_messages", o.items) catch {};
    }

    fn cmdGetCommands(self: *Rpc, job: *const Job) !void {
        // pi lists extension commands + prompt templates + skills. zpi's
        // equivalent: the built-in slash command set (no extension system).
        const builtins = [_][]const u8{
            "model", "thinking", "settings", "session", "name", "tree", "fork",
            "clone", "resume", "new", "compact", "export", "import", "copy",
            "share", "reload", "skill", "mcp", "trust", "login", "logout",
            "scoped-models", "hotkeys", "changelog",
        };
        var o = std.array_list.Managed(u8).init(self.alloc);
        defer o.deinit();
        try o.appendSlice("{\"commands\":[");
        for (builtins, 0..) |c, i| {
            if (i > 0) try o.append(',');
            try o.appendSlice("{\"name\":\"/");
            try o.appendSlice(c);
            try o.appendSlice("\"}");
        }
        try o.appendSlice("]}");
        self.okData(job.id, "get_commands", o.items) catch {};
    }
};
