//! Theme system for the TUI, aligned with pi 1.5.0's JSON themes.
//!
//! pi ships built-in themes as JSON (modes/interactive/theme/{dark,light}.json)
//! and lets users drop custom themes in `~/.pi/agent/themes/*.json`. Each theme
//! names 53 color tokens whose values are one of:
//!   - ""            terminal default
//!   - "#RGB"/"#RRGGBB"   sRGB hex
//!   - "okhsl(h s% l%)"   OKHSL (gamut-relative saturation)
//!   - "oklch(l c h)"     OKLCH
//!   - 0-255 (int)   256-color palette index
//!   - "varName"       a reference into the theme's `vars` map
//!
//! We resolve every token to a concrete value at load time (var references and
//! the 5 fallback tokens) and expose pre-computed sRGB so the hot render path
//! never re-parses. Color conversion lives in oklab.zig (a byte-exact port of
//! pi-tui's oklab.js).

const std = @import("std");
const oklab = @import("oklab.zig");

/// One of the 53 pi theme tokens (order matches THEME_TOKENS).
pub const Token = enum {
    accent,
    border,
    borderAccent,
    borderMuted,
    success,
    @"error",
    warning,
    muted,
    dim,
    text,
    thinkingText,
    scrollbarTrack,
    scrollbarThumb,
    selectedBg,
    searchMatchBg,
    searchMatchText,
    userMessageBg,
    userMessageText,
    customMessageBg,
    customMessageText,
    customMessageLabel,
    toolPendingBg,
    toolSuccessBg,
    toolErrorBg,
    toolTitle,
    toolOutput,
    mdHeading,
    mdLink,
    mdLinkUrl,
    mdCode,
    mdCodeBlock,
    mdCodeBlockBorder,
    mdQuote,
    mdQuoteBorder,
    mdHr,
    mdListBullet,
    toolDiffAdded,
    toolDiffRemoved,
    toolDiffContext,
    syntaxComment,
    syntaxKeyword,
    syntaxFunction,
    syntaxVariable,
    syntaxString,
    syntaxNumber,
    syntaxType,
    syntaxOperator,
    syntaxPunctuation,
    thinkingOff,
    thinkingMinimal,
    thinkingLow,
    thinkingMedium,
    thinkingHigh,
    thinkingXhigh,
    thinkingMax,
    bashMode,

    pub fn fromStr(s: []const u8) ?Token {
        const names = @typeInfo(Token).@"enum".field_names;
        var i: usize = 0;
        while (i < names.len) : (i += 1) {
            if (std.mem.eql(u8, names[i], s)) return @enumFromInt(i);
        }
        return null;
    }
};

/// A resolved theme color value.
pub const Value = union(enum) {
    terminal: void,
    rgb: oklab.Rgb,
    indexed: u8,
};

/// A fully-resolved theme: every token mapped to a concrete color.
pub const Theme = struct {
    name: []const u8,
    values: [@typeInfo(Token).@"enum".field_names.len]Value,

    pub fn get(self: *const Theme, t: Token) Value {
        return self.values[@intFromEnum(t)];
    }

    /// Foreground SGR prefix, e.g. "\x1b[38;2;r;g;bm". Terminal default returns
    /// "\x1b[39m". Built with manual digit assembly (no std.fmt) so it is cheap
    /// at comptime (used to seed the global SgrSet).
    pub fn fgSgr(self: *const Theme, t: Token, buf: *[48]u8) []const u8 {
        return sgrPrefix(buf, 38, self.get(t));
    }

    /// Background SGR prefix, e.g. "\x1b[48;2;r;g;bm".
    pub fn bgSgr(self: *const Theme, t: Token, buf: *[48]u8) []const u8 {
        return sgrPrefix(buf, 48, self.get(t));
    }

    pub const RESET = "\x1b[0m";
};

/// Append a decimal value (0-255) to buf at position `pos`, returning the new
/// length. Manual digit assembly (comptime-cheap, no std.fmt).
fn appendDec(buf: []u8, start: usize, val: u8) usize {
    var pos = start;
    var v = val;
    if (v >= 100) {
        buf[pos] = v / 100 + '0';
        pos += 1;
        v = v % 100;
        buf[pos] = v / 10 + '0';
        pos += 1;
        v = v % 10;
    } else if (v >= 10) {
        buf[pos] = v / 10 + '0';
        pos += 1;
        v = v % 10;
    }
    buf[pos] = v + '0';
    return pos + 1;
}

