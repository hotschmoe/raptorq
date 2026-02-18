// RFC 6330 Section 5.4 - PI solver (inactivation decoding) conformance tests
// Verifies that the five-phase solver correctly recovers intermediate symbols
// for identity, small, and full constraint matrix systems.

const std = @import("std");
const raptorq = @import("raptorq");
const SymbolBuffer = raptorq.symbol.SymbolBuffer;
const Octet = raptorq.octet.Octet;
const DenseBinaryMatrix = raptorq.dense_binary_matrix.DenseBinaryMatrix;
const SparseBinaryMatrix = raptorq.sparse_matrix.SparseBinaryMatrix;
const pi_solver = raptorq.pi_solver;
const cm = raptorq.constraint_matrix;
const sc = raptorq.systematic_constants;
const encoder = raptorq.encoder;
const octets = raptorq.octets;

test "PI solver with K'=18 constraint matrix" {
    const allocator = std.testing.allocator;

    const kp: u32 = 18;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 4;

    var matrices = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer matrices.deinit();

    var d = try SymbolBuffer.init(allocator, l, sym_size);
    defer d.deinit();

    for (0..kp) |i| {
        const row = d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    var source_copy: [18][4]u8 = undefined;
    for (0..kp) |i| @memcpy(&source_copy[i], d.getConst(@intCast(s + h + i)));

    try pi_solver.solve(DenseBinaryMatrix, allocator, &matrices, &d, kp);

    for (0..kp) |i| {
        const regenerated = try encoder.ltEncode(allocator, kp, &d, @intCast(i));
        defer allocator.free(regenerated);
        try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated);
    }
}

test "PI solver with known small system" {
    const allocator = std.testing.allocator;

    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 1;

    var matrices = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer matrices.deinit();

    var d = try SymbolBuffer.init(allocator, l, sym_size);
    defer d.deinit();

    for (0..kp) |i| {
        d.get(@intCast(s + h + i))[0] = @intCast((i + 1) % 256);
    }

    var source_copy: [10]u8 = undefined;
    for (0..kp) |i| source_copy[i] = d.getConst(@intCast(s + h + i))[0];

    try pi_solver.solve(DenseBinaryMatrix, allocator, &matrices, &d, kp);

    for (0..kp) |i| {
        const regenerated = try encoder.ltEncode(allocator, kp, &d, @intCast(i));
        defer allocator.free(regenerated);
        try std.testing.expectEqual(source_copy[i], regenerated[0]);
    }
}

test "PI solver repair symbol recovery" {
    const allocator = std.testing.allocator;

    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 4;

    var matrices = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer matrices.deinit();

    var d = try SymbolBuffer.init(allocator, l, sym_size);
    defer d.deinit();

    for (0..kp) |i| {
        const row = d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    var source_copy: [10][4]u8 = undefined;
    for (0..kp) |i| @memcpy(&source_copy[i], d.getConst(@intCast(s + h + i)));

    try pi_solver.solve(DenseBinaryMatrix, allocator, &matrices, &d, kp);

    for (0..kp) |i| {
        const regenerated = try encoder.ltEncode(allocator, kp, &d, @intCast(i));
        defer allocator.free(regenerated);
        try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated);
    }
}

test "PI solver underdetermined detection" {
    const allocator = std.testing.allocator;

    const kp: u32 = 10;

    var matrices = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer matrices.deinit();

    // Zero out column 0 in both matrices
    const hdpc_start = matrices.l - matrices.h;
    var row: u32 = 0;
    while (row < hdpc_start) : (row += 1) {
        matrices.binary.set(row, 0, false);
    }
    row = 0;
    while (row < matrices.h) : (row += 1) {
        matrices.hdpc.set(row, 0, Octet.ZERO);
    }

    var buf = try SymbolBuffer.init(allocator, matrices.l, 1);
    defer buf.deinit();

    const result = pi_solver.solve(DenseBinaryMatrix, allocator, &matrices, &buf, kp);
    try std.testing.expectError(error.SingularMatrix, result);
}

test "PI solver determinism" {
    const allocator = std.testing.allocator;

    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 4;

    var results: [2][27][4]u8 = undefined;

    for (0..2) |run| {
        var matrices = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
        defer matrices.deinit();

        var d = try SymbolBuffer.init(allocator, l, sym_size);
        defer d.deinit();

        for (0..kp) |i| {
            const row = d.get(@intCast(s + h + i));
            for (row, 0..) |*v, j| {
                v.* = @intCast((i * sym_size + j + 1) % 256);
            }
        }

        try pi_solver.solve(DenseBinaryMatrix, allocator, &matrices, &d, kp);

        for (0..l) |i| @memcpy(&results[run][i], d.getConst(@intCast(i)));
    }

    for (0..@as(usize, l)) |i| {
        try std.testing.expectEqualSlices(u8, &results[0][i], &results[1][i]);
    }
}

test "SparseBinaryMatrix solver matches DenseBinaryMatrix for K'=10" {
    const allocator = std.testing.allocator;

    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 4;

    // Solve with DenseBinaryMatrix
    var dense_cm = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer dense_cm.deinit();

    var dense_d = try SymbolBuffer.init(allocator, l, sym_size);
    defer dense_d.deinit();

    for (0..kp) |i| {
        const row = dense_d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    try pi_solver.solve(DenseBinaryMatrix, allocator, &dense_cm, &dense_d, kp);

    // Solve with SparseBinaryMatrix
    var sparse_cm = try cm.buildConstraintMatrices(SparseBinaryMatrix, allocator, kp);
    defer sparse_cm.deinit();

    var sparse_d = try SymbolBuffer.init(allocator, l, sym_size);
    defer sparse_d.deinit();

    for (0..kp) |i| {
        const row = sparse_d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    try pi_solver.solve(SparseBinaryMatrix, allocator, &sparse_cm, &sparse_d, kp);

    // Verify intermediate symbols match
    for (0..l) |i| {
        try std.testing.expectEqualSlices(u8, dense_d.getConst(@intCast(i)), sparse_d.getConst(@intCast(i)));
    }
}

test "SparseBinaryMatrix solver matches DenseBinaryMatrix for K'=18" {
    const allocator = std.testing.allocator;

    const kp: u32 = 18;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: u32 = kp + si.s + si.h;
    const sym_size: u32 = 4;

    var dense_cm = try cm.buildConstraintMatrices(DenseBinaryMatrix, allocator, kp);
    defer dense_cm.deinit();

    var dense_d = try SymbolBuffer.init(allocator, l, sym_size);
    defer dense_d.deinit();

    for (0..kp) |i| {
        const row = dense_d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    try pi_solver.solve(DenseBinaryMatrix, allocator, &dense_cm, &dense_d, kp);

    var sparse_cm = try cm.buildConstraintMatrices(SparseBinaryMatrix, allocator, kp);
    defer sparse_cm.deinit();

    var sparse_d = try SymbolBuffer.init(allocator, l, sym_size);
    defer sparse_d.deinit();

    for (0..kp) |i| {
        const row = sparse_d.get(@intCast(s + h + i));
        for (row, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    try pi_solver.solve(SparseBinaryMatrix, allocator, &sparse_cm, &sparse_d, kp);

    for (0..l) |i| {
        try std.testing.expectEqualSlices(u8, dense_d.getConst(@intCast(i)), sparse_d.getConst(@intCast(i)));
    }
}
