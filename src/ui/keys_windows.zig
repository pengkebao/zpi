//! Windows console input → terminal byte stream (Phase 1).
//!
//! The POSIX path reads raw tty bytes (termios raw mode) and `parseKey`
//! decodes them. On Windows there is no tty byte stream: `ReadConsoleA`
//! returns structured `INPUT_RECORD`s. This bridge converts them into the
//! SAME byte encodings the terminal would have produced (CSI arrows, SGR
//! mouse, \r for Enter, ESC for Alt), so `parseKey` is unchanged.
//!
//! Input modes: raw console mode (no line buffering/echo) is set by
//! terminal.zig before reads; `ENABLE_VIRTUAL_TERMINAL_INPUT` is NOT set,
//! so we get classic KEY/MOUSE/WINDOW_BUFFER_SIZE events.

const std = @import("std");
const windows = std.os.windows;
const keys = @import("keys.zig");

// 0.17's std.os.windows has no INPUT_RECORD; define the minimum (wincon.h
// layout, ANSI variant of ReadConsoleA).
const COORD = extern struct {
    X: i16,
    Y: i16,
};
const CHAR_INFO = extern struct {
    UnicodeChar: u16,
    Attributes: u16,
};
const KEY_EVENT = extern struct {
    bKeyDown: c_int,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union {
        AsciiChar: u8,
        UnicodeChar: u16,
    },
    dwControlKeyState: u32,
};
const MOUSE_EVENT = extern struct {
    dwMousePosition: COORD,
    dwButtonState: u32,
    dwControlKeyState: u32,
    dwEventFlags: u32,
};
const WINDOW_BUFFER_SIZE_EVENT = extern struct {
    dwSizeX: u16,
    dwSizeY: u16,
};
const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT,
        MouseEvent: MOUSE_EVENT,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_EVENT,
        MenuEvent: extern struct {
            dwCommandId: u32,
        },
        FocusEvent: extern struct {
            bSetFocus: c_int,
        },
    },
};

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetNumberOfConsoleInputEvents(hInputHandle: windows.HANDLE, lpNumberOfEvents: *u32) callconv(.winapi) c_int;
// ReadConsoleInputW reads structured INPUT_RECORDs (keyboard/mouse/resize).
// NOTE: ReadConsoleA/W read a flat CHAR/WCHAR byte stream — using it with an
// INPUT_RECORD buffer is a layout mismatch that corrupts every event.
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: windows.HANDLE, lpBuffer: *INPUT_RECORD, nNumberOfInputsToRead: u32, lpNumberOfInputsRead: *u32) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;

// Virtual key codes (winuser.h).
const VK_BACK: u16 = 0x08;
const VK_TAB: u16 = 0x09;
const VK_RETURN: u16 = 0x0D;
const VK_ESCAPE: u16 = 0x1B;
const VK_SPACE: u16 = 0x20;
const VK_PRIOR: u16 = 0x21; // PgUp
const VK_NEXT: u16 = 0x22; // PgDn
const VK_END: u16 = 0x23;
const VK_HOME: u16 = 0x24;
const VK_LEFT: u16 = 0x25;
const VK_UP: u16 = 0x26;
const VK_RIGHT: u16 = 0x27;
const VK_DOWN: u16 = 0x28;

/// Convert one INPUT_RECORD into terminal-style bytes. Returns the number of
/// bytes written (0 = event ignored, e.g. focus/menu).
const KEY_EVENT_TYPE: u16 = 1;
const MOUSE_EVENT_TYPE: u16 = 2;
const WINDOW_BUFFER_SIZE_EVENT_TYPE: u16 = 4;
const FOCUS_EVENT_TYPE: u16 = 8;
const MENU_EVENT_TYPE: u16 = 16;

const KEY_EVENTF_KEYUP: u32 = 0x0002;
const LEFT_ALT_PRESSED: u32 = 0x0001;
const RIGHT_ALT_PRESSED: u32 = 0x0002;
const LEFT_CTRL_PRESSED: u32 = 0x0008;
const RIGHT_CTRL_PRESSED: u32 = 0x0010;

