//! Key parsing for the TUI (Phase G).
//!
//! Splits into a pure, testable `parseKey` (bytes → Key) and an I/O `readKey`
//! that collects a full byte sequence from the terminal (handling ESC
//! sequences with a short timeout for standalone Escape).
//!
//! Supports: printable chars, special keys, arrow/home/end/pgup/pgdn, F1-F12,
//! Ctrl/Alt combinations, and both CSI (`ESC [`) and SS3 (`ESC O`) sequences.

const std = @import("std");
const builtin = @import("builtin");

// termios cc[] indices (differ by platform).
pub const CC_VMIN: usize = if (builtin.os.tag == .linux) 6 else 16;
pub const CC_VTIME: usize = if (builtin.os.tag == .linux) 5 else 17;

/// A 0-based screen cell reported by a mouse event.
pub const MouseCell = struct {
    col: u16,
    row: u16,
};

// ---- SIGWINCH (terminal resize) ----

/// Set by the signal handler (one atomic store: async-signal-safe),
/// consumed by KeyReader.fill after every poll. Module-level because signal
/// handlers carry no context.
var sigwinch_flag = std.atomic.Value(bool).init(false);

/// The disposition SIGWINCH had before installWinchHandler, for restore.
var old_winch_action: ?std.posix.Sigaction = null;

fn onWinchSignal(_: std.posix.SIG) callconv(.c) void {
    sigwinch_flag.store(true, .release);
}

/// Deliver SIGWINCH to `onWinchSignal` (pi: process.stdout.on("resize")).
/// Idempotent: setupTerminal runs again after the external editor.
pub fn installWinchHandler() void {
    if (old_winch_action != null) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onWinchSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.WINCH, &act, &old);
    old_winch_action = old;
}

/// Put SIGWINCH back the way the process found it.
pub fn restoreWinchHandler() void {
    const old = old_winch_action orelse return;
    std.posix.sigaction(std.posix.SIG.WINCH, &old, null);
    old_winch_action = null;
    sigwinch_flag.store(false, .release);
}

/// A parsed key event.
pub const Key = union(enum) {
    escape,
    enter,
    shift_enter,
    tab,
    shift_tab,
    space,
    backspace,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    /// The terminal was resized (SIGWINCH); the caller re-measures and does
    /// a full repaint. Never produced by parseKey, only by nextKey.
    resize,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    /// Terminal mouse wheel (SGR encoding, button bit 64; low bits 0=up,
    /// 1=down). `alt` scrolls faster (pi: ALT_WHEEL_SCROLL_MULTIPLIER).
    wheel: struct {
        down: bool,
        alt: bool,
    },
    /// A left-button mouse press at a 0-based screen cell (SGR encoding):
    /// the "Jump to latest message" label, the scrollbar, the search buttons.
    mouse_click: MouseCell,
    /// Pointer motion with the left button held (scrollbar dragging).
    mouse_drag: MouseCell,
    /// Pointer motion with no button held (hover; needs all-motion tracking).
    mouse_move: MouseCell,
    /// The left button was released.
    mouse_release: MouseCell,
    /// The terminal window gained / lost focus (mode 1004).
    focus_in,
    focus_out,
    /// Ctrl+End (jump to latest message) / Ctrl+Home.
    ctrl_end,
    ctrl_home,
    /// Ctrl+Up/Down, optionally with Shift (jump between user messages).
    ctrl_up,
    ctrl_down,
    ctrl_shift_up,
    ctrl_shift_down,
    /// Alt+Up / Alt+Down: restore a queued follow-up message (pi:
    /// app.message.dequeue); alt+down is unused but parses for symmetry.
    alt_up,
    alt_down,
    /// A typed character with optional modifiers. For plain letters, ctrl/alt
    /// are false and `c` is the character. For ctrl+letter, ctrl is true and
    /// `c` is the lowercase letter. For alt+letter, alt is true. `shift` is
    /// only reported together with ctrl (ctrl+shift+f), where the terminal's
    /// keyboard protocol can tell the two apart.
    char: struct {
        c: u8,
        ctrl: bool,
        alt: bool,
        shift: bool = false,
    },
    /// A multi-byte UTF-8 character (CJK, emoji, etc.). `bytes` holds up to 4
    /// bytes, `len` is the number of valid bytes. Carries the raw UTF-8 so the
    /// editor can insert it byte-for-byte.
    text: struct {
        bytes: [4]u8,
        len: u8,
    },
    unknown,
};

/// Number of bytes in a UTF-8 sequence given its leading byte (0xC0..0xF7).
fn utf8Len(lead: u8) usize {
    return if (lead < 0xE0) 2
    else if (lead < 0xF0) 3
    else 4;
}

