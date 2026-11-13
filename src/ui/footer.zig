//! Footer lines below the editor (pi: FooterComponent).
//!
//!   ~/Projects/app (main) • session name
//!   ↑12k ↓3.4k R80k W2.1k CH87.5% $0.123 12.3%/200k (auto)     (provider) model • high
//!
//! Formatting is pure; `readGitBranch` is the only IO.

const std = @import("std");
const wmod = @import("width.zig");

// pi dark theme (okhsl converted to sRGB with pi-tui's color pipeline).
const RESET = "\x1b[0m";
const FG_DIM = "\x1b[38;2;126;136;142m"; // dim      okhsl(229 8% 56%)
const FG_WARNING = "\x1b[38;2;205;154;34m"; // warning  okhsl(83 88% 67%)
const FG_ERROR = "\x1b[38;2;234;127;129m"; // error    okhsl(20 72% 67%)

/// Columns kept between the usage stats and the model.
const MIN_PADDING = 2;

/// Session usage for the stats line.
pub const Stats = struct {
    /// Input tokens that were not served from the prompt cache.
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    /// Share of the latest prompt read from the cache, in percent; null when
    /// there is no response yet.
    cache_hit_rate: ?f64 = null,
    /// Total cost in USD.
    cost: f64 = 0,
    context_tokens: u64 = 0,
    context_window: u64 = 0,
    auto_compact: bool = true,
};

/// The model shown on the right of the stats line.
pub const Model = struct {
    id: []const u8,
    /// Shown as `(provider)`; pass it only when several providers are in use.
    provider: ?[]const u8 = null,
    /// Thinking level of a reasoning model ("off", "high", ...). Null for a
    /// model without reasoning, which shows no level.
    thinking: ?[]const u8 = null,
};

/// A token count as 850, 1.2k, 45k, 1.3M or 12M (pi: formatTokens).
pub fn formatTokens(buf: []u8, count: u64) []const u8 {
    const n: f64 = @floatFromInt(count);
    if (count < 1_000) return std.fmt.bufPrint(buf, "{d}", .{count}) catch "";
    if (count < 10_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{n / 1_000.0}) catch "";
    if (count < 1_000_000) return std.fmt.bufPrint(buf, "{d}k", .{roundToInt(n / 1_000.0)}) catch "";
    if (count < 10_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{n / 1_000_000.0}) catch "";
    return std.fmt.bufPrint(buf, "{d}M", .{roundToInt(n / 1_000_000.0)}) catch "";
}

fn roundToInt(x: f64) u64 {
    return @intFromFloat(@round(x));
}

/// The stats line, `width` columns wide: usage on the left and the model
/// right-aligned, all dim. The context share turns yellow above 70% and red
/// above 90%. Zero counters are left out. The caller owns the result.
pub fn statsLine(alloc: std.mem.Allocator, stats: Stats, model: Model, width: usize) ![]u8 {
    var num: [24]u8 = undefined;

    // Everything left of the context share.
    var left: std.ArrayListUnmanaged(u8) = .empty;
    defer left.deinit(alloc);
    if (stats.input > 0) try appendPart(alloc, &left, "↑", formatTokens(&num, stats.input));
    if (stats.output > 0) try appendPart(alloc, &left, "↓", formatTokens(&num, stats.output));
    if (stats.cache_read > 0) try appendPart(alloc, &left, "R", formatTokens(&num, stats.cache_read));
    if (stats.cache_write > 0) try appendPart(alloc, &left, "W", formatTokens(&num, stats.cache_write));
    if (stats.cache_read > 0 or stats.cache_write > 0) {
        if (stats.cache_hit_rate) |rate| {
            try appendPart(alloc, &left, "CH", std.fmt.bufPrint(&num, "{d:.1}%", .{rate}) catch "");
        }
    }
    if (stats.cost > 0) try appendPart(alloc, &left, "$", std.fmt.bufPrint(&num, "{d:.3}", .{stats.cost}) catch "");

    // The context share: `12.3%/200k (auto)`.
    const percent: f64 = if (stats.context_window > 0)
        @as(f64, @floatFromInt(stats.context_tokens)) * 100.0 / @as(f64, @floatFromInt(stats.context_window))
    else
        0;
    var ctx_buf: [64]u8 = undefined;
    const ctx = std.fmt.bufPrint(&ctx_buf, "{d:.1}%/{s}{s}", .{
        percent,
        formatTokens(&num, stats.context_window),
        if (stats.auto_compact) " (auto)" else "",
    }) catch "";
    const ctx_color: []const u8 = if (percent > 90) FG_ERROR else if (percent > 70) FG_WARNING else "";

    // The model, with the provider when there is room for it.
    const left_w = wmod.visualWidth(left.items) + wmod.visualWidth(ctx);
    const plain_right = try rightSide(alloc, model, false);
    defer alloc.free(plain_right);
    var right: []const u8 = plain_right;
    var with_provider: ?[]u8 = null;
    defer if (with_provider) |r| alloc.free(r);
    if (model.provider != null) {
        with_provider = try rightSide(alloc, model, true);
        if (left_w + MIN_PADDING + wmod.visualWidth(with_provider.?) <= width) right = with_provider.?;
    }
    // Not enough room: cut the model short, or drop it.
    if (left_w + MIN_PADDING + wmod.visualWidth(right) > width) {
        const room = if (width > left_w + MIN_PADDING) width - left_w - MIN_PADDING else 0;
        right = truncateColumns(right, room);
    }
    const right_w = wmod.visualWidth(right);
    const padding = if (width > left_w + right_w) width - left_w - right_w else 0;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, FG_DIM);
    try out.appendSlice(alloc, left.items);
    if (ctx_color.len > 0) {
        // The color's reset ends the dim as well; start it again after.
        try out.appendSlice(alloc, ctx_color);
        try out.appendSlice(alloc, ctx);
        try out.appendSlice(alloc, RESET);
        try out.appendSlice(alloc, FG_DIM);
    } else {
        try out.appendSlice(alloc, ctx);
    }
    try out.appendNTimes(alloc, ' ', padding);
    try out.appendSlice(alloc, right);
    try out.appendSlice(alloc, RESET);
    return out.toOwnedSlice(alloc);
}

