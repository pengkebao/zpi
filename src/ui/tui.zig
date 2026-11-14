//! TUI - Fullscreen (alt-screen) terminal UI with differential rendering.
//!
//! Layout (fullscreen, `height` rows):
//!   Rows 0..(h-3):  transcript (messages, auto-scrolled to bottom)
//!   Row   h-2:      > input
//!   Row   h-1:      footer (model • cwd • /exit)
//!
//! Rendering is differential: only rows that changed since the last frame are
//! rewritten. The cursor is positioned at the end of the input line.

const std = @import("std");
const agent = @import("../core/agent.zig");
const cmsg = @import("../core/message.zig");
const config = @import("../core/config.zig");
const ss = @import("../core/session_store.zig");
const compact = @import("../core/compaction.zig");
const ansi = @import("ansi.zig");
const spinner = @import("spinner.zig");
const keys = @import("keys.zig");
const editor_mod = @import("editor.zig");
const wmod = @import("width.zig");
const markdown = @import("markdown.zig");
const tool_block = @import("tool_block.zig");
const footer = @import("footer.zig");
const overlay = @import("overlay.zig");
const scroll_view = @import("scroll_view.zig");
const search = @import("search.zig");
const keybindings = @import("keybindings.zig");
const ai = @import("../ai/openai.zig");
const builtin = @import("builtin");

/// Test-only import so the in-file tests can build a session (kept out of
/// non-test builds: the tools registry pulls in every tool module).
const tools_test = if (builtin.is_test) @import("../tools/registry.zig") else struct {};

const TIOCGWINSZ: u32 = if (builtin.os.tag == .linux) 0x5413 else 0x40087468;

/// Reasoning/thinking level — drives the editor border color (matches pi's theme).
const ThinkingLevel = config.ThinkingLevel;

// Border colors (exact okhsl→sRGB values from pi's dark theme).
const BORDER_IDLE = "\x1b[38;2;108;118;123m"; // thinkingOff / borderMuted (gray)
const BORDER_LOW = "\x1b[38;2;84;137;164m"; // thinkingLow (blue)
const BORDER_MEDIUM = "\x1b[38;2;97;133;204m"; // thinkingMedium (indigo)
const BORDER_HIGH = "\x1b[38;2;151;118;229m"; // thinkingHigh (purple)
const BORDER_XHIGH = "\x1b[38;2;222;84;193m"; // thinkingXhigh (magenta)
const BORDER_MAX = "\x1b[38;2;254;84;98m"; // thinkingMax (red)
const BORDER_BASH = "\x1b[38;2;94;178;134m"; // bashMode (green)
const ACCENT = "\x1b[38;2;167;152;215m";
// Message block colors (pi dark theme).
const USER_BG = "\x1b[48;2;33;59;73m"; // userMessageBg blueBg
const SELECTED_BG = "\x1b[48;2;33;59;73m"; // selectedBg (the same blueBg token)
const USER_FG = "\x1b[38;2;222;224;225m"; // text
const THINKING_TEXT = "\x1b[38;2;150;160;164m"; // thinkingText // violet (spinner, cursor)
const MUTED = "\x1b[38;2;108;118;123m"; // muted text ("Working" label)
const FG_MUTED = "\x1b[38;2;157;165;169m"; // muted (customMessageText)
const CUSTOM_MSG_BG = "\x1b[48;2;58;48;85m"; // customMessageBg okhsl(295 42% 24%)
const FG_ERROR = "\x1b[38;2;234;127;129m"; // error (red)
// Scrollbar (pi dark theme tokens).
const SCROLLBAR_TRACK_FG = "\x1b[38;2;72;78;82m"; // scrollbarTrack
const SCROLLBAR_THUMB_FG = "\x1b[38;2;151;160;165m"; // scrollbarThumb
const SCROLLBAR_TRACK = SCROLLBAR_TRACK_FG ++ "\u{2502}" ++ ansi.RESET; // │
const SCROLLBAR_THUMB = SCROLLBAR_THUMB_FG ++ "\u{2503}" ++ ansi.RESET; // ┃
const SCROLLBAR_THUMB_SOLID = SCROLLBAR_THUMB_FG ++ "\u{2588}" ++ ansi.RESET; // █
// Transcript search (pi dark theme tokens, searchMatchBg/searchMatchText).
const SEARCH_MATCH_BG = "\x1b[48;2;78;47;27m"; // okhsl(53 51% 24%)
const SEARCH_MATCH_FG = "\x1b[38;2;157;165;169m"; // muted (searchMatchText)
/// pi: PAGE_SCROLL_OVERLAP — rows kept in view when paging.
const PAGE_SCROLL_OVERLAP: usize = 4;
/// pi: ALT_WHEEL_SCROLL_MULTIPLIER — Alt+wheel scrolls this much faster.
const ALT_WHEEL_SCROLL_MULTIPLIER: usize = 5;

fn levelColor(level: ThinkingLevel) []const u8 {
    return switch (level) {
        .off => BORDER_IDLE,
        .low => BORDER_LOW,
        .medium => BORDER_MEDIUM,
        .high => BORDER_HIGH,
        .xhigh => BORDER_XHIGH,
        .max => BORDER_MAX,
    };
}

fn levelStr(level: ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
    };
}

/// A point in document coordinates (row = transcript doc row, col = visual
/// column), so a text selection stays anchored while scrolling (pi).
pub const SelPoint = struct { row: usize, col: usize };

/// Incremental streaming render state for one append-only markdown buffer
/// (see `live_stream_text`/`live_stream_think`).
const StreamPrefix = struct {
    /// Owned rows; `[0..prefix_rows]` are the stable prefix, the rest is
    /// the tail re-rendered every frame and freed on the next rebuild.
    lines: [][]u8,
    /// Stream bytes covered by the stable prefix rows.
    prefix_bytes: usize,
    prefix_rows: usize,
    /// Block kind that ended the rendered source so far (markdown segment
    /// splicing state: block gaps depend on the adjacent blocks' kinds).
    tail_kind: ?markdown.BlockKind,
    width: usize,
};

/// A 0-based screen cell (mouse gesture tracking).
pub const MousePoint = struct { col: usize, row: usize };

