//! System clipboard access via command-line tools (pi utils/clipboard.js +
//! clipboard-image.js, but zero-dependency: OS tools instead of a native
//! module).
//!
//! Image reading:
//! - macOS: `osascript -e 'the clipboard as «class PNGf»'` prints
//!   `«data PNGf<hex>»`; we decode the hex into PNG bytes. Screenshot tools
//!   (Cmd+Shift+4, WeChat/QQ snips) put PNG data on the clipboard.
//! - Linux (best effort): `xclip -t image/png -o` / `wl-paste --type image/png`.
//!
//! Text reading:
//! - macOS `pbpaste`; Linux `xclip -o` / `wl-paste`.
//!
//! No terminal protocol involved — pi likewise reads the OS clipboard, then
//! hands the model a file path it can Read (the read tool attaches images).

const std = @import("std");
const shell = @import("../tools/shell.zig");

pub const ImageData = struct {
    bytes: []u8, // owned by alloc
    mime: []const u8,
};

/// Read raw bytes from a shell command line's stdout (sh -c form: shell.exec
/// always appends `command`, so wrapping through sh -c avoids an empty tail
/// argument that osascript/xclip would reject). Returns null on failure.
fn runCapture(alloc: std.mem.Allocator, io: std.Io, cmd_line: []const u8, timeout_s: f64, out: *std.array_list.Managed(u8)) bool {
    const res = shell.exec(alloc, io, .{ .shell = "/bin/sh", .args = &.{"-c"} }, cmd_line, .{
        .timeout = timeout_s,
    }, out) catch return false;
    return !res.aborted and !res.timed_out;
}

/// Decode `«data PNGf<hex>»` payload (everything after the class name up to
/// the closing guillemet) into bytes. Returns null unless the text contains
/// a data literal whose hex decodes to a plausible image.
pub fn decodeOsascriptData(alloc: std.mem.Allocator, text: []const u8) ?[]u8 {
    // Find "PNGf" (or TIFF etc.) inside a «data XXX<hex>» literal.
    const marker = std.mem.indexOf(u8, text, "«data ") orelse return null;
    var start = marker + "«data ".len;
    // Skip the 4-char Mac OSType class name (letters only, e.g. PNGf,
    // TIFF, utxt) — hex digits must not be consumed.
    while (start < text.len and std.ascii.isAlphabetic(text[start])) : (start += 1) {}
    var end = start;
    // The osascript literal ends with » (UTF-8 C2 BB) — terminate at the
    // first non-hex byte instead of comparing the multi-byte char.
    while (end < text.len and std.ascii.isHex(text[end])) : (end += 1) {}
    const hex = text[start..end];
    if (hex.len < 16 or hex.len % 2 != 0) return null;
    const bytes = alloc.alloc(u8, hex.len / 2) catch return null;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch {
            alloc.free(bytes);
            return null;
        };
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch {
            alloc.free(bytes);
            return null;
        };
        bytes[i] = (hi << 4) | lo;
    }
    errdefer alloc.free(bytes);
    // Sanity: PNG signature or JPEG SOI.
    const is_png = bytes.len >= 8 and bytes[0] == 0x89 and std.mem.eql(u8, bytes[1..4], "PNG");
    const is_jpeg = bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8;
    if (!is_png and !is_jpeg) {
        alloc.free(bytes);
        return null;
    }
    return bytes;
}

/// Read an image from the system clipboard (macOS PNGf via osascript; Linux
/// xclip/wl-paste). Returns null when the clipboard holds no supported image.
pub fn readClipboardImage(alloc: std.mem.Allocator, io: std.Io) ?ImageData {
    var raw = std.array_list.Managed(u8).init(alloc);
    defer raw.deinit();

    if (@import("builtin").os.tag == .macos) {
        if (runCapture(alloc, io, "osascript -e 'the clipboard as «class PNGf»'", 3, &raw)) {
            if (decodeOsascriptData(alloc, raw.items)) |bytes| {
                return .{ .bytes = bytes, .mime = "image/png" };
            }
        }
    } else {
        // Linux best effort: Wayland then X11.
        if (runCapture(alloc, io, "wl-paste --type image/png --no-newline", 2, &raw)) {
            if (raw.items.len > 8 and raw.items[0] == 0x89 and std.mem.eql(u8, raw.items[1..4], "PNG")) {
                const bytes = alloc.dupe(u8, raw.items) catch return null;
                return .{ .bytes = bytes, .mime = "image/png" };
            }
        }
        raw.clearRetainingCapacity();
        if (runCapture(alloc, io, "xclip -selection clipboard -t image/png -o", 2, &raw)) {
            if (raw.items.len > 8 and raw.items[0] == 0x89 and std.mem.eql(u8, raw.items[1..4], "PNG")) {
                const bytes = alloc.dupe(u8, raw.items) catch return null;
                return .{ .bytes = bytes, .mime = "image/png" };
            }
        }
    }
    return null;
}

/// Read plain text from the system clipboard (macOS pbpaste; Linux
/// xclip/wl-paste). Returns null when empty/unavailable. Owned by alloc.
pub fn readClipboardText(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    var raw = std.array_list.Managed(u8).init(alloc);
    errdefer raw.deinit();
    const cmd_line: []const u8 = if (@import("builtin").os.tag == .macos)
        "pbpaste"
    else if (@import("builtin").os.tag == .linux)
        "xclip -selection clipboard -o"
    else
        return null;
    if (!runCapture(alloc, io, cmd_line, 2, &raw)) {
        raw.deinit();
        return null;
    }
    const trimmed = std.mem.trim(u8, raw.items, " \t\r\n");
    if (trimmed.len == 0) {
        raw.deinit();
        return null;
    }
    return raw.toOwnedSlice() catch null;
}

/// pi handleClipboardPaste: write clipboard image bytes to a temp file and
/// return the path (owned). The model Reads the path (read tool attaches
/// images), matching pi's "images are attached via temporary files" flow.
pub fn writeImageTempFile(alloc: std.mem.Allocator, io: std.Io, data: ImageData, ext: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(alloc, "/tmp/rpi-clipboard-{d}.{s}", .{ std.Io.Timestamp.now(io, .real).nanoseconds, ext }) catch return null;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data.bytes }) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

test "decodeOsascriptData decodes hex payload" {
    const a = std.testing.allocator;
    // PNG signature in hex inside the osascript data literal.
    const lit = "«data PNGf89504E470D0A1A0A000000» trailing";
    const bytes = decodeOsascriptData(a, lit) orelse return error.TestUnexpectedResult;
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 11), bytes.len);
    try std.testing.expect(bytes[0] == 0x89);
    try std.testing.expectEqualStrings("PNG", bytes[1..4]);
    // garbage → null
    try std.testing.expect(decodeOsascriptData(a, "«data PNGfzzzz»") == null);
    try std.testing.expect(decodeOsascriptData(a, "no literal here") == null);
}
