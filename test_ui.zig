test "REPRO: scroll up shows garbage in Jump to latest message area" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alloc = std.heap.page_allocator;
    var model: config.Config.Model = .{
        .provider = try alloc.dupe(u8, "test"),
        .id = try alloc.dupe(u8, "test-id"),
        .name = try alloc.dupe(u8, "test-model"),
        .base_url = try alloc.dupe(u8, "http://localhost:8080/v1"),
        .api_key = try alloc.dupe(u8, ""),
        .api = try alloc.dupe(u8, "openai-completions"),
    };
    const provider = try aiprovider.buildFromModel(alloc, io, &model);
    var registry = tools.Registry.init(alloc);
    try tools.registerAll(&registry);
    var session = try agent.Session.init(alloc, io, &model, &registry, provider, "test");
    var t = tui.TUI.init(io, alloc, &session, "test-model", "/tmp/sessions", "/tmp", null, null, .empty, null, null);
    defer t.deinit();
    t.width = 80;
    t.height = 24;
    
    // Add some long content to scroll through
    t.addMessage("This is a long message that will fill multiple lines and allow scrolling up and down. " ++ 
                "The content includes various characters and should be properly rendered. " ++
                "We need to test the scrolling behavior and see if any garbage appears in the Jump to latest message area. " ++
                "This is line 1 of the test content. " ++
                "This is line 2 of the test content. " ++
                "This is line 3 of the test content. " ++
                "This is line 4 of the test content. " ++
                "This is line 5 of the test content. " ++
                "This is line 6 of the test content. " ++
                "This is line 7 of the test content. " ++
                "This is line 8 of the test content. " ++
                "This is line 9 of the test content. " ++
                "This is line 10 of the test content. " ++
                "This is line 11 of the test content. " ++
                "This is line 12 of the test content. " ++
                "This is line 13 of the test content. " ++
                "This is line 14 of the test content. " ++
                "This is line 15 of the test content. " ++
                "This is line 16 of the test content. " ++
                "This is line 17 of the test content. " ++
                "This is line 18 of the test content. " ++
                "This is line 19 of the test content. " ++
                "This is line 20 of the test content. ");
    
    // Initial render
    t.redraw();
    
    // Scroll up a few times
    for (0..5) |_| {
const _ = t.sv.scrollTo(-1, .{}, ss.nowMs(io));
        t.redraw();
        
        // Check for garbage in the Jump to latest message area
        const transcript_h = t.transcript_h;
        if (transcript_h > 0) {
            const last_row = t.prev_lines.items[transcript_h - 1];
            // Look for any unusual characters in the Jump to latest message area
            const jump_area = last_row[0..@min(last_row.len, 30)];
            for (jump_area) |c| {
                if (c < 32 and c != 10 and c != 13 and c != 9) {
                    std.debug.print("Found garbage character {d} in Jump to latest message area: {s}\\n", .{ c, jump_area });
                    return error.GarbageFound;
                }
            }
        }
    }
}