/// Build an SGR color prefix into `buf` for `mode` (38 = foreground, 48 =
/// background) and a resolved color value. Returns the written slice.
fn sgrPrefix(buf: *[48]u8, mode: u8, v: Value) []const u8 {
    var s: [48]u8 = undefined;
    var n: usize = 0;
    s[n] = 0x1b;
    n += 1;
    s[n] = '[';
    n += 1;
    switch (v) {
        .terminal => {
            // default fg = 39, default bg = 49
            s[n] = @as(u8, mode + 1) + '0';
            n += 1;
            s[n] = 'm';
            n += 1;
        },
        .indexed => |i| {
            n = appendDec(s[0..], n, mode);
            s[n] = ';';
            n += 1;
            s[n] = '5';
            n += 1;
            s[n] = ';';
            n += 1;
            n = appendDec(s[0..], n, @intCast(i));
            s[n] = 'm';
            n += 1;
        },
        .rgb => |c| {
            n = appendDec(s[0..], n, mode);
            s[n] = ';';
            n += 1;
            s[n] = '2';
            n += 1;
            s[n] = ';';
            n += 1;
            n = appendDec(s[0..], n, c.r);
            s[n] = ';';
            n += 1;
            n = appendDec(s[0..], n, c.g);
            s[n] = ';';
            n += 1;
            n = appendDec(s[0..], n, c.b);
            s[n] = 'm';
            n += 1;
        },
    }
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Color value parsing (a single scalar: "" / hex / okhsl / oklch / int)
// ---------------------------------------------------------------------------

/// Parse one concrete color scalar (not a var reference). Returns null on a
/// malformed value.
pub fn parseScalar(s: []const u8) ?Value {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return .{ .terminal = {} };
    if (t[0] == '#') return parseHex(t) orelse return null;
    if (std.mem.startsWith(u8, t, "okhsl(") or std.mem.startsWith(u8, t, "oklch(")) {
        return parseOklab(t) orelse return null;
    }
    if (std.ascii.isDigit(t[0])) {
        const n = std.fmt.parseInt(u16, t, 10) catch return null;
        if (n > 255) return null;
        return .{ .indexed = @intCast(n) };
    }
    return null;
}

fn parseHex(s: []const u8) ?Value {
    const h = s[1..];
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    if (h.len == 3) {
        r = hexNibble(h[0]) orelse return null;
        g = hexNibble(h[1]) orelse return null;
        b = hexNibble(h[2]) orelse return null;
        r = @as(u8, @intCast(r * 17));
        g = @as(u8, @intCast(g * 17));
        b = @as(u8, @intCast(b * 17));
    } else if (h.len == 6) {
        r = hexByte(h[0..2]) orelse return null;
        g = hexByte(h[2..4]) orelse return null;
        b = hexByte(h[4..6]) orelse return null;
    } else return null;
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexNibble(s[0]) orelse return null;
    const lo = hexNibble(s[1]) orelse return null;
    return @as(u8, @intCast(hi * 16 + lo));
}

/// Parse "okhsl(h s% l%)" or "oklch(l% c h)". Percent on s/l is optional.
fn parseOklab(s: []const u8) ?Value {
    // Find the opening paren and closing paren.
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    const close = std.mem.lastIndexOf(u8, s, ")") orelse return null;
    if (close <= open) return null;
    const inner = s[open + 1 .. close];
    const nums = splitWhitespace(inner);
    if (std.mem.startsWith(u8, s, "okhsl(")) {
        if (nums.count != 3) return null;
        const h = parseNum(nums.fields[0]) orelse return null;
        const sat = parsePct(nums.fields[1]) orelse return null;
        const lit = parsePct(nums.fields[2]) orelse return null;
        return .{ .rgb = oklab.okhslToRgb(h, sat, lit) };
    } else {
        if (nums.count != 3) return null;
        const l = parsePct(nums.fields[0]) orelse return null;
        const c = parseNum(nums.fields[1]) orelse return null;
        const h = parseNum(nums.fields[2]) orelse return null;
        return .{ .rgb = oklab.oklchToRgb(l, c, h) };
    }
}

/// Split `s` on spaces/tabs into at most 4 fields. Returns the array and
/// count; the caller owns the storage (the fields alias `s`).
pub const SplitResult = struct {
    fields: [4][]const u8,
    count: usize,
};

fn splitWhitespace(s: []const u8) SplitResult {
    var out: [4][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
        if (n < 4) out[n] = s[start..i];
        n += 1;
    }
    return .{ .fields = out, .count = n };
}

fn parseNum(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

fn parsePct(s: []const u8) ?f64 {
    const is_pct = s.len > 0 and s[s.len - 1] == '%';
    const t = if (is_pct) s[0 .. s.len - 1] else s;
    const v = std.fmt.parseFloat(f64, t) catch return null;
    return if (is_pct) v / 100.0 else v;
}

// ---------------------------------------------------------------------------
// Theme resolution: vars + fallbacks
// ---------------------------------------------------------------------------

/// A var map entry (name → scalar string). Bounded by a simple open array.
const VarMap = std.StringHashMapUnmanaged([]const u8);

/// Bounded stack of var names on the current resolution path (cycle guard).
const VarStack = struct {
    items: [16][]const u8 = undefined,
    len: usize = 0,

    fn contains(self: *const VarStack, v: []const u8) bool {
        for (self.items[0..self.len]) |x| {
            if (std.mem.eql(u8, x, v)) return true;
        }
        return false;
    }

    fn push(self: *VarStack, v: []const u8) void {
        if (self.len < 16) self.items[self.len] = v;
        self.len += 1;
    }

    fn pop(self: *VarStack) void {
        self.len -= 1;
    }
};

/// Resolve a possibly-var-referencing value against `vars`, with cycle
/// detection. Returns null on a missing var, cycle, or bad scalar.
fn resolveVar(value: []const u8, vars: *const VarMap, visited: *VarStack) ?Value {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "okhsl(") or std.mem.startsWith(u8, t, "oklch(") or std.ascii.isDigit(t[0])) {
        return parseScalar(t);
    }
    if (visited.contains(t)) return null; // cycle
    visited.push(t);
    const target = vars.get(t) orelse return null;
    const r = resolveVar(target, vars, visited);
    visited.pop();
    return r;
}

