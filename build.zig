const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.link_libc = true;
    const unit = b.addTest(.{ .root_module = lib_module });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run all test suites and compile the server executable");
    const server_module = b.createModule(.{
        .root_source_file = b.path("examples/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ubiq", .module = lib_module }},
    });
    server_module.link_libc = true;
    const server_exe = b.addExecutable(.{ .name = "ubiq-server", .root_module = server_module });
    test_step.dependOn(&server_exe.step);
    test_step.dependOn(&run_unit.step);
    inline for (.{"bdd", "integration", "security", "load_stress"}) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path("tests/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ubiq", .module = lib_module }},
        });
        module.link_libc = true;
        const artifact = b.addTest(.{ .root_module = module });
        const run = b.addRunArtifact(artifact);
        test_step.dependOn(&run.step);
    }
}
