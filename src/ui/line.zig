//! Line-mode interactive REPL.
//! Uses raw POSIX read() for stdin to handle TTY correctly.

const std = @import("std");
const agent = @import("../core/agent.zig");

/// Read a single line from stdin using POSIX read().
/// Returns null on EOF.
fn readLinePosix(alloc: std.mem.Allocator) ?[]u8 {
    var line_buf = std.array_list.Managed(u8).init(alloc);
    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(0, &byte_buf) catch {
            line_buf.deinit();
            return null;
        };
        if (n == 0) {
            line_buf.deinit();
            return null; // EOF
        }
        const c = byte_buf[0];
        if (c == '\n' or c == '\r') break;
        line_buf.append(c) catch {
            line_buf.deinit();
            return null;
        };
    }
    return line_buf.toOwnedSlice() catch null;
}

pub fn repl(io: std.Io, alloc: std.mem.Allocator, session: *agent.Session) !void {
    std.debug.print("rpi-zig interactive mode (line UI)\n", .{});
    std.debug.print("Type a message and press Enter. /exit to quit, /help for commands.\n", .{});
    std.debug.print("────────────────────────────────────────\n", .{});
    _ = io;

    while (true) {
        std.debug.print("\nYou> ", .{});

        const line = readLinePosix(alloc) orelse {
            std.debug.print("\nbye\n", .{});
            return;
        };
        defer alloc.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) break;
        if (std.mem.eql(u8, trimmed, "/help")) {
            std.debug.print("  /exit     quit\n  /help     show this help\n  /clear    clear conversation history\n", .{});
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/clear")) {
            for (session.context.messages.items) |*m| m.deinit();
            session.context.messages.clearRetainingCapacity();
            std.debug.print("(history cleared)\n", .{});
            continue;
        }

        std.debug.print("Assistant> ", .{});
        session.runPrompt(trimmed) catch |e| {
            std.debug.print("\n[error: {s}]\n", .{@errorName(e)});
        };
        std.debug.print("\n", .{});
    }

    std.debug.print("\nbye\n", .{});
}