// Mouse event flags (wincon.h MOUSE_EVENT_RECORD.dwEventFlags): the console
// API has NO press/release flag — button transitions are inferred by
// diffing dwButtonState against the previous event's state.
const MOUSE_MOVED: u32 = 0x0001;
const MOUSE_WHEEL: u32 = 0x0004;
const MOUSE_HWHEEL: u32 = 0x0100;

/// Left/middle/right held on the previous mouse event (button 0/1/2, 3 =
/// none) — the console API reports no explicit press/release events.
var last_btn: u8 = 3;

fn eventToBytes(rec: *const INPUT_RECORD, out: []u8) usize {
    return switch (rec.EventType) {
        KEY_EVENT_TYPE => {
            const ke = rec.Event.KeyEvent;
            if (ke.dwControlKeyState & KEY_EVENTF_KEYUP != 0) return 0; // key-up: ignore (no release events in tty streams)
            const vk = ke.wVirtualKeyCode;
            const ascii = ke.uChar.AsciiChar;
            const ctrl = ke.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0;
            const alt = ke.dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED) != 0;
            const is_printable = ascii >= 0x20 and ascii < 0x7F and (vk == 0 or vk == ascii or vk == 0xE0);

            // Ctrl+letter: the tty byte is (letter - 'a' + 1) & 0x1f.
            if (ctrl and ascii >= 'A' and ascii <= 'Z') {
                if (out.len < 1) return 0;
                out[0] = (ascii - 'a' + 1) & 0x1F;
                return 1;
            }
            // Ctrl+space / Ctrl+backslash etc. arrive with control codes in
            // AsciiChar already; pass through.
            if (ctrl and ascii != 0) {
                if (out.len < 1) return 0;
                out[0] = ascii & 0x1F;
                return 1;
            }
            // Alt+letter: ESC prefix (tty alt encoding).
            if (alt and is_printable) {
                if (out.len < 2) return 0;
                out[0] = 0x1B;
                out[1] = ascii;
                return 2;
            }
            // Named keys → CSI/SS3 sequences.
            if (!is_printable) {
                const seq: []const u8 = switch (vk) {
                    VK_RETURN => "\r",
                    VK_BACK => "\x7f",
                    VK_TAB => "\t",
                    VK_ESCAPE => "\x1b",
                    VK_SPACE => " ",
                    VK_UP => "\x1b[A",
                    VK_DOWN => "\x1b[B",
                    VK_RIGHT => "\x1b[C",
                    VK_LEFT => "\x1b[D",
                    VK_HOME => "\x1b[H",
                    VK_END => "\x1b[F",
                    VK_PRIOR => "\x1b[5~",
                    VK_NEXT => "\x1b[6~",
                    0x70...0x7B => seq: {
                        // F1..F12: 1~, 2~, 3~, 11~..14~ (xterm numbering).
                        const idx: u8 = @intCast(vk - 0x70);
                        const num: []const u8 = if (idx < 3) switch (idx) {
                            0 => "1",
                            1 => "2",
                            else => "3",
                        } else switch (idx) {
                            3 => "11",
                            4 => "12",
                            5 => "13",
                            else => "14",
                        };
                        var b: [8]u8 = undefined;
                        break :seq std.fmt.bufPrint(&b, "\x1b[{s}~", .{num}) catch "";
                    },
                    else => "",
                };
                if (seq.len == 0 or seq.len > out.len) return 0;
                @memcpy(out[0..seq.len], seq);
                return seq.len;
            }
            if (out.len < 1) return 0;
            out[0] = ascii;
            return 1;
        },
        MOUSE_EVENT_TYPE => {
            const me = rec.Event.MouseEvent;
            const action: u32 = me.dwEventFlags;
            var code: u8 = 0; // press/motion
            var btn: u8 = 3; // none
            if (action & (MOUSE_WHEEL | MOUSE_HWHEEL) != 0) {
                // Wheel: SGR button code 64|direction (0=up, 1=down). The
                // signed delta lives in the HIGH word of dwButtonState;
                // negative = scroll down.
                const delta = @as(i16, @intCast(me.dwButtonState >> 16));
                code = 64;
                btn = if (delta < 0) 1 else 0;
            } else if (action & MOUSE_MOVED != 0) {
                const now_btn: u8 = switch (me.dwButtonState & 0x0007) {
                    0x0001 => 0, // LEFT
                    0x0002 => 1, // MIDDLE
                    0x0004 => 2, // RIGHT
                    else => 3,
                };
                if (now_btn != last_btn) {
                    // State changed: a button went down or up (the console
                    // API has no explicit press/release events).
                    if (now_btn != 3 and last_btn == 3) {
                        code = 0; // press
                        btn = now_btn;
                    } else {
                        code = 1; // release
                        btn = if (now_btn != 3) now_btn else last_btn;
                    }
                } else {
                    // No state change: plain motion. SGR motion bit 32 while
                    // a button is held (drag); hover (no button) is 32|3.
                    code = 32;
                    btn = now_btn;
                }
                last_btn = now_btn;
            } else {
                return 0;
            }
            var b: [24]u8 = undefined;
            // SGR terminators: 'M' = press/motion, 'm' = release.
            const term = if (code == 1) "m" else "M";
            // SGR cells are 1-based; the console API's dwMousePosition is
            // 0-based (parseSgrMouse subtracts 1, so add it back here).
            const s = std.fmt.bufPrint(&b, "\x1b[<{};{};{}{s}", .{ code | btn, me.dwMousePosition.X + 1, me.dwMousePosition.Y + 1, term }) catch return 0;
            if (s.len > out.len) return 0;
            @memcpy(out[0..s.len], s);
            return s.len;
        },
        WINDOW_BUFFER_SIZE_EVENT_TYPE => {
            // The run loop polls the flag; set it via the shared atomic.
            keys.winchFlag().store(true, .release);
            return 0;
        },
        else => return 0,
    };
}

