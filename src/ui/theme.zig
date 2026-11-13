//! Theme and color system for TUI.
//! Mirrors pi-rust's theme.rs with ANSI 256-color support.

const std = @import("std");

pub const Color = enum {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    ansi256,

    pub fn sgr(self: Color) []const u8 {
        return switch (self) {
            .default => "0",
            .black => "30",
            .red => "31",
            .green => "32",
            .yellow => "33",
            .blue => "34",
            .magenta => "35",
            .cyan => "36",
            .white => "37",
            .bright_black => "90",
            .bright_red => "91",
            .bright_green => "92",
            .bright_yellow => "93",
            .bright_blue => "94",
            .bright_magenta => "95",
            .bright_cyan => "96",
            .bright_white => "97",
            .ansi256 => "38;5;",
        };
    }
};

/// Theme colors matching pi-rust's dark theme.
pub const Theme = struct {
    text: Color = .bright_white,
    muted: Color = .bright_black,
    dim: Color = .bright_black,
    accent: Color = .bright_cyan,
    error_c: Color = .bright_red,
    success: Color = .bright_green,
    warning: Color = .bright_yellow,
    info: Color = .bright_blue,
    background: Color = .default,
    surface: Color = .ansi256,
    border: Color = .bright_black,
    border_accent: Color = .bright_cyan,
    thinking_text: Color = .bright_black,
    md_heading: Color = .bright_yellow,
    md_code: Color = .bright_magenta,
    md_code_block: Color = .bright_green,
    md_link: Color = .bright_blue,
    md_quote: Color = .bright_black,
    tool_pending_bg: Color = .ansi256,
    tool_success_bg: Color = .ansi256,
    tool_error_bg: Color = .ansi256,
    tool_title: Color = .bright_cyan,
    tool_output: Color = .bright_black,

    /// Format a string with a foreground color.
    pub fn fg(s: []const u8, color: Color) []const u8 {
        return switch (color) {
            .default => s,
            .ansi256 => s, // handled separately
            else => blk: {
                var buf: [s.len + 16]u8 = undefined;
                const sgr = color.sgr();
                const out = std.fmt.bufPrint(&buf, "\x1b[{s}{s}\x1b[0m", .{ sgr, s }) catch return s;
                break :blk out;
            },
        };
    }

    /// Format a string with a 256-color foreground.
    pub fn fg256(s: []const u8, code: u8) []const u8 {
        var buf: [s.len + 20]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "\x1b[38;5;{d}{s}\x1b[0m", .{ code, s }) catch return s;
        return out;
    }
};

/// Current theme instance.
pub const theme = Theme{};
