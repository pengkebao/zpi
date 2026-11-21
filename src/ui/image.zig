//! Inline terminal images (pi terminal-image.js / components/image.js).
//!
//! A tool result that read an image file produces a base64 blob + mime type.
//! When the terminal speaks an image protocol (Kitty graphics on Ghostty/
//! Kitty/WezTerm) and the `showImages` setting is on, the TUI renders the
//! image inline; otherwise it falls back to a one-line `[Image: mime WxH]`
//! indicator (pi getTextOutput/imageFallback).
//!
//! A Kitty image is ONE model line but occupies N visual rows: the encoded
//! sequence is written on a row, the cursor advanced N-1 rows, then moved
//! back up (pi's fullRender image branch). The diff engine must treat that
//! line specially — see tui.zig diffRender.
const std = @import("std");
const mem = std.mem;
const base64 = std.base64;

/// Supported image protocols. `kitty` is the only one zpi encodes (Ghostty,
/// Kitty, WezTerm). tmux strips image protocols, so it is always `none`.
pub const Protocol = enum { none, kitty };

/// Terminal capabilities, cached once (pi getCapabilities).
pub const Caps = struct { images: Protocol };

/// Detect the image protocol from the environment (pi
/// detectCapabilitiesFromEnvironment).
pub fn detect(environ: std.process.Environ) Caps {
    if (std.process.Environ.getPosix(environ, "TMUX") != null) return .{ .images = .none };
    const kitty = std.process.Environ.getPosix(environ, "KITTY_WINDOW_ID") != null;
    const tp_raw = std.process.Environ.getPosix(environ, "TERM_PROGRAM");
    var tp_buf: [64]u8 = undefined;
    const tp: []const u8 = if (tp_raw) |t| blk: {
        if (t.len <= tp_buf.len) {
            _ = std.ascii.lowerString(tp_buf[0..t.len], t);
            break :blk tp_buf[0..t.len];
        }
        break :blk t;
    } else "";
    if (kitty) return .{ .images = .kitty };
    // Ghostty + WezTerm both implement the Kitty graphics protocol.
    if (mem.indexOf(u8, tp, "ghostty") != null or mem.indexOf(u8, tp, "wezterm") != null or
        mem.eql(u8, tp, "kitty"))
    {
        return .{ .images = .kitty };
    }
    return .{ .images = .none };
}

fn be16(p: []const u8) u16 {
    return @as(u16, p[0]) << 8 | p[1];
}
fn be32(p: []const u8) u32 {
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | p[3];
}
fn le16(p: []const u8) u16 {
    return @as(u16, p[0]) | @as(u16, p[1]) << 8;
}
fn le32(p: []const u8) u32 {
    return @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16 | @as(u32, p[3]) << 24;
}

pub const Dims = struct { w: u32, h: u32 };

/// Image pixel dimensions from the raw (DECODED) image bytes (pi
/// getImageDimensions).
pub fn dimensions(raw: []const u8, mime: []const u8) ?Dims {
    if (mem.eql(u8, mime, "image/png")) return pngDims(raw);
    if (mem.eql(u8, mime, "image/jpeg")) return jpegDims(raw);
    if (mem.eql(u8, mime, "image/gif")) return gifDims(raw);
    if (mem.eql(u8, mime, "image/webp")) return webpDims(raw);
    return null;
}

fn pngDims(raw: []const u8) ?Dims {
    // PNG: 8-byte sig, IHDR chunk -> width (BE32 @16), height (BE32 @20).
    if (raw.len < 24) return null;
    if (!mem.eql(u8, raw[0..8], "\x89PNG\r\n\x1a\n")) return null;
    const w = be32(raw[16..20]);
    const h = be32(raw[20..24]);
    return .{ .w = w, .h = h };
}

fn gifDims(raw: []const u8) ?Dims {
    // GIF: 'GIF8' header, logical screen width LE16 @6, height LE16 @8.
    if (raw.len < 10) return null;
    if (!mem.startsWith(u8, raw, "GIF8")) return null;
    const w = le16(raw[6..8]);
    const h = le16(raw[8..10]);
    return .{ .w = w, .h = h };
}

