//! Micro-benchmark: markdown.render cost per small chunk/block sizes.
const std = @import("std");
const markdown = @import("src/ui/markdown.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const cases = .{
        .{ "tiny paragraph", "这是**流式**第 x 段中文内容，带 `code` 与表格：" },
        .{ "small table", "| a | b |\n|---|---|\n| 1 | ✅ |" },
        .{ "paragraph + table", "这是**流式**第 x 段中文内容，带 `code` 与表格：\n\n| a | b |\n|---|---|\n| 1 | ✅ |" },
        .{ "code fence", "```zig\nconst x = 1;\nconst y = x + 42;\n```" },
        .{ "wide CJK paragraph", "中文内容段落，包含全角标点、英文单词和 emoji ✅⚠️🎉 的混合文本，用于测试宽度计算路径的成本。" },
    };
    inline for (cases) |c| {
        const text = c[1];
        // warmup
        {
            const lines = try markdown.render(alloc, text, 108);
            markdown.freeLines(alloc, lines);
        }
        var sum: u64 = 0;
        const reps = 2000;
        for (0..reps) |_| {
            const t0 = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
            const lines = try markdown.render(alloc, text, 108);
            const t1 = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
            sum += @intCast(t1 - t0);
            markdown.freeLines(alloc, lines);
        }
        std.debug.print("{s:>22}: avg {d:>8.3} ms/render ({d} reps)\n", .{
            c[0], @as(f64, @floatFromInt(sum)) / reps / std.time.ns_per_ms, reps,
        });
    }
}
