const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sentry_mod = b.addModule("sentry-zig", .{
        .root_source_file = b.path("src/sentry.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = sentry_mod;

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/sentry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
