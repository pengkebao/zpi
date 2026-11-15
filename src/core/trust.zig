//! Project trust store — a port of pi's `core/trust-manager.js`.
//!
//! `~/.pi/agent/trust.json` maps canonical absolute paths to trust
//! decisions (`true`/`false`/`null` = remove). Reading a decision walks UP
//! from the cwd to the nearest ancestor with an entry, so trusting a parent
//! covers all nested projects (pi findNearestTrustEntry). Entries are
//! written sorted with a trailing newline (pi writeTrustFile); zpi is
//! single-process so the lockfile step is omitted.

const std = @import("std");

pub const TrustRequiringResources = [_][]const u8{
    "settings.json", "mcp.json",    "extensions", "skills",
    "prompts",       "themes",      "SYSTEM.md",  "APPEND_SYSTEM.md",
};

/// Process cwd (Zig 0.17: no std.fs.cwd(); std.c.getcwd works everywhere).
fn processCwd(alloc: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const p = std.c.getcwd(&buf, buf.len) orelse return error.CwdTooLong;
    const end = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return alloc.dupe(u8, p[0..end]);
}

/// Canonical absolute path (pi normalizeCwd). pi uses realpath; zpi uses a
/// hand-rolled lexical normalization — std.fs.path.resolve's ArrayList
/// shrink trips the SafeAllocator's remap tracking (double free), and
/// symlink-resolving realpath is unavailable in Zig 0.17 std anyway. Trust
/// keys stay consistent because every caller passes paths from the same
/// source (kernel cwd / user input). Relative paths resolve against the
/// process cwd.
pub fn canonicalize(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const abs = if (std.fs.path.isAbsolute(path)) path else blk: {
        const cwd = try processCwd(alloc);
        defer alloc.free(cwd);
        break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, path });
    };
    defer if (!std.fs.path.isAbsolute(path)) alloc.free(abs);
    // Normalize components: drop empty/".", pop on "..".
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (n > 0) n -= 1;
            continue;
        }
        if (n >= parts.len) return error.NameTooLong;
        parts[n] = comp;
        n += 1;
    }
    var out = try alloc.alloc(u8, abs.len + 1);
    defer alloc.free(out);
    out[0] = '/';
    var w: usize = 1;
    for (parts[0..n]) |p| {
        if (w > 1) {
            out[w] = '/';
            w += 1;
        }
        @memcpy(out[w..w + p.len], p);
        w += p.len;
    }
    return alloc.dupe(u8, out[0..w]);
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, agent_dir: []const u8) !Store {
        const path = try std.fmt.allocPrint(alloc, "{s}/trust.json", .{agent_dir});
        return .{ .alloc = alloc, .io = io, .path = path };
    }

    pub fn deinit(self: *Store) void {
        self.alloc.free(self.path);
    }

    fn parseEntries(self: *Store) !std.StringArrayHashMapUnmanaged(bool) {
        var map: std.StringArrayHashMapUnmanaged(bool) = .empty;
        errdefer {
            for (map.keys()) |k| self.alloc.free(k);
            map.deinit(self.alloc);
        }
        const buf = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.alloc, .limited(1 << 20)) catch {
            return map;
        };
        defer self.alloc.free(buf);
        var p = std.json.parseFromSlice(std.json.Value, self.alloc, buf, .{}) catch return map;
        defer p.deinit();
        const root = switch (p.value) {
            .object => |o| o,
            else => return map,
        };
        for (root.keys(), root.values()) |k, v| {
            const decision: ?bool = switch (v) {
                .bool => |b| b,
                .null => null,
                else => continue, // pi throws on invalid values; zpi skips
            };
            const key = try self.alloc.dupe(u8, k);
            try map.put(self.alloc, key, decision orelse false);
            if (decision == null) {
                // pi keeps null entries out of the effective store.
                _ = map.orderedRemove(key);
                self.alloc.free(key);
            }
        }
        return map;
    }

    /// The stored decision for `cwd` or its nearest trusted ancestor
    /// (pi findNearestTrustEntry). Caller frees the returned path.
    pub fn getEntry(self: *Store, cwd: []const u8) !?struct { path: []u8, decision: bool } {
        var map = try self.parseEntries();
        defer {
            for (map.keys()) |k| self.alloc.free(k);
            map.deinit(self.alloc);
        }
        const norm = try canonicalize(self.alloc, cwd);
        defer self.alloc.free(norm);
        var current: []const u8 = norm;
        while (true) {
            if (map.get(current)) |d| {
                return .{ .path = try self.alloc.dupe(u8, current), .decision = d };
            }
            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            current = parent;
        }
    }

    /// The stored decision for `cwd` or its nearest ancestor.
    pub fn get(self: *Store, cwd: []const u8) ?bool {
        const entry = self.getEntry(cwd) catch return null;
        if (entry) |e| {
            defer self.alloc.free(e.path);
            return e.decision;
        }
        return null;
    }

    fn writeEntries(self: *Store, map: *std.StringArrayHashMapUnmanaged(bool)) !void {
        // Sorted keys, "key": true/false, trailing newline (pi writeTrustFile).
        var keys: [][]const u8 = try self.alloc.alloc([]const u8, map.count());
        defer self.alloc.free(keys);
        for (map.keys(), 0..) |k, i| keys[i] = k;
        std.mem.sort([]const u8, keys, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var out = std.array_list.Managed(u8).init(self.alloc);
        defer out.deinit();
        try out.appendSlice("{\n");
        for (keys, 0..) |k, i| {
            try out.appendSlice("  \"");
            // Escape the path for JSON (backslashes on Windows, quotes).
            for (k) |c| {
                switch (c) {
                    '"' => try out.appendSlice("\\\""),
                    '\\' => try out.appendSlice("\\\\"),
                    else => try out.append(c),
                }
            }
            try out.appendSlice("\": ");
            try out.appendSlice(if (map.get(k).? == true) "true" else "false");
            if (i + 1 < keys.len) try out.append(',');
            try out.append('\n');
        }
        try out.appendSlice("}\n");
        if (std.fs.path.dirname(self.path)) |parent| {
            std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        }
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = out.items }) catch return error.WriteFailed;
    }

    /// Set the decision for one path (pi set).
    pub fn set(self: *Store, cwd: []const u8, decision: bool) !void {
        var map = try self.parseEntries();
        defer {
            for (map.keys()) |k| self.alloc.free(k);
            map.deinit(self.alloc);
        }
        const norm = try canonicalize(self.alloc, cwd);
        defer self.alloc.free(norm);
        // Replace any casing-variant key (pi setMany deletes variants).
        var i: usize = 0;
        while (i < map.count()) {
            const k = map.keys()[i];
            if (std.ascii.eqlIgnoreCase(k, norm)) {
                _ = map.orderedRemove(k);
            } else i += 1;
        }
        // The map owns its keys — norm itself is freed by the defer above.
        const key = try self.alloc.dupe(u8, norm);
        try map.put(self.alloc, key, decision);
        try self.writeEntries(&map);
    }

    /// Trust the parent folder and drop the entry for `cwd` itself
    /// (pi "Trust parent folder" updates).
    pub fn setParent(self: *Store, cwd: []const u8) !void {
        var map = try self.parseEntries();
        defer {
            for (map.keys()) |k| self.alloc.free(k);
            map.deinit(self.alloc);
        }
        const norm = try canonicalize(self.alloc, cwd);
        defer self.alloc.free(norm);
        const parent = std.fs.path.dirname(norm) orelse return error.NoParent;
        var i: usize = 0;
        while (i < map.count()) {
            const k = map.keys()[i];
            if (std.ascii.eqlIgnoreCase(k, norm)) {
                _ = map.orderedRemove(k);
            } else i += 1;
        }
        const key = try self.alloc.dupe(u8, parent);
        try map.put(self.alloc, key, true);
        try self.writeEntries(&map);
    }
};

