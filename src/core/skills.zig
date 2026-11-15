//! Skills (pi core/skills.js) — the Agent Skills specification subset.
//!
//! A skill is a directory containing `SKILL.md` (frontmatter + instructions)
//! plus optional supporting files (scripts/, references/, assets/). At startup
//! each discovered skill's name + description + path are advertised in the
//! system prompt; the full instructions are loaded on demand (the model reads
//! SKILL.md with the read tool) or forced via `/skill:name`.
//!
//! Discovery locations (first discovered wins on a name collision):
//!   user:    <agent_dir>/skills,  <home>/.agents/skills
//!   project: <cwd>/.pi/skills,    <cwd>/.agents/skills
//!
//! Recursive rule (pi loadSkillsFromDirInternal): a directory that contains a
//! SKILL.md is a skill root and is not recursed into; otherwise direct `.md`
//! children at the location root are loaded as standalone skills and subdirs
//! are recursed into (dotfiles and node_modules skipped).
//!
//! Frontmatter is a YAML subset: single-level `key: value` lines. Recognised
//! keys: name, description, disable-model-invocation. Malformed files or
//! skills without a description are skipped (pi: warnings, not errors).

const std = @import("std");

pub const MAX_NAME_LENGTH = 64;
pub const MAX_DESCRIPTION_LENGTH = 1024;

pub const Skill = struct {
    name: []u8, // owned
    description: []u8, // owned
    file_path: []u8, // owned, absolute path to SKILL.md
    base_dir: []u8, // owned, parent directory of SKILL.md
    disable_model_invocation: bool,
};

/// Discover skills from all configured locations. Returns an owned slice.
pub fn discover(
    alloc: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
    cwd: []const u8,
    home_dir: ?[]const u8,
    /// Project-trust gate (pi): when false, project locations (cwd/.pi/skills,
    /// cwd/.agents/skills and cwd ancestors) are skipped — only user-level
    /// skills load.
    include_project: bool,
) ![]Skill {
    // Discovered skills, deduped by name (first wins — pi keeps the first
    // discovered on a collision). A plain list + linear scan keeps ownership
    // simple: every Skill's strings are freed exactly once.
    var collected = std.array_list.Managed(Skill).init(alloc);
    var diags = Diagnostics.init(alloc);
    defer diags.deinit();

    // Ordered location list: user first (so a user skill wins over a project
    // one with the same name — pi keeps the first discovered).
    var locs = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (locs.items) |l| alloc.free(l);
        locs.deinit();
    }
    try addLoc(alloc, &locs, agent_dir, "skills");
    if (home_dir) |h| try addLoc(alloc, &locs, h, ".agents/skills");
    if (include_project) {
        try addLoc(alloc, &locs, cwd, ".pi/skills");
        try addLoc(alloc, &locs, cwd, ".agents/skills");
    }

    for (locs.items) |loc| {
        scanDir(alloc, io, loc, true, &collected, &diags) catch continue;
    }

    // Dedupe in place (first wins), freeing the losers.
    var w: usize = 0;
    var r: usize = 0;
    while (r < collected.items.len) : (r += 1) {
        const s = collected.items[r];
        var dup = false;
        for (collected.items[0..w]) |o| {
            if (std.mem.eql(u8, o.name, s.name)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            diags.collision(s.name, s.file_path);
            freeOne(alloc, s);
            continue;
        }
        collected.items[w] = s;
        w += 1;
    }
    while (collected.items.len > w) {
        _ = collected.pop();
    }

    // Ownership of the surviving items transfers to the caller.
    const result = collected.toOwnedSlice() catch {
        for (collected.items) |s| freeOne(alloc, s);
        collected.deinit();
        return error.OutOfMemory;
    };
    return result;
}

fn addLoc(alloc: std.mem.Allocator, locs: *std.array_list.Managed([]u8), base: []const u8, sub: []const u8) !void {
    const p = std.fs.path.join(alloc, &.{ base, sub }) catch return error.OutOfMemory;
    try locs.append(p);
}

