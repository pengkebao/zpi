//! Configurable keybindings (G7) — `~/.pi/agent/keybindings.json`.
//!
//! Maps UI actions to keys. Format mirrors pi: an object where each value is
//! a key name string or an array of them:
//!
//! ```json
//! {
//!   "newline": ["ctrl+j", "alt+enter"],
//!   "submit": "enter",
//!   "menu_close": "escape"
//! }
//! ```
//!
//! Unknown actions/keys are ignored; actions not mentioned keep their
//! defaults. The run loop translates matched keys into the canonical editor
//! keys (newline → shift+enter, submit → enter) so the editor itself stays
//! mapping-agnostic.

const std = @import("std");
const keys = @import("keys.zig");

pub const Key = keys.Key;

/// Number of configurable key slots per action.
pub const MAX_KEYS = 4;

pub const Action = enum(u8) {
    newline = 0, // insert a line break in the editor
    submit, // submit the prompt
    clear_editor_exit, // ctrl+c smart behavior: clear if non-empty, else exit
    external_editor, // open $EDITOR (pi: app.editor.external)
    menu_up,
    menu_down,
    menu_tab,
    menu_confirm,
    menu_close,
    toggle_tools, // ctrl+o: collapse/expand tool output (pi: app.tools.expand)
    toggle_thinking, // ctrl+t: show/hide thinking blocks (pi: app.thinking.toggle)
    // Transcript viewport (pi: tui.altScreen.*). These intentionally shadow
    // the unmodified editor bindings, like pi's fullscreen mode.
    scroll_page_up, // pageUp
    scroll_page_down, // pageDown
    scroll_half_page_up, // unbound by default
    scroll_half_page_down, // unbound by default
    scroll_line_up, // unbound by default
    scroll_line_down, // unbound by default
    scroll_top, // ctrl+home
    scroll_bottom, // ctrl+end
    prompt_previous, // ctrl+shift+up / ctrl+up: previous user message
    prompt_next, // ctrl+shift+down / ctrl+down: next user message
    search, // ctrl+shift+f: find in transcript (toggles)
    search_next, // enter / ctrl+g, while the search box is open
    search_previous, // shift+enter / ctrl+shift+g
    search_close, // escape

    pub const count = @typeInfo(Action).@"enum".field_names.len;

    pub fn name(self: Action) []const u8 {
        return @tagName(self);
    }

    fn fromString(s: []const u8) ?Action {
        inline for (0..count) |i| {
            const a: Action = @enumFromInt(i);
            if (std.mem.eql(u8, a.name(), s)) return a;
        }
        return null;
    }
};