/// Canonical string for a key (for keybinding matching + display).
/// Writes into `buf`; returns the used slice, or null if it doesn't fit.
pub fn keyToString(key: Key, buf: []u8) ?[]const u8 {
    if (key == .text) {
        const t = key.text;
        if (buf.len < t.len) return null;
        @memcpy(buf[0..t.len], t.bytes[0..t.len]);
        return buf[0..t.len];
    }
    if (key != .char) {
        const name = @tagName(key);
        if (buf.len < name.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const ch = key.char;
    if (ch.ctrl and ch.alt) {
        const s = std.fmt.bufPrint(buf, "ctrl+alt+{c}", .{ch.c}) catch return null;
        return s;
    }
    if (ch.ctrl) {
        const s = std.fmt.bufPrint(buf, "ctrl+{c}", .{ch.c}) catch return null;
        return s;
    }
    if (ch.alt) {
        const s = std.fmt.bufPrint(buf, "alt+{c}", .{ch.c}) catch return null;
        return s;
    }
    if (buf.len < 1) return null;
    buf[0] = ch.c;
    return buf[0..1];
}

/// A decoded SGR mouse event (`ESC [ < button ; col ; row M|m`). `col`/`row`
/// are 0-based screen cells (the terminal sends them 1-based).
pub const SgrMouse = struct {
    button: usize,
    col: u16,
    row: u16,
    release: bool,
};

/// Parse one complete SGR mouse sequence. Returns null for anything that is
/// not exactly `ESC [ < <button> ; <col> ; <row> M|m`.
pub fn parseSgrMouse(data: []const u8) ?SgrMouse {
    if (data.len < 9 or !std.mem.startsWith(u8, data, "\x1b[<")) return null;
    const last = data[data.len - 1];
    if (last != 'M' and last != 'm') return null;
    const body = data[3 .. data.len - 1];
    var it = std.mem.splitScalar(u8, body, ';');
    const button = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return null;
    const col = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return null;
    const row = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return null;
    if (it.next() != null) return null; // extra fields: not an SGR mouse event
    return .{
        .button = button,
        .col = col -| 1,
        .row = row -| 1,
        .release = last == 'm',
    };
}

/// Parse a complete key byte sequence into a Key. Returns null if unrecognized.
pub fn parseKey(data: []const u8) ?Key {
    if (data.len == 0) return null;
    const b = data[0];
    if (b != 27) {
        // Multi-byte UTF-8 leading byte: consume the full sequence.
        if (b >= 0xC0) {
            const expected = utf8Len(b);
            if (data.len < expected) return null;
            var t: [4]u8 = undefined;
            @memcpy(t[0..expected], data[0..expected]);
            return .{ .text = .{ .bytes = t, .len = @intCast(expected) } };
        }
        return parseSingleByte(b);
    }

    // SGR mouse: ESC [ < button ; col ; row M|m (0-based cells are returned).
    // Button bits: the low two are the button (3 = none), 4 shift, 8 alt,
    // 16 ctrl, 32 motion, 64 wheel.
    if (std.mem.startsWith(u8, data, "\x1b[<")) {
        const m = parseSgrMouse(data) orelse return null;
        const cell: MouseCell = .{ .col = m.col, .row = m.row };
        if (m.button & 64 != 0) {
            // Wheel: the low bits give the direction (0=up, 1=down).
            const alt = m.button & 8 != 0;
            return switch (m.button & 3) {
                0 => .{ .wheel = .{ .down = false, .alt = alt } },
                1 => .{ .wheel = .{ .down = true, .alt = alt } },
                else => null,
            };
        }
        const button = m.button & 3;
        // pi: release wins over motion, motion over press.
        if (m.release) return if (button == 0) .{ .mouse_release = cell } else null;
        if (m.button & 32 != 0) {
            // Motion: a drag with the left button held, a hover with none.
            if (button == 0) return .{ .mouse_drag = cell };
            if (button == 3) return .{ .mouse_move = cell };
            return null;
        }
        if (button != 0) return null; // middle/right buttons are not used
        return .{ .mouse_click = cell };
    }
    if (data.len == 1) return .escape;
    const b1 = data[1];
    if (b1 == '[') return parseCsi(data[2..], false);
    if (b1 == 'O') return parseCsi(data[2..], true);
    // ESC ESC
    if (b1 == 27) return .{ .char = .{ .c = '[', .ctrl = true, .alt = true } };
    // Specific keys first (before the ctrl range, which would swallow them).
    if (b1 == 13) return .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } }; // alt+enter
    if (b1 == 127 or b1 == 8) return .{ .char = .{ .c = ' ', .ctrl = false, .alt = true } }; // alt+backspace
    // ESC + ctrl+letter (1..=26) = ctrl+alt+letter.
    if (b1 >= 1 and b1 <= 26) return .{ .char = .{ .c = b1 + 96, .ctrl = true, .alt = true } };
    // ESC + printable = alt+letter.
    if (b1 >= 32 and b1 < 127) return .{ .char = .{ .c = b1, .ctrl = false, .alt = true } };
    return .escape;
}

fn parseSingleByte(b: u8) ?Key {
    switch (b) {
        9 => return .tab,
        13 => return .enter, // \r = Enter (submit)
        10 => return .shift_enter, // \n = Ctrl+J / Shift+Enter (newline)
        127, 8 => return .backspace,
        32 => return .space,
        else => {},
    }
    // Ctrl+letter: bytes 1..=26 map to a..z (checked after the named keys above,
    // which overlap the range — e.g. \r=13 is enter, not ctrl+m).
    if (b >= 1 and b <= 26) return .{ .char = .{ .c = b + 96, .ctrl = true, .alt = false } };
    if (b >= 32 and b < 127) return .{ .char = .{ .c = b, .ctrl = false, .alt = false } };
    return null;
}

/// Kitty CSI-u body: `<codepoint>[:<shifted>[:<base>]];<mod>[:<event>]`.
const KittyU = struct {
    codepoint: usize,
    shifted: ?usize,
    mod: usize, // 1-indexed bitmask: 1=none, 2=shift, 3=shift+alt, 4=alt, 5=shift+ctrl, ...
    event: u8, // 1=press, 2=repeat, 3=release (1 when absent)
};