/// The 5 tokens with a fallback to another token (pi THEME_TOKENS `fallback`).
const FALLBACKS: []const struct { token: Token, to: Token } = &.{
    .{ .token = .scrollbarTrack, .to = .muted },
    .{ .token = .scrollbarThumb, .to = .text },
    .{ .token = .searchMatchBg, .to = .selectedBg },
    .{ .token = .searchMatchText, .to = .text },
    .{ .token = .thinkingMax, .to = .thinkingXhigh },
};

/// Apply fallback tokens: any token left unset (null) copies its fallback's
/// resolved value.
fn applyFallbacks(values: *[@typeInfo(Token).@"enum".field_names.len]Value, set: *[@typeInfo(Token).@"enum".field_names.len]bool) void {
    for (FALLBACKS) |f| {
        const ti = @intFromEnum(f.token);
        const fi = @intFromEnum(f.to);
        if (!set[ti] and set[fi]) {
            values[ti] = values[fi];
            set[ti] = true;
        }
    }
}

/// Build a Theme from a parsed JSON object. `alloc` owns `name` and (for
/// custom themes) nothing else — values are value-typed. Returns null with an
/// error set when required tokens are missing or unparseable.
pub fn fromJson(alloc: std.mem.Allocator, json: std.json.Value) !*Theme {
    const obj = switch (json) {
        .object => |o| o,
        else => return error.ThemeInvalid,
    };

    const name_v = obj.get("name") orelse return error.ThemeInvalid;
    const name = switch (name_v) {
        .string => |s| s,
        else => return error.ThemeInvalid,
    };
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.ThemeInvalid;

    // vars
    var vars: VarMap = .{};
    var vars_done = false;
    defer {
        if (!vars_done) vars.deinit(alloc);
    }
    if (obj.get("vars")) |v| {
        const vmap = switch (v) {
            .object => |o| o,
            else => return error.ThemeInvalid,
        };
        for (vmap.keys()) |k| {
            const val = switch (vmap.get(k).?) {
                .string => |s| s,
                else => return error.ThemeInvalid,
            };
            vars.put(alloc, k, val) catch return error.OutOfMemory;
        }
    }

    const colors = obj.get("colors") orelse return error.ThemeInvalid;
    const cmap = switch (colors) {
        .object => |o| o,
        else => return error.ThemeInvalid,
    };

    var values: [@typeInfo(Token).@"enum".field_names.len]Value = undefined;
    var set: [@typeInfo(Token).@"enum".field_names.len]bool = undefined;
    @memset(&set, false);
    var visited = VarStack{};

    for (cmap.keys()) |k| {
        const tok = Token.fromStr(k) orelse continue; // unknown token: ignore
        const raw = switch (cmap.get(k).?) {
            .string => |s| s,
            .integer => |n| blk: {
                var tb: [8]u8 = undefined;
                break :blk std.fmt.bufPrint(&tb, "{d}", .{n}) catch return error.ThemeInvalid;
            },
            else => return error.ThemeInvalid,
        };
        const val = resolveVar(raw, &vars, &visited) orelse return error.ThemeInvalid;
        values[@intFromEnum(tok)] = val;
        set[@intFromEnum(tok)] = true;
    }
    vars.deinit(alloc);
    vars_done = true;

    // A theme must define at least `text`; missing tokens fall back or stay
    // terminal-default.
    if (!set[@intFromEnum(Token.text)]) return error.ThemeInvalid;
    applyFallbacks(&values, &set);
    for (0..@typeInfo(Token).@"enum".field_names.len) |i| {
        if (!set[i]) values[i] = .{ .terminal = {} };
    }

    const owned_name = try alloc.dupe(u8, name);
    const t = try alloc.create(Theme);
    t.* = .{ .name = owned_name, .values = values };
    return t;
}

