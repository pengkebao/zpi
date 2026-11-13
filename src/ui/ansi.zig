//! ANSI escape sequence helpers.

const std = @import("std");

pub const ESC: []const u8 = "\x1b";
pub const RESET: []const u8 = "\x1b[0m";
pub const BOLD: []const u8 = "\x1b[1m";
pub const DIM: []const u8 = "\x1b[2m";
pub const ITALIC: []const u8 = "\x1b[3m";
pub const UNDERLINE: []const u8 = "\x1b[4m";
pub const HIDE_CURSOR: []const u8 = "\x1b[?25l";
pub const SHOW_CURSOR: []const u8 = "\x1b[?25h";
pub const CLEAR_SCREEN: []const u8 = "\x1b[2J\x1b[H";
pub const CLEAR_EOL: []const u8 = "\x1b[K";
pub const CLEAR_EOS: []const u8 = "\x1b[J";
/// CSI r — reset the scrolling region to the full screen (DECSTBM reset).
pub const RESET_SCROLL_REGION: []const u8 = "\x1b[r";
/// ESC M — reverse index: with the cursor at a region's top row the region
/// scrolls down one row (VT100). Universal terminal support.
pub const REVERSE_INDEX: []const u8 = "\x1bM";

/// Write a moveTo sequence to the given buffer, returns length written.
pub fn moveTo(buf: []u8, row: u16, col: u16) usize {
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col }) catch return 0;
    return out.len;
}

/// CSI Ps;Ps r — DECSTBM: set the scrolling region (1-based, inclusive rows).
/// Setting/resetting it homes the cursor; callers reposition afterwards.
pub fn setScrollRegion(buf: []u8, top: u16, bottom: u16) usize {
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}r", .{ top, bottom }) catch return 0;
    return out.len;
}

/// Write a moveUp sequence to the given buffer.
pub fn moveUp(buf: []u8, n: u16) usize {
    const out = std.fmt.bufPrint(buf, "\x1b[{d}A", .{n}) catch return 0;
    return out.len;
}

/// Write a moveDown sequence to the given buffer.
pub fn moveDown(buf: []u8, n: u16) usize {
    const out = std.fmt.bufPrint(buf, "\x1b[{d}B", .{n}) catch return 0;
    return out.len;
}
