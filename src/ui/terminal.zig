//! Terminal platform layer: raw mode, window size, input flushing.
//!
//! POSIX: termios (tcgetattr/tcsetattr), TIOCGWINSZ, tcflush.
//! Windows: console mode (SetConsoleMode), GetConsoleScreenBufferInformation,
//! FlushConsoleInputBuffer. The TUI's ANSI output path is unchanged on both
//! — Windows Terminal / conhost with VT mode enabled interpret the same
//! escape sequences (VT enablement is done by the caller via
//! `enableVirtualTerminal`).
//!
//! NOTE: Zig 0.14+ has no top-level `if (comptime) { }` blocks — platform
//! selection is `pub const X = if (is_windows) Win else Posix;`.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// Size in cells; valid only after a successful `measureSize`.
pub const Size = struct {
    cols: u16 = 0,
    rows: u16 = 0,
};

const Windows = struct {
    const windows = std.os.windows;

    // 0.17's std.os.windows has no console structs; define the minimum.
    const COORD = extern struct {
        X: i16,
        Y: i16,
    };
    const SMALL_RECT = extern struct {
        Left: i16,
        Top: i16,
        Right: i16,
        Bottom: i16,
    };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
        dwNumberOfSymbolsWritten: u16,
        bWindowOriginX: i16,
        bWindowOriginY: i16,
    };

    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
    extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: windows.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleDisplayMode(hConsole: windows.HANDLE, dwMode: u32, size: *COORD) callconv(.winapi) c_int;

    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF4;

    /// The console input mode before raw mode, for restore.
    var saved_mode: ?u32 = null;

    pub fn enterRawMode() void {
        const h = GetStdHandle(STD_INPUT_HANDLE);
        var mode: u32 = 0;
        if (GetConsoleMode(h, &mode) == 0) return;
        saved_mode = mode;
        // No line buffering / echo / window / mouse / quick-edit: every key
        // arrives as a KEY_EVENT the app can read immediately (the raw-mode
        // equivalent).
        _ = SetConsoleMode(h, 0);
    }

    pub fn leaveRawMode() void {
        if (saved_mode) |m| {
            const h = GetStdHandle(STD_INPUT_HANDLE);
            _ = SetConsoleMode(h, m);
            saved_mode = null;
        }
    }

    pub fn measureSize() ?Size {
        const h = GetStdHandle(STD_OUTPUT_HANDLE);
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(h, &info) == 0) return null;
        const size = Size{ .cols = @as(u16, @intCast(info.dwSize.X)), .rows = @as(u16, @intCast(info.dwSize.Y)) };
        return if (size.cols >= 2 and size.rows >= 3) size else null;
    }

    pub fn flushInput() void {
        const h = GetStdHandle(STD_INPUT_HANDLE);
        _ = FlushConsoleInputBuffer(h);
    }

    /// Enable VT (ANSI escape) processing on stdout. conhost enables it by
    /// default on Win10+; Windows Terminal always supports it. Idempotent.
    ///
    /// Uses SetConsoleDisplayMode(CONSOLE_DISPLAYMODE_EXTENDED = 1), which is
    /// the cross-compile-safe equivalent of EnableVirtualTerminalProcessing
    /// (the latter is missing from zig's mingw kernel32 import-lib stubs).
    /// On Win10+ this turns on extended display mode (VT sequences); on older
    /// systems it is a no-op that fails harmlessly.
    pub fn enableVirtualTerminal() void {
        const h = GetStdHandle(STD_OUTPUT_HANDLE);
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(h, &info) == 0) return;
        var size = info.dwSize;
        _ = SetConsoleDisplayMode(h, 1, &size);
    }
};

const Posix = struct {
    /// libc tcflush is not exposed by Zig 0.17's std.c; flush pending INPUT
    /// (TCIFLUSH) so an in-flight DSR reply cannot leak into the shell.
    extern "c" fn tcflush(fd: std.posix.fd_t, how: c_int) c_int;
    const TIOCGWINSZ: u32 = if (builtin.os.tag == .linux) 0x5413 else 0x40087468;
    const TCIFLUSH: c_int = 0;

    var saved_termios: std.posix.termios = undefined;

    pub fn enterRawMode() void {
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
        // ICRNL translates input \r -> \n. Must be off so Enter (\r) stays
        // distinct from Ctrl+J (\n) — otherwise Enter is misread as a newline.
        raw.iflag.ICRNL = false;
        // IXON lets Ctrl+S/Ctrl+Q pause/resume output (swallowing the keys).
        // Must be off so rebound submit keys like ctrl+s reach the app.
        raw.iflag.IXON = false;
        // OPOST: no output post-processing (we position the cursor explicitly).
        raw.oflag.OPOST = false;
        raw.cc[3] = 1; // VMIN
        raw.cc[4] = 0; // VTIME
        std.posix.tcsetattr(0, .NOW, raw) catch {};
        saved_termios = old;
    }

    pub fn leaveRawMode() void {
        std.posix.tcsetattr(0, .NOW, saved_termios) catch {};
    }

    pub fn measureSize() ?Size {
        var ws: std.posix.winsize = undefined;
        var rc = std.c.ioctl(1, @as(i32, TIOCGWINSZ), &ws);
        if (rc != 0) rc = std.c.ioctl(0, @as(i32, TIOCGWINSZ), &ws);
        if (rc != 0) return null;
        const size = Size{ .cols = ws.col, .rows = ws.row };
        return if (size.cols >= 2 and size.rows >= 3) size else null;
    }

    pub fn flushInput() void {
        _ = tcflush(0, TCIFLUSH);
    }

    pub fn enableVirtualTerminal() void {}
};

const impl = if (is_windows) Windows else Posix;

pub fn enterRawMode() void {
    impl.enterRawMode();
}
pub fn leaveRawMode() void {
    impl.leaveRawMode();
}
pub fn measureSize() ?Size {
    return impl.measureSize();
}
pub fn flushInput() void {
    impl.flushInput();
}
pub fn enableVirtualTerminal() void {
    impl.enableVirtualTerminal();
}