/// Recursively scan `dir` for skills (pi loadSkillsFromDirInternal).
fn scanDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    include_root_files: bool,
    out: *std.array_list.Managed(Skill),
    diags: *Diagnostics,
) !void {
    // Phase 1: a SKILL.md directly in this dir makes it a skill root.
    const skill_md_path = try std.fs.path.join(alloc, &.{ dir, "SKILL.md" });
    defer alloc.free(skill_md_path);
    if (statIsFile(io, skill_md_path)) {
        if (loadSkillFromFile(alloc, io, skill_md_path, dir)) |s| {
            try out.append(s);
        }
        return; // skill root: do not recurse further
    }

    // Phase 2: no SKILL.md → load root .md files + recurse subdirs.
    // (e.name borrows the iterator's buffer, so it is consumed within the
    // loop body and never stored.)
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return;
    defer d.close(io);
    var it = d.iterateAssumeFirstIteration();
    while (it.next(io) catch null) |e| {
        if (std.mem.startsWith(u8, e.name, ".")) continue;
        if (std.mem.eql(u8, e.name, "node_modules")) continue;
        const full = try std.fs.path.join(alloc, &.{ dir, e.name });
        defer alloc.free(full);
        if (e.kind == .directory) {
            try scanDir(alloc, io, full, false, out, diags);
        } else if (include_root_files and (e.kind == .file or e.kind == .sym_link) and std.mem.endsWith(u8, e.name, ".md")) {
            if (statIsFile(io, full)) {
                if (loadSkillFromFile(alloc, io, full, dir)) |s| {
                    try out.append(s);
                }
            }
        }
    }
}

fn statIsFile(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    return (f.stat(io) catch return false).kind == .file;
}

/// Parse one SKILL.md / standalone .md into a Skill (null when invalid).
fn loadSkillFromFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, dir: []const u8) ?Skill {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(raw);

    var fm = Frontmatter.parse(raw, alloc) catch return null;
    defer fm.deinit();
    const fm_name = fm.get("name");
    const fm_desc = fm.get("description");
    const disable = fm.get("disable-model-invocation");

    const has_desc = fm_desc != null and std.mem.trim(u8, fm_desc.?, " \t\r\n").len > 0;
    if (!has_desc) return null; // pi: skills without a description are not loaded

    // name: frontmatter name, else parent dir name.
    const parent = std.fs.path.dirname(path) orelse ".";
    const parent_base = std.fs.path.basename(parent);
    const name = if (fm_name) |n| n else parent_base;

    // Validate name (pi: warnings, but we still load; a name that is empty is fatal).
    if (name.len == 0) return null;

    const desc = std.mem.trim(u8, fm_desc.?, " \t\r\n");
    const desc_owned = alloc.dupe(u8, desc) catch return null;
    errdefer alloc.free(desc_owned);
    const name_owned = alloc.dupe(u8, name) catch return null;
    errdefer alloc.free(name_owned);
    const path_owned = alloc.dupe(u8, path) catch return null;
    errdefer alloc.free(path_owned);
    const dir_owned = alloc.dupe(u8, dir) catch return null;
    errdefer alloc.free(dir_owned);

    return Skill{
        .name = name_owned,
        .description = desc_owned,
        .file_path = path_owned,
        .base_dir = dir_owned,
        .disable_model_invocation = disable != null and std.mem.eql(u8, std.mem.trim(u8, disable.?, " \t\r\n"), "true"),
    };
}

fn freeOne(alloc: std.mem.Allocator, s: Skill) void {
    alloc.free(s.name);
    alloc.free(s.description);
    alloc.free(s.file_path);
    alloc.free(s.base_dir);
}

/// Free a discovered list (and the list itself).
pub fn freeAll(alloc: std.mem.Allocator, skills: []Skill) void {
    for (skills) |s| freeOne(alloc, s);
    alloc.free(skills);
}

/// Validate a skill name per the Agent Skills spec. Returns the number of
/// (static) validation messages; `msg_buf` receives them (up to `msg_buf.len`).
pub fn validateName(name: []const u8, msg_buf: [][]const u8) usize {
    var n: usize = 0;
    if (name.len > MAX_NAME_LENGTH) {
        if (n < msg_buf.len) msg_buf[n] = "name exceeds 64 characters";
        n += 1;
    }
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) {
            if (n < msg_buf.len) msg_buf[n] = "name contains invalid characters";
            n += 1;
            return n;
        }
    }
    if (name.len > 0 and name[0] == '-') {
        if (n < msg_buf.len) msg_buf[n] = "name must not start with a hyphen";
        n += 1;
    }
    if (name.len > 0 and name[name.len - 1] == '-') {
        if (n < msg_buf.len) msg_buf[n] = "name must not end with a hyphen";
        n += 1;
    }
    if (std.mem.indexOf(u8, name, "--") != null) {
        if (n < msg_buf.len) msg_buf[n] = "name must not contain consecutive hyphens";
        n += 1;
    }
    return n;
}

