const std = @import("std");

// fnmatch-ng M1 build: static C-ABI library exporting fnmatch_ng().
// See src/matcher.zig for the matcher. Requires Zig 0.14.1 (toolchain
// pinned in docs/language-choice.md).

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Release library: leaf matcher, no threads, no unwinding. Stripped:
    // debug sections were ~60% of the archive and leaked host paths.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/matcher.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .single_threaded = true,
        .omit_frame_pointer = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "fnmatch_ng",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Unit tests run on their own unstripped module, pinned ReleaseSafe so
    // optimized-codegen paths (tail anchor, byte guards) are exercised.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/matcher.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const lib_unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Trap fuzzer: ReleaseSafe so the runtime aborts on any overstep.
    // Runs the documented seed; loop more seeds explicitly for soak runs.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/memfuzz.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "matcher", .module = test_mod }},
    });
    const fuzz_exe = b.addExecutable(.{ .name = "memfuzz", .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addArgs(&.{ "0x5eed", "20000" });

    const fuzz_step = b.step("fuzz", "Run trap fuzzer (documented seed, 20k smoke)");
    fuzz_step.dependOn(&run_fuzz.step);
}