pub const Bindings = struct {
    keys: [Action.count][MAX_KEYS]?Key,

    pub fn default() Bindings {
        var b: Bindings = undefined;
        for (&b.keys) |*slot| slot.* = @splat(null);
        b.set(.newline, parseKeyStr("shift+enter") orelse Key.shift_enter);
        b.set(.newline, parseKeyStr("ctrl+j") orelse Key.shift_enter);
        b.set(.submit, parseKeyStr("enter") orelse Key.enter);
        b.set(.clear_editor_exit, parseKeyStr("ctrl+c") orelse Key.escape);
        b.set(.external_editor, parseKeyStr("ctrl+g") orelse Key.escape);
        b.set(.menu_up, parseKeyStr("up") orelse Key.up);
        b.set(.menu_down, parseKeyStr("down") orelse Key.down);
        b.set(.menu_tab, parseKeyStr("tab") orelse Key.tab);
        b.set(.menu_confirm, parseKeyStr("enter") orelse Key.enter);
        b.set(.menu_close, parseKeyStr("escape") orelse Key.escape);
        b.set(.toggle_tools, parseKeyStr("ctrl+o") orelse Key.escape);
        b.set(.toggle_thinking, parseKeyStr("ctrl+t") orelse Key.escape);
        b.set(.scroll_page_up, parseKeyStr("pageUp") orelse Key.page_up);
        b.set(.scroll_page_down, parseKeyStr("pageDown") orelse Key.page_down);
        // halfPage / line scroll: no default keys (configurable).
        b.set(.scroll_top, parseKeyStr("ctrl+home") orelse Key.ctrl_home);
        b.set(.scroll_bottom, parseKeyStr("ctrl+end") orelse Key.ctrl_end);
        b.set(.prompt_previous, parseKeyStr("ctrl+shift+up") orelse Key.ctrl_shift_up);
        b.set(.prompt_previous, parseKeyStr("ctrl+up") orelse Key.ctrl_up);
        b.set(.prompt_next, parseKeyStr("ctrl+shift+down") orelse Key.ctrl_shift_down);
        b.set(.prompt_next, parseKeyStr("ctrl+down") orelse Key.ctrl_down);
        b.set(.search, parseKeyStr("ctrl+shift+f") orelse Key.escape);
        b.set(.search_next, parseKeyStr("enter") orelse Key.enter);
        b.set(.search_next, parseKeyStr("ctrl+g") orelse Key.escape);
        b.set(.search_previous, parseKeyStr("shift+enter") orelse Key.shift_enter);
        b.set(.search_previous, parseKeyStr("ctrl+shift+g") orelse Key.escape);
        b.set(.search_close, parseKeyStr("escape") orelse Key.escape);
        return b;
    }

    /// Append a key binding (ignores duplicates and overflow).
    pub fn set(self: *Bindings, action: Action, key: Key) void {
        const slot = &self.keys[@intFromEnum(action)];
        for (slot) |existing| {
            if (existing) |k| {
                if (keyEql(k, key)) return;
            }
        }
        for (slot) |*k| {
            if (k.* == null) {
                k.* = key;
                return;
            }
        }
    }

    pub fn matches(self: *const Bindings, key: Key, action: Action) bool {
        for (self.keys[@intFromEnum(action)]) |k| {
            if (k) |bound| {
                if (keyEql(bound, key)) return true;
            }
        }
        return false;
    }

    /// Load bindings from `<base_dir>/keybindings.json`; missing/invalid file
    /// returns the defaults.
    pub fn load(alloc: std.mem.Allocator, io: std.Io, base_dir: []const u8) Bindings {
        _ = alloc;
        var b = Bindings.default();
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/keybindings.json", .{base_dir}) catch return b;
        const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return b;
        defer std.Io.File.close(f, io);
        var buf: [1 << 16]u8 = undefined;
        const nbytes = std.Io.File.readPositionalAll(f, io, &buf, 0) catch return b;
        b.applyJson(buf[0..nbytes]) catch {};
        return b;
    }

    /// Apply a JSON object of `action: key-or-array-of-keys` overrides.
    /// An action mentioned in the JSON fully replaces its default bindings.
    pub fn applyJson(self: *Bindings, data: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadFormat;
        var seen: [Action.count]bool = @splat(false);
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const action = Action.fromString(entry.key_ptr.*) orelse continue;
            // First mention: replace defaults entirely.
            if (!seen[@intFromEnum(action)]) {
                seen[@intFromEnum(action)] = true;
                self.keys[@intFromEnum(action)] = @splat(null);
            }
            switch (entry.value_ptr.*) {
                .string => |s| {
                    if (parseKeyStr(s)) |k| self.set(action, k);
                },
                .array => |arr| {
                    for (arr.items) |v| {
                        if (v == .string) {
                            if (parseKeyStr(v.string)) |k| self.set(action, k);
                        }
                    }
                },
                else => {},
            }
        }
    }
};

