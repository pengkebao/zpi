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

/// True under WSL (interop with the Windows clipboard via powershell.exe).
fn isWsl(environ: std.process.Environ) bool {
    return std.process.Environ.getPosix(environ, "WSL_DISTRO_NAME") != null;
}

/// Run a PowerShell script capturing stdout (windows/WSL). `shell` is
/// "powershell" (native) or "powershell.exe" (WSL interop).
fn runPowerShell(alloc: std.mem.Allocator, io: std.Io, shell_name: []const u8, script: []const u8, out: *std.array_list.Managed(u8)) bool {
    const res = shell.exec(alloc, io, .{ .shell = shell_name, .args = &.{ "-NoProfile", "-Command" } }, script, .{
        .timeout = 5,
    }, out) catch return false;
    return !res.aborted and !res.timed_out;
}

/// Read an image from the system clipboard (macOS PNGf via osascript; native
/// Windows/WSL via PowerShell GetImage; Linux xclip/wl-paste). Returns null
/// when the clipboard holds no supported image.
pub fn readClipboardImage(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ?ImageData {
    var raw = std.array_list.Managed(u8).init(alloc);
    defer raw.deinit();

    switch (@import("builtin").os.tag) {
        .macos => {
            if (runCapture(alloc, io, "osascript -e 'the clipboard as «class PNGf»'", 3, &raw)) {
                if (decodeOsascriptData(alloc, raw.items)) |bytes| {
                    return .{ .bytes = bytes, .mime = "image/png" };
                }
            }
        },
        .windows => {
            // Native Windows: PowerShell saves the clipboard image (if any)
            // to %TEMP%\rpi-clip.png; we read the file back as PNG bytes.
            const temp = std.process.Environ.getPosix(environ, "TEMP") orelse "C:\\Windows\\Temp";
            const win_path = std.fmt.allocPrint(alloc, "{s}\\rpi-clipboard.png", .{temp}) catch return null;
            defer alloc.free(win_path);
            const script = std.fmt.allocPrint(alloc, "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $i = [System.Windows.Forms.Clipboard]::GetImage(); if ($i) {{ $i.Save('{s}', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output ok }} else {{ Write-Output empty }}", .{win_path}) catch return null;
            defer alloc.free(script);
            raw.clearRetainingCapacity();
            if (runPowerShell(alloc, io, "powershell", script, &raw)) {
                if (std.mem.indexOf(u8, raw.items, "ok") != null) {
                    const bytes = std.Io.Dir.cwd().readFileAlloc(io, win_path, alloc, .limited(32 * 1024 * 1024)) catch return null;
                    return .{ .bytes = bytes, .mime = "image/png" };
                }
            }
        },
        else => {
            // Linux: WSL first (Windows screenshots never reach the X11/Wayland
            // clipboard — pi uses the same PowerShell fallback), then Wayland/X11.
            if (isWsl(environ)) {
                const win_path = "C:\\Windows\\Temp\\rpi-clipboard.png";
                const script = "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $i = [System.Windows.Forms.Clipboard]::GetImage(); if ($i) { $i.Save('" ++ win_path ++ "', [System.Drawing.Imaging.ImageFormat]::Png); Write-Output ok } else { Write-Output empty }";
                raw.clearRetainingCapacity();
                if (runPowerShell(alloc, io, "powershell.exe", script, &raw)) {
                    if (std.mem.indexOf(u8, raw.items, "ok") != null) {
                        // Convert the Windows path to its /mnt/... form and read.
                        var conv = std.array_list.Managed(u8).init(alloc);
                        defer conv.deinit();
                        if (runCapture(alloc, io, "wslpath -u '" ++ win_path ++ "'", 2, &conv)) {
                            const wsl_path = std.mem.trim(u8, conv.items, " \t\r\n");
                            if (wsl_path.len > 0) {
                                const bytes = std.Io.Dir.cwd().readFileAlloc(io, wsl_path, alloc, .limited(32 * 1024 * 1024)) catch return null;
                                return .{ .bytes = bytes, .mime = "image/png" };
                            }
                        }
                    }
                }
            }
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
        },
    }
    return null;
}

/// Read plain text from the system clipboard (macOS pbpaste; Windows/WSL
/// PowerShell Get-Clipboard; Linux xclip). Returns null when
/// empty/unavailable. Owned by alloc.
pub fn readClipboardText(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ?[]u8 {
    var raw = std.array_list.Managed(u8).init(alloc);
    errdefer raw.deinit();
    var ok = false;
    switch (@import("builtin").os.tag) {
        .macos => ok = runCapture(alloc, io, "pbpaste", 2, &raw),
        .windows => ok = runPowerShell(alloc, io, "powershell", "Get-Clipboard", &raw),
        .linux => {
            if (isWsl(environ)) ok = runPowerShell(alloc, io, "powershell.exe", "Get-Clipboard", &raw);
            if (!ok) ok = runCapture(alloc, io, "xclip -selection clipboard -o", 2, &raw);
        },
        else => return null,
    }
    if (!ok) {
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
    const dir: []const u8 = if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    const path = std.fmt.allocPrint(alloc, "{s}/rpi-clipboard-{d}.{s}", .{ dir, @as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000))), ext }) catch return null;
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
