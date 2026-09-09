const std = @import("std");

// fnmatch-ng M1 build: static C-ABI library exporting fnmatch_ng().
// See src/matcher.zig for the matcher. Requires Zig 0.14.1 (toolchain
// pinned in docs/language-choice.md).

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/matcher.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "fnmatch_ng",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
