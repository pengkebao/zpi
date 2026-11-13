//! Loading spinner component.

const std = @import("std");

pub const SPINNER_FRAMES: [10][]const u8 = .{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

pub const Loader = struct {
    frame: usize = 0,
    running: bool = true,
    text: ?[]const u8 = null,

    pub fn init() Loader {
        return .{};
    }

    pub fn start(self: *Loader) void {
        self.running = true;
        self.frame = 0;
    }

    pub fn stop(self: *Loader) void {
        self.running = false;
    }

    /// Advance the spinner frame (call periodically)
    pub fn tick(self: *Loader) void {
        if (self.running) {
            self.frame = (self.frame + 1) % SPINNER_FRAMES.len;
        }
    }

    /// Render the spinner to a buffer. Returns the rendered length.
    pub fn render(self: *const Loader, buf: []u8) usize {
        if (!self.running) return 0;
        const ch = SPINNER_FRAMES[self.frame];
        if (self.text) |t| {
            const out = std.fmt.bufPrint(buf, "\x1b[96m{s}\x1b[0m {s}", .{ ch, t }) catch return 0;
            return out.len;
        }
        const out = std.fmt.bufPrint(buf, "\x1b[96m{s}\x1b[0m", .{ch}) catch return 0;
        return out.len;
    }
};