/// Human-readable label for a Key (for /hotkeys display), in the notation
/// `parseKeyStr` reads back.
pub fn keyLabel(alloc: std.mem.Allocator, key: Key) ![]u8 {
    switch (key) {
        .char => |c| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(alloc);
            if (c.ctrl) try out.appendSlice(alloc, "ctrl+");
            if (c.shift) try out.appendSlice(alloc, "shift+");
            if (c.alt) try out.appendSlice(alloc, "alt+");
            try out.append(alloc, c.c);
            return out.toOwnedSlice(alloc);
        },
        .shift_enter => return alloc.dupe(u8, "shift+enter"),
        .enter => return alloc.dupe(u8, "enter"),
        .escape => return alloc.dupe(u8, "escape"),
        .tab => return alloc.dupe(u8, "tab"),
        .shift_tab => return alloc.dupe(u8, "shift+tab"),
        .space => return alloc.dupe(u8, "space"),
        .backspace => return alloc.dupe(u8, "backspace"),
        .page_up => return alloc.dupe(u8, "pageUp"),
        .page_down => return alloc.dupe(u8, "pageDown"),
        .ctrl_home => return alloc.dupe(u8, "ctrl+home"),
        .ctrl_end => return alloc.dupe(u8, "ctrl+end"),
        .ctrl_up => return alloc.dupe(u8, "ctrl+up"),
        .ctrl_down => return alloc.dupe(u8, "ctrl+down"),
        .ctrl_shift_up => return alloc.dupe(u8, "ctrl+shift+up"),
        .ctrl_shift_down => return alloc.dupe(u8, "ctrl+shift+down"),
        else => {
            const tag = @tagName(key);
            var buf: [32]u8 = undefined;
            // snake_case -> lowercased tag as-is (up/down/left/right/f1..)
            const label = std.ascii.lowerString(&buf, tag);
            return alloc.dupe(u8, label);
        },
    }
}

/// A key label in pi's display form: every `+`-separated part capitalized
/// ("shift+enter" → "Shift+Enter", "ctrl+g" → "Ctrl+G"). Owned.
pub fn keyTitle(alloc: std.mem.Allocator, key: Key) ![]u8 {
    const label = try keyLabel(alloc, key);
    var start = true;
    for (label) |*c| {
        if (start) c.* = std.ascii.toUpper(c.*);
        start = c.* == '+';
    }
    return label;
}

/// Comma-separated labels of all keys bound to `action` (owned).
pub fn actionLabel(alloc: std.mem.Allocator, b: *const Bindings, action: Action) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (b.keys[@intFromEnum(action)]) |maybe| {
        const k = maybe orelse continue;
        const label = try keyLabel(alloc, k);
        defer alloc.free(label);
        if (out.items.len > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, label);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// Structural key equality (union(enum) with payloads).
pub fn keyEql(a: Key, b: Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .char => |ca| {
            const cb = b.char;
            return ca.c == cb.c and ca.ctrl == cb.ctrl and ca.alt == cb.alt and ca.shift == cb.shift;
        },
        .text => |ta| {
            const tb = b.text;
            return ta.len == tb.len and std.mem.eql(u8, ta.bytes[0..ta.len], tb.bytes[0..tb.len]);
        },
        else => return true, // same tag, no payload
    }
}