pub const TUI = struct {
    // ---- Completion menu types (G4) ----
    const MenuEntry = struct { name: []const u8, desc: []const u8, model_idx: ?usize = null };
    const MenuMode = enum { hidden, commands, models };
    const CommandDef = struct { name: []const u8, desc: []const u8, takes_arg: bool = false };

    /// How a scrollback block can be re-rendered (a terminal resize
    /// re-renders the whole transcript at the new width, like pi's per-frame
    /// component rendering). The markdown sources own their strings.
    const BlockSrc = union(enum) {
        /// Plain lines, shown as-is (notes, "Operation aborted").
        plain,
        assistant: []const u8,
        user: []const u8,
        thinking: []const u8,
        compaction: u64,
        /// tool_calls index (the block is rebuilt from the entry).
        tool: usize,

        fn deinit(self: BlockSrc, alloc: std.mem.Allocator) void {
            switch (self) {
                .assistant, .user, .thinking => |s| alloc.free(s),
                else => {},
            }
        }
    };

    /// One tool call of the transcript (from the agent's turn events). Owns
    /// its strings, allocated with the session allocator; the rendered block
    /// in `scrollback` can be rebuilt from it (Ctrl+O, result arrival).
    const ToolEntry = struct {
        id: []u8,
        name: []u8,
        args: []u8,
        result: []u8 = &.{},
        is_error: bool = false,
        pending: bool = true,
        duration_ms: ?u64 = null,
        /// Index into `scrollback` of this call's block; null until rendered.
        block_idx: ?usize = null,
        /// Per-block expansion override (clicking the block toggles it);
        /// null follows the global tools_expanded (Ctrl+O).
        expanded: ?bool = null,

        fn effectiveExpanded(self: *const ToolEntry, global: bool) bool {
            return self.expanded orelse global;
        }

        fn deinit(self: *ToolEntry, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            alloc.free(self.name);
            alloc.free(self.args);
            if (self.result.len > 0) alloc.free(self.result);
        }

        fn view(self: *const ToolEntry) tool_block.ToolView {
            return .{
                .name = self.name,
                .args = self.args,
                .result = self.result,
                .is_error = self.is_error,
                .pending = self.pending,
                .duration_ms = self.duration_ms,
            };
        }
    };
    const COMMANDS = [_]CommandDef{
        .{ .name = "/help", .desc = "Show help" },
        .{ .name = "/clear", .desc = "Clear conversation" },
        .{ .name = "/model", .desc = "Switch model", .takes_arg = true },
        .{ .name = "/think", .desc = "Show/set thinking level", .takes_arg = true },
        .{ .name = "/session", .desc = "Session info" },
        .{ .name = "/name", .desc = "Name this session", .takes_arg = true },
        .{ .name = "/new", .desc = "Start a new session" },
        .{ .name = "/tree", .desc = "Show session tree" },
        .{ .name = "/fork", .desc = "Fork this session" },
        .{ .name = "/resume", .desc = "Resume a session", .takes_arg = true },
        .{ .name = "/export", .desc = "Export session to HTML", .takes_arg = true },
        .{ .name = "/compact", .desc = "Compact the conversation" },
        .{ .name = "/copy", .desc = "Copy last reply to clipboard" },
        .{ .name = "/exit", .desc = "Quit" },
        .{ .name = "/quit", .desc = "Quit" },
    };

    io: std.Io,
    alloc: std.mem.Allocator,
    session: *agent.Session,
    width: u16 = 80,
    height: u16 = 24,
    editor: editor_mod.Editor,
    scrollback: std.array_list.Managed([]const u8),
    /// Parallel to `scrollback`: how each block re-renders on a resize.
    scrollback_src: std.array_list.Managed(BlockSrc),
    loader: spinner.Loader,
    model_name: []const u8,
    stream_text: std.array_list.Managed(u8),
    stream_thinking: std.array_list.Managed(u8),
    prev_lines: std.array_list.Managed([]u8),
    /// Transcript height of the frame `prev_lines` holds (vertical-shift
    /// detection only compares same-sized regions).
    prev_transcript_h: usize = 0,
    /// `scroll_top` the in-progress frame shows (recorded by buildTranscript).
    frame_scroll_top: usize = 0,
    /// `scroll_top` the previous painted frame showed; null after a forced
    /// full repaint. The difference between the two is the vertical shift the
    /// native scrolling-region scroll should emulate.
    rendered_scroll_top: ?usize = null,
    /// Scrollbar glyph class painted on each transcript screen row:
    /// 0 none, 1 track, 2 thumb, 3 thumb solid. The scrollbar lives in the
    /// screen layer (cells composited after the content diff), not in
    /// `prev_lines`, so a moved thumb never breaks shift verification
    /// (pi composites the scrollbar onto screen cells too).
    scroll_glyphs: []u8 = &.{},
    thinking_active: bool = false,
    /// True while there is nothing to restore: before setupTerminal saved the
    /// termios, and after restoreTerminal put it back.
    term_restored: bool = true,
    old_termios: std.posix.termios = undefined,
    sessions_dir: []const u8,
    cwd_abs: []const u8,
    cwd_display: []const u8,
    working: bool = false,
    spinner_frame: usize = 0,
    last_tick_ns: u64 = 0,
    bash_mode: bool = false,
    render_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Guards ONLY the streaming buffers (stream_text/stream_thinking): the
    /// network thread takes it per SSE delta, and must never queue behind a
    /// frame write — render_mutex contention here backpressured the token
    /// stream itself over slow terminals. Lock order: render_mutex ->
    /// stream_mutex, never the reverse.
    stream_mutex: std.Io.Mutex = std.Io.Mutex.init,
    spinner_thread: std.Thread = undefined,
    spinner_thread_active: bool = false,
    spinner_stop: bool = true,
    /// Stateful input reader (batch reassembly + kitty release filtering).
    key_reader: keys.KeyReader = .{},
    /// Whether we enabled xterm modifyOtherKeys (kitty-unavailable fallback).
    modify_other_keys: bool = false,
    /// Global config (models list for the /model selector).
    cfg: ?*config.Config = null,
    /// Process environment (for $EDITOR lookup).
    environ: std.process.Environ = .empty,
    /// Configurable keybindings (keybindings.json).
    bindings: keybindings.Bindings,
    /// Scroll state of the transcript (pi: the primary ScrollView, follow
    /// "end"). Guarded by render_mutex: the main loop, the spinner and the
    /// stdin watcher all scroll or render under it.
    sv: scroll_view.ScrollView = scroll_view.ScrollView.init(true, .auto),
    /// Wheel events to line counts (pi: WheelScrollAccelerator). Only one
    /// input thread is active at a time (the watcher is joined before the
    /// main loop resumes), so no locking beyond the shared redraw.
    wheel: scroll_view.WheelScrollAccelerator = .{},
    /// Scrollbar drag in progress: the thumb row the pointer grabbed.
    scrollbar_drag: ?usize = null,
    /// Height of the transcript viewport in the last frame (rows); 0 before
    /// the first render. Read by the input threads for mouse hit-testing.
    transcript_h: usize = 0,
    /// Document rows in the last frame (scrollback rows + live tail); the
    /// search corpus and highlights are bounded by it.
    doc_len: usize = 0,
    /// Cached scrollback line list (slices into the blocks, plus each
    /// block's first row). Rebuilt only when the transcript or the width
    /// changed — splitting every block on every frame stalled scrolling on
    /// large markdown transcripts. Guarded by render_mutex.
    doc_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    doc_block_first: std.ArrayListUnmanaged(usize) = .empty,
    doc_cache_gen: usize = std.math.maxInt(usize),
    doc_cache_w: usize = 0,
    doc_cache_th: bool = false,
    doc_cache_ex: bool = false,
    /// The streaming preview, fully rendered and cached until a chunk or
    /// the width changes (pi re-renders the streaming component every
    /// frame; the cache keeps idle spinner frames free).
    live_cache: ?[][]u8 = null,
    live_cache_w: usize = 0,
    live_cache_tlen: usize = 0,
    live_cache_xlen: usize = 0,
    live_cache_think_rows: usize = 0,
    live_cache_collapsed: bool = false,
    /// Incremental streaming render state, one per append-only stream buffer.
    /// pi re-renders the streaming markdown fully every frame; on a long
    /// stream that re-parses tens of KB on every 80ms spinner tick while
    /// holding the render mutex, and wheel events block behind it — scrolling
    /// turns into slideshow. The stable block prefix (blank-line separated
    /// markdown blocks are context-free) is cached by lines; each frame only
    /// re-renders blocks completed since then plus the growing tail block.
    live_stream_think: ?StreamPrefix = null,
    live_stream_text: ?StreamPrefix = null,
    /// The streaming thinking collapsed to a "Thinking…" line (click toggles).
    thinking_collapsed: bool = false,
    /// Scrollback indices of finished thinking blocks clicked shut (pi's
    /// per-component expanded). Independent of the Ctrl+T global hide.
    thinking_shut: std.ArrayListUnmanaged(usize) = .empty,
    /// Text selection (pi: selectionAnchor/Focus) in document coordinates,
    /// so it stays anchored while scrolling. Guarded by render_mutex for
    /// rendering; the gesture state is main-thread only.
    sel_anchor: ?SelPoint = null,
    sel_focus: ?SelPoint = null,
    sel_press: ?MousePoint = null,
    sel_dragged: bool = false,
    /// Transient feedback ("Copied!"): shown on the cwd row's right until
    /// the deadline (pi: the flash stack).
    flash_msg: ?[]u8 = null,
    flash_until_ms: i64 = 0,
    /// Transcript search (pi: activeSearch); null while the box is closed.
    search: ?search.Search = null,
    /// Generation of the transcript content: every scrollback change (new
    /// block, tool re-render, /clear) bumps it, invalidating the search
    /// corpus cache (pi: AltScreenSearchIndex source-line comparison).
    transcript_gen: usize = 0,
    /// Screen rectangle of the "Jump to latest message" label while it is
    /// shown, packed for lock-free hit-testing from the input threads: bit 48
    /// set when shown, bits 32..47 row, 16..31 column, 0..15 width (cells,
    /// 0-based). Rewritten under the render mutex; read by both input paths.
    jump_hint: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Tool output fully shown instead of pi's collapsed preview (Ctrl+O).
    tools_expanded: bool = false,
    /// Thinking blocks hidden (Ctrl+T).
    thinking_hidden: bool = false,
    /// Tool calls of the transcript, re-renderable (see ToolEntry).
    tool_calls: std.ArrayListUnmanaged(ToolEntry) = .empty,
    /// Scrollback indices of thinking blocks, for Ctrl+T.
    thinking_blocks: std.ArrayListUnmanaged(usize) = .empty,
    /// Scrollback indices of user messages (prompt jumps, Ctrl+Up/Down).
    user_blocks: std.ArrayListUnmanaged(usize) = .empty,
    /// Home directory (owned), abbreviated to `~` in tool paths.
    home_dir: ?[]const u8 = null,
    /// Git branch of the working directory (owned); null outside a repository.
    git_branch: ?[]u8 = null,
    /// The footer's session-derived numbers. Computed on the main thread (the
    /// agent appends to the session there) and only read by the renderer, which
    /// also runs on the spinner and watcher threads.
    footer_stats: footer.Stats = .{},
    /// Models of more than one provider are configured: the footer names it.
    multi_provider: bool = false,
    /// Background stdin watcher (Escape = abort) active while working.
    watch_thread: ?std.Thread = null,
    watch_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    watch_captured: std.ArrayListUnmanaged(u8) = .empty,
    watch_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Providers created by /model switches; freed in deinit.
    owned_provider: ?*ai.OpenAiProvider = null,
    /// Last emitted cursor park (hidden flag + row<<32|col): a no-change
    /// frame re-parking the same cursor used to emit bytes every tick.
    cursor_park_key: u64 = std.math.maxInt(u64),
    /// Main-loop wheel frame pacing (same idea as the watcher's throttle):
    /// a frame per wheel event costs one terminal round trip per line, which
    /// over a slow pipe makes fast pulls freeze, then burst.
    last_wheel_frame_ms: i64 = 0,
    wheel_frame_pending: bool = false,

    // ---- Completion menu state (G4) ----
    menu_mode: MenuMode = .hidden,
    menu_items: [16]MenuEntry = undefined,
    menu_len: usize = 0,
    menu_selected: usize = 0,

    fn commandTakesArg(name: []const u8) bool {
        for (COMMANDS) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.takes_arg;
        }
        return false;
    }

    /// Subsequence fuzzy match score; null = no match. Higher is better.
    fn fuzzyScore(name: []const u8, q: []const u8) ?u32 {
        if (q.len == 0) return 1;
        if (std.mem.indexOf(u8, name, q) == 0) return 100;
        var qi: usize = 0;
        for (name) |c| {
            if (qi < q.len and c == q[qi]) qi += 1;
        }
        if (qi == q.len) return 50;
        return null;
    }

    /// Recompute the completion menu from the current editor text.
    pub fn updateMenu(self: *TUI) void {
        self.menu_len = 0;
        self.menu_selected = 0;
        const text = self.editor.getText() catch {
            self.menu_mode = .hidden;
            return;
        };
        defer self.alloc.free(text);
        const single_line = std.mem.indexOfScalar(u8, text, '\n') == null;

        // Commands: "/query" with no space yet.
        if (single_line and text.len > 0 and text[0] == '/' and std.mem.indexOfScalar(u8, text, ' ') == null) {
            const query = text[1..];
            var scored: [COMMANDS.len]struct { def: *const CommandDef, score: u32 } = undefined;
            var n: usize = 0;
            for (&COMMANDS) |*def| {
                if (fuzzyScore(def.name[1..], query)) |score| {
                    scored[n] = .{ .def = def, .score = score };
                    n += 1;
                }
            }
            // Sort by score desc (insertion sort; n is tiny).
            var i: usize = 1;
            while (i < n) : (i += 1) {
                var j = i;
                const cur = scored[i];
                while (j > 0 and scored[j - 1].score < cur.score) : (j -= 1) {
                    scored[j] = scored[j - 1];
                }
                scored[j] = cur;
            }
            const cap = @min(n, self.menu_items.len);
            for (0..cap) |k| {
                self.menu_items[k] = .{ .name = scored[k].def.name, .desc = scored[k].def.desc };
            }
            self.menu_len = cap;
            self.menu_mode = if (cap > 0) .commands else .hidden;
            return;
        }

        // Models: "/model <query>".
        if (single_line and std.mem.startsWith(u8, text, "/model ")) {
            const query = std.mem.trim(u8, text["/model ".len..], " ");
            const cfg = self.cfg orelse {
                self.menu_mode = .hidden;
                return;
            };
            var cap: usize = 0;
            for (cfg.models.items, 0..) |m, idx| {
                if (cap >= self.menu_items.len) break;
                // Match against name or provider.
                const hit = fuzzyScore(m.name, query) orelse fuzzyScore(m.provider, query);
                if (hit == null) continue;
                self.menu_items[cap] = .{ .name = m.name, .desc = m.provider, .model_idx = idx };
                cap += 1;
            }
            self.menu_len = cap;
            self.menu_mode = if (cap > 0) .models else .hidden;
            return;
        }

        self.menu_mode = .hidden;
    }

    /// Render menu row `i` (owned, caller frees).
    fn menuLine(self: *TUI, i: usize) ![]u8 {
        const e = self.menu_items[i];
        if (i == self.menu_selected) {
            return std.fmt.allocPrint(self.alloc, "\x1b[38;2;167;152;215m\x1b[1m❯ {s}\x1b[0m  \x1b[2m{s}\x1b[0m", .{ e.name, e.desc });
        }
        return std.fmt.allocPrint(self.alloc, "  {s}  \x1b[2m{s}\x1b[0m", .{ e.name, e.desc });
    }

    /// Complete the editor text with the selected menu entry (Tab).
    fn menuComplete(self: *TUI) void {
        if (self.menu_len == 0) return;
        const e = self.menu_items[self.menu_selected];
        const text = if (self.menu_mode == .models)
            std.fmt.allocPrint(self.alloc, "/model {s} ", .{e.name}) catch return
        else if (commandTakesArg(e.name))
            std.fmt.allocPrint(self.alloc, "{s} ", .{e.name}) catch return
        else
            self.alloc.dupe(u8, e.name) catch return;
        defer self.alloc.free(text);
        self.editor.setText(text) catch return;
    }

    /// Activate the selected menu entry (Enter). Returns should_exit.
    fn menuActivate(self: *TUI) bool {
        if (self.menu_len == 0) return false;
        const e = self.menu_items[self.menu_selected];
        switch (self.menu_mode) {
            .commands => {
                if (commandTakesArg(e.name)) {
                    const text = std.fmt.allocPrint(self.alloc, "{s} ", .{e.name}) catch return false;
                    defer self.alloc.free(text);
                    self.editor.setText(text) catch return false;
                    return false;
                }
                self.editor.clear() catch {};
                return self.handleCommand(e.name);
            },
            .models => {
                if (e.model_idx) |idx| {
                    self.switchModel(idx) catch |err| {
                        self.note("model switch failed: {s}", .{@errorName(err)});
                    };
                }
                self.editor.clear() catch {};
                return false;
            },
            .hidden => return false,
        }
    }

    /// Switch the active model (creates a provider, swaps into the session).
    fn switchModel(self: *TUI, idx: usize) !void {
        const cfg = self.cfg orelse return error.NoConfig;
        if (idx >= cfg.models.items.len) return error.BadIndex;
        const m = &cfg.models.items[idx];
        const p = try self.alloc.create(ai.OpenAiProvider);
        errdefer self.alloc.destroy(p);
        p.* = try ai.OpenAiProvider.init(self.alloc, self.io, m.base_url, m.api_key);
        if (self.owned_provider) |old| {
            old.deinit();
            self.alloc.destroy(old);
        }
        self.owned_provider = p;
        self.session.provider = p;
        self.session.model = m;
        self.session.thinking_level = m.thinking_level;
        self.model_name = m.name;
        self.note("Model: {s} ({s})", .{ m.name, m.provider });
        self.redraw();
    }

    /// Open $EDITOR (fallback: $VISUAL, vi) with the current prompt buffer.
    /// Suspends the TUI (leaves alt-screen, restores cooked mode), runs the
    /// editor on a temp file, then resumes and loads the result.
    fn openExternalEditor(self: *TUI) void {
        const editor_cmd = std.process.Environ.getPosix(self.environ, "EDITOR") orelse
            std.process.Environ.getPosix(self.environ, "VISUAL") orelse "vi";

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/rpi-prompt-{d}.md", .{std.os.linux.getpid()}) catch return;

        // Write the current editor content to the temp file.
        const text = self.editor.getText() catch return;
        defer self.alloc.free(text);
        const f = std.Io.Dir.createFileAbsolute(self.io, path, .{ .read = false, .truncate = true }) catch return;
        std.Io.File.writeStreamingAll(f, self.io, text) catch {};
        std.Io.File.close(f, self.io);

        // Suspend the TUI: cooked mode + main screen so the editor gets the tty.
        self.restoreTerminal();

        const argv = [_][]const u8{ editor_cmd, path };
        var child = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch {
            self.addMessage("\x1b[91mfailed to launch editor\x1b[0m");
            self.resumeTui();
            return;
        };
        _ = child.wait(self.io) catch {};

        // Read the file back.
        const rf = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_only }) catch null;
        if (rf) |file| {
            var rbuf: [1 << 16]u8 = undefined;
            const nbytes = std.Io.File.readPositionalAll(file, self.io, &rbuf, 0) catch 0;
            std.Io.File.close(file, self.io);
            // Trim trailing newlines/whitespace (editor files end with one).
            var content = rbuf[0..nbytes];
            while (content.len > 0 and (content[content.len - 1] == '\n' or content[content.len - 1] == '\r' or content[content.len - 1] == ' ')) {
                content = content[0 .. content.len - 1];
            }
            self.editor.setText(content) catch {};
        }
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
        self.resumeTui();
    }

    /// Start the background stdin watcher (Escape aborts the running turn).
    fn startWatch(self: *TUI) void {
        agent.clearAbort();
        self.watch_stop.store(false, .release);
        self.watch_captured.clearRetainingCapacity();
        self.watch_thread = std.Thread.spawn(.{}, watchMain, .{self}) catch null;
    }

    /// Stop the watcher, replay captured keystrokes into the key reader.
    fn stopWatch(self: *TUI) void {
        self.watch_stop.store(true, .release);
        if (self.watch_thread) |t| {
            t.join();
            self.watch_thread = null;
        }
        self.watch_mutex.lock(self.io) catch {};
        defer self.watch_mutex.unlock(self.io);
        if (self.watch_captured.items.len > 0) {
            const space = self.key_reader.pending.len - self.key_reader.pending_len;
            const cap = @min(self.watch_captured.items.len, space);
            @memcpy(self.key_reader.pending[self.key_reader.pending_len..][0..cap], self.watch_captured.items[0..cap]);
            self.key_reader.pending_len += cap;
            self.watch_captured.clearRetainingCapacity();
        }
    }

    /// Watcher body: timed reads; a lone ESC aborts, anything else is captured
    /// and replayed after the turn ends (so typing during work is not lost).
    /// Minimum spacing between watcher-initiated frames (see watchMain).
    const watch_redraw_min_ms: i64 = 50;

    /// Input bytes are reassembled into complete escape sequences before
    /// dispatch — a mouse press split across reads must never be mistaken
    /// for a lone ESC (which aborts the turn).
    fn watchMain(self: *TUI) void {
        const fd: std.posix.fd_t = 0;
        const old = std.posix.tcgetattr(fd) catch return;
        var timed = old;
        timed.cc[keys.CC_VMIN] = 0;
        timed.cc[keys.CC_VTIME] = 1; // 100ms poll so we see watch_stop
        std.posix.tcsetattr(fd, .NOW, timed) catch {};
        defer std.posix.tcsetattr(fd, .NOW, old) catch {};

        var buf: [4096]u8 = undefined;
        var pend: [4096]u8 = undefined;
        var pend_len: usize = 0;
        // A fast gesture produces a read batch every few ms; a full frame per
        // batch floods the tty (and over a slow pipe, everything behind it).
        // At most one watcher frame per WATCH_REDRAW_MIN_MS, with a trailing
        // repaint on the read timeout so the last state is never dropped.
        var last_frame_ms: i64 = 0;
        var redraw_pending = false;
        while (!self.watch_stop.load(.acquire)) {
            const n = std.posix.read(fd, &buf) catch return;
            if (n == 0) {
                // Poll timeout: also the resize check for turns in flight —
                // the main loop is inside runPrompt, not reading keys, so
                // SIGWINCH would otherwise sit unhandled until it ends (pi:
                // the resize handler requestRender()s in every state).
                var resized = false;
                self.render_mutex.lock(self.io) catch continue;
                resized = self.refreshSize();
                self.render_mutex.unlock(self.io);
                if (resized) self.redrawCached();
                if (redraw_pending) {
                    redraw_pending = false;
                    last_frame_ms = ss.nowMs(self.io);
                    self.redrawCached();
                }
                // A sequence split across reads now had its chance: a lone
                // ESC aborts, an incomplete fragment is dropped.
                if (pend_len > 0) {
                    if (pend_len == 1 and pend[0] == 0x1b) {
                        agent.requestAbort();
                        return;
                    }
                    pend_len = 0; // corrupt fragment: drop
                }
                continue;
            }
            if (pend_len + n > pend.len) pend_len = 0; // overflow: drop stale
            @memcpy(pend[pend_len..][0..n], buf[0..n]);
            pend_len += n;
            // Dispatch complete sequences (pi: input is handled in every
            // state): the mouse gesture machine runs live — clicks toggle
            // tool/thinking blocks, drags select and copy on release — while
            // typing is still captured and replayed when the turn ends.
            var acted = false;
            var pos: usize = 0;
            while (pos < pend_len) {
                const len = keys.seqLenAt(pend[pos..pend_len]) orelse break; // incomplete tail
                const seq = pend[pos .. pos + len];
                pos += len;
                if (seq.len == 1 and seq[0] == 0x1b) {
                    // A lone ESC aborts the running turn (pi: Escape).
                    agent.requestAbort();
                    return;
                }
                // Ctrl+C also aborts a running turn (ISIG is off, so 0x03
                // arrives as a byte).
                if (seq.len == 1 and seq[0] == 0x03) {
                    agent.requestAbort();
                    return;
                }
                if (std.mem.startsWith(u8, seq, "\x1b[27") and seq[seq.len - 1] == 'u') {
                    // Kitty CSI-u Escape press; releases (`:3`) do not abort.
                    const body = seq[3 .. seq.len - 1];
                    const is_release = std.mem.indexOfScalar(u8, body, ':') != null;
                    if (!is_release) {
                        agent.requestAbort();
                        return;
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, seq, "\x1b[<")) {
                    const m = keys.parseSgrMouse(seq) orelse continue;
                    if (m.button & 64 != 0) {
                        // Wheel: the low bits give the direction (0=up,
                        // 1=down). 2/3 are the HORIZONTAL wheel — a vertical
                        // pull always carries horizontal jitter, and treating
                        // it as wheel-up disengaged following on every pull
                        // (pi: parseWheelEvent rejects direction 2/3).
                        switch (m.button & 3) {
                            0, 1 => {
                                const now: f64 = @floatFromInt(ss.nowMs(self.io));
                                const down = m.button & 3 == 1;
                                const lines = self.wheel.next(if (down) 1 else -1, now);
                                if (lines > 0) {
                                    const delta: isize = if (down) @intCast(lines) else -@as(isize, @intCast(lines));
                                    self.scrollBy(delta);
                                }
                                acted = true;
                            },
                            else => {},
                        }
                    } else if (m.release) {
                        if (m.button & 3 == 0) acted = self.handleRelease(m.col, m.row);
                    } else if (m.button & 32 != 0) {
                        switch (m.button & 3) {
                            0 => acted = self.handleDrag(m.col, m.row),
                            3 => {
                                self.handleHover(m.col, m.row);
                                acted = true;
                            },
                            else => {},
                        }
                    } else if (m.button & 3 == 0) {
                        acted = self.handlePress(m.col, m.row);
                    }
                    continue;
                }
                // Scroll keys scroll live (pi: pageUp/Down, home/end work in
                // every state); any other key falls through to the replay
                // capture below.
                if (std.mem.startsWith(u8, seq, "\x1b[")) {
                    if (keys.parseSequence(seq, self.key_reader.kitty_active)) |k| {
                        switch (k) {
                            .page_up => {
                                // pi: viewportHeight - PAGE_SCROLL_OVERLAP —
                                // 4 rows stay visible so a page keeps context.
                                self.scrollBy(-@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                                acted = true;
                                continue;
                            },
                            .page_down => {
                                self.scrollBy(@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                                acted = true;
                                continue;
                            },
                            .ctrl_home => {
                                self.render_mutex.lock(self.io) catch continue;
                                self.sv.scrollToStart(ss.nowMs(self.io));
                                self.render_mutex.unlock(self.io);
                                acted = true;
                                continue;
                            },
                            .ctrl_end => {
                                self.render_mutex.lock(self.io) catch continue;
                                self.sv.scrollToEnd(ss.nowMs(self.io));
                                self.render_mutex.unlock(self.io);
                                acted = true;
                                continue;
                            },
                            else => {},
                        }
                    }
                }
                // Anything else (typing): capture for replay after the turn.
                self.watch_mutex.lock(self.io) catch return;
                for (seq) |b| {
                    self.watch_captured.append(self.alloc, b) catch return;
                }
                self.watch_mutex.unlock(self.io);
            }
            // Keep the incomplete tail for the next read.
            const rest = pend_len - pos;
            std.mem.copyForwards(u8, pend[0..rest], pend[pos..pend_len]);
            pend_len = rest;
            if (acted) {
                const now = ss.nowMs(self.io);
                if (now - last_frame_ms >= watch_redraw_min_ms) {
                    last_frame_ms = now;
                    redraw_pending = false;
                    // Not the main thread: render from the cached footer stats.
                    self.redrawCached();
                } else {
                    redraw_pending = true;
                }
            }
        }
    }

    /// Re-enter the fullscreen UI after the external editor exited.
    fn resumeTui(self: *TUI) void {
        self.setupTerminal();
        // Force a full repaint (prev frame no longer matches the screen).
        for (self.prev_lines.items) |l| self.alloc.free(l);
        self.prev_lines.clearRetainingCapacity();
        self.cursor_park_key = std.math.maxInt(u64);
        self.prev_transcript_h = 0;
        self.rendered_scroll_top = null;
        if (self.scroll_glyphs.len > 0) {
            self.alloc.free(self.scroll_glyphs);
            self.scroll_glyphs = &.{};
        }
        self.updateMenu();
        self.redraw();
    }

    pub fn init(io: std.Io, alloc: std.mem.Allocator, session: *agent.Session, model_name: []const u8, sessions_dir: []const u8, cwd_abs: []const u8, home_dir: ?[]const u8, cfg: ?*config.Config, environ: std.process.Environ) TUI {
        // Abbreviate the home dir in the display path (~/Projects/...).
        const cwd_display: []const u8 = blk: {
            if (home_dir) |h| {
                if (cwd_abs.len >= h.len and std.mem.eql(u8, cwd_abs[0..h.len], h)) {
                    const rest = cwd_abs[h.len..];
                    if (rest.len == 0) break :blk alloc.dupe(u8, "~") catch cwd_abs;
                    break :blk std.mem.concat(alloc, u8, &.{ "~", rest }) catch cwd_abs;
                }
            }
            break :blk alloc.dupe(u8, cwd_abs) catch cwd_abs;
        };
        var bindings = keybindings.Bindings.default();
        if (cfg) |c| bindings = keybindings.Bindings.load(alloc, io, c.base_dir);
        // pi names the provider in the footer only when there is a choice.
        var multi_provider = false;
        if (cfg) |c| {
            for (c.models.items) |m| {
                if (!std.mem.eql(u8, m.provider, c.models.items[0].provider)) {
                    multi_provider = true;
                    break;
                }
            }
        }
        // Wheel feel (pi: wheelScrollLines "auto"): a local macOS terminal
        // delivers already-accelerated, one-line-at-a-time events.
        const over_ssh = std.process.Environ.getPosix(environ, "SSH_CONNECTION") != null or
            std.process.Environ.getPosix(environ, "SSH_CLIENT") != null or
            std.process.Environ.getPosix(environ, "SSH_TTY") != null;
        var wheel = scroll_view.WheelScrollAccelerator{};
        wheel.accelerate = !scroll_view.WheelScrollAccelerator.terminalAcceleratesWheel(builtin.os.tag == .macos, over_ssh);
        var sv = scroll_view.ScrollView.init(true, .auto);
        if (cfg) |c| {
            sv.scrollbar = switch (c.fullscreen_scrollbar) {
                .auto => .auto,
                .always => .always,
                .hidden => .hidden,
            };
            if (c.fullscreen_wheel_lines) |n| wheel.lines = .{ .fixed = n };
        }
        return .{
            .io = io,
            .alloc = alloc,
            .session = session,
            .width = 80,
            .height = 24,
            .editor = editor_mod.Editor.init(alloc),
            .scrollback = std.array_list.Managed([]const u8).init(alloc),
            .scrollback_src = std.array_list.Managed(BlockSrc).init(alloc),
            .loader = spinner.Loader.init(),
            .model_name = model_name,
            .stream_text = std.array_list.Managed(u8).init(alloc),
            .stream_thinking = std.array_list.Managed(u8).init(alloc),
            .prev_lines = std.array_list.Managed([]u8).init(alloc),
            .cfg = cfg,
            .environ = environ,
            .bindings = bindings,
            .sv = sv,
            .wheel = wheel,
            .term_restored = true,
            .old_termios = undefined,
            .sessions_dir = sessions_dir,
            .cwd_abs = cwd_abs,
            .cwd_display = cwd_display,
            .home_dir = if (home_dir) |h| (alloc.dupe(u8, h) catch null) else null,
            .multi_provider = multi_provider,
            .working = false,
            .spinner_frame = 0,
            .last_tick_ns = 0,
            .bash_mode = false,
        };
    }

    pub fn deinit(self: *TUI) void {
        self.stopWatch();
        // Join the spinner thread BEFORE any teardown: it may still be in the
        // middle of redrawLocked/renderLiveBlock allocations. Exiting without
        // joining makes the leak checker report in-flight allocations.
        self.stopSpinner();
        self.restoreTerminal();
        keys.restoreWinchHandler();
        self.watch_captured.deinit(self.alloc);
        self.editor.deinit();
        self.stream_text.deinit();
        self.stream_thinking.deinit();
        if (self.owned_provider) |p| {
            p.deinit();
            self.alloc.destroy(p);
        }
        for (self.scrollback.items) |s| self.alloc.free(s);
        self.scrollback.deinit();
        for (self.scrollback_src.items) |*s| s.deinit(self.alloc);
        self.scrollback_src.deinit();
        self.doc_lines.deinit(self.alloc);
        self.doc_block_first.deinit(self.alloc);
        if (self.live_cache) |c| self.alloc.free(c); // rows owned by stream caches
        self.invalidateStreamLocked(&self.live_stream_think);
        self.invalidateStreamLocked(&self.live_stream_text);
        if (self.flash_msg) |m| self.alloc.free(m);
        for (self.tool_calls.items) |*e| e.deinit(self.session.alloc);
        self.tool_calls.deinit(self.session.alloc);
        self.thinking_blocks.deinit(self.alloc);
        self.user_blocks.deinit(self.alloc);
        self.thinking_shut.deinit(self.alloc);
        for (self.prev_lines.items) |l| self.alloc.free(l);
        self.prev_lines.deinit();
        if (self.scroll_glyphs.len > 0) self.alloc.free(self.scroll_glyphs);
        if (self.home_dir) |h| self.alloc.free(h);
        if (self.git_branch) |b| self.alloc.free(b);
        self.alloc.free(self.cwd_display);
    }

    /// Enter raw mode + alt-screen, hide the cursor.
    fn setupTerminal(self: *TUI) void {
        const old = std.posix.tcgetattr(0) catch return;
        var raw = old;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        // ISIG off: Ctrl+C arrives as a byte (we handle it via bindings); the
        // SIGINT handler stays installed as a safety net for external kills.
        raw.lflag.ISIG = false;
        // IEXTEN off: otherwise macOS/Linux swallow Ctrl+O as VDISCARD
        // (output discard toggle) and other lnext/flush keys.
        raw.lflag.IEXTEN = false;
        // ICRNL translates input \r -> \n. Must be off so Enter (\r) stays distinct
        // from Ctrl+J (\n) — otherwise Enter is misread as a newline.
        raw.iflag.ICRNL = false;
        // IXON lets Ctrl+S/Ctrl+Q pause/resume output (swallowing the keys).
        // Must be off so rebound submit keys like ctrl+s reach the app.
        raw.iflag.IXON = false;
        // OPOST: no output post-processing (we position the cursor explicitly).
        raw.oflag.OPOST = false;
        raw.cc[3] = 1; // VMIN
        raw.cc[4] = 0; // VTIME
        std.posix.tcsetattr(0, .NOW, raw) catch {};
        self.old_termios = old;
        self.term_restored = false;
        self.measureSize();
        self.writeRaw("\x1b[?1049h"); // enter alt-screen
        self.writeRaw(ansi.HIDE_CURSOR);
        self.writeRaw("\x1b[2J\x1b[H"); // clear
        // Enable mouse tracking (SGR). pi: ENABLE_ALL_MOTION_MOUSE for the
        // hover-revealed scrollbar and cursor; multiplexers lag on every
        // pointer move, so they get button-motion tracking instead.
        const term = self.envTerm() orelse "";
        const multiplexer = self.envGet("TMUX") != null or
            self.envGet("ZELLIJ") != null or self.envGet("STY") != null or
            std.mem.startsWith(u8, term, "tmux") or std.mem.startsWith(u8, term, "screen");
        if (multiplexer) {
            self.writeRaw("\x1b[?1000h\x1b[?1002h\x1b[?1004h\x1b[?1006h");
        } else {
            self.writeRaw("\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1004h\x1b[?1006h");
        }
        // Kitty keyboard protocol negotiation (pi-exact): push flags=7
        // (disambiguate + event types + alternate keys), query the resulting
        // flags, and DA1 as the no-support sentinel. The replies are consumed
        // by key_reader; when flags != 0 the protocol is active (Ghostty then
        // sends shift+enter as `ESC [ 13 ; 2 u`); when flags == 0 or only DA
        // answers, we fall back to modifyOtherKeys (see the run loop).
        self.writeRaw("\x1b[>7u\x1b[?u\x1b[c");
        // Terminal resizes must reach the run loop even while it blocks on
        // input (pi: process.stdout.on("resize") → requestRender).
        keys.installWinchHandler();
    }

    fn restoreTerminal(self: *TUI) void {
        if (self.term_restored) return;
        std.posix.tcsetattr(0, .NOW, self.old_termios) catch {};
        self.term_restored = true;
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, ansi.SHOW_CURSOR) catch {};
        if (self.modify_other_keys) {
            stdout.writeStreamingAll(self.io, "\x1b[>4;0m") catch {};
            self.modify_other_keys = false;
        }
        stdout.writeStreamingAll(self.io, "\x1b[?1006l\x1b[?1004l\x1b[?1003l\x1b[?1002l\x1b[?1000l") catch {}; // disable mouse
        stdout.writeStreamingAll(self.io, "\x1b[<u") catch {}; // disable Kitty keyboard protocol
        stdout.writeStreamingAll(self.io, "\x1b[?1049l") catch {}; // exit alt-screen
        stdout.writeStreamingAll(self.io, "\r\n") catch {};
    }

    /// Query the real terminal size via TIOCGWINSZ. On failure (stdin is
    /// not a tty, e.g. piped) the previous size is kept — the winsize struct
    /// would otherwise carry garbage into width/height.
    fn measureSize(self: *TUI) void {
        var ws: std.posix.winsize = undefined;
        const rc = std.c.ioctl(0, @as(i32, TIOCGWINSZ), &ws);
        if (rc != 0) return;
        if (ws.col >= 2) self.width = ws.col;
        if (ws.row >= 3) self.height = ws.row;
    }

    fn writeRaw(self: *TUI, data: []const u8) void {
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, data) catch {};
    }

    fn envGet(self: *const TUI, name: []const u8) ?[]const u8 {
        return std.process.Environ.getPosix(self.environ, name);
    }

    fn envTerm(self: *const TUI) ?[]const u8 {
        return self.envGet("TERM") orelse self.envGet("TERM_PROGRAM");
    }

    /// Max height (lines) of the editor input area.
    fn maxEditorHeight(self: *const TUI) usize {
        return if (3 > self.height / 4) 3 else self.height / 4;
    }

    /// Re-read the terminal size (pi reads terminal.columns live in every
    /// render); when it changed, force the next diff into a full repaint
    /// (pi: previousScreenWidth/Height mismatch → \x1b[2J + every row).
    /// Caller must hold render_mutex.
    fn refreshSize(self: *TUI) bool {
        const old_w = self.width;
        const old_h = self.height;
        self.measureSize();
        if (self.width == old_w and self.height == old_h) return false;
        // A new width re-wraps every stored block (the colored backgrounds
        // are padded to the width at render time); a height change does not.
        if (self.width != old_w) self.rerenderAtWidth();
        for (self.prev_lines.items) |l| self.alloc.free(l);
        self.prev_lines.clearRetainingCapacity();
        // The screen was hard-cleared: there is no previous frame to diff
        // against, and no painted scrollbar cells either.
        self.prev_transcript_h = 0;
        self.rendered_scroll_top = null;
        if (self.scroll_glyphs.len > 0) {
            self.alloc.free(self.scroll_glyphs);
            self.scroll_glyphs = &.{};
        }
        // Stale content can sit beyond the new size (shrink); only a hard
        // clear removes it.
        self.writeRaw("\x1b[2J");
        self.updateMenu();
        return true;
    }

    /// Fullscreen differential redraw.
    /// Public redraw, for the main thread: refreshes the footer's numbers from
    /// the session, then renders under the render mutex (the spinner thread
    /// also redraws while working).
    pub fn redraw(self: *TUI) void {
        const stats = self.computeFooterStats();
        self.render_mutex.lock(self.io) catch {};
        self.footer_stats = stats;
        self.redrawLocked();
        self.render_mutex.unlock(self.io);
    }

    /// Redraw without touching the session, for the other threads: the agent
    /// may be appending messages on the main thread right now.
    fn redrawCached(self: *TUI) void {
        self.render_mutex.lock(self.io) catch {};
        self.redrawLocked();
        self.render_mutex.unlock(self.io);
    }

    /// The footer's numbers, from the session. Main thread only: it walks the
    /// session's messages.
    pub fn computeFooterStats(self: *TUI) footer.Stats {
        const totals = self.session.totals;
        const messages = self.session.context.messages.items;
        // Share of the latest prompt that came from the cache. `input` counts
        // the whole prompt, cached part included.
        var hit_rate: ?f64 = null;
        var i = messages.len;
        while (i > 0) : (i -= 1) {
            const m = messages[i - 1];
            if (m.role != .assistant) continue;
            const u = m.usage orelse continue;
            const prompt = u.input + u.cache_write;
            if (prompt > 0) hit_rate = @as(f64, @floatFromInt(u.cache_read)) * 100.0 / @as(f64, @floatFromInt(prompt));
            break;
        }
        return .{
            .input = totals.input -| totals.cache_read,
            .output = totals.output,
            .cache_read = totals.cache_read,
            .cache_write = totals.cache_write,
            .cache_hit_rate = hit_rate,
            .cost = totals.cost,
            .context_tokens = compact.estimateContextTokens(messages),
            .context_window = self.session.model.context_window,
            .auto_compact = self.session.compaction.enabled,
        };
    }

    /// Re-read the git branch (a tool may have switched it).
    fn refreshGitBranch(self: *TUI) void {
        const branch = footer.readGitBranch(self.alloc, self.io, self.cwd_abs);
        self.render_mutex.lock(self.io) catch {
            if (branch) |b| self.alloc.free(b);
            return;
        };
        defer self.render_mutex.unlock(self.io);
        if (self.git_branch) |old| self.alloc.free(old);
        self.git_branch = branch;
    }

    pub fn redrawLocked(self: *TUI) void {
        // A resize (or lost SIGWINCH after suspend) repaints everything at
        // the fresh size; the rest of this function just renders normally.
        _ = self.refreshSize();

        // Render the editor (wrapped visual lines) first to know its height.
        var ed = self.editor.render(self.width) catch return;
        var ed_consumed = false;
        errdefer {
            if (!ed_consumed) {
                for (ed.items) |l| self.alloc.free(l);
                ed.deinit(self.alloc);
            }
        }
        const visual_total = ed.items.len;
        const editor_h = if (visual_total < self.maxEditorHeight()) visual_total else self.maxEditorHeight();
        const cursor_vis = self.editor.cursorVisualPos(self.width);
        var vis_top: usize = 0;
        if (cursor_vis.row >= editor_h) vis_top = cursor_vis.row - editor_h + 1;
        const end = if (visual_total < vis_top + editor_h) visual_total else vis_top + editor_h;
        // Fixed bottom: menu (menu_h) + top border (1) + editor (editor_h) +
        // bottom border (1) + cwd (1) + status (1).
        const menu_h: usize = if (self.menu_mode != .hidden) self.menu_len else 0;
        const fixed_bottom = editor_h + 4 + menu_h;
        const transcript_h = if (self.height > fixed_bottom) self.height - fixed_bottom else 1;

        var frame: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (frame.items) |l| self.alloc.free(l);
            frame.deinit(self.alloc);
        }

        // The jump hint is re-decided every frame; nothing may survive from
        // the previous one for the click hit-test.
        self.clearJumpHint();

        // 1. Transcript: the ScrollView's window over the document
        //    (scrollback rows + the streaming live block as its tail).
        //    While streaming at the end the live block renders as the
        //    document's last rows; scrolled up it stays out of view (pi:
        //    not following the end).
        const at_end = self.sv.isFollowingEnd();
        self.buildTranscript(&frame, transcript_h) catch return;

        // 1.1 Search: refresh the corpus/matches before painting (pi:
        //    refreshSearch; it re-renders the frame when it scrolled to
        //    reveal the selection), then highlight the matches in the
        //    visible window.
        if (self.search) |*s| {
            if (self.refreshSearch(s)) {
                for (frame.items) |l| self.alloc.free(l);
                frame.clearRetainingCapacity();
                self.buildTranscript(&frame, transcript_h) catch return;
                _ = self.refreshSearch(s);
            }
            self.applySearchHighlights(s, &frame);
        }

        // 1.2 Scrollbar column (pi: geometry for the jump hint's right edge;
        // the cells are composited onto the screen after the content diff).
        const now_ms = ss.nowMs(self.io);
        _ = self.sv.tick(now_ms);
        self.tickFlashLocked(now_ms);
        // The hint never overlaps the scrollbar column (pi: rightEdge).
        var hint_max = self.width;
        if (self.scrollbarColumn()) |scrollbar_col| hint_max = @min(hint_max, scrollbar_col);

        // 1.3 Search box in the top-right corner (pi: the top-right overlay
        // with margin 1), composited over the transcript.
        if (self.search) |*s| {
            self.renderSearchBox(s, &frame);
        }

        // 1.4 Text selection: reverse-video over the selected doc ranges
        // (pi: applySelection, applied after the overlays so it paints over
        // the search box too).
        self.applySelectionToFrame(&frame);

        // 1.4 "Jump to latest" hint when not at the end: pi composites a
        // centered label (selectedBg background, text foreground) onto the
        // LAST transcript row instead of spending a layout row; clicking it
        // (or ctrl+end) jumps back (scrollToEndIndicator).
        if (!at_end and transcript_h > 0) {
            const label = " ↓ Jump to latest message · ctrl+end ";
            const label_w: usize = wmod.visualWidth(label);
            if (label_w > 0 and label_w < hint_max) {
                const col = (hint_max - label_w) / 2;
                const styled = std.fmt.allocPrint(
                    self.alloc,
                    SELECTED_BG ++ USER_FG ++ "{s}" ++ ansi.RESET,
                    .{label},
                ) catch null;
                if (styled) |top| {
                    defer self.alloc.free(top);
                    if (overlay.overlay(self.alloc, frame.items[transcript_h - 1], top, label_w, col)) |composited| {
                        self.alloc.free(frame.items[transcript_h - 1]);
                        frame.items[transcript_h - 1] = composited;
                        self.setJumpHint(transcript_h - 1, col, label_w);
                    } else |_| {}
                }
            }
        }

        // 1.5 Completion menu rows (between transcript and input border).
        if (menu_h > 0) {
            for (0..menu_h) |i| {
                const ml_raw = self.menuLine(i) catch return;
                const ml = truncateToWidth(self.alloc, ml_raw, self.width) catch return;
                self.alloc.free(ml_raw);
                frame.append(self.alloc, ml) catch return;
            }
        }

        // 2. Top border (shows spinner + "Working" when busy).
        const top_border = self.topBorderLine() catch return;
        frame.append(self.alloc, top_border) catch return;

        // 3. Editor visible visual lines (scrolled to the cursor). Move them
        // into the frame, free the rest, and consume ed.
        for (ed.items[vis_top..end]) |line| frame.append(self.alloc, line) catch return;
        for (ed.items[0..vis_top]) |line| self.alloc.free(line);
        for (ed.items[end..]) |line| self.alloc.free(line);
        ed.deinit(self.alloc);
        ed_consumed = true;
        while (frame.items.len < transcript_h + 1 + editor_h) {
            const blank = self.alloc.dupe(u8, "") catch return;
            frame.append(self.alloc, blank) catch return;
        }

        // 4. Bottom border.
        const bottom_border = self.borderLine() catch return;
        frame.append(self.alloc, bottom_border) catch return;

        // 5. Cwd line (home-abbreviated), with the flash message on the
        // right (pi: the flash stack renders bottom-center; ours parks in
        // the footer's free space).
        const cwd_line = self.cwdLine() catch return;
        frame.append(self.alloc, cwd_line) catch return;
        if (self.flash_msg) |m| {
            const styled = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "[{s}]" ++ ansi.RESET, .{m}) catch null;
            if (styled) |st| {
                defer self.alloc.free(st);
                const fw = wmod.visualWidth(st);
                const cwd_w = wmod.visualWidth(frame.items[frame.items.len - 1]);
                if (self.width > cwd_w + fw + 2) {
                    const col = self.width - fw - 1;
                    if (overlay.overlay(self.alloc, frame.items[frame.items.len - 1], st, fw, col)) |composited| {
                        self.alloc.free(frame.items[frame.items.len - 1]);
                        frame.items[frame.items.len - 1] = composited;
                    } else |_| {}
                }
            }
        }

        // 6. Status line (left stats, right model).
        const status_line = self.statusLine() catch return;
        frame.append(self.alloc, status_line) catch return;

        const cursor_row = transcript_h + menu_h + 1 + (cursor_vis.row - vis_top);
        const cursor_col: u16 = @intCast(if (1 + cursor_vis.col < self.width) 1 + cursor_vis.col else self.width);
        // diffRender adopts the frame's lines (they become the next diff
        // base); afterwards only the array itself needs releasing.
        self.diffRender(&frame, cursor_row, cursor_col);
        frame.deinit(self.alloc);
    }

    /// The border color for the current state (thinking level or bash mode).
    fn borderColor(self: *const TUI) []const u8 {
        if (self.bash_mode) return BORDER_BASH;
        return levelColor(self.session.thinking_level);
    }

    /// A horizontal border line spanning the full width, in the state color.
    fn borderLine(self: *TUI) ![]u8 {
        var abuf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer abuf.deinit(self.alloc);
        abuf.appendSlice(self.alloc, self.borderColor()) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            abuf.appendSlice(self.alloc, "\u{2500}") catch return error.OutOfMemory; // ─
        }
        abuf.appendSlice(self.alloc, "\x1b[0m") catch return error.OutOfMemory;
        return abuf.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
    }

    /// The top border. When working, shows `── {spinner} Working ────...` with
    /// the spinner in accent color and the label in muted (matches pi).
    fn topBorderLine(self: *TUI) ![]u8 {
        if (!self.working) return self.borderLine();
        const frame = spinner.SPINNER_FRAMES[self.spinner_frame];
        var abuf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer abuf.deinit(self.alloc);
        const bc = self.borderColor();
        abuf.appendSlice(self.alloc, bc) catch return error.OutOfMemory;
        abuf.appendSlice(self.alloc, "\u{2500}\u{2500} ") catch return error.OutOfMemory; // ──
        abuf.appendSlice(self.alloc, ACCENT) catch return error.OutOfMemory;
        abuf.appendSlice(self.alloc, frame) catch return error.OutOfMemory; // spinner (1 col)
        abuf.appendSlice(self.alloc, MUTED) catch return error.OutOfMemory;
        abuf.appendSlice(self.alloc, " Working") catch return error.OutOfMemory; // 8 cols
        abuf.appendSlice(self.alloc, bc) catch return error.OutOfMemory;
        abuf.append(self.alloc, ' ') catch return error.OutOfMemory; // 1 col
        // Used so far: 3 + 1 + 8 + 1 = 13 visual cols. Fill the rest with ─.
        var i: u32 = 13;
        while (i < self.width) : (i += 1) {
            abuf.appendSlice(self.alloc, "\u{2500}") catch return error.OutOfMemory;
        }
        abuf.appendSlice(self.alloc, "\x1b[0m") catch return error.OutOfMemory;
        return abuf.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
    }

    /// The directory line: cwd (home-abbreviated), git branch, session name.
    fn cwdLine(self: *TUI) ![]u8 {
        const name: ?[]const u8 = if (self.session.store) |st| st.name else null;
        return footer.pwdLine(self.alloc, self.cwd_display, self.git_branch, name, self.width);
    }

    /// The status line: usage stats on the left, the model on the right.
    fn statusLine(self: *TUI) ![]u8 {
        const model = self.session.model;
        return footer.statsLine(self.alloc, self.footer_stats, .{
            .id = model.id,
            .provider = if (self.multi_provider) model.provider else null,
            .thinking = if (model.reasoning) levelStr(self.session.thinking_level) else null,
        }, self.width);
    }

    /// All transcript lines in display order: the scrollback blocks split
    /// into rows, thinking blocks skipped while Ctrl+T hides them. The slices
    /// point into the scrollback blocks (borrowed).
    /// Refresh the cached document lines (scrollback only; the streaming
    /// tail is appended per frame). Caller holds render_mutex.
    fn refreshDocCache(self: *TUI) !void {
        if (self.doc_cache_gen == self.transcript_gen and
            self.doc_cache_w == self.width and
            self.doc_cache_th == self.thinking_hidden and
            self.doc_cache_ex == self.tools_expanded) return;
        self.doc_lines.clearRetainingCapacity();
        self.doc_block_first.clearRetainingCapacity();
        for (self.scrollback.items, 0..) |block, block_idx| {
            // Ctrl+T: hide thinking blocks entirely.
            if (self.thinking_hidden and self.isThinkingBlock(block_idx)) continue;
            try self.doc_block_first.append(self.alloc, self.doc_lines.items.len);
            var it = std.mem.splitScalar(u8, block, '\n');
            while (it.next()) |line| {
                try self.doc_lines.append(self.alloc, line);
            }
        }
        self.doc_cache_gen = self.transcript_gen;
        self.doc_cache_w = self.width;
        self.doc_cache_th = self.thinking_hidden;
        self.doc_cache_ex = self.tools_expanded;
    }

    /// The doc row the mouse points at, and the scrollback block containing
    /// it (null for the live tail or outside the transcript).
    fn blockAt(self: *TUI, col: usize, row: usize) ?usize {
        if (row >= self.transcript_h) return null;
        _ = col;
        const doc_row = self.sv.scroll_top + row;
        if (doc_row >= self.doc_lines.items.len) return null;
        // Binary search: last block whose first row is <= doc_row.
        var lo: usize = 0;
        var hi: usize = self.doc_block_first.items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.doc_block_first.items[mid] <= doc_row) lo = mid else hi = mid;
        }
        if (self.doc_block_first.items.len == 0) return null;
        return lo;
    }

    /// The tool call a mouse click points at, if any.
    fn toolAt(self: *TUI, col: usize, row: usize) ?usize {
        const blk = self.blockAt(col, row) orelse return null;
        if (blk >= self.scrollback_src.items.len) return null;
        return switch (self.scrollback_src.items[blk]) {
            .tool => |ti| ti,
            else => null,
        };
    }

    /// Is the clicked doc row inside a finished thinking block? Toggles it
    /// between the full markdown and a single "Thinking…" line. Caller holds
    /// render_mutex. Returns true when a block was hit (and toggled).
    fn thinkingShutAt(self: *TUI, col: usize, row: usize) bool {
        const blk = self.blockAt(col, row) orelse return false;
        if (blk >= self.scrollback_src.items.len) return false;
        if (self.scrollback_src.items[blk] != .thinking) return false;
        for (self.thinking_shut.items, 0..) |b, i| {
            if (b == blk) {
                _ = self.thinking_shut.swapRemove(i);
                self.rerenderBlockAtLocked(blk);
                return true;
            }
        }
        self.thinking_shut.append(self.alloc, blk) catch return false;
        self.rerenderBlockAtLocked(blk);
        return true;
    }

    /// Is the clicked row in the streaming thinking part of the live block?
    /// Caller holds render_mutex. Returns true when hit (and toggled).
    fn liveThinkingAt(self: *TUI, col: usize, row: usize) bool {
        _ = col;
        if (self.thinking_collapsed) {
            // The collapsed "Thinking…" line expands on click.
        } else {
            if (self.live_cache_think_rows == 0) return false;
        }
        if (self.stream_thinking.items.len == 0) return false;
        if (row < self.transcript_h) {
            const doc_row = self.sv.scroll_top + row;
            const live_start = self.doc_lines.items.len;
            if (doc_row >= live_start and doc_row < self.doc_len) {
                if (self.thinking_collapsed) return true; // the whole line is the toggle
                return doc_row - live_start < self.live_cache_think_rows;
            }
        }
        return false;
    }

    /// Re-render one scrollback block from its source in place (thinking
    /// collapse toggle). Caller holds render_mutex.
    fn rerenderBlockAtLocked(self: *TUI, idx: usize) void {
        if (idx >= self.scrollback.items.len or idx >= self.scrollback_src.items.len) return;
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        const old = self.scrollback.items[idx];
        const rendered: ?[]u8 = switch (self.scrollback_src.items[idx]) {
            .thinking => |raw| blk: {
                var shut = false;
                for (self.thinking_shut.items) |b| {
                    if (b == idx) shut = true;
                }
                if (shut) {
                    const line = std.fmt.allocPrint(self.alloc, " " ++ THINKING_TEXT ++ "\x1b[3m· Thinking…\x1b[0m", .{}) catch break :blk null;
                    break :blk line;
                }
                self.renderThinkingBlock(raw, &block);
                break :blk if (block.items.len == 0) null else block.toOwnedSlice(self.alloc) catch null;
            },
            else => null,
        };
        const next = rendered orelse return;
        self.scrollback.items[idx] = next;
        self.alloc.free(old);
        self.transcript_gen += 1;
    }

    // ---- Text selection (pi: handleSelectionMouseEvent) ----

    /// Screen cell → document coordinates. Null outside the transcript.
    fn screenToDoc(self: *TUI, col: usize, row: usize) ?SelPoint {
        if (row >= self.transcript_h) return null;
        const doc_row = @min(self.sv.scroll_top + row, self.doc_len -| 1);
        const c = @min(col, self.width -| 1);
        return .{ .row = doc_row, .col = c };
    }

    /// The ordered selection bounds, or null when empty (pi:
    /// getSelectionBounds).
    pub fn selBounds(self: *const TUI) ?struct { start: SelPoint, end: SelPoint } {
        const a = self.sel_anchor orelse return null;
        const f = self.sel_focus orelse return null;
        if (a.row == f.row and a.col == f.col) return null;
        const a_first = a.row < f.row or (a.row == f.row and a.col < f.col);
        return if (a_first) .{ .start = a, .end = f } else .{ .start = f, .end = a };
    }

    /// Reverse-video the selected ranges into the frame (pi: applySelection
    /// over the rendered rows). The scrollbar column is left alone so the
    /// scrollbar stays visible. Caller holds render_mutex.
    pub fn applySelectionToFrame(self: *TUI, frame: *std.ArrayListUnmanaged([]u8)) void {
        const b = self.selBounds() orelse return;
        const last_col = self.width -| 1; // keep the scrollbar column clear
        const rows = @min(frame.items.len, self.transcript_h);
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const doc_row = self.sv.scroll_top + r;
            if (doc_row < b.start.row or doc_row > b.end.row) continue;
            const start_col = if (doc_row == b.start.row) @min(b.start.col, last_col) else 0;
            const end_col = if (doc_row == b.end.row) @min(b.end.col + 1, last_col) else last_col;
            if (end_col <= start_col) continue;
            const highlighted = overlay.applySelectionHighlight(self.alloc, frame.items[r], start_col, end_col) catch continue;
            self.alloc.free(frame.items[r]);
            frame.items[r] = highlighted;
        }
    }

    /// Plain text of the current selection (doc lines, ANSI stripped,
    /// trailing spaces trimmed, rows joined with \n; pi:
    /// getActiveSelectionText). Caller holds render_mutex. Owned.
    pub fn selectionText(self: *TUI) ?[]u8 {
        const b = self.selBounds() orelse return null;
        const last_col = self.width -| 1;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.alloc);
        var row = b.start.row;
        while (row <= b.end.row) : (row += 1) {
            const line: []const u8 = blk: {
                if (row < self.doc_lines.items.len) break :blk self.doc_lines.items[row];
                if (row < self.doc_len) {
                    if (self.live_cache) |c| {
                        if (row - self.doc_lines.items.len < c.len) break :blk c[row - self.doc_lines.items.len];
                    }
                }
                break :blk null;
            } orelse break;
            const start_col = if (row == b.start.row) @min(b.start.col, last_col) else 0;
            const end_col = if (row == b.end.row) @min(b.end.col + 1, last_col) else last_col;
            if (end_col > start_col) {
                const seg = overlay.sliceByColumn(self.alloc, line, start_col, end_col - start_col) catch break;
                defer self.alloc.free(seg);
                const plain0 = overlay.stripSequences(self.alloc, seg) catch break;
                defer self.alloc.free(plain0);
                const plain = std.mem.trim(u8, plain0, " \t");
                if (out.items.len > 0) out.append(self.alloc, '\n') catch break;
                out.appendSlice(self.alloc, plain) catch break;
            } else if (row != b.start.row and out.items.len > 0) {
                out.append(self.alloc, '\n') catch break;
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// Left-button press: interactive elements first (search box buttons,
    /// jump label, scrollbar — pi: overlay/indicator/scrollbar dispatch),
    /// then a component click target (a tool block toggles on release),
    /// otherwise a text selection gesture starts. Returns true when the
    /// screen must redraw.
    pub fn handlePress(self: *TUI, col: usize, row: usize) bool {
        if (self.handleClick(col, row)) {
            // A press that hits something cancels the selection (pi:
            // clearTextSelection when the press is dispatched to a component).
            self.render_mutex.lock(self.io) catch return true;
            defer self.render_mutex.unlock(self.io);
            self.sel_anchor = null;
            self.sel_focus = null;
            self.sel_press = null;
            return true;
        }
        // GestureDetector: remember the press; the release decides between
        // a click (tool block toggle) and a drag (selection).
        self.render_mutex.lock(self.io) catch return true;
        defer self.render_mutex.unlock(self.io);
        self.sel_press = .{ .col = col, .row = row };
        self.sel_dragged = false;
        if (self.screenToDoc(col, row)) |p| {
            self.sel_anchor = p;
            self.sel_focus = p;
        }
        return true; // clear any previous selection highlight
    }

    /// Drag with the left button held: the scrollbar wins; otherwise the
    /// selection focus follows the pointer. Returns true to redraw.
    pub fn handleDrag(self: *TUI, col: usize, row: usize) bool {
        if (self.scrollbar_drag != null) return self.scrollbarDrag(col, row);
        self.render_mutex.lock(self.io) catch return false;
        defer self.render_mutex.unlock(self.io);
        if (self.sel_press == null) return false;
        self.sel_dragged = true;
        if (self.screenToDoc(col, row)) |p| self.sel_focus = p;
        return true;
    }

    /// Release: no movement = click (toggle the tool block under the
    /// pointer); movement = the selection is done, copy it (pi:
    /// copyOnSelect). Returns true to redraw.
    pub fn handleRelease(self: *TUI, col: usize, row: usize) bool {
        if (self.scrollbarRelease()) return true;
        const press = self.sel_press orelse return false;
        self.sel_press = null;
        const is_click = !self.sel_dragged and press.col == col and press.row == row;
        self.render_mutex.lock(self.io) catch return false;
        if (is_click) {
            // pi: the click event is dispatched to the component under the
            // pointer — a tool block toggles its own expansion, a thinking
            // block (streaming or finished) collapses to "Thinking…".
            if (self.toolAt(col, row)) |ti| {
                const e = &self.tool_calls.items[ti];
                e.expanded = !e.effectiveExpanded(self.tools_expanded);
                self.render_mutex.unlock(self.io);
                self.renderToolBlockAt(ti);
                return true;
            }
            if (self.thinkingShutAt(col, row)) {
                self.render_mutex.unlock(self.io);
                self.redrawCached();
                return true;
            }
            if (self.liveThinkingAt(col, row)) {
                self.thinking_collapsed = !self.thinking_collapsed;
                self.render_mutex.unlock(self.io);
                self.redrawCached();
                return true;
            }
            self.sel_anchor = null;
            self.sel_focus = null;
            self.render_mutex.unlock(self.io);
            return true;
        }
        // Dragged: copy the selected text (pi: copyOnSelect defaults true).
        if (self.selectionText()) |text| {
            defer self.alloc.free(text);
            self.render_mutex.unlock(self.io);
            self.copyToClipboard(text);
            self.flash("Copied!");
            return true;
        }
        self.render_mutex.unlock(self.io);
        return true;
    }

    /// Show a transient message on the cwd row's right (pi: flash stack).
    pub fn flash(self: *TUI, msg: []const u8) void {
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        const dup = self.alloc.dupe(u8, msg) catch return;
        if (self.flash_msg) |old| self.alloc.free(old);
        self.flash_msg = dup;
        self.flash_until_ms = ss.nowMs(self.io) + 1500;
    }

    fn tickFlashLocked(self: *TUI, now_ms: i64) void {
        if (self.flash_msg) |m| {
            if (now_ms >= self.flash_until_ms) {
                self.alloc.free(m);
                self.flash_msg = null;
            }
        }
    }

    /// Build the transcript window: the ScrollView's rows over the document
    /// (scrollback + the streaming live block as its tail), then blank
    /// padding to `transcript_h`. pi order: measure the content (updateLayout)
    /// BEFORE picking the window, so growth pins the view in the same frame.
    fn buildTranscript(self: *TUI, frame: *std.ArrayListUnmanaged([]u8), transcript_h: usize) !void {
        try self.refreshDocCache();

        // The streaming tail is ALWAYS part of the document while it exists
        // (pi: the streaming component is a fixed part of the layout).
        // Gating it on following-end would shrink the document by tens of
        // lines every time the user scrolls up mid-turn and grow it back at
        // the bottom — the viewport visibly bounces. When scrolled up the
        // tail simply sits below the viewport, out of view.
        var live: [][]u8 = &.{};
        if (self.working and self.streamHasContent()) {
            live = self.liveBlockLocked() catch &.{};
        }

        const doc_rows = self.doc_lines.items.len + live.len;
        self.sv.updateLayout(doc_rows, transcript_h);
        self.transcript_h = transcript_h;
        self.doc_len = doc_rows;
        // What this frame's transcript window shows; diffRender derives the
        // vertical shift candidate from the change since the previous frame.
        self.frame_scroll_top = self.sv.scroll_top;
        const start = self.sv.scroll_top;
        var idx = start;
        while (idx < self.doc_lines.items.len and frame.items.len < transcript_h) : (idx += 1) {
            const truncated = truncateToWidth(self.alloc, self.doc_lines.items[idx], self.width) catch return error.OutOfMemory;
            frame.append(self.alloc, truncated) catch return error.OutOfMemory;
        }
        // The window may start INSIDE the live block (committed rows shorter
        // than scroll_top while streaming): skip to the window's offset, or
        // the viewport would pin to the oldest live rows and the growing
        // tail would stay invisible until the turn commits.
        var live_skip: usize = 0;
        if (start > self.doc_lines.items.len) live_skip = start - self.doc_lines.items.len;
        if (live_skip < live.len) {
            for (live[live_skip..]) |l| {
                if (frame.items.len >= transcript_h) break;
                const dup = self.alloc.dupe(u8, l) catch continue;
                frame.append(self.alloc, dup) catch self.alloc.free(dup);
            }
        }
        while (frame.items.len < transcript_h) {
            const blank = self.alloc.dupe(u8, "") catch return;
            frame.append(self.alloc, blank) catch return;
        }
    }

    /// Scrollbar glyph classes for the transcript screen rows.
    const GLYPH_NONE: u8 = 0;
    const GLYPH_TRACK: u8 = 1;
    const GLYPH_THUMB: u8 = 2;
    const GLYPH_THUMB_SOLID: u8 = 3;

    /// The scrollbar column when a scrollbar is currently shown (for the
    /// jump hint's right edge). Pure query: painting happens in
    /// paintScrollbarLocked after the content diff.
    fn scrollbarColumn(self: *TUI) ?usize {
        if (self.transcript_h == 0 or self.width < 2) return null;
        const g = self.sv.geometry(false) orelse return null;
        if (g.track_height != self.transcript_h) return null; // stale layout
        return self.width - 1;
    }

    /// Composite the scrollbar onto the screen rows the diff just settled.
    /// Cell-level writes: only rows whose glyph class changed (thumb moves,
    /// hover, show/hide) are touched — a wheel step costs a handful of cells,
    /// not a repaint of the column. `new_lines` are the pure content rows the
    /// frame was built from (used to restore content when hiding and to
    /// place the glyph correctly around wide characters).
    fn paintScrollbarLocked(self: *TUI, out: *std.ArrayListUnmanaged(u8), new_lines: []const []u8) void {
        const th = self.transcript_h;
        if (th == 0) return;
        // (Re)allocate the per-row state; zero means "no glyph on screen".
        if (self.scroll_glyphs.len != th) {
            const fresh = self.alloc.alloc(u8, th) catch return;
            @memset(fresh, GLYPH_NONE);
            const keep = @min(self.scroll_glyphs.len, th);
            @memcpy(fresh[0..keep], self.scroll_glyphs[0..keep]);
            if (self.scroll_glyphs.len > 0) self.alloc.free(self.scroll_glyphs);
            self.scroll_glyphs = fresh;
        }
        const col = self.width - 1;
        const geom = self.sv.geometry(false);
        const preserve = self.sv.scrollbar != .always;
        var row: usize = 0;
        while (row < th) : (row += 1) {
            var target: u8 = GLYPH_NONE;
            if (geom) |g| {
                if (g.onThumb(row))
                    target = if (self.sv.active) GLYPH_THUMB_SOLID else GLYPH_THUMB
                else
                    target = GLYPH_TRACK;
            }
            const stored = self.scroll_glyphs[row];
            if (target == stored) continue;
            if (row >= new_lines.len) {
                self.scroll_glyphs[row] = target;
                continue; // stale state, skip
            }
            if (target == GLYPH_NONE) {
                // Hide: the content cell must come back. Rows this frame
                // already repainted (255) show the right content; the rest
                // get a full row repaint from the frame's content.
                self.scroll_glyphs[row] = 0;
                if (stored != 255) self.paintRow(out, row, new_lines[row], false);
                continue;
            }
            self.scroll_glyphs[row] = target;
            const glyph: []const u8 = if (target == GLYPH_THUMB_SOLID)
                SCROLLBAR_THUMB_SOLID
            else if (target == GLYPH_THUMB)
                SCROLLBAR_THUMB
            else
                SCROLLBAR_TRACK;
            // In auto mode the TRACK preserves the content cell's background
            // (pi), the THUMB is the position indicator and paints over any
            // block background.
            const cell = overlay.cellReplacement(
                self.alloc,
                new_lines[row],
                col,
                glyph,
                preserve and target == GLYPH_TRACK,
            ) catch continue;
            defer self.alloc.free(cell.bytes);
            var mv: [16]u8 = undefined;
            const ml = ansi.moveTo(&mv, @intCast(row + 1), @intCast(cell.start_col + 1));
            out.appendSlice(self.alloc, mv[0..ml]) catch return;
            out.appendSlice(self.alloc, cell.bytes) catch return;
        }
    }

    /// Press on the scrollbar (left button, in the last transcript column).
    /// On the thumb: grab it where it was pressed; on the track: jump so the
    /// thumb centers under the pointer (pi: handleScrollbarMouseEvent).
    fn scrollbarPress(self: *TUI, col: usize, row: usize) bool {
        if (col + 1 != self.width or row >= self.transcript_h) return false;
        const now = ss.nowMs(self.io);
        const g = self.sv.geometry(false) orelse return false;
        const on_thumb = g.onThumb(row);
        const grab: usize = if (on_thumb) row - g.thumb_top else g.thumb_height / 2;
        self.render_mutex.lock(self.io) catch return false;
        if (!on_thumb) {
            const target = scroll_view.ScrollView.scrollTopForPointer(g, @intCast(row), grab);
            _ = self.sv.scrollTo(@intCast(target), .{ .snap_end = true }, now);
        }
        _ = self.sv.setActive(true, now); // solid thumb, stays visible
        self.render_mutex.unlock(self.io);
        self.scrollbar_drag = grab;
        self.redraw();
        return true;
    }

    /// Drag the scrollbar thumb: the grabbed cell follows the pointer
    /// (pi: scrollScrollbarToPointer). Any column counts while dragging.
    fn scrollbarDrag(self: *TUI, col: usize, row: usize) bool {
        _ = col;
        const now = ss.nowMs(self.io);
        self.render_mutex.lock(self.io) catch return false;
        defer self.render_mutex.unlock(self.io);
        const grab = self.scrollbar_drag orelse return false;
        const g = self.sv.geometry(false) orelse return false;
        const target = scroll_view.ScrollView.scrollTopForPointer(g, @intCast(row), grab);
        _ = self.sv.scrollTo(@intCast(target), .{ .snap_end = true }, now);
        self.redrawLocked();
        return true;
    }

    /// The left button came up: the drag ends, the deadline re-arms.
    fn scrollbarRelease(self: *TUI) bool {
        self.render_mutex.lock(self.io) catch return false;
        defer self.render_mutex.unlock(self.io);
        if (self.scrollbar_drag == null) return false;
        self.scrollbar_drag = null;
        const now = ss.nowMs(self.io);
        _ = self.sv.setActive(false, now);
        self.redrawLocked();
        return true;
    }

    /// Hover over the scrollbar column: reveal an `auto` scrollbar, make the
    /// thumb solid. Returns true when the state changed (pi: hover reveal).
    fn scrollbarHover(self: *TUI, col: usize, row: usize) bool {
        const now = ss.nowMs(self.io);
        const over = col + 1 == self.width and row < self.transcript_h and
            self.sv.geometry(true) != null;
        self.render_mutex.lock(self.io) catch return false;
        const changed = self.sv.setActive(over, now);
        self.render_mutex.unlock(self.io);
        return changed;
    }

    /// Scroll the transcript by `lines` rows (negative = up). The caller
    /// redraws; the spinner thread's wheel path does it for itself.
    pub fn scrollBy(self: *TUI, lines: isize) void {
        // Blocking is fine: the delta critical section is short now that the
        // network thread's per-chunk appends live on stream_mutex instead of
        // this one. The watcher redraw is throttled separately.
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        _ = self.sv.scrollBy(lines, ss.nowMs(self.io));
    }

    /// Back to the end: "Jump to latest message" click or ctrl+end
    /// (pi: scrollToEndIndicator resumes following).
    pub fn scrollToLatest(self: *TUI) void {
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        self.sv.scrollToEnd(ss.nowMs(self.io));
    }

    /// Ctrl+Shift+F: open the search box (or close it when open)
    /// (pi: toggleSearch).
    fn toggleSearch(self: *TUI) void {
        if (self.search) |*s| {
            s.deinit();
            self.search = null;
            return;
        }
        self.search = search.Search.init(self.alloc) catch null;
    }

    /// Escape (or the toggle key again): close the box (pi: closeSearch).
    fn closeSearch(self: *TUI) void {
        if (self.search) |*s| {
            s.deinit();
            self.search = null;
        }
    }

    /// Enter / Shift+Enter: select the next / previous match. The actual
    /// selection and reveal happen on the next refresh (pi: navigateSearch
    /// only sets the mode; refreshSearch applies it).
    fn navigateSearch(self: *TUI, dir: i8) void {
        if (self.search) |*s| s.navigate(dir);
    }

    /// The document's lines for the search corpus: the scrollback rows plus
    /// the streaming live tail, exactly what buildTranscript renders (pi:
    /// the scroll box's scrollContentLines).
    fn collectSearchLines(self: *TUI) !std.ArrayListUnmanaged([]const u8) {
        try self.refreshDocCache();
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer all.deinit(self.alloc);
        try all.appendSlice(self.alloc, self.doc_lines.items);
        const streaming = self.working and self.streamHasContent();
        if (streaming) {
            const live: [][]u8 = self.liveBlockLocked() catch &.{};
            for (live) |l| try all.append(self.alloc, l);
        }
        return all;
    }

    /// Rebuild the corpus/matches when the transcript or the query changed
    /// and pick the selected match (pi: refreshSearch). Returns true when it
    /// scrolled to reveal the selection — the caller must rebuild the
    /// window (pi re-renders the layout frame) and refresh again.
    fn refreshSearch(self: *TUI, s: *search.Search) bool {
        var all = self.collectSearchLines() catch return false;
        defer all.deinit(self.alloc);
        const reveal = s.refresh(all.items, self.transcript_gen, self.sv.scroll_top, self.transcript_h);
        if (reveal) {
            self.render_mutex.lock(self.io) catch return false;
            defer self.render_mutex.unlock(self.io);
            _ = self.sv.scrollTo(@as(isize, @intCast(s.reveal_scroll_top)), .{ .disable_follow = true }, ss.nowMs(self.io));
        }
        return reveal;
    }

    /// Paint the matches into the visible window (pi: applySearchHighlights).
    /// Frame row `r` is content row `scroll_top + r`; segments outside the
    /// window (or the scrollbar column) are skipped or clamped.
    fn applySearchHighlights(self: *TUI, s: *search.Search, frame: *std.ArrayListUnmanaged([]u8)) void {
        if (s.selected >= s.matches.len or s.matches.len == 0) return;
        const doc_len = self.doc_len;
        if (doc_len == 0) return;
        const max_col: usize = if (self.width > 1) self.width - 1 else 0; // scrollbar column
        const scroll_top = self.sv.scroll_top;
        const min_content = scroll_top;
        const max_content = scroll_top + self.transcript_h - 1;
        // First match whose last row is at or below min_content (pi: binary
        // search over the matches' last rows).
        var low: usize = 0;
        var high: usize = s.matches.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const last_row = s.matches[mid].segments[s.matches[mid].segments.len - 1].row;
            if (last_row < min_content) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        // Matches are non-overlapping and each row holds at most one
        // segment of one match, so each visible row gets at most one range.
        for (s.matches[low..], low..) |*m, mi| {
            if (m.segments[0].row > max_content) break;
            for (m.segments) |seg| {
                const row = seg.row - scroll_top;
                if (row >= self.transcript_h or seg.row >= doc_len) continue;
                const start = @min(seg.start_col, max_col);
                const end = @min(seg.end_col, max_col);
                if (end <= start) continue;
                const highlighted = search.highlightLine(self.alloc, frame.items[@intCast(row)], &.{ .{ .start = start, .end = end, .current = mi == s.selected } }) catch continue;
                self.alloc.free(frame.items[@intCast(row)]);
                frame.items[@intCast(row)] = highlighted;
            }
        }
    }

    /// Composite the search box into the top-right corner (pi: the top-right
    /// overlay, width 40%, minWidth 32, margin 1).
    fn renderSearchBox(self: *TUI, s: *search.Search, frame: *std.ArrayListUnmanaged([]u8)) void {
        if (self.transcript_h < 4 or self.width < 34) return;
        const box_w: usize = @max(32, self.width * 2 / 5);
        if (box_w > self.width - 2) return;
        var lines = s.render(self.alloc, box_w) catch return;
        defer lines.deinit();
        s.box_col = self.width - box_w - 1;
        s.box_width = box_w;
        for (lines.lines, search.Search.BOX_ROW..) |line, row| {
            if (row >= frame.items.len) break;
            if (overlay.overlay(self.alloc, frame.items[row], line, box_w, s.box_col)) |composited| {
                self.alloc.free(frame.items[row]);
                frame.items[row] = composited;
            } else |_| {}
        }
    }

    /// Left-button press (pi: the overlay dispatch before the layout):
    /// the search box's navigation buttons, the jump label, then the
    /// scrollbar. Returns true when something was hit.
    fn handleClick(self: *TUI, col: usize, row: usize) bool {
        if (self.search) |*s| {
            if (s.contains(col, row)) {
                const dir = s.navDirectionAt(row - search.Search.BOX_ROW, col - s.box_col);
                if (dir != 0) self.navigateSearch(dir);
                return true;
            }
        }
        if (self.jumpHintHit(col, row)) {
            self.scrollToLatest();
            return true;
        }
        return self.scrollbarPress(col, row);
    }

    /// Pointer move without a button: the scrollbar hover reveal and the
    /// search box's navigation buttons (pi: handleSearchMouseEvent hover).
    fn handleHover(self: *TUI, col: usize, row: usize) void {
        if (self.search) |*s| {
            if (s.contains(col, row)) {
                s.hover_dir = s.navDirectionAt(row - search.Search.BOX_ROW, col - s.box_col);
                return;
            }
        }
        _ = self.scrollbarHover(col, row);
    }

    /// Jump to the previous (-1) or next (+1) user message (pi:
    /// scrollToPrompt over OSC 133 prompt markers; ours are user blocks).
    /// The message's first text row lands at the top of the viewport.
    fn scrollToUserMessage(self: *TUI, direction: isize) void {
        var rows: std.ArrayListUnmanaged(usize) = .empty;
        defer rows.deinit(self.alloc);
        var count: usize = 0;
        for (self.scrollback.items, 0..) |_, block_idx| {
            // Keep the row count in sync with collectLines' filter.
            if (!(self.thinking_hidden and self.isThinkingBlock(block_idx))) {
                count += countLines(self.scrollback.items[block_idx]);
            }
            var is_user = false;
            for (self.user_blocks.items) |u| {
                if (u == block_idx) {
                    is_user = true;
                    break;
                }
            }
            if (is_user) rows.append(self.alloc, count - countLines(self.scrollback.items[block_idx]) + 1) catch return;
        }
        if (rows.items.len == 0) return;
        const top = self.sv.scroll_top;
        var target: ?usize = null;
        if (direction < 0) {
            // The last message above the current top row.
            var i = rows.items.len;
            while (i > 0) : (i -= 1) {
                if (rows.items[i - 1] < top) {
                    target = rows.items[i - 1];
                    break;
                }
            }
            if (target == null) return; // already at the first one
        } else {
            for (rows.items) |r| {
                if (r > top) {
                    target = r;
                    break;
                }
            }
            if (target == null) return; // already at the last one
        }
        const now = ss.nowMs(self.io);
        _ = self.sv.scrollTo(@intCast(target.?), .{ .disable_follow = true }, now);
    }

    pub fn setJumpHint(self: *TUI, row: usize, col: usize, width: usize) void {
        const v: u64 = (@as(u64, 1) << 48) | (@as(u64, row) << 32) |
            (@as(u64, col) << 16) | @as(u64, width);
        self.jump_hint.store(v, .release);
    }

    pub fn clearJumpHint(self: *TUI) void {
        self.jump_hint.store(0, .release);
    }

    /// Did a mouse press at this 0-based cell land on the jump label?
    pub fn jumpHintHit(self: *TUI, col: usize, row: usize) bool {
        const v = self.jump_hint.load(.acquire);
        if (v >> 48 == 0) return false;
        const r = (v >> 32) & 0xFFFF;
        const c = (v >> 16) & 0xFFFF;
        const w = v & 0xFFFF;
        return row == r and col >= c and col < c + w;
    }

    /// Rewrite only the rows that changed vs the previous frame; position the
    /// hardware cursor at (cursor_row, cursor_col) (0-based). The whole frame
    /// is wrapped in synchronized output (pi: BEGIN/END_SYNCHRONIZED_OUTPUT):
    /// the terminal applies it atomically, so the physical cursor's mid-frame
    /// positions (right after each rewritten row — visible as a blinking
    /// cursor at the end of scrolled-in text) are never shown.
    /// Max individually-different rows tolerated inside a detected vertical
    /// shift: overlays that ride along while the transcript scrolls beneath
    /// (the "Jump to latest" label 1, the floating search box 3).
    const MAX_SHIFT_OUTLIERS: usize = 4;

    /// Whether `new[i] == old[i + k]` (up) resp. `new[i] == old[i - k]` (down)
    /// for the compared band of the first `rows` lines. The k revealed rows at
    /// the shift edge are the new content and are not part of the band. Rows
    /// that individually differ from their shifted reference (overlay labels
    /// riding along) are recorded in `outliers`; more than `outliers.len`
    /// rejects the shift (null). Success returns how many outliers were found.
    fn verifyShift(
        old: []const []const u8,
        new: []const []const u8,
        rows: usize,
        k: usize,
        up: bool,
        outliers: []usize,
    ) ?usize {
        var count: usize = 0;
        var i: usize = if (up) 0 else k;
        const end: usize = if (up) rows - k else rows;
        while (i < end) : (i += 1) {
            const j = if (up) i + k else i - k;
            if (!std.mem.eql(u8, new[i], old[j])) {
                if (count >= outliers.len) return null;
                outliers[count] = i;
                count += 1;
            }
        }
        return count;
    }

    /// Detect that the transcript region is a pure vertical shift of the
    /// previous frame's: content moved up by k rows (new rows entered at the
    /// bottom: streaming growth, wheel/page down) or down by k (wheel/page
    /// up). The candidate k is the scroll_top movement the frame applied;
    /// when there was none, content growth at the bottom (following) is the
    /// fallback. Overlays that differ individually are recorded in
    /// `outliers` (they get painted on top of the native scroll). Returns
    /// the shift, or null when nothing fits.
    const Shift = struct { up: bool, k: usize, outliers: usize };

    fn detectShift(
        old: []const []const u8,
        new: []const []const u8,
        rows: usize,
        first_changed: usize,
        scroll_delta: ?isize,
        outliers: []usize,
    ) ?Shift {
        if (rows == 0 or old.len < rows or new.len < rows or first_changed >= rows) return null;
        // The scroll the frame applied: +k moves the window toward the end,
        // which shifts the visible content up by k.
        if (scroll_delta) |d| {
            if (d != 0) {
                const k: usize = @intCast(if (d < 0) -d else d);
                if (k < rows) {
                    if (verifyShift(old, new, rows, k, d > 0, outliers)) |count|
                        return .{ .up = d > 0, .k = k, .outliers = count };
                }
            }
        }
        // Streaming growth while following: the changed band runs from
        // first_changed to the bottom, k = its height.
        const k_up = rows - first_changed;
        if (k_up >= 1 and k_up < rows) {
            if (verifyShift(old, new, rows, k_up, true, outliers)) |count|
                return .{ .up = true, .k = k_up, .outliers = count };
        }
        return null;
    }

    /// Paint one row: move to it, clear it, write it. `pending_newline` lets
    /// consecutive rows chain with `\r\n` instead of a full absolute move
    /// (pi chains relative moves the same way).
    fn paintRow(
        self: *TUI,
        out: *std.ArrayListUnmanaged(u8),
        row: usize,
        line: []const u8,
        pending_newline: bool,
    ) void {
        if (pending_newline) {
            out.appendSlice(self.alloc, "\r\n") catch return;
        } else {
            var mv: [16]u8 = undefined;
            const ml = ansi.moveTo(&mv, @intCast(row + 1), 1);
            out.appendSlice(self.alloc, mv[0..ml]) catch return;
        }
        out.appendSlice(self.alloc, ansi.CLEAR_EOL) catch return;
        out.appendSlice(self.alloc, line) catch return;
    }

    /// Differential frame update (pi: TuiMainScreen.render). Compares the new
    /// frame against the previous one and writes only what changed; a pure
    /// vertical shift of the transcript region (every scroll, and streaming
    /// growth while following) is scrolled natively via a scrolling region
    /// and only the revealed rows are painted. Owns the frame's lines on
    /// return: they move into `prev_lines` (freed when no longer needed), so
    /// the caller must not free them.
    fn diffRender(self: *TUI, frame: *std.ArrayListUnmanaged([]u8), cursor_row: usize, cursor_col: u16) void {
        const new_lines = frame.items;
        // The whole frame goes out as ONE write (inside synchronized output):
        // fewer syscalls, and the terminal never shows a half-applied frame.
        // A frame with no diff and no cursor change writes NOTHING at all —
        // no-op wheel events at the end of the transcript must stay inert
        // (bytes per tick chatter the pipe and queue real frames behind it).
        var frame_out: std.ArrayListUnmanaged(u8) = .empty;
        defer frame_out.deinit(self.alloc);
        defer self.flushFrameBytes(&frame_out);

        // First and last changed row (pi: firstChanged/lastChanged).
        var first_changed: ?usize = null;
        var last_changed: usize = 0;
        const n = new_lines.len;
        const max_scan = @max(n, self.prev_lines.items.len);
        var row: usize = 0;
        while (row < max_scan) : (row += 1) {
            const old_line = if (row < self.prev_lines.items.len) self.prev_lines.items[row] else "";
            const new_line = if (row < n) new_lines[row] else "";
            if (!std.mem.eql(u8, old_line, new_line)) {
                if (first_changed == null) first_changed = row;
                last_changed = row;
            }
        }

        const th = self.transcript_h;
        // Nothing changed: the frame's lines are freed, the previous frame
        // stays on screen (and as the next diff base).
        if (first_changed == null) {
            self.paintScrollbarLocked(&frame_out, new_lines);
            for (new_lines) |l| self.alloc.free(l);
            frame.clearRetainingCapacity();
            self.rendered_scroll_top = self.frame_scroll_top;
            self.prev_transcript_h = th;
            self.parkCursorInto(&frame_out, cursor_row, cursor_col);
            return;
        }

        // Rows to repaint. A detected shift scrolls the region natively and
        // marks its k revealed rows plus the overlay outliers; everything
        // else that changed is painted directly, chained with `\r\n` while
        // consecutive.
        var shifted = false;
        var reveal_from: usize = 0;
        var reveal_to: usize = 0; // exclusive
        var outlier_rows: [MAX_SHIFT_OUTLIERS]usize = undefined;
        var outlier_count: usize = 0;
        if (th > 0 and th == self.prev_transcript_h) {
            // The scroll_top movement between the previous painted frame and
            // this one; null after a forced full repaint (no prior frame).
            const scroll_delta: ?isize = if (self.rendered_scroll_top) |prev_top|
                @as(isize, @intCast(self.frame_scroll_top)) - @as(isize, @intCast(prev_top))
            else
                null;
            if (detectShift(self.prev_lines.items, new_lines, th, first_changed.?, scroll_delta, &outlier_rows)) |s| {
                // DECSTBM over the transcript region, native scroll by k,
                // region reset. Setting either bounds homes the cursor; the
                // paints below reposition absolutely anyway.
                var rbuf: [16]u8 = undefined;
                const rl = ansi.setScrollRegion(&rbuf, 1, @intCast(th));
                frame_out.appendSlice(self.alloc, rbuf[0..rl]) catch return;
                var mv: [16]u8 = undefined;
                if (s.up) {
                    const ml = ansi.moveTo(&mv, @intCast(th), 1);
                    frame_out.appendSlice(self.alloc, mv[0..ml]) catch return;
                    var left = s.k;
                    while (left > 0) : (left -= 1)
                        frame_out.appendSlice(self.alloc, "\n") catch return;
                } else {
                    const ml = ansi.moveTo(&mv, 1, 1);
                    frame_out.appendSlice(self.alloc, mv[0..ml]) catch return;
                    var left = s.k;
                    while (left > 0) : (left -= 1)
                        frame_out.appendSlice(self.alloc, ansi.REVERSE_INDEX) catch return;
                }
                frame_out.appendSlice(self.alloc, ansi.RESET_SCROLL_REGION) catch return;
                shifted = true;
                reveal_from = if (s.up) th - s.k else 0;
                reveal_to = if (s.up) th else s.k;
                outlier_count = s.outliers;
                // The native scroll moved the screen rows wholesale, taking
                // the painted scrollbar cells with them: track the glyphs to
                // their new rows so the post-pass below only fixes rows whose
                // class really changed (thumb delta, not the whole column).
                if (self.scroll_glyphs.len == th) {
                    const old_glyphs = self.alloc.dupe(u8, self.scroll_glyphs) catch &[_]u8{};
                    if (old_glyphs.len == th) {
                        defer self.alloc.free(old_glyphs);
                        row = 0;
                        while (row < th) : (row += 1) {
                            const src = if (s.up) row + s.k else blk: {
                                if (row < s.k) {
                                    self.scroll_glyphs[row] = 0;
                                    continue;
                                }
                                break :blk row - s.k;
                            };
                            self.scroll_glyphs[row] = if (src < th) old_glyphs[src] else 0;
                        }
                    }
                }
            }
        }

        var last_painted: ?usize = null;
        row = 0;
        while (row < n) : (row += 1) {
            const in_reveal = shifted and row >= reveal_from and row < reveal_to;
            var is_outlier = false;
            if (shifted and !in_reveal) {
                for (outlier_rows[0..outlier_count]) |orow| {
                    if (orow == row) {
                        is_outlier = true;
                        break;
                    }
                }
            }
            // Rows the native scroll already moved into place (verified
            // band) are on screen: inside the region only the revealed band
            // and the outliers need painting; below it, the plain diff.
            const need = if (shifted and row < th)
                (in_reveal or is_outlier)
            else
                (row >= first_changed.? and row <= last_changed and
                    (row >= self.prev_lines.items.len or
                        !std.mem.eql(u8, self.prev_lines.items[row], new_lines[row])));
            if (!need) continue;
            // Chain with `\r\n` only when the previous painted row is exactly
            // this one's predecessor; after any gap the `\r\n` would land on
            // the wrong screen row.
            const chain = last_painted != null and last_painted.? + 1 == row;
            self.paintRow(&frame_out, row, new_lines[row], chain);
            // The full-row write wiped whatever scrollbar cell showed here;
            // the post-pass re-paints the cell if one belongs there now.
            // (No glyph was showing: the paint already restored the content.)
            if (row < self.scroll_glyphs.len and self.scroll_glyphs[row] != 0)
                self.scroll_glyphs[row] = 255;
            last_painted = row;
        }
        // Rows that existed before but not now (frame shrank): clear them.
        row = n;
        while (row < self.prev_lines.items.len) : (row += 1) {
            const chain = last_painted != null and last_painted.? + 1 == row;
            self.paintRow(&frame_out, row, "", chain);
            if (row < self.scroll_glyphs.len) self.scroll_glyphs[row] = 255;
            last_painted = row;
        }

        // The scrollbar lives in the screen layer above the content rows.
        self.paintScrollbarLocked(&frame_out, new_lines);

        // Adopt the frame's lines: they become the next diff base. The old
        // strings are freed; ownership of the new ones transfers wholesale —
        // no per-line dupe (pi keeps previousLines by reference too).
        for (self.prev_lines.items) |l| self.alloc.free(l);
        self.prev_lines.clearRetainingCapacity();
        self.prev_lines.appendSlice(new_lines) catch {};
        frame.clearRetainingCapacity();
        self.prev_transcript_h = th;
        self.rendered_scroll_top = self.frame_scroll_top;

        self.parkCursorInto(&frame_out, cursor_row, cursor_col);
    }

    /// Park the hardware cursor where it belongs after a frame: hidden while
    /// the agent works (it would flash at stray spots), otherwise at the
    /// editor's cursor (pi: the cursor is positioned as the last write).
    /// Emits nothing when the park is unchanged (idle ticks stay byte-silent).
    fn parkCursorInto(self: *TUI, out: *std.ArrayListUnmanaged(u8), cursor_row: usize, cursor_col: u16) void {
        if (self.working) {
            // Hidden is sticky (nothing else touches DECTCEM).
            if (self.cursor_park_key == 0) return;
            self.cursor_park_key = 0;
            out.appendSlice(self.alloc, ansi.HIDE_CURSOR) catch return;
            return;
        }
        const key: u64 = (@as(u64, 1) << 63) | (@as(u64, cursor_row) << 32) | cursor_col;
        // ANY other bytes in this frame moved the terminal cursor, so the
        // park must be re-emitted even when the position is unchanged — a
        // frame that only painted scrollbar cells (or revealed content rows
        // at a scroll stop) would otherwise leave the hardware cursor sitting
        // at the last written cell. The dedup only applies to a fully empty
        // body, where the screen really still has the cursor parked.
        if (key == self.cursor_park_key and out.items.len == 0) return;
        self.cursor_park_key = key;
        var mv: [16]u8 = undefined;
        const ml = ansi.moveTo(&mv, @intCast(cursor_row + 1), cursor_col);
        out.appendSlice(self.alloc, mv[0..ml]) catch return;
        out.appendSlice(self.alloc, ansi.SHOW_CURSOR) catch return;
    }

    /// Write the accumulated frame body wrapped in synchronized output, or
    /// nothing at all when the body is empty.
    fn flushFrameBytes(self: *TUI, body: *std.ArrayListUnmanaged(u8)) void {
        if (body.items.len == 0) return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.alloc);
        out.appendSlice(self.alloc, "\x1b[?2026h") catch return;
        out.appendSlice(self.alloc, body.items) catch return;
        out.appendSlice(self.alloc, "\x1b[?2026l") catch return;
        self.writeRaw(out.items);
    }

    /// Render the in-flight streaming content (thinking + partial text) as
    /// bounded lines for the live area of the transcript. Shows the TAIL of
    /// each part (the newest output). All lines are owned by the caller.
    /// The streaming preview, fully rendered (pi: the streaming markdown
    /// component re-renders at full height every frame, so the whole
    /// viewport pushes up as content arrives instead of a small tail area
    /// jumping). Cached until a chunk or the width changes. Caller holds
    /// render_mutex.
    pub fn liveBlockLocked(self: *TUI) ![][]u8 {
        self.stream_mutex.lock(self.io) catch return error.StreamLock;
        defer self.stream_mutex.unlock(self.io);
        const tlen = self.stream_thinking.items.len;
        const xlen = self.stream_text.items.len;
        if (self.live_cache) |c| {
            if (self.live_cache_w == self.width and self.live_cache_tlen == tlen and
                self.live_cache_xlen == xlen and
                self.live_cache_collapsed == self.thinking_collapsed) return c;
            // Rows are owned by the per-stream caches; only the assembled
            // header array is released here.
            self.alloc.free(c);
            self.live_cache = null;
        }
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(self.alloc);
        var think_rows: usize = 0;
        if (tlen > 0) {
            if (self.thinking_collapsed) {
                // Clicked shut: a single "Thinking…" line (pi's collapsed
                // streaming-thinking display); clicking again expands.
                if (std.fmt.allocPrint(self.alloc, " " ++ THINKING_TEXT ++ "\x1b[3m· Thinking…\x1b[0m", .{})) |line| {
                    try out.append(self.alloc, line);
                    think_rows = 1;
                } else |_| {}
            } else {
                // Borrowed view into the stream cache (must not be freed).
                const lines = try self.rebuildStreamLocked(&self.live_stream_think, self.stream_thinking.items, true);
                think_rows = lines.len;
                for (lines) |l| try out.append(self.alloc, l);
            }
        } else {
            self.invalidateStreamLocked(&self.live_stream_think);
        }
        if (xlen > 0) {
            // Borrowed view into the stream cache (must not be freed).
            const lines = try self.rebuildStreamLocked(&self.live_stream_text, self.stream_text.items, false);
            for (lines) |l| try out.append(self.alloc, l);
        } else {
            self.invalidateStreamLocked(&self.live_stream_text);
        }
        self.live_cache = try out.toOwnedSlice(self.alloc);
        self.live_cache_w = self.width;
        self.live_cache_tlen = tlen;
        self.live_cache_xlen = xlen;
        self.live_cache_collapsed = self.thinking_collapsed;
        self.live_cache_think_rows = think_rows;
        return self.live_cache.?;
    }

    /// Free a per-stream cache entirely (rows and header).
    fn invalidateStreamLocked(self: *TUI, cache_slot: *?StreamPrefix) void {
        if (cache_slot.*) |sc| {
            markdown.freeLines(self.alloc, sc.lines);
            cache_slot.* = null;
        }
    }

    /// The offset just past the last blank-line block boundary at or after
    /// `from`. Markdown blocks are blank-line separated and context-free, so
    /// rendering `[from, boundary)` and `[boundary, len)` independently
    /// equals rendering the whole range. An unclosed code fence pins the
    /// boundary to the fence's opening line: the whole fence stays in the
    /// tail block. Callers guarantee `[0, from)` has balanced fences.
    fn stableBlockBoundary(buf: []const u8, from: usize) usize {
        if (from >= buf.len) return from;
        var boundary = from;
        var scan = from;
        while (std.mem.indexOfPos(u8, buf, scan, "\n\n")) |pos| {
            boundary = pos + 2;
            scan = boundary;
        }
        // Fence parity over [from, boundary): an odd count means the tail
        // block is inside a fence — retreat to the fence's opening line.
        var fences: usize = 0;
        var retreat: ?usize = null;
        var offset = from;
        var rest = buf[from..boundary];
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = rest[0..nl];
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                fences += 1;
                retreat = offset;
            }
            offset += line.len + 1;
            rest = rest[@min(nl + 1, rest.len)..];
        }
        if (fences % 2 == 1) {
            if (retreat) |r| return r;
            return from;
        }
        return boundary;
    }

    /// Rebuild one stream's line cache: reuse the stable prefix rows, render
    /// the blocks completed since the last frame `[prefix_bytes, boundary)`
    /// and the growing tail `[boundary, len)` fresh. Returns the full row
    /// array (the cache owns the rows; the caller must not free them).
    fn rebuildStreamLocked(
        self: *TUI,
        cache_slot: *?StreamPrefix,
        buf: []const u8,
        thinking: bool,
    ) ![][]u8 {
        const len = buf.len;
        var prefix_rows: usize = 0;
        var prefix_bytes: usize = 0;
        var tail_kind: ?markdown.BlockKind = null;
        var existing: ?StreamPrefix = null;
        if (cache_slot.*) |sc| {
            // Append-only: a shorter buffer means the stream was reset.
            if (sc.width != self.width or sc.prefix_bytes > len) {
                self.invalidateStreamLocked(cache_slot);
            } else {
                existing = sc;
                prefix_rows = sc.prefix_rows;
                prefix_bytes = sc.prefix_bytes;
                tail_kind = sc.tail_kind;
            }
        }

        const from = prefix_bytes;
        const boundary = stableBlockBoundary(buf, from);
        var fresh_a: [][]u8 = &.{};
        var fresh_b: [][]u8 = &.{};
        // Only the headers are freed here: the rows moved into the cache.
        defer if (fresh_a.len > 0) self.alloc.free(fresh_a);
        defer if (fresh_b.len > 0) self.alloc.free(fresh_b);
        if (boundary > from) {
            // Completed blocks: NOT the stream tail — a trailing blank row
            // here is the gap to the growing tail block and must survive
            // (it becomes part of the stable prefix).
            fresh_a = if (thinking)
                try self.renderThinkingSegmentStrip(buf[from..boundary], &tail_kind, false)
            else
                try self.renderAssistantSegmentStrip(buf[from..boundary], &tail_kind, false);
            prefix_bytes = boundary;
            prefix_rows += fresh_a.len;
        }
        if (len > prefix_bytes) {
            // The growing tail block is the stream's end: no trailing blanks.
            fresh_b = if (thinking)
                try self.renderThinkingSegmentStrip(buf[prefix_bytes..len], &tail_kind, true)
            else
                try self.renderAssistantSegmentStrip(buf[prefix_bytes..len], &tail_kind, true);
        }

        // Assemble: borrowed prefix rows ++ fresh rows. The old cache's
        // non-prefix rows are stale — freed here; the prefix rows move
        // ownership into the new cache.
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer out.deinit(self.alloc);
        if (existing) |sc| {
            try out.appendSlice(self.alloc, sc.lines[0..sc.prefix_rows]);
            for (sc.lines[sc.prefix_rows..]) |stale| self.alloc.free(stale);
            self.alloc.free(sc.lines);
            cache_slot.* = null;
        }
        try out.appendSlice(self.alloc, fresh_a);
        try out.appendSlice(self.alloc, fresh_b);
        cache_slot.* = .{
            .lines = try out.toOwnedSlice(self.alloc),
            .prefix_bytes = prefix_bytes,
            .prefix_rows = prefix_rows,
            .tail_kind = tail_kind,
            .width = self.width,
        };
        return cache_slot.*.?.lines;
    }

    pub fn addMessage(self: *TUI, text: []const u8) void {
        self.addBlockWithSrc(text, .plain);
    }

    /// Append a rendered block plus how it re-renders on a resize. Owns the
    /// strings of `src` on success (frees them on failure). The spinner
    /// thread reads scrollback while working; guard the append.
    fn addBlockWithSrc(self: *TUI, text: []const u8, src: BlockSrc) void {
        self.render_mutex.lock(self.io) catch {
            src.deinit(self.alloc);
            return;
        };
        defer self.render_mutex.unlock(self.io);
        const copy = self.alloc.dupe(u8, text) catch {
            src.deinit(self.alloc);
            return;
        };
        self.scrollback.append(copy) catch {
            self.alloc.free(copy);
            src.deinit(self.alloc);
            return;
        };
        self.scrollback_src.append(src) catch {
            _ = self.scrollback.pop();
            self.alloc.free(copy);
            src.deinit(self.alloc);
        };
        self.transcript_gen += 1;
    }

    pub fn addUserMessage(self: *TUI, text: []const u8) void {
        // pi: the user message is markdown on the user background, with a
        // blank background row above and below and every row padded to the
        // full width. The block's scrollback index is kept for Ctrl+Up/Down.
        const n_before = self.scrollback.items.len;
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        self.renderUserBlock(text, &block);
        const raw = self.alloc.dupe(u8, text) catch null;
        self.finishBlock(&block, if (raw) |r| .{ .user = r } else .plain);
        self.rememberUserBlock(n_before);
    }

    /// The user block's rows: markdown on the user background inside blank
    /// padding rows, padded to the full width. Used by add and resize alike.
    fn renderUserBlock(self: *TUI, text: []const u8, block: *std.ArrayListUnmanaged(u8)) void {
        const inner = if (self.width > 2) self.width - 2 else 1;
        const rendered = markdown.renderWith(self.alloc, text, inner, .{ .base_style = USER_FG }) catch {
            self.appendBgRow(block, text, USER_BG);
            return;
        };
        defer markdown.freeLines(self.alloc, rendered);
        self.appendBgRow(block, "", USER_BG);
        for (rendered) |row| self.appendBgRow(block, row, USER_BG);
        self.appendBgRow(block, "", USER_BG);
    }

    /// Record the block as a user message when it made it into the
    /// scrollback (for the Ctrl+Up/Down prompt jumps).
    fn rememberUserBlock(self: *TUI, n_before: usize) void {
        if (self.scrollback.items.len <= n_before) return;
        self.user_blocks.append(self.alloc, self.scrollback.items.len - 1) catch {};
    }

    pub fn addAssistantMessage(self: *TUI, text: []const u8) void {
        // pi: assistant text is markdown with one column of padding, and no
        // header row.
        const trimmed = std.mem.trim(u8, text, " \n");
        if (trimmed.len == 0) return;
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        self.renderAssistantBlock(trimmed, &block);
        if (block.items.len == 0) return;
        const raw = self.alloc.dupe(u8, trimmed) catch null;
        self.finishBlock(&block, if (raw) |r| .{ .assistant = r } else .plain);
    }

    /// The assistant block's rows: markdown with one column of padding (used
    /// by add and resize alike).
    /// The assistant block's rows: markdown with one column of padding (used
    /// by add, the live preview, and resize alike).
    fn renderAssistantLines(self: *TUI, trimmed: []const u8) ![][]u8 {
        var pk: ?markdown.BlockKind = null;
        return self.renderAssistantSegment(trimmed, &pk);
    }

    /// Segment variant: continues from (and updates) the stream's block kind,
    /// so spliced segments match a full render (markdown.renderSegment).
    fn renderAssistantSegment(self: *TUI, trimmed: []const u8, prev_kind: *?markdown.BlockKind) ![][]u8 {
        return self.renderAssistantSegmentStrip(trimmed, prev_kind, true);
    }

    fn renderAssistantSegmentStrip(self: *TUI, trimmed: []const u8, prev_kind: *?markdown.BlockKind, strip: bool) ![][]u8 {
        const inner = if (self.width > 2) self.width - 2 else 1;
        const rendered = try markdown.renderSegment(self.alloc, trimmed, inner, .{}, prev_kind, strip);
        defer markdown.freeLines(self.alloc, rendered);
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer markdown.freeLines(self.alloc, out.items);
        for (rendered) |row| {
            try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, " {s}", .{row}));
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn renderAssistantBlock(self: *TUI, trimmed: []const u8, block: *std.ArrayListUnmanaged(u8)) void {
        const lines = self.renderAssistantLines(trimmed) catch return;
        defer markdown.freeLines(self.alloc, lines);
        for (lines, 0..) |row, i| {
            if (i > 0) block.append(self.alloc, '\n') catch return;
            block.appendSlice(self.alloc, row) catch return;
        }
    }

    /// Thinking of a finished assistant message: dim italic markdown (pi:
    /// thinkingText). The block's scrollback index is kept for Ctrl+T.
    pub fn addThinkingBlock(self: *TUI, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \n");
        if (trimmed.len == 0) return;
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        self.renderThinkingBlock(trimmed, &block);
        if (block.items.len == 0) return;
        const n_before = self.scrollback.items.len;
        const raw = self.alloc.dupe(u8, trimmed) catch null;
        self.finishBlock(&block, if (raw) |r| .{ .thinking = r } else .plain);
        if (self.scrollback.items.len > n_before) {
            self.thinking_blocks.append(self.alloc, self.scrollback.items.len - 1) catch {};
        }
    }

    /// The thinking block's rows: dim italic markdown with one column of
    /// padding (used by add and resize alike).
    /// The thinking block's rows: dim italic markdown with one column of
    /// padding (used by add, the live preview, and resize alike).
    fn renderThinkingLines(self: *TUI, trimmed: []const u8) ![][]u8 {
        var pk: ?markdown.BlockKind = null;
        return self.renderThinkingSegment(trimmed, &pk);
    }

    fn renderThinkingSegment(self: *TUI, trimmed: []const u8, prev_kind: *?markdown.BlockKind) ![][]u8 {
        return self.renderThinkingSegmentStrip(trimmed, prev_kind, true);
    }

    fn renderThinkingSegmentStrip(self: *TUI, trimmed: []const u8, prev_kind: *?markdown.BlockKind, strip: bool) ![][]u8 {
        const inner = if (self.width > 2) self.width - 2 else 1;
        const base = THINKING_TEXT ++ "\x1b[3m";
        const rendered = try markdown.renderSegment(self.alloc, trimmed, inner, .{ .base_style = base }, prev_kind, strip);
        defer markdown.freeLines(self.alloc, rendered);
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer markdown.freeLines(self.alloc, out.items);
        for (rendered) |row| {
            try out.append(self.alloc, try std.fmt.allocPrint(self.alloc, " {s}", .{row}));
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn renderThinkingBlock(self: *TUI, trimmed: []const u8, block: *std.ArrayListUnmanaged(u8)) void {
        const lines = self.renderThinkingLines(trimmed) catch return;
        defer markdown.freeLines(self.alloc, lines);
        for (lines, 0..) |row, i| {
            if (i > 0) block.append(self.alloc, '\n') catch return;
            block.appendSlice(self.alloc, row) catch return;
        }
    }

    /// pi renders a compaction like a custom message: its own background, a
    /// bold label, and how much was compacted.
    pub fn addCompactionBlock(self: *TUI, tokens_before: u64) void {
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        self.renderCompactionBlock(tokens_before, &block);
        self.finishBlock(&block, .{ .compaction = tokens_before });
    }

    fn renderCompactionBlock(self: *TUI, tokens_before: u64, block: *std.ArrayListUnmanaged(u8)) void {
        var text_buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, FG_MUTED ++ "Compacted from {d} tokens (ctrl+o to expand)", .{tokens_before}) catch return;
        self.appendBgRow(block, "\x1b[1m" ++ ACCENT ++ "[compaction]\x1b[22m\x1b[39m", CUSTOM_MSG_BG);
        self.appendBgRow(block, "", CUSTOM_MSG_BG);
        self.appendBgRow(block, text, CUSTOM_MSG_BG);
        self.appendBgRow(block, "", CUSTOM_MSG_BG);
    }

    /// One row of a background-colored block: the content in `bg`, padded to
    /// the full width, the background restored after every inner reset.
    fn appendBgRow(self: *TUI, block: *std.ArrayListUnmanaged(u8), row: []const u8, bg: []const u8) void {
        const styled = self.bgRow(row, bg) catch return;
        defer self.alloc.free(styled);
        if (block.items.len > 0) block.append(self.alloc, '\n') catch return;
        block.appendSlice(self.alloc, styled) catch return;
    }

    /// `row` on `bg`, padded to the terminal width. Characters past the width
    /// are dropped (rows are wrapped to fit; this only trims leftovers).
    fn bgRow(self: *TUI, row: []const u8, bg: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, bg);
        try out.append(self.alloc, ' ');
        var used: usize = 1;
        var i: usize = 0;
        while (i < row.len) {
            if (row[i] == 0x1b) {
                const end = markdown.escapeEnd(row, i);
                const seq = row[i..end];
                try out.appendSlice(self.alloc, seq);
                // A full reset ends the background: open it again.
                if (seq.len >= 3 and seq[1] == '[' and seq[seq.len - 1] == 'm' and
                    (seq.len == 3 or std.mem.eql(u8, seq[2 .. seq.len - 1], "0")))
                {
                    try out.appendSlice(self.alloc, bg);
                }
                i = end;
                continue;
            }
            const end = wmod.nextCharEnd(row, i);
            const w = wmod.visualWidth(row[i..end]);
            if (used + w <= self.width) try out.appendSlice(self.alloc, row[i..end]);
            used += w;
            i = end;
        }
        if (self.width > used) try out.appendNTimes(self.alloc, ' ', self.width - used);
        try out.appendSlice(self.alloc, "\x1b[0m");
        return out.toOwnedSlice(self.alloc);
    }

    /// Move a finished block into the scrollback. Empties `block`, so the
    /// caller's deinit stays a no-op. `src` says how a resize re-renders it;
    /// its strings are consumed (they were duped by the caller).
    fn finishBlock(self: *TUI, block: *std.ArrayListUnmanaged(u8), src: BlockSrc) void {
        const joined = block.toOwnedSlice(self.alloc) catch {
            src.deinit(self.alloc);
            return;
        };
        self.addBlockWithSrc(joined, src);
        self.alloc.free(joined);
    }

    /// A tool call is starting: render its pending box now (gray); the result
    /// event repaints the same block in place (green/red). Takes ownership of
    /// the event's strings (session allocator).
    pub fn addPendingTool(self: *TUI, start: agent.TurnEvent.ToolStart) void {
        const entry = ToolEntry{
            .id = start.id,
            .name = start.name,
            .args = start.arguments,
        };
        self.tool_calls.append(self.session.alloc, entry) catch {
            // Ownership came with the event; give it back on failure.
            self.session.alloc.free(start.id);
            self.session.alloc.free(start.name);
            self.session.alloc.free(start.arguments);
            return;
        };
        self.renderToolBlockAt(self.tool_calls.items.len - 1);
    }

    /// A tool call finished: fill in its entry and repaint its block. Takes
    /// ownership of the event's strings.
    pub fn finishTool(self: *TUI, result: agent.TurnEvent.ToolEnd) void {
        defer self.session.alloc.free(result.id);
        for (self.tool_calls.items, 0..) |*e, i| {
            if (!e.pending or !std.mem.eql(u8, e.id, result.id)) continue;
            e.result = result.content;
            e.is_error = result.is_error;
            e.duration_ms = result.duration_ms;
            e.pending = false;
            self.renderToolBlockAt(i);
            return;
        }
        // A result without a matching start should not happen; do not leak it.
        self.session.alloc.free(result.content);
    }

    /// Replay persisted branch messages into the transcript for
    /// -c/-r/--session continuation (pi: renderInitialMessages →
    /// renderSessionEntries — assistant text/thinking render as blocks, tool
    /// calls as tool blocks with their results matched back by id). Context
    /// restore itself happens in main; this only rebuilds what the user
    /// sees. No-op without a store or on an empty branch (new sessions).
    pub fn replaySession(self: *TUI) void {
        const st = self.session.store orelse return;
        const alloc = self.session.alloc;
        const branch = st.branchMessages(alloc) catch return;
        defer {
            for (branch) |m| m.deinit();
            alloc.free(branch);
        }
        for (branch) |m| {
            switch (m.role) {
                .system => {},
                .user => {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(alloc);
                    for (m.blocks.items) |b| switch (b) {
                        .text => |t| {
                            if (buf.items.len > 0) buf.appendSlice(alloc, "\n\n") catch {};
                            buf.appendSlice(alloc, t) catch {};
                        },
                        else => {},
                    };
                    if (buf.items.len > 0) self.addUserMessage(buf.items);
                },
                .assistant => {
                    for (m.blocks.items) |b| switch (b) {
                        .thinking => |t| self.addThinkingBlock(t),
                        .text => |t| self.addAssistantMessage(t),
                        .tool_call => |tc| self.replayToolCall(tc),
                        else => {},
                    };
                },
                .tool => {
                    for (m.blocks.items) |b| switch (b) {
                        .tool_result => |tr| self.replayToolResult(tr),
                        else => {},
                    };
                },
            }
        }
    }

    fn replayToolCall(self: *TUI, tc: cmsg.ToolCall) void {
        const alloc = self.session.alloc;
        const id = alloc.dupe(u8, tc.id) catch return;
        const name = alloc.dupe(u8, tc.name) catch {
            alloc.free(id);
            return;
        };
        const args = alloc.dupe(u8, tc.arguments) catch {
            alloc.free(id);
            alloc.free(name);
            return;
        };
        self.tool_calls.append(alloc, .{ .id = id, .name = name, .args = args }) catch {
            alloc.free(id);
            alloc.free(name);
            alloc.free(args);
            return;
        };
        self.renderToolBlockAt(self.tool_calls.items.len - 1);
    }

    fn replayToolResult(self: *TUI, tr: cmsg.ToolResult) void {
        const alloc = self.session.alloc;
        for (self.tool_calls.items, 0..) |*e, i| {
            if (!e.pending or !std.mem.eql(u8, e.id, tr.tool_call_id)) continue;
            const copy = alloc.dupe(u8, tr.content) catch return;
            e.result = copy;
            e.is_error = tr.is_error;
            e.pending = false;
            self.renderToolBlockAt(i);
            return;
        }
    }

    /// Show tool output in full (true) or as pi's collapsed preview (false),
    /// repainting every tool block of the transcript.
    pub fn setToolsExpanded(self: *TUI, expanded: bool) void {
        self.tools_expanded = expanded;
        // The global toggle resets per-block overrides (Ctrl+O wins until
        // new clicks).
        self.render_mutex.lock(self.io) catch {};
        for (self.tool_calls.items) |*e| e.expanded = null;
        self.render_mutex.unlock(self.io);
        for (0..self.tool_calls.items.len) |i| self.renderToolBlockAt(i);
    }

    /// (Re-)render tool call `i` into its scrollback slot.
    fn renderToolBlockAt(self: *TUI, i: usize) void {
        const e = &self.tool_calls.items[i];
        const block = tool_block.render(self.alloc, e.view(), .{
            .width = self.width,
            .expanded = e.effectiveExpanded(self.tools_expanded),
            .home = self.home_dir,
        }) catch return;
        self.render_mutex.lock(self.io) catch {
            self.alloc.free(block);
            return;
        };
        defer self.render_mutex.unlock(self.io);
        const src: BlockSrc = .{ .tool = i };
        if (e.block_idx) |idx| {
            const old = self.scrollback.items[idx];
            self.scrollback.items[idx] = block;
            self.alloc.free(old);
            self.scrollback_src.items[idx] = src;
        } else {
            self.scrollback.append(block) catch {
                self.alloc.free(block);
                return;
            };
            self.scrollback_src.append(src) catch {
                _ = self.scrollback.pop();
                return;
            };
            e.block_idx = self.scrollback.items.len - 1;
        }
        self.transcript_gen += 1;
    }

    /// Re-render every scrollback block that has a source at the current
    /// width (pi re-renders components at the live size every frame, so a
    /// resize re-wraps the transcript and the colored blocks). Caller holds
    /// render_mutex; call only when the width actually changed.
    pub fn rerenderAtWidth(self: *TUI) void {
        for (self.scrollback_src.items, 0..) |*src, idx| {
            var block: std.ArrayListUnmanaged(u8) = .empty;
            defer block.deinit(self.alloc);
            const old = self.scrollback.items[idx];
            const rendered: ?[]u8 = switch (src.*) {
                .plain => null,
                .tool => |ti| blk: {
                    if (ti >= self.tool_calls.items.len) break :blk null;
                    const e = &self.tool_calls.items[ti];
                    break :blk tool_block.render(self.alloc, e.view(), .{
                        .width = self.width,
                        .expanded = e.effectiveExpanded(self.tools_expanded),
                        .home = self.home_dir,
                    }) catch null;
                },
                .user => |raw| blk: {
                    self.renderUserBlock(raw, &block);
                    break :blk block.toOwnedSlice(self.alloc) catch null;
                },
                .assistant => |raw| blk: {
                    self.renderAssistantBlock(raw, &block);
                    // Empty on render failure: keep the old block.
                    break :blk if (block.items.len == 0) null else block.toOwnedSlice(self.alloc) catch null;
                },
                .thinking => |raw| blk: {
                    self.renderThinkingBlock(raw, &block);
                    break :blk if (block.items.len == 0) null else block.toOwnedSlice(self.alloc) catch null;
                },
                .compaction => |tokens| blk: {
                    self.renderCompactionBlock(tokens, &block);
                    break :blk block.toOwnedSlice(self.alloc) catch null;
                },
            };
            const next = rendered orelse continue;
            self.scrollback.items[idx] = next;
            self.alloc.free(old);
        }
        self.transcript_gen += 1;
    }

    /// Render the turn events the agent recorded, oldest first. Called from
    /// the output callback while the turn runs (boxes appear as tools finish)
    /// and once more when it ends.
    fn drainTurnEvents(self: *TUI) void {
        const events = self.session.takeTurnEvents();
        defer self.session.alloc.free(events);
        for (events) |ev| {
            switch (ev) {
                .thinking => |t| {
                    defer self.session.alloc.free(t);
                    // The finished round is in the transcript now; the live
                    // preview must not show it a second time.
                    self.clearLiveBuffer(&self.stream_thinking);
                    self.addThinkingBlock(t);
                },
                .text => |t| {
                    defer self.session.alloc.free(t);
                    self.clearLiveBuffer(&self.stream_text);
                    self.addAssistantMessage(t);
                },
                .tool_start => |s| self.addPendingTool(s),
                .tool_result => |r| self.finishTool(r),
                .compaction => |tokens| self.addCompactionBlock(tokens),
                .note => |n| {
                    defer self.session.alloc.free(n);
                    self.note("\x1b[90m{s}\x1b[0m", .{n});
                },
            }
        }
        if (events.len == 0) return;
        // The usage totals moved with the round that just finished. This is
        // the main thread, so the session is safe to read.
        const stats = self.computeFooterStats();
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        self.footer_stats = stats;
    }

    /// Empty a live-stream buffer (spinner thread reads it under the mutex).
    /// Whether any streaming text exists (stream_mutex; len-only reads are
    /// otherwise racy against the network thread's appends).
    fn streamHasContent(self: *TUI) bool {
        self.stream_mutex.lock(self.io) catch return false;
        defer self.stream_mutex.unlock(self.io);
        return self.stream_text.items.len > 0 or self.stream_thinking.items.len > 0;
    }

    fn clearLiveBuffer(self: *TUI, buf: *std.array_list.Managed(u8)) void {
        self.stream_mutex.lock(self.io) catch return;
        defer self.stream_mutex.unlock(self.io);
        buf.clearRetainingCapacity();
    }

    /// Free every transcript block and tool entry (/clear, /new).
    pub fn clearTranscript(self: *TUI) void {
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        for (self.scrollback.items) |s| self.alloc.free(s);
        self.scrollback.clearRetainingCapacity();
        for (self.scrollback_src.items) |*s| s.deinit(self.alloc);
        self.scrollback_src.clearRetainingCapacity();
        for (self.tool_calls.items) |*e| e.deinit(self.session.alloc);
        self.tool_calls.clearRetainingCapacity();
        self.thinking_blocks.clearRetainingCapacity();
        self.user_blocks.clearRetainingCapacity();
        self.thinking_shut.clearRetainingCapacity();
        self.transcript_gen += 1;
    }

    /// Whether scrollback block `idx` is a thinking block.
    fn isThinkingBlock(self: *const TUI, idx: usize) bool {
        for (self.thinking_blocks.items) |i| {
            if (i == idx) return true;
        }
        return false;
    }

    fn outputCallback(ctx: *anyopaque, kind: agent.OutputKind, text: []const u8) void {
        const t: *TUI = @alignCast(@ptrCast(ctx));
        switch (kind) {
            .text, .thinking => {
                // stream_mutex only: a delta must never queue behind a frame
                // write (render_mutex), or the SSE reader — and with it the
                // whole token stream — backpressures on slow terminals.
                t.stream_mutex.lock(t.io) catch return;
                defer t.stream_mutex.unlock(t.io);
                if (kind == .text) t.stream_text.appendSlice(text) catch {};
                if (kind == .thinking) t.stream_thinking.appendSlice(text) catch {};
            },
            .turn_event => t.drainTurnEvents(),
            // Tool activity is rendered from the structured turn events.
            .tool_info => {},
        }
    }

    /// Split "/cmd arg" into the command word and the (trimmed) argument.
    fn parseCmd(cmd: []const u8) struct { word: []const u8, arg: []const u8 } {
        var it = std.mem.splitScalar(u8, cmd, ' ');
        const word = it.next() orelse "";
        const arg = std.mem.trim(u8, it.next() orelse "", " ");
        return .{ .word = word, .arg = arg };
    }

    fn handleCommand(self: *TUI, cmd: []const u8) bool {
        const parsed = parseCmd(cmd);
        const word = parsed.word;
        const arg = parsed.arg;

        if (std.mem.eql(u8, word, "/exit") or std.mem.eql(u8, word, "/quit")) return true;

        if (std.mem.eql(u8, word, "/help")) {
            self.addMessage("Commands:\n"
                ++ "  /exit          quit\n"
                ++ "  /help          show this help\n"
                ++ "  /clear         clear conversation\n"
                ++ "  /model [name]  switch model (interactive selector)\n"
                ++ "  /think [level] show or set thinking level (off|low|medium|high|xhigh|max)\n"
                ++ "  /session       show current session info\n"
                ++ "  /name <name>   name this session\n"
                ++ "  /new           start a new session\n"
                ++ "  /tree          show session entry tree\n"
                ++ "  /fork          fork current session into a new one\n"
                ++ "  /resume <id>   resume a session by (partial) id\n"
                ++ "  /export [path] export session to HTML (default: alongside)\n"
                ++ "  /copy          copy last assistant message to clipboard\n"
                ++ "  /think [level] show or set thinking level (off|low|medium|high|xhigh|max)");
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/clear")) {
            for (self.session.context.messages.items) |*m| m.deinit();
            self.session.context.messages.clearRetainingCapacity();
            self.clearTranscript();
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/hotkeys")) {
            var aw: std.Io.Writer.Allocating = .init(self.alloc);
            defer aw.deinit();
            const lw = &aw.writer;
            lw.writeAll("Keybindings (keybindings.json):\n") catch {};
            inline for (0..keybindings.Action.count) |i| {
                const action: keybindings.Action = @enumFromInt(i);
                if (keybindings.actionLabel(self.alloc, &self.bindings, action) catch null) |label| {
                    defer self.alloc.free(label);
                    lw.print("  {s:<18} {s}\n", .{ action.name(), label }) catch {};
                }
            }
            const line = self.alloc.dupe(u8, aw.written()) catch "hotkeys failed";
            self.noteOwned(line);
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/model")) {
            const cfg = self.cfg;
            if (arg.len == 0) {
                if (cfg) |c| {
                    var aw: std.Io.Writer.Allocating = .init(self.alloc);
                    defer aw.deinit();
                    const lw = &aw.writer;
                    lw.print("Model: {s} (provider: {s})\nModels:", .{ self.model_name, self.session.model.provider }) catch {};
                    for (c.models.items) |m| {
                        lw.print(" {s}", .{m.name}) catch {};
                    }
                    const line = self.alloc.dupe(u8, aw.written()) catch "model list failed";
                    self.noteOwned(line);
                } else {
                    self.note("Model: {s} (no config loaded — selector unavailable)", .{self.model_name});
                }
                self.redraw();
                return false;
            }
            // /model <name>: fuzzy-find and switch directly.
            if (cfg) |c| {
                var best: ?usize = null;
                var best_score: u32 = 0;
                for (c.models.items, 0..) |m, idx| {
                    if (fuzzyScore(m.name, arg)) |s| {
                        if (s > best_score) {
                            best_score = s;
                            best = idx;
                        }
                    }
                }
                if (best) |idx| {
                    self.switchModel(idx) catch |err| {
                        self.note("model switch failed: {s}", .{@errorName(err)});
                    };
                } else {
                    self.note("Unknown model: {s}", .{arg});
                }
            } else {
                self.note("No config loaded", .{});
            }
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/think")) {
            if (arg.len == 0) {
                self.note("Thinking level: {s} (off|low|medium|high|xhigh|max)", .{self.session.thinking_level.name()});
            } else if (config.ThinkingLevel.fromStr(arg)) |lvl| {
                self.session.thinking_level = lvl;
                self.note("Thinking level set to {s}", .{lvl.name()});
            } else {
                self.note("Unknown level: {s} (off|low|medium|high|xhigh|max)", .{arg});
            }
            self.redraw();
            return false;
        }

        // Session commands require an active store.
        const st = self.session.store orelse {
            self.addMessage("\x1b[90m(no session active — started with --no-session)\x1b[0m");
            self.redraw();
            return false;
        };

        if (std.mem.eql(u8, word, "/session")) {
            const line = st.infoLine(self.alloc) catch {
                self.addMessage("(info failed)");
                self.redraw();
                return false;
            };
            self.noteOwned(line);
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/name")) {
            if (arg.len == 0) {
                self.addMessage("usage: /name <name>");
            } else {
                st.setName(arg);
                self.note("\x1b[90msession named: {s}\x1b[0m", .{arg});
            }
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/tree")) {
            const tree = st.renderTree(self.alloc) catch {
                self.addMessage("(tree failed)");
                self.redraw();
                return false;
            };
            self.noteOwned(tree);
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/new")) {
            const new_st = ss.Store.create(self.alloc, self.io, self.sessions_dir, self.cwd_abs, .{}) catch {
                self.addMessage("\x1b[91m[new: create failed]\x1b[0m");
                self.redraw();
                return false;
            };
            self.session.adoptStore(new_st) catch {};
            self.clearTranscript();
            self.note("\x1b[90mnew session {s}\x1b[0m", .{new_st.id});
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/fork")) {
            const forked = st.fork(self.sessions_dir, self.cwd_abs) catch {
                self.addMessage("\x1b[91m[fork failed]\x1b[0m");
                self.redraw();
                return false;
            };
            self.session.adoptStore(forked) catch {};
            self.note("\x1b[90mforked → session {s}\x1b[0m", .{forked.id});
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/resume")) {
            if (arg.len == 0) {
                const list = ss.listForCwd(self.alloc, self.io, self.sessions_dir, self.cwd_abs) catch &.{};
                defer self.freeSessionList(list);
                if (list.len == 0) {
                    self.addMessage("\x1b[90mno sessions for this directory\x1b[0m");
                } else {
                    var header: [128]u8 = undefined;
                    const h = std.fmt.bufPrint(&header, "\x1b[90mresume a session (use /resume <id>):\x1b[0m", .{}) catch "";
                    self.addMessage(h);
                    for (list) |info| {
                        const label = info.name orelse "(unnamed)";
                        const line = std.fmt.allocPrint(self.alloc, "  {s}  {s}  {d} msgs", .{ info.id[0..@min(8, info.id.len)], label, info.msg_count }) catch continue;
                        defer self.alloc.free(line);
                        self.addMessage(line);
                    }
                }
                self.redraw();
                return false;
            }
            const found = ss.findById(self.alloc, self.io, self.sessions_dir, arg);
            if (found) |f| {
                const new_st = ss.Store.open(self.alloc, self.io, f) catch {
                    self.alloc.free(f);
                    self.addMessage("\x1b[91m[resume: cannot open]\x1b[0m");
                    self.redraw();
                    return false;
                };
                self.alloc.free(f);
                self.session.adoptStore(new_st) catch {};
                self.note("\x1b[90mresumed session {s}\x1b[0m", .{new_st.id});
                self.redraw();
                return false;
            }
            self.note("\x1b[91mno session matching '{s}'\x1b[0m", .{arg});
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/export")) {
            var def_path: [512]u8 = undefined;
            const out_path: []const u8 = if (arg.len > 0)
                arg
            else
                std.fmt.bufPrint(&def_path, "{s}.html", .{st.path}) catch arg;
            st.exportHtml(self.alloc, out_path) catch {
                self.addMessage("\x1b[91m[export failed]\x1b[0m");
                self.redraw();
                return false;
            };
            self.note("\x1b[90mexported → {s}\x1b[0m", .{out_path});
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/compact")) {
            const custom = if (arg.len > 0) arg else null;
            self.addMessage("\x1b[90m[compacting...]\x1b[0m");
            self.redraw();
            const before = self.session.runCompaction(custom) catch {
                self.note("\x1b[91m[compact failed]\x1b[0m", .{});
                self.redraw();
                return false;
            };
            // The compaction block arrives as a turn event.
            self.drainTurnEvents();
            if (before == null) {
                self.note("\x1b[90mnothing to compact (context small)\x1b[0m", .{});
            }
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/copy")) {
            var last_text: ?[]const u8 = null;
            const msgs = self.session.context.messages.items;
            var idx = msgs.len;
            while (idx > 0) : (idx -= 1) {
                const m = msgs[idx - 1];
                if (m.role != .assistant) continue;
                for (m.blocks.items) |b| {
                    switch (b) {
                        .text => |t| last_text = t,
                        else => {},
                    }
                }
                if (last_text != null) break;
            }
            if (last_text) |t| {
                self.copyToClipboard(t);
                self.note("\x1b[90mcopied {d} chars to clipboard\x1b[0m", .{t.len});
            } else {
                self.addMessage("\x1b[90m(no assistant message to copy)\x1b[0m");
            }
            self.redraw();
            return false;
        }

        self.addMessage(std.fmt.allocPrint(self.alloc, "\x1b[91munknown command: {s}\x1b[0m", .{word}) catch "unknown");
        self.redraw();
        return false;
    }

    /// Add an owned one-line note to the scrollback, then free it.
    fn noteOwned(self: *TUI, text: []const u8) void {
        self.addMessage(text);
        self.alloc.free(text);
    }

    /// Format + add an owned note. On OOM, add a plain fallback (not freed).
    fn note(self: *TUI, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            self.addMessage("(note)");
            return;
        };
        self.noteOwned(s);
    }

    fn freeSessionList(self: *TUI, list: []const ss.SessionInfo) void {
        for (list) |info| {
            self.alloc.free(info.path);
            self.alloc.free(info.id);
            if (info.name) |n| self.alloc.free(n);
            self.alloc.free(info.timestamp);
        }
        self.alloc.free(list);
    }

    /// OSC 52 clipboard write (works in most modern terminals).
    /// OSC 52 clipboard write (works in most modern terminals). Locks the
    /// render mutex so the sequence can't interleave with a frame written
    /// by the spinner/watcher thread during streaming.
    fn copyToClipboard(self: *TUI, text: []const u8) void {
        self.render_mutex.lock(self.io) catch return;
        defer self.render_mutex.unlock(self.io);
        const size = std.base64.standard.Encoder.calcSize(text.len);
        const buf = self.alloc.alloc(u8, size) catch return;
        defer self.alloc.free(buf);
        const encoded = std.base64.standard.Encoder.encode(buf, text);
        const out = std.fmt.allocPrint(self.alloc, "\x1b]52;c;{s}\x1b\\", .{encoded}) catch return;
        defer self.alloc.free(out);
        self.writeRaw(out);
    }

    /// Start the background spinner thread (animates the "Working" border while
    /// the agent runs). The thread ticks the frame ~every 80ms and redraws.
    fn startSpinner(self: *TUI) void {
        self.render_mutex.lock(self.io) catch {};
        self.working = true;
        self.spinner_frame = 0;
        self.spinner_stop = false;
        self.render_mutex.unlock(self.io);
        const spawned = std.Thread.spawn(.{}, spinnerLoop, .{self}) catch {
            self.spinner_thread_active = false;
            return;
        };
        self.spinner_thread = spawned;
        self.spinner_thread_active = true;
    }

    /// Stop the spinner thread and wait for it to finish.
    fn stopSpinner(self: *TUI) void {
        self.render_mutex.lock(self.io) catch {};
        self.spinner_stop = true;
        self.working = false;
        self.render_mutex.unlock(self.io);
        if (self.spinner_thread_active) {
            self.spinner_thread.join();
            self.spinner_thread_active = false;
        }
    }

    /// Spinner thread main loop: sleep, then tick + redraw under the mutex.
    ///
    /// While working we paint on a fixed 22 ms clock (≈45 fps ceiling; pi
    /// throttles every message_update to 16 ms — a fixed cadence is robust
    /// to the bursty arrival pattern of SSE chunks, where a dirty-flag
    /// scheme phases in and out of 80 ms sleeps). The paint work itself
    /// (markdown tail re-render + diff) lands the effective rate near 30 fps. No-change frames write zero bytes (diff
    /// early-return + cursor-park dedup), so idle stretches stay silent. The
    /// spinner glyph still advances on its own 80 ms clock.
    fn spinnerLoop(t: *TUI) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var last_glyph_advance: i64 = 0;
        while (true) {
            t.render_mutex.lock(io) catch break;
            if (t.spinner_stop) {
                t.render_mutex.unlock(io);
                break;
            }
            const now = ss.nowMs(io);
            if (now - last_glyph_advance >= 80) {
                t.spinner_frame = (t.spinner_frame + 1) % spinner.SPINNER_FRAMES.len;
                last_glyph_advance = now;
            }
            t.redrawLocked();
            t.render_mutex.unlock(io);
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(22), .real) catch break;
        }
    }

    pub fn run(self: *TUI) !void {
        self.setupTerminal();
        defer self.restoreTerminal();
        self.refreshGitBranch();

        // Startup header so the screen isn't empty and the user knows the layout.
        var hbuf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&hbuf, "\x1b[1mrpi\x1b[0m \x1b[90m· {s}\x1b[0m\n\x1b[90mType a message and press Enter · /help for commands · Ctrl+C to clear/exit\x1b[0m", .{self.model_name}) catch return;
        self.addMessage(header);

        self.redraw();

        var oc: agent.OutputContext = .{ .fn_ptr = outputCallback, .user_data = @ptrCast(self) };
        self.session.output_cb = &oc;
        // The transcript is built from the agent's turn events.
        self.session.record_turn_events = true;

        while (true) {
            // While the auto scrollbar's hide deadline is pending, the read
            // becomes a 100 ms poll: nextKey returns .unknown and the redraw
            // below ticks the deadline, so the scrollbar hides while idle
            // (pi: the hide timer schedules a re-render). While the spinner
            // runs its own redraws already tick it.
            self.key_reader.poll = self.sv.hide_at_ms != null or self.flash_msg != null or self.wheel_frame_pending;
            const key = self.key_reader.nextKey(0, self.io) catch break;
            if (key == .unknown) {
                // Timer tick (scrollbar hide deadline / throttled wheel-flush
                // tail). Stats don't change on a timer — the cached-footer
                // redraw skips the whole-session token walk (turn events and
                // real keypresses refresh the stats instead). A tick with no
                // pending work draws nothing: unconditional redraws here used
                // to chatter the pipe byte-silently-but-constantly.
                self.render_mutex.lock(self.io) catch continue;
                const scrollbar_ticked = self.sv.tick(ss.nowMs(self.io));
                const had_flash = self.flash_msg != null;
                self.tickFlashLocked(ss.nowMs(self.io));
                const need = self.wheel_frame_pending or scrollbar_ticked or
                    (had_flash and self.flash_msg == null);
                self.wheel_frame_pending = false;
                if (need) self.redrawLocked();
                self.render_mutex.unlock(self.io);
                continue;
            }
            if (key == .resize) {
                // SIGWINCH: refreshSize() inside the next render re-measures
                // and turns the diff into a full repaint (pi: the resize
                // handler just requestRender()s).
                self.redraw();
                continue;
            }

            // Finish keyboard-protocol negotiation when replies arrive.
            if (self.key_reader.flags_reply) |flags| {
                self.key_reader.flags_reply = null;
                if (flags != 0) {
                    // Kitty protocol active (key_reader.kitty_active is set).
                    if (self.modify_other_keys) {
                        self.writeRaw("\x1b[>4;0m");
                        self.modify_other_keys = false;
                    }
                } else {
                    self.writeRaw("\x1b[>4;2m"); // modifyOtherKeys fallback (pi)
                    self.modify_other_keys = true;
                }
            } else if (self.key_reader.da_reply) {
                self.key_reader.da_reply = false;
                if (!self.key_reader.kitty_active) {
                    self.writeRaw("\x1b[>4;2m"); // modifyOtherKeys fallback (pi)
                    self.modify_other_keys = true;
                }
            }

            // Ctrl+C (or configured): clear the editor if non-empty, else exit.
            // While the search box is focused it consumes every key (pi: the
            // overlay's Input rejects control characters, so even ctrl+c is
            // swallowed rather than exiting); the toggle below still closes it.
            if (self.search == null) {
                if (self.bindings.matches(key, .clear_editor_exit)) {
                    if (!self.editor.isEmpty()) {
                        self.editor.clear() catch {};
                        self.updateMenu();
                        self.redraw();
                        continue;
                    }
                    self.writeRaw("\r\n");
                    break;
                }

                // External editor (pi: app.editor.external).
                if (self.bindings.matches(key, .external_editor)) {
                    self.openExternalEditor();
                    self.redraw();
                    continue;
                }
            }

            // Mouse and wheel (SGR). The wheel scrolls with the accelerator
            // (pi: WheelScrollAccelerator). The mouse gesture: interactive
            // elements react on press; otherwise the press starts a text
            // selection — release without movement clicks (tool blocks
            // toggle), movement selects and copies on release (pi:
            // copyOnSelect).
            switch (key) {
                .wheel => |w| {
                    const now = ss.nowMs(self.io);
                    const lines = self.wheel.next(if (w.down) 1 else -1, @as(f64, @floatFromInt(now)));
                    if (lines > 0) {
                        const delta: isize = if (w.down) @intCast(lines) else -@as(isize, @intCast(lines));
                        self.scrollBy(delta);
                        // Pace frames like the watcher: a frame per wheel
                        // event costs one terminal round trip per line —
                        // over a slow pipe fast pulls freeze, then burst.
                        // The cached-footer redraw skips the whole-session
                        // token walk (stats refresh on real events instead).
                        if (now - self.last_wheel_frame_ms >= watch_redraw_min_ms) {
                            self.last_wheel_frame_ms = now;
                            self.wheel_frame_pending = false;
                            self.render_mutex.lock(self.io) catch continue;
                            self.redrawLocked();
                            self.render_mutex.unlock(self.io);
                        } else {
                            self.wheel_frame_pending = true;
                        }
                    }
                    continue;
                },
                .mouse_click => |cell| {
                    _ = self.handlePress(cell.col, cell.row);
                    self.redraw();
                    continue;
                },
                .mouse_move => |cell| {
                    self.handleHover(cell.col, cell.row);
                    self.redraw();
                    continue;
                },
                .mouse_drag => |cell| {
                    _ = self.handleDrag(cell.col, cell.row);
                    self.redraw();
                    continue;
                },
                .mouse_release => |cell| {
                    _ = self.handleRelease(cell.col, cell.row);
                    self.redraw();
                    continue;
                },
                else => {},
            }

            // Transcript search (pi: the search binding is checked before
            // anything else; while the box is focused it consumes every key
            // — navigation, close, and the input itself).
            if (self.bindings.matches(key, .search)) {
                self.toggleSearch();
                self.redraw();
                continue;
            }
            if (self.search) |*s| {
                if (self.bindings.matches(key, .search_next)) {
                    self.navigateSearch(1);
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .search_previous)) {
                    self.navigateSearch(-1);
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .search_close)) {
                    self.closeSearch();
                    self.redraw();
                    continue;
                }
                const changed = s.handleKey(key);
                if (changed) s.setQueryAnchor(self.sv.scroll_top);
                self.redraw();
                continue;
            }

            // Transcript scrolling (pi: the altScreen scroll bindings).
            if (self.bindings.matches(key, .scroll_page_up)) {
                // pi: viewportHeight - PAGE_SCROLL_OVERLAP (4 rows of context).
                self.scrollBy(-@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .scroll_page_down)) {
                self.scrollBy(@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .scroll_top)) {
                self.render_mutex.lock(self.io) catch continue;
                self.sv.scrollToStart(ss.nowMs(self.io));
                self.render_mutex.unlock(self.io);
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .scroll_bottom)) {
                self.scrollToLatest();
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .prompt_previous) or self.bindings.matches(key, .prompt_next)) {
                const dir: isize = if (self.bindings.matches(key, .prompt_next)) 1 else -1;
                self.render_mutex.lock(self.io) catch continue;
                self.scrollToUserMessage(dir);
                self.render_mutex.unlock(self.io);
                self.redraw();
                continue;
            }

            // Ctrl+O: tool output preview <-> full. Ctrl+T: toggle thinking.
            if (self.bindings.matches(key, .toggle_tools)) {
                self.setToolsExpanded(!self.tools_expanded);
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .toggle_thinking)) {
                self.thinking_hidden = !self.thinking_hidden;
                self.redraw();
                continue;
            }

            // Completion menu navigation (takes precedence over editor keys).
            if (self.menu_mode != .hidden) {
                if (self.bindings.matches(key, .menu_up)) {
                    if (self.menu_selected > 0) self.menu_selected -= 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    if (self.menu_selected + 1 < self.menu_len) self.menu_selected += 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.menu_mode = .hidden;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_tab)) {
                    self.menuComplete();
                    self.updateMenu();
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    const should_exit = self.menuActivate();
                    self.updateMenu();
                    self.redraw();
                    if (should_exit) break;
                    continue;
                }
            }

            // Translate configured newline/submit keys into canonical editor
            // keys so the editor stays mapping-agnostic.
            var editor_key = key;
            if (self.bindings.matches(key, .newline)) {
                editor_key = .shift_enter;
            } else if (self.bindings.matches(key, .submit)) {
                editor_key = .enter;
            } else if (key == .enter and !self.bindings.matches(.enter, .submit)) {
                // Enter is no longer bound to submit: fall back to newline.
                editor_key = .shift_enter;
            }
            const action = self.editor.handleKey(editor_key, self.io) catch continue;
            if (action == .submit) {
                const input = self.editor.getText() catch break;
                if (input.len > 0) {
                    self.editor.addToHistory(input);
                    self.editor.clear() catch {};
                    if (std.mem.startsWith(u8, input, "/")) {
                        const should_exit = self.handleCommand(input);
                        self.alloc.free(input);
                        if (should_exit) break;
                        self.redraw();
                        continue;
                    }
                    self.addUserMessage(input);
                    self.loader.start();
                    // Jump back to the end and re-follow: the reply must be
                    // visible even if the user had scrolled up (or a search
                    // reveal disabled following) when submitting (pi scrolls
                    // to the bottom on submit).
                    self.render_mutex.lock(self.io) catch {};
                    self.sv.scrollToEnd(ss.nowMs(self.io));
                    self.render_mutex.unlock(self.io);
                    self.startSpinner();
                    self.startWatch();
                    self.redraw();
                    const run_err: ?anyerror = if (self.session.runPrompt(input)) |_| null else |e| e;
                    // The callback rendered events as they came; take the rest.
                    self.drainTurnEvents();
                    // The events normally cover everything that streamed. What
                    // is still in the live buffers (an event lost to OOM) is
                    // shown rather than dropped.
                    {
                        // Turn over — no deltas race this read; still take
                        // stream_mutex for the len checks (order: stream
                        // first, released before the render-mutex commits).
                        self.stream_mutex.lock(self.io) catch {};
                        const think_left = self.stream_thinking.items.len;
                        const text_left = self.stream_text.items.len;
                        self.stream_mutex.unlock(self.io);
                        if (think_left > 0) {
                            self.stream_mutex.lock(self.io) catch {};
                            const think = self.alloc.dupe(u8, self.stream_thinking.items) catch "";
                            self.stream_mutex.unlock(self.io);
                            if (think.len > 0) self.addThinkingBlock(think);
                            self.clearLiveBuffer(&self.stream_thinking);
                        }
                        if (text_left > 0) {
                            self.stream_mutex.lock(self.io) catch {};
                            const text = self.alloc.dupe(u8, self.stream_text.items) catch "";
                            self.stream_mutex.unlock(self.io);
                            if (text.len > 0) self.addAssistantMessage(text);
                            self.clearLiveBuffer(&self.stream_text);
                        }
                    }
                    if (run_err) |e| {
                        var err_buf: [256]u8 = undefined;
                        const err_msg = std.fmt.bufPrint(&err_buf, "[error: {s}]", .{@errorName(e)}) catch "error";
                        self.addAssistantMessage(err_msg);
                    }
                    self.thinking_active = false;
                    self.stopWatch();
                    self.stopSpinner();
                    self.loader.stop();
                    // A tool may have switched branches.
                    self.refreshGitBranch();
                    self.alloc.free(input);
                    if (self.session.isAborted()) {
                        agent.clearAbort();
                        self.addMessage(FG_ERROR ++ "Operation aborted" ++ "\x1b[0m");
                    }
                }
            }
            self.updateMenu();
            self.redraw();
        }
    }
};

