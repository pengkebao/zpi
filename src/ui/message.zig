//! Message rendering components.

const std = @import("std");
const theme = @import("theme.zig");

/// Render a user message with a subtle background box.
pub fn renderUserMessage(msg: []const u8, buf: []u8) ?[]const u8 {
    const border = "\x1b[90m";
    const reset = "\x1b[0m";
    const accent = "\x1b[96m";
    
    var pos: usize = 0;
    const top = std.fmt.bufPrint(&buf[pos..], "{b}┌{r} {a} You {r}{b}┐{r}\n", .{ .b = border, .r = reset, .a = accent }) catch return null;
    pos += top.len;
    
    const content = std.fmt.bufPrint(&buf[pos..], "  {m}  \n", .{ .m = msg }) catch return null;
    pos += content.len;
    
    const bot = std.fmt.bufPrint(&buf[pos..], "{b}└{r}{b}┘{r}", .{ .b = border, .r = reset }) catch return null;
    pos += bot.len;
    
    return buf[0..pos];
}

/// Render an assistant message.
pub fn renderAssistantMessage(msg: []const u8, buf: []u8) ?[]const u8 {
    const accent = "\x1b[96m";
    const reset = "\x1b[0m";
    
    var pos: usize = 0;
    const header = std.fmt.bufPrint(&buf[pos..], "{a}● Assistant{r}\n", .{ .a = accent, .r = reset }) catch return null;
    pos += header.len;
    
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        const c = std.fmt.bufPrint(&buf[pos..], "  {l}\n", .{ .l = line }) catch return null;
        pos += c.len;
    }
    
    return buf[0..pos];
}

/// Render a tool execution block.
pub fn renderToolCall(name: []const u8, args: []const u8, status: []const u8, result: ?[]const u8, buf: []u8) ?[]const u8 {
    const border = "\x1b[90m";
    const reset = "\x1b[0m";
    const tool_color = "\x1b[95m";
    const success = "\x1b[92m";
    const err_c = "\x1b[91m";
    
    var pos: usize = 0;
    
    const sc = if (std.mem.indexOfScalar(u8, status, '✓') != null) success else err_c;
    const header = std.fmt.bufPrint(&buf[pos..], "{t}⚡ {n}{r} {sc}{s}{r}\n", .{ .t = tool_color, .n = name, .r = reset, .sc = sc, .s = status }) catch return null;
    pos += header.len;
    
    if (args.len > 0) {
        const ad = if (args.len > 80) args[0..80] else args;
        const a = std.fmt.bufPrint(&buf[pos..], "  {b}{ad}{r}\n", .{ .b = border, .ad = ad, .r = reset }) catch return null;
        pos += a.len;
    }
    
    if (result) |r| {
        var line_count: usize = 0;
        var rit = std.mem.splitScalar(u8, r, '\n');
        while (rit.next()) |line| {
            if (line_count >= 5) {
                const more = std.fmt.bufPrint(&buf[pos..], "  {b}...{r}\n", .{ .b = border, .r = reset }) catch return null;
                pos += more.len;
                break;
            }
            if (line.len > 0) {
                const lr = std.fmt.bufPrint(&buf[pos..], "  {b}{l}{r}\n", .{ .b = border, .l = line, .r = reset }) catch return null;
                pos += lr.len;
                line_count += 1;
            }
        }
    }
    
    return buf[0..pos];
}