/// Wait for console input, never blocking longer than `poll_ms`; convert to
/// terminal bytes in `buf`. Returns bytes read (0 = timeout/no data).
pub fn readInputBytes(buf: []u8, poll_ms: u32) usize {
    const h = GetStdHandle(STD_INPUT_HANDLE);
    var count: u32 = 0;
    if (GetNumberOfConsoleInputEvents(h, &count) == 0) return 0;
    if (count == 0) {
        Sleep(poll_ms);
        return 0;
    }
    var records: [64]INPUT_RECORD = undefined;
    const want = @min(count, @as(u32, 64));
    var got: u32 = 0;
    if (ReadConsoleInputW(h, &records[0], want, &got) == 0) return 0;
    var out_len: usize = 0;
    for (records[0..got]) |*rec| {
        if (out_len >= buf.len) break;
        out_len += eventToBytes(rec, buf[out_len..]);
    }
    return out_len;
}

/// Timed read for the input watcher (the POSIX VMIN=0/VTIME=1 equivalent):
/// wait up to `timeout_ms` for input, 0 bytes on timeout.
pub fn timedRead(buf: []u8, timeout_ms: u32) usize {
    var waited: u32 = 0;
    while (waited < timeout_ms) {
        const n = readInputBytes(buf, 10);
        if (n > 0) return n;
        waited += 10;
    }
    return 0;
}

/// Blocking-ish drain used by teardown: read whatever is pending (no sleep).
pub fn drainInput(buf: []u8) usize {
    const h = GetStdHandle(STD_INPUT_HANDLE);
    var count: u32 = 0;
    if (GetNumberOfConsoleInputEvents(h, &count) == 0) return 0;
    if (count == 0) return 0;
    var records: [64]INPUT_RECORD = undefined;
    var got: u32 = 0;
    if (ReadConsoleInputW(h, &records[0], @min(count, 64), &got) == 0) return 0;
    var out_len: usize = 0;
    for (records[0..got]) |*rec| {
        if (out_len >= buf.len) break;
        out_len += eventToBytes(rec, buf[out_len..]);
    }
    return out_len;
}