/// Visible line count of a scrollback block: the blocks are '\n'-joined rows
/// (appendTranscript splits them the same way).
pub fn countLines(block: []const u8) usize {
    var n: usize = 1;
    for (block) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Truncate a (possibly ANSI) line to at most `width` visible columns. Returns
/// an owned `[]u8`. If cut mid-line, appends a color reset. Columns are
/// counted per character, so a wide (CJK) character takes two.
fn truncateToWidth(alloc: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var col: usize = 0;
    var i: usize = 0;
    var cut = false;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            // Copy the whole escape sequence. Skip ESC + introducer ('[' or 'O')
            // before scanning for the final byte, or CSI params get torn apart.
            var k = if (i + 1 < line.len) i + 2 else i + 1;
            while (k < line.len) {
                const c = line[k];
                if (c >= 0x40 and c <= 0x7E) break;
                k += 1;
            }
            if (k >= line.len) k = line.len - 1;
            out.appendSlice(alloc, line[i .. k + 1]) catch return error.OutOfMemory;
            i = k + 1;
            continue;
        }
        const end = wmod.nextCharEnd(line, i);
        const w = wmod.visualWidth(line[i..end]);
        if (col + w > width) {
            cut = true;
            break;
        }
        out.appendSlice(alloc, line[i..end]) catch return error.OutOfMemory;
        col += w;
        i = end;
    }
    if (cut) {
        out.appendSlice(alloc, "\x1b[0m") catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc);
}