/// Read a skill's instruction body (SKILL.md content after the frontmatter).
/// Returns an owned slice, or null when the file cannot be read.
pub fn loadBody(alloc: std.mem.Allocator, io: std.Io, file_path: []const u8) ?[]u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(raw);
    var fm = Frontmatter.parse(raw, alloc) catch return null;
    defer fm.deinit();
    return alloc.dupe(u8, fm.body) catch null;
}

/// Format the `<available_skills>` block (pi formatSkillsForPrompt). Returns an
/// owned slice, or null when there are no visible (non-disabled) skills.
pub fn formatForPrompt(alloc: std.mem.Allocator, skills: []const Skill) !?[]u8 {
    var visible = std.array_list.Managed(*const Skill).init(alloc);
    defer visible.deinit();
    for (skills) |*s| {
        if (!s.disable_model_invocation) try visible.append(s);
    }
    if (visible.items.len == 0) return null;
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice("The following skills provide specialized instructions for specific tasks.");
    try out.appendSlice("\nUse the read tool to load a skill's file when the task matches its description.");
    try out.appendSlice("\nResolve relative paths against the skill's directory (parent of SKILL.md). Use absolute paths in tool calls.");
    try out.appendSlice("\n\n<available_skills>");
    for (visible.items) |s| {
        try out.appendSlice("\n  <skill>");
        try out.appendSlice("\n    <name>");
        try escapeXml(&out, s.name);
        try out.appendSlice("</name>");
        try out.appendSlice("\n    <description>");
        try escapeXml(&out, s.description);
        try out.appendSlice("</description>");
        try out.appendSlice("\n    <location>");
        try escapeXml(&out, s.file_path);
        try out.appendSlice("</location>");
        try out.appendSlice("\n  </skill>");
    }
    try out.appendSlice("\n</available_skills>");
    return try out.toOwnedSlice();
}

fn escapeXml(out: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice("&amp;"),
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            '"' => try out.appendSlice("&quot;"),
            '\'' => try out.appendSlice("&apos;"),
            else => try out.append(c),
        }
    }
}

const Diagnostics = struct {
    alloc: std.mem.Allocator,
    list: std.array_list.Managed([]u8),

    fn init(alloc: std.mem.Allocator) Diagnostics {
        return .{ .alloc = alloc, .list = .init(alloc) };
    }
    fn deinit(self: *Diagnostics) void {
        for (self.list.items) |m| self.alloc.free(m);
        self.list.deinit();
    }
    fn collision(self: *Diagnostics, name: []const u8, path: []const u8) void {
        const m = std.fmt.allocPrint(self.alloc, "skill name \"{s}\" collision at {s}", .{ name, path }) catch return;
        self.list.append(m) catch self.alloc.free(m);
    }
};

// ── Minimal YAML-subset frontmatter parser ───────────────────────────
//
// Handles a leading `---\n ... \n---\n` block of single-level `key: value`
// pairs. Values are taken verbatim (trimmed); no nesting, no multi-line.

