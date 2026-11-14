//! rpi-zig — A coding agent CLI written in Zig.
//! Mirrors the architecture of pi-rust (Rust port of pi coding agent).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const ai = @import("src/ai/openai.zig");
const tools = @import("src/tools/registry.zig");
const selection = @import("src/tools/selection.zig");
const tui = @import("src/ui/tui.zig");
const ss = @import("src/core/session_store.zig");
const sp = @import("src/core/system_prompt.zig");

fn getCwdAlloc(alloc: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const p = std.c.getcwd(&buf, buf.len) orelse return error.CwdTooLong;
    const end = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return alloc.dupe(u8, p[0..end]);
}

/// Split a comma-separated list into trimmed, non-empty substrings.
/// Substrings point into `s`; the returned outer slice is owned.
fn splitComma(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(alloc);
    errdefer list.deinit();
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) try list.append(trimmed);
    }
    return list.toOwnedSlice();
}

/// Build the sectioned system prompt (Phase D): tool snippets from the registry,
/// context files (AGENTS.md/CLAUDE.md) discovered in agent_dir + cwd ancestors,
/// plus optional append/override. Returns an owned slice.
fn buildSystemPromptFor(
    alloc: std.mem.Allocator,
    io: std.Io,
    registry: *tools.Registry,
    cwd_abs: []const u8,
    agent_dir: []const u8,
    append_system_prompt: ?[]const u8,
    system_prompt_override: ?[]const u8,
) ![]u8 {
    var snippets = std.array_list.Managed(sp.ToolSnippet).init(alloc);
    defer snippets.deinit();
    for (registry.tools.items) |t| {
        try snippets.append(.{ .name = t.name, .snippet = t.description });
    }
    const ctx_files = try sp.loadProjectContextFiles(alloc, io, cwd_abs, agent_dir);
    defer {
        for (ctx_files) |cf| {
            alloc.free(cf.path);
            alloc.free(cf.content);
        }
        alloc.free(ctx_files);
    }
    const opts = sp.Options{
        .cwd = cwd_abs,
        .tools = snippets.items,
        .append_system_prompt = append_system_prompt orelse "",
        .custom_prompt = system_prompt_override,
        .context_files = ctx_files,
    };
    return try sp.buildSystemPrompt(alloc, opts);
}