/// Parse a key name like "ctrl+j", "shift+enter", "alt+x", "escape", "tab",
/// "pageUp", "ctrl+up", "ctrl+home" into a Key. Names are case-insensitive.
/// Returns null for unknown names.
pub fn parseKeyStr(s: []const u8) ?Key {
    var ctrl = false;
    var alt = false;
    var shift = false;
    var rest = s;
    while (true) {
        if (std.mem.startsWith(u8, rest, "ctrl+")) {
            ctrl = true;
            rest = rest[5..];
        } else if (std.mem.startsWith(u8, rest, "alt+")) {
            alt = true;
            rest = rest[4..];
        } else if (std.mem.startsWith(u8, rest, "shift+")) {
            shift = true;
            rest = rest[6..];
        } else break;
    }
    if (rest.len == 0) return null;
    // Named keys (case-insensitive: pi writes "pageUp").
    var name_buf: [16]u8 = undefined;
    if (rest.len >= 2 and rest.len <= name_buf.len) {
        const name = std.ascii.lowerString(&name_buf, rest);
        if (std.mem.eql(u8, name, "enter")) {
            if (alt) return .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } };
            if (ctrl) return .{ .char = .{ .c = '\r', .ctrl = true, .alt = false } };
            return if (shift) Key.shift_enter else Key.enter;
        }
        if (std.mem.eql(u8, name, "escape")) return Key.escape;
        if (std.mem.eql(u8, name, "tab")) return if (shift) Key.shift_tab else Key.tab;
        if (std.mem.eql(u8, name, "space")) return Key.space;
        if (std.mem.eql(u8, name, "up")) return verticalKey(true, ctrl, shift);
        if (std.mem.eql(u8, name, "down")) return verticalKey(false, ctrl, shift);
        if (std.mem.eql(u8, name, "left")) return Key.left;
        if (std.mem.eql(u8, name, "right")) return Key.right;
        if (std.mem.eql(u8, name, "home")) return if (ctrl) Key.ctrl_home else Key.home;
        if (std.mem.eql(u8, name, "end")) return if (ctrl) Key.ctrl_end else Key.end;
        if (std.mem.eql(u8, name, "backspace")) return Key.backspace;
        if (std.mem.eql(u8, name, "delete")) return Key.delete;
        if (std.mem.eql(u8, name, "pageup")) return Key.page_up;
        if (std.mem.eql(u8, name, "pagedown")) return Key.page_down;
    }
    // Single character with modifiers.
    if (rest.len == 1) {
        const c = rest[0];
        if (ctrl or alt or c >= 32) {
            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            return .{ .char = .{ .c = lower, .ctrl = ctrl, .alt = alt, .shift = shift and ctrl } };
        }
    }
    return null;
}

/// "up"/"down" with ctrl (and optionally shift) name the transcript jumps.
fn verticalKey(up: bool, ctrl: bool, shift: bool) Key {
    if (!ctrl) return if (up) Key.up else Key.down;
    if (up) return if (shift) Key.ctrl_shift_up else Key.ctrl_up;
    return if (shift) Key.ctrl_shift_down else Key.ctrl_down;
}

// ---- tests ----

const t = std.testing;

test "default bindings" {
    const b = Bindings.default();
    try t.expect(b.matches(.shift_enter, .newline));
    try t.expect(b.matches(.{ .char = .{ .c = 'j', .ctrl = true, .alt = false } }, .newline));
    try t.expect(!b.matches(.enter, .newline));
    try t.expect(b.matches(.enter, .submit));
    try t.expect(b.matches(.escape, .menu_close));
    try t.expect(b.matches(.{ .char = .{ .c = 'g', .ctrl = true, .alt = false } }, .external_editor));
}

test "parseKeyStr" {
    try t.expect(keyEql(parseKeyStr("ctrl+j").?, .{ .char = .{ .c = 'j', .ctrl = true, .alt = false } }));
    try t.expect(keyEql(parseKeyStr("alt+x").?, .{ .char = .{ .c = 'x', .ctrl = false, .alt = true } }));
    try t.expect(keyEql(parseKeyStr("escape").?, .escape));
    try t.expect(keyEql(parseKeyStr("shift+enter").?, .shift_enter));
    try t.expect(keyEql(parseKeyStr("ctrl+C").?, .{ .char = .{ .c = 'c', .ctrl = true, .alt = false } }));
    try t.expect(parseKeyStr("bogus") == null);
    try t.expect(parseKeyStr("ctrl+") == null);
}

test "parseKeyStr viewport and search keys" {
    // pi spells it "pageUp"; names are case-insensitive.
    try t.expect(keyEql(parseKeyStr("pageUp").?, .page_up));
    try t.expect(keyEql(parseKeyStr("pagedown").?, .page_down));
    try t.expect(keyEql(parseKeyStr("ctrl+home").?, .ctrl_home));
    try t.expect(keyEql(parseKeyStr("ctrl+end").?, .ctrl_end));
    try t.expect(keyEql(parseKeyStr("home").?, .home));
    try t.expect(keyEql(parseKeyStr("ctrl+up").?, .ctrl_up));
    try t.expect(keyEql(parseKeyStr("ctrl+shift+up").?, .ctrl_shift_up));
    try t.expect(keyEql(parseKeyStr("ctrl+down").?, .ctrl_down));
    try t.expect(keyEql(parseKeyStr("ctrl+shift+down").?, .ctrl_shift_down));
    try t.expect(keyEql(parseKeyStr("up").?, .up));
    // ctrl+shift+f is not ctrl+f.
    const csf = parseKeyStr("ctrl+shift+f").?;
    try t.expect(keyEql(csf, .{ .char = .{ .c = 'f', .ctrl = true, .alt = false, .shift = true } }));
    try t.expect(!keyEql(csf, parseKeyStr("ctrl+f").?));
    // Shift alone does not mark a plain character.
    try t.expect(keyEql(parseKeyStr("shift+x").?, .{ .char = .{ .c = 'x', .ctrl = false, .alt = false } }));
}

