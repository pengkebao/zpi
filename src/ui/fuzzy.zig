//! Fuzzy matching for completion menus — a port of pi-tui's `fuzzy.js`
//! (MIT, @earendil-works/pi-tui). Matches if all query characters appear in
//! order (not necessarily consecutive); lower score = better match.
//!
//! pi scores are floating point; here they are scaled by 10 into integers
//! (a linear transform, so ordering is preserved exactly):
//!   consecutive-match bonus  -5/char  -> -50/char
//!   gap penalty              +2/char  -> +20/char
//!   word-boundary bonus      -10      -> -100
//!   position penalty         +0.1/idx -> +1/idx
//!   exact match              -100     -> -1000
//!   letters/digits swap      +5       -> +50

const std = @import("std");

const WORD_BOUNDARIES = " \t-_./:";

fn isWordBoundary(c: u8) bool {
    return std.mem.indexOfScalar(u8, WORD_BOUNDARIES, c) != null;
}

/// Score one aligned set of match positions (pi scorePositions).
fn scorePositions(text_lower: []const u8, positions: []const usize) i64 {
    var score: i64 = 0;
    var last_match_index: ?usize = null;
    var consecutive: usize = 0;
    for (positions) |i| {
        if (last_match_index) |last| {
            if (last + 1 == i) {
                consecutive += 1;
                score -= @intCast(consecutive * 50);
            } else {
                consecutive = 0;
                score += @intCast((i - last - 1) * 20);
            }
        } else {
            consecutive = 0;
        }
        // Reward word-boundary matches.
        if (i == 0 or isWordBoundary(text_lower[i - 1])) score -= 100;
        // Slight penalty for later matches (pi: i * 0.1, scaled x10).
        score += @intCast(i);
        last_match_index = i;
    }
    return score;
}

/// Greedy per-character alignment plus best-contiguous-occurrence refinement
/// (pi matchQuery). `i64` score or null when the query cannot match.
fn matchQuery(query_lower: []const u8, text_lower: []const u8, positions: []usize) ?i64 {
    if (query_lower.len == 0) return 0;
    if (query_lower.len > text_lower.len) return null;
    var last: usize = 0;
    for (query_lower, 0..) |qc, qi| {
        const idx = std.mem.indexOfScalarPos(u8, text_lower, last, qc) orelse return null;
        positions[qi] = idx;
        last = idx + 1;
    }
    var score = scorePositions(text_lower, positions);
    // The greedy alignment can scatter the query over an earlier, unrelated
    // part of the text ("opus" matching "openrouter/.../claude-opus" from the
    // "openrouter" letters). Also score every contiguous occurrence and keep
    // the best alignment.
    var start_opt = std.mem.indexOf(u8, text_lower, query_lower);
    while (start_opt) |start| {
        for (0..query_lower.len) |k| positions[k] = start + k;
        score = @min(score, scorePositions(text_lower, positions));
        start_opt = std.mem.indexOfPos(u8, text_lower, start + 1, query_lower);
    }
    if (std.mem.eql(u8, query_lower, text_lower)) score -= 1000;
    return score;
}

/// A query of the form "letters+digits" (or the reverse) also tries the
/// swapped order ("m3" matches "3m") with a +5 (pi: +50 scaled) penalty.
/// pi requires both a letters and a digits group (two regexes).
fn swappedQuery(alloc: std.mem.Allocator, query_lower: []const u8) ?[]u8 {
    // letters+digits (pi alphaNumericMatch) -> digits+letters
    var i: usize = 0;
    while (i < query_lower.len and query_lower[i] >= 'a' and query_lower[i] <= 'z') i += 1;
    const a_end = i;
    while (i < query_lower.len and query_lower[i] >= '0' and query_lower[i] <= '9') i += 1;
    if (i == query_lower.len and a_end > 0 and i > a_end) {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ query_lower[a_end..], query_lower[0..a_end] }) catch null;
    }
    // digits+letters (pi numericAlphaMatch) -> letters+digits
    i = 0;
    while (i < query_lower.len and query_lower[i] >= '0' and query_lower[i] <= '9') i += 1;
    const c_end = i;
    while (i < query_lower.len and query_lower[i] >= 'a' and query_lower[i] <= 'z') i += 1;
    if (i == query_lower.len and c_end > 0 and i > c_end) {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ query_lower[c_end..], query_lower[0..c_end] }) catch null;
    }
    return null;
}

pub fn fuzzyMatch(alloc: std.mem.Allocator, query: []const u8, text: []const u8) ?i64 {
    const q = std.ascii.allocLowerString(alloc, query) catch return null;
    defer alloc.free(q);
    const t = std.ascii.allocLowerString(alloc, text) catch return null;
    defer alloc.free(t);
    var positions: [128]usize = undefined;
    if (q.len > positions.len) return null;
    if (matchQuery(q, t, positions[0..q.len])) |s| return s;
    const swapped = swappedQuery(alloc, q) orelse return null;
    defer alloc.free(swapped);
    if (swapped.len > positions.len) return null;
    if (matchQuery(swapped, t, positions[0..swapped.len])) |s| return s + 50;
    return null;
}