pub const Frontmatter = struct {
    alloc: std.mem.Allocator,
    pairs: std.StringArrayHashMapUnmanaged([]const u8),
    body: []const u8,

    /// Parse frontmatter from raw content. The returned Frontmatter borrows
    /// `raw` for the body but owns the key/value strings.
    pub fn parse(raw: []const u8, alloc: std.mem.Allocator) !Frontmatter {
        var fm = Frontmatter{
            .alloc = alloc,
            .pairs = try .init(alloc, &[_][]const u8{}, &[_][]const u8{}),
            .body = raw,
        };
        var i: usize = 0;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\r' or raw[i] == '\n')) i += 1;
        if (i + 3 > raw.len or !std.mem.eql(u8, raw[i .. i + 3], "---")) return fm;
        // find the closing "\n---"
        var j: usize = i + 3;
        var close: ?usize = null;
        while (j < raw.len) : (j += 1) {
            if (raw[j] == '\n' and j + 3 <= raw.len and std.mem.eql(u8, raw[j + 1 .. j + 4], "---")) {
                close = j;
                break;
            }
        }
        if (close == null) {
            // unterminated frontmatter: treat whole content as body (empty map).
            return fm;
        }
        const block = raw[i + 3 .. close.?];
        const after = close.? + 4;
        var body_start = after;
        while (body_start < raw.len and (raw[body_start] == '\r' or raw[body_start] == '\n')) body_start += 1;
        fm.body = raw[body_start..];

        // Parse `key: value` lines.
        var line_start: usize = 0;
        var k: usize = 0;
        var lines = std.array_list.Managed([]const u8).init(alloc);
        defer lines.deinit();
        while (k <= block.len) : (k += 1) {
            if (k == block.len or block[k] == '\n') {
                const ls = line_start;
                var le = k;
                if (le > ls and block[le - 1] == '\r') le -= 1;
                lines.append(block[ls..le]) catch break;
                line_start = k + 1;
            }
        }
        for (lines.items) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (t.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
            const key = std.mem.trim(u8, t[0..colon], " \t");
            const val_raw = std.mem.trim(u8, t[colon + 1 ..], " \t");
            var val = val_raw;
            // strip a surrounding matching pair of quotes
            if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
                val = val[1 .. val.len - 1];
            }
            const key_owned = alloc.dupe(u8, key) catch continue;
            errdefer alloc.free(key_owned);
            const val_owned = alloc.dupe(u8, val) catch {
                alloc.free(key_owned);
                continue;
            };
            fm.pairs.put(alloc, key_owned, val_owned) catch {
                alloc.free(key_owned);
                alloc.free(val_owned);
            };
        }
        return fm;
    }

    pub fn get(self: *const Frontmatter, key: []const u8) ?[]const u8 {
        return self.pairs.get(key);
    }

    pub fn deinit(self: *Frontmatter) void {
        var it = self.pairs.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.pairs.deinit(self.alloc);
    }
};

test "frontmatter parse" {
    const alloc = std.testing.allocator;
    const raw = "---\nname: pdf-tools\ndescription: Extract text.\ndisable-model-invocation: true\n---\n\n# Body here";
    var fm = try Frontmatter.parse(raw, alloc);
    defer fm.deinit();
    try std.testing.expectEqualStrings("pdf-tools", fm.get("name").?);
    try std.testing.expectEqualStrings("Extract text.", fm.get("description").?);
    try std.testing.expectEqualStrings("true", fm.get("disable-model-invocation").?);
    try std.testing.expect(std.mem.indexOf(u8, fm.body, "# Body here") != null);
    try std.testing.expect(fm.get("missing") == null);
}

test "frontmatter no block" {
    const alloc = std.testing.allocator;
    const raw = "# Just a heading\nbody";
    var fm = try Frontmatter.parse(raw, alloc);
    defer fm.deinit();
    try std.testing.expectEqualStrings("# Just a heading\nbody", fm.body);
    try std.testing.expect(fm.get("name") == null);
}

test "frontmatter quoted values" {
    const alloc = std.testing.allocator;
    const raw = "---\nname: \"my-skill\"\ndescription: 'a: b'\n---\nbody";
    var fm = try Frontmatter.parse(raw, alloc);
    defer fm.deinit();
    try std.testing.expectEqualStrings("my-skill", fm.get("name").?);
    try std.testing.expectEqualStrings("a: b", fm.get("description").?);
}

test "validateName" {
    var msgs: [8][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), validateName("pdf-tools", &msgs));
    try std.testing.expectEqual(@as(usize, 1), validateName("-bad", &msgs));
    try std.testing.expectEqual(@as(usize, 1), validateName("bad-", &msgs));
    try std.testing.expectEqual(@as(usize, 1), validateName("a--b", &msgs));
    try std.testing.expectEqual(@as(usize, 1), validateName("UPPER", &msgs));
    const long = try std.mem.concat(std.testing.allocator, u8, &.{ "a", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
    defer std.testing.allocator.free(long);
    try std.testing.expect(validateName(long, &msgs) > 0);
}

test "formatForPrompt" {
    const alloc = std.testing.allocator;
    const name = try alloc.dupe(u8, "pdf-tools");
    const desc = try alloc.dupe(u8, "Extract <text> & tables.");
    const path = try alloc.dupe(u8, "/x/pdf-tools/SKILL.md");
    const dir = try alloc.dupe(u8, "/x/pdf-tools");
    const hidden_name = try alloc.dupe(u8, "hidden");
    const hidden_desc = try alloc.dupe(u8, "no");
    const hidden_path = try alloc.dupe(u8, "/x/h/SKILL.md");
    const hidden_dir = try alloc.dupe(u8, "/x/h");
    var skills = [_]Skill{
        .{ .name = name, .description = desc, .file_path = path, .base_dir = dir, .disable_model_invocation = false },
        .{ .name = hidden_name, .description = hidden_desc, .file_path = hidden_path, .base_dir = hidden_dir, .disable_model_invocation = true },
    };
    const block = try formatForPrompt(alloc, &skills) orelse unreachable;
    defer alloc.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "<name>pdf-tools</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Extract &lt;text&gt; &amp; tables.") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "hidden") == null); // disabled excluded
    // cleanup
    for (skills) |s| freeOne(alloc, s);
    // empty → null
    try std.testing.expect(try formatForPrompt(alloc, &.{}) == null);
}