/// True when cwd has project-local resources gated by project trust:
/// trust-requiring entries under `cwd/.pi`, or `.agents/skills` in cwd or
/// one of its ancestors (pi hasTrustRequiringProjectResources; the user's
/// `~/.agents/skills` is always a trusted user resource and is ignored).
pub fn hasTrustRequiringResources(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: ?[]const u8,
) bool {
    const config_dir = std.fmt.allocPrint(alloc, "{s}/.pi", .{cwd}) catch return false;
    defer alloc.free(config_dir);
    for (TrustRequiringResources) |entry| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ config_dir, entry }) catch continue;
        defer alloc.free(p);
        if (pathExists(io, p)) return true;
    }
    // .agents/skills in cwd or any ancestor (except the user's own).
    const current_buf = alloc.dupe(u8, cwd) catch return false;
    defer alloc.free(current_buf);
    var current: []const u8 = current_buf;
    while (true) {
        const agents = std.fmt.allocPrint(alloc, "{s}/.agents/skills", .{current}) catch return false;
        defer alloc.free(agents);
        var is_user = false;
        if (pathExists(io, agents)) {
            if (home_dir) |h| {
                if (std.fmt.allocPrint(alloc, "{s}/.agents/skills", .{h})) |user_skills| {
                    defer alloc.free(user_skills);
                    is_user = sameDir(alloc, agents, user_skills);
                } else |_| {}
            }
            if (!is_user) return true;
        }
        const parent = std.fs.path.dirname(current) orelse return false;
        if (std.mem.eql(u8, parent, current)) return false;
        // dirname(current) IS a prefix slice of current_buf — just shorten
        // (a @memcpy of the prefix onto itself is an aliasing error).
        current = current[0..parent.len];
    }
}