/// Parse the body of a Kitty keyboard-protocol CSI-u sequence (without the
/// leading `ESC [` and trailing `u`).
fn parseKittyU(body: []const u8) ?KittyU {
    const semi = std.mem.lastIndexOfScalar(u8, body, ';') orelse {
        const cp = std.fmt.parseInt(usize, body, 10) catch return null;
        return .{ .codepoint = cp, .shifted = null, .mod = 1, .event = 1 };
    };
    const cp_part = body[0..semi];
    const mod_part = body[semi + 1 ..];
    // mod: digits before the first ':'; the digits after it are the event type.
    const colon_mod = std.mem.indexOfScalar(u8, mod_part, ':') orelse mod_part.len;
    const mod = std.fmt.parseInt(usize, mod_part[0..colon_mod], 10) catch 1;
    var event: u8 = 1;
    if (colon_mod < mod_part.len) {
        const ev = std.fmt.parseInt(u8, mod_part[colon_mod + 1 ..], 10) catch 1;
        if (ev >= 1 and ev <= 3) event = ev;
    }
    // codepoint: digits before the first ':' in cp_part.
    const colon_cp = std.mem.indexOfScalar(u8, cp_part, ':') orelse cp_part.len;
    const codepoint = std.fmt.parseInt(usize, cp_part[0..colon_cp], 10) catch return null;
    // shifted: digits after the first ':' up to the next ':' (or end).
    var shifted: ?usize = null;
    if (colon_cp < cp_part.len) {
        const rest = cp_part[colon_cp + 1 ..];
        const colon2 = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        if (colon2 > 0) shifted = std.fmt.parseInt(usize, rest[0..colon2], 10) catch null;
    }
    return .{ .codepoint = codepoint, .shifted = shifted, .mod = mod, .event = event };
}

/// Encode a Unicode codepoint into UTF-8. Returns the byte count, or 0 if invalid.
fn encodeUtf8(cp: usize, buf: *[4]u8) usize {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else if (cp < 0x110000) {
        buf[0] = @intCast(0xF0 | (cp >> 18));
        buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
    return 0;
}

/// Up/Down with Ctrl (and optionally Shift) are their own keys (jump between
/// user messages); every other modifier combination is the plain arrow.
fn verticalArrow(up: bool, ctrl: bool, shift: bool, alt: bool) Key {
    if (alt and !ctrl) return if (up) .alt_up else .alt_down;
    if (ctrl) {
        if (up) return if (shift) .ctrl_shift_up else .ctrl_up;
        return if (shift) .ctrl_shift_down else .ctrl_down;
    }
    return if (up) .up else .down;
}

/// Parse the body of a CSI (`ESC [`) or SS3 (`ESC O`) sequence.
fn parseCsi(params: []const u8, ss3: bool) ?Key {
    if (params.len == 0) return null;
    const final = params[params.len - 1];

    if (ss3) {
        // SS3: a single final byte.
        return switch (params[0]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => null,
        };
    }

    // Kitty keyboard protocol: CSI <codepoint>[:<shifted>[:<base>]];<mod>[:<event>] u.
    // With flag 2 (report event types) every reported key also has a release
    // event (event=3), which must be dropped (pi filters these in the TUI loop).
    if (final == 'u') {
        const body = params[0 .. params.len - 1];
        const k = parseKittyU(body) orelse return null;
        if (k.event == 3) return null; // key release
        // modifier is 0-indexed: shift=1, alt=2, ctrl=4, super=8 (k.mod is 1-indexed).
        const modifier = k.mod - 1;
        const is_shift = modifier & 1 != 0;
        const is_alt = modifier & 2 != 0;
        const is_ctrl = modifier & 4 != 0;
        // Enter (13) / KP_Enter (57414): shift → newline, else submit.
        // alt → alt+enter (steering follow-up submit; pi: app.message.followUp).
        if (k.codepoint == 13 or k.codepoint == 57414) {
            if (is_alt) return .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } };
            return if (is_shift) .shift_enter else .enter;
        }
        if (k.codepoint == 27) return .escape;
        // Kitty functional keys (PUA): pi's KITTY_FUNCTIONAL_KEY_EQUIVALENTS.
        switch (k.codepoint) {
            57417 => return .left,
            57418 => return .right,
            57419 => return verticalArrow(true, is_ctrl, is_shift, is_alt),
            57420 => return verticalArrow(false, is_ctrl, is_shift, is_alt),
            57421 => return .page_up,
            57422 => return .page_down,
            57423 => return if (is_ctrl) .ctrl_home else .home,
            57424 => return if (is_ctrl) .ctrl_end else .end,
            57425 => return .insert,
            57426 => return .delete,
            else => {},
        }
        if (k.codepoint == 9) return .tab;
        if (k.codepoint == 32) return .space;
        if (k.codepoint == 127) return .backspace;
        // Ctrl+letter reported as a control-char codepoint (1..26) with ctrl.
        if (is_ctrl and k.codepoint >= 1 and k.codepoint <= 26) {
            return .{ .char = .{ .c = @intCast(k.codepoint + 96), .ctrl = true, .alt = is_alt, .shift = is_shift } };
        }
        // Printable character (>= 32, outside the functional PUA range 57344-63743).
        var cp = k.codepoint;
        if (is_shift) {
            if (k.shifted) |s| cp = s;
        }
        // Ctrl/Alt combos for ASCII keys (pi: formatKeyNameWithModifiers).
        if ((is_ctrl or is_alt) and cp < 128) {
            const c: u8 = @intCast(cp);
            if (is_ctrl) {
                if (c >= 'a' and c <= 'z') return .{ .char = .{ .c = c, .ctrl = true, .alt = is_alt, .shift = is_shift } };
                if (c >= 'A' and c <= 'Z') return .{ .char = .{ .c = c + 32, .ctrl = true, .alt = is_alt, .shift = is_shift } };
            }
            if (is_alt) return .{ .char = .{ .c = c, .ctrl = false, .alt = true } };
        }
        if (cp >= 32 and cp < 57344) {
            var t: [4]u8 = undefined;
            const n = encodeUtf8(cp, &t);
            if (n == 0) return null;
            return .{ .text = .{ .bytes = t, .len = @intCast(n) } };
        }
        return null;
    }

    // CSI with a `~` terminator: numeric code + ~.
    if (final == '~') {
        const body = params[0 .. params.len - 1];
        // xterm modifyOtherKeys: CSI 27 ; <mods> ; <keycode> ~
        if (std.mem.startsWith(u8, body, "27;")) {
            var it = std.mem.splitScalar(u8, body, ';');
            _ = it.next(); // 27
            const mods = std.fmt.parseInt(usize, it.next() orelse "1", 10) catch 1;
            const key = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
            if (key == 13) return if (mods & 2 != 0) .shift_enter else .enter;
            // Ctrl+letter: the only way a legacy terminal can tell ctrl+f
            // from ctrl+shift+f. `mods` is 1 + (shift=1 | alt=2 | ctrl=4).
            const modifier = mods -| 1;
            if (modifier & 4 != 0 and key < 128) {
                const c: u8 = @intCast(key);
                const shift = modifier & 1 != 0;
                const alt = modifier & 2 != 0;
                if (c >= 'a' and c <= 'z') return .{ .char = .{ .c = c, .ctrl = true, .alt = alt, .shift = shift } };
                if (c >= 'A' and c <= 'Z') return .{ .char = .{ .c = c + 32, .ctrl = true, .alt = alt, .shift = shift } };
            }
            return null;
        }
        const code = std.fmt.parseInt(usize, body, 10) catch return null;
        return switch (code) {
            1 => .home,
            2 => .insert,
            3 => .delete,
            4 => .end,
            5 => .page_up,
            6 => .page_down,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => null,
        };
    }

    // Cursor keys with a modifier: CSI 1 ; <mod>[:<event>] <final>
    // (e.g. Ctrl+End = ESC [ 1 ; 5 F). The modifier is 1-indexed:
    // shift=1, alt=2, ctrl=4. Kitty release events (`:3`) are dropped.
    if (params.len >= 3 and std.mem.startsWith(u8, params, "1;")) {
        const mod_part = params[2 .. params.len - 1];
        const colon = std.mem.indexOfScalar(u8, mod_part, ':') orelse mod_part.len;
        if (colon + 1 < mod_part.len and mod_part[colon + 1] == '3') return null;
        const mod = std.fmt.parseInt(usize, mod_part[0..colon], 10) catch 1;
        const modifier = mod -| 1;
        const is_ctrl = modifier & 4 != 0;
        const is_shift = modifier & 1 != 0;
        return switch (final) {
            'A' => verticalArrow(true, is_ctrl, is_shift, false),
            'B' => verticalArrow(false, is_ctrl, is_shift, false),
            'C' => .right,
            'D' => .left,
            'H' => if (is_ctrl) .ctrl_home else .home,
            'F' => if (is_ctrl) .ctrl_end else .end,
            else => null,
        };
    }

    // Simple CSI: a single final letter (no intermediate params).
    if (params.len == 1) {
        return switch (params[0]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'I' => .focus_in, // mode 1004: the terminal window gained focus
            'O' => .focus_out,
            'Z' => .shift_tab,
            else => null,
        };
    }
    return null;
}

