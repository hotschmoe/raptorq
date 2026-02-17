const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("raptorq", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests (from library module)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Conformance tests
    const conformance_step = b.step("test-conformance", "Run conformance tests");
    const conformance_files = [_][]const u8{
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
    };
    for (conformance_files) |test_file| {
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
        const run_t = b.addRunArtifact(t);
        conformance_step.dependOn(&run_t.step);
    }

    // Fuzz tests
    const fuzz_step = b.step("test-fuzz", "Run fuzz tests");
    const fuzz_files = [_][]const u8{"test/fuzz/test_fuzz.zig"};
    for (fuzz_files) |test_file| {
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
        fuzz_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Interop tests (Rust-generated vectors)
    const interop_step = b.step("test-interop", "Run interop tests against Rust-generated vectors");
    const interop_files = [_][]const u8{"test/interop/test_interop.zig"};
    for (interop_files) |test_file| {
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
        interop_step.dependOn(&b.addRunArtifact(t).step);
    }
}
