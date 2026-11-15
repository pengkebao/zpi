//! Prompt templates (pi core/prompt-templates.js).
//!
//! Discovery: `<agent-dir>/prompts/*.md` (user) + `<cwd>/.pi/prompts/*.md`
//! (project). Template name = file stem. Frontmatter (`---` block) is
//! stripped; `description` / `argument-hint` are recognised but only used
//! for display.
//!
//! Expansion: a submission starting with `/name args...` whose name matches
//! a template is replaced by the template body with argument placeholders
//! substituted:
//!   $1..$n positional, $@ / $ARGUMENTS = all args joined,
//!   ${N:-default} / ${@:-default} = arg with fallback,
//!   ${@:N} / ${@:N:L} bash-style slicing.
//! Non-matching / non-slash text is returned unchanged.

const std = @import("std");

pub const Template = struct {
    name: []u8,
    content: []u8, // body after frontmatter strip (owned)
    description: []u8, // frontmatter description or first line (owned)
    /// Autocomplete source tag scope: "u" user (~/.pi/agent) or "p" project
    /// (pi getAutocompleteSourceTag renders it as `[u]`/`[p]` prefix).
    scope: []const u8 = "p",
};

/// Discover templates: agent_dir/prompts + cwd/.pi/prompts. Later entries
/// (project) win on name clash (they are found first during lookup).
pub fn discover(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
    cwd: []const u8,
    /// Project-trust gate (pi): when false, cwd/.pi/prompts is skipped.
    include_project: bool,
) []Template {
    var list = std.array_list.Managed(Template).init(alloc);
    // Project first so user-level entries cannot shadow project ones.
    if (include_project) {
        const proj = std.fmt.allocPrint(alloc, "{s}/.pi/prompts", .{cwd}) catch return list.toOwnedSlice() catch return &.{};
        defer alloc.free(proj);
        addDir(&list, alloc, io, proj, "p");
    }
    const glob = std.fmt.allocPrint(alloc, "{s}/prompts", .{agent_dir}) catch return list.toOwnedSlice() catch return &.{};
    defer alloc.free(glob);
    addDir(&list, alloc, io, glob, "u");
    return list.toOwnedSlice() catch return &.{};
}

fn addDir(list: *std.array_list.Managed(Template), alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8, scope: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".md")) continue;
        const stem = name[0 .. name.len - 3];
        if (stem.len == 0) continue;
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name }) catch continue;
        defer alloc.free(path);
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 * 1024)) catch continue;
        const body = stripFrontmatter(raw);
        const t = Template{
            .name = alloc.dupe(u8, stem) catch {
                alloc.free(raw);
                continue;
            },
            .content = alloc.dupe(u8, body) catch {
                alloc.free(raw);
                continue;
            },
            .description = firstLine(body, alloc) catch alloc.dupe(u8, "") catch "",
            .scope = scope,
        };
        list.append(t) catch {
            alloc.free(t.name);
            alloc.free(t.content);
            alloc.free(t.description);
        };
        alloc.free(raw);
    }
}

/// Strip a leading `---\n...\n---\n` frontmatter block.
pub fn stripFrontmatter(raw: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return raw;
    const line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse return raw;
    const rest = trimmed[line_end..];
    const close = std.mem.indexOf(u8, rest, "\n---") orelse return raw;
    var after = rest[close + 4 ..];
    after = std.mem.trimStart(u8, after, "\r\n");
    return after;
}

fn firstLine(body: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var line: []const u8 = body;
    while (true) {
        const idx = std.mem.indexOfAny(u8, line, "\r\n");
        const cur = if (idx) |k| line[0..k] else line;
        const t = std.mem.trim(u8, cur, " \t");
        if (t.len > 0) {
            const take = @min(t.len, 60);
            const suffix: []const u8 = if (t.len > 60) "..." else "";
            return std.mem.concat(alloc, u8, &.{ t[0..take], suffix });
        }
        if (idx == null) return alloc.dupe(u8, "");
        line = line[idx.? + 1 ..];
    }
}