fn sameDir(alloc: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    const ca = canonicalize(alloc, a) catch return std.mem.eql(u8, a, b);
    defer alloc.free(ca);
    const cb = canonicalize(alloc, b) catch return false;
    defer alloc.free(cb);
    return std.mem.eql(u8, ca, cb);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub const DecisionKind = enum {
    trust,
    trust_parent,
    trust_session,
    distrust,
    distrust_session,
};

pub const TrustOption = struct {
    kind: DecisionKind,
    label: []const u8,
    /// Path saved to (null for session-only choices).
    saved_path: ?[]const u8 = null,
    trusted: bool,
};

/// The prompt options, in pi's order (getProjectTrustOptions with
/// includeSessionOnly). Labels match pi verbatim.
pub fn optionsFor(alloc: std.mem.Allocator, cwd: []const u8) ![]TrustOption {
    // Built inside an arena (scratch label/saved_path strings), then copied
    // out — the SafeAllocator double-frees intermediates built with the raw
    // caller allocator here (arena frees once, at the end).
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var out = std.array_list.Managed(TrustOption).init(aa);
    const norm = try canonicalize(aa, cwd);
    try out.append(.{ .kind = .trust, .label = "Trust", .saved_path = norm, .trusted = true });
    if (std.fs.path.dirname(norm)) |parent| {
        const label = try std.fmt.allocPrint(aa, "Trust parent folder ({s})", .{parent});
        try out.append(.{ .kind = .trust_parent, .label = label, .saved_path = parent, .trusted = true });
    }
    try out.append(.{ .kind = .trust_session, .label = "Trust (this session only)", .trusted = true });
    try out.append(.{ .kind = .distrust, .label = "Do not trust", .saved_path = norm, .trusted = false });
    try out.append(.{ .kind = .distrust_session, .label = "Do not trust (this session only)", .trusted = false });
    const scratch = try out.toOwnedSlice();
    // Deep-copy into the caller allocator (labels borrow saved_path, so copy
    // saved_path first and point labels at the copies).
    var final = try alloc.alloc(TrustOption, scratch.len);
    for (scratch, 0..) |o, i| {
        final[i] = o;
        if (o.saved_path) |sp| {
            const copy = try alloc.dupe(u8, sp);
            final[i].saved_path = copy;
            final[i].label = if (i == 0 or i == 2)
                o.label // static "Trust"/session labels
            else if (std.mem.startsWith(u8, o.label, "Trust parent folder "))
                try std.fmt.allocPrint(alloc, "Trust parent folder ({s})", .{copy})
            else
                alloc.dupe(u8, o.label) catch o.label;
        }
    }
    return final;
}

// ---- tests ----

const testing = std.testing;
var t_threaded: ?std.Io.Threaded = null;
fn tIo() std.Io {
    if (t_threaded == null) {
        t_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return t_threaded.?.io();
}

test "canonicalize resolves relative paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const abs = try canonicalize(arena.allocator(), ".");
    try testing.expect(std.fs.path.isAbsolute(abs));
}

test "optionsFor includes all five choices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const opts = try optionsFor(arena.allocator(), "/tmp/proj");
    try testing.expectEqual(@as(usize, 5), opts.len);
    try testing.expectEqualStrings("Trust", opts[0].label);
    try testing.expectEqualStrings("Trust parent folder (/tmp)", opts[1].label);
    try testing.expectEqualStrings("Trust (this session only)", opts[2].label);
    try testing.expectEqualStrings("Do not trust", opts[3].label);
    try testing.expectEqualStrings("Do not trust (this session only)", opts[4].label);
    try testing.expect(opts[2].saved_path == null); // session-only never writes
    try testing.expect(opts[4].trusted == false);
}