test "discover scans agent + project dirs recursively" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Unique temp root so parallel test runs don't collide.
    const root = try alloc.dupe(u8, "/tmp/rpi-skill-test");
    defer alloc.free(root);
    // Clean any stale run, then build the tree.
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const agent_skills = try std.fs.path.join(alloc, &.{ root, "agent", "skills" });
    defer alloc.free(agent_skills);
    const proj_skills = try std.fs.path.join(alloc, &.{ root, "proj", ".pi", "skills" });
    defer alloc.free(proj_skills);

    // agent/skills/pdf-tools/SKILL.md
    try writeFile(alloc, io, try join3(alloc, root, "agent/skills/pdf-tools", "SKILL.md"),
        "---\nname: pdf-tools\ndescription: Extract text from PDFs.\n---\n\n# PDF tools\nBody.");
    // agent/skills/nested/deep/inner/SKILL.md (recursive discovery)
    try writeFile(alloc, io, try join3(alloc, root, "agent/skills/nested/deep/inner", "SKILL.md"),
        "---\nname: deep-skill\ndescription: Found by recursion.\n---\nbody");
    // agent/skills/nodesc/SKILL.md (no description → skipped)
    try writeFile(alloc, io, try join3(alloc, root, "agent/skills/nodesc", "SKILL.md"),
        "---\nname: nodesc\n---\nno description");
    // agent/skills/hidden-skill/SKILL.md (disable-model-invocation)
    try writeFile(alloc, io, try join3(alloc, root, "agent/skills/hidden-skill", "SKILL.md"),
        "---\nname: hidden-skill\ndescription: Hidden.\ndisable-model-invocation: true\n---\nbody");
    // proj/.pi/skills/proj-skill/SKILL.md
    try writeFile(alloc, io, try join3(alloc, root, "proj/.pi/skills/proj-skill", "SKILL.md"),
        "---\nname: proj-skill\ndescription: Project skill.\n---\nbody");

    const agent_dir = try std.fs.path.join(alloc, &.{ root, "agent" });
    defer alloc.free(agent_dir);
    const cwd = try std.fs.path.join(alloc, &.{ root, "proj" });
    defer alloc.free(cwd);

    const found = try discover(alloc, io, agent_dir, cwd, null, true);
    defer freeAll(alloc, found);

    // Expect exactly: pdf-tools, deep-skill, hidden-skill, proj-skill (nodesc skipped).
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings("Extract text from PDFs.", findSkill(found, "pdf-tools").?.description);
    try std.testing.expectEqualStrings("Found by recursion.", findSkill(found, "deep-skill").?.description);
    try std.testing.expect(findSkill(found, "hidden-skill").?.disable_model_invocation);
    try std.testing.expectEqualStrings("Project skill.", findSkill(found, "proj-skill").?.description);
    // nodesc must be absent.
    var has_nodesc = false;
    for (found) |s| {
        if (std.mem.eql(u8, s.name, "nodesc")) has_nodesc = true;
    }
    try std.testing.expect(!has_nodesc);
}

/// Write `content` to `path`, creating parent dirs. `path` is an owned slice
/// (joined in the caller) and is freed here.
fn writeFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    defer alloc.free(path);
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    try f.writePositionalAll(io, content, 0);
    f.close(io);
}

fn join3(alloc: std.mem.Allocator, root: []const u8, mid: []const u8, leaf: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, mid, leaf });
}

fn findSkill(found: []const Skill, name: []const u8) ?Skill {
    for (found) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}