/// Length of the first complete input sequence in `buf`, or null if more bytes
/// are needed. A sequence is one keypress: a single byte, one complete UTF-8
/// character, or one ESC-prefixed escape sequence. Lone ESC needs a timeout
/// (handled by KeyReader).
pub fn seqLenAt(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const b = buf[0];
    if (b != 27) {
        if (b >= 0xC0) {
            const need = utf8Len(b);
            return if (buf.len >= need) need else null;
        }
        return 1;
    }
    if (buf.len < 2) return null; // lone ESC so far
    const b1 = buf[1];
    if (b1 == 'O') return if (buf.len >= 3) 3 else null; // SS3
    if (b1 == '[') {
        // CSI: scan for the final byte (0x40..0x7E); params are all < 0x40.
        var i: usize = 2;
        while (i < buf.len) : (i += 1) {
            const c = buf[i];
            if (c >= 0x40 and c <= 0x7E) return i + 1;
        }
        return null;
    }
    return 2; // ESC ESC or alt+byte
}

/// Does this raw sequence look like a Kitty key-release event (event type 3)?
/// Mirrors pi's isKeyRelease. With event types enabled every reported key also
/// produces a release event which must not be processed as a press.
pub fn isReleaseSeq(seq: []const u8) bool {
    const suffixes = [_][]const u8{ ":3u", ":3~", ":3A", ":3B", ":3C", ":3D", ":3H", ":3F", ":3P", ":3Q", ":3S" };
    for (suffixes) |s| {
        if (std.mem.indexOf(u8, seq, s) != null) return true;
    }
    return false;
}