fn jpegDims(raw: []const u8) ?Dims {
    // JPEG: SOI (FFD8), then segments; the first SOFn (C0..CF) holds
    // height (BE16) then width (BE16) after a 3-byte length + precision.
    if (raw.len < 4 or raw[0] != 0xFF or raw[1] != 0xD8) return null;
    var i: usize = 2;
    while (i + 9 < raw.len) {
        if (raw[i] != 0xFF) {
            i += 1;
            continue;
        }
        const m = raw[i + 1];
        // Standalone markers (RSTn, SOI, etc.) carry no length.
        if (m == 0xFF or (m >= 0xD0 and m <= 0xD9) or m == 0x01) {
            i += 2;
            continue;
        }
        if (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC) {
            const h = be16(raw[i + 5 .. i + 7]);
            const w = be16(raw[i + 7 .. i + 9]);
            return .{ .w = w, .h = h };
        }
        const seglen = be16(raw[i + 2 .. i + 4]);
        if (seglen < 2) break;
        i += 2 + seglen;
    }
    return null;
}

fn webpDims(raw: []const u8) ?Dims {
    // RIFF....WEBP, then a VP8 / VP8L / VP8X chunk.
    if (raw.len < 30) return null;
    if (!mem.eql(u8, raw[0..4], "RIFF") or !mem.eql(u8, raw[8..12], "WEBP")) return null;
    const fmt = raw[12..16];
    if (mem.eql(u8, fmt, "VP8X")) {
        // width = 1 + 24-bit LE @24, height = 1 + 24-bit LE @27.
        const w = 1 + (@as(u32, raw[24]) | (@as(u32, raw[25]) << 8) | (@as(u32, raw[26]) << 16));
        const h = 1 + (@as(u32, raw[27]) | (@as(u32, raw[28]) << 8) | (@as(u32, raw[29]) << 16));
        return .{ .w = w, .h = h };
    } else if (mem.eql(u8, fmt, "VP8L")) {
        // 4-byte LE bit-packed: bits 0-14 width-1, 15-29 height-1.
        const b = le32(raw[21..25]);
        const w = 1 + (b & 0x3FFF);
        const h = 1 + ((b >> 14) & 0x3FFF);
        return .{ .w = w, .h = h };
    } else if (mem.eql(u8, fmt, "VP8")) {
        // Frame tag at 16; key frame (bits 0-2 == 1) has width/height LE16 @26.
        if ((raw[20] & 0x07) != 1) return null;
        const w = le16(raw[26..28]) & 0x3FFF;
        const h = le16(raw[28..30]) & 0x3FFF;
        return .{ .w = w, .h = h };
    }
    return null;
}

/// pi Image.render defaultMaxHeight: without an explicit per-image limit the
/// height is capped at the width-equivalent in cells (a square image never
/// exceeds maxWidth rows; at the 9x18 default cell that is maxWidth/2).
pub fn defaultMaxHeight(max_width_cells: u32) u32 {
    const cell_w: f64 = 9;
    const cell_h: f64 = 18;
    const maxw = @as(f64, @floatFromInt(@max(1, max_width_cells)));
    return @max(1, @as(u32, @intFromFloat(@ceil((maxw * cell_w) / cell_h))));
}