/// SIGINT/SIGTERM: request a graceful agent abort instead of dying.
fn handleSignal(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    agent.requestAbort();
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return; // Phase K: Win32 console handler
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    installSignalHandlers();

    var argv = std.array_list.Managed([]const u8).init(alloc);
    defer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit();
    }
    var arg_it = try init.minimal.args.iterateAllocator(alloc);
    while (arg_it.next()) |arg| {
        try argv.append(alloc.dupe(u8, arg) catch break);
    }

    // Parse args
    var print_mode = false;
    var prompt: ?[]const u8 = null;
    var model_name: ?[]const u8 = null;
    var cli_thinking: ?config.ThinkingLevel = null;
    var model_id: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var no_tui = false;
    var list_models = false;
    // Session persistence (B)
    var no_session = false;
    var continue_last = false;
    var resume_mode = false;
    var session_path: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var fork_from: ?[]const u8 = null; // path or id of session to fork
    var session_name: ?[]const u8 = null;
    var session_dir: ?[]const u8 = null;
    var list_sessions = false;
    // Tool selection (Phase E7)
    var tools_arg: ?[]const u8 = null;
    var exclude_tools_arg: ?[]const u8 = null;
    var no_tools = false;
    // System prompt (Phase D5)
    var append_system_prompt: ?[]const u8 = null;
    var system_prompt_override: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.items.len) : (i += 1) {
        const arg = argv.items[i];
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
            if (i + 1 < argv.items.len) prompt = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            if (i + 1 < argv.items.len) model_name = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            if (i + 1 < argv.items.len) {
                const lv = argv.items[i + 1];
                if (config.ThinkingLevel.fromStr(lv)) |tl| {
                    cli_thinking = tl;
                } else {
                    std.debug.print("warning: invalid thinking level \"{s}\" (valid: off, low, medium, high, xhigh, max)\n", .{lv});
                }
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--model-id")) {
            if (i + 1 < argv.items.len) model_id = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            if (i + 1 < argv.items.len) cwd = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-tui")) {
            no_tui = true;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            list_models = true;
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            no_session = true;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            continue_last = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            resume_mode = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (i + 1 < argv.items.len) session_path = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            if (i + 1 < argv.items.len) session_id = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fork")) {
            if (i + 1 < argv.items.len) fork_from = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 < argv.items.len) session_name = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            if (i + 1 < argv.items.len) session_dir = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--list-sessions")) {
            list_sessions = true;
        } else if (std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < argv.items.len) tools_arg = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt")) {
            if (i + 1 < argv.items.len) exclude_tools_arg = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            no_tools = true;
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            if (i + 1 < argv.items.len) append_system_prompt = argv.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            if (i + 1 < argv.items.len) system_prompt_override = argv.items[i + 1];
            i += 1;
        }
    }

    // Load config
    var cfg = try config.load(io, alloc, init.minimal.environ);
    defer cfg.deinit(alloc);

    if (list_models) {
        std.debug.print("models ({s}):\n", .{cfg.base_dir});
        for (cfg.models.items) |*m| {
            const default = cfg.findDefaultModel();
            const mark = if (default == m) " *" else "";
            const ci = m.cost_input orelse -1;
            const co = m.cost_output orelse -1;
            if (ci >= 0 and co >= 0) {
                std.debug.print("  {s}/{s}  {s}  ctx={d} maxTokens={d} ${d:.2}/${d:.2} per M{s}\n", .{ m.provider, m.id, m.name, m.context_window, m.max_tokens, ci, co, mark });
            } else {
                std.debug.print("  {s}/{s}  {s}  ctx={d} maxTokens={d}{s}\n", .{
                    m.provider, m.id, m.name, m.context_window, m.max_tokens, mark,
                });
            }
        }
        return;
    }

    // Select model: -m/--model-id > settings.json default > first
    var model: config.Config.Model = blk: {
        if (model_name) |name| {
            // pi resolveModelReference: exact reference first, then a
            // `:level` thinking suffix split (strict — an invalid suffix
            // keeps the text whole and fails). Explicit --thinking wins
            // over the suffix (pi main.js).
            if (cfg.findModel(name)) |m| {
                var mm = m.*;
                if (cli_thinking) |tl| mm.thinking_level = tl;
                break :blk mm;
            }
            if (config.splitThinkingSuffix(name)) |suffix| {
                if (cfg.findModel(suffix.base)) |m| {
                    var mm = m.*;
                    mm.thinking_level = cli_thinking orelse suffix.level;
                    break :blk mm;
                }
            }
            std.debug.print("error: unknown model '{s}' (use --list-models)\n", .{name});
            return error.UnknownModel;
        }
        if (model_id) |id| {
            if (cfg.findModel(id)) |m| {
                var mm = m.*;
                if (cli_thinking) |tl| mm.thinking_level = tl;
                break :blk mm;
            }
            std.debug.print("error: unknown model id '{s}' (use --list-models)\n", .{id});
            return error.UnknownModel;
        }
        if (cfg.findDefaultModel()) |m| {
            var mm = m.*;
            if (cli_thinking) |tl| mm.thinking_level = tl;
            break :blk mm;
        }
        var mm = cfg.models.items[0];
        if (cli_thinking) |tl| mm.thinking_level = tl;
        break :blk mm;
    };

    // Init provider
    var provider = try ai.OpenAiProvider.init(alloc, io, model.base_url, model.api_key);
    defer provider.deinit();

    // Init tools
    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try tools.registerAll(&registry);

    // ---- Tool selection (Phase E7) ----
    // Resolve --tools / --exclude-tools / --no-tools against the default set
    // (settings defaultTools if set, else the built-in default).
    var cli_tools_list: ?[]const []const u8 = null;
    var exclude_list: ?[]const []const u8 = null;
    if (tools_arg) |t| cli_tools_list = try splitComma(alloc, t);
    if (exclude_tools_arg) |e| exclude_list = try splitComma(alloc, e);
    defer if (cli_tools_list) |l| alloc.free(l);
    defer if (exclude_list) |l| alloc.free(l);

    // Validate --tools (plain vs modifier, no wildcards in modifiers).
    if (cli_tools_list) |list| {
        const tool_err = try selection.getToolListError(alloc, list);
        if (tool_err) |msg| {
            std.debug.print("error: --tools: {s}\n", .{msg});
            alloc.free(msg);
            return error.BadTools;
        }
    }

    // Base set: --no-tools -> empty; else defaultTools (resolved) or built-in.
    var base_owned: ?[]const []const u8 = null;
    const base: []const []const u8 = if (no_tools) blk: {
        break :blk &[_][]const u8{};
    } else if (cfg.default_tools) |dt| blk: {
        base_owned = try selection.resolveDefaultTools(alloc, dt);
        break :blk base_owned.?;
    } else blk: {
        break :blk &selection.DEFAULT_TOOL_NAMES;
    };
    defer if (base_owned) |b| alloc.free(b);

    const selected = try selection.select(alloc, base, cli_tools_list, exclude_list orelse &[_][]const u8{});
    defer alloc.free(selected);
    registry.filterToNames(selected);

    // Resolve cwd (needed for the system prompt + sessions)
    var cwd_alloc: ?[]u8 = null;
    const cwd_abs = blk: {
        if (cwd) |c| {
            break :blk c;
        }
        cwd_alloc = try getCwdAlloc(alloc);
        break :blk cwd_alloc.?;
    };

    // chdir so tools (read/bash/edit) resolve relative paths against --cwd.
    if (builtin.os.tag != .windows) {
        if (std.mem.indexOfScalar(u8, cwd_abs, 0) == null) {
            const cwd_z = alloc.alloc(u8, cwd_abs.len + 1) catch null;
            if (cwd_z) |z| {
                @memcpy(z[0..cwd_abs.len], cwd_abs);
                z[cwd_abs.len] = 0;
                _ = std.c.chdir(@ptrCast(z.ptr));
                alloc.free(z);
            }
        }
    }

    // Build the sectioned system prompt (Phase D)
    const system_prompt = try buildSystemPromptFor(alloc, io, &registry, cwd_abs, cfg.base_dir, append_system_prompt, system_prompt_override);

    // Create session
    const model_ptr = &model;
    var session = try agent.Session.init(alloc, io, model_ptr, &registry, &provider, system_prompt);
    defer session.deinit();
    alloc.free(system_prompt);
    session.compaction = cfg.compaction;

    // Session store (B)
    var sessions_dir_alloc: ?[]u8 = null;
    const sessions_dir = blk: {
        if (session_dir) |d| break :blk d;
        sessions_dir_alloc = try std.fmt.allocPrint(alloc, "{s}/sessions", .{cfg.base_dir});
        break :blk sessions_dir_alloc.?;
    };

    if (list_sessions) {
        const list = try ss.listForCwd(alloc, io, sessions_dir, cwd_abs);
        defer {
            for (list) |info| {
                alloc.free(info.path);
                alloc.free(info.id);
                if (info.name) |n| alloc.free(n);
                alloc.free(info.timestamp);
            }
            alloc.free(list);
        }
        std.debug.print("sessions for {s} ({d}):\n", .{ cwd_abs, list.len });
        for (list) |info| {
            const label = info.name orelse "(unnamed)";
            std.debug.print("  {s}  {d} msgs  {s}\n", .{ label, info.msg_count, info.path });
        }
        if (cwd_alloc) |c| alloc.free(c);
        if (sessions_dir_alloc) |d| alloc.free(d);
        return;
    }

    var store: ?*ss.Store = null;
    if (!no_session) {
        store = blk: {
            if (session_id) |sid| {
                const found = ss.findById(alloc, io, sessions_dir, sid);
                if (found) |f| {
                    const st = ss.Store.open(alloc, io, f) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{f});
                        alloc.free(f);
                        break :blk null;
                    };
                    alloc.free(f);
                    break :blk st;
                }
                std.debug.print("[session: no session matching id '{s}']\n", .{sid});
            }
            if (session_path) |sp_arg| {
                // pi: --session accepts a file path or a full/partial id
                var spath_owned = false;
                const spath = blk2: {
                    std.Io.Dir.cwd().access(io, sp_arg, .{}) catch {
                        const found = ss.findById(alloc, io, sessions_dir, sp_arg);
                        if (found) |f| {
                            spath_owned = true;
                            break :blk2 f;
                        }
                        std.debug.print("[session: cannot find '{s}'\n", .{sp_arg});
                        break :blk null;
                    };
                    break :blk2 sp_arg;
                };
                const st = ss.Store.open(alloc, io, spath) catch {
                    std.debug.print("[session: cannot open {s}]\n", .{spath});
                    if (spath_owned) alloc.free(spath);
                    break :blk null;
                };
                if (spath_owned) alloc.free(spath);
                break :blk st;
            }
            if (fork_from) |fref| {
                const fpath = fpblk: {
                    if (std.fs.path.isAbsolute(fref)) {
                        const fpath = fref;
                        break :fpblk fpath;
                    }
                    const found = ss.findById(alloc, io, sessions_dir, fref);
                    if (found) |f| break :fpblk f;
                    std.debug.print("[session: no session matching '{s}']\n", .{fref});
                    break :fpblk null;
                };
                if (fpath) |fp| {
                    const src = ss.Store.open(alloc, io, fp) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{fp});
                        break :blk null;
                    };
                    defer if (!std.mem.eql(u8, fp, fref)) alloc.free(fp);
                    const st = src.fork(sessions_dir, cwd_abs) catch {
                        std.debug.print("[session: fork failed]\n", .{});
                        src.deinit();
                        break :blk null;
                    };
                    src.deinit();
                    break :blk st;
                }
            }
            if (continue_last or resume_mode) {
                const list = ss.listForCwd(alloc, io, sessions_dir, cwd_abs) catch &.{};
                defer {
                    for (list) |info| {
                        alloc.free(info.path);
                        alloc.free(info.id);
                        if (info.name) |n| alloc.free(n);
                        alloc.free(info.timestamp);
                    }
                    alloc.free(list);
                }
                if (list.len > 0) {
                    const st = ss.Store.open(alloc, io, list[0].path) catch {
                        std.debug.print("[session: cannot open {s}]\n", .{list[0].path});
                        break :blk null;
                    };
                    std.debug.print("[session: {s} ({s})]\n", .{
                        if (st.name) |n| n else "unnamed", st.id,
                    });
                    break :blk st;
                }
                std.debug.print("[session: no previous session for {s}]\n", .{cwd_abs});
            }
            const st = ss.Store.create(alloc, io, sessions_dir, cwd_abs, .{
                .name = session_name,
            }) catch {
                std.debug.print("[session: create failed]\n", .{});
                break :blk null;
            };
            if (resume_mode) {
                // replayed context is empty; messages will follow
            }
            break :blk st;
        };
        if (store) |st| {
            session.store = st;
            // B3: replay the active branch into context
            const branch = st.branchMessages(alloc) catch &.{};
            defer {
                for (branch) |m| m.deinit();
                alloc.free(branch);
            }
            for (branch) |m| session.context.append(m) catch {};
            if (session_name) |n| st.recordSessionInfo(n);
        }
    }

    // Run
    if (print_mode) {
        if (prompt) |p| {
            // Text streams to stdout; tool activity/thinking go to stderr.
            session.runPrompt(p) catch |e| {
                if (e != error.Aborted) {
                    std.debug.print("\n[error: {s}]\n", .{@errorName(e)});
                }
            };
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(io, "\n") catch {};
            if (session.totals.total > 0) {
                std.debug.print("[usage: {d} in / {d} out / {d} cache-read tokens, ${d:.4} ]\n", .{
                    session.totals.input, session.totals.output, session.totals.cache_read, session.totals.cost,
                });
            }
        }
    } else {
        // TUI mode
        const home_dir = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse
            std.process.Environ.getPosix(init.minimal.environ, "USERPROFILE");
        var t = tui.TUI.init(io, alloc, &session, model.name, sessions_dir, cwd_abs, home_dir, &cfg, init.minimal.environ);
        defer t.deinit();
        // Persisted history → visible transcript (pi: renderInitialMessages
        // runs whenever the session has messages — continue/resume/--session).
        t.replaySession();
        t.run() catch |e| {
            std.debug.print("[TUI error: {s}]\n", .{@errorName(e)});
        };
    }

    if (store) |st| st.deinit();
    if (cwd_alloc) |c| alloc.free(c);
    if (sessions_dir_alloc) |d| alloc.free(d);
}