/// If `seq` is a Kitty protocol flags reply (`ESC [ ? <flags> u`), return the
/// flags value. This is the reply to the `ESC [ ? u` query.
pub fn parseKittyFlagsReply(seq: []const u8) ?usize {
    if (seq.len < 5) return null;
    if (seq[0] != 27 or seq[1] != '[' or seq[2] != '?' or seq[seq.len - 1] != 'u') return null;
    const digits = seq[3 .. seq.len - 1];
    if (digits.len == 0) return null;
    for (digits) |d| {
        if (d < '0' or d > '9') return null;
    }
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// Is `seq` a device-attributes reply (`ESC [ ? <attrs> c`)? Sent by terminals
/// in response to DA1; a DA reply without a flags reply means no Kitty support.
pub fn isDeviceAttributesReply(seq: []const u8) bool {
    if (seq.len < 5) return false;
    if (seq[0] != 27 or seq[1] != '[' or seq[2] != '?' or seq[seq.len - 1] != 'c') return false;
    for (seq[3 .. seq.len - 1]) |d| {
        if (!((d >= '0' and d <= '9') or d == ';')) return false;
    }
    return true;
}

/// Parse one complete raw input sequence, honoring the kitty-protocol state
/// for the ambiguous legacy sequences (pi's `_kittyProtocolActive` checks).
/// NOTE (deliberate pi deviation): `\n` (Ctrl+J) is ALWAYS a newline here —
/// on terminals without Kitty/shift+enter support it is the only way to
/// insert a line break. pi maps `\n` to enter when Kitty is inactive.
pub fn parseSequence(seq: []const u8, kitty_active: bool) ?Key {
    if (seq.len == 1 and seq[0] == '\n') {
        return .shift_enter; // Ctrl+J / terminal shift+enter mapping: newline
    }
    if (seq.len == 2 and seq[0] == 27 and seq[1] == '\r') {
        // Dual-mode: with the kitty protocol negotiated, alt+enter arrives
        // as CSI 13;3u (handled in parseCsi), so a bare ESC CR here is
        // shift+enter (search "previous"); without kitty, terminals send
        // ESC CR for alt+enter and \n / CSI 13;2u for shift+enter.
        if (kitty_active) return .shift_enter;
        return .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } };
    }
    if (std.mem.eql(u8, seq, "\x1bOM")) return .enter; // numpad enter
    return parseKey(seq);
}

/// Stateful key reader for the TUI input loop.
///
/// Terminal input arrives in batches (kitty press+release pairs, IME commits,
/// negotiation replies), so bytes are accumulated in `pending` and split into
/// individual sequences before parsing — mirroring pi's StdinBuffer. Release
/// events and negotiation replies are dropped here, never surfaced as keys.
pub const KeyReader = struct {
    // Large pending: mouse-wheel floods (trackpad inertia) arrive faster than
    // the UI can redraw; overflow would tear sequences mid-stream.
    pending: [4096]u8 = undefined,
    pending_len: usize = 0,
    /// Whether the Kitty protocol is known-active (flags reply != 0). Legacy
    /// mappings (`\n`, `ESC CR`) depend on this.
    kitty_active: bool = false,
    /// Set when a flags reply was consumed; the TUI polls and clears it to
    /// finish negotiation (enabling modifyOtherKeys when flags == 0).
    flags_reply: ?usize = null,
    /// Set when a DA1 reply was consumed without a flags reply (no Kitty).
    da_reply: bool = false,
    /// True right after a negotiation reply was consumed; nextKey returns
    /// immediately so the caller can act on flags_reply/da_reply without
    /// waiting for a keypress.
    consumed_reply: bool = false,
    /// When set, the blocking read becomes a 100 ms poll and nextKey returns
    /// `.unknown` while nothing arrived, so the caller can run timers (the
    /// transient scrollbar's hide deadline). Set only while a deadline is
    /// pending; otherwise the loop polls at 100 ms anyway to catch the
    /// SIGWINCH flag (a resize must not wait for a keypress).
    poll: bool = false,

    // 33 ms: poll is also the wakeup for timer-ish work (the scrollbar's
    // hide deadline, throttled wheel-render flushes), so the tail frame of a
    // scroll burst lands within one poll instead of three.
    const FILL_POLL_MS: i32 = 33;
    const FillResult = enum { data, timeout, eof, signal };

    /// Read the next key from `fd` (terminal in raw mode). Blocks until a key
    /// is available. Drops release events and negotiation replies.
    pub fn nextKey(self: *KeyReader, fd: std.posix.fd_t, io: std.Io) !Key {
        _ = io;
        while (true) {
            if (self.pending_len > 0) {
                if (seqLenAt(self.pending[0..self.pending_len])) |len| {
                    if (self.take(len)) |k| return k;
                    // Release events are skipped silently; negotiation replies
                    // return immediately so the caller can finish negotiation.
                    if (self.consumed_reply) {
                        self.consumed_reply = false;
                        return .unknown;
                    }
                    continue;
                }
                // Incomplete sequence at head: read more with a short timeout.
                switch (self.fill(fd, true)) {
                    .data => continue,
                    .timeout => {
                        if (self.pending_len == 1 and self.pending[0] == 27) {
                            self.pending_len = 0;
                            return .escape; // standalone Escape
                        }
                        self.pending_len = 0; // corrupt fragment: drop
                        return .unknown;
                    },
                    .eof => return error.EndOfStream,
                    .signal => return .resize,
                }
            }
            switch (self.fill(fd, self.poll)) {
                .data => {},
                .eof => return error.EndOfStream,
                .timeout => {
                    // Only surface timeouts when the caller wants to run
                    // timers; otherwise keep waiting (the SIGWINCH flag is
                    // checked inside fill).
                    if (self.poll) return .unknown;
                    continue;
                },
                .signal => return .resize,
            }
        }
    }

    /// Extract the first `len` bytes as one sequence and parse it. Returns null
    /// when the sequence should be silently skipped (release/reply).
    fn take(self: *KeyReader, len: usize) ?Key {
        const data = self.pending[0..len];
        defer {
            const rest = self.pending_len - len;
            std.mem.copyForwards(u8, self.pending[0..rest], self.pending[len..self.pending_len]);
            self.pending_len = rest;
        }
        if (parseKittyFlagsReply(data)) |flags| {
            self.flags_reply = flags;
            self.kitty_active = flags != 0;
            self.consumed_reply = true;
            return null;
        }
        if (isDeviceAttributesReply(data)) {
            self.da_reply = true;
            self.consumed_reply = true;
            return null;
        }
        if (isReleaseSeq(data)) return null;
        return parseSequence(data, self.kitty_active) orelse .unknown;
    }

    /// Wait for input on `fd`, never blocking longer than FILL_POLL_MS. The
    /// old VMIN=0/VTIME=1 tcsetattr dance is replaced by poll(): it cannot
    /// miss the SIGWINCH flag and doesn't touch the shared termios while a
    /// timed read is in flight. A set SIGWINCH flag wins over input so the
    /// next frame uses the new size (pi: the resize handler requestRender()s,
    /// and the render reads the live size).
    fn fill(self: *KeyReader, fd: std.posix.fd_t, timed: bool) FillResult {
        _ = timed;
        if (sigwinch_flag.swap(false, .acq_rel)) return .signal;
        var fds: [1]std.posix.pollfd = .{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, FILL_POLL_MS) catch return .eof;
        if (ready == 0) {
            // The handler may have fired while poll was sleeping.
            if (sigwinch_flag.swap(false, .acq_rel)) return .signal;
            return .timeout;
        }
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            // Read once so a real EOF is distinguished from a transient error.
            var buf: [128]u8 = undefined;
            const got = std.posix.read(fd, &buf) catch return .eof;
            if (got == 0) return .eof;
            if (self.pending_len + got > self.pending.len) return .timeout;
            @memcpy(self.pending[self.pending_len..][0..got], buf[0..got]);
            self.pending_len += got;
            return .data;
        }
        if (fds[0].revents & std.posix.POLL.IN == 0) return .timeout;
        var buf: [128]u8 = undefined;
        const got = std.posix.read(fd, &buf) catch return .eof;
        if (got == 0) return .eof;
        if (self.pending_len + got > self.pending.len) return .timeout; // overflow guard
        @memcpy(self.pending[self.pending_len..][0..got], buf[0..got]);
        self.pending_len += got;
        return .data;
    }
};