/// Cell size for an image (pi calculateImageCellSize with the aspect-ratio
/// correction for kitty). `max_width_cells` caps the width; `max_height_cells`
/// (pi maxHeightCells, null = unbounded) caps the height — the scale is the
/// min of both axes so tall images shrink to fit instead of overflowing the
/// viewport. The height derives from the aspect ratio at the default 9x18
/// cell (pi's default cellDimensions).
pub fn cellSize(dims: Dims, max_width_cells: u32, max_height_cells: ?u32, is_kitty: bool) struct { columns: u32, rows: u32 } {
    const cell_w: f64 = 9;
    const cell_h: f64 = 18;
    const iw = @as(f64, @floatFromInt(@max(1, dims.w)));
    const ih = @as(f64, @floatFromInt(@max(1, dims.h)));
    const maxw = @as(f64, @floatFromInt(@max(1, max_width_cells)));
    const width_scale = (maxw * cell_w) / iw;
    // pi: heightScale defaults to widthScale when no height limit is given
    // (the scale is then width-driven only); rows are clamped to maxHeight.
    const maxh_f: ?f64 = if (max_height_cells) |mh| @as(f64, @floatFromInt(@max(1, mh))) else null;
    const height_scale: f64 = if (maxh_f) |mh| (mh * cell_h) / ih else width_scale;
    const scale = @min(width_scale, height_scale);
    const scaled_w = iw * scale;
    const scaled_h = ih * scale;
    const cw: u32 = @intFromFloat(@ceil(scaled_w / cell_w));
    var columns = @min(@as(u32, max_width_cells), cw);
    columns = @max(1, columns);
    var rows: u32 = @max(1, @as(u32, @intFromFloat(@ceil(scaled_h / cell_h))));
    if (maxh_f) |mh| {
        const mh_u: u32 = @as(u32, @intFromFloat(mh));
        rows = @min(mh_u, rows);
    }
    if (is_kitty) {
        // pi chooseLessDistortedCellCount: the cell count nearest the ideal
        // aspect ratio. With both axes capped the ideal count stays within
        // the caps (pi guarantees this algebraically; see image.js).
        const ideal_w = (@as(f64, @floatFromInt(columns)) * cell_w * ih) / (iw * cell_h);
        const ideal_h = (@as(f64, @floatFromInt(rows)) * cell_h * iw) / (ih * cell_w);
        const ideal = if (width_scale <= height_scale) ideal_w else ideal_h;
        const lo_i: u32 = @max(1, @as(u32, @intFromFloat(@floor(ideal))));
        const hi_i: u32 = lo_i + 1;
        const lo: f64 = @floatFromInt(lo_i);
        const hi: f64 = @floatFromInt(hi_i);
        const dlo = if (ideal >= lo) ideal - lo else lo - ideal;
        const dhi = if (ideal >= hi) ideal - hi else hi - ideal;
        var nearest = if (dlo <= dhi) lo_i else hi_i;
        nearest = @max(1, nearest);
        // Re-clamp both axes after the distortion pick (pi does not need
        // this — its ideal counts are provably inside the caps — but the
        // float ceil here is not, so clamp defensively).
        if (maxh_f) |mh| {
            const mh_u: u32 = @as(u32, @intFromFloat(mh));
            nearest = @min(mh_u, nearest);
        }
        nearest = @min(@as(u32, max_width_cells), nearest);
        rows = nearest;
    }
    return .{ .columns = columns, .rows = rows };
}

/// Encode base64 image data as a (possibly chunked) Kitty graphics sequence
/// (pi encodeKitty): `a=T f=100 q=2 C=1 c=<cols> r=<rows> i=<id>` then the
/// payload in 4096-char chunks (`m=1` first, `m=1` middle, `m=0` last).
/// The caller owns the returned slice.
pub fn encodeKitty(alloc: std.mem.Allocator, b64: []const u8, image_id: u32, cols: u32, rows: u32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    const header = std.fmt.allocPrint(alloc, "\x1b_Ga=T,f=100,q=2,C=1,c={d},r={d},i={d}", .{ cols, rows, image_id }) catch return error.OutOfMemory;
    defer alloc.free(header);
    const CHUNK: usize = 4096;
    if (b64.len <= CHUNK) {
        try out.appendSlice(alloc, header);
        try out.append(alloc, ';');
        try out.appendSlice(alloc, b64);
        try out.appendSlice(alloc, "\x1b\\");
        return out.toOwnedSlice(alloc);
    }
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const end = @min(off + CHUNK, b64.len);
        const is_last = end >= b64.len;
        if (first) {
            try out.appendSlice(alloc, header);
            try out.appendSlice(alloc, ",m=1;");
            first = false;
        } else if (is_last) {
            try out.appendSlice(alloc, "\x1b_Gm=0;");
        } else {
            try out.appendSlice(alloc, "\x1b_Gm=1;");
        }
        try out.appendSlice(alloc, b64[off..end]);
        try out.appendSlice(alloc, "\x1b\\");
        off = end;
    }
    return out.toOwnedSlice(alloc);
}

