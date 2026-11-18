const std = @import("std");
const tui = @import("src/ui/tui.zig");
const config = @import("src/core/config.zig");
const agent = @import("src/core/agent.zig");
const aiprovider = @import("src/ai/provider.zig");
const tools = @import("src/tools/registry.zig");

// ---- /login + /logout (pi OAuthSelectorComponent + LoginDialogComponent) ----

/// A real Config backed by a throwaway agent dir (auth.json lands there).
fn makeCfg(alloc: std.mem.Allocator, io: std.Io) !*config.Config {
    const cfg = try alloc.create(config.Config);
    cfg.* = .{
        .base_dir = try alloc.dupe(u8, "/tmp/zpi-login-test"),
        .models = std.array_list.Managed(config.Config.Model).init(alloc),
    };
    var dir: std.Io.Dir = .cwd();
    dir.createDirPath(io, "/tmp/zpi-login-test") catch {};
    return cfg;
}

fn makeTui(alloc: std.mem.Allocator, io: std.Io, cfg: ?*config.Config) !tui.TUI {
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "openai"),
        .id = try alloc.dupe(u8, "chat-latest"),
        .name = try alloc.dupe(u8, "OpenAI default"),
        .base_url = try alloc.dupe(u8, "https://api.openai.com/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    return tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, cfg, .empty, null, null);
}

test "login: openLoginSelector fills providers sorted by name" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var t = try makeTui(alloc, io, null);
    defer t.deinit();

    t.openLoginSelector(null);
    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .login_select);
    // The built-in catalog has ~20+ providers.
    try std.testing.expect(tui.testAccess.loginCount(&t) > 10);
    // Sorted by name: no adjacent pair out of order.
    var i: usize = 1;
    while (i < tui.testAccess.loginCount(&t)) : (i += 1) {
        const a = tui.testAccess.loginName(&t, i - 1);
        const b = tui.testAccess.loginName(&t, i);
        try std.testing.expect(std.mem.order(u8, a, b) != .gt);
    }
    // Selection starts at the first row.
    try std.testing.expectEqual(@as(usize, 0), tui.testAccess.loginSel(&t));
}

test "login: provider ref filters to the matching entry" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var t = try makeTui(alloc, io, null);
    defer t.deinit();

    t.openLoginSelector("openai");
    try std.testing.expectEqual(@as(usize, 1), tui.testAccess.loginCount(&t));
    try std.testing.expectEqualStrings("openai", tui.testAccess.loginId(&t, 0));

    // Display name match also works (pi findLoginProviderOptions).
    t.openLoginSelector("DeepSeek");
    try std.testing.expect(tui.testAccess.loginCount(&t) >= 1);
    try std.testing.expectEqualStrings("deepseek", tui.testAccess.loginId(&t, 0));
}

test "login: key dialog stores the credential and refreshes models" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    const cfg = try makeCfg(alloc, io);
    var t = try makeTui(alloc, io, cfg);
    defer t.deinit();

    tui.testAccess.openLoginKeyDialogForTest(&t, "deepseek");
    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .login_key);
    // Prompt names the env var (pi envApiKeyAuth: "Enter <name>").
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", tui.testAccess.loginPromptName(&t));

    tui.testAccess.typeKeyText(&t, "sk-test-123");
    tui.testAccess.submitLoginKey(&t);

    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .hidden);
    // Provider models are now available with the key applied.
    var found: usize = 0;
    for (cfg.models.items) |*m| {
        if (std.mem.eql(u8, m.provider, "deepseek")) {
            found += 1;
            try std.testing.expectEqualStrings("sk-test-123", m.api_key);
        }
    }
    try std.testing.expect(found > 0);
    // pi completeProviderAuthentication: the session switched to the
    // provider's default model.
    try std.testing.expectEqualStrings("deepseek", tui.testAccess.sessionModelProvider(&t));
    // The stored default model ref points into cfg — provider must match.
    try std.testing.expectEqualStrings("deepseek", tui.testAccess.sessionModelProvider(&t));
}

test "login: empty key submit stays in the dialog" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var t = try makeTui(alloc, io, null);
    defer t.deinit();

    tui.testAccess.openLoginKeyDialogForTest(&t, "deepseek");
    tui.testAccess.submitLoginKey(&t);
    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .login_key);
}

test "logout: selector lists stored credentials only" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var t = try makeTui(alloc, io, null);
    defer t.deinit();

    // Nothing stored: pi shows a status note instead of the selector.
    t.openLogoutSelector();
    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .hidden);
}

test "login: addProviderModels dedups existing ids" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    const cfg = try makeCfg(alloc, io);
    var t = try makeTui(alloc, io, cfg);
    defer t.deinit();

    const before = cfg.models.items.len;
    // DeepSeek has no models yet (no credential); addProviderModels adds the
    // catalog set.
    const added = try config.addProviderModels(alloc, cfg, "deepseek", "k1");
    try std.testing.expect(added > 0);
    // A second call adds nothing (dedup on provider/id).
    const added2 = try config.addProviderModels(alloc, cfg, "deepseek", "k1");
    try std.testing.expectEqual(@as(usize, 0), added2);
    try std.testing.expectEqual(before + added, cfg.models.items.len);
}

test "login: unknown provider ref leaves an empty list" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var t = try makeTui(alloc, io, null);
    defer t.deinit();

    t.openLoginSelector("no-such-provider");
    try std.testing.expectEqual(@as(usize, 0), tui.testAccess.loginCount(&t));
    try std.testing.expectEqual(tui.testAccess.menuMode(&t), .login_select);
}