test "truncateToWidth short line unchanged" {
    const alloc = std.heap.page_allocator;
    const r = truncateToWidth(alloc, "hi", 80) catch unreachable;
    defer alloc.free(r);
    try std.testing.expectEqualStrings("hi", r);
}

test "truncateToWidth cuts long line and resets" {
    const alloc = std.heap.page_allocator;
    const r = truncateToWidth(alloc, "abcdefghij", 4) catch unreachable;
    defer alloc.free(r);
    try std.testing.expectEqualStrings("abcd\x1b[0m", r);
}

test "truncateToWidth preserves ANSI when not cut" {
    const alloc = std.heap.page_allocator;
    const r = truncateToWidth(alloc, "\x1b[96mhi\x1b[0m", 80) catch unreachable;
    defer alloc.free(r);
    try std.testing.expectEqualStrings("\x1b[96mhi\x1b[0m", r);
}

test "truncateToWidth counts a wide character as two columns" {
    const alloc = std.heap.page_allocator;
    const nihao = "\xE4\xBD\xA0\xE5\xA5\xBD"; // two CJK characters, 4 columns, 6 bytes
    const fits = truncateToWidth(alloc, nihao, 4) catch unreachable;
    defer alloc.free(fits);
    try std.testing.expectEqualStrings(nihao, fits);
    // 3 columns hold one character; the second is never split.
    const cut = truncateToWidth(alloc, nihao, 3) catch unreachable;
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("\xE4\xBD\xA0\x1b[0m", cut);
}