/// Per-image geometry registered at encode time (pi
/// registerKittyImageMetadata): cropKitty needs the source pixel height to
/// map cropped cell rows back onto source rows.
pub const Meta = struct { columns: u32, rows: u32, width_px: u32, height_px: u32 };

/// Crop an encoded Kitty line to the cell rows `[hidden, hidden+visible)` of
/// its placement (pi cropKittyImageLine): the first chunk's header loses its
/// `y`/`h`/`r` params and gains `y=<sourceY> h=<sourceHeight> r=<cropped>`;
/// the base64 payload (including any `m=1` continuation chunks) is kept
/// verbatim, so no image data is re-transmitted. Returns null when the line
/// is not a Kitty image, the metadata is missing, the window is empty, or
/// the crop would cover the whole placement (the caller then uses the line
/// as-is). Caller owns the returned slice.
pub fn cropKitty(alloc: std.mem.Allocator, line: []const u8, meta: Meta, hidden_rows: u32, visible_rows: u32) ?[]u8 {
    if (!isImageLine(line)) return null;
    if (hidden_rows >= meta.rows or visible_rows == 0) return null;
    const cropped_rows = @min(visible_rows, meta.rows - hidden_rows);
    if (hidden_rows == 0 and cropped_rows >= meta.rows) return null;
    // First chunk header: from ESC _ G up to (excluding) the first ';'.
    const esc_g = mem.indexOf(u8, line, "\x1b_G") orelse return null;
    const params_start = esc_g + 2;
    const params_end = mem.indexOfScalarPos(u8, line, params_start, ';') orelse return null;
    const source_y: u32 = @intFromFloat(@floor(@as(f64, @floatFromInt(meta.height_px * hidden_rows)) / @as(f64, @floatFromInt(meta.rows))));
    const source_end_f = @ceil(@as(f64, @floatFromInt(meta.height_px * (hidden_rows + cropped_rows))) / @as(f64, @floatFromInt(meta.rows)));
    const source_end = @min(@as(f64, @floatFromInt(meta.height_px)), source_end_f);
    const source_y_f = @as(f64, @floatFromInt(source_y));
    const source_h: u32 = @intFromFloat(@max(1, source_end - source_y_f));
    // Rebuild the header without y/h/r, then append the crop params.
    var header: std.ArrayListUnmanaged(u8) = .empty;
    defer header.deinit(alloc);
    var it = mem.splitScalar(u8, line[params_start..params_end], ',');
    var first = true;
    while (it.next()) |kv| {
        if (kv.len >= 2 and (kv[0] == 'y' or kv[0] == 'h' or kv[0] == 'r') and kv[1] == '=') continue;
        if (!first) header.append(alloc, ',') catch return null;
        header.appendSlice(alloc, kv) catch return null;
        first = false;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, line[0..params_start]) catch return null;
    out.appendSlice(alloc, header.items) catch return null;
    const crop_params = std.fmt.allocPrint(alloc, ",y={d},h={d},r={d}", .{ source_y, source_h, cropped_rows }) catch return null;
    defer alloc.free(crop_params);
    out.appendSlice(alloc, crop_params) catch return null;
    out.appendSlice(alloc, line[params_end..]) catch return null;
    return out.toOwnedSlice(alloc) catch null;
}