/// `<label><value> ` appended to `out`.
fn appendPart(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), label: []const u8, value: []const u8) !void {
    try out.appendSlice(alloc, label);
    try out.appendSlice(alloc, value);
    try out.append(alloc, ' ');
}

/// `(provider) model • level`. A reasoning model at level "off" reads
/// "thinking off".
fn rightSide(alloc: std.mem.Allocator, model: Model, with_provider: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    if (with_provider) {
        if (model.provider) |p| {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, p);
            try out.appendSlice(alloc, ") ");
        }
    }
    try out.appendSlice(alloc, model.id);
    if (model.thinking) |level| {
        try out.appendSlice(alloc, " • ");
        if (std.mem.eql(u8, level, "off")) try out.appendSlice(alloc, "thinking ");
        try out.appendSlice(alloc, level);
    }
    return out.toOwnedSlice(alloc);
}

/// The directory line: `<cwd> (<branch>) • <session name>`, dim, cut with
/// "..." when it does not fit. The caller owns the result.
pub fn pwdLine(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    branch: ?[]const u8,
    session_name: ?[]const u8,
    width: usize,
) ![]u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(alloc);
    try text.appendSlice(alloc, cwd);
    if (branch) |b| {
        try text.appendSlice(alloc, " (");
        try text.appendSlice(alloc, b);
        try text.append(alloc, ')');
    }
    if (session_name) |name| {
        if (name.len > 0) {
            try text.appendSlice(alloc, " • ");
            try text.appendSlice(alloc, name);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, FG_DIM);
    if (wmod.visualWidth(text.items) > width) {
        const ellipsis = "...";
        const room = if (width > ellipsis.len) width - ellipsis.len else 0;
        try out.appendSlice(alloc, truncateColumns(text.items, room));
        try out.appendSlice(alloc, truncateColumns(ellipsis, width));
    } else {
        try out.appendSlice(alloc, text.items);
    }
    try out.appendSlice(alloc, RESET);
    return out.toOwnedSlice(alloc);
}

/// The longest prefix of plain `s` that fits `columns`, ending on a character
/// boundary.
fn truncateColumns(s: []const u8, columns: usize) []const u8 {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const end = wmod.nextCharEnd(s, i);
        const w = wmod.visualWidth(s[i..end]);
        if (used + w > columns) break;
        used += w;
        i = end;
    }
    return s[0..i];
}