pub fn deinit(self: *Theme, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
    alloc.destroy(self);
}

// ---------------------------------------------------------------------------
// Built-in themes (dark + light), resolved comptime from the same token
// values pi ships. Kept in sync with pi 1.5.0's theme JSON.
// ---------------------------------------------------------------------------

fn builtinDark() Theme {
    // Resolved sRGB for pi's dark.json (verified against pi-tui parseColor).
    const d: [@typeInfo(Token).@"enum".field_names.len]Value = .{
        .{ .rgb = .{ .r = 167, .g = 152, .b = 215 } }, // accent
        .{ .rgb = .{ .r = 95, .g = 168, .b = 204 } }, // border
        .{ .rgb = .{ .r = 160, .g = 142, .b = 213 } }, // borderAccent
        .{ .rgb = .{ .r = 118, .g = 129, .b = 134 } }, // borderMuted
        .{ .rgb = .{ .r = 104, .g = 183, .b = 141 } }, // success
        .{ .rgb = .{ .r = 234, .g = 127, .b = 129 } }, // error
        .{ .rgb = .{ .r = 205, .g = 154, .b = 34 } }, // warning
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // muted
        .{ .rgb = .{ .r = 126, .g = 136, .b = 142 } }, // dim
        .{ .rgb = .{ .r = 222, .g = 224, .b = 225 } }, // text
        .{ .rgb = .{ .r = 150, .g = 160, .b = 164 } }, // thinkingText
        .{ .rgb = .{ .r = 72, .g = 78, .b = 82 } }, // scrollbarTrack
        .{ .rgb = .{ .r = 151, .g = 160, .b = 165 } }, // scrollbarThumb
        .{ .rgb = .{ .r = 33, .g = 59, .b = 73 } }, // selectedBg
        .{ .rgb = .{ .r = 78, .g = 47, .b = 27 } }, // searchMatchBg
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // searchMatchText
        .{ .rgb = .{ .r = 33, .g = 59, .b = 73 } }, // userMessageBg
        .{ .rgb = .{ .r = 222, .g = 224, .b = 225 } }, // userMessageText
        .{ .rgb = .{ .r = 58, .g = 48, .b = 85 } }, // customMessageBg
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // customMessageText
        .{ .rgb = .{ .r = 167, .g = 152, .b = 215 } }, // customMessageLabel
        .{ .rgb = .{ .r = 52, .g = 56, .b = 58 } }, // toolPendingBg
        .{ .rgb = .{ .r = 37, .g = 65, .b = 49 } }, // toolSuccessBg
        .{ .rgb = .{ .r = 91, .g = 40, .b = 42 } }, // toolErrorBg
        .{ .rgb = .{ .r = 222, .g = 224, .b = 225 } }, // toolTitle
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // toolOutput
        .{ .rgb = .{ .r = 205, .g = 154, .b = 34 } }, // mdHeading
        .{ .rgb = .{ .r = 105, .g = 173, .b = 208 } }, // mdLink
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // mdLinkUrl
        .{ .rgb = .{ .r = 167, .g = 152, .b = 215 } }, // mdCode
        .{ .rgb = .{ .r = 104, .g = 183, .b = 141 } }, // mdCodeBlock
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // mdCodeBlockBorder
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // mdQuote
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // mdQuoteBorder
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // mdHr
        .{ .rgb = .{ .r = 167, .g = 152, .b = 215 } }, // mdListBullet
        .{ .rgb = .{ .r = 104, .g = 183, .b = 141 } }, // toolDiffAdded
        .{ .rgb = .{ .r = 234, .g = 127, .b = 129 } }, // toolDiffRemoved
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // toolDiffContext
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // syntaxComment
        .{ .rgb = .{ .r = 105, .g = 173, .b = 208 } }, // syntaxKeyword
        .{ .rgb = .{ .r = 205, .g = 154, .b = 34 } }, // syntaxFunction
        .{ .rgb = .{ .r = 93, .g = 179, .b = 186 } }, // syntaxVariable
        .{ .rgb = .{ .r = 222, .g = 141, .b = 90 } }, // syntaxString
        .{ .rgb = .{ .r = 104, .g = 183, .b = 141 } }, // syntaxNumber
        .{ .rgb = .{ .r = 167, .g = 152, .b = 215 } }, // syntaxType
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // syntaxOperator
        .{ .rgb = .{ .r = 157, .g = 165, .b = 169 } }, // syntaxPunctuation
        .{ .rgb = .{ .r = 108, .g = 118, .b = 123 } }, // thinkingOff
        .{ .rgb = .{ .r = 104, .g = 128, .b = 141 } }, // thinkingMinimal
        .{ .rgb = .{ .r = 84, .g = 137, .b = 164 } }, // thinkingLow
        .{ .rgb = .{ .r = 97, .g = 133, .b = 204 } }, // thinkingMedium
        .{ .rgb = .{ .r = 151, .g = 118, .b = 229 } }, // thinkingHigh
        .{ .rgb = .{ .r = 222, .g = 84, .b = 193 } }, // thinkingXhigh
        .{ .rgb = .{ .r = 254, .g = 84, .b = 98 } }, // thinkingMax
        .{ .rgb = .{ .r = 94, .g = 178, .b = 134 } }, // bashMode
    };
    return .{ .name = "dark", .values = d };
}