test "default viewport and search bindings" {
    const b = Bindings.default();
    try t.expect(b.matches(.page_up, .scroll_page_up));
    try t.expect(b.matches(.page_down, .scroll_page_down));
    try t.expect(b.matches(.ctrl_home, .scroll_top));
    try t.expect(b.matches(.ctrl_end, .scroll_bottom));
    try t.expect(b.matches(.ctrl_up, .prompt_previous));
    try t.expect(b.matches(.ctrl_shift_up, .prompt_previous));
    try t.expect(b.matches(.ctrl_down, .prompt_next));
    try t.expect(b.matches(.ctrl_shift_down, .prompt_next));
    try t.expect(b.matches(.{ .char = .{ .c = 'f', .ctrl = true, .alt = false, .shift = true } }, .search));
    try t.expect(!b.matches(.{ .char = .{ .c = 'f', .ctrl = true, .alt = false } }, .search));
    try t.expect(b.matches(.enter, .search_next));
    try t.expect(b.matches(.{ .char = .{ .c = 'g', .ctrl = true, .alt = false } }, .search_next));
    try t.expect(b.matches(.shift_enter, .search_previous));
    try t.expect(b.matches(.{ .char = .{ .c = 'g', .ctrl = true, .alt = false, .shift = true } }, .search_previous));
    try t.expect(b.matches(.escape, .search_close));
    // No default keys for half-page and line scrolling.
    try t.expect(!b.matches(.up, .scroll_line_up));
    try t.expect(!b.matches(.page_up, .scroll_half_page_up));
}

test "keyLabel and keyTitle" {
    const alloc = std.heap.page_allocator;
    const label = try keyLabel(alloc, parseKeyStr("ctrl+shift+f").?);
    defer alloc.free(label);
    try t.expectEqualStrings("ctrl+shift+f", label);
    const up = try keyLabel(alloc, .ctrl_shift_up);
    defer alloc.free(up);
    try t.expectEqualStrings("ctrl+shift+up", up);
    // pi's display form capitalizes every part.
    const title = try keyTitle(alloc, .shift_enter);
    defer alloc.free(title);
    try t.expectEqualStrings("Shift+Enter", title);
    const g = try keyTitle(alloc, parseKeyStr("ctrl+g").?);
    defer alloc.free(g);
    try t.expectEqualStrings("Ctrl+G", g);
    const enter = try keyTitle(alloc, .enter);
    defer alloc.free(enter);
    try t.expectEqualStrings("Enter", enter);
}

test "applyJson overrides" {
    var b = Bindings.default();
    try b.applyJson(
        \\{ "submit": "ctrl+s", "newline": ["alt+enter", "ctrl+j"], "unknown_action": "x", "submit_bad": "nope" }
    );
    // submit rebound
    try t.expect(b.matches(.{ .char = .{ .c = 's', .ctrl = true, .alt = false } }, .submit));
    try t.expect(!b.matches(.enter, .submit));
    // newline: defaults replaced by the array (alt+enter + ctrl+j)
    try t.expect(b.matches(.{ .char = .{ .c = '\r', .ctrl = false, .alt = true } }, .newline));
    try t.expect(b.matches(.{ .char = .{ .c = 'j', .ctrl = true, .alt = false } }, .newline));
    try t.expect(!b.matches(.shift_enter, .newline));
}