/// The branch a git HEAD file names: the branch of a symbolic ref, or
/// "detached" for a commit id (pi: getGitBranch). Null for an empty file.
pub fn branchFromHead(head: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, head, " \t\r\n");
    if (s.len == 0) return null;
    const branch_ref = "ref: refs/heads/";
    if (std.mem.startsWith(u8, s, branch_ref)) return s[branch_ref.len..];
    const any_ref = "ref: ";
    if (std.mem.startsWith(u8, s, any_ref)) return s[any_ref.len..];
    return "detached";
}

/// The git branch of the repository containing the absolute path `cwd`:
/// searches upward for `.git`, which is a directory, or in a worktree a file
/// naming the real git directory. Null outside a repository. The caller owns
/// the result.
pub fn readGitBranch(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(cwd)) return null;
    const sep = std.fs.path.sep_str;
    var path_buf: [4096]u8 = undefined;
    var content_buf: [1024]u8 = undefined;
    var dir = cwd;
    while (true) {
        // A regular repository: <dir>/.git/HEAD.
        if (std.fmt.bufPrint(&path_buf, "{s}" ++ sep ++ ".git" ++ sep ++ "HEAD", .{dir})) |head_path| {
            if (readSmallFile(io, head_path, &content_buf)) |head| return dupeBranch(alloc, head);
        } else |_| {}

        // A worktree: <dir>/.git is a file holding "gitdir: <path>".
        if (std.fmt.bufPrint(&path_buf, "{s}" ++ sep ++ ".git", .{dir})) |git_path| {
            if (readSmallFile(io, git_path, &content_buf)) |content| {
                const text = std.mem.trim(u8, content, " \t\r\n");
                const marker = "gitdir: ";
                if (!std.mem.startsWith(u8, text, marker)) return null;
                const git_dir = std.mem.trim(u8, text[marker.len..], " \t");
                var head_path_buf: [4096]u8 = undefined;
                const head_path = (if (std.fs.path.isAbsolute(git_dir))
                    std.fmt.bufPrint(&head_path_buf, "{s}" ++ sep ++ "HEAD", .{git_dir})
                else
                    std.fmt.bufPrint(&head_path_buf, "{s}" ++ sep ++ "{s}" ++ sep ++ "HEAD", .{ dir, git_dir })) catch return null;
                var head_buf: [1024]u8 = undefined;
                const head = readSmallFile(io, head_path, &head_buf) orelse return null;
                return dupeBranch(alloc, head);
            }
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len >= dir.len) return null;
        dir = parent;
    }
}

fn dupeBranch(alloc: std.mem.Allocator, head: []const u8) ?[]u8 {
    const branch = branchFromHead(head) orelse return null;
    return alloc.dupe(u8, branch) catch null;
}

/// Read a file of at most `buf.len` bytes. Null when it cannot be read (it
/// does not exist, or is a directory).
fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer std.Io.File.close(file, io);
    const n = std.Io.File.readPositionalAll(file, io, buf, 0) catch return null;
    return buf[0..n];
}

// ---- tests ----

const t = std.testing;

