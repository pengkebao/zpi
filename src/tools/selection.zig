//! Tool selection engine (Phase E7).
//!
//! Mirrors pi's tool selection semantics (sdk.js):
//!   - `DEFAULT_TOOL_NAMES` is the built-in default set.
//!   - `--tools a,b,c` (plain names) REPLACES the default set.
//!   - `--tools +x,-y` (all modifiers) MODIFIES the default set:
//!     `+x` adds x if absent, `-y` removes y if present.
//!   - Plain and modifier entries cannot be mixed.
//!   - Modifier entries take exact names (no wildcards).
//!   - `--exclude-tools a,b,p*` removes matching names (wildcards allowed).
//!   - `defaultTools` in settings.json is resolved the same way as --tools.

const std = @import("std");
const match = @import("match.zig");

pub const DEFAULT_TOOL_NAMES = [_][]const u8{ "read", "bash", "edit", "write" };

pub const Error = error{OutOfMemory};

/// A `+name` / `-name` entry (vs a plain tool name).
pub fn isToolModifier(entry: []const u8) bool {
    return entry.len > 0 and (entry[0] == '+' or entry[0] == '-');
}

fn hasModifier(entries: []const []const u8) bool {
    for (entries) |e| {
        if (isToolModifier(e)) return true;
    }
    return false;
}

fn nameIndex(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Validate a `--tools` list. Returns a dup'd error message, or null if valid.
pub fn getToolListError(alloc: std.mem.Allocator, entries: []const []const u8) Error!?[]u8 {
    if (!hasModifier(entries)) return null;
    for (entries) |e| {
        if (!isToolModifier(e)) {
            const msg = try std.fmt.allocPrint(alloc, "tool names cannot be mixed with +name or -name entries", .{});
            return msg;
        }
    }
    for (entries) |e| {
        if (std.mem.indexOfScalar(u8, e, '*') != null) {
            const msg = try std.fmt.allocPrint(alloc, "+name and -name entries take exact tool names, not patterns: {s}", .{e});
            return msg;
        }
    }
    return null;
}

/// Apply `+name`/`-name` modifiers to a base list. Returns an owned slice of
/// name pointers (pointing into `base`/`entries`, not dup'd).
pub fn applyToolModifiers(alloc: std.mem.Allocator, base: []const []const u8, entries: []const []const u8) Error![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(alloc);
    errdefer list.deinit();
    for (base) |n| try list.append(n);
    for (entries) |entry| {
        if (!isToolModifier(entry)) continue;
        const name = entry[1..];
        const idx = nameIndex(list.items, name);
        if (entry[0] == '+') {
            if (idx == null) try list.append(name);
        } else if (idx) |i| {
            list.items[i] = list.items[list.items.len - 1];
            _ = list.pop();
        }
    }
    return list.toOwnedSlice();
}

/// Resolve a `defaultTools` setting value into a concrete tool list.
/// Plain (non-modifier) names become the base; otherwise the built-in default
/// is the base. Modifier entries are applied on top.
pub fn resolveDefaultTools(alloc: std.mem.Allocator, entries: []const []const u8) Error![]const []const u8 {
    const has_plain = blk: {
        for (entries) |e| {
            if (!isToolModifier(e)) break :blk true;
        }
        break :blk false;
    };
    const base: []const []const u8 = if (has_plain or entries.len == 0) entries else &DEFAULT_TOOL_NAMES;
    return applyToolModifiers(alloc, base, entries);
}

/// Compute the final active tool set.
/// - `base`: the resolved default set (built-in or from defaultTools).
/// - `cli_tools`: the `--tools` value (plain names OR all-modifiers), or null.
/// - `exclude`: `--exclude-tools` patterns (exact names or `*` wildcards).
pub fn select(alloc: std.mem.Allocator, base: []const []const u8, cli_tools: ?[]const []const u8, exclude: []const []const u8) Error![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(alloc);
    errdefer list.deinit();

    var owned_mods: ?[]const []const u8 = null;
    const selected: []const []const u8 = if (cli_tools) |tools| blk: {
        if (hasModifier(tools)) {
            owned_mods = try applyToolModifiers(alloc, base, tools);
            break :blk owned_mods.?;
        }
        break :blk tools;
    } else base;
    defer if (owned_mods) |m| alloc.free(m);

    for (selected) |n| {
        if (!matchesAny(n, exclude)) try list.append(n);
    }
    return list.toOwnedSlice();
}

/// Does `name` match any exclude pattern (exact, or `*` wildcard)?
pub fn matchesAny(name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (std.mem.indexOfScalar(u8, p, '*') == null) {
            if (std.mem.eql(u8, p, name)) return true;
        } else if (match.globMatch(p, name)) {
            return true;
        }
    }
    return false;
}

test "isToolModifier" {
    try std.testing.expect(isToolModifier("+read"));
    try std.testing.expect(isToolModifier("-read"));
    try std.testing.expect(!isToolModifier("read"));
    try std.testing.expect(!isToolModifier(""));
}

