const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("raptorq", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example executable
    const example_exe = b.addExecutable(.{
        .name = "encode_decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/encode_decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raptorq", .module = mod },
            },
        }),
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example", "Build and run the encode/decode example");
    example_step.dependOn(&run_example.step);

    // Benchmark executable (forced ReleaseFast)
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "raptorq", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Build and run benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Profiler executable (forced ReleaseFast)
    const profile_exe = b.addExecutable(.{
        .name = "profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/profile.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "raptorq", .module = mod },
            },
        }),
    });
    b.installArtifact(profile_exe);
    const run_profile = b.addRunArtifact(profile_exe);
    const profile_step = b.step("profile", "Build and run solver profiler (ReleaseFast)");
    profile_step.dependOn(&run_profile.step);

    // Unit tests (from library module)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Conformance tests
    addTestFiles(b, mod, target, optimize, b.step("test-conformance", "Run conformance tests"), &.{
        "test/conformance/test_octet.zig",
        "test/conformance/test_rng.zig",
        "test/conformance/test_systematic_constants.zig",
        "test/conformance/test_symbol.zig",
        "test/conformance/test_matrix.zig",
        "test/conformance/test_constraint_matrix.zig",
        "test/conformance/test_pi_solver.zig",
        "test/conformance/test_base.zig",
        "test/conformance/test_encoder.zig",
        "test/conformance/test_decoder.zig",
        "test/conformance/test_roundtrip.zig",
        "test/conformance/test_edge_cases.zig",
    });

    // Fuzz tests
    addTestFiles(b, mod, target, optimize, b.step("test-fuzz", "Run fuzz tests"), &.{
        "test/fuzz/test_fuzz.zig",
    });

    // Interop tests (Rust-generated vectors)
    addTestFiles(b, mod, target, optimize, b.step("test-interop", "Run interop tests against Rust-generated vectors"), &.{
        "test/interop/test_interop.zig",
    });
}

fn addTestFiles(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step: *std.Build.Step,
    test_files: []const []const u8,
) void {
    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "raptorq", .module = mod },
                },
            }),
        });
        step.dependOn(&b.addRunArtifact(t).step);
    }
}