fn expectKey(actual: ?Key, expected: Key) !void {
    try std.testing.expectEqual(expected, actual.?);
}

test "parseKey single byte" {
    const a: Key = .{ .char = .{ .c = 'a', .ctrl = false, .alt = false } };
    try expectKey(parseKey("a"), a);
    try expectKey(parseKey(" "), .space);
    try expectKey(parseKey("\r"), .enter);
    try expectKey(parseKey("\n"), .shift_enter); // Ctrl+J / Shift+Enter
    try expectKey(parseKey("\x1b[13u"), .enter); // Kitty Enter
    try expectKey(parseKey("\x1b[13;2u"), .shift_enter); // Kitty Shift+Enter
    try expectKey(parseKey("\x1b[27;2;13~"), .shift_enter); // modifyOtherKeys Shift+Enter
    try expectKey(parseKey("\x1b[27;1;13~"), .enter); // modifyOtherKeys Enter
    try expectKey(parseKey("\t"), .tab);
    try expectKey(parseKey("\x7f"), .backspace);
    try expectKey(parseKey("\x1b"), .escape);
    const cc: Key = .{ .char = .{ .c = 'c', .ctrl = true, .alt = false } };
    const cd: Key = .{ .char = .{ .c = 'd', .ctrl = true, .alt = false } };
    const cz: Key = .{ .char = .{ .c = 'z', .ctrl = true, .alt = false } };
    try expectKey(parseKey("\x03"), cc);
    try expectKey(parseKey("\x04"), cd);
    try expectKey(parseKey("\x1a"), cz);
}

test "parseKey arrow and navigation" {
    try std.testing.expect(parseKey("\x1b[A").? == .up);
    try std.testing.expect(parseKey("\x1b[B").? == .down);
    try std.testing.expect(parseKey("\x1b[C").? == .right);
    try std.testing.expect(parseKey("\x1b[D").? == .left);
    try std.testing.expect(parseKey("\x1b[H").? == .home);
    try std.testing.expect(parseKey("\x1b[F").? == .end);
    try std.testing.expect(parseKey("\x1b[3~").? == .delete);
    try std.testing.expect(parseKey("\x1b[5~").? == .page_up);
    try std.testing.expect(parseKey("\x1b[6~").? == .page_down);
    try std.testing.expect(parseKey("\x1b[Z").? == .shift_tab);
    // SS3 variants.
    try std.testing.expect(parseKey("\x1bOH").? == .home);
    try std.testing.expect(parseKey("\x1bOF").? == .end);
}

test "parseKey function keys" {
    try std.testing.expect(parseKey("\x1b[11~").? == .f1);
    try std.testing.expect(parseKey("\x1b[12~").? == .f2);
    try std.testing.expect(parseKey("\x1b[24~").? == .f12);
}