test "getToolListError" {
    const gpa = std.testing.allocator;
    // Plain names: no error.
    const plain = [_][]const u8{"read", "bash"};
    const r1 = getToolListError(gpa, &plain) catch return;
    try std.testing.expect(r1 == null);
    // All modifiers: no error.
    const mods = [_][]const u8{ "+grep", "-write" };
    const r2 = getToolListError(gpa, &mods) catch return;
    try std.testing.expect(r2 == null);
    // Mixed: error.
    const mixed = [_][]const u8{ "read", "+grep" };
    const err = try getToolListError(gpa, &mixed);
    if (err) |e| {
        defer gpa.free(e);
        try std.testing.expect(std.mem.indexOf(u8, e, "mixed") != null);
    } else {
        @panic("expected error for mixed tools");
    }
    // Modifier with wildcard: error.
    const wild = [_][]const u8{ "+g*" };
    const err2 = try getToolListError(gpa, &wild);
    if (err2) |e| {
        defer gpa.free(e);
        try std.testing.expect(std.mem.indexOf(u8, e, "patterns") != null);
    } else {
        @panic("expected error for wildcard modifier");
    }
}

test "applyToolModifiers add and remove" {
    const gpa = std.testing.allocator;
    const base = &DEFAULT_TOOL_NAMES;
    // +grep adds, -write removes.
    const entries = [_][]const u8{ "+grep", "-write" };
    const out = applyToolModifiers(gpa, base, &entries) catch return;
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expect(nameIndex(out, "read") != null);
    try std.testing.expect(nameIndex(out, "bash") != null);
    try std.testing.expect(nameIndex(out, "edit") != null);
    try std.testing.expect(nameIndex(out, "write") == null);
    try std.testing.expect(nameIndex(out, "grep") != null);
    // +read (already present) does not duplicate.
    const dup = [_][]const u8{ "+read" };
    const out2 = applyToolModifiers(gpa, base, &dup) catch return;
    defer gpa.free(out2);
    try std.testing.expectEqual(@as(usize, 4), out2.len);
    // -unknown is a no-op.
    const unk = [_][]const u8{ "-nope" };
    const out3 = applyToolModifiers(gpa, base, &unk) catch return;
    defer gpa.free(out3);
    try std.testing.expectEqual(@as(usize, 4), out3.len);
}

test "resolveDefaultTools" {
    const gpa = std.testing.allocator;
    // Plain names become the base.
    const plain = [_][]const u8{ "read", "bash" };
    const out = resolveDefaultTools(gpa, &plain) catch return;
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // Modifiers only: base is the built-in default.
    const mods = [_][]const u8{ "+grep" };
    const out2 = resolveDefaultTools(gpa, &mods) catch return;
    defer gpa.free(out2);
    try std.testing.expect(nameIndex(out2, "read") != null);
    try std.testing.expect(nameIndex(out2, "grep") != null);
    // Empty setting: resolves to empty (an explicit empty defaultTools means no
    // tools). The built-in DEFAULT fallback happens at the call site when the
    // setting is absent (null), not when it is present-but-empty.
    const out3 = resolveDefaultTools(gpa, &[_][]const u8{}) catch return;
    defer gpa.free(out3);
    try std.testing.expectEqual(@as(usize, 0), out3.len);
}

test "select plain replace" {
    const gpa = std.testing.allocator;
    const out = select(gpa, &DEFAULT_TOOL_NAMES, &[_][]const u8{"read", "bash"}, &[_][]const u8{}) catch return;
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(nameIndex(out, "read") != null);
    try std.testing.expect(nameIndex(out, "bash") != null);
    try std.testing.expect(nameIndex(out, "write") == null);
}

test "select modifiers" {
    const gpa = std.testing.allocator;
    const out = select(gpa, &DEFAULT_TOOL_NAMES, &[_][]const u8{ "+grep", "-write" }, &[_][]const u8{}) catch return;
    defer gpa.free(out);
    try std.testing.expect(nameIndex(out, "read") != null);
    try std.testing.expect(nameIndex(out, "grep") != null);
    try std.testing.expect(nameIndex(out, "write") == null);
}

test "select exclude exact" {
    const gpa = std.testing.allocator;
    const out = select(gpa, &DEFAULT_TOOL_NAMES, null, &[_][]const u8{"bash"}) catch return;
    defer gpa.free(out);
    try std.testing.expect(nameIndex(out, "bash") == null);
    try std.testing.expect(nameIndex(out, "read") != null);
    try std.testing.expectEqual(@as(usize, 3), out.len);
}

test "select exclude wildcard" {
    const gpa = std.testing.allocator;
    // base has find + grep; exclude "f*" removes find.
    const base = [_][]const u8{ "read", "find", "grep" };
    const out = select(gpa, &base, null, &[_][]const u8{ "f*" }) catch return;
    defer gpa.free(out);
    try std.testing.expect(nameIndex(out, "find") == null);
    try std.testing.expect(nameIndex(out, "grep") != null);
    try std.testing.expect(nameIndex(out, "read") != null);
    // exclude "*" removes everything.
    const out2 = select(gpa, &base, null, &[_][]const u8{ "*" }) catch return;
    defer gpa.free(out2);
    try std.testing.expectEqual(@as(usize, 0), out2.len);
}

test "matchesAny" {
    try std.testing.expect(matchesAny("bash", &[_][]const u8{"bash"}));
    try std.testing.expect(!matchesAny("bash", &[_][]const u8{"read"}));
    try std.testing.expect(matchesAny("find", &[_][]const u8{"f*"}));
    try std.testing.expect(!matchesAny("grep", &[_][]const u8{"f*"}));
}