/// Build a placement-only command from an encoded Kitty line (pi
/// getKittyImagePlacement → replacementLine): the first chunk's header
/// keeps only placement-relevant controls (a is dropped, everything else
/// survives: i/p/x/y/w/h/X/Y/c/r/C/U/z/P/Q/H/V) and the ENTIRE payload
/// (all chunks) is dropped — the terminal re-anchors the already-uploaded
/// image data at the cursor instead of re-transmitting it. Returns null
/// when the line is not a Kitty image. Caller owns the returned slice.
pub fn placementOnly(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    if (!isImageLine(line)) return error.NotAnImage;
    const params_start = mem.indexOf(u8, line, "\x1b_G") orelse return error.NotAnImage;
    const ps = params_start + 3; // skip ESC _ G
    const params_end = mem.indexOfScalarPos(u8, line, ps, ';') orelse return error.NotAnImage;
    const KEEP = "i p x y w h X Y c r C U z P Q H V";
    var keep: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keep.deinit(alloc);
    var kit = mem.splitScalar(u8, KEEP, ' ');
    while (kit.next()) |k| try keep.append(alloc, k);
    var hdr: std.ArrayListUnmanaged(u8) = .empty;
    defer hdr.deinit(alloc);
    try hdr.appendSlice(alloc, "\x1b_Ga=p,q=2");
    var it = mem.splitScalar(u8, line[ps..params_end], ',');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const key = kv[0..1];
        var kept = false;
        for (keep.items) |k| {
            if (mem.eql(u8, key, k)) {
                kept = true;
                break;
            }
        }
        if (!kept) continue;
        try hdr.append(alloc, ',');
        try hdr.appendSlice(alloc, kv);
    }
    try hdr.appendSlice(alloc, "\x1b\\");
    return hdr.toOwnedSlice(alloc);
}

/// Format a delete-by-id sequence into `buf` (pi deleteKittyImage: frees the
/// placement and its image data); returns the used prefix.
pub fn deleteKittyInto(buf: []u8, image_id: u32) []const u8 {
    const s = std.fmt.bufPrint(buf, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id}) catch return "";
    return s;
}

/// True when the line is already a viewport crop (a `y=` param in the first
/// chunk's header — see cropKitty). Re-cropping a cropped line would restart
/// its source window from row 0; callers paint those as-is.
pub fn isCropped(line: []const u8) bool {
    if (!isImageLine(line)) return false;
    const params_end = mem.indexOfScalar(u8, line, ';') orelse return false;
    var it = mem.splitScalar(u8, line[2..params_end], ',');
    while (it.next()) |kv| {
        if (kv.len >= 2 and kv[0] == 'y' and kv[1] == '=') return true;
    }
    return false;
}

/// Extract the placement id from an encoded Kitty line (the `i=<n>` param in
/// the first chunk's header). Null when the line is not a Kitty image.
pub fn imageId(line: []const u8) ?u32 {
    if (line.len < 4 or line[0] != 0x1b or line[1] != '_') return null;
    // The header runs to the first ';' (params); the payload follows.
    var i: usize = 2;
    var found_start: ?usize = null;
    while (i < line.len) : (i += 1) {
        if (line[i] == ';') break;
        if (line[i] == 'i' and i + 1 < line.len and line[i + 1] == '=') {
            found_start = i + 2;
            break;
        }
    }
    if (found_start == null) return null;
    var v: u32 = 0;
    var j = found_start.?;
    var any = false;
    while (j < line.len) : (j += 1) {
        if (line[j] < '0' or line[j] > '9') break;
        v = v * 10 + @as(u32, line[j] - '0');
        any = true;
    }
    if (!any) return null;
    return v;
}

/// The reserved row count (`r=<n>` param) of an encoded Kitty line, or null
/// when the line is not a Kitty image / has no `r` param.
pub fn rowsOf(line: []const u8) ?u32 {
    if (line.len < 4 or line[0] != 0x1b or line[1] != '_') return null;
    var i: usize = 2;
    var found_start: ?usize = null;
    while (i < line.len) : (i += 1) {
        if (line[i] == ';') break;
        if (line[i] == 'r' and i + 1 < line.len and line[i + 1] == '=') {
            found_start = i + 2;
            break;
        }
    }
    if (found_start == null) return null;
    var v: u32 = 0;
    var j = found_start.?;
    var any = false;
    while (j < line.len) : (j += 1) {
        if (line[j] < '0' or line[j] > '9') break;
        v = v * 10 + @as(u32, line[j] - '0');
        any = true;
    }
    if (!any) return null;
    return v;
}

/// True when `line` is an encoded Kitty image (starts with `ESC _ G`).
pub fn isImageLine(line: []const u8) bool {
    return line.len >= 3 and line[0] == 0x1b and line[1] == '_' and line[2] == 'G';
}