test "parseKey alt combinations" {
    const alt_a: Key = .{ .char = .{ .c = 'a', .ctrl = false, .alt = true } };
    const alt_bs: Key = .{ .char = .{ .c = ' ', .ctrl = false, .alt = true } };
    const alt_enter: Key = .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } };
    try expectKey(parseKey("\x1ba"), alt_a);
    try expectKey(parseKey("\x1b\x7f"), alt_bs);
    try expectKey(parseKey("\x1b\r"), alt_enter);
}

test "parseKey SGR mouse wheel and buttons" {
    // Wheel: bit 64, low bits 0 (up) / 1 (down); bit 8 is the Alt modifier.
    try expectKey(parseKey("\x1b[<64;10;5M"), .{ .wheel = .{ .down = false, .alt = false } });
    try expectKey(parseKey("\x1b[<65;1;1M"), .{ .wheel = .{ .down = true, .alt = false } });
    try expectKey(parseKey("\x1b[<72;3;3M"), .{ .wheel = .{ .down = false, .alt = true } });
    try expectKey(parseKey("\x1b[<68;3;3M"), .{ .wheel = .{ .down = false, .alt = false } }); // shift+wheel
    try std.testing.expect(parseKey("\x1b[<66;3;3M") == null); // horizontal wheel
    // Left-button press → click with 0-based coordinates.
    try expectKey(parseKey("\x1b[<0;32;12M"), .{ .mouse_click = .{ .col = 31, .row = 11 } });
    // Its release, a drag (motion with the button held), a hover (no button).
    try expectKey(parseKey("\x1b[<0;32;12m"), .{ .mouse_release = .{ .col = 31, .row = 11 } });
    try expectKey(parseKey("\x1b[<32;40;9M"), .{ .mouse_drag = .{ .col = 39, .row = 8 } });
    try expectKey(parseKey("\x1b[<35;7;2M"), .{ .mouse_move = .{ .col = 6, .row = 1 } });
    // Other buttons are not keys, pressed, dragged or released.
    try std.testing.expect(parseKey("\x1b[<1;32;12M") == null);
    try std.testing.expect(parseKey("\x1b[<2;32;12M") == null);
    try std.testing.expect(parseKey("\x1b[<34;32;12M") == null);
    try std.testing.expect(parseKey("\x1b[<2;32;12m") == null);
    // Coordinates clamp at the origin instead of wrapping.
    try expectKey(parseKey("\x1b[<0;1;1M"), .{ .mouse_click = .{ .col = 0, .row = 0 } });
}

test "parseKey ctrl+shift letters and ctrl arrows" {
    const csf: Key = .{ .char = .{ .c = 'f', .ctrl = true, .alt = false, .shift = true } };
    const cf: Key = .{ .char = .{ .c = 'f', .ctrl = true, .alt = false } };
    // Kitty: ctrl+shift+f, with and without the shifted codepoint.
    try expectKey(parseKey("\x1b[102;6u"), csf);
    try expectKey(parseKey("\x1b[102:70;6u"), csf);
    try expectKey(parseKey("\x1b[102;5u"), cf); // plain ctrl+f stays distinct
    // xterm modifyOtherKeys.
    try expectKey(parseKey("\x1b[27;6;70~"), csf);
    try expectKey(parseKey("\x1b[27;6;102~"), csf);
    try expectKey(parseKey("\x1b[27;5;102~"), cf);
    // Legacy ctrl+f carries no shift information.
    try expectKey(parseKey("\x06"), cf);

    // Ctrl (and Ctrl+Shift) with Up/Down are their own keys.
    try expectKey(parseKey("\x1b[1;5A"), .ctrl_up);
    try expectKey(parseKey("\x1b[1;5B"), .ctrl_down);
    try expectKey(parseKey("\x1b[1;6A"), .ctrl_shift_up);
    try expectKey(parseKey("\x1b[1;6B"), .ctrl_shift_down);
    try expectKey(parseKey("\x1b[57419;5u"), .ctrl_up);
    try expectKey(parseKey("\x1b[57420;6u"), .ctrl_shift_down);
    // Other modifiers stay the plain arrow; left/right ignore them.
    try expectKey(parseKey("\x1b[1;2A"), .up);
    try expectKey(parseKey("\x1b[1;3B"), .down);
    try expectKey(parseKey("\x1b[1;5C"), .right);
    try expectKey(parseKey("\x1b[1;5D"), .left);
    // Ctrl+Home/End, also with Shift held.
    try expectKey(parseKey("\x1b[1;5H"), .ctrl_home);
    try expectKey(parseKey("\x1b[1;5F"), .ctrl_end);
    try expectKey(parseKey("\x1b[1;6F"), .ctrl_end);
    try expectKey(parseKey("\x1b[1;2H"), .home);
    // Kitty release events of these keys are dropped.
    try std.testing.expect(parseKey("\x1b[1;5:3A") == null);
}

test "parseKey focus events" {
    try expectKey(parseKey("\x1b[I"), .focus_in);
    try expectKey(parseKey("\x1b[O"), .focus_out);
    try std.testing.expectEqual(@as(?usize, 3), seqLenAt("\x1b[O\x1b[I"));
}

test "parseKey CJK multi-byte" {
    // 中 = E4 B8 AD (3 bytes).
    const k = parseKey("\xE4\xB8\xAD") orelse return error.Failed;
    if (k != .text) return error.Failed;
    const t = k.text;
    try std.testing.expectEqual(@as(u8, 3), t.len);
    try std.testing.expectEqual(@as(u8, 0xE4), t.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xB8), t.bytes[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), t.bytes[2]);
    // Incomplete sequence → null.
    try std.testing.expect(parseKey("\xE4\xB8") == null);
    // 4-byte emoji 🚀 = F0 9F 9A 80.
    const e = parseKey("\xF0\x9F\x9A\x80") orelse return error.Failed;
    if (e != .text) return error.Failed;
    try std.testing.expectEqual(@as(u8, 4), e.text.len);
}

