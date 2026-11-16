const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Ship builds stay ReleaseFast regardless of the standard option dance
    // (0.17's configurer rejects -Doptimize here); dev builds override via
    // -Doptimize=true semantics below.
    _ = optimize;
    const exe = b.addExecutable(.{
        .name = "zpi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