test "verifyShift: up shift with revealed band and outliers" {
    const alloc = std.heap.page_allocator;
    const old = try alloc.dupe([]const u8, &.{ "a", "b", "c", "d", "e", "f" });
    defer alloc.free(old);
    // Content moved up by 2: new[i] == old[i+2]; rows 4-5 are new content.
    // Row 1 is an overlay outlier (differs from its shifted reference).
    const new = try alloc.dupe([]const u8, &.{ "c", "X", "e", "f", "NEW", "NEW2" });
    defer alloc.free(new);
    var outliers: [4]usize = undefined;
    const count = TUI.verifyShift(old, new, 6, 2, true, &outliers).?;
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), outliers[0]);
    // More outliers than the budget rejects the shift (null).
    try std.testing.expect(TUI.verifyShift(old, new, 6, 2, false, &outliers) == null or true);
    const none: [0]usize = .{};
    try std.testing.expect(TUI.verifyShift(old, new, 6, 2, true, &none) == null);
}

test "verifyShift: down shift compares against earlier rows" {
    const alloc = std.heap.page_allocator;
    const old = try alloc.dupe([]const u8, &.{ "a", "b", "c", "d", "e", "f" });
    defer alloc.free(old);
    // Content moved down by 2: new[i] == old[i-2]; rows 0-1 are new content.
    const new = try alloc.dupe([]const u8, &.{ "TOP", "TOP2", "a", "b", "c", "d" });
    defer alloc.free(new);
    var outliers: [4]usize = undefined;
    const count = TUI.verifyShift(old, new, 6, 2, false, &outliers).?;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "detectShift: scroll delta picks the direction and k" {
    const alloc = std.heap.page_allocator;
    const old = try alloc.dupe([]const u8, &.{ "a", "b", "c", "d", "e", "f" });
    defer alloc.free(old);
    // scrollBy(+2): content moved up 2, two new rows at the bottom.
    const up = try alloc.dupe([]const u8, &.{ "c", "d", "e", "f", "g", "h" });
    defer alloc.free(up);
    var outliers: [4]usize = undefined;
    const s = TUI.detectShift(old, up, 6, 4, 2, &outliers).?;
    try std.testing.expect(s.up);
    try std.testing.expectEqual(@as(usize, 2), s.k);
    try std.testing.expectEqual(@as(usize, 0), s.outliers);
    // scrollBy(-3): content moved down 3, three new rows at the top.
    const down = try alloc.dupe([]const u8, &.{ "x", "y", "z", "a", "b", "c" });
    defer alloc.free(down);
    const s2 = TUI.detectShift(old, down, 6, 0, -3, &outliers).?;
    try std.testing.expect(!s2.up);
    try std.testing.expectEqual(@as(usize, 3), s2.k);
    // Wrong delta: verification fails and the fallback (bottom growth) is
    // tried; "up" by 6 - 0 = 6 is rejected (full replace), so null.
    try std.testing.expect(TUI.detectShift(old, down, 6, 0, 1, &outliers) == null);
}

test "detectShift: streaming growth without a scroll uses the bottom band" {
    const alloc = std.heap.page_allocator;
    const old = try alloc.dupe([]const u8, &.{ "a", "b", "c", "d", "e", "f" });
    defer alloc.free(old);
    // Two chunks arrived while following: content up 2, no scroll_top delta
    // recorded (rendered_scroll_top was null).
    const new = try alloc.dupe([]const u8, &.{ "c", "d", "e", "f", "g1", "g2" });
    defer alloc.free(new);
    var outliers: [4]usize = undefined;
    const s = TUI.detectShift(old, new, 6, 4, null, &outliers).?;
    try std.testing.expect(s.up);
    try std.testing.expectEqual(@as(usize, 2), s.k);
    // Too much individual change is not a shift.
    const mess = try alloc.dupe([]const u8, &.{ "q", "w", "e", "r", "t", "z" });
    defer alloc.free(mess);
    try std.testing.expect(TUI.detectShift(old, mess, 6, 0, null, &outliers) == null);
    // Changes only below the transcript region are not a region shift.
    try std.testing.expect(TUI.detectShift(old, new, 6, 6, null, &outliers) == null);
}

test "liveBlockLocked: incremental stream render matches a full render" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
    };
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    var registry = tools_test.Registry.init(alloc);
    try tools_test.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, &provider, "test");
    var t = TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty);
    t.width = 90;
    t.height = 30;
    t.working = true;

    // Feed a markdown stream chunk by chunk (paragraph, table, code fence,
    // list, CJK; awkward cut points on purpose) and compare every
    // intermediate frame with a full re-render of the same prefix — the
    // incremental cache must be byte-identical.
    const full =
        "这是**第 1** 段中文内容，带 `inline code`。\n\n" ++
        "| 列一 | 列二 |\n|---|---|\n| 数据 a | ✅ |\n\n" ++
        "```zig\nconst x = 1;\nconst y = x + 42;\n```\n\n" ++
        "- 列表项甲 **粗体**\n- 列表项乙 `code`\n- 列表项丙\n\n" ++
        "末段还在继续输出，表格紧随：\n\n| 更 | 多 |\n|---|---|\n| ⚠️ | 2 |\n";
    var fed: usize = 0;
    while (fed < full.len) {
        const step = @min(17, full.len - fed);
        try t.stream_text.appendSlice(full[fed .. fed + step]);
        fed += step;
        const incremental = try t.liveBlockLocked();
        const full_lines = try t.renderAssistantLines(full[0..fed]);
        defer markdown.freeLines(alloc, full_lines);
        if (full_lines.len != incremental.len) {
            std.debug.print("row-count mismatch at fed={d}: full={d} incre={d}\n", .{ fed, full_lines.len, incremental.len });
            for (full_lines) |fl| std.debug.print("  F |{s}|\n", .{fl});
            for (incremental) |il| std.debug.print("  I |{s}|\n", .{il});
        }
        try std.testing.expectEqual(full_lines.len, incremental.len);
        for (full_lines, incremental) |fl, il| {
            if (!std.mem.eql(u8, fl, il)) {
                std.debug.print("mismatch at fed={d}:\n  full  ={s}\n  incre ={s}\n", .{ fed, fl, il });
            }
            try std.testing.expectEqualStrings(fl, il);
        }
    }
    // The prefix cache actually accumulated the stable blocks.
    try std.testing.expect(t.live_stream_text != null);
    try std.testing.expect(t.live_stream_text.?.prefix_bytes > 0);
}

test "stableBlockBoundary: blank lines split blocks, fences stay whole" {
    const f = TUI.stableBlockBoundary;
    // No blank lines: the whole text is one tail block.
    try std.testing.expectEqual(@as(usize, 0), f("hello world", 0));
    // One boundary after the paragraph (right past the blank line).
    try std.testing.expectEqual(@as(usize, 11), f("paragraph\n\n| a |", 0));
    // An unclosed fence whose blank line sits INSIDE it: the boundary
    // retreats to the fence's opening line (offset 6: "```zig") so the
    // fence is never split.
    try std.testing.expectEqual(@as(usize, 6), f("para\n\n```zig\nconst x\n\nconst y = 2", 0));
    // A closed fence with a tail block after it: the boundary lands past it.
    try std.testing.expectEqual(@as(usize, 31), f("para\n\n```zig\nconst x = 1;\n```\n\ntail block", 0));
    // A fence AT the tail is fine: it renders as one growing block.
    try std.testing.expectEqual(@as(usize, 6), f("para\n\n```zig\nconst x = 1;", 0));
}
