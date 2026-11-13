//! Box/Panel component with border and background.
//! Mirrors pi-rust's box_component.rs.

const std = @import("std");
const theme = @import("theme.zig");

pub const Box = struct {
    padding_x: usize,
    padding_y: usize,
    border_color: theme.Color,
    title: ?[]const u8,
    title_color: theme.Color,

    pub fn init(padding_x: usize, padding_y: usize) Box {
        return .{
            .padding_x = padding_x,
            .padding_y = padding_y,
            .border_color = .bright_black,
            .title = null,
            .title_color = .bright_cyan,
        };
    }

    pub fn withBorder(self: *Box, color: theme.Color) void {
        self.border_color = color;
    }

    pub fn withTitle(self: *Box, title: []const u8, color: theme.Color) void {
        self.title = title;
        self.title_color = color;
    }

    /// Render a top border line: ┌─ title ─────────┐
    pub fn renderTop(self: *const Box, width: usize, buf: []u8) ?[]const u8 {
        const border = "\x1b[90m"; // bright black
        const reset = "\x1b[0m";
        if (self.title) |t| {
            const out = std.fmt.bufPrint(buf, "{s}┌{reset} {s}{s} {s}┐{reset}", .{ border, theme.Theme.fg(t, self.title_color), "", border }) catch return null;
            return out;
        }
        const out = std.fmt.bufPrint(buf, "{s}┌{reset}{s}{s}┐{reset}", .{ border, "", border }) catch return null;
        return out;
    }

    /// Render a content line with left/right borders: │ content │
    pub fn renderContent(self: *const Box, content: []const u8, width: usize, buf: []u8) ?[]const u8 {
        const border = "\x1b[90m";
        const reset = "\x1b[0m";
        const pad_left = self.padding_x;
        const pad_right = self.padding_x;
        const content_width = if (width > 2 + pad_left + pad_right) width - 2 - pad_left - pad_right else 0;
        // Truncate content to fit
        var display_content = content;
        if (std.mem.lenAsBytes(display_content) > content_width) {
            display_content = display_content[0..content_width];
        }
        const out = std.fmt.bufPrint(buf, "{s}│{reset} {s}{s}{s}│{reset}", .{ border, "", display_content, border }) catch return null;
        return out;
    }

    /// Render bottom border: └────────────────────┘
    pub fn renderBottom(self: *const Box, width: usize, buf: []u8) ?[]const u8 {
        const border = "\x1b[90m";
        const reset = "\x1b[0m";
        const out = std.fmt.bufPrint(buf, "{s}└{reset}{s}{s}┘{reset}", .{ border, "", border }) catch return null;
        return out;
    }
};