fn builtinLight() Theme {
    const l: [@typeInfo(Token).@"enum".field_names.len]Value = .{
        .{ .rgb = .{ .r = 116, .g = 89, .b = 180 } }, // accent
        .{ .rgb = .{ .r = 61, .g = 142, .b = 179 } }, // border
        .{ .rgb = .{ .r = 138, .g = 114, .b = 203 } }, // borderAccent
        .{ .rgb = .{ .r = 154, .g = 162, .b = 167 } }, // borderMuted
        .{ .rgb = .{ .r = 51, .g = 126, .b = 88 } }, // success
        .{ .rgb = .{ .r = 200, .g = 37, .b = 61 } }, // error
        .{ .rgb = .{ .r = 143, .g = 104, .b = 2 } }, // warning
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // muted
        .{ .rgb = .{ .r = 135, .g = 144, .b = 149 } }, // dim
        .{ .rgb = .{ .r = 59, .g = 63, .b = 65 } }, // text
        .{ .rgb = .{ .r = 124, .g = 134, .b = 140 } }, // thinkingText
        .{ .rgb = .{ .r = 225, .g = 227, .b = 228 } }, // scrollbarTrack
        .{ .rgb = .{ .r = 150, .g = 160, .b = 164 } }, // scrollbarThumb
        .{ .rgb = .{ .r = 223, .g = 231, .b = 236 } }, // selectedBg
        .{ .rgb = .{ .r = 237, .g = 227, .b = 221 } }, // searchMatchBg
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // searchMatchText
        .{ .rgb = .{ .r = 223, .g = 231, .b = 236 } }, // userMessageBg
        .{ .rgb = .{ .r = 59, .g = 63, .b = 65 } }, // userMessageText
        .{ .rgb = .{ .r = 230, .g = 228, .b = 238 } }, // customMessageBg
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // customMessageText
        .{ .rgb = .{ .r = 116, .g = 89, .b = 180 } }, // customMessageLabel
        .{ .rgb = .{ .r = 228, .g = 229, .b = 230 } }, // toolPendingBg
        .{ .rgb = .{ .r = 222, .g = 233, .b = 225 } }, // toolSuccessBg
        .{ .rgb = .{ .r = 238, .g = 226, .b = 225 } }, // toolErrorBg
        .{ .rgb = .{ .r = 59, .g = 63, .b = 65 } }, // toolTitle
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // toolOutput
        .{ .rgb = .{ .r = 143, .g = 104, .b = 2 } }, // mdHeading
        .{ .rgb = .{ .r = 47, .g = 120, .b = 153 } }, // mdLink
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // mdLinkUrl
        .{ .rgb = .{ .r = 116, .g = 89, .b = 180 } }, // mdCode
        .{ .rgb = .{ .r = 51, .g = 126, .b = 88 } }, // mdCodeBlock
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // mdCodeBlockBorder
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // mdQuote
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // mdQuoteBorder
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // mdHr
        .{ .rgb = .{ .r = 116, .g = 89, .b = 180 } }, // mdListBullet
        .{ .rgb = .{ .r = 51, .g = 126, .b = 88 } }, // toolDiffAdded
        .{ .rgb = .{ .r = 200, .g = 37, .b = 61 } }, // toolDiffRemoved
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // toolDiffContext
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // syntaxComment
        .{ .rgb = .{ .r = 47, .g = 120, .b = 153 } }, // syntaxKeyword
        .{ .rgb = .{ .r = 143, .g = 104, .b = 2 } }, // syntaxFunction
        .{ .rgb = .{ .r = 40, .g = 122, .b = 129 } }, // syntaxVariable
        .{ .rgb = .{ .r = 164, .g = 84, .b = 23 } }, // syntaxString
        .{ .rgb = .{ .r = 51, .g = 126, .b = 88 } }, // syntaxNumber
        .{ .rgb = .{ .r = 116, .g = 89, .b = 180 } }, // syntaxType
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // syntaxOperator
        .{ .rgb = .{ .r = 103, .g = 113, .b = 118 } }, // syntaxPunctuation
        .{ .rgb = .{ .r = 194, .g = 200, .b = 202 } }, // thinkingOff
        .{ .rgb = .{ .r = 181, .g = 196, .b = 203 } }, // thinkingMinimal
        .{ .rgb = .{ .r = 159, .g = 194, .b = 213 } }, // thinkingLow
        .{ .rgb = .{ .r = 162, .g = 183, .b = 224 } }, // thinkingMedium
        .{ .rgb = .{ .r = 181, .g = 165, .b = 232 } }, // thinkingHigh
        .{ .rgb = .{ .r = 229, .g = 133, .b = 205 } }, // thinkingXhigh
        .{ .rgb = .{ .r = 254, .g = 116, .b = 121 } }, // thinkingMax
        .{ .rgb = .{ .r = 64, .g = 151, .b = 108 } }, // bashMode
    };
    return .{ .name = "light", .values = l };
}