test "keyToString" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("up", keyToString(.up, &buf).?);
    try std.testing.expectEqualStrings("ctrl+c", keyToString(.{ .char = .{ .c = 'c', .ctrl = true, .alt = false } }, &buf).?);
    try std.testing.expectEqualStrings("a", keyToString(.{ .char = .{ .c = 'a', .ctrl = false, .alt = false } }, &buf).?);
    try std.testing.expectEqualStrings("alt+a", keyToString(.{ .char = .{ .c = 'a', .ctrl = false, .alt = true } }, &buf).?);
    try std.testing.expectEqualStrings("escape", keyToString(.escape, &buf).?);
}

test "kitty release events are dropped" {
    // Press + release pair: only the press parses; release → null.
    try std.testing.expect(parseKey("\x1b[13;2:1u") != null); // press
    try std.testing.expect(parseKey("\x1b[13;2:3u") == null); // release
    try std.testing.expect(parseKey("\x1b[97;1:3u") == null); // release of 'a'
    try std.testing.expect(isReleaseSeq("\x1b[13;2:3u"));
    try std.testing.expect(isReleaseSeq("\x1b[1;1:3A"));
    try std.testing.expect(!isReleaseSeq("\x1b[13;2:1u"));
    try std.testing.expect(!isReleaseSeq("hello"));
}

test "kitty repeat events parse as presses" {
    // Plain letter repeat (no modifiers) is text.
    const k = parseKey("\x1b[97;1:2u") orelse return error.Failed;
    if (k != .text) return error.Failed;
    try std.testing.expectEqual(@as(u8, 1), k.text.len);
    try std.testing.expectEqual(@as(u8, 'a'), k.text.bytes[0]);
}

test "kitty CSI-u escape key" {
    try expectKey(parseKey("\x1b[27u"), .escape);
}

test "kitty alt+letter via CSI-u" {
    const alt_a: Key = .{ .char = .{ .c = 'a', .ctrl = false, .alt = true } };
    try expectKey(parseKey("\x1b[97;3u"), alt_a);
}

test "parseSequence legacy mappings depend on kitty state" {
    // \n (Ctrl+J) is ALWAYS a newline (deliberate pi deviation: on terminals
    // without shift+enter support it is the only newline key).
    try expectKey(parseSequence("\n", true), .shift_enter);
    try expectKey(parseSequence("\n", false), .shift_enter);
    // ESC CR: shift+enter when kitty active (alt+enter comes as CSI 13;3u
    // then), alt+enter otherwise (steering follow-up submit).
    try expectKey(parseSequence("\x1b\r", true), .shift_enter);
    const alt_enter: Key = .{ .char = .{ .c = '\r', .ctrl = false, .alt = true } };
    try expectKey(parseSequence("\x1b\r", false), alt_enter);
    // Kitty shift+enter (CSI 13;2u) and alt+enter (CSI 13;3u): plain CSI
    // routes through parseKey — but parseSequence's ESC CR check does not
    // see these (they carry the full CSI form, not the legacy pair).
    try expectKey(parseSequence("\x1b[13;2u", true), .shift_enter);
    try expectKey(parseSequence("\x1b[13;3u", true), alt_enter);
    // Numpad enter is always enter.
    try expectKey(parseSequence("\x1bOM", true), .enter);
    try expectKey(parseSequence("\x1bOM", false), .enter);
}

test "negotiation reply detection" {
    try std.testing.expectEqual(@as(?usize, 7), parseKittyFlagsReply("\x1b[?7u"));
    try std.testing.expectEqual(@as(?usize, 0), parseKittyFlagsReply("\x1b[?0u"));
    try std.testing.expect(parseKittyFlagsReply("\x1b[13u") == null);
    try std.testing.expect(parseKittyFlagsReply("\x1b[?abcu") == null);
    try std.testing.expect(isDeviceAttributesReply("\x1b[?62;1;6c"));
    try std.testing.expect(isDeviceAttributesReply("\x1b[?64;1;2;6;9;15;18;21;22c"));
    try std.testing.expect(!isDeviceAttributesReply("\x1b[13u"));
    try std.testing.expect(!isDeviceAttributesReply("\x1b[?7u"));
}

test "seqLenAt splits batched sequences" {
    try std.testing.expectEqual(@as(?usize, 1), seqLenAt("a\x1b[B"));
    try std.testing.expectEqual(@as(?usize, 3), seqLenAt("\x1b[B你好"));
    try std.testing.expectEqual(@as(?usize, 3), seqLenAt("你好"));
    try std.testing.expectEqual(@as(?usize, 9), seqLenAt("\x1b[13;2:1u\x1b[13;2:3u"));
    try std.testing.expectEqual(@as(?usize, 7), seqLenAt("\x1b[13;2u"));
    try std.testing.expect(seqLenAt("\x1b") == null); // lone ESC: timeout path
    try std.testing.expect(seqLenAt("\x1b[13;2") == null); // incomplete CSI
    try std.testing.expect(seqLenAt("\xE4\xB8") == null); // incomplete UTF-8
    try std.testing.expectEqual(@as(?usize, 2), seqLenAt("\x1ba rest"));
}