/// Free a discovered template list.
pub fn freeAll(alloc: std.mem.Allocator, templates: []Template) void {
    for (templates) |t| {
        alloc.free(t.name);
        alloc.free(t.content);
        alloc.free(t.description);
    }
    alloc.free(templates);
}

/// Bash-style argument splitting honouring double/single quotes (pi
/// parseCommandArgs): quoted empty strings are kept as arguments.
pub fn parseCommandArgs(alloc: std.mem.Allocator, args_string: []const u8) [][]const u8 {
    var args = std.array_list.Managed([]const u8).init(alloc);
    defer args.deinit();
    var current = std.array_list.Managed(u8).init(alloc);
    defer current.deinit();
    var has_token = false;
    var in_quote: ?u8 = null;
    var i: usize = 0;
    while (i < args_string.len) : (i += 1) {
        const ch = args_string[i];
        if (in_quote) |q| {
            if (ch == q) {
                in_quote = null;
            } else {
                current.append(ch) catch {};
            }
        } else if (ch == '"' or ch == '\'') {
            in_quote = ch;
            has_token = true;
        } else if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            if (has_token) {
                const dup = alloc.dupe(u8, current.items) catch {
                    current.clearRetainingCapacity();
                    has_token = false;
                    continue;
                };
                args.append(dup) catch alloc.free(dup);
                current.clearRetainingCapacity();
                has_token = false;
            }
        } else {
            current.append(ch) catch {};
            has_token = true;
        }
    }
    if (has_token) {
        if (alloc.dupe(u8, current.items)) |dup| {
            args.append(dup) catch alloc.free(dup);
        } else |_| {}
    }
    return args.toOwnedSlice() catch &.{};
}

pub fn freeArgs(alloc: std.mem.Allocator, args: [][]const u8) void {
    for (args) |a| alloc.free(a);
    alloc.free(args);
}

/// Substitute argument placeholders (pi substituteArgs). Writes into an
/// output list; returns allocation errors.
pub fn substituteArgs(out: *std.array_list.Managed(u8), alloc: std.mem.Allocator, content: []const u8, args: []const []const u8) !void {
    const all_args = try std.mem.join(alloc, " ", args);
    defer alloc.free(all_args);
    var i: usize = 0;
    while (i < content.len) {
        const ch = content[i];
        if (ch != '$') {
            try out.append(ch);
            i += 1;
            continue;
        }
        // ${N:-default} / ${@:-default} / ${ARGUMENTS:-default}
        // ${@:N} / ${@:N:L}
        // $ARGUMENTS / $@ / $N
        if (i + 1 < content.len and content[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, content, i, '}')) |close| {
                const inner = content[i + 2 .. close];
                if (parseBraced(inner)) |spec| {
                    switch (spec.kind) {
                        .default_value => {
                            const idx: ?usize = if (spec.target_at) |t| blk: {
                                if (t == 0) break :blk null; // "@" / ARGUMENTS
                                break :blk t - 1;
                            } else null;
                            const val: []const u8 = if (spec.target_at != null and spec.target_at.? == 0)
                                all_args
                            else if (idx != null and idx.? < args.len) args[idx.?] else "";
                            if (val.len > 0) {
                                try out.appendSlice(val);
                            } else {
                                try out.appendSlice(spec.extra);
                            }
                        },
                        .slice => {
                            var start: usize = if (spec.target_at) |t| t - 1 else 0;
                            if (start == 0 and spec.target_at == null) start = 0;
                            // user 1-indexed; 0 treated as 1 (bash convention)
                            if (spec.target_at != null and spec.target_at.? == 0) start = 0;
                            if (spec.slice_len) |l| {
                                const end = @min(args.len, start + l);
                                const joined = try std.mem.join(alloc, " ", args[@min(start, args.len)..end]);
                                defer alloc.free(joined);
                                try out.appendSlice(joined);
                            } else {
                                const s0 = @min(start, args.len);
                                const joined = try std.mem.join(alloc, " ", args[s0..]);
                                defer alloc.free(joined);
                                try out.appendSlice(joined);
                            }
                        },
                    }
                    i = close + 1;
                    continue;
                }
            }
            // not a recognised braced form: literal
            try out.append(ch);
            i += 1;
            continue;
        }
        if (i + 1 < content.len and (content[i + 1] == '@')) {
            try out.appendSlice(all_args);
            i += 2;
            continue;
        }
        if (i + 9 < content.len and std.mem.eql(u8, content[i + 1 .. i + 10], "ARGUMENTS")) {
            try out.appendSlice(all_args);
            i += 10;
            continue;
        }
        if (i + 1 < content.len and content[i + 1] >= '1' and content[i + 1] <= '9') {
            var j = i + 1;
            var num: usize = 0;
            while (j < content.len and content[j] >= '0' and content[j] <= '9') : (j += 1) {
                num = num * 10 + (content[j] - '0');
            }
            const idx = num - 1;
            if (idx < args.len) {
                try out.appendSlice(args[idx]);
            }
            i = j;
            continue;
        }
        try out.append(ch);
        i += 1;
    }
}

