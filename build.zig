const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const unit = b.addTest(.{ .root_module = root });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run all test suites");
    test_step.dependOn(&run_unit.step);
    inline for (.{"bdd", "integration", "security", "load_stress"}) |name| {
        const module = b.createModule(.{ .root_source_file = b.path("tests/" ++ name ++ ".zig"), .target = target, .optimize = optimize });
        const artifact = b.addTest(.{ .root_module = module });
        const run = b.addRunArtifact(artifact);
        test_step.dependOn(&run.step);
    }
}