pub const builtin_dark = builtinDark();
pub const builtin_light = builtinLight();

/// Pre-computed SGR prefix strings for every token, so the render path takes
/// a `[]const u8` with no scratch buffer. Recomputed when the active theme
/// changes (rare) — rendering is the hot path.
pub const SgrSet = struct {
    const N = @typeInfo(Token).@"enum".field_names.len;
    fg: [N][48]u8 = undefined,
    fg_len: [N]usize = undefined,
    bg: [N][48]u8 = undefined,
    bg_len: [N]usize = undefined,

    pub fn compute(theme: *const Theme) SgrSet {
        var s: SgrSet = undefined;
        for (0..N) |i| {
            const tok = @as(Token, @enumFromInt(i));
            const f = theme.fgSgr(tok, &s.fg[i]);
            s.fg_len[i] = f.len;
            const b = theme.bgSgr(tok, &s.bg[i]);
            s.bg_len[i] = b.len;
        }
        return s;
    }

    pub fn fgStr(self: *const SgrSet, t: Token) []const u8 {
        const i = @intFromEnum(t);
        return self.fg[i][0..self.fg_len[i]];
    }

    pub fn bgStr(self: *const SgrSet, t: Token) []const u8 {
        const i = @intFromEnum(t);
        return self.bg[i][0..self.bg_len[i]];
    }
};

