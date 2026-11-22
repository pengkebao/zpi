const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Ship builds stay ReleaseFast regardless of the standard option dance
    // (0.17's configurer rejects -Doptimize here); dev builds override via
    // -Doptimize=true semantics below.
    _ = optimize;
    // std.c (ioctl/poll/termios) needs libc on POSIX; the Windows console
    // API is linked automatically (kernel32) and has no libc.
    const is_windows = target.result.os.tag == .windows;
    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        // std.c (ioctl/poll/termios) needs libc on POSIX; the Windows
        // console API has no libc.
        .link_libc = !is_windows,
    });
    if (is_windows) {
        // Console API import library (kernel32). Zig auto-adds libs for
        // `extern "kernel32"`, but the screen-buffer / VT-processing functions
        // are pulled in late, so link kernel32 explicitly for the cross target.
        root.linkSystemLibrary("kernel32", .{});
    }
    const exe = b.addExecutable(.{
        .name = "zpi",
        .root_module = root,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