const BracedSpec = struct {
    kind: enum { default_value, slice },
    /// 0 = "@" / ARGUMENTS; N = positional 1-indexed.
    target_at: ?usize,
    extra: []const u8, // default value for .default_value
    slice_len: ?usize,
};

/// Parse the inside of `${...}`: `N:-default` | `@:-default` | `ARGUMENTS:-default` | `@:N[:L]`.
fn parseBraced(inner: []const u8) ?BracedSpec {
    // ${@:N[:L]}
    if (std.mem.startsWith(u8, inner, "@:")) {
        const rest = inner[2..];
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const start_s = if (colon) |c| rest[0..c] else rest;
        const start = std.fmt.parseInt(usize, start_s, 10) catch return null;
        var len: ?usize = null;
        if (colon) |c| {
            len = std.fmt.parseInt(usize, rest[c + 1 ..], 10) catch return null;
        }
        return .{ .kind = .slice, .target_at = start, .extra = "", .slice_len = len };
    }
    // ${X:-default}
    if (std.mem.indexOf(u8, inner, ":-")) |di| {
        const target = inner[0..di];
        const default_value = inner[di + 2 ..];
        var at: usize = 0;
        if (std.mem.eql(u8, target, "@") or std.mem.eql(u8, target, "ARGUMENTS")) {
            at = 0;
        } else {
            at = std.fmt.parseInt(usize, target, 10) catch return null;
        }
        return .{ .kind = .default_value, .target_at = at, .extra = default_value, .slice_len = null };
    }
    return null;
}

/// Expand a `/name args...` submission against discovered templates (pi
/// expandPromptTemplate): non-slash text and unknown names are returned
/// unchanged (owned copy).
pub fn expand(alloc: std.mem.Allocator, text: []const u8, templates: []const Template) ![]u8 {
    if (!std.mem.startsWith(u8, text, "/")) return alloc.dupe(u8, text);
    // ^\/([^\s]+)(?:\s+([\s\S]*))?$
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (!std.mem.startsWith(u8, trimmed, "/")) return alloc.dupe(u8, text);
    const rest = trimmed[1..];
    var name_end: usize = 0;
    while (name_end < rest.len and rest[name_end] != ' ' and rest[name_end] != '\t' and rest[name_end] != '\r' and rest[name_end] != '\n') : (name_end += 1) {}
    const name = rest[0..name_end];
    const args_string = std.mem.trim(u8, rest[@min(name_end + 1, rest.len)..], " \t");
    for (templates) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            const args = parseCommandArgs(alloc, args_string);
            defer freeArgs(alloc, args);
            var out = std.array_list.Managed(u8).init(alloc);
            errdefer out.deinit();
            try substituteArgs(&out, alloc, t.content, args);
            return out.toOwnedSlice();
        }
    }
    return alloc.dupe(u8, text);
}