// ---------------------------------------------------------------------------
// Active theme (runtime). The TUI sets this on load / on /themes switch.
// Rendering files read it via `active()` so a theme change is picked up on
// the next frame without threading a pointer through every render call.
// Defaults to the built-in dark theme (byte-identical to the previous
// hard-coded palette), so un-themed code paths render unchanged.
// ---------------------------------------------------------------------------

var active_ptr: ?*const Theme = null;

/// The currently active theme, or the built-in dark theme when none is set.
pub fn active() *const Theme {
    return active_ptr orelse &builtin_dark;
}

/// Pre-computed SGR strings for the active theme. Recomputed on setActive.
var active_sgr: SgrSet = SgrSet.compute(&builtin_dark);

pub fn setActive(t: *const Theme) void {
    active_ptr = t;
    active_sgr = SgrSet.compute(t);
}

/// The name of the active theme (for settings persistence + the ✓ marker).
/// Defaults to "dark".
pub var active_name: []const u8 = "dark";

/// Set the active theme AND record its name (pi settings "theme").
pub fn setActiveNamed(t: *const Theme, name: []const u8) void {
    setActive(t);
    active_name = name;
}

pub fn resetActive() void {
    active_ptr = null;
    active_sgr = SgrSet.compute(&builtin_dark);
}

/// Foreground SGR prefix for a token (no scratch buffer needed).
pub fn fgStr(t: Token) []const u8 {
    return active_sgr.fgStr(t);
}

/// Background SGR prefix for a token (no scratch buffer needed).
pub fn bgStr(t: Token) []const u8 {
    return active_sgr.bgStr(t);
}

/// Foreground SGR prefix for a token from the active theme.
pub fn fg(token: Token, buf: *[48]u8) []const u8 {
    return active().fgSgr(token, buf);
}

/// Background SGR prefix for a token from the active theme.
pub fn bg(token: Token, buf: *[48]u8) []const u8 {
    return active().bgSgr(token, buf);
}

// ---------------------------------------------------------------------------
// Custom theme discovery (~/.pi/agent/themes/*.json)
// ---------------------------------------------------------------------------

/// List custom theme names in `themes_dir` (files ending in ".json"). Returns
/// an owned slice of owned names.
pub fn listCustomThemes(alloc: std.mem.Allocator, io: std.Io, themes_dir: []const u8) ![][]u8 {
    var out = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        alloc.free(out.items);
    }
    const empty: [][]u8 = &[_][]u8{};
    const dir = std.Io.Dir.cwd().openDir(io, themes_dir, .{ .iterate = true }) catch return empty;
    defer dir.close(io);
    var it = std.Io.Dir.iterate(dir);
    while (true) {
        const entry = it.next(io) catch break;
        if (entry == null) break;
        const e = entry.?;
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        const stem = e.name[0 .. e.name.len - 5];
        const dup = try alloc.dupe(u8, stem);
        out.append(alloc, dup) catch { alloc.free(dup); return error.OutOfMemory; };
    }
    return try out.toOwnedSlice(alloc);
}