test "hasTrustRequiringResources walks ancestors without aliasing" {
    const io = tIo();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    // no .pi anywhere in the tmp tree; pass the REAL home so the user's
    // ~/.agents/skills (if present) is excluded like production does —
    // otherwise every ancestor walk finds $HOME/.agents/skills and gates.
    const home_c = std.c.getenv("HOME") orelse "/nonexistent";
    const home = std.mem.span(home_c);
    try testing.expectEqual(false, hasTrustRequiringResources(alloc, io, root, home));
    // .pi/skills at an ANCESTOR of the cwd gates it (project .agents/skills
    // and cwd/.pi are the same check family — exercise the ancestor walk).
    const nested = try std.fmt.allocPrint(alloc, "{s}/a/b/c", .{root});
    std.Io.Dir.cwd().createDirPath(io, nested) catch {};
    const agents = try std.fmt.allocPrint(alloc, "{s}/a/.agents/skills", .{root});
    std.Io.Dir.cwd().createDirPath(io, agents) catch {};
    try testing.expectEqual(true, hasTrustRequiringResources(alloc, io, nested, home));
}

test "store set/get/inherit roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [1024]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const base = root_buf[0..root_len];
    const agent_dir = try std.fs.path.join(alloc, &.{ base, "agent" });
    var store = try Store.init(alloc, io, agent_dir);
    defer store.deinit();

    // No entry yet.
    try testing.expectEqual(@as(?bool, null), store.get(base));

    // Trust the parent; child inherits.
    try store.setParent(base);
    const child = try std.fs.path.join(alloc, &.{ base, "sub", "proj" });
    try testing.expectEqual(@as(?bool, true), store.get(child));

    // Distrust the child explicitly.
    try store.set(child, false);
    try testing.expectEqual(@as(?bool, false), store.get(child));
    try testing.expectEqual(@as(?bool, true), store.get(base));

    // Re-trust the child.
    try store.set(child, true);
    try testing.expectEqual(@as(?bool, true), store.get(child));

    // File is valid JSON with sorted keys and trailing newline.
    const raw = std.Io.Dir.cwd().readFileAlloc(io, store.path, alloc, .limited(1 << 20)) catch unreachable;
    defer alloc.free(raw);
    try testing.expect(std.mem.endsWith(u8, raw, "\n"));
    try testing.expect(std.mem.indexOf(u8, raw, "\"") != null);
    var p = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch unreachable;
    defer p.deinit();
    try testing.expect(p.value == .object);
}
