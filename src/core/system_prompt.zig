//! System prompt construction (Phase D1 + D2), aligned with pi's
//! `core/system-prompt.js` + `core/resource-loader.js`.
//!
//! The prompt is built from ordered, independently replaceable sections:
//!   preamble  (raw, unwrapped)
//!   tools     <tools>…</tools>
//!   rules     <rules>…</rules>
//!   addendum  <addendum>…</addendum>          (only if append_system_prompt set)
//!   project_context <project_context>…</project_context>  (only if context files found)
//!   cwd       <cwd>…</cwd>
//!
//! Context files (AGENTS.override.md / AGENTS.md / CLAUDE.md) are discovered in
//! the agent dir (global) and the cwd ancestor chain (root → cwd).

const std = @import("std");

pub const PREAMBLE =
    \\You are a coding assistant running inside pi, a coding agent harness. Help users inspect files, run commands, and modify code.
;

/// One discovered context file (AGENTS.md / CLAUDE.md / …).
pub const ContextFile = struct {
    path: []const u8, // owned
    content: []const u8, // owned
};

/// A tool name + one-line snippet for the <tools> section.
pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const Options = struct {
    cwd: []const u8,
    tools: []const ToolSnippet,
    append_system_prompt: []const u8 = "",
    /// Full override: replaces preamble + tools + rules (pi's `customPrompt`).
    custom_prompt: ?[]const u8 = null,
    context_files: []const ContextFile = &.{},
    /// Pre-formatted `<available_skills>` block (skills.formatForPrompt), or
    /// null when there are no visible skills. Rendered as a `<skills>` section.
    skills_block: ?[]const u8 = null,
};

const CONTEXT_CANDIDATES = [_][]const u8{ "AGENTS.override.md", "AGENTS.md", "CLAUDE.md" };