/// Load a custom theme by name from `themes_dir`. Null when absent.
pub fn loadCustomTheme(alloc: std.mem.Allocator, io: std.Io, themes_dir: []const u8, name: []const u8) ?*Theme {
    var path: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&path, "{s}/{s}.json", .{ themes_dir, name }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    return fromJson(alloc, parsed.value) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn rgbOf(v: Value) [3]u8 {
    return switch (v) {
        .rgb => |c| .{ c.r, c.g, c.b },
        else => .{ 0, 0, 0 },
    };
}

test "parseScalar hex" {
    const e1 = [_]u8{ 255, 0, 128 };
    try std.testing.expectEqualSlices(u8, &e1, &rgbOf(parseScalar("#ff0080").?));
    const e2 = [_]u8{ 17, 34, 51 };
    try std.testing.expectEqualSlices(u8, &e2, &rgbOf(parseScalar("#123").?));
}

test "parseScalar okhsl matches pi" {
    const e = [_]u8{ 95, 168, 204 };
    try std.testing.expectEqualSlices(u8, &e, &rgbOf(parseScalar("okhsl(231 57% 65%)").?));
}

test "parseScalar 256 index + terminal default" {
    try std.testing.expectEqual(@as(u8, 123), parseScalar("123").?.indexed);
    try std.testing.expect(switch (parseScalar("").?) { .terminal => true, else => false });
}

test "fromJson resolves vars + fallbacks" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "name": "t",
        \\  "vars": { "base": "#102030" },
        \\  "colors": {
        \\    "text": "base",
        \\    "accent": "base",
        \\    "selectedBg": "#405060",
        \\    "error": "base"
        \\  }
        \\}
    ;
    var tree = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer tree.deinit();
    const t = try fromJson(alloc, tree.value);
    defer deinit(t, alloc);
    const e1 = [_]u8{ 0x10, 0x20, 0x30 };
    try std.testing.expectEqualSlices(u8, &e1, &rgbOf(t.get(.text)));
    const e2 = [_]u8{ 0x40, 0x50, 0x60 };
    try std.testing.expectEqualSlices(u8, &e2, &rgbOf(t.get(.searchMatchBg)));
    try std.testing.expectEqualSlices(u8, &e1, &rgbOf(t.get(.scrollbarThumb)));
}

test "fromJson rejects missing text and bad names" {
    const alloc = std.testing.allocator;
    const bad1 = "{\"name\":\"x\",\"colors\":{\"accent\":\"#fff\"}}";
    var p1 = try std.json.parseFromSlice(std.json.Value, alloc, bad1, .{});
    defer p1.deinit();
    try std.testing.expectError(error.ThemeInvalid, fromJson(alloc, p1.value));
    const bad2 = "{\"name\":\"a/b\",\"colors\":{\"text\":\"#fff\"}}";
    var p2 = try std.json.parseFromSlice(std.json.Value, alloc, bad2, .{});
    defer p2.deinit();
    try std.testing.expectError(error.ThemeInvalid, fromJson(alloc, p2.value));
}

test "builtin dark matches pi reference tokens" {
    const d = builtin_dark;
    const e1 = [_]u8{ 95, 168, 204 };
    try std.testing.expectEqualSlices(u8, &e1, &rgbOf(d.get(.border)));
    const e2 = [_]u8{ 234, 127, 129 };
    const err_tok = @as(Token, @enumFromInt(5));
    try std.testing.expectEqualSlices(u8, &e2, &rgbOf(d.get(err_tok)));
    const e3 = [_]u8{ 222, 224, 225 };
    try std.testing.expectEqualSlices(u8, &e3, &rgbOf(d.get(.text)));
    const e4 = [_]u8{ 33, 59, 73 };
    try std.testing.expectEqualSlices(u8, &e4, &rgbOf(d.get(.userMessageBg)));
}

test "fgSgr/bgSgr produce truecolor escapes" {
    const d = builtin_dark;
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[38;2;95;168;204m", d.fgSgr(.border, &buf));
    try std.testing.expectEqualStrings("\x1b[48;2;33;59;73m", d.bgSgr(.userMessageBg, &buf));
}
