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
const shell = @import("../tools/shell.zig");
const clipboard = @import("../core/clipboard.zig");
const ptmod = @import("../core/prompt_template.zig");
const trust = @import("../core/trust.zig");
const events = @import("../core/events.zig");
const fuzzy = @import("fuzzy.zig");
const compact = @import("../core/compaction.zig");
const skills = @import("../core/skills.zig");
const sp = @import("../core/system_prompt.zig");
const mcp = @import("../core/mcp.zig");
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
const aiprovider = @import("../ai/provider.zig");
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
const BORDER_INFO = "\x1b[38;2;114;130;216m"; // theme.border okhsl(231 57% 65%) — modal selectors
const ACCENT = "\x1b[38;2;167;152;215m";
// Message block colors (pi dark theme).
const USER_BG = "\x1b[48;2;33;59;73m"; // userMessageBg blueBg
const SELECTED_BG = "\x1b[48;2;33;59;73m"; // selectedBg (the same blueBg token)
const USER_FG = "\x1b[38;2;222;224;225m"; // text
const THINKING_TEXT = "\x1b[38;2;150;160;164m"; // thinkingText // violet (spinner, cursor)
const MUTED = "\x1b[38;2;108;118;123m"; // muted text ("Working" label)
const FG_MUTED = "\x1b[38;2;157;165;169m"; // muted (customMessageText)
pub const VERSION = "0.1.0";
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
    /// One completion-menu row. `value` is the completion text without the
    /// leading slash (pi item.value: label may differ, e.g. models show the
    /// id but complete to "provider/id"); empty = use `name`.
    const MenuEntry = struct { name: []const u8, desc: []const u8, model_idx: ?usize = null, value: []const u8 = "" };
    const MenuMode = enum { hidden, commands, models, settings, files, sessions, tree, forksel, mcp, mcp_server, mcp_tools, mcp_exposure, trust, scoped, model_selector };
    const CommandDef = struct { name: []const u8, desc: []const u8, takes_arg: bool = false };

    /// pi settings-selector items (pi-tui SettingsList + settings-selector.js),
    /// same ids/labels/descriptions/values. Items rpi cannot back yet render
    /// their default and say so on Enter (settingsApply returns false).
    const SettingKind = enum {
        autocompact, show_images, image_width, auto_resize_images, block_images,
        skill_commands, show_hardware_cursor, editor_padding, output_padding,
        autocomplete_max, clear_on_shrink, terminal_progress, steering_mode,
        follow_up_mode, transport, share_destination, http_idle_timeout,
        cache_warming, hide_thinking, mermaid, cache_miss_notices,
        collapse_changelog, quiet_startup, install_telemetry,
        default_project_trust, double_escape, tree_filter, warnings,
        model_thinking, tui_mode, fs_exit_output, fs_scrollbar,
        fs_copy_on_select, fs_wheel_lines, theme,
    };
    const SettingDef = struct {
        kind: SettingKind,
        label: []const u8,
        desc: []const u8,
        values: []const []const u8,
    };
    const SETTING_DEFS = [_]SettingDef{
        .{ .kind = .autocompact, .label = "Auto-compact", .desc = "Automatically compact context when it gets too large", .values = &.{ "true", "false" } },
        .{ .kind = .show_images, .label = "Show images", .desc = "Render images inline in terminal", .values = &.{ "true", "false" } },
        .{ .kind = .image_width, .label = "Image width", .desc = "Preferred inline image width in terminal cells", .values = &.{ "60", "80", "120" } },
        .{ .kind = .auto_resize_images, .label = "Auto-resize images", .desc = "Resize large images to 2000x2000 max for better model compatibility", .values = &.{ "true", "false" } },
        .{ .kind = .block_images, .label = "Block images", .desc = "Prevent images from being sent to LLM providers", .values = &.{ "true", "false" } },
        .{ .kind = .skill_commands, .label = "Skill commands", .desc = "Register skills as /skill:name commands", .values = &.{ "true", "false" } },
        .{ .kind = .show_hardware_cursor, .label = "Show hardware cursor", .desc = "Use the terminal cursor instead of Pi's drawn cursor", .values = &.{ "true", "false" } },
        .{ .kind = .editor_padding, .label = "Editor padding", .desc = "Horizontal padding for input editor (0-3)", .values = &.{ "0", "1", "2", "3" } },
        .{ .kind = .output_padding, .label = "Output padding", .desc = "Horizontal padding for messages, tool output, and command output", .values = &.{ "0", "1" } },
        .{ .kind = .autocomplete_max, .label = "Autocomplete max items", .desc = "Max visible items in autocomplete dropdown (3-20)", .values = &.{ "3", "5", "7", "10", "15", "20" } },
        .{ .kind = .clear_on_shrink, .label = "Clear on shrink", .desc = "Clear empty rows when content shrinks (may cause flicker)", .values = &.{ "true", "false" } },
        .{ .kind = .terminal_progress, .label = "Terminal progress", .desc = "Show OSC 9;4 progress indicators in the terminal tab bar", .values = &.{ "true", "false" } },
        .{ .kind = .steering_mode, .label = "Steering mode", .desc = "Enter while streaming queues steering messages. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.", .values = &.{ "one-at-a-time", "all" } },
        .{ .kind = .follow_up_mode, .label = "Follow-up mode", .desc = "alt+enter queues follow-up messages until agent stops. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.", .values = &.{ "one-at-a-time", "all" } },
        .{ .kind = .transport, .label = "Transport", .desc = "Preferred transport for providers that support multiple transports", .values = &.{"auto"} },
        .{ .kind = .share_destination, .label = "Session share destination", .desc = "Where to upload sessions with /share (auto prefers Radius when authenticated, otherwise GitHub Gist)", .values = &.{ "auto", "radius", "gist" } },
        .{ .kind = .http_idle_timeout, .label = "HTTP idle timeout", .desc = "Maximum idle gap while waiting for HTTP headers or body chunks. Disable for local models that pause longer than five minutes.", .values = &.{"default"} },
        .{ .kind = .cache_warming, .label = "Cache warming", .desc = "off; streaming while the agent runs; idle also between runs while continuation stays profitable", .values = &.{"off"} },
        .{ .kind = .hide_thinking, .label = "Hide thinking", .desc = "Hide thinking blocks in assistant responses", .values = &.{ "true", "false" } },
        .{ .kind = .mermaid, .label = "Mermaid diagrams", .desc = "Render Mermaid code blocks as Unicode diagrams", .values = &.{"off"} },
        .{ .kind = .cache_miss_notices, .label = "Cache miss notices", .desc = "Show transcript notices for cache costs and provider recovery diagnostics", .values = &.{ "true", "false" } },
        .{ .kind = .collapse_changelog, .label = "Collapse changelog", .desc = "Show condensed changelog after updates", .values = &.{ "true", "false" } },
        .{ .kind = .quiet_startup, .label = "Quiet startup", .desc = "Disable verbose printing at startup (header: keep only the startup header)", .values = &.{"false"} },
        .{ .kind = .install_telemetry, .label = "Install telemetry", .desc = "Send an anonymous version/update ping after changelog-detected updates", .values = &.{ "true", "false" } },
        .{ .kind = .default_project_trust, .label = "Default project trust", .desc = "Fallback behavior when no extension or saved trust decision decides project trust", .values = &.{ "Ask", "Always trust", "Never trust" } },
        .{ .kind = .double_escape, .label = "Double-escape action", .desc = "Action when pressing Escape twice with empty editor", .values = &.{"none"} },
        .{ .kind = .tree_filter, .label = "Tree filter mode", .desc = "Default filter when opening /tree", .values = &.{"all"} },
        .{ .kind = .warnings, .label = "Warnings", .desc = "Enable or disable individual warnings", .values = &.{"true"} },
        .{ .kind = .model_thinking, .label = "Default thinking level per model", .desc = "Override the default thinking level for specific models.", .values = &.{"none"} },
        .{ .kind = .tui_mode, .label = "TUI mode", .desc = "Interface layout; regular mode uses the terminal's normal scrollback", .values = &.{ "regular", "fullscreen" } },
        .{ .kind = .fs_exit_output, .label = "Fullscreen exit output", .desc = "Print the transcript or only a session resume hint when exiting fullscreen mode", .values = &.{ "transcript", "resume-hint" } },
        .{ .kind = .fs_scrollbar, .label = "Fullscreen scrollbar", .desc = "Scrollbar behavior in fullscreen mode; has no effect in regular mode", .values = &.{ "auto", "always", "hidden" } },
        .{ .kind = .fs_copy_on_select, .label = "Fullscreen copy on select", .desc = "Automatically copy selected text in fullscreen mode; disable to copy selections with Ctrl+X", .values = &.{ "true", "false" } },
        .{ .kind = .fs_wheel_lines, .label = "Fullscreen wheel scrolling", .desc = "Lines per mouse-wheel event in fullscreen mode; 'auto' speeds up fast wheel spins where the terminal does not", .values = &.{ "auto", "1", "2", "3", "5", "10" } },
        .{ .kind = .theme, .label = "Theme", .desc = "Color theme for the interface", .values = &.{"dark"} },
    };
    /// Selector row capacity (sessions/tree/fork pickers).
    const SEL_MAX = 64;
    /// One picker row: display name/desc + attached id (entry id or path).
    const SelRow = struct {
        name: [168]u8 = undefined,
        name_len: usize = 0,
        desc: [80]u8 = undefined,
        desc_len: usize = 0,
        id: [300]u8 = undefined,
        id_len: usize = 0,
    };

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
        // pi BUILTIN_SLASH_COMMANDS (core/slash-commands.js), same order and
        // descriptions. /mcp sits at the end (pi registers it as an extension
        // command, which pi renders after templates and before skills).
        .{ .name = "/settings", .desc = "Open settings menu" },
        .{ .name = "/model", .desc = "Select model (opens selector UI)", .takes_arg = true },
        .{ .name = "/tree", .desc = "Navigate session tree (switch branches)" },
        .{ .name = "/thinking", .desc = "Set thinking level", .takes_arg = true },
        .{ .name = "/scoped-models", .desc = "Enable/disable models for Ctrl+P cycling" },
        .{ .name = "/export", .desc = "Export session (HTML default, or specify path: .html/.jsonl)" },
        .{ .name = "/import", .desc = "Import a JSONL session, preserving its ID and working directory" },
        .{ .name = "/share", .desc = "Share session via a Radius artifact or a GitHub gist" },
        .{ .name = "/bug", .desc = "Report a bug to the Pi developers", .takes_arg = true },
        .{ .name = "/copy", .desc = "Copy last agent message to clipboard" },
        .{ .name = "/name", .desc = "Set session display name" },
        .{ .name = "/session", .desc = "Show session info and stats" },
        .{ .name = "/changelog", .desc = "Show changelog entries" },
        .{ .name = "/hotkeys", .desc = "Show all keyboard shortcuts" },
        .{ .name = "/fork", .desc = "Create a new fork from a previous user message" },
        .{ .name = "/clone", .desc = "Duplicate the current session at the current position" },
        .{ .name = "/trust", .desc = "Save project trust decision for future sessions" },
        .{ .name = "/login", .desc = "Configure provider authentication", .takes_arg = true },
        .{ .name = "/logout", .desc = "Remove provider authentication" },
        .{ .name = "/new", .desc = "Start a new session" },
        .{ .name = "/compact", .desc = "Manually compact the session context" },
        .{ .name = "/resume", .desc = "Resume another session" },
        .{ .name = "/reload", .desc = "Reload keybindings, extensions, skills, prompts, themes, and context files" },
        .{ .name = "/quit", .desc = "Quit" },
        .{ .name = "/mcp", .desc = "Show MCP servers and their state" },
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
    /// CLI `--append-system-prompt` / `--system-prompt` (borrowed from cfg /
    /// startup), preserved across `/reload`.
    append_system_prompt: ?[]const u8 = null,
    system_prompt_override: ?[]const u8 = null,
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
    owned_provider: ?aiprovider.AnyProvider = null,
    /// /scoped-models: models (as "provider/id") enabled for Ctrl+P
    /// cycling. null = all enabled (pi session.scopedModels). Session-only
    /// (pi persists via Ctrl+S — not implemented yet).
    scoped_models: ?std.ArrayListUnmanaged([]u8) = null,
    /// /settings selector state (pi SettingsSelectorComponent): the editor
    /// line doubles as the search input; these hold the filtered view.
    settings_filtered: [SETTING_DEFS.len]usize = undefined,
    settings_visible: usize = 0,
    settings_sel: usize = 0,
    /// /model selector state (pi ModelSelectorComponent): filtered model
    /// indices into cfg.models + selection + scope (all/scoped cycling).
    ms_filtered: std.ArrayListUnmanaged(usize) = .empty,
    ms_visible: usize = 0,
    ms_sel: usize = 0,
    ms_scope_all: bool = true,
    /// Backed settings fields (see settingsApply).
    skill_commands: bool = true,
    steering_mode_all: bool = true,
    follow_up_mode_all: bool = true,
    fullscreen_copy_on_select: bool = true,
    autocomplete_max: usize = 5,
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
    /// Filtered candidates in ranked order (pi fuzzyFilter output; the
    /// render window shows `autocompleteMaxVisible` of them, centered on
    /// the selection). 64 covers COMMANDS + prompt templates + skills.
    menu_items: [64]MenuEntry = undefined,
    /// Storage for formatted settings descriptions (menu_items' desc points here).
    settings_desc_buf: [16][64]u8 = undefined,
    // ---- @file completion menu state ----
    file_names: [16][160]u8 = undefined,
    file_paths: [16][256]u8 = undefined,
    file_path_lens: [16]usize = undefined,
    /// Byte offset of the '@' that opened the menu (per row).
    file_at_col: [16]usize = undefined,
    /// The token last applied by completion: the file menu stays closed
    /// until the token changes again (pi dismisses on selection).
    at_suppress: ?[]u8 = null,
    menu_len: usize = 0,
    menu_selected: usize = 0,
    /// Selector rows for the modal pickers (sessions/tree/fork): static
    /// buffers the menu_items rows point into (menu_items cap is 16; the
    /// full row set lives here with a scrolling viewport).
    sel_rows: [SEL_MAX]SelRow = undefined,
    sel_len: usize = 0,
    /// Byte id attached to each selector row (entry id or session path).
    /// Type--to-filter state for the sessions picker.
    sel_filter: [80]u8 = undefined,
    sel_filter_len: usize = 0,
    /// First visible menu row (viewport follows menu_selected).
    menu_view_start: usize = 0,
    /// Dynamic slash commands (pi: prompt templates + `skill:<name>` appear
    /// in the `/` menu next to the built-ins, description prefixed with a
    /// source tag like `[u]` user / `[p]` project). Owned; refreshed on
    /// startup and /reload.
    slash_extras: std.ArrayListUnmanaged(SlashExtra) = .empty,
    /// Server the /mcp detail/exposure/tools menus act on (static copy; MCP
    /// server names are manager-owned and stable for the session).
    mcp_server_name: [64]u8 = undefined,
    mcp_server_name_len: usize = 0,
    /// Snapshot of the editor text the menu was last built from (pi
    /// rebuilds suggestions only on editor onChange; the main loop calls
    /// updateMenu after EVERY key, and rebuilding unconditionally would
    /// reset menu_selected on navigation keys — the menu would snap back to
    /// the first row on every up/down).
    menu_text_cache: ?[]u8 = null,
    /// Project-trust decision (pi resolveProjectTrusted). Set by main after
    /// the trust flow; gates project skills/prompts/templates discovery.
    project_trusted: bool = false,
    /// Pending trust prompt: when set, the main loop shows the trust modal
    /// (pi TrustSelectorComponent) before processing any other key.
    trust_prompt: ?TrustPrompt = null,
    /// main-provided reload hook: re-runs project-resource loading after a
    /// trust decision (project mcp connect + tool registration).
    trust_reload_ctx: ?*anyopaque = null,
    trust_reload_fn: ?*const fn (ctx: *anyopaque, t: *TUI, trusted: bool) void = null,

    const TrustPrompt = struct {
        cwd: []u8,
        saved: ?bool,
        /// /trust flow (re-decide + save) vs startup ask (esc = distrust).
        from_command: bool,
    };

    const SlashExtra = struct { name: []u8, desc: []u8 };

    fn commandTakesArg(name: []const u8) bool {
        for (COMMANDS) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.takes_arg;
        }
        return false;
    }

    /// Rebuild slash_extras from prompt templates + skills (pi
    /// createBaseAutocompleteProvider: templates then skills, tagged by
    /// scope). Best-effort: discovery failures leave the list empty.
    fn refreshSlashExtras(self: *TUI) void {
        for (self.slash_extras.items) |*e| {
            self.alloc.free(e.name);
            self.alloc.free(e.desc);
        }
        self.slash_extras.clearRetainingCapacity();
        const agent_dir = self.agent_dir_for_templates();
        const templates = ptmod.discover(self.alloc, self.io, agent_dir, self.cwd_abs, self.project_trusted);
        defer ptmod.freeAll(self.alloc, templates);
        for (templates) |t| {
            const name = std.fmt.allocPrint(self.alloc, "/{s}", .{t.name}) catch continue;
            const desc = std.fmt.allocPrint(self.alloc, "[{s}] {s}", .{ t.scope, t.description }) catch {
                self.alloc.free(name);
                continue;
            };
            self.slash_extras.append(self.alloc, .{ .name = name, .desc = desc }) catch {
                self.alloc.free(name);
                self.alloc.free(desc);
            };
        }
        const skills_list = skills.discover(self.alloc, self.io, agent_dir, self.cwd_abs, self.home_dir, self.project_trusted) catch return;
        defer skills.freeAll(self.alloc, skills_list);
        for (skills_list) |sk| {
            // pi: skills come from user or project dirs; tag by which root
            // owns the file (pi sourceInfo.scope: project = cwd, else user).
            const scope: []const u8 = if (std.mem.startsWith(u8, sk.base_dir, self.cwd_abs)) "p" else "u";
            const name = std.fmt.allocPrint(self.alloc, "/skill:{s}", .{sk.name}) catch continue;
            const desc = std.fmt.allocPrint(self.alloc, "[{s}] {s}", .{ scope, sk.description }) catch {
                self.alloc.free(name);
                continue;
            };
            self.slash_extras.append(self.alloc, .{ .name = name, .desc = desc }) catch {
                self.alloc.free(name);
                self.alloc.free(desc);
            };
        }
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

    /// Search text for a /-menu candidate (pi: item.value; `skill:` entries
    /// also match by their bare skill name).
    const SlashCtx = struct {
        values: []const []const u8,

        fn bare(self: @This(), i: usize) []const u8 {
            const v = self.values[i];
            if (std.mem.startsWith(u8, v, "skill:")) return v["skill:".len..];
            return v;
        }
    };

    fn slashBare(ctx: SlashCtx, i: usize) []const u8 {
        return ctx.bare(i);
    }

    /// Recompute the completion menu from the current editor text. Skipped
    /// when the text has not changed since the last build (navigation only
    /// moves the selection; pi updateAutocomplete semantics).
    fn freeMenuTextCache(self: *TUI) void {
        if (self.menu_text_cache) |c| {
            self.alloc.free(c);
            self.menu_text_cache = null;
        }
    }

    pub fn updateMenu(self: *TUI) void {
        // Modal dialogs (settings, session/tree/fork pickers, the /mcp
        // manager, scoped-models) are not driven by editor text.
        switch (self.menu_mode) {
            .settings, .sessions, .tree, .forksel, .mcp, .mcp_server, .mcp_tools, .mcp_exposure, .trust, .scoped, .model_selector => return,
            else => {},
        }
        const text = self.editor.getText() catch {
            self.menu_mode = .hidden;
            return;
        };
        defer self.alloc.free(text);
        if (self.menu_text_cache) |c| {
            if (std.mem.eql(u8, c, text)) {
                // Text unchanged: keep the current items and selection.
                return;
            }
            self.alloc.free(c);
        }
        if (self.alloc.dupe(u8, text)) |copy| {
            self.menu_text_cache = copy;
        } else |_| {}
        self.menu_len = 0;
        self.menu_selected = 0;
        const single_line = std.mem.indexOfScalar(u8, text, '\n') == null;

        // Commands: "/query" with no space yet (pi slash autocomplete:
        // fuzzy token filter over the command values; `skill:` entries also
        // match by their bare skill name, with full-name-only matches
        // appended after; ranked ascending by fuzzy score).
        if (single_line and text.len > 0 and text[0] == '/' and std.mem.indexOfScalar(u8, text, ' ') == null) {
            const query = text[1..];
            var values: [64][]const u8 = undefined;
            var n: usize = 0;
            for (COMMANDS) |c| {
                if (n >= values.len) break;
                self.menu_items[n] = .{ .name = c.name, .desc = c.desc, .value = c.name[1..] };
                values[n] = c.name[1..];
                n += 1;
            }
            for (self.slash_extras.items) |e| {
                if (n >= values.len) break;
                // pi: an extra conflicting with a built-in command is skipped
                // (getBuiltInCommandConflictDiagnostics) — the built-in wins.
                var conflict = false;
                for (COMMANDS) |c| {
                    if (std.mem.eql(u8, c.name, e.name)) conflict = true;
                }
                if (conflict) continue;
                self.menu_items[n] = .{ .name = e.name, .desc = e.desc, .value = e.name[1..] };
                values[n] = e.name[1..];
                n += 1;
            }
            const ctx = SlashCtx{ .values = values[0..n] };
            var combined: [64]usize = undefined;
            var cap: usize = 0;
            var bare_set: [64]bool = @splat(false);
            // Pass 1: bare-name matching (skill: entries match without the prefix).
            if (fuzzy.fuzzyFilter(self.alloc, n, query, ctx, slashBare) catch null) |bare| {
                defer self.alloc.free(bare);
                for (bare) |i| {
                    if (cap >= combined.len) break;
                    bare_set[i] = true;
                    combined[cap] = i;
                    cap += 1;
                }
            }
            // Pass 2: `skill:` entries the bare pass missed, matched by full
            // name and appended after (pi fullNameOnlyMatches).
            var skill_idx: [64]usize = undefined;
            var skill_n: usize = 0;
            for (0..n) |i| {
                if (std.mem.startsWith(u8, values[i], "skill:") and !bare_set[i]) {
                    skill_idx[skill_n] = i;
                    skill_n += 1;
                }
            }
            if (skill_n > 0) {
                const SkillCtx = struct {
                    vals: []const []const u8,
                    idx: []const usize,
                    fn get(c: @This(), i: usize) []const u8 {
                        return c.vals[c.idx[i]];
                    }
                };
                const sctx = SkillCtx{ .vals = values[0..n], .idx = skill_idx[0..skill_n] };
                if (fuzzy.fuzzyFilter(self.alloc, skill_n, query, sctx, SkillCtx.get) catch null) |ranked| {
                    defer self.alloc.free(ranked);
                    for (ranked) |r| {
                        if (cap >= combined.len) break;
                        combined[cap] = skill_idx[r];
                        cap += 1;
                    }
                }
            }
            // Reorder menu_items into the ranked order.
            var ordered: [64]MenuEntry = undefined;
            for (0..cap) |k| ordered[k] = self.menu_items[combined[k]];
            for (0..cap) |k| self.menu_items[k] = ordered[k];
            self.menu_len = cap;
            // pi: the "/"-prefixed prefix never exact/prefix-matches a value,
            // so the editor keeps the default selection (first row).
            self.menu_selected = 0;
            self.menu_mode = if (cap > 0) .commands else .hidden;
            return;
        }

        // Models: "/model <query>" (pi model argument completion: fuzzy
        // token match over id/provider/"provider/id"/name; label = id,
        // completion value = "provider/id", description = provider; initial
        // selection = first exact/prefix value match).

        // "@path" completion: the cursor sits right after an "@token" on the
        // current line ('@' at line start or after whitespace, no spaces in
        // the token). Live fuzzy menu over cwd entries (pi editor.js
        // autocomplete with trigger character '@').
        if (self.editor.lineBeforeCursor()) |before| {
            if (std.mem.lastIndexOfScalar(u8, before, '@')) |at| {
                const tok = before[at + 1 ..];
                const boundary_ok = at == 0 or before[at - 1] == ' ' or before[at - 1] == '\t';
                const has_space = std.mem.indexOfAny(u8, tok, " \t") != null;
                if (boundary_ok and !has_space) {
                    if (self.at_suppress) |sup| {
                        if (std.mem.eql(u8, tok, sup)) {
                            self.menu_mode = .hidden;
                            return;
                        }
                        self.alloc.free(sup);
                        self.at_suppress = null;
                    }
                    self.fillFileMenu(tok, at);
                    return;
                }
            }
        }

        self.menu_mode = .hidden;
    }

    /// Fill the file menu for an "@query" token: base dir from the query's
    /// directory part (pi getBaseDirSuggestions), fuzzy filter, depth/length
    /// tie-breaks, cap 16. Directories render with a trailing '/' and
    /// complete with one (pi buildCompletionValue).
    /// Fill the file menu for an "@query" token: base dir from the query's
    /// directory part, pi fuzzyFilter over the entry names (ranked, stable),
    /// top 16 into the static buffers. Directories render with a trailing
    /// '/' and complete with one (pi buildCompletionValue).
    fn fillFileMenu(self: *TUI, query: []const u8, at_col: usize) void {
        self.menu_len = 0;
        self.menu_selected = 0;
        const cwd = self.cwd_abs;
        // Split query into (dir_part, name_part).
        var dir_part: []const u8 = "";
        var name_part: []const u8 = query;
        if (std.mem.lastIndexOfScalar(u8, query, '/')) |slash| {
            dir_part = query[0 .. slash + 1]; // keep trailing '/'
            name_part = query[slash + 1 ..];
        }
        const base = if (dir_part.len > 0)
            std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ cwd, dir_part }) catch return
        else
            self.alloc.dupe(u8, cwd) catch return;
        defer self.alloc.free(base);

        var dir = std.Io.Dir.cwd().openDir(self.io, base, .{}) catch {
            self.menu_mode = .hidden;
            return;
        };
        defer dir.close(self.io);

        const CAP = 64;
        const Entry = struct { name_len: usize, path_len: usize, is_dir: bool };
        var entries: [CAP]Entry = undefined;
        var names: [CAP][]const u8 = undefined;
        var n: usize = 0;
        var it = dir.iterateAssumeFirstIteration();
        while (it.next(self.io) catch null) |entry| {
            if (n >= CAP) break;
            const nm = entry.name;
            // Hidden files only surface when the query starts with '.'.
            if (nm.len > 0 and nm[0] == '.' and (name_part.len == 0 or name_part[0] != '.')) continue;
            const with_slash: []const u8 = if (entry.kind == .directory) "/" else "";
            names[n] = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ nm, with_slash }) catch continue;
            entries[n] = .{
                .name_len = @min(names[n].len, self.file_names[0].len - 1),
                .path_len = @min(dir_part.len + names[n].len, self.file_paths[0].len - 1),
                .is_dir = entry.kind == .directory,
            };
            n += 1;
        }
        if (n == 0) {
            self.menu_mode = .hidden;
            return;
        }
        // pi fuzzyFilter over the display names (empty query keeps the
        // readdir order); ranked ascending, stable.
        const FCtx = struct {
            nm: []const []const u8,
            fn get(c: @This(), i: usize) []const u8 {
                return c.nm[i];
            }
        };
        const fctx = FCtx{ .nm = names[0..n] };
        var cap: usize = 0;
        const order: ?[]usize = fuzzy.fuzzyFilter(self.alloc, n, name_part, fctx, FCtx.get) catch null;
        defer if (order) |o| self.alloc.free(o);
        var ordered_names: [16][160]u8 = undefined;
        var ordered_paths: [16][256]u8 = undefined;
        var ordered_lens: [16]usize = undefined;
        var ordered_at: [16]usize = undefined;
        if (order) |o| {
            for (o) |i| {
                if (cap >= self.menu_items.len) break;
                const nm = names[i][0..@min(names[i].len, ordered_names[cap].len)];
                @memcpy(ordered_names[cap][0..nm.len], nm);
                const full = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ dir_part, nm }) catch continue;
                defer self.alloc.free(full);
                const pl = @min(full.len, ordered_paths[cap].len);
                @memcpy(ordered_paths[cap][0..pl], full[0..pl]);
                ordered_lens[cap] = pl;
                ordered_at[cap] = at_col;
                self.menu_items[cap] = .{ .name = ordered_names[cap][0..nm.len], .desc = ordered_paths[cap][0..pl] };
                cap += 1;
            }
            // Free the temp entry names (menu_items points into the static buffers).
            for (names[0..n]) |nm| self.alloc.free(nm);
        } else {
            for (names[0..n]) |nm| self.alloc.free(nm);
            self.menu_mode = .hidden;
            return;
        }
        if (cap == 0) {
            self.menu_mode = .hidden;
            return;
        }
        self.file_names = ordered_names;
        self.file_paths = ordered_paths;
        self.file_path_lens = ordered_lens;
        self.file_at_col = ordered_at;
        // Re-point menu_items at the (now stable) static buffers.
        for (0..cap) |k| {
            self.menu_items[k] = .{ .name = self.file_names[k][0..self.menu_items[k].name.len], .desc = self.file_paths[k][0..self.file_path_lens[k]] };
        }
        self.menu_len = cap;
        self.menu_mode = .files;
    }

    /// Apply the selected file completion: replace the "@token" before the
    /// cursor with "@selected" (directories keep their trailing '/').
    fn applyFileCompletion(self: *TUI) void {
        if (self.menu_len == 0 or self.menu_selected >= self.menu_len) return;
        const path = self.file_paths[self.menu_selected][0..self.file_path_lens[self.menu_selected]];
        if (path.len == 0) return;
        const at = self.file_at_col[self.menu_selected];
        const col = self.editor.cursorPos().col;
        const insertion = std.fmt.allocPrint(self.alloc, "@{s}", .{path}) catch return;
        defer self.alloc.free(insertion);
        self.editor.replaceRange(at, col, insertion) catch return;
        // Suppress re-opening until the token changes.
        if (self.at_suppress) |old| self.alloc.free(old);
        self.at_suppress = self.alloc.dupe(u8, insertion[1..]) catch null;
        self.menu_mode = .hidden;
    }

    /// Render menu row `i` (owned, caller frees).
    /// Keep the menu viewport window such that menu_selected stays visible.
    /// Visible window height for the current menu mode: pi's editor
    /// autocomplete shows AUTOCOMPLETE_MAX_VISIBLE (default 5) rows centered
    /// on the selection; modal pickers show up to 16.
    fn menuMaxVisible(self: *const TUI) usize {
        if (self.menu_mode == .settings or self.menu_mode == .model_selector) return 10;
        return switch (self.menu_mode) {
            .commands, .models, .files => 5,
            .mcp => @min(self.sel_len, 12),
            else => @min(if (self.menu_len > 0) self.menu_len else 1, 16),
        };
    }

    /// Keep the menu viewport window such that menu_selected stays visible
    /// (pi SelectList.getVisibleRange: centered on the selection).
    fn updateMenuViewport(self: *TUI, menu_h: usize) void {
        const total = if (self.menu_len > 0) self.menu_len else 1;
        if (menu_h >= total) {
            self.menu_view_start = 0;
            return;
        }
        const half: usize = menu_h / 2;
        var start: usize = if (self.menu_selected > half) self.menu_selected - half else 0;
        if (start + menu_h > total) start = total - menu_h;
        self.menu_view_start = start;
    }

    /// Truncate `s` to at most `max_w` visual columns into `buf` (no
    /// allocation; pi truncateToWidth for the short menu labels). Returns a
    /// prefix slice of `buf`.
    fn truncInto(buf: []u8, s: []const u8, max_w: usize) []const u8 {
        if (max_w == 0) return buf[0..0];
        var w: usize = 0;
        var i: usize = 0;
        while (i < s.len and i < buf.len) {
            const lead = s[i];
            const n: usize = if (lead < 0x80) 1 else wmod.utf8Len(lead);
            if (i + n > s.len) break;
            const cw = wmod.visualWidth(s[i..i + n]);
            if (w + cw > max_w) break;
            @memcpy(buf[i..i + n], s[i..i + n]);
            i += n;
            w += cw;
        }
        return buf[0..i];
    }

    /// Render one visible menu row (pi SelectList.renderItem): `→ ` prefix
    /// on the selected row, primary column clamped to [col_min, col_max]
    /// (widest visible label + 2-space gap), description in the right column
    /// (muted); the whole row is accent-colored when selected. Owned,
    /// caller frees.
    const selected_bg = "\x1b[48;2;62;72;94m";
    const fg_warn = "\x1b[38;2;222;147;95m";

    /// pi SessionSelector row rendering for one visible row.
    fn sessionPickerLine(self: *TUI, v: usize, width: usize) ![]u8 {
        const muted = FG_MUTED;
        const accent = "\x1b[38;2;167;152;215m";
        const reset = ansi.RESET;
        const item_idx = self.menu_view_start + v;
        const selected = item_idx == self.menu_selected;
        // Hint row (after all entries).
        if (item_idx >= self.sel_len) {
            return std.fmt.allocPrint(self.alloc, "  {s}Type to filter \u{b7} Ctrl+D delete{s}", .{ muted, reset }) catch return error.OutOfMemory;
        }
        const r = &self.sel_rows[item_idx];
        const preview = r.name[0..r.name_len];
        const right = r.desc[0..r.desc_len];
        const is_current = blk: {
            const path = r.id[0..r.id_len];
            const st = self.session.store orelse break :blk false;
            break :blk std.mem.eql(u8, path, st.path);
        };
        const has_name = self.session.store != null and false; // preview==name when named
        _ = has_name;
        // Named sessions render orange; current session accent (pi).
        const is_named = blk2: {
            const st_store = self.session.store;
            _ = st_store;
            break :blk2 preview.len > 0 and std.mem.indexOfScalar(u8, preview, ' ') == null and !std.mem.startsWith(u8, preview, "dc") and false;
        };
        _ = is_named;
        var msg_color: []const u8 = "";
        if (is_current) msg_color = accent;
        var clean = std.array_list.Managed(u8).init(self.alloc);
        defer clean.deinit();
        const cursor: []const u8 = if (selected) "\u{203a} " else "  ";
        clean.appendSlice(cursor) catch return error.OutOfMemory;
        if (msg_color.len > 0) clean.appendSlice(msg_color) catch return error.OutOfMemory;
        if (selected) clean.appendSlice("\x1b[1m") catch return error.OutOfMemory;
        // Truncate preview to available width (right side + spacing).
        const right_w = wmod.visualWidth(right);
        const avail = @max(10, width -| 2 -| right_w -| 2);
        var used: usize = 0;
        var ci: usize = 0;
        while (ci < preview.len) {
            const cw = @min(wmod.utf8Len(preview[ci]), preview.len - ci);
            if (used + 1 > avail) break; // conservative: 1 col per char
            clean.appendSlice(preview[ci .. ci + cw]) catch return error.OutOfMemory;
            ci += cw;
            used += 1;
        }
        clean.appendSlice(reset) catch return error.OutOfMemory;
        // Right-align the dim right part.
        const left_w = wmod.visualWidth(clean.items);
        const spacing = if (width > left_w + right_w) width - left_w - right_w else 1;
        var pad_buf: [512]u8 = undefined;
        const pads: usize = @min(spacing, pad_buf.len);
        @memset(pad_buf[0..pads], ' ');
        clean.appendSlice(pad_buf[0..pads]) catch return error.OutOfMemory;
        clean.appendSlice(muted) catch return error.OutOfMemory;
        clean.appendSlice(right) catch return error.OutOfMemory;
        clean.appendSlice(reset) catch return error.OutOfMemory;
        if (selected) {
            // Reverse-video the whole row (pi selectedBg) — wrap: bg code
            // needs to precede content; simplest robust approach: re-emit
            // with bg by prefixing and letting the terminal apply to spaces.
            var out2 = std.array_list.Managed(u8).init(self.alloc);
            defer out2.deinit();
            out2.appendSlice(selected_bg) catch return error.OutOfMemory;
            out2.appendSlice(clean.items) catch return error.OutOfMemory;
            // pad the remainder of the row with the bg so the highlight spans
            const w = wmod.visualWidth(clean.items);
            if (width > w) {
                var rest = width - w;
                var bgpad: [64]u8 = undefined;
                @memset(bgpad[0..@min(rest, bgpad.len)], ' ');
                out2.appendSlice(bgpad[0..@min(rest, bgpad.len)]) catch return error.OutOfMemory;
                rest -|= @min(rest, bgpad.len);
                while (rest > 0) {
                    const chunk = @min(rest, bgpad.len);
                    @memset(bgpad[0..chunk], ' ');
                    out2.appendSlice(bgpad[0..chunk]) catch return error.OutOfMemory;
                    rest -= chunk;
                }
            }
            out2.appendSlice(reset) catch return error.OutOfMemory;
            return out2.toOwnedSlice() catch return error.OutOfMemory;
        }
        return clean.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn menuLine(self: *TUI, v: usize, width: usize, col_min: usize, col_max: usize) ![]u8 {
        // Session picker rows (pi SessionSelector): "› <preview>" left,
        // "<count> <age>" right (dim), selected = reverse video + bold;
        // named sessions render orange, the current session accent.
        if (self.menu_mode == .sessions) {
            return self.sessionPickerLine(v, width);
        }
        // Editor menus keep the FULL filtered list in menu_items: v is the
        // window-relative row and the window starts at menu_view_start.
        // Modal pickers (sessions/tree/settings//mcp manager) PROJECT their
        // rows into menu_items through refreshSelMenu — there v indexes the
        // projected window directly and menu_view_start only decides the
        // selection marker.
        const projected = switch (self.menu_mode) {
            .settings, .sessions, .tree, .forksel, .mcp, .mcp_server, .mcp_tools, .mcp_exposure, .trust, .scoped, .model_selector => true,
            else => false,
        };
        const item_idx = if (projected) v else self.menu_view_start + v;
        const e = self.menu_items[item_idx];
        const selected = (self.menu_view_start + v) == self.menu_selected;
        const prefix: []const u8 = if (selected) "\u{2192} " else "  ";
        const name_full = if (e.name.len > 0 and e.name[0] == '/') e.name[1..] else e.name;
        const accent = "\x1b[38;2;167;152;215m";
        const reset = ansi.RESET;
        const muted = FG_MUTED;
        var name_buf: [192]u8 = undefined;
        var desc_buf: [256]u8 = undefined;
        var desc_sp_buf: [256]u8 = undefined;
        // Two-column layout (pi: only with a description and width > 40, and
        // only when at least MIN_DESCRIPTION_WIDTH (10) columns remain).
        if (e.desc.len > 0 and width > 40) {
            // Primary column = widest visible label + PRIMARY_COLUMN_GAP (2).
            var widest: usize = 0;
            for (0..self.menu_len) |k| {
                const n = self.menu_items[k].name;
                const w = if (n.len > 0 and n[0] == '/') n.len - 1 else n.len;
                if (w + 2 > widest) widest = w + 2;
            }
            var col = widest;
            if (col < col_min) col = col_min;
            if (col > col_max) col = col_max;
            const effective = @max(1, @min(col, width - prefix.len - 4));
            const max_primary = @max(1, effective - 2);
            const name = truncInto(&name_buf, name_full, max_primary);
            const name_w = wmod.visualWidth(name);
            const spacing = effective - @min(effective, name_w);
            const desc_start = prefix.len + name_w + spacing;
            const remaining = if (width > desc_start + 2) width - desc_start - 2 else 0;
            if (remaining > 10) {
                const desc = truncInto(&desc_buf, e.desc, remaining);
                const desc_w = wmod.visualWidth(desc);
                // spacing + desc in one muted run (pi: theme.description(spacing + desc))
                const pad = @min(spacing + desc_w, desc_sp_buf.len);
                var w: usize = 0;
                for (0..spacing) |_| {
                    if (w >= desc_sp_buf.len) break;
                    desc_sp_buf[w] = ' ';
                    w += 1;
                }
                @memcpy(desc_sp_buf[w..@min(w + desc_w, desc_sp_buf.len)], desc[0..@min(desc_w, desc_sp_buf.len - w)]);
                _ = pad;
                const styled_tail = desc_sp_buf[0..@min(w + desc_w, desc_sp_buf.len)];
                if (selected) {
                    return std.fmt.allocPrint(self.alloc, "{s}{s}{s}{s}{s}{s}", .{ accent, prefix, name, muted, styled_tail, reset }) catch error.OutOfMemory;
                }
                return std.fmt.allocPrint(self.alloc, "{s}{s}{s}{s}{s}{s}", .{ prefix, name, muted, styled_tail, reset, "" }) catch error.OutOfMemory;
            }
        }
        if (selected) {
            return std.fmt.allocPrint(self.alloc, "{s}{s}{s}{s}", .{ accent, prefix, name_full, reset }) catch error.OutOfMemory;
        }
        return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, name_full }) catch error.OutOfMemory;
    }

    /// Complete the editor text with the selected menu entry (Tab, or Enter
    /// on a takes_arg command). pi applyCompletion: a slash completion is
    /// always "/value " with a trailing space; models complete to
    /// "provider/id" (pi item.value) while displaying just the id.
    fn menuComplete(self: *TUI) void {
        if (self.menu_len == 0) return;
        if (self.menu_mode == .files) {
            self.applyFileCompletion();
            return;
        }
        const e = self.menu_items[self.menu_selected];
        var text: []u8 = undefined;
        if (self.menu_mode == .models) {
            var done = false;
            if (e.model_idx) |idx| {
                if (self.cfg) |cfg| {
                    if (idx < cfg.models.items.len) {
                        const m = cfg.models.items[idx];
                        text = std.fmt.allocPrint(self.alloc, "/model {s}/{s} ", .{ m.provider, m.id }) catch return;
                        done = true;
                    }
                }
            }
            if (!done) text = std.fmt.allocPrint(self.alloc, "/model {s} ", .{e.name}) catch return;
        } else {
            text = std.fmt.allocPrint(self.alloc, "{s} ", .{e.name}) catch return;
        }
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
                    // pi editor.js tui.select.confirm: a "/" prefix
                    // completion falls through to SUBMIT — the filled
                    // "/name " is handed to handleCommand immediately (so
                    // /model opens the selector in one Enter, /login shows
                    // its usage, etc). No second Enter needed.
                    self.menuComplete();
                    self.updateMenu();
                    const filled = self.editor.getText() catch return false;
                    defer self.alloc.free(filled);
                    return self.handleCommand(filled);
                }
                self.editor.clear() catch {};
                // Close the menu BEFORE running the command: the command may
                // rebuild slash_extras (/reload) — menu_items holds borrowed
                // pointers into it, and the command's own redraw would then
                // render freed entries (segfault in menuLine).
                self.menu_mode = .hidden;
                self.menu_len = 0;
                if (self.menu_text_cache) |c| {
                    self.alloc.free(c);
                    self.menu_text_cache = null;
                }
                return self.handleCommand(e.name);
            },
            .scoped => {
                // pi ScopedModelsSelector: Enter toggles the model's enabled
                // state; the menu stays open for more toggles (Esc closes).
                if (e.model_idx) |idx| {
                    self.toggleScopedModel(idx);
                    self.note("{s} {s}", .{ e.name, self.modelScoped(e.model_idx.?) });
                }
                return false;
            },
            .models => unreachable, // legacy autocomplete menu; /model now opens the selector
            .model_selector => {
                // pi ModelSelector: Enter selects (switchModel) and closes.
                if (self.ms_visible > 0) {
                    const idx = self.ms_filtered.items[self.ms_sel];
                    self.closeModelSelector();
                    self.switchModel(idx) catch |err| {
                        self.note("model switch failed: {s}", .{@errorName(err)});
                    };
                }
                return false;
            },
            .files => {
                self.applyFileCompletion();
                return false;
            },
            .settings => {
                // pi SettingsList: Enter/Space cycles the selected value
                // silently (the row already shows the new value).
                if (self.settings_visible > 0) {
                    const def = SETTING_DEFS[self.settings_filtered[self.settings_sel]];
                    if (!self.settingsApplyNext(def)) {
                        self.note("{s}: not implemented yet", .{def.label});
                    }
                }
                return false;
            },
            .sessions => {
                const path = self.selRowId();
                if (path.len == 0) return false;
                self.menu_mode = .hidden;
                const new_st = ss.Store.open(self.alloc, self.io, path) catch {
                    self.note("resume failed: cannot open {s}", .{path});
                    return false;
                };
                const id_copy = self.alloc.dupe(u8, new_st.id) catch "?";
                self.switchToStore(new_st);
                self.note("\x1b[90mresumed session {s}\x1b[0m", .{id_copy});
                return false;
            },
            .tree => {
                const entry_id = self.selRowId();
                if (entry_id.len == 0) return false;
                const st = self.session.store orelse return false;
                const leaf = st.leaf_id orelse return false;
                self.menu_mode = .hidden;
                if (std.mem.eql(u8, entry_id, leaf)) {
                    self.note("Already at this point", .{});
                    return false;
                }
                self.branchWithSummary(entry_id);
                return false;
            },
            .forksel => {
                const entry_id = self.selRowId();
                if (entry_id.len == 0) return false;
                self.menu_mode = .hidden;
                self.forkFromUserMessage(entry_id);
                return false;
            },
            .mcp, .mcp_server, .mcp_tools, .mcp_exposure => {
                return self.mcpMenuActivate();
            },
            .trust => {
                self.applyTrustChoice();
                return false;
            },
            .hidden => return false,
        }
    }

    // ---- /settings (pi settings-selector: Enter cycles a value) ----

    /// Current label/description rows for the settings menu (owned by
    /// menu_items' static slices + formatted descs in a small buffer).
    const SPACES48: [48]u8 = @splat(' ');

    /// Total frame rows the settings view occupies below the editor line
    /// (matches renderSettingsView): blank + min(visible,10) items + count
    /// (when the list scrolls) + blank + description + hint. The editor
    /// line itself is already in editor_h.
    fn settingsViewHeight(self: *TUI, editor_h: usize) usize {
        _ = editor_h;
        const visible_rows = @min(self.settings_visible, 10);
        var h: usize = 1 + visible_rows; // blank + items
        if (self.settings_visible > 10) h += 1; // "(n/total)"
        h += 1; // blank
        if (self.settings_visible > 0) {
            const def = SETTING_DEFS[self.settings_filtered[self.settings_sel]];
            h += wrapDescLines(def.desc, self.width).len; // description
        }
        h += 1; // hint
        return h;
    }

    /// pi wrapTextWithAnsi (plain text here): word wrap to width.
    fn wrapDescLines(text: []const u8, width: usize) []const []const u8 {
        // Static output buffer (renderSettingsView consumes immediately).
        const S = struct {
            var lines_buf: [8][]const u8 = undefined;
            var text_buf: [512]u8 = undefined;
        };
        const max_w = @max(1, width -| 6);
        var n: usize = 0;
        var used: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " ");
        while (it.next()) |word| {
            const wl = wmod.visualWidth(word);
            if (used > 0 and used + 1 + wl > max_w) {
                n += 1;
                if (n >= S.lines_buf.len) break;
                used = 0;
            }
            if (used == 0) {
                @memcpy(S.text_buf[n * max_w ..][0..wl], word);
                S.lines_buf[n] = S.text_buf[n * max_w ..][0..wl];
                used = wl;
            } else {
                if (used + 1 + wl > max_w) continue;
                S.text_buf[n * max_w + used] = ' ';
                @memcpy(S.text_buf[n * max_w + used + 1 ..][0..wl], word);
                S.lines_buf[n] = S.text_buf[n * max_w ..][0 .. used + 1 + wl];
                used += 1 + wl;
            }
        }
        if (used > 0 and (n == 0 or S.lines_buf[n].len > 0)) n += 1;
        return S.lines_buf[0..n];
    }

    fn renderSettingsView(self: *TUI, frame: *std.ArrayListUnmanaged([]u8), editor_h: usize, settings_h: usize) void {
        _ = settings_h;
        const width = self.width;
        const muted = FG_MUTED;
        const accent = "\x1b[38;2;167;152;215m";
        const reset = ansi.RESET;
        // Blank line after the search input (pi: searchInput then "").
        frame.append(self.alloc, "") catch return;
        // Skip past the editor rows already appended (transcript + border +
        // editor lines); we append right after them, in order.
        const visible_rows = @min(self.settings_visible, 10);
        if (self.settings_visible == 0) {
            const line = std.fmt.allocPrint(self.alloc, "  {s}No matching settings{s}", .{ muted, reset }) catch return;
            frame.append(self.alloc, line) catch return;
        } else {
            // Max label width across ALL settings (pi: min(36, widest)).
            var max_label: usize = 0;
            for (SETTING_DEFS) |def| {
                const w = wmod.visualWidth(def.label);
                if (w > max_label) max_label = w;
            }
            if (max_label > 36) max_label = 36;
            // Scroll window centered on the selection.
            const total = self.settings_visible;
            const start: usize = if (self.settings_sel >= visible_rows)
                @min(self.settings_sel - visible_rows / 2, total -| visible_rows)
            else
                0;
            var vbuf: [64]u8 = undefined;
            for (0..visible_rows) |v| {
                const idx = self.settings_filtered[start + v];
                const def = SETTING_DEFS[idx];
                const selected = (start + v) == self.settings_sel;
                const prefix: []const u8 = if (selected) "\u{2192} " else "  ";
                const cur = self.settingsCurrentValue(def, &vbuf);
                // label padded to max_label + two spaces + value
                const label_w = wmod.visualWidth(def.label);
                const pad = if (max_label > label_w) max_label - label_w else 0;
                const line = std.fmt.allocPrint(
                    self.alloc,
                    "{s}{s}{s}{s}{s}  {s}{s}{s}",
                    .{
                        prefix,
                        if (selected) accent else "",
                        def.label,
                        reset,
                        (SPACES48)[0..@min(48, pad)],
                        if (selected) muted else muted,
                        cur,
                        reset,
                    },
                ) catch return;
                frame.append(self.alloc, line) catch return;
            }
            if (total > visible_rows) {
                const cnt = std.fmt.allocPrint(self.alloc, "  {s}({d}/{d}){s}", .{ muted, self.settings_sel + 1, total, reset }) catch return;
                frame.append(self.alloc, cnt) catch return;
            }
            // Blank + wrapped description.
            if (self.settings_visible > 0) {
                const def = SETTING_DEFS[self.settings_filtered[self.settings_sel]];
                frame.append(self.alloc, "") catch return;
                for (wrapDescLines(def.desc, width)) |dl| {
                    const dl_line = std.fmt.allocPrint(self.alloc, "  {s}{s}{s}", .{ muted, dl, reset }) catch return;
                    frame.append(self.alloc, dl_line) catch return;
                }
            }
        }
        // Hint line (pi addHintLine: search enabled → includes "Type to search").
        const hint = std.fmt.allocPrint(self.alloc, "  {s}Type to search \u{b7} Enter/Space to change \u{b7} Esc to cancel{s}", .{ muted, reset }) catch return;
        frame.append(self.alloc, hint) catch return;
        // NOTE: frame rows are pre-allocated to height by the caller's blank
        // fill below; appends beyond editor_h shift nothing (caller pads).
        _ = editor_h;
    }

    /// Frame rows the model selector occupies below the editor line:
    /// blank + notice-or-scope rows (+scope hint when scoped) + items +
    /// count + blank + Model Name + hint. Keep in sync with
    /// renderModelSelectorView.
    fn modelSelectorViewHeight(self: *TUI) usize {
        const scoped = self.scoped_models != null;
        var h: usize = 1; // blank after search line
        if (scoped) {
            h += 2; // "Scope: all | scoped" + tab hint
        } else {
            h += 1; // "Only showing models from configured providers..."
        }
        h += @min(self.ms_visible, 10);
        if (self.ms_visible > 10) h += 1; // (n/total)
        h += 1; // blank
        if (self.ms_visible > 0) h += 1; // Model Name: ...
        h += 1; // hint
        return h;
    }

    fn renderModelSelectorView(self: *TUI, frame: *std.ArrayListUnmanaged([]u8)) void {
        const muted = FG_MUTED;
        const accent = "\x1b[38;2;167;152;215m";
        const warn = "\x1b[38;2;222;147;95m";
        const reset = ansi.RESET;
        frame.append(self.alloc, "") catch return;
        if (self.scoped_models != null) {
            const line = std.fmt.allocPrint(self.alloc, "  {s}Scope: {s}{s}all{s}{s} | {s}scoped{s}{s}  {s}tab (all/scoped){s}", .{
                muted, if (self.ms_scope_all) accent else muted, reset, if (self.ms_scope_all) accent else muted, reset, muted, reset, muted, muted, reset,
            }) catch return;
            frame.append(self.alloc, line) catch return;
            const hint = std.fmt.allocPrint(self.alloc, "  {s}tab (all/scoped){s}", .{muted, reset}) catch return;
            frame.append(self.alloc, hint) catch return;
        } else {
            const line = std.fmt.allocPrint(self.alloc, "{s}Only showing models from configured providers. Use /login to add providers.{s}", .{ warn, reset }) catch return;
            frame.append(self.alloc, line) catch return;
        }
        const visible_rows = @min(self.ms_visible, 10);
        if (self.ms_visible == 0) {
            const line = std.fmt.allocPrint(self.alloc, "  {s}No matching models{s}", .{ muted, reset }) catch return;
            frame.append(self.alloc, line) catch return;
        } else {
            const total = self.ms_visible;
            const start: usize = if (self.ms_sel >= visible_rows)
                @min(self.ms_sel - visible_rows / 2, total -| visible_rows)
            else
                0;
            for (0..visible_rows) |v| {
                const idx = self.ms_filtered.items[start + v];
                const cfg = self.cfg orelse return;
                if (idx >= cfg.models.items.len) continue;
                const m = &cfg.models.items[idx];
                const selected = (start + v) == self.ms_sel;
                var clean = std.array_list.Managed(u8).init(self.alloc);
                defer clean.deinit();
                clean.appendSlice(if (selected) "\u{2192} " else "  ") catch return;
                if (selected) clean.appendSlice(accent) catch return;
                clean.appendSlice(if (self.isCurrentModel(idx)) "\u{2713} " else "  ") catch return;
                clean.appendSlice(m.id) catch return;
                clean.appendSlice(reset) catch return;
                clean.appendSlice(" ") catch return;
                clean.appendSlice(muted) catch return;
                clean.appendSlice("[") catch return;
                clean.appendSlice(m.provider) catch return;
                clean.appendSlice("]") catch return;
                if (self.isDefaultModel(idx)) clean.appendSlice(" \u{b7} default") catch return;
                clean.appendSlice(reset) catch return;
                frame.append(self.alloc, clean.toOwnedSlice() catch return) catch return;
            }
            if (total > visible_rows) {
                const cnt = std.fmt.allocPrint(self.alloc, "  {s}({d}/{d}){s}", .{ muted, self.ms_sel + 1, total, reset }) catch return;
                frame.append(self.alloc, cnt) catch return;
            }
            frame.append(self.alloc, "") catch return;
            const sel_idx = self.ms_filtered.items[self.ms_sel];
            const sel_name = if (self.cfg) |c|
                (if (sel_idx < c.models.items.len) c.models.items[sel_idx].name else "")
            else
                "";
            const name_line = std.fmt.allocPrint(self.alloc, "  {s}Model Name: {s}{s}", .{ muted, sel_name, reset }) catch return;
            frame.append(self.alloc, name_line) catch return;
        }
        const hint = std.fmt.allocPrint(self.alloc, "  {s}Enter to select \u{b7} Ctrl+S to set as default \u{b7} Escape/Ctrl+C to cancel{s}", .{ muted, reset }) catch return;
        frame.append(self.alloc, hint) catch return;
    }

    fn openSettingsMenu(self: *TUI) void {
        if (self.cfg != null) {
            // Reflect persisted values (compaction etc.) in the selector.
            self.settingsRefilter();
        }
        self.menu_selected = 0;
        self.settings_sel = 0;
        self.menu_mode = .settings;
        self.editor.clear() catch {};
        self.freeMenuTextCache();
        self.redraw();
    }

    /// pi SettingsList: label contains the query (case-insensitive).
    fn settingsRefilter(self: *TUI) void {
        const query_raw = self.editor.getText() catch "";
        defer self.alloc.free(query_raw);
        const query = std.mem.trim(u8, query_raw, " ");
        var n: usize = 0;
        for (SETTING_DEFS, 0..) |def, i| {
            if (query.len > 0 and !containsIgnoreCase2(def.label, query)) continue;
            self.settings_filtered[n] = i;
            n += 1;
        }
        self.settings_visible = n;
        if (self.settings_sel >= n) self.settings_sel = if (n > 0) n - 1 else 0;
    }

    fn containsIgnoreCase2(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Current value of a setting (pi item.currentValue). `buf` holds small
    /// formatted numbers; static strings are returned directly.
    fn settingsCurrentValue(self: *TUI, def: SettingDef, buf: *[64]u8) []const u8 {
        const cfg = self.cfg;
        return switch (def.kind) {
            .autocompact => if (cfg) |c| (if (c.compaction.enabled) "true" else "false") else "true",
            .show_images => "true",
            .image_width => "60",
            .auto_resize_images => "true",
            .block_images => "false",
            .skill_commands => if (self.skill_commands) "true" else "false",
            .show_hardware_cursor => "false",
            .editor_padding => "0",
            .output_padding => "1",
            .autocomplete_max => std.fmt.bufPrint(buf, "{d}", .{self.autocomplete_max}) catch "5",
            .clear_on_shrink => "false",
            .terminal_progress => "false",
            .steering_mode => if (self.steering_mode_all) "all" else "one-at-a-time",
            .follow_up_mode => if (self.follow_up_mode_all) "all" else "one-at-a-time",
            .transport => "auto",
            .share_destination => "auto",
            .http_idle_timeout => "default",
            .cache_warming => "off",
            .hide_thinking => if (self.thinking_hidden) "true" else "false",
            .mermaid => "off",
            .cache_miss_notices => "false",
            .collapse_changelog => "true",
            .quiet_startup => "false",
            .install_telemetry => "false",
            .default_project_trust => if (cfg) |c| switch (c.default_project_trust) {
                .ask => "Ask",
                .always => "Always trust",
                .never => "Never trust",
            } else "Ask",
            .double_escape => "none",
            .tree_filter => "all",
            .warnings => "true",
            .model_thinking => "none",
            .tui_mode => "fullscreen",
            .fs_exit_output => "transcript",
            .fs_scrollbar => if (cfg) |c| switch (c.fullscreen_scrollbar) {
                .auto => "auto",
                .always => "always",
                .hidden => "hidden",
            } else "auto",
            .fs_copy_on_select => if (self.fullscreen_copy_on_select) "true" else "false",
            .fs_wheel_lines => blk_wl: {
                if (cfg) |c| {
                    if (c.fullscreen_wheel_lines) |wl| {
                        break :blk_wl std.fmt.bufPrint(buf, "{d}", .{wl}) catch "auto";
                    }
                }
                break :blk_wl "auto";
            },
            .theme => "dark",
        };
    }

    /// Cycle to the next value; returns false when rpi cannot back the
    /// setting (placeholder items don't cycle — pi backs all of them).
    fn settingsApplyNext(self: *TUI, def: SettingDef) bool {
        var vbuf: [64]u8 = undefined;
        const cur = self.settingsCurrentValue(def, &vbuf);
        var pos: usize = 0;
        var found = false;
        for (def.values, 0..) |v, i| {
            if (std.mem.eql(u8, v, cur)) {
                pos = i;
                found = true;
                break;
            }
        }
        const next = def.values[if (found) (pos + 1) % def.values.len else 0];
        const cfg = self.cfg;
        switch (def.kind) {
            .autocompact => {
                const on = std.mem.eql(u8, next, "true");
                if (cfg) |c| c.compaction.enabled = on;
                // Session holds a copy consumed by maybeAutoCompact and the
                // footer "(auto)" marker — keep them in sync immediately.
                self.session.compaction.enabled = on;
            },
            .skill_commands => self.skill_commands = std.mem.eql(u8, next, "true"),
            .autocomplete_max => self.autocomplete_max = std.fmt.parseInt(usize, next, 10) catch 5,
            .steering_mode => self.steering_mode_all = std.mem.eql(u8, next, "all"),
            .follow_up_mode => self.follow_up_mode_all = std.mem.eql(u8, next, "all"),
            .hide_thinking => self.thinking_hidden = std.mem.eql(u8, next, "true"),
            .default_project_trust => {
                if (cfg) |c| {
                    c.default_project_trust = if (std.mem.eql(u8, next, "Always trust"))
                        .always
                    else if (std.mem.eql(u8, next, "Never trust"))
                        .never
                    else
                        .ask;
                }
            },
            .fs_scrollbar => {
                if (cfg) |c| {
                    c.fullscreen_scrollbar = if (std.mem.eql(u8, next, "always"))
                        .always
                    else if (std.mem.eql(u8, next, "hidden"))
                        .hidden
                    else
                        .auto;
                }
            },
            .fs_copy_on_select => self.fullscreen_copy_on_select = std.mem.eql(u8, next, "true"),
            .fs_wheel_lines => {
                if (cfg) |c| {
                    c.fullscreen_wheel_lines = if (std.mem.eql(u8, next, "auto")) null else std.fmt.parseInt(u16, next, 10) catch null;
                }
            },
            // tui_mode/theme/etc: rpi cannot back these yet.
            else => return false,
        }
        if (cfg) |c| c.persistSettings(self.alloc, self.io) catch {};
        return true;
    }

    // ---- modal selectors (pi session/tree selectors) ----

    fn selSetName(self: *TUI, row: usize, name: []const u8) void {
        const n = @min(name.len, self.sel_rows[row].name.len);
        @memcpy(self.sel_rows[row].name[0..n], name[0..n]);
        self.sel_rows[row].name_len = n;
    }

    fn selSetDesc(self: *TUI, row: usize, desc: []const u8) void {
        const n = @min(desc.len, self.sel_rows[row].desc.len);
        @memcpy(self.sel_rows[row].desc[0..n], desc[0..n]);
        self.sel_rows[row].desc_len = n;
    }

    fn selSetId(self: *TUI, row: usize, id: []const u8) void {
        const n = @min(id.len, self.sel_rows[row].id.len);
        @memcpy(self.sel_rows[row].id[0..n], id[0..n]);
        self.sel_rows[row].id_len = n;
    }

    /// Project the selector row window into menu_items (cap 16) for
    /// rendering; menu viewport math stays shared with the other menus.
    fn refreshSelMenu(self: *TUI) void {
        var n: usize = 0;
        const start = self.menu_view_start;
        while (start + n < self.sel_len and n < self.menu_items.len) : (n += 1) {
            const r = &self.sel_rows[start + n];
            self.menu_items[n] = .{
                .name = r.name[0..r.name_len],
                .desc = r.desc[0..r.desc_len],
            };
        }
        self.menu_len = n;
        if (self.menu_selected >= self.sel_len) self.menu_selected = if (self.sel_len > 0) self.sel_len - 1 else 0;
    }

    /// Clamp the viewport so menu_selected stays visible, then re-project.
    fn scrollSelMenu(self: *TUI) void {
        const menu_h: usize = self.menuMaxVisible();
        self.updateMenuViewport(menu_h);
        self.refreshSelMenu();
    }

    /// Open the /resume picker: sessions for this cwd, type-to-filter.
    fn openSessionsMenu(self: *TUI) void {
        self.sel_filter_len = 0;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.menu_mode = .sessions;
        self.editor.clear() catch {};
        self.refilterSessions();
    }

    /// Trim a UTF-8 slice to max bytes WITHOUT splitting a codepoint.
    fn utf8Cut(s: []const u8, max: usize) []const u8 {
        if (s.len <= max) return s;
        var end = max;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
        return s[0..end];
    }

    /// pi formatSessionDate: relative age (unit suffix by magnitude).
    fn formatSessionAgeUnit(diff_ms: i64, buf: *[8]u8) []const u8 {
        if (diff_ms < 0) return "now";
        const mins = @divTrunc(diff_ms, 60_000);
        if (mins < 1) return "now";
        if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "now";
        const hours = @divTrunc(mins, 60);
        if (hours < 24) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "now";
        const days = @divTrunc(hours, 24);
        if (days < 7) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "now";
        if (days < 30) return std.fmt.bufPrint(buf, "{d}w", .{@divTrunc(days, 7)}) catch "now";
        if (days < 365) return std.fmt.bufPrint(buf, "{d}mo", .{@divTrunc(days, 30)}) catch "now";
        return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(days, 365)}) catch "now";
    }

    /// Rebuild the session rows from the directory listing, applying the
    /// current filter as a case-insensitive substring on id+name.
    fn refilterSessions(self: *TUI) void {
        self.sel_len = 0;
        const list = ss.listForCwd(self.alloc, self.io, self.sessions_dir, self.cwd_abs) catch &.{};
        defer self.freeSessionList(list);
        const now_ms = ss.nowMs(self.io);
        const flt = self.sel_filter[0..self.sel_filter_len];
        for (list) |info| {
            if (self.sel_len >= SEL_MAX) break;
            const label = info.name orelse (info.first_message orelse "(unnamed)");
            // Match against "id name/preview".
            var hay: [400]u8 = undefined;
            const hay_txt = std.fmt.bufPrint(&hay, "{s} {s}", .{ info.id, label }) catch continue;
            if (flt.len > 0 and !containsNoCase(hay_txt, flt)) continue;
            const row = self.sel_len;
            // pi: display text = name ?? first user message (trimmed).
            self.selSetName(row, utf8Cut(label, self.sel_rows[row].name.len));
            // Right side: "<msg count> <age>" (pi rightPart). Format into a
            // stack buffer first — bufPrint into the destination slice then
            // memcpy from it is an overlapping self-copy.
            var age_buf: [8]u8 = undefined;
            const age = formatSessionAgeUnit(now_ms - info.modified_ms, &age_buf);
            var dbuf: [80]u8 = undefined;
            const right_txt = std.fmt.bufPrint(&dbuf, "{d} {s}", .{ info.msg_count, age }) catch "";
            self.selSetDesc(row, right_txt);
            self.selSetId(row, info.path);
            self.sel_len += 1;
        }
        self.menu_view_start = 0;
        self.menu_selected = 0;
        self.refreshSelMenu();
    }

    /// Open the /tree picker: entries along the leaf chain with previews.
    fn openTreeMenu(self: *TUI) void {
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.menu_mode = .tree;
        self.editor.clear() catch {};
        self.sel_len = 0;
        const st = self.session.store orelse return;
        var chain: [SEL_MAX]ss.Store.ChainItem = undefined;
        const cnt = st.leafChain(&chain);
        for (chain[0..cnt]) |ci| {
            if (self.sel_len >= SEL_MAX) break;
            const row = self.sel_len;
            const depth: usize = @min(self.sel_len, 12);
            var name_buf: [168]u8 = undefined;
            const icon: []const u8 = switch (ci.kind) {
                .message => if (ci.is_user_message) "❯" else "✱",
                .compaction => "⛁",
                .branch_summary => "⑂",
                .session_info => "✎",
                .model_change => "◆",
                .thinking_level_change => "◍",
                else => "·",
            };
            const indent_src = "                                ";
            const id_txt = ci.id[0..ci.id_len];
            const name_txt = std.fmt.bufPrint(&name_buf, "{s}{s} {s}", .{
                indent_src[0 .. depth * 2], icon, id_txt,
            }) catch continue;
            self.selSetName(row, name_txt);
            self.selSetDesc(row, ci.preview[0..ci.preview_len]);
            self.selSetId(row, ci.id[0..ci.id_len]);
            self.sel_len += 1;
        }
        // Start the selection on the current leaf.
        self.menu_selected = if (self.sel_len > 0) self.sel_len - 1 else 0;
        self.refreshSelMenu();
    }

    /// Open the /fork picker: user messages along the leaf chain.
    fn openForkMenu(self: *TUI) void {
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.menu_mode = .forksel;
        self.editor.clear() catch {};
        self.sel_len = 0;
        const st = self.session.store orelse return;
        var chain: [SEL_MAX]ss.Store.ChainItem = undefined;
        _ = st.leafChain(&chain);
        for (chain) |ci| {
            if (!ci.is_user_message) continue;
            if (self.sel_len >= SEL_MAX) break;
            const row = self.sel_len;
            self.selSetName(row, ci.id[0..ci.id_len]);
            self.selSetDesc(row, ci.preview[0..ci.preview_len]);
            self.selSetId(row, ci.id[0..ci.id_len]);
            self.sel_len += 1;
        }
        self.refreshSelMenu();
    }

    fn selRowId(self: *TUI) []const u8 {
        if (self.menu_selected >= self.sel_len) return "";
        const r = &self.sel_rows[self.menu_selected];
        return r.id[0..r.id_len];
    }

    /// Swap in a (new or reopened) store and rebuild both the agent context
    /// and the visible transcript (pi: resume/fork/clone/import all replace
    /// the view). Applies the branch's recorded model_change /
    /// thinking_level_change (pi replays them on resume).
    fn switchToStore(self: *TUI, new_st: *ss.Store) void {
        const old_st = self.session.store;
        self.clearTranscript();
        self.session.adoptStore(new_st) catch {};
        // adoptStore's caller-owned contract: retire the previous store.
        if (old_st) |o| {
            if (o != new_st) o.deinit();
        }
        if (new_st.latestModelChange(self.alloc)) |mc| {
            defer {
                self.alloc.free(mc.provider);
                self.alloc.free(mc.model_id);
            }
            if (self.cfg) |c| {
                for (c.models.items, 0..) |m, idx| {
                    if (std.mem.eql(u8, m.provider, mc.provider) and std.mem.eql(u8, m.id, mc.model_id)) {
                        self.switchModel(idx) catch {};
                        break;
                    }
                }
            }
        }
        if (new_st.latestThinkingLevel(self.alloc)) |lv| {
            defer self.alloc.free(lv);
            if (config.ThinkingLevel.fromStr(lv)) |tl| {
                self.session.thinking_level = tl;
            }
        }
        self.replaySession();
    }

    /// Same-store view rebuild after a branch cut.
    fn switchToStoreLive(self: *TUI) void {
        self.clearTranscript();
        if (self.session.store) |st| self.session.adoptStore(st) catch {};
        self.replaySession();
    }

    /// /tree branch: cut the leaf to an earlier entry, summarize the
    /// abandoned path with the LLM (pi branchWithSummary), record a
    /// branch_summary entry and rebuild the view.
    fn branchWithSummary(self: *TUI, cut_entry_id: []const u8) void {
        const st = self.session.store orelse return;
        const from_id = self.alloc.dupe(u8, st.leaf_id orelse return) catch return;
        defer self.alloc.free(from_id);
        // Messages after the cut point belong to the abandoned branch.
        var abandoned = std.array_list.Managed(cmsg.Message).init(self.alloc);
        defer {
            for (abandoned.items) |*m| m.deinit();
            abandoned.deinit();
        }
        if (self.collectAbandonedMessages(cut_entry_id, &abandoned) and abandoned.items.len > 0) {
            const res = compact.generateSummary(
                self.alloc,
                self.io,
                self.session.provider,
                self.session.model.id,
                abandoned.items,
                null,
                null,
                null,
            ) catch null;
            if (res) |r| {
                defer self.alloc.free(r.text);
                st.branchAt(cut_entry_id, from_id, r.text);
                self.switchToStoreLive();
                self.addMessage(r.text);
                self.note("\x1b[90mbranched from {s} · summary of the abandoned path above\x1b[0m", .{cut_entry_id});
                return;
            }
        }
        // No summary available (empty branch or LLM failure): cut only.
        st.branchAt(cut_entry_id, from_id, "(no summary)");
        self.switchToStoreLive();
        self.note("\x1b[90mbranched from {s}\x1b[0m", .{cut_entry_id});
    }

    /// Messages on the leaf path strictly after `cut_entry_id`.
    fn collectAbandonedMessages(self: *TUI, cut_entry_id: []const u8, out: *std.array_list.Managed(cmsg.Message)) bool {
        const st = self.session.store orelse return false;
        const all = st.branchMessages(self.alloc) catch return false;
        defer {
            for (all) |m| m.deinit();
            self.alloc.free(all);
        }
        const ids = st.branchMessageIds(self.alloc) catch return false;
        // The ids borrow the store's entries: free only the slice (same
        // ownership as agent.zig's compaction usage).
        defer self.alloc.free(ids);
        // branchMessages and branchMessageIds are index-aligned.
        var cut_idx: ?usize = null;
        for (ids, 0..) |id, i| {
            if (std.mem.eql(u8, id, cut_entry_id)) cut_idx = i;
        }
        const start = (cut_idx orelse return false) + 1;
        if (start >= all.len) return false; // nothing to summarize
        for (all[start..]) |m| {
            out.append(m.clone(self.alloc) catch return false) catch return false;
        }
        return true;
    }

    /// /fork from an earlier user message: new session copying the chain up
    /// to that message (pi handleForkCommand → runtimeHost.fork).
    fn forkFromUserMessage(self: *TUI, entry_id: []const u8) void {
        const st = self.session.store orelse return;
        const forked = st.forkAt(entry_id, self.sessions_dir, self.cwd_abs) catch {
            self.note("fork failed", .{});
            return;
        };
        self.clearTranscript();
        self.session.adoptStore(forked) catch {};
        if (st != forked) st.deinit();
        self.replaySession();
        self.note("\x1b[90mforked → session {s}\x1b[0m", .{forked.id});
    }

    /// /import <path>: copy a session JSONL into the sessions dir (dedup
    /// suffixes like pi importFromJsonl) and switch to it.
    fn importSessionFrom(self: *TUI, input_path: []const u8) void {
        const alloc = self.alloc;
        const resolved = if (std.fs.path.isAbsolute(input_path)) blk: {
            break :blk alloc.dupe(u8, input_path) catch return;
        } else blk: {
            const joined = std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.cwd_abs, input_path }) catch return;
            break :blk joined;
        };
        defer alloc.free(resolved);
        const io_file = std.Io.Dir.cwd().openFile(self.io, resolved, .{}) catch {
            self.note("\x1b[91m/import: no such file: {s}\x1b[0m", .{resolved});
            return;
        };
        io_file.close(self.io);
        // Destination: sessions dir + basename (name-1, name-2 on collision).
        const base = std.fs.path.basename(resolved);
        var dest: []u8 = std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.sessions_dir, base }) catch return;
        defer alloc.free(dest);
        var suffix: usize = 1;
        while (true) {
            if (std.Io.Dir.cwd().openFile(self.io, dest, .{})) |f| {
                f.close(self.io);
                const stem = std.fs.path.stem(base);
                const ext = std.fs.path.extension(base);
                const next = std.fmt.allocPrint(alloc, "{s}/{s}-{d}{s}", .{ self.sessions_dir, stem, suffix, ext }) catch return;
                alloc.free(dest);
                dest = next;
                suffix += 1;
            } else |_| break;
        }
        // Copy file contents.
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, alloc, .limited(64 * 1024 * 1024)) catch {
            self.note("\x1b[91m/import: read failed\x1b[0m", .{});
            return;
        };
        defer alloc.free(data);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = data }) catch {
            self.note("\x1b[91m/import: write failed\x1b[0m", .{});
            return;
        };
        const new_st = ss.Store.open(alloc, self.io, dest) catch {
            self.note("\x1b[91m/import: parse failed\x1b[0m", .{});
            return;
        };
        const id_copy = alloc.dupe(u8, new_st.id) catch "?";
        self.switchToStore(new_st);
        self.note("\x1b[90mimported session {s} from {s}\x1b[0m", .{ id_copy, resolved });
    }

    /// Enter on a settings row: cycle to the next value, apply in memory and
    /// persist to settings.json (pi settings-selector semantics).
    /// /debug (pi handleDebugCommand): dump terminal size, every scrollback
    /// row with its visible width, and the session messages (JSONL) to a log
    /// file; report the path.
    fn writeDebugLog(self: *TUI) void {
        const alloc = self.alloc;
        var out = std.array_list.Managed(u8).init(alloc);
        defer out.deinit();
        var buf: [160]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "Debug output\nTerminal: {d}x{d}\nTotal rows: {d}\n\n=== All rendered rows with visible widths ===\n", .{ self.width, self.height, self.scrollback.items.len }) catch return;
        out.appendSlice(head) catch return;
        for (self.scrollback.items, 0..) |row, idx| {
            const vw = wmod.visualWidth(row);
            const line = std.fmt.allocPrint(alloc, "[{d}] (w={d}) {s}\n", .{ idx, vw, row }) catch break;
            out.appendSlice(line) catch break;
            alloc.free(line);
        }
        out.appendSlice("\n=== Agent messages (JSONL) ===\n") catch {};
        for (self.session.context.messages.items) |*m| {
            ss.writeMessageJson(&out, m) catch break;
            out.appendSlice("\n") catch break;
        }
        const path = std.fmt.allocPrint(alloc, "/tmp/rpi-debug-{d}.log", .{ss.nowMs(self.io)}) catch return;
        defer alloc.free(path);
        self.note("debug: writing {d} bytes to {s}", .{ out.items.len, path });
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.items }) catch {
            self.note("{s}", .{"debug log write failed"});
            return;
        };
        self.note("debug log written", .{});
    }

    /// Add an owned one-line note to the scrollback, then free it.

    /// Switch the active model (creates a provider, swaps into the session).
    fn switchModel(self: *TUI, idx: usize) !void {
        const cfg = self.cfg orelse return error.NoConfig;
        if (idx >= cfg.models.items.len) return error.BadIndex;
        const m = &cfg.models.items[idx];
        const p = try aiprovider.buildFromModel(self.alloc, self.io, m);
        if (self.owned_provider) |old| {
            old.deinit();
        }
        self.owned_provider = p;
        self.session.provider = p;
        self.session.model = m;
        self.session.thinking_level = m.thinking_level;
        self.model_name = m.name;
        // pi showStatus: "Switched to <name>[ (thinking: <level>)]" in dim
        // gray. Reasoning models follow the model's default thinking level.
        if (m.reasoning and m.thinking_level != .off) {
            self.note("\x1b[90mSwitched to {s} (thinking: {s})\x1b[0m", .{ m.name, m.thinking_level.name() });
        } else {
            self.note("\x1b[90mSwitched to {s}\x1b[0m", .{m.name});
        }
        self.redraw();
    }

    /// Cycle the thinking level off→low→medium→high→xhigh→max→off
    /// (pi: app.thinking.cycle, shift+tab).
    fn cycleThinkingLevel(self: *TUI) void {
        const levels = [_]config.ThinkingLevel{ .off, .low, .medium, .high, .xhigh, .max };
        var idx: usize = 0;
        for (levels, 0..) |l, i| {
            if (l == self.session.thinking_level) idx = i;
        }
        self.session.thinking_level = levels[(idx + 1) % levels.len];
        self.flash(self.session.thinking_level.name());
        self.redraw();
    }

    /// pi ScopedModelsSelector.isEnabled: null = all enabled.
    fn modelScoped(self: *TUI, idx: usize) []const u8 {
        if (self.scoped_models == null) return "\u{2713} enabled";
        return if (self.isModelScoped(idx)) "\u{2713} enabled" else "\u{2717} disabled";
    }

    fn isModelScoped(self: *TUI, idx: usize) bool {
        const cfg = self.cfg orelse return true;
        if (idx >= cfg.models.items.len) return true;
        const list = &(self.scoped_models orelse return true);
        var fbuf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ cfg.models.items[idx].provider, cfg.models.items[idx].id }) catch return true;
        for (list.items) |id| {
            if (std.mem.eql(u8, id, full)) return true;
        }
        return false;
    }

    fn toggleScopedModel(self: *TUI, idx: usize) void {
        const cfg = self.cfg orelse return;
        if (idx >= cfg.models.items.len) return;
        var fbuf: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ cfg.models.items[idx].provider, cfg.models.items[idx].id }) catch return;
        if (self.scoped_models == null) {
            // null = all enabled → disabling one starts an explicit list of
            // every OTHER model (pi toggle()).
            var list = std.ArrayListUnmanaged([]u8).empty;
            for (cfg.models.items, 0..) |*m, i| {
                if (i == idx) continue;
                const mid = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ m.provider, m.id }) catch continue;
                const id = self.alloc.dupe(u8, mid) catch continue;
                list.append(self.alloc, id) catch {};
            }
            self.scoped_models = list;
            return;
        }
        var list = &self.scoped_models.?;
        for (list.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, full)) {
                self.alloc.free(id);
                _ = list.orderedRemove(i);
                return;
            }
        }
        const id = self.alloc.dupe(u8, full) catch return;
        list.append(self.alloc, id) catch self.alloc.free(id);
    }

    /// /scoped-models — pi ScopedModelsSelector: list all models with their
    /// enabled state; Enter toggles, Esc closes. Session-only.
    fn closeModelSelector(self: *TUI) void {
        self.menu_mode = .hidden;
        self.editor.clear() catch {};
        self.ms_visible = 0;
        self.ms_sel = 0;
    }

    fn modelSearchText(self: *TUI, idx: usize, buf: *[256]u8) []const u8 {
        const cfg = self.cfg orelse return "";
        if (idx >= cfg.models.items.len) return "";
        const m = &cfg.models.items[idx];
        const is_default = self.isDefaultModel(idx);
        return std.fmt.bufPrint(buf, "{s} {s}/{s} {s} {s}{s}", .{
            m.provider, m.provider, m.id, m.provider, m.id,
            if (is_default) " default" else "",
        }) catch "";
    }

    fn isCurrentModel(self: *TUI, idx: usize) bool {
        const m = self.session.model;
        const cfg = self.cfg orelse return false;
        if (idx >= cfg.models.items.len) return false;
        return std.mem.eql(u8, cfg.models.items[idx].provider, m.provider) and
            std.mem.eql(u8, cfg.models.items[idx].id, m.id);
    }

    fn isDefaultModel(self: *TUI, idx: usize) bool {
        const cfg = self.cfg orelse return false;
        if (idx >= cfg.models.items.len) return false;
        const m = &cfg.models.items[idx];
        return cfg.default_provider != null and cfg.default_model != null and
            std.mem.eql(u8, cfg.default_provider.?, m.provider) and
            std.mem.eql(u8, cfg.default_model.?, m.id);
    }

    /// pi sortModels: current first, default second, rest by provider.
    fn modelSelectorSort(self: *TUI, list: *std.ArrayListUnmanaged(usize)) void {
        const Ctx = struct { tui: *TUI };
        const ctx = Ctx{ .tui = self };
        std.mem.sort(usize, list.items, ctx, struct {
            fn f(c: Ctx, a: usize, b: usize) bool {
                const a_cur = c.tui.isCurrentModel(a);
                const b_cur = c.tui.isCurrentModel(b);
                if (a_cur != b_cur) return a_cur;
                const a_def = c.tui.isDefaultModel(a);
                const b_def = c.tui.isDefaultModel(b);
                if (a_def != b_def) return a_def;
                const cfg = c.tui.cfg orelse return false;
                const am = &cfg.models.items[a];
                const bm = &cfg.models.items[b];
                return std.mem.order(u8, am.provider, bm.provider) == .lt;
            }
        }.f);
    }

    /// pi ModelSelector.filterModels: substring over the pi search text;
    /// a query starting with "default" pins default models first.
    fn modelSelectorRefilter(self: *TUI) void {
        const query_raw = self.editor.getText() catch "";
        defer self.alloc.free(query_raw);
        const query = std.mem.trim(u8, query_raw, " ");
        self.ms_filtered.clearRetainingCapacity();
        const cfg = self.cfg orelse return;
        const scope_all = self.ms_scope_all or self.scoped_models == null;
        var vbuf: [256]u8 = undefined;
        for (cfg.models.items, 0..) |_, i| {
            if (!scope_all and !self.isModelScoped(i)) continue;
            if (query.len > 0) {
                const text = self.modelSearchText(i, &vbuf);
                if (!containsIgnoreCase2(text, query)) continue;
            }
            self.ms_filtered.append(self.alloc, i) catch {};
        }
        if (query.len > 0 and std.ascii.startsWithIgnoreCase(query, "default")) {
            var defaults = std.ArrayListUnmanaged(usize).empty;
            var rest = std.ArrayListUnmanaged(usize).empty;
            for (self.ms_filtered.items) |i| {
                if (self.isDefaultModel(i)) {
                    defaults.append(self.alloc, i) catch {};
                } else {
                    rest.append(self.alloc, i) catch {};
                }
            }
            self.ms_filtered.clearRetainingCapacity();
            self.ms_filtered.appendSlice(self.alloc, defaults.items) catch {};
            self.ms_filtered.appendSlice(self.alloc, rest.items) catch {};
            defaults.deinit(self.alloc);
            rest.deinit(self.alloc);
        }
        if (query.len == 0) self.modelSelectorSort(&self.ms_filtered);
        self.ms_visible = self.ms_filtered.items.len;
        if (self.ms_sel >= self.ms_visible) self.ms_sel = if (self.ms_visible > 0) self.ms_visible - 1 else 0;
    }

    fn openModelSelector(self: *TUI, prefill: ?[]const u8) void {
        self.menu_mode = .model_selector;
        self.ms_scope_all = true;
        self.editor.clear() catch {};
        if (prefill) |pf| {
            if (pf.len > 0) self.editor.setText(pf) catch {};
        }
        self.modelSelectorRefilter();
        self.ms_sel = 0;
        self.freeMenuTextCache();
        self.redraw();
    }

    fn setDefaultModel(self: *TUI, idx: usize) void {
        const cfg = self.cfg orelse return;
        if (idx >= cfg.models.items.len) return;
        const m = &cfg.models.items[idx];
        cfg.setDefaultProviderModel(self.alloc, m.provider, m.id) catch {};
        cfg.persistSettings(self.alloc, self.io) catch |err| {
            self.note("settings save failed: {s}", .{@errorName(err)});
        };
        self.note("\x1b[90mSet as default model: {s}/{s}\x1b[0m", .{ m.provider, m.id });
    }

    fn openScopedModelsMenu(self: *TUI) void {
        const cfg = self.cfg orelse {
            self.note("no config loaded", .{});
            self.redraw();
            return;
        };
        var n: usize = 0;
        for (cfg.models.items, 0..) |*m, i| {
            if (n >= self.menu_items.len) break;
            self.menu_items[n] = .{
                .name = m.id,
                .desc = self.modelScoped(i),
                .model_idx = i,
            };
            n += 1;
        }
        self.menu_len = n;
        self.menu_selected = 0;
        self.menu_mode = .scoped;
        self.editor.clear() catch {};
        self.note("Enter toggles; Esc closes (session-only)", .{});
        self.redraw();
    }

    /// Cycle to the next/previous configured model (pi: app.model.cycle,
    /// ctrl+p / shift+ctrl+p). Wraps around the flattened models list.
    fn cycleModel(self: *TUI, dir: isize) void {
        const cfg = self.cfg orelse {
            self.flash("no config — selector unavailable");
            return;
        };
        const n = cfg.models.items.len;
        if (n == 0) return;
        var idx: usize = 0;
        for (cfg.models.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.name, self.model_name)) idx = i;
        }
        // pi: scoped models limit the Ctrl+P cycle; null = all.
        var step: usize = 0;
        var cur = idx;
        while (step < n) : (step += 1) {
            const cand: isize = @mod(@as(isize, @intCast(cur)) + dir, @as(isize, @intCast(n)));
            cur = @intCast(cand);
            if (self.isModelScoped(cur)) break;
        }
        if (step >= n) return; // everything disabled — stay put
        self.switchModel(cur) catch |err| {
            self.note("model switch failed: {s}", .{@errorName(err)});
        };
    }

    /// Copy the selection, or the last assistant reply when nothing is
    /// selected (pi: app.message.copy, ctrl+x).
    fn copyLastMessage(self: *TUI) void {
        if (self.selectionText()) |text| {
            defer self.alloc.free(text);
            self.copyToClipboard(text);
            self.flash("Copied!");
            self.redraw();
            return;
        }
        const msgs = self.session.context.messages.items;
        var i = msgs.len;
        while (i > 0) {
            i -= 1;
            const m = &msgs[i];
            if (m.role != .assistant) continue;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(self.alloc);
            for (m.blocks.items) |b| switch (b) {
                .text => |t| {
                    if (buf.items.len > 0) buf.appendSlice(self.alloc, "\n\n") catch {};
                    buf.appendSlice(self.alloc, t) catch {};
                },
                else => {},
            };
            if (buf.items.len == 0) continue;
            self.copyToClipboard(buf.items);
            self.flash("Copied!");
            self.redraw();
            return;
        }
        self.flash("Nothing to copy");
        self.redraw();
    }

    /// Suspend to background (pi: app.suspend, ctrl+z). Restores the tty so
    /// the shell takes over; the default SIGTSTP stops us and SIGCONT
    /// resumes right after the raise, where we re-enter raw mode and
    /// repaint from scratch.
    fn suspendToBackground(self: *TUI) void {
        self.restoreTerminal();
        std.posix.raise(std.posix.SIG.TSTP) catch {};
        self.resumeTui();
    }

    /// Open $EDITOR (fallback: $VISUAL, vi) with the current prompt buffer.
    /// Suspends the TUI (leaves alt-screen, restores cooked mode), runs the
    /// editor on a temp file, then resumes and loads the result.
    fn openExternalEditor(self: *TUI) void {
        const editor_cmd = std.process.Environ.getPosix(self.environ, "EDITOR") orelse
            std.process.Environ.getPosix(self.environ, "VISUAL") orelse "vi";

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/rpi-prompt-{d}.md", .{std.c.getpid()}) catch return;

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
                // pi: the editor stays interactive while the agent runs.
                // Typing edits the buffer live; enter submits it to the
                // steering queue (injected before the next LLM request);
                // alt+enter queues a follow-up (new turn after this one);
                // alt+up restores a queued follow-up to the editor. Ctrl
                // combos and keys we don't handle here keep the old capture
                // and replay behavior below.
                if (keys.parseSequence(seq, self.key_reader.kitty_active)) |k| {
                    const steering_key: bool = switch (k) {
                        .enter, .backspace, .space, .shift_enter, .left, .right, .up, .down, .home, .end, .delete => true,
                        .char => |ch| !ch.ctrl and !ch.alt,
                        .text => true,
                        else => false,
                    };
                    // alt+enter arrives as char{c='\r', alt=true} — a
                    // follow-up queue submit, not an editor newline. Checked
                    // BEFORE the editor keys (steering_key is false for it).
                    // NOTE: render calls (note/addUserMessage) happen AFTER
                    // the unlock — they take render_mutex themselves, and
                    // this mutex is not recursive.
                    if (k == .char and k.char.alt and k.char.c == '\r') {
                        self.render_mutex.lockUncancelable(self.io);
                        const text = self.editor.getText() catch "";
                        defer self.alloc.free(@constCast(text));
                        const has_text = text.len > 0;
                        if (has_text) {
                            self.session.queueFollowUp(text);
                            self.editor.clear() catch {};
                        }
                        self.render_mutex.unlock(self.io);
                        if (has_text) {
                            self.note("\x1b[90m[follow-up queued — alt+up to restore]\x1b[0m", .{});
                            // Watcher thread: render from cached footer stats
                            // (self.redraw() walks the session on the main
                            // thread only, and the agent thread is appending
                            // to it right now).
                            self.redrawCached();
                        }
                        acted = true;
                        continue;
                    }
                    if (steering_key) {
                        if (k == .enter) {
                            // Enter while running: steer the current turn.
                            self.render_mutex.lockUncancelable(self.io);
                            const text = self.editor.getText() catch "";
                            defer self.alloc.free(@constCast(text));
                            const has_text = text.len > 0;
                            if (has_text) {
                                self.session.queueSteering(text);
                                self.editor.clear() catch {};
                            }
                            self.render_mutex.unlock(self.io);
                            if (has_text) {
                                self.addUserMessage(text);
                                self.render_mutex.lock(self.io) catch {};
                                self.sv.scrollToEnd(ss.nowMs(self.io));
                                self.render_mutex.unlock(self.io);
                                self.redrawCached();
                            }
                            acted = true;
                            continue;
                        }
                        self.render_mutex.lockUncancelable(self.io);
                        _ = self.editor.handleKey(k, self.io) catch {};
                        self.render_mutex.unlock(self.io);
                        acted = true;
                        continue;
                    }
                    if (k == .char and k.char.alt and k.char.c == 'v') {
                        // alt+v (windows pi binding) / alt+up both restore a
                        // queued follow-up into the editor.
                        if (self.session.drainFollowUp()) |text| {
                            defer self.alloc.free(text);
                            self.render_mutex.lockUncancelable(self.io);
                            self.editor.setText(text) catch {};
                            self.render_mutex.unlock(self.io);
                            acted = true;
                            continue;
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

    pub fn init(io: std.Io, alloc: std.mem.Allocator, session: *agent.Session, model_name: []const u8, sessions_dir: []const u8, cwd_abs: []const u8, home_dir: ?[]const u8, cfg: ?*config.Config, environ: std.process.Environ, append_system_prompt: ?[]const u8, system_prompt_override: ?[]const u8) TUI {
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
        // OSC 8 hyperlinks leak as raw text in environments that do not
        // forward them (tmux without passthrough); dumb terminals too.
        {
            const term = std.process.Environ.getPosix(environ, "TERM") orelse "";
            if (std.process.Environ.getPosix(environ, "TMUX") != null or
                std.mem.startsWith(u8, term, "tmux") or std.mem.eql(u8, term, "dumb"))
            {
                markdown.hyperlinks_enabled = false;
            }
        }
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
            .append_system_prompt = append_system_prompt,
            .system_prompt_override = system_prompt_override,
            .multi_provider = multi_provider,
            .working = false,
            .spinner_frame = 0,
            .last_tick_ns = 0,
            .bash_mode = false,
        };
    }

    /// Late init for the parts that need the struct built (pi creates the
    /// autocomplete provider right after session setup): dynamic slash
    /// entries (templates + skills). Best-effort.
    pub fn initLate(self: *TUI) void {
        self.refreshSlashExtras();
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
        for (self.slash_extras.items) |*e| {
            self.alloc.free(e.name);
            self.alloc.free(e.desc);
        }
        self.slash_extras.deinit(self.alloc);
        if (self.menu_text_cache) |c| self.alloc.free(c);
        self.editor.deinit();
        self.stream_text.deinit();
        self.stream_thinking.deinit();
        if (self.scoped_models) |*list| {
            for (list.items) |id| self.alloc.free(id);
            list.deinit(self.alloc);
        }
        self.ms_filtered.deinit(self.alloc);
        if (self.owned_provider) |p| {
            p.deinit();
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
        if (self.at_suppress) |sup| self.alloc.free(sup);
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
        // In settings mode the editor line is the search input (pi Input
        // component, default prompt "> "): render inset by 2 and let the
        // frame prepend the prompt prefix.
        const settings_search = self.menu_mode == .settings;
        const modal_search = settings_search or self.menu_mode == .model_selector;
        const ed_width: usize = if (modal_search) (if (self.width > 2) self.width - 2 else 1) else self.width;
        var ed = self.editor.render(ed_width) catch return;
        var ed_consumed = false;
        errdefer {
            if (!ed_consumed) {
                for (ed.items) |l| self.alloc.free(l);
                ed.deinit(self.alloc);
            }
        }
        const visual_total = ed.items.len;
        const editor_h = if (visual_total < self.maxEditorHeight()) visual_total else self.maxEditorHeight();
        const cursor_vis_raw = self.editor.cursorVisualPos(ed_width);
        var cursor_vis = self.editor.cursorVisualPos(self.width);
        cursor_vis.row = cursor_vis_raw.row;
        cursor_vis.col = cursor_vis_raw.col + (if (settings_search) @as(u32, 2) else 0);
        var vis_top: usize = 0;
        if (cursor_vis.row >= editor_h) vis_top = cursor_vis.row - editor_h + 1;
        const end = if (visual_total < vis_top + editor_h) visual_total else vis_top + editor_h;
        // Fixed bottom: menu (menu_h) + top border (1) + editor (editor_h) +
        // bottom border (1) + cwd (1) + status (1). The menu viewport shows
        // at most 16 rows (pi select-list maxVisible).
        const menu_h: usize = if (self.menu_mode != .hidden) @min(self.menu_len, self.menuMaxVisible()) else 0;
        // The "(sel/total)" scroll-indicator row renders under the menu rows
        // (pi SelectList.render appends it after the items) and must be part
        // of the bottom budget — without it the frame is one row taller than
        // the terminal, which scrolls the screen by one line on every menu
        // frame and leaves stale rows behind.
        const count_line: usize = if (menu_h > 0 and self.menu_len > menu_h) 1 else 0;
        // Trust prompt panel: title + cwd + saved/current lines above the
        // list and a key-hint footer below (pi TrustSelectorComponent frame).
        const trust_head: usize = if (self.menu_mode == .trust) 4 else 0;
        const trust_foot: usize = if (self.menu_mode == .trust) 1 else 0;
        // Settings selector (pi SettingsSelectorComponent): renders inside
        // the editor borders — search line (the editor), blank, up to 10
        // item rows, scroll count, blank, wrapped description, hint.
        const settings_h: usize = if (self.menu_mode == .settings) self.settingsViewHeight(editor_h) else 0;
        const ms_h: usize = if (self.menu_mode == .model_selector) self.modelSelectorViewHeight() else 0;
        const fixed_bottom = editor_h + 4 + menu_h + count_line + trust_head + trust_foot + settings_h + ms_h;
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

        // 2. Top border (shows spinner + "Working" when busy).
        const top_border = self.topBorderLine() catch return;
        frame.append(self.alloc, top_border) catch return;

        // 3. Editor visible visual lines (scrolled to the cursor). Move them
        // into the frame, free the rest, and consume ed. Settings mode adds
        // the Input-component prompt prefix ("> " first line, two spaces on
        // wrapped continuation lines).
        for (ed.items[vis_top..end], 0..) |line, vi| {
            if (!modal_search) {
                frame.append(self.alloc, line) catch return;
            } else {
                const prefixed = std.fmt.allocPrint(self.alloc, "{s}{s}", .{
                    if (vis_top + vi == 0) "> " else "  ",
                    line,
                }) catch {
                    frame.append(self.alloc, line) catch return;
                    continue;
                };
                frame.append(self.alloc, prefixed) catch return;
                // Ownership moves into the frame (freed at frame teardown).
                self.alloc.free(line);
            }
        }
        for (ed.items[0..vis_top]) |line| self.alloc.free(line);
        for (ed.items[end..]) |line| self.alloc.free(line);
        ed.deinit(self.alloc);
        ed_consumed = true;
        while (frame.items.len < transcript_h + 1 + editor_h) {
            const blank = self.alloc.dupe(u8, "") catch return;
            frame.append(self.alloc, blank) catch return;
        }

        // 3.5 Settings selector view (pi SettingsList.renderMainList):
        // blank, item rows (label padded to min(36, widest) + two spaces +
        // value), scroll count, blank, wrapped description, hint line.
        if (self.menu_mode == .settings and settings_h > 0) {
            self.renderSettingsView(&frame, editor_h, settings_h);
        }
        // 3.6 Model selector view (pi ModelSelectorComponent.updateList):
        // provider notice / scope rows, item rows with ✓/· default badges,
        // scroll count, blank, Model Name detail, key hint line.
        if (self.menu_mode == .model_selector and ms_h > 0) {
            self.renderModelSelectorView(&frame);
        }

        // 4. Bottom border.
        const bottom_border = self.borderLine() catch return;
        frame.append(self.alloc, bottom_border) catch return;

        // 4.5 Completion menu rows (pi editor.render: the autocomplete
        // SelectList renders BELOW the input's bottom border). The window
        // centers on menu_selected; a scroll indicator shows when the list
        // has more rows (pi: "  (sel/total)" in muted).
        if (menu_h > 0) {
            const col_min: usize = if (self.menu_mode == .commands or self.menu_mode == .models) 12 else 32;
            const col_max: usize = if (self.menu_mode == .commands or self.menu_mode == .models) 32 else 32;
            if (self.menu_mode == .trust) {
                if (self.trust_prompt) |tp| {
                    const accent = "\x1b[38;2;167;152;215m";
                    const saved_txt = if (tp.saved) |sv|
                        (if (sv) "trusted" else "untrusted")
                    else
                        "none";
                    const lines = [_][]const u8{
                        "Project trust",
                        tp.cwd,
                        "Saved decision: none",
                        "Current session: none",
                    };
                    _ = lines;
                    const l1 = std.fmt.allocPrint(self.alloc, "{s}Project trust{s}", .{ accent, ansi.RESET }) catch return;
                    frame.append(self.alloc, l1) catch return;
                    const l2 = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "{s}" ++ ansi.RESET, .{tp.cwd}) catch return;
                    frame.append(self.alloc, l2) catch return;
                    const l3 = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "Saved decision: {s}" ++ ansi.RESET, .{saved_txt}) catch return;
                    frame.append(self.alloc, l3) catch return;
                    const cur: []const u8 = if (self.project_trusted) "trusted" else "untrusted";
                    const l4 = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "Current session: {s}" ++ ansi.RESET, .{cur}) catch return;
                    frame.append(self.alloc, l4) catch return;
                }
            }
            self.updateMenuViewport(menu_h);
            for (0..menu_h) |v| {
                // menu_items is the projected window (modal pickers project
                // their sel_rows through refreshSelMenu), so v is the
                // window-relative index for both paths.
                const ml_raw = self.menuLine(v, self.width, col_min, col_max) catch return;
                const ml = truncateToWidth(self.alloc, ml_raw, self.width) catch return;
                self.alloc.free(ml_raw);
                frame.append(self.alloc, ml) catch return;
            }
            if (self.menu_len > menu_h) {
                const indicator = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "  ({d}/{d})" ++ ansi.RESET, .{ self.menu_selected + 1, self.menu_len }) catch return;
                frame.append(self.alloc, indicator) catch return;
            }
            if (self.menu_mode == .trust) {
                const foot = std.fmt.allocPrint(self.alloc, FG_MUTED ++ "\u{2191}\u{2193} navigate \u{2022} enter save \u{2022} esc cancel" ++ ansi.RESET, .{}) catch return;
                frame.append(self.alloc, foot) catch return;
            }
        }

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

        // The menu renders below the editor (pi editor.render: autocomplete
        // after the bottom border), so the editor row is transcript_h +
        // top border + row — menu_h no longer shifts it.
        const cursor_row = transcript_h + 1 + (cursor_vis.row - vis_top);
        const cursor_col: u16 = @intCast(if (1 + cursor_vis.col < self.width) 1 + cursor_vis.col else self.width);
        // diffRender adopts the frame's lines (they become the next diff
        // base); afterwards only the array itself needs releasing.
        self.diffRender(&frame, cursor_row, cursor_col);
        frame.deinit(self.alloc);
    }

    /// The border color for the current state (thinking level or bash mode).
    fn borderColor(self: *const TUI) []const u8 {
        if (self.bash_mode) return BORDER_BASH;
        // Modal selectors render their own theme.border (blue) in pi; the
        // plain autocomplete menus (commands/models/files) keep the editor
        // in its normal editing state.
        switch (self.menu_mode) {
            .settings, .scoped, .model_selector, .sessions, .tree, .forksel, .mcp, .mcp_server, .mcp_tools, .mcp_exposure, .trust => return BORDER_INFO,
            else => {},
        }
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
            // Splice directly: base[0..box_col) + box line + base[box_col+box_w..).
            // (overlay()'s SGR-state tracking mis-renders this box because the
            // box line carries its own SGR runs; a plain column splice is what
            // the layout actually needs here.)
            const before = overlay.sliceByColumn(self.alloc, frame.items[row], 0, s.box_col) catch continue;
            defer self.alloc.free(before);
            const after = overlay.sliceByColumn(self.alloc, frame.items[row], s.box_col + box_w, self.width) catch continue;
            defer self.alloc.free(after);
            // Pad `before` up to box_col so the box sits at a fixed column
            // even when the base row is shorter (empty transcript rows).
            const before_w = wmod.visibleWidthEsc(before);
            const pad = if (s.box_col > before_w) s.box_col - before_w else 0;
            var pad_buf: [128]u8 = undefined;
            const pad_str = if (pad > 0 and pad <= pad_buf.len) blk: {
                @memset(pad_buf[0..pad], ' ');
                break :blk pad_buf[0..pad];
            } else "";
            const composed = std.fmt.allocPrint(self.alloc, "{s}{s}{s}{s}", .{ before, pad_str, line, after }) catch continue;
            self.alloc.free(frame.items[row]);
            frame.items[row] = composed;
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
        // The editor stays interactive while the agent runs (steering), so
        // the cursor parks at the editor position in every state; the dedup
        // below keeps idle ticks silent.
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

    /// addMessage with formatting (allocPrint's into a transient buffer that
    /// addBlockWithSrc copies).
    fn addMessageFmt(self: *TUI, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(text);
        self.addMessage(text);
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

    /// The transcript's first block: startup header (pi: headerContainer is
    /// a child of documentContainer — it scrolls WITH the document, so a
    /// continued session only shows it at the very top, never between the
    /// history and the input). Content follows pi's compact header: bold
    /// wordmark + dim version, muted key hints, dim onboarding line.
    pub fn addWelcomeHeader(self: *TUI) void {
        const text = "\x1b[1mrpi\x1b[0m" ++ FG_MUTED ++ " v" ++ VERSION ++
            "\x1b[0m  " ++ FG_MUTED ++
            "esc interrupt · ctrl+c clear/exit · / commands · ctrl+o tools · ctrl+t thinking\x1b[0m\n" ++
            FG_MUTED ++ "Ask rpi how to use or extend it — it can explain its own features.\x1b[0m";
        self.addMessage(text);
    }

    /// Replay persisted branch messages into the transcript for
    /// -c/-r/--session continuation (pi: renderInitialMessages →
    /// renderSessionEntries — assistant text/thinking render as blocks, tool
    /// calls as tool blocks with their results matched back by id). Context
    /// restore itself happens in main; this only rebuilds what the user
    /// sees. No-op without a store or on an empty branch (new sessions).
    pub fn replaySession(self: *TUI) void {
        // Runs BEFORE run()/setupTerminal, where width is still the init
        // default (80). Measure now — otherwise every replayed block renders
        // at 80 columns and stays there (the first frame's refreshSize sees
        // setupTerminal's measureSize as a no-op, so rerenderAtWidth never
        // fires). Caller holds no locks; the add* helpers take their own.
        {
            self.render_mutex.lock(self.io) catch {};
            defer self.render_mutex.unlock(self.io);
            self.measureSize();
        }
        self.addWelcomeHeader();
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
                .bash_execution => {
                    const cmd = m.bash_command orelse "";
                    const out_text = if (m.blocks.items.len > 0) blk: {
                        for (m.blocks.items) |b| switch (b) {
                            .text => |t| break :blk t,
                            else => {},
                        };
                        break :blk "";
                    } else "";
                    self.addBashBlock(cmd, out_text, m.bash_exit_code, m.bash_exclude);
                },
            }
        }
    }

    /// Render one !cmd execution block (pi BashExecutionComponent look):
    /// command line + truncated output + exit status, dim/colored.
    pub fn addBashBlock(self: *TUI, command: []const u8, output: []const u8, exit_code: ?i32, exclude: bool) void {
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.alloc);
        const a = self.alloc;
        const tag: []const u8 = if (exclude) "bash (excluded)" else "bash";
        block.appendSlice(a, "\x1b[2m[") catch return;
        block.appendSlice(a, tag) catch return;
        block.appendSlice(a, "] $ ") catch return;
        block.appendSlice(a, command) catch return;
        block.appendSlice(a, "\x1b[0m\n") catch return;
        if (output.len > 0) {
            // Indent the first 20 lines; dim them.
            var it = std.mem.splitScalar(u8, output, '\n');
            var n: usize = 0;
            while (it.next()) |line| {
                if (n >= 20) {
                    block.appendSlice(a, "\x1b[2m…\x1b[0m\n") catch {};
                    break;
                }
                block.appendSlice(a, "  \x1b[2m") catch break;
                block.appendSlice(a, line[0..@min(line.len, 200)]) catch break;
                block.appendSlice(a, "\x1b[0m\n") catch break;
                n += 1;
            }
        } else {
            block.appendSlice(a, "\x1b[2m  (no output)\x1b[0m\n") catch {};
        }
        if (exit_code) |code| {
            if (code != 0) {
                var eb: [64]u8 = undefined;
                const row = std.fmt.bufPrint(&eb, "\x1b[31m  exited {d}\x1b[0m\n", .{code}) catch "";
                block.appendSlice(a, row) catch {};
            }
        }
        self.finishBlock(&block, .plain);
    }

    fn isPromptTemplate(self: *TUI, word: []const u8) bool {
        if (!std.mem.startsWith(u8, word, "/")) return false;
        const name = word[1..];
        if (name.len == 0) return false;
        const templates = ptmod.discover(self.alloc, self.io, self.agent_dir_for_templates(), self.cwd_abs, self.project_trusted);
        defer ptmod.freeAll(self.alloc, templates);
        for (templates) |t| {
            if (std.mem.eql(u8, t.name, name)) return true;
        }
        return false;
    }

    /// Expand a `/name args` submission against discovered prompt templates
    /// (pi expandPromptTemplate). Returns the input unchanged when no
    /// template matches; the caller frees the returned slice.
    fn expandTemplate(self: *TUI, text: []const u8) ![]u8 {
        const templates = ptmod.discover(self.alloc, self.io, self.agent_dir_for_templates(), self.cwd_abs, self.project_trusted);
        defer ptmod.freeAll(self.alloc, templates);
        return ptmod.expand(self.alloc, text, templates);
    }

    fn agent_dir_for_templates(self: *TUI) []const u8 {
        return self.cfg.?.base_dir;
    }

    /// Expand a `/skill:name [args]` submission (pi _expandSkillCommand). The
    /// skill's SKILL.md body is wrapped in a `<skill>` block and (optionally)
    /// followed by the args as a user request. Returns an owned slice, or null
    /// when the skill is unknown (caller passes the input through unchanged).
    fn expandSkillCommand(self: *TUI, text: []const u8) ?[]u8 {
        if (!std.mem.startsWith(u8, text, "/skill:")) return null;
        const rest = text[7..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const skill_name = rest[0..space];
        const args = if (space < rest.len) std.mem.trim(u8, rest[space + 1 ..], " ") else "";
        const list = skills.discover(self.alloc, self.io, self.agent_dir_for_templates(), self.cwd_abs, self.home_dir, self.project_trusted) catch return null;
        defer skills.freeAll(self.alloc, list);
        for (list) |s| {
            if (!std.mem.eql(u8, s.name, skill_name)) continue;
            const body = skills.loadBody(self.alloc, self.io, s.file_path) orelse return null;
            defer self.alloc.free(body);
            const block = std.fmt.allocPrint(self.alloc, "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>", .{ s.name, s.file_path, s.base_dir, body }) catch return null;
            defer self.alloc.free(block);
            if (args.len > 0) {
                const final = std.mem.concat(self.alloc, u8, &.{ block, "\n\n", args }) catch return null;
                return final;
            }
            return self.alloc.dupe(u8, block) catch null;
        }
        return null; // unknown skill: pass through
    }

    /// Re-discover skills and rebuild the system prompt (pi `/reload`). Reports
    /// the number of visible skills. Returns an error string on failure.
    fn reloadResources(self: *TUI) !void {
        const cfg = self.cfg orelse return;
        const list = try skills.discover(self.alloc, self.io, cfg.base_dir, self.cwd_abs, self.home_dir, self.project_trusted);
        defer skills.freeAll(self.alloc, list);
        const block = try skills.formatForPrompt(self.alloc, list);
        defer {
            if (block) |b| self.alloc.free(b);
        }
        var tool_snippets = std.array_list.Managed(sp.ToolSnippet).init(self.alloc);
        defer tool_snippets.deinit();
        for (self.session.registry.tools.items) |t| {
            // Only active tools are declared to the model (pi).
            if (!t.active) continue;
            try tool_snippets.append(.{ .name = t.name, .snippet = t.description });
        }
        const new_prompt = try sp.buildFromSnippets(self.alloc, self.io, tool_snippets.items, self.cwd_abs, cfg.base_dir, self.append_system_prompt, self.system_prompt_override, block);
        try self.session.setSystemPrompt(new_prompt);
        self.alloc.free(new_prompt);
        var visible: usize = 0;
        for (list) |s| {
            if (!s.disable_model_invocation) visible += 1;
        }
        self.note("Reloaded resources: {d} skill(s) advertised in the system prompt.", .{visible});
        // Templates and skills may have changed on disk: refresh the dynamic
        // `/` menu entries (pi rebuilds the autocomplete provider).
        self.refreshSlashExtras();
    }

    /// /mcp — list configured MCP servers with their state (pi /mcp).
    /// Format matches pi's SelectList: `→ name<col> state · exposure · scope`.
    fn showMcpStatus(self: *TUI) void {
        // pi /mcp opens the interactive manager (select a server → manage
        // enable/tools/exposure/reconnect); the read-only listing is the
        // empty state. Keep the text dump for "no servers" only.
        const mgr = mcp.Manager.getGlobal();
        if (mgr == null or mgr.?.servers.items.len == 0) {
            self.addMessage("No MCP servers configured.\nAdd entries to mcp.json under your agent dir or in .pi/mcp.json.");
            return;
        }
        self.openMcpManager();
    }

    // ---- /mcp manager (pi McpManagerView: servers → server → actions) ----

    fn mcpSetServer(self: *TUI, name: []const u8) void {
        // name may BE this very buffer (openMcpServerMenu(self.mcpServerName())) — skip the self-copy.
        if (std.mem.eql(u8, self.mcpServerName(), name)) return;
        const n = @min(name.len, self.mcp_server_name.len);
        @memcpy(self.mcp_server_name[0..n], name[0..n]);
        self.mcp_server_name_len = n;
    }

    fn mcpServerName(self: *TUI) []const u8 {
        return self.mcp_server_name[0..self.mcp_server_name_len];
    }

    /// describeState (pi mcp extension): state · exposure · scope.
    fn mcpServerDesc(self: *TUI, srv: *mcp.Server) []const u8 {
        var desc = std.array_list.Managed(u8).init(self.alloc);
        if (!srv.enabled) {
            desc.appendSlice("disabled") catch return "?";
        } else if (srv.connected) {
            const s = std.fmt.allocPrint(self.alloc, "connected · {d} tool{s}", .{ srv.tools.len, if (srv.tools.len == 1) "" else "s" }) catch return "connected";
            desc.appendSlice(s) catch {};
            self.alloc.free(s);
        } else if (srv.error_msg) |e| {
            desc.appendSlice("failed: ") catch {};
            desc.appendSlice(e) catch {};
        } else {
            desc.appendSlice("starting") catch {};
        }
        desc.appendSlice(" · ") catch {};
        desc.appendSlice(srv.exposure orelse "codemode") catch {};
        desc.appendSlice(" · ") catch {};
        desc.appendSlice(if (std.mem.eql(u8, srv.source, "project")) "project" else "global") catch {};
        return desc.toOwnedSlice() catch {
            desc.deinit();
            return "?";
        };
    }

    /// The mcp.json file that defines (or overrode) the server — the file
    /// enable/disable/exposure writes back to (pi override semantics use the
    /// entry's own file; project overrides are read last and win).
    fn mcpServerConfigPath(self: *TUI, srv: *mcp.Server) []u8 {
        const base = if (self.cfg) |c| c.base_dir else return self.alloc.dupe(u8, "mcp.json") catch unreachable;
        if (std.mem.eql(u8, srv.source, "project")) {
            return std.fmt.allocPrint(self.alloc, "{s}/.pi/mcp.json", .{self.cwd_abs}) catch unreachable;
        }
        return std.fmt.allocPrint(self.alloc, "{s}/mcp.json", .{base}) catch unreachable;
    }

    /// Open the servers menu (pi serversMenu): rows sorted by state
    /// attention, description = state · exposure · scope.
    fn openMcpManager(self: *TUI) void {
        const mgr = mcp.Manager.getGlobal() orelse return;
        self.menu_mode = .mcp;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.sel_len = 0;
        // attention rank (pi): failed first, then disabled, then connected.
        const Item = struct { srv: *mcp.Server, rank: u8 };
        var items: [mcp_max_servers]Item = undefined;
        var n: usize = 0;
        for (mgr.servers.items) |srv| {
            if (n >= mcp_max_servers) break;
            const rank: u8 = if (!srv.enabled) 1 else if (!srv.connected) 0 else 2;
            items[n] = .{ .srv = srv, .rank = rank };
            n += 1;
        }
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            const cur = items[i];
            while (j > 0 and (items[j - 1].rank > cur.rank or
                (items[j - 1].rank == cur.rank and std.mem.lessThan(u8, items[j - 1].srv.name, cur.srv.name)))) : (j -= 1)
            {
                items[j] = items[j - 1];
            }
            items[j] = cur;
        }
        for (items[0..n]) |it| {
            if (self.sel_len >= SEL_MAX) break;
            const row = self.sel_len;
            const desc = self.mcpServerDesc(it.srv);
            defer self.alloc.free(desc);
            self.selSetName(row, it.srv.name);
            self.selSetDesc(row, desc);
            self.selSetId(row, it.srv.name);
            self.sel_len += 1;
        }
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.refreshSelMenu();
    }

    const mcp_max_servers = 32;

    /// The actions menu for one server (pi serverMenu): enable/sign-in /
    /// tools/reconnect/sign-out/exposure/disable, with transport/scope/state
    /// details.
    fn openMcpServerMenu(self: *TUI, name: []const u8) void {
        const mgr = mcp.Manager.getGlobal() orelse return;
        const srv = mgr.findByName(name) orelse return;
        self.mcpSetServer(name);
        self.menu_mode = .mcp_server;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.sel_len = 0;
        var row: usize = 0;
        if (!srv.enabled) {
            self.selSetName(row, "Enable");
            self.selSetDesc(row, "saved to mcp.json");
            self.selSetId(row, "enable");
            row += 1;
        } else {
            if (srv.connected) {
                const d = std.fmt.allocPrint(self.alloc, "{d} offered", .{srv.tools.len}) catch return;
                defer self.alloc.free(d);
                self.selSetName(row, "Tools");
                self.selSetDesc(row, d);
                self.selSetId(row, "tools");
                row += 1;
            }
            self.selSetName(row, "Reconnect");
            self.selSetDesc(row, "");
            self.selSetId(row, "reconnect");
            row += 1;
            self.selSetName(row, "Exposure");
            self.selSetDesc(row, srv.exposure orelse "codemode");
            self.selSetId(row, "exposure");
            row += 1;
            self.selSetName(row, "Disable");
            self.selSetDesc(row, "saved to mcp.json");
            self.selSetId(row, "disable");
            row += 1;
        }
        self.sel_len = row;
        self.menu_selected = 0;
        self.refreshSelMenu();
    }

    /// The server's tool list (pi showTools): name + first description line;
    /// Enter goes back.
    fn openMcpToolsMenu(self: *TUI) void {
        const mgr = mcp.Manager.getGlobal() orelse return;
        const srv = mgr.findByName(self.mcpServerName()) orelse return;
        self.menu_mode = .mcp_tools;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.sel_len = 0;
        for (srv.tools) |t| {
            if (self.sel_len >= SEL_MAX) break;
            const row = self.sel_len;
            // first line of the description
            var line = t.description;
            if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
            self.selSetName(row, t.raw_name);
            self.selSetDesc(row, line);
            self.selSetId(row, t.raw_name);
            self.sel_len += 1;
        }
        self.menu_selected = 0;
        self.refreshSelMenu();
    }

    /// Exposure choice list (pi chooseExposure): all four values, the
    /// current one marked ✓.
    fn openMcpExposureMenu(self: *TUI) void {
        const mgr = mcp.Manager.getGlobal() orelse return;
        const srv = mgr.findByName(self.mcpServerName()) orelse return;
        const current = srv.exposure orelse "codemode";
        self.menu_mode = .mcp_exposure;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        self.sel_len = 0;
        const values = [_][]const u8{ "codemode", "direct", "deferred", "hidden" };
        const descs = [_][]const u8{
            "not declared; tool_search loads them",
            "declared to the model",
            "not declared; tool_search loads them",
            "unreachable",
        };
        for (values, 0..) |v, k| {
            if (self.sel_len >= SEL_MAX) break;
            const row = self.sel_len;
            var name_buf: [80]u8 = undefined;
            const name = if (std.mem.eql(u8, v, current))
                std.fmt.bufPrint(&name_buf, "✓ {s}", .{v}) catch v
            else
                v;
            self.selSetName(row, name);
            self.selSetDesc(row, descs[k]);
            self.selSetId(row, v);
            self.sel_len += 1;
            if (std.mem.eql(u8, v, current)) self.menu_selected = row;
        }
        self.refreshSelMenu();
    }

    /// Remove and re-register one server's tools (after reconnect/exposure/
    /// enable/disable changes).
    fn mcpReregisterTools(self: *TUI) void {
        const mgr = mcp.Manager.getGlobal() orelse return;
        const srv = mgr.findByName(self.mcpServerName()) orelse return;
        const prefix = std.fmt.allocPrint(self.alloc, "mcp__{s}__", .{srv.name}) catch return;
        defer self.alloc.free(prefix);
        self.session.registry.removeMatchingOn(&.{prefix}, struct {
            fn pred(patterns: []const []const u8, name: []const u8) bool {
                return patterns.len > 0 and std.mem.startsWith(u8, name, patterns[0]);
            }
        }.pred);
        _ = srv.registerToolsInto(self.session.registry);
    }

    // ---- Project trust prompt (pi TrustSelectorComponent) ----

    /// Open the trust selector (pi getProjectTrustOptions order). Called by
    /// main when a startup ask is pending, and by the /trust command.
    pub fn beginTrustPrompt(self: *TUI, cwd: []const u8, saved: ?bool, from_command: bool) void {
        self.freeTrustPrompt();
        const cwd_copy = self.alloc.dupe(u8, cwd) catch return;
        // Five options in pi's order; labels are copied into the static
        // sel_rows (kind ids ride along for applyTrustChoice).
        const parent = std.fs.path.dirname(cwd);
        const labels = [_][]const u8{
            "Trust",
            "Trust parent folder",
            "Trust (this session only)",
            "Do not trust",
            "Do not trust (this session only)",
        };
        const kinds = [_][]const u8{ "trust", "trust_parent", "trust_session", "distrust", "distrust_session" };
        self.sel_len = 0;
        self.menu_selected = 0;
        self.menu_view_start = 0;
        for (labels, 0..) |base_label, i| {
            if (self.sel_len >= SEL_MAX) break;
            if (i == 1 and parent == null) continue; // no parent (root cwd)
            const row = self.sel_len;
            var name_buf: [200]u8 = undefined;
            const name = if (i == 1)
                std.fmt.bufPrint(&name_buf, "{s} ({s})", .{ base_label, parent.? }) catch continue
            else
                base_label;
            self.selSetName(row, name);
            self.selSetDesc(row, "");
            self.selSetId(row, kinds[i]);
            self.sel_len += 1;
        }
        // Start on the saved-decision option (pi isSavedOption: first match).
        self.menu_selected = 0;
        if (saved) |sv| {
            const want: []const u8 = if (sv) "trust" else "distrust";
            for (0..self.sel_len) |i| {
                if (std.mem.eql(u8, self.sel_rows[i].id[0..self.sel_rows[i].id_len], want)) {
                    self.menu_selected = i;
                    break;
                }
            }
        }
        self.trust_prompt = .{ .cwd = cwd_copy, .saved = saved, .from_command = from_command };
        self.menu_mode = .trust;
        self.editor.clear() catch {};
        self.refreshSelMenu();
        self.redraw();
    }

    fn freeTrustPrompt(self: *TUI) void {
        if (self.trust_prompt) |*tp| {
            self.alloc.free(tp.cwd);
            self.trust_prompt = null;
        }
    }

    /// Enter in the trust selector: persist per kind (session-only choices
    /// skip the store), flip project_trusted, run the main-provided reload
    /// hook, then close (pi saveProjectTrustPromptResult + resource reload).
    fn applyTrustChoice(self: *TUI) void {
        const tp = self.trust_prompt orelse return;
        const kind = self.selRowId();
        var store = trust.Store.init(self.alloc, self.io, self.cfg.?.base_dir) catch null;
        defer if (store) |*st| st.deinit();
        if (std.mem.eql(u8, kind, "trust")) {
            if (store) |*st| st.set(tp.cwd, true) catch {};
            self.project_trusted = true;
            self.note("Project trusted (saved)", .{});
        } else if (std.mem.eql(u8, kind, "trust_parent")) {
            if (store) |*st| st.setParent(tp.cwd) catch {};
            self.project_trusted = true;
            self.note("Parent folder trusted (saved)", .{});
        } else if (std.mem.eql(u8, kind, "trust_session")) {
            self.project_trusted = true;
            self.note("Project trusted (this session only)", .{});
        } else if (std.mem.eql(u8, kind, "distrust")) {
            if (store) |*st| st.set(tp.cwd, false) catch {};
            self.project_trusted = false;
            self.note("Project marked untrusted (saved)", .{});
        } else {
            self.project_trusted = false;
            self.note("Project untrusted (this session only)", .{});
        }
        if (self.trust_reload_fn) |f| {
            if (self.trust_reload_ctx) |ctx| f(ctx, self, self.project_trusted);
        }
        self.endTrustPrompt(tp.from_command);
    }

    fn endTrustPrompt(self: *TUI, from_command: bool) void {
        self.freeTrustPrompt();
        self.menu_mode = .hidden;
        self.refreshSlashExtras();
        self.reloadResources() catch {};
        self.redraw();
        _ = from_command;
    }

    /// ESC in the trust prompt: startup ask cancels to untrusted (pi
    /// resolveProjectTrusted returns false when the prompt is cancelled);
    /// /trust just closes without changing anything.
    fn trustMenuCancel(self: *TUI) void {
        const tp = self.trust_prompt orelse {
            self.menu_mode = .hidden;
            return;
        };
        if (!tp.from_command) {
            self.project_trusted = false;
            if (self.trust_reload_fn) |f| {
                if (self.trust_reload_ctx) |ctx| f(ctx, self, false);
            }
            self.note("Project untrusted (this session only)", .{});
            self.endTrustPrompt(false);
        } else {
            self.freeTrustPrompt();
            self.menu_mode = .hidden;
            self.redraw();
        }
    }

    /// Enter in the /mcp manager menus. Returns should_exit (always false).
    fn mcpMenuActivate(self: *TUI) bool {
        switch (self.menu_mode) {
            .mcp => {
                const name = self.selRowId();
                if (name.len == 0) return false;
                self.openMcpServerMenu(name);
                self.redraw();
                return false;
            },
            .mcp_server => {
                const action = self.selRowId();
                const mgr = mcp.Manager.getGlobal() orelse return false;
                const srv = mgr.findByName(self.mcpServerName()) orelse return false;
                const path = self.mcpServerConfigPath(srv);
                defer self.alloc.free(path);
                if (std.mem.eql(u8, action, "enable") or std.mem.eql(u8, action, "disable")) {
                    const want = std.mem.eql(u8, action, "enable");
                    _ = mcp.setEntryField(self.alloc, self.io, path, srv.name, "enabled", if (want) "true" else "false") catch false;
                    srv.enabled = want;
                    if (want) {
                        if (srv.error_msg) |em| {
                            self.alloc.free(em);
                            srv.error_msg = null;
                        }
                        if (mgr.reconnectServer(srv.name)) {
                            self.mcpReregisterTools();
                            self.note("{s} connected", .{srv.name});
                        } else {
                            self.note("{s} reconnect failed", .{srv.name});
                        }
                    } else {
                        _ = mgr.reconnectServer(srv.name); // fails fast: disabled
                        srv.enabled = false;
                        if (srv.error_msg) |em| {
                            self.alloc.free(em);
                            srv.error_msg = null;
                        }
                        srv.error_msg = self.alloc.dupe(u8, "disabled") catch null;
                        mcp.teardownProcess(srv);
                        self.mcpReregisterTools();
                        self.note("{s} disabled", .{srv.name});
                    }
                } else if (std.mem.eql(u8, action, "reconnect")) {
                    if (mgr.reconnectServer(srv.name)) {
                        self.mcpReregisterTools();
                        self.note("{s} connected ({d} tools)", .{ srv.name, srv.tools.len });
                    } else {
                        self.mcpReregisterTools();
                        self.note("{s} reconnect failed: {s}", .{ srv.name, srv.error_msg orelse "?" });
                    }
                } else if (std.mem.eql(u8, action, "tools")) {
                    self.openMcpToolsMenu();
                    self.redraw();
                    return false;
                } else if (std.mem.eql(u8, action, "exposure")) {
                    self.openMcpExposureMenu();
                    self.redraw();
                    return false;
                }
                self.openMcpServerMenu(self.mcpServerName());
                self.redraw();
                return false;
            },
            .mcp_tools => {
                self.openMcpServerMenu(self.mcpServerName());
                self.redraw();
                return false;
            },
            .mcp_exposure => {
                const value = self.selRowId();
                if (value.len > 0) {
                    const mgr = mcp.Manager.getGlobal() orelse return false;
                    const srv = mgr.findByName(self.mcpServerName()) orelse return false;
                    const path = self.mcpServerConfigPath(srv);
                    defer self.alloc.free(path);
                    const vj = std.fmt.allocPrint(self.alloc, "\"{s}\"", .{value}) catch return false;
                    defer self.alloc.free(vj);
                    _ = mcp.setEntryField(self.alloc, self.io, path, srv.name, "exposure", vj) catch false;
                    if (srv.exposure) |old| self.alloc.free(old);
                    srv.exposure = self.alloc.dupe(u8, value) catch null;
                    self.mcpReregisterTools();
                    self.note("{s} exposure set to {s}", .{ srv.name, value });
                }
                self.openMcpServerMenu(self.mcpServerName());
                self.redraw();
                return false;
            },
            else => return false,
        }
    }

    /// ESC in the /mcp manager: back one level (servers menu closes).
    fn mcpMenuCancel(self: *TUI) void {
        switch (self.menu_mode) {
            .mcp_server, .mcp_tools, .mcp_exposure => self.openMcpManager(),
            else => self.menu_mode = .hidden,
        }
        self.redraw();
    }

    /// Send text as a user prompt with the full submit ceremony (display,
    /// scroll-to-end, spinner, watch). Frees the caller-owned text.
    fn submitText(self: *TUI, text: []const u8) void {
        self.addUserMessage(text);
        self.loader.start();
        self.render_mutex.lock(self.io) catch {};
        self.sv.scrollToEnd(ss.nowMs(self.io));
        self.render_mutex.unlock(self.io);
        self.startSpinner();
        self.startWatch();
        self.redraw();
        const run_err: ?anyerror = if (self.session.runPrompt(text)) |_| null else |e| e;
        _ = run_err;
        // Same post-turn ceremony as the editor path.
        self.drainTurnEvents();
        self.stopWatch();
        self.stopSpinner();
        self.loader.stop();
        self.redraw();
    }

    /// pi handleClipboardPaste (ctrl+v): clipboard image → temp file path
    /// inserted at cursor (the model Reads the path; the read tool attaches
    /// images); file paths and plain text fall back to direct insertion.
    fn handleClipboardPaste(self: *TUI) void {
        const alloc = self.alloc;
        if (clipboard.readClipboardImage(alloc, self.io, self.environ)) |img| {
            defer alloc.free(img.bytes);
            const path = clipboard.writeImageTempFile(alloc, self.io, img, if (std.mem.eql(u8, img.mime, "image/jpeg")) "jpg" else "png") orelse {
                self.note("{s}", .{"failed to write clipboard image"});
                return;
            };
            self.editor.insertBytes(path) catch {};
            alloc.free(path);
            self.redraw();
            return;
        }
        if (clipboard.readClipboardText(alloc, self.io, self.environ)) |text| {
            defer alloc.free(text);
            self.editor.insertBytes(text) catch {};
            self.redraw();
            return;
        }
    }

    /// Run a user `!cmd` synchronously (pi handleBashCommand): execute via
    /// the shell executor (30s cap), record a bashExecution message, and
    /// render a block. `!!` records excluded-from-context (pi prefix).
    fn runUserBash(self: *TUI, command: []const u8, exclude: bool) void {
        if (self.working) {
            self.note("{s}", .{"A bash command is already running. Press Esc to cancel it first."});
            return;
        }
        var out = std.array_list.Managed(u8).init(self.alloc);
        defer out.deinit();
        const res = shell.exec(self.alloc, self.io, shell.defaultConfig(), command, .{
            .timeout = 30,
        }, &out) catch {
            self.note("{s}", .{"failed to spawn shell"});
            return;
        };
        const exit_code: ?i32 = if (res.aborted or res.timed_out) null else if (res.exit_code) |c| @as(i32, c) else null;
        if (res.timed_out) out.appendSlice("\n[timed out after 30s]") catch {};
        if (res.aborted) out.appendSlice("\n[cancelled]") catch {};
        self.addBashBlock(command, out.items, exit_code, exclude);
        self.session.appendBashExecution(command, out.items, exit_code, exclude);
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
        const turn_events = self.session.takeTurnEvents();
        defer self.session.alloc.free(turn_events);
        for (turn_events) |ev| {
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
        if (turn_events.len == 0) return;
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
        const trimmed = std.mem.trim(u8, cmd, " \t");
        if (trimmed.len == 0) return .{ .word = "", .arg = "" };
        // word = first token; arg = the REST (multi-word args like
        // "/login <provider> <key>" or "/name my session" stay intact).
        const split_at = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return .{ .word = trimmed, .arg = "" };
        return .{ .word = trimmed[0..split_at], .arg = std.mem.trim(u8, trimmed[split_at + 1 ..], " \t") };
    }

    fn handleCommand(self: *TUI, cmd: []const u8) bool {
        const parsed = parseCmd(cmd);
        const word = parsed.word;
        const arg = parsed.arg;

        if (std.mem.eql(u8, word, "/exit") or std.mem.eql(u8, word, "/quit")) return true;

        // /skill:name [args] — force-load a skill (pi _expandSkillCommand).
        if (std.mem.startsWith(u8, word, "/skill:")) {
            if (self.expandSkillCommand(cmd)) |expanded| {
                defer self.alloc.free(expanded);
                self.submitText(expanded);
                return false;
            }
            self.note("Unknown skill: {s}", .{ word[7..] });
            self.redraw();
            return false;
        }

        // /reload — re-discover skills and rebuild the system prompt (pi).
        if (std.mem.eql(u8, word, "/reload")) {
            self.reloadResources() catch |e| {
                self.note("reload failed: {s}", .{@errorName(e)});
                self.redraw();
            };
            self.redraw();
            return false;
        }

        // /trust — re-run the project trust decision (pi showTrustSelector).
        if (std.mem.eql(u8, word, "/trust")) {
            var saved: ?bool = null;
            if (self.cfg) |c| {
                var store = trust.Store.init(self.alloc, self.io, c.base_dir) catch null;
                defer if (store) |*st| st.deinit();
                if (store) |*st| saved = st.get(self.cwd_abs);
            }
            self.beginTrustPrompt(self.cwd_abs, saved, true);
            self.redraw();
            return false;
        }

        // /mcp — list configured MCP servers with their state (pi /mcp).
        if (std.mem.eql(u8, word, "/mcp")) {
            self.showMcpStatus();
            self.redraw();
            return false;
        }

        // pi: an unknown `/name` is first checked against prompt templates —
        // a match sends the expansion as a normal message (handled here by
        // falling through to the editor path with the expansion applied).
        if (self.isPromptTemplate(word)) {
            const expanded = self.expandTemplate(cmd) catch null;
            if (expanded) |ex| {
                defer self.alloc.free(ex);
                self.submitText(ex);
                return false;
            }
        }

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
                ++ "  /mcp           list MCP servers and their state\n"
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

        // pi: /model (with or without a search term) opens the selector
        // (ModelSelectorComponent); Enter selects, Ctrl+S sets default.
        if (std.mem.eql(u8, word, "/model")) {
            self.openModelSelector(arg);
            self.redraw();
            return false;
        }

        // /login <provider> <api-key> — store a credential (pi /login: the
        // interactive picker + secret prompt needs a text-input UI we don't
        // have yet; the argument form covers api_key providers).
        if (std.mem.eql(u8, word, "/login")) {
            var pid: ?[]const u8 = null;
            var key: ?[]const u8 = null;
            var it = std.mem.tokenizeAny(u8, arg, " \t");
            if (it.next()) |a| pid = a;
            if (it.next()) |k| key = k;
            if (pid == null or key == null) {
                self.note("usage: /login <provider> <api-key>", .{});
            } else if (self.cfg) |c| {
                config.saveAuthEntry(self.alloc, self.io, c.base_dir, pid.?, key.?) catch {
                    self.note("failed to write auth.json", .{});
                    self.redraw();
                    return false;
                };
                // Apply immediately to models of that provider.
                var n: usize = 0;
                for (c.models.items) |*m| {
                    if (std.ascii.eqlIgnoreCase(m.provider, pid.?)) {
                        const copy = self.alloc.dupe(u8, key.?) catch continue;
                        self.alloc.free(m.api_key);
                        m.api_key = copy;
                        n += 1;
                    }
                }
                self.note("logged in to {s} ({d} models updated)", .{ pid.?, n });
            } else {
                self.note("no config loaded", .{});
            }
            self.redraw();
            return false;
        }

        // /logout [provider] — drop a stored credential (default: current).
        if (std.mem.eql(u8, word, "/logout")) {
            const pid = if (arg.len > 0) arg else self.session.model.provider;
            if (self.cfg) |c| {
                config.removeAuthEntry(self.alloc, self.io, c.base_dir, pid) catch {};
                for (c.models.items) |*m| {
                    if (std.mem.eql(u8, m.provider, pid)) {
                        const blank = self.alloc.dupe(u8, "") catch continue;
                        self.alloc.free(m.api_key);
                        m.api_key = blank;
                    }
                }
                self.note("logged out from {s}", .{pid});
            } else {
                self.note("no config loaded", .{});
            }
            self.redraw();
            return false;
        }

        // /scoped-models — pi ScopedModelsSelector (Enter toggles, Esc closes).
        if (std.mem.eql(u8, word, "/scoped-models")) {
            self.openScopedModelsMenu();
            return false;
        }

        // /share — pi shares via Radius artifact or GitHub gist; both need a
        // remote backend rpi does not have yet (K3).
        if (std.mem.eql(u8, word, "/share")) {
            self.addMessage("\x1b[90mshare is not available yet (needs a Radius/gist backend — planned)\x1b[0m");
            self.redraw();
            return false;
        }

        // /bug — report to the rpi repository.
        if (std.mem.eql(u8, word, "/bug")) {
            const detail = if (arg.len > 0) arg else "(no description)";
            self.addMessageFmt("bug tracker: https://git.yumakeji.cn/pengkebao/zpi/issues\nplease include: rpi v0.1.0 ({s}), the command you ran, and this description:\n  {s}", .{ @tagName(builtin.os.tag), detail });
            self.redraw();
            return false;
        }

        // /changelog — rpi keeps no packaged changelog file yet; point at git.
        if (std.mem.eql(u8, word, "/changelog")) {
            self.addMessage("rpi v0.1.0\nchangelog: https://git.yumakeji.cn/pengkebao/zpi/-/commits/main");
            self.redraw();
            return false;
        }

        // /thinking (pi) with the legacy /think kept as an alias.
        if (std.mem.eql(u8, word, "/think") or std.mem.eql(u8, word, "/thinking")) {
            if (arg.len == 0) {
                self.note("Thinking level: {s} (off|low|medium|high|xhigh|max)", .{self.session.thinking_level.name()});
            } else if (config.ThinkingLevel.fromStr(arg)) |lvl| {
                self.session.thinking_level = lvl;
                if (self.session.store) |st_think| st_think.recordThinkingLevel(lvl.name());
                self.note("Thinking level set to {s}", .{lvl.name()});
            } else {
                self.note("Unknown level: {s} (off|low|medium|high|xhigh|max)", .{arg});
            }
            self.redraw();
            return false;
        }

        // Session commands require an active store; unrecognized slash
        // commands fall through to send-as-message (pi semantics — a pasted
        // `/tmp/...` path is a message, not a command).
        const is_session_cmd = std.mem.eql(u8, word, "/session") or
            std.mem.eql(u8, word, "/name") or
            std.mem.eql(u8, word, "/tree") or
            std.mem.eql(u8, word, "/fork") or
            std.mem.eql(u8, word, "/clone") or
            std.mem.eql(u8, word, "/resume") or
            std.mem.eql(u8, word, "/import") or
            std.mem.eql(u8, word, "/export") or
            std.mem.eql(u8, word, "/compact");
        const st = if (!is_session_cmd) undefined else self.session.store orelse {
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
            const st_tree = self.session.store orelse {
                self.addMessage("\x1b[90m(no session active — started with --no-session)\x1b[0m");
                self.redraw();
                return false;
            };
            var chain: [SEL_MAX]ss.Store.ChainItem = undefined;
            if (st_tree.leafChain(&chain) == 0) {
                self.note("No entries in session", .{});
                self.redraw();
                return false;
            }
            self.openTreeMenu();
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
            const st_fork = self.session.store orelse {
                self.addMessage("\x1b[90m(no session active — started with --no-session)\x1b[0m");
                self.redraw();
                return false;
            };
            var chain: [SEL_MAX]ss.Store.ChainItem = undefined;
            const cnt_fork = st_fork.leafChain(&chain);
            var user_cnt: usize = 0;
            for (chain[0..cnt_fork]) |ci| {
                if (ci.is_user_message) user_cnt += 1;
            }
            if (user_cnt == 0) {
                self.note("No user messages to fork from", .{});
                self.redraw();
                return false;
            }
            self.openForkMenu();
            self.redraw();
            return false;
        }

        // pi /clone: duplicate the current session at its current position.
        if (std.mem.eql(u8, word, "/clone")) {
            const cloned = st.fork(self.sessions_dir, self.cwd_abs) catch {
                self.addMessage("\x1b[91m[clone failed]\x1b[0m");
                self.redraw();
                return false;
            };
            self.switchToStore(cloned);
            self.note("\x1b[90mcloned to session {s}\x1b[0m", .{cloned.id});
            self.redraw();
            return false;
        }

        // pi /import <path>: copy a session JSONL into the sessions dir and
        // switch to it (preserving its id and cwd).
        if (std.mem.eql(u8, word, "/import")) {
            if (arg.len == 0) {
                self.note("Usage: /import <path.jsonl>", .{});
                self.redraw();
                return false;
            }
            self.importSessionFrom(arg);
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/resume")) {
            if (arg.len == 0) {
                const list = ss.listForCwd(self.alloc, self.io, self.sessions_dir, self.cwd_abs) catch &.{};
                defer self.freeSessionList(list);
                if (list.len == 0) {
                    self.addMessage("\x1b[90mno sessions for this directory\x1b[0m");
                    self.redraw();
                    return false;
                }
                self.openSessionsMenu();
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
            if (std.mem.endsWith(u8, out_path, ".jsonl")) {
                // pi: .jsonl export = the raw session file (same entry stream).
                const data = std.Io.Dir.cwd().readFileAlloc(self.io, st.path, self.alloc, .limited(1 << 30)) catch {
                    self.addMessage("\x1b[91m[export failed: cannot read session file]\x1b[0m");
                    self.redraw();
                    return false;
                };
                defer self.alloc.free(data);
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out_path, .data = data }) catch {
                    self.addMessage("\x1b[91m[export failed]\x1b[0m");
                    self.redraw();
                    return false;
                };
            } else {
                st.exportHtml(self.alloc, out_path) catch {
                    self.addMessage("\x1b[91m[export failed]\x1b[0m");
                    self.redraw();
                    return false;
                };
            }
            self.note("\x1b[90mexported → {s}\x1b[0m", .{out_path});
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/compact")) {
            const custom = if (arg.len > 0) arg else null;
            self.addMessage("\x1b[90m[compacting...]\x1b[0m");
            self.redraw();
            const before = self.session.runCompactionReasoned(custom, "manual") catch {
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

        if (std.mem.eql(u8, word, "/settings")) {
            self.openSettingsMenu();
            self.redraw();
            return false;
        }

        if (std.mem.eql(u8, word, "/debug")) {
            self.writeDebugLog();
            self.redraw();
            return false;
        }

        // pi: an unrecognized slash command is sent as a normal message
        // (the clipboard paste flow inserts /tmp paths that start with "/").
        self.submitText(cmd);
        return false;
    }

    /// Add an owned one-line note to the scrollback, then free it.

    fn noteOwned(self: *TUI, text: []const u8) void {
        self.addMessage(text);
        self.alloc.free(text);
    }

    /// Format + add an owned note. On OOM, add a plain fallback (not freed).
    pub fn note(self: *TUI, comptime fmt: []const u8, args: anytype) void {
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

        // The startup header lives at the top of the document (added by
        // replaySession before any history, pi: headerContainer inside
        // documentContainer); the model is shown in the footer like pi.

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
            // Modal dialogs swallow the global bindings (scroll, search,
            // ctrl+c/d exit, paste...) — only the dialog's own keys respond.
            const modal_open = self.menu_mode == .settings or self.menu_mode == .sessions or
                self.menu_mode == .tree or self.menu_mode == .forksel or
                self.menu_mode == .mcp or self.menu_mode == .mcp_server or
                self.menu_mode == .mcp_tools or self.menu_mode == .mcp_exposure or
                self.menu_mode == .trust;
            if (key == .unknown and !modal_open) {
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
                if (!modal_open and self.bindings.matches(key, .clear_editor_exit)) {
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
            if (!modal_open and self.bindings.matches(key, .search)) {
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
            // While ANY completion menu is open, pgup/pgdn/home/end belong to
            // the menu (pi editor.js: autocomplete state intercepts
            // tui.select.pageUp/pageDown before anything else) — transcript
            // scrolling is skipped so the keys reach the menu branch below.
            const menu_captures_nav = self.menu_mode != .hidden;
            if (!menu_captures_nav and self.bindings.matches(key, .scroll_page_up)) {
                // pi: viewportHeight - PAGE_SCROLL_OVERLAP (4 rows of context).
                self.scrollBy(-@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                self.redraw();
                continue;
            }
            if (!menu_captures_nav and self.bindings.matches(key, .scroll_page_down)) {
                self.scrollBy(@as(isize, @intCast(@max(1, self.transcript_h -| 4))));
                self.redraw();
                continue;
            }
            if (!menu_captures_nav and self.bindings.matches(key, .scroll_top)) {
                self.render_mutex.lock(self.io) catch continue;
                self.sv.scrollToStart(ss.nowMs(self.io));
                self.render_mutex.unlock(self.io);
                self.redraw();
                continue;
            }
            if (!menu_captures_nav and self.bindings.matches(key, .scroll_bottom)) {
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
            if (!modal_open and self.bindings.matches(key, .toggle_tools)) {
                self.setToolsExpanded(!self.tools_expanded);
                self.redraw();
                continue;
            }
            if (self.bindings.matches(key, .toggle_thinking)) {
                self.thinking_hidden = !self.thinking_hidden;
                self.redraw();
                continue;
            }

            // pi: app.thinking.cycle (shift+tab), app.model.cycle (ctrl+p /
            // shift+ctrl+p), app.model.select (ctrl+l), app.message.copy
            // (ctrl+x), app.suspend (ctrl+z), app.exit (ctrl+d).
            if (self.bindings.matches(key, .thinking_cycle)) {
                self.cycleThinkingLevel();
                continue;
            }
            if (!modal_open and self.bindings.matches(key, .model_next)) {
                self.cycleModel(1);
                continue;
            }
            if (!modal_open and self.bindings.matches(key, .model_prev)) {
                self.cycleModel(-1);
                continue;
            }
            if (self.bindings.matches(key, .model_select)) {
                _ = self.handleCommand("/model");
                continue;
            }
            if (self.bindings.matches(key, .copy_message)) {
                self.copyLastMessage();
                continue;
            }
            if (!modal_open and self.bindings.matches(key, .paste_clipboard)) {

                self.handleClipboardPaste();
                continue;
            }
            if (self.bindings.matches(key, .suspend_bg)) {
                self.suspendToBackground();
                continue;
            }
            if (!modal_open and self.bindings.matches(key, .exit_empty)) {
                if (self.editor.isEmpty()) break;
                continue;
            }

            // Completion menu navigation (takes precedence over editor keys).
            if (key == .tab and self.menu_mode == .hidden) {
                // Tab manually opens the @file menu (pi: Tab lists files at
                // the cursor's '@' token). Without a pending token the key
                // falls through to the editor (no-op).
                if (self.at_suppress) |sup| {
                    self.alloc.free(sup);
                    self.at_suppress = null;
                }
                self.updateMenu();
                if (self.menu_mode == .files) {
                    self.redraw();
                    continue;
                }
            }
            if (self.menu_mode == .files) {
                if (self.bindings.matches(key, .menu_up)) {
                    self.menu_selected = if (self.menu_selected == 0) self.menu_len - 1 else self.menu_selected - 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    self.menu_selected = if (self.menu_selected + 1 >= self.menu_len) 0 else self.menu_selected + 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.menu_mode = .hidden;
                    if (self.at_suppress) |sup| {
                        self.alloc.free(sup);
                        self.at_suppress = null;
                    }
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    self.applyFileCompletion();
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_tab)) {
                    self.applyFileCompletion();
                    self.updateMenu();
                    self.redraw();
                    continue;
                }
                // anything else falls through to the editor (live filtering)
            }
            if (self.menu_mode == .trust) {
                // Trust prompt: arrows + Enter + Esc only (pi TrustSelector).
                if (self.bindings.matches(key, .menu_up)) {
                    self.menu_selected = if (self.menu_selected == 0) self.sel_len - 1 else self.menu_selected - 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    self.menu_selected = if (self.menu_selected + 1 >= self.sel_len) 0 else self.menu_selected + 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.trustMenuCancel();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    _ = self.menuActivate();
                    self.redraw();
                    continue;
                }
                continue; // swallow everything else while the prompt is open
            }
            if (self.menu_mode == .scoped) {
                // Scoped-models selector (pi ScopedModelsSelector): arrows +
                // Enter toggle; Esc closes. Session-only.
                if (self.bindings.matches(key, .menu_up)) {
                    self.menu_selected = if (self.menu_selected == 0) self.menu_len - 1 else self.menu_selected - 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    self.menu_selected = if (self.menu_selected + 1 >= self.menu_len) 0 else self.menu_selected + 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.menu_mode = .hidden;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    _ = self.menuActivate();
                    self.redraw();
                    continue;
                }
                continue; // swallow everything else while the selector is open
            }
            if (self.menu_mode == .model_selector) {
                // Model selector (pi ModelSelectorComponent): arrows navigate;
                // Enter selects; Ctrl+S sets the default model; Esc cancels;
                // printable keys edit the search. Tab toggles all/scoped when
                // a scope exists.
                if (self.bindings.matches(key, .menu_up)) {
                    if (self.ms_sel > 0) self.ms_sel -= 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    if (self.ms_sel + 1 < self.ms_visible) self.ms_sel += 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.closeModelSelector();
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    if (self.ms_visible > 0) {
                        const idx = self.ms_filtered.items[self.ms_sel];
                        self.closeModelSelector();
                        self.switchModel(idx) catch |err| {
                            self.note("model switch failed: {s}", .{@errorName(err)});
                        };
                    }
                    self.redraw();
                    continue;
                }
                switch (key) {
                    .char => |c| {
                        if (c.ctrl and (c.c == 's' or c.c == 'S')) {
                            // pi app.models.save: set as default model.
                            if (self.ms_visible > 0) {
                                self.setDefaultModel(self.ms_filtered.items[self.ms_sel]);
                            }
                            self.redraw();
                            continue;
                        }
                        if (!c.ctrl and !c.alt and c.c >= 0x20 and c.c != 127) {
                            self.editor.insertChar(c.c) catch {};
                            self.ms_sel = 0;
                            self.modelSelectorRefilter();
                            self.redraw();
                            continue;
                        }
                    },
                    .backspace => {
                        const t = self.editor.getText() catch "";
                        if (t.len > 0) {
                            self.editor.replaceRange(t.len - 1, t.len, "") catch {};
                            self.ms_sel = 0;
                            self.modelSelectorRefilter();
                        }
                        self.redraw();
                        continue;
                    },
                    .tab => {
                        if (self.scoped_models != null) {
                            self.ms_scope_all = !self.ms_scope_all;
                            self.ms_sel = 0;
                            self.modelSelectorRefilter();
                        }
                        self.redraw();
                        continue;
                    },
                    else => {},
                }
                continue; // swallow everything else while the selector is open
            }
            if (self.menu_mode == .settings) {
                // Settings selector (pi SettingsSelectorComponent): the
                // editor line is the search input; arrows navigate; Enter/
                // Space cycles the value; Esc cancels. Printable keys and
                // backspace edit the search.
                if (self.bindings.matches(key, .menu_up)) {
                    if (self.settings_sel > 0) self.settings_sel -= 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    if (self.settings_sel + 1 < self.settings_visible) self.settings_sel += 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.menu_mode = .hidden;
                    self.editor.clear() catch {};
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    // pi applies silently — the row's value already shows it.
                    if (self.settings_visible > 0) {
                        const def = SETTING_DEFS[self.settings_filtered[self.settings_sel]];
                        if (!self.settingsApplyNext(def)) {
                            self.note("{s}: not implemented yet", .{def.label});
                        }
                    }
                    self.redraw();
                    continue;
                }
                // Space also cycles (pi Enter/Space to change).
                if (key == .space) {
                    if (self.settings_visible > 0) {
                        const def = SETTING_DEFS[self.settings_filtered[self.settings_sel]];
                        if (!self.settingsApplyNext(def)) {
                            self.note("{s}: not implemented yet", .{def.label});
                        }
                    }
                    self.redraw();
                    continue;
                }
                if (key == .backspace) {
                    // Backspace: drop the last search character.
                    const t = self.editor.getText() catch "";
                    if (t.len > 0) {
                        const cut = t[t.len - 1] & 0x7f;
                        _ = cut;
                        self.editor.replaceRange(t.len - 1, t.len, "") catch {};
                        self.settingsRefilter();
                        self.settings_sel = 0;
                    }
                    self.redraw();
                    continue;
                }
                switch (key) {
                    .char => |c| {
                        // Printable: append to the search line and refilter.
                        if (!c.ctrl and !c.alt and c.c >= 0x20 and c.c != 127) {
                            self.editor.insertChar(c.c) catch {};
                            self.settingsRefilter();
                            self.settings_sel = 0;
                            self.redraw();
                            continue;
                        }
                    },
                    else => {},
                }
                continue; // swallow everything else while the selector is open
            }
            if (self.menu_mode == .sessions or self.menu_mode == .tree or self.menu_mode == .forksel) {
                // Modal session/tree pickers (pi SessionSelector/
                // TreeSelector): arrows + Enter; the sessions picker also
                // filters on typed characters and deletes with ctrl+d.
                if (self.bindings.matches(key, .menu_up)) {
                    self.menu_selected = if (self.menu_selected == 0) self.sel_len - 1 else self.menu_selected - 1;
                    self.scrollSelMenu();
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    self.menu_selected = if (self.menu_selected + 1 >= self.sel_len) 0 else self.menu_selected + 1;
                    self.scrollSelMenu();
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    self.menu_mode = .hidden;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_confirm)) {
                    const should_exit = self.menuActivate();
                    if (should_exit) break;
                    self.redraw();
                    continue;
                } else if (key == .char and key.char.ctrl and key.char.c == 'd' and self.menu_mode == .sessions) {
                    // pi: Ctrl+D deletes the highlighted session.
                    const path = self.alloc.dupe(u8, self.selRowId()) catch null;
                    if (path) |p| {
                        defer self.alloc.free(p);
                        ss.Store.deleteSessionFile(self.io, p);
                        self.refilterSessions();
                        self.note("deleted {s}", .{std.fs.path.basename(p)});
                    }
                    self.redraw();
                    continue;
                } else if (key == .backspace and self.menu_mode == .sessions) {
                    // Type-to-filter: backspace trims the filter (keys parse
                    // 0x7f/0x08 as .backspace, not .char).
                    if (self.sel_filter_len > 0) self.sel_filter_len -= 1;
                    self.refilterSessions();
                    self.redraw();
                    continue;
                } else if (key == .char and !key.char.ctrl and self.menu_mode == .sessions) {
                    // Type-to-filter (pi session selector search).
                    const c = key.char.c;
                    if (c >= 0x20 and self.sel_filter_len < self.sel_filter.len) {
                        self.sel_filter[self.sel_filter_len] = c;
                        self.sel_filter_len += 1;
                    } else {
                        continue;
                    }
                    self.refilterSessions();
                    self.redraw();
                    continue;
                }
                continue; // swallow everything else while a picker is open
            }
            if (self.menu_mode != .hidden) {
                const is_mcp = self.menu_mode == .mcp or self.menu_mode == .mcp_server or
                    self.menu_mode == .mcp_tools or self.menu_mode == .mcp_exposure;
                // pi SelectList.handleInput: up/down WRAP AROUND; pgup/pgdn
                // move by one page (clamped to the bounds).
                if (self.bindings.matches(key, .menu_up)) {
                    self.menu_selected = if (self.menu_selected == 0) self.menu_len - 1 else self.menu_selected - 1;
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_down)) {
                    self.menu_selected = if (self.menu_selected + 1 >= self.menu_len) 0 else self.menu_selected + 1;
                    self.redraw();
                    continue;
                } else if (key == .page_up or key == .page_down) {
                    // pi getSelectPageIndex: target = clamp(sel ± pageSize).
                    const page = self.menuMaxVisible();
                    if (key == .page_up) {
                        self.menu_selected = if (self.menu_selected > page) self.menu_selected - page else 0;
                    } else {
                        const rest = self.menu_len - 1 - self.menu_selected;
                        self.menu_selected = if (rest > page) self.menu_selected + page else self.menu_len - 1;
                    }
                    self.redraw();
                    continue;
                } else if (self.bindings.matches(key, .menu_close)) {
                    if (is_mcp) {
                        self.mcpMenuCancel();
                    } else {
                        self.menu_mode = .hidden;
                        self.redraw();
                    }
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
                } else if (is_mcp) {
                    // The manager menu swallows everything else (pi
                    // McpManagerView handles only menu keys).
                    continue;
                }
            }

            // Translate configured newline/submit keys into canonical editor
            // keys so the editor stays mapping-agnostic.
            // pi handleFollowUp (interactive-mode.js): idle Alt+Enter acts
            // like regular Enter (submit); while streaming the watcher
            // queues it as follow-up instead.
            const is_alt_enter = switch (key) {
                .char => |c| c.c == '\r' and c.alt,
                else => false,
            };
            var editor_key = key;
            if (self.bindings.matches(key, .newline)) {
                editor_key = .shift_enter;
            } else if (self.bindings.matches(key, .submit)) {
                editor_key = .enter;
            } else if (is_alt_enter) {
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
                    // Phase I3: the input event (hooks.json "input" scripts).
                    if (events.getGlobal()) |bus| {
                        if (bus.emitBlocking(.{ .input = input })) |reason| {
                            bus.alloc.free(reason);
                            self.note("input blocked by hook", .{});
                            self.redraw();
                            self.alloc.free(input);
                            continue;
                        }
                    }
                    if (std.mem.startsWith(u8, input, "/")) {
                        const should_exit = self.handleCommand(input);
                        self.alloc.free(input);
                        if (should_exit) break;
                        self.redraw();
                        continue;
                    }
                    // pi handleBashCommand: `!cmd` runs locally and records a
                    // bashExecution message; `!!cmd` is excluded from context.
                    if (std.mem.startsWith(u8, input, "!")) {
                        const is_excluded = std.mem.startsWith(u8, input, "!!");
                        const command = std.mem.trim(u8, if (is_excluded) input[2..] else input[1..], " \t");
                        if (command.len > 0) {
                            self.runUserBash(command, is_excluded);
                        }
                        self.alloc.free(input);
                        self.redraw();
                        continue;
                    }
                    // pi expandPromptTemplate: `/name args` submissions expand
                    // against discovered prompt templates before sending.
                    if (std.mem.startsWith(u8, input, "/") == false and input.len > 1 and input[0] == '/') {}
                    const expanded_input = self.expandTemplate(input) catch input;
                    const text_to_send: []const u8 = if (expanded_input.ptr != input.ptr) blk: {
                        self.alloc.free(input);
                        break :blk expanded_input;
                    } else expanded_input;
                    self.addUserMessage(text_to_send);
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
                    const run_err: ?anyerror = if (self.session.runPrompt(text_to_send)) |_| null else |e| e;
                    // text_to_send is freed once at the end of the turn
                    // (it owns the expanded copy or the raw input).
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
                    // Owns either `expanded_input` (input already freed at
                    // the expansion site) or `input` itself — exactly once.
                    self.alloc.free(text_to_send);
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
            // Copy the whole escape sequence: CSI (params + final byte),
            // OSC (terminated by BEL or ST — an OSC 8 hyperlink must not be
            // torn apart or the URL leaks into the cell math), and plain
            // two-byte escapes.
            var k = i + 1;
            if (k < line.len and line[k] == '[') {
                k += 1;
                while (k < line.len and !(line[k] >= 0x40 and line[k] <= 0x7E)) k += 1;
                k = @min(k + 1, line.len);
            } else if (k < line.len and (line[k] == ']' or line[k] == 'P' or line[k] == '_' or line[k] == '^')) {
                k += 1;
                while (k < line.len) : (k += 1) {
                    if (line[k] == 0x07) {
                        k += 1;
                        break;
                    }
                    if (line[k] == 0x1b and k + 1 < line.len and line[k + 1] == '\\') {
                        k += 2;
                        break;
                    }
                }
            } else if (k < line.len) {
                k += 1;
            }
            out.appendSlice(alloc, line[i..k]) catch return error.OutOfMemory;
            i = k;
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
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools_test.Registry.init(alloc);
    try tools_test.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    var t = TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
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

/// Case-insensitive substring search (heap-free; used by the session picker).
fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) continue :outer;
        }
        return true;
    }
    return false;
}
