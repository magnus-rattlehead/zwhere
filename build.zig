const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const search = b.addModule("search", .{
        .root_source_file = b.path("src/search/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zwhere",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zwhere.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("search", search);

    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run zwhere");
    run_step.dependOn(&run_exe.step);
}