/// Text fallback when the terminal cannot render inline images (pi
/// imageFallback): `[Image: mime WxH]`. Owned; caller frees.
pub fn fallback(alloc: std.mem.Allocator, mime: []const u8, dims: ?Dims) ![]u8 {
    return if (dims) |d|
        std.fmt.allocPrint(alloc, "[Image: {s} {d}x{d}]", .{ mime, d.w, d.h })
    else
        std.fmt.allocPrint(alloc, "[Image: {s}]", .{mime});
}

test "png dimensions" {
    var raw: [24]u8 = undefined;
    @memcpy(raw[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(raw[8..12], "IHDR");
    raw[16] = 0;
    raw[17] = 0;
    raw[18] = 0;
    raw[19] = 3;
    raw[20] = 0;
    raw[21] = 0;
    raw[22] = 0;
    raw[23] = 2;
    const d = dimensions(&raw, "image/png") orelse return error.BadImage;
    try std.testing.expectEqual(@as(u32, 3), d.w);
    try std.testing.expectEqual(@as(u32, 2), d.h);
}

test "gif dimensions" {
    var raw: [10]u8 = undefined;
    @memcpy(raw[0..4], "GIF8");
    raw[6] = 40;
    raw[7] = 0;
    raw[8] = 20;
    raw[9] = 0;
    const d = dimensions(&raw, "image/gif") orelse return error.BadImage;
    try std.testing.expectEqual(@as(u32, 40), d.w);
    try std.testing.expectEqual(@as(u32, 20), d.h);
}

test "webp VP8X dimensions" {
    var raw: [30]u8 = undefined;
    @memcpy(raw[0..4], "RIFF");
    @memcpy(raw[8..12], "WEBP");
    @memcpy(raw[12..16], "VP8X");
    raw[24] = 0xFF; // width-1 = 255 -> 256
    raw[25] = 0x00;
    raw[26] = 0x00;
    raw[27] = 0x00; // height-1 = 0 -> 1
    raw[28] = 0x00;
    raw[29] = 0x00;
    const d = dimensions(&raw, "image/webp") orelse return error.BadImage;
    try std.testing.expectEqual(@as(u32, 256), d.w);
    try std.testing.expectEqual(@as(u32, 1), d.h);
}

test "kitty encode single chunk carries id and dims" {
    const alloc = std.heap.page_allocator;
    const seq = try encodeKitty(alloc, "QUJD", 7, 10, 5);
    defer alloc.free(seq);
    try std.testing.expectEqualStrings("\x1b_Ga=T,f=100,q=2,C=1,c=10,r=5,i=7;QUJD\x1b\\", seq);
    try std.testing.expectEqual(@as(u32, 7), imageId(seq));
    try std.testing.expect(isImageLine(seq));
}

test "kitty encode chunks large payloads" {
    const alloc = std.heap.page_allocator;
    var big: [9000]u8 = undefined;
    @memset(&big, 'A');
    const seq = try encodeKitty(alloc, &big, 1, 2, 2);
    defer alloc.free(seq);
    try std.testing.expect(mem.startsWith(u8, seq, "\x1b_Ga=T,f=100,q=2,C=1,c=2,r=2,i=1,m=1;"));
    try std.testing.expect(mem.indexOf(u8, seq, "\x1b_Gm=0;") != null);
    try std.testing.expectEqual(@as(u32, 1), imageId(seq));
}

test "jpeg dimensions" {
    var raw: [40]u8 = undefined;
    raw[0] = 0xFF;
    raw[1] = 0xD8;
    raw[2] = 0xFF; // APP0
    raw[3] = 0xE0;
    raw[4] = 0;
    raw[5] = 16;
    const sof: usize = 20;
    raw[sof] = 0xFF;
    raw[sof + 1] = 0xC0; // SOF0
    raw[sof + 2] = 0;
    raw[sof + 3] = 8;
    raw[sof + 4] = 8;
    raw[sof + 5] = 0;
    raw[sof + 6] = 2; // height
    raw[sof + 7] = 0;
    raw[sof + 8] = 3; // width
    const d = dimensions(&raw, "image/jpeg") orelse return error.BadImage;
    try std.testing.expectEqual(@as(u32, 3), d.w);
    try std.testing.expectEqual(@as(u32, 2), d.h);
}

test "deleteKittyInto" {
    var buf: [48]u8 = undefined;
    const s = deleteKittyInto(&buf, 42);
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=I,i=42,q=2\x1b\\", s);
}

test "defaultMaxHeight caps square image height" {
    // pi Image.render: defaultMaxHeight = ceil(maxWidth*9/18) = ceil(60/2).
    try std.testing.expectEqual(@as(u32, 30), defaultMaxHeight(60));
    try std.testing.expectEqual(@as(u32, 1), defaultMaxHeight(1));
}

test "cellSize caps tall image height at maxHeight" {
    // 1000x800 at cap 60 without a height limit: width-driven scale
    // (540x432 px) -> 60 cols x 24 rows.
    const wide = cellSize(.{ .w = 1000, .h = 800 }, 60, null, true);
    try std.testing.expectEqual(@as(u32, 60), wide.columns);
    try std.testing.expectEqual(@as(u32, 24), wide.rows);
    // A 1000x2000 portrait image would be 60 rows uncapped; pi's default
    // height cap (30 rows) shrinks both axes to 30x30, aspect kept.
    const tall_none = cellSize(.{ .w = 1000, .h = 2000 }, 60, null, true);
    try std.testing.expectEqual(@as(u32, 60), tall_none.rows);
    const tall_capped = cellSize(.{ .w = 1000, .h = 2000 }, 60, 30, true);
    try std.testing.expectEqual(@as(u32, 30), tall_capped.rows);
    try std.testing.expectEqual(@as(u32, 30), tall_capped.columns);
}

test "cropKitty rewrites header and keeps payload" {
    const alloc = std.heap.page_allocator;
    const seq = try encodeKitty(alloc, "QUJD", 7, 10, 6);
    defer alloc.free(seq);
    // Hidden top row, keep 3 of the remaining 5 rows.
    const cropped = cropKitty(alloc, seq, .{ .columns = 10, .rows = 6, .width_px = 100, .height_px = 60 }, 1, 3) orelse return error.NoCrop;
    defer alloc.free(cropped);
    // Header keeps a/c/r? -> original params (C=1,c=10,r=6,i=7) minus y/h/r,
    // plus the crop window; payload QUJD and terminator intact.
    try std.testing.expect(mem.startsWith(u8, cropped, "\x1b_Ga=T,f=100,q=2,C=1,c=10,i=7,y="));
    try std.testing.expect(mem.indexOf(u8, cropped, ";QUJD\x1b\\") != null);
    // The placement id survives (the delete/replace machinery keys on it).
    try std.testing.expectEqual(@as(u32, 7), imageId(cropped) orelse 0);
    // Full window is a no-op (the caller paints the line as-is).
    try std.testing.expectEqual(@as(?[]u8, null), cropKitty(alloc, seq, .{ .columns = 10, .rows = 6, .width_px = 100, .height_px = 60 }, 0, 6));
}

test "placementOnly keeps controls, drops payload" {
    const alloc = std.heap.page_allocator;
    const seq = try encodeKitty(alloc, "QUJD", 7, 34, 24);
    defer alloc.free(seq);
    const p = try placementOnly(alloc, seq);
    defer alloc.free(p);
    try std.testing.expectEqualStrings("\x1b_Ga=p,q=2,C=1,c=34,r=24,i=7\x1b\\", p);
    // cropped lines keep their y/h crop window
    const cropped = cropKitty(alloc, seq, .{ .columns = 34, .rows = 24, .width_px = 100, .height_px = 200 }, 4, 12) orelse return error.NoCrop;
    defer alloc.free(cropped);
    const pc = try placementOnly(alloc, cropped);
    defer alloc.free(pc);
    try std.testing.expectEqualStrings("\x1b_Ga=p,q=2,C=1,c=34,i=7,y=33,h=101,r=12\x1b\\", pc);
    try std.testing.expectError(error.NotAnImage, placementOnly(alloc, "hello"));
}