/// Filter and sort item indices by fuzzy match quality (best first).
/// Supports whitespace- and slash-separated tokens: all tokens must match.
/// Ties keep the input order (stable insertion sort; pi's sort is also
/// effectively stable for these small lists). Returns an owned slice of
/// indices into `items`; empty query keeps every item in order.
pub fn fuzzyFilter(
    alloc: std.mem.Allocator,
    count: usize,
    query: []const u8,
    context: anytype,
    comptime getText: fn (@TypeOf(context), usize) []const u8,
) ![]usize {
    var trimmed = query;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\t')) trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) {
        const all = try alloc.alloc(usize, count);
        for (0..count) |i| all[i] = i;
        return all;
    }

    // Tokenize on [\s/]+.
    var tokens_buf: [16][]const u8 = undefined;
    var ntokens: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t/");
    while (it.next()) |tok| {
        if (ntokens >= tokens_buf.len) break;
        tokens_buf[ntokens] = tok;
        ntokens += 1;
    }
    if (ntokens == 0) {
        const all = try alloc.alloc(usize, count);
        for (0..count) |i| all[i] = i;
        return all;
    }
    const tokens = tokens_buf[0..ntokens];

    const Scored = struct { idx: usize, score: i64 };
    var matched = try std.ArrayListUnmanaged(Scored).initCapacity(alloc, count);
    defer matched.deinit(alloc);
    for (0..count) |i| {
        const text = getText(context, i);
        var total: i64 = 0;
        var all = true;
        for (tokens) |tok| {
            if (fuzzyMatch(alloc, tok, text)) |s| {
                total += s;
            } else {
                all = false;
                break;
            }
        }
        if (all) try matched.append(alloc, .{ .idx = i, .score = total });
    }
    // Stable insertion sort, ascending score (lower = better).
    var i: usize = 1;
    while (i < matched.items.len) : (i += 1) {
        var j = i;
        const cur = matched.items[i];
        while (j > 0 and matched.items[j - 1].score > cur.score) : (j -= 1) {
            matched.items[j] = matched.items[j - 1];
        }
        matched.items[j] = cur;
    }
    var out = try std.ArrayListUnmanaged(usize).initCapacity(alloc, matched.items.len);
    errdefer out.deinit(alloc);
    for (matched.items) |m| try out.append(alloc, m.idx);
    return out.toOwnedSlice(alloc);
}

/// pi editor's initial-selection rule: exact `prefix === value` wins, then
/// the first item whose value starts with the prefix, else -1 (keep index 0).
pub fn bestMatchIndex(items_count: usize, prefix: []const u8, context: anytype, comptime getValue: fn (@TypeOf(context), usize) []const u8) ?usize {
    if (prefix.len == 0) return null;
    var first_prefix: ?usize = null;
    for (0..items_count) |i| {
        const value = getValue(context, i);
        if (std.mem.eql(u8, value, prefix)) return i;
        if (first_prefix == null and std.mem.startsWith(u8, value, prefix)) first_prefix = i;
    }
    return first_prefix;
}

// ---- tests ----

const testing = std.testing;

const t_items = [_][]const u8{ "settings", "model", "tree", "thinking", "scoped-models", "session" };

fn getTextSimple(_: void, i: usize) []const u8 {
    return t_items[i];
}

test "fuzzyFilter empty query keeps order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const idx = try fuzzyFilter(arena.allocator(), t_items.len, "", {}, getTextSimple);
    try testing.expectEqual(@as(usize, 6), idx.len);
    try testing.expectEqual(@as(usize, 0), idx[0]);
}

test "fuzzyFilter prefix match ranks exact-ish first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // "se" hits settings/session; "settings" has the word-boundary bonus and
    // shorter distance, so it sorts before "session".
    const idx = try fuzzyFilter(alloc, t_items.len, "se", {}, getTextSimple);
    try testing.expect(idx.len >= 2);
    try testing.expectEqualStrings("settings", t_items[idx[0]]);
    // "sett" matches only settings.
    const only = try fuzzyFilter(alloc, t_items.len, "sett", {}, getTextSimple);
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("settings", t_items[only[0]]);
}

test "fuzzyFilter requires all tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const idx = try fuzzyFilter(alloc, t_items.len, "se mo", {}, getTextSimple);
    // Both tokens must match one item: only "scoped-models" has a "se"
    // subsequence (scop-e-d) and a "mo" one.
    try testing.expectEqual(@as(usize, 1), idx.len);
    try testing.expectEqualStrings("scoped-models", t_items[idx[0]]);
}

test "fuzzyMatch exact beats scattered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const exact = fuzzyMatch(alloc, "model", "model").?;
    const scattered = fuzzyMatch(alloc, "model", "scoped-models").?;
    try testing.expect(exact < scattered);
}

test "fuzzyMatch no match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?i64, null), fuzzyMatch(arena.allocator(), "zz", "model"));
}

test "fuzzyMatch letters/digits swap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const direct = fuzzyMatch(alloc, "m3", "m3").?;
    const swapped = fuzzyMatch(alloc, "3m", "m3");
    try testing.expect(swapped != null);
    try testing.expect(direct < swapped.?);
}

test "bestMatchIndex exact then prefix" {
    const vals = [_][]const u8{ "zai/glm-5.3", "google/gemini" };
    const Ctx = struct {
        fn get(_: @This(), i: usize) []const u8 {
            return vals[i];
        }
    };
    const ctx = Ctx{};
    try testing.expectEqual(@as(?usize, 0), bestMatchIndex(2, "zai/glm-5.3", ctx, Ctx.get));
    try testing.expectEqual(@as(?usize, 1), bestMatchIndex(2, "google", ctx, Ctx.get));
    try testing.expectEqual(@as(?usize, null), bestMatchIndex(2, "anthropic", ctx, Ctx.get));
}