/// `line` without its escape sequences. Free with the testing allocator.
fn plain(line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(t.allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            i += 2; // ESC [
            while (i < line.len and !(line[i] >= 0x40 and line[i] <= 0x7E)) i += 1;
            i += 1;
        } else {
            try out.append(t.allocator, line[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(t.allocator);
}

fn expectPlain(expected: []const u8, line: []const u8) !void {
    const got = try plain(line);
    defer t.allocator.free(got);
    try t.expectEqualStrings(expected, got);
}

test "formatTokens follows pi's steps" {
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("0", formatTokens(&buf, 0));
    try t.expectEqualStrings("999", formatTokens(&buf, 999));
    try t.expectEqualStrings("1.0k", formatTokens(&buf, 1_000));
    try t.expectEqualStrings("2.7k", formatTokens(&buf, 2_700));
    try t.expectEqualStrings("10k", formatTokens(&buf, 10_000));
    try t.expectEqualStrings("128k", formatTokens(&buf, 128_000));
    try t.expectEqualStrings("1.0M", formatTokens(&buf, 1_000_000));
    try t.expectEqualStrings("2.5M", formatTokens(&buf, 2_500_000));
    try t.expectEqualStrings("12M", formatTokens(&buf, 12_000_000));
}

test "statsLine: a fresh session shows only the context share and the model" {
    const line = try statsLine(t.allocator, .{ .context_window = 128_000 }, .{ .id = "m" }, 30);
    defer t.allocator.free(line);
    try expectPlain("0.0%/128k (auto)             m", line);
}

test "statsLine: every counter, right-aligned model with provider and level" {
    const line = try statsLine(t.allocator, .{
        .input = 2_700,
        .output = 200,
        .cache_read = 80_000,
        .cache_write = 2_100,
        .cache_hit_rate = 87.46,
        .cost = 0.1234,
        .context_tokens = 24_600,
        .context_window = 200_000,
    }, .{ .id = "glm-5", .provider = "zai", .thinking = "high" }, 80);
    defer t.allocator.free(line);
    const got = try plain(line);
    defer t.allocator.free(got);
    try t.expect(std.mem.startsWith(u8, got, "↑2.7k ↓200 R80k W2.1k CH87.5% $0.123 12.3%/200k (auto)  "));
    try t.expect(std.mem.endsWith(u8, got, " (zai) glm-5 • high"));
    try t.expectEqual(@as(u32, 80), wmod.visualWidth(got));
}

test "statsLine: thinking off, no auto-compaction, no provider" {
    const line = try statsLine(t.allocator, .{
        .output = 5,
        .context_window = 1_000,
        .auto_compact = false,
    }, .{ .id = "m", .thinking = "off" }, 40);
    defer t.allocator.free(line);
    const got = try plain(line);
    defer t.allocator.free(got);
    try t.expect(std.mem.startsWith(u8, got, "↓5 0.0%/1.0k "));
    try t.expect(std.mem.endsWith(u8, got, " m • thinking off"));
}

test "statsLine: the context share is colored by how full it is" {
    const calm = try statsLine(t.allocator, .{ .context_tokens = 70, .context_window = 100 }, .{ .id = "m" }, 40);
    defer t.allocator.free(calm);
    try t.expect(std.mem.indexOf(u8, calm, FG_WARNING) == null);
    try t.expect(std.mem.indexOf(u8, calm, FG_ERROR) == null);

    const warm = try statsLine(t.allocator, .{ .context_tokens = 71, .context_window = 100 }, .{ .id = "m" }, 40);
    defer t.allocator.free(warm);
    try t.expect(std.mem.indexOf(u8, warm, FG_WARNING ++ "71.0%/100 (auto)" ++ RESET ++ FG_DIM) != null);

    const full = try statsLine(t.allocator, .{ .context_tokens = 91, .context_window = 100 }, .{ .id = "m" }, 40);
    defer t.allocator.free(full);
    try t.expect(std.mem.indexOf(u8, full, FG_ERROR ++ "91.0%/100 (auto)") != null);
}

test "statsLine: the provider is dropped, then the model cut, when narrow" {
    const stats: Stats = .{ .output = 5, .context_window = 1_000 };
    const model: Model = .{ .id = "long-model-id", .provider = "provider" };

    // "↓5 0.0%/1.0k (auto)" is 19 columns; with 2 of padding the model has 15.
    const no_provider = try statsLine(t.allocator, stats, model, 36);
    defer t.allocator.free(no_provider);
    try expectPlain("↓5 0.0%/1.0k (auto)    long-model-id", no_provider);

    const cut = try statsLine(t.allocator, stats, model, 26);
    defer t.allocator.free(cut);
    try expectPlain("↓5 0.0%/1.0k (auto)  long-", cut);

    const none = try statsLine(t.allocator, stats, model, 19);
    defer t.allocator.free(none);
    try expectPlain("↓5 0.0%/1.0k (auto)", none);
}

test "pwdLine: directory, branch and session name" {
    const full = try pwdLine(t.allocator, "~/p/app", "main", "refactor", 60);
    defer t.allocator.free(full);
    try expectPlain("~/p/app (main) • refactor", full);
    try t.expect(std.mem.startsWith(u8, full, FG_DIM));

    const bare = try pwdLine(t.allocator, "~/p/app", null, null, 60);
    defer t.allocator.free(bare);
    try expectPlain("~/p/app", bare);

    const cut = try pwdLine(t.allocator, "~/projects/a-long-name", "main", null, 12);
    defer t.allocator.free(cut);
    try expectPlain("~/project...", cut);
}

test "branchFromHead" {
    try t.expectEqualStrings("main", branchFromHead("ref: refs/heads/main\n").?);
    try t.expectEqualStrings("feature/x", branchFromHead("ref: refs/heads/feature/x").?);
    try t.expectEqualStrings("detached", branchFromHead("4b825dc642cb6eb9a060e54bf8d69288fbee4904\n").?);
    try t.expect(branchFromHead("  \n") == null);
}