/// Build the rendered system prompt text. Returns an owned slice (caller frees).
pub fn buildSystemPrompt(alloc: std.mem.Allocator, opts: Options) ![]u8 {
    // Collect the wrapped sections (in order). Section content pointers must stay
    // valid until `out` is rendered, so owned section strings are freed by a defer
    // at function end (after rendering).
    var sections = std.array_list.Managed(Section).init(alloc);
    defer sections.deinit();

    var tools_str: ?[]u8 = null;
    var rules_str: ?[]u8 = null;
    var pc_str: ?[]u8 = null;
    defer {
        if (tools_str) |s| alloc.free(s);
        if (rules_str) |s| alloc.free(s);
        if (pc_str) |s| alloc.free(s);
    }

    var preamble: []const u8 = PREAMBLE;
    if (opts.custom_prompt) |cp| {
        preamble = cp;
        // custom prompt replaces tools + rules (pi behavior).
    } else {
        tools_str = try buildToolsSection(alloc, opts.tools);
        rules_str = try buildRulesSection(alloc, opts.tools);
        try sections.append(.{ .name = "tools", .content = tools_str.? });
        try sections.append(.{ .name = "rules", .content = rules_str.? });
    }

    if (opts.skills_block) |sb| {
        try sections.append(.{ .name = "skills", .content = sb });
    }

    if (opts.append_system_prompt.len > 0) {
        try sections.append(.{ .name = "addendum", .content = opts.append_system_prompt });
    }

    if (opts.context_files.len > 0) {
        pc_str = try buildProjectContext(alloc, opts.context_files);
        try sections.append(.{ .name = "project_context", .content = pc_str.? });
    }

    try sections.append(.{ .name = "cwd", .content = opts.cwd });

    // Render: preamble, then each section wrapped in <name>…</name>, joined by blank lines.
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice(preamble);
    for (sections.items) |s| {
        try out.appendSlice("\n\n<");
        try out.appendSlice(s.name);
        try out.appendSlice(">\n");
        try out.appendSlice(s.content);
        try out.appendSlice("\n</");
        try out.appendSlice(s.name);
        try out.appendSlice(">");
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const Section = struct {
    name: []const u8,
    content: []const u8,
};

/// Build the full sectioned system prompt from pre-extracted tool snippets,
/// the cwd ancestor context files, and an optional skills block. Shared by
/// startup (main.zig) and `/reload` (tui.zig). Returns an owned slice
/// (caller frees).
pub fn buildFromSnippets(
    alloc: std.mem.Allocator,
    io: std.Io,
    tool_snippets: []const ToolSnippet,
    cwd: []const u8,
    agent_dir: []const u8,
    append_system_prompt: ?[]const u8,
    system_prompt_override: ?[]const u8,
    skills_block: ?[]const u8,
) ![]u8 {
    const ctx_files = try loadProjectContextFiles(alloc, io, cwd, agent_dir);
    defer {
        for (ctx_files) |cf| {
            alloc.free(cf.path);
            alloc.free(cf.content);
        }
        alloc.free(ctx_files);
    }
    return try buildSystemPrompt(alloc, .{
        .cwd = cwd,
        .tools = tool_snippets,
        .append_system_prompt = append_system_prompt orelse "",
        .custom_prompt = system_prompt_override,
        .context_files = ctx_files,
        .skills_block = skills_block,
    });
}

/// buildFromSnippets with project context files disabled (pi --no-context-files).
pub fn buildFromSnippetsNoContext(
    alloc: std.mem.Allocator,
    tool_snippets: []const ToolSnippet,
    cwd: []const u8,
    append_system_prompt: ?[]const u8,
    system_prompt_override: ?[]const u8,
    skills_block: ?[]const u8,
) ![]u8 {
    return try buildSystemPrompt(alloc, .{
        .cwd = cwd,
        .tools = tool_snippets,
        .append_system_prompt = append_system_prompt orelse "",
        .custom_prompt = system_prompt_override,
        .context_files = &.{},
        .skills_block = skills_block,
    });
}

fn buildToolsSection(alloc: std.mem.Allocator, tools: []const ToolSnippet) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    if (tools.len == 0) {
        try out.appendSlice("(none)");
    } else {
        for (tools, 0..) |t, i| {
            if (i > 0) try out.append('\n');
            try out.appendSlice("- ");
            try out.appendSlice(t.name);
            try out.appendSlice(": ");
            try out.appendSlice(t.snippet);
        }
        try out.appendSlice("\n\nAdditional tools may be available.");
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn buildRulesSection(alloc: std.mem.Allocator, tools: []const ToolSnippet) ![]u8 {
    var rules = std.array_list.Managed([]const u8).init(alloc);
    defer rules.deinit();
    var seen = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{});
    defer seen.deinit(alloc);

    const hasBash = hasTool(tools, "bash");
    const hasGrep = hasTool(tools, "grep");
    const hasFind = hasTool(tools, "find");
    const hasLs = hasTool(tools, "ls");
    if (hasBash and !hasGrep and !hasFind and !hasLs) {
        addRuleUnique(alloc, &seen, &rules, "Use bash for file operations like ls, rg, find");
    }
    addRuleUnique(alloc, &seen, &rules, "Be concise in your responses");
    addRuleUnique(alloc, &seen, &rules, "Show file paths clearly when working with files");

    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    for (rules.items, 0..) |r, i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice("- ");
        try out.appendSlice(r);
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn addRuleUnique(
    alloc: std.mem.Allocator,
    seen: *std.StringArrayHashMapUnmanaged(void),
    rules: *std.array_list.Managed([]const u8),
    r: []const u8,
) void {
    const trimmed = std.mem.trim(u8, r, " \t\n");
    if (trimmed.len == 0 or seen.contains(trimmed)) return;
    seen.put(alloc, trimmed, {}) catch return;
    rules.append(trimmed) catch return;
}

fn hasTool(tools: []const ToolSnippet, name: []const u8) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

fn buildProjectContext(alloc: std.mem.Allocator, files: []const ContextFile) ![]u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    try out.appendSlice("Project-specific instructions and guidelines:");
    for (files) |f| {
        try out.appendSlice("\n\n<project_instructions path=\"");
        try out.appendSlice(f.path);
        try out.appendSlice("\">\n");
        try out.appendSlice(f.content);
        try out.appendSlice("\n</project_instructions>");
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Discover context files: global (agent dir) first, then cwd ancestor chain
/// (root → cwd). Returns an owned slice; each ContextFile's path and content are owned.
pub fn loadProjectContextFiles(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, agent_dir: []const u8) ![]ContextFile {
    var result = std.array_list.Managed(ContextFile).init(alloc);
    errdefer result.deinit();
    var seen = try std.StringArrayHashMapUnmanaged(void).init(alloc, &[_][]const u8{}, &[_]void{});
    defer seen.deinit(alloc);

    var buf: [1 << 18]u8 = undefined; // 256 KiB, plenty for AGENTS.md

    // 1. Global context file from the agent dir.
    if (try loadContextFileFromDir(alloc, io, agent_dir, &buf)) |cf| {
        try result.append(cf);
        try seen.put(alloc, cf.path, {});
    }

    // 2. Ancestor chain from cwd up to root (collect cwd → root, then reverse).
    var ancestors = std.array_list.Managed(ContextFile).init(alloc);
    defer ancestors.deinit();

    // Build the list of ancestor dir paths (cwd → root) as owned strings.
    var dirs = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit();
    }
    var cur = try alloc.dupe(u8, cwd);
    while (true) {
        try dirs.append(cur); // dirs now owns `cur`
        const parent = std.fs.path.dirname(cur) orelse break; // sub-slice of cur
        const fixed = std.mem.eql(u8, parent, cur); // reached "/"
        const parent_owned = try alloc.dupe(u8, parent);
        if (fixed) {
            alloc.free(parent_owned); // don't need the duplicate
            break;
        }
        cur = parent_owned; // the previous `cur` is owned by `dirs`
    }

    for (dirs.items) |dir| {
        if (try loadContextFileFromDir(alloc, io, dir, &buf)) |cf| {
            if (!seen.contains(cf.path)) {
                try seen.put(alloc, cf.path, {});
                try ancestors.append(cf);
            }
        }
    }

    // Reverse ancestors → root → cwd order.
    var i: usize = 0;
    var j: usize = ancestors.items.len;
    if (j > 0) j -= 1;
    while (i < j) : ({ i += 1; j -= 1; }) {
        const tmp = ancestors.items[i];
        ancestors.items[i] = ancestors.items[j];
        ancestors.items[j] = tmp;
    }
    for (ancestors.items) |cf| try result.append(cf);

    return result.toOwnedSlice() catch error.OutOfMemory;
}

/// Try to load the first existing context file in `dir`. Returns null if none.
fn loadContextFileFromDir(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, buf: []u8) !?ContextFile {
    for (CONTEXT_CANDIDATES) |name| {
        const path = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
        const data = std.Io.Dir.cwd().readFile(io, path, buf) catch {
            alloc.free(path);
            continue;
        };
        // Strip a leading UTF-8 BOM.
        const content = if (data.len > 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) data[3..] else data;
        const path_owned = try alloc.dupe(u8, path);
        alloc.free(path);
        const content_owned = try alloc.dupe(u8, content);
        return .{ .path = path_owned, .content = content_owned };
    }
    return null;
}

test "buildFromSnippetsNoContext skips context files (pi --no-context-files)" {
    const alloc = std.testing.allocator;
    const sp = try buildFromSnippetsNoContext(alloc, &.{}, "/tmp/proj", null, null, null);
    defer alloc.free(sp);
    try std.testing.expect(std.mem.indexOf(u8, sp, "You are a coding assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<cwd>\n/tmp/proj\n</cwd>") != null);
    // No project context section without context files.
    try std.testing.expect(std.mem.indexOf(u8, sp, "<project_context>") == null);
}

test "buildSystemPrompt basic" {
    const alloc = std.testing.allocator;
    const opts = Options{
        .cwd = "/tmp/proj",
        .tools = &.{
            .{ .name = "read", .snippet = "Read a file" },
            .{ .name = "bash", .snippet = "Run a command" },
        },
    };
    const sp = try buildSystemPrompt(alloc, opts);
    defer alloc.free(sp);
    try std.testing.expect(std.mem.indexOf(u8, sp, "You are a coding assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<tools>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "- read: Read a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<rules>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<cwd>\n/tmp/proj\n</cwd>") != null);
    // bash present but no grep/find/ls → bash rule added
    try std.testing.expect(std.mem.indexOf(u8, sp, "Use bash for file operations") != null);
}

test "buildSystemPrompt with context files + append" {
    const alloc = std.testing.allocator;
    const cf_path = try alloc.dupe(u8, "/x/AGENTS.md");
    const cf_content = try alloc.dupe(u8, "Always run tests.");
    const files = [_]ContextFile{.{ .path = cf_path, .content = cf_content }};
    const opts = Options{
        .cwd = "/x",
        .tools = &.{.{ .name = "grep", .snippet = "Search" }},
        .append_system_prompt = "Extra rule here.",
        .context_files = &files,
    };
    const sp = try buildSystemPrompt(alloc, opts);
    defer alloc.free(sp);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<project_context>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "Always run tests.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "<addendum>\nExtra rule here.\n</addendum>") != null);
    // grep present → no bash rule
    try std.testing.expect(std.mem.indexOf(u8, sp, "Use bash for file operations") == null);
    alloc.free(cf_path);
    alloc.free(cf_content);
}
