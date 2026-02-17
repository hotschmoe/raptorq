// RFC 6330 Section 5.4 - PI solver (inactivation decoding) conformance tests
// Verifies that the five-phase solver correctly recovers intermediate symbols
// for identity, small, and full constraint matrix systems.

const std = @import("std");
const raptorq = @import("raptorq");
const OctetMatrix = raptorq.octet_matrix.OctetMatrix;
const Symbol = raptorq.symbol.Symbol;
const Octet = raptorq.octet.Octet;
const pi_solver = raptorq.pi_solver;
const cm = raptorq.constraint_matrix;
const sc = raptorq.systematic_constants;

test "PI solver with K'=18 constraint matrix" {
    const allocator = std.testing.allocator;

    // K'=18 is the smallest value where the old solver failed (SingularMatrix).
    // Verifies inactivation decoding works beyond trivial sizes.
    const kp: u32 = 18;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: usize = @intCast(kp + si.s + si.h);
    const sym_size: usize = 4;

    var a = try cm.buildConstraintMatrix(allocator, kp);
    defer a.deinit();

    const d = try allocator.alloc(Symbol, l);
    var d_init: usize = 0;
    defer {
        for (d[0..d_init]) |sym| sym.deinit();
        allocator.free(d);
    }

    for (0..s + h) |i| {
        d[i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
    }
    for (0..kp) |i| {
        d[s + h + i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
        for (d[s + h + i].data, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    var source_copy: [18][4]u8 = undefined;
    for (0..kp) |i| @memcpy(&source_copy[i], d[s + h + i].data);

    const result = try pi_solver.solve(allocator, &a, d, kp);
    defer allocator.free(result.ops.ops);

    // Verify: LT encoding of intermediate symbols regenerates source
    for (0..kp) |i| {
        var regenerated = try raptorq.encoder.ltEncode(allocator, kp, d, @intCast(i));
        defer regenerated.deinit();
        try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated.data);
    }
}

test "PI solver with known small system" {
    const allocator = std.testing.allocator;

    // Use real constraint matrix for K'=10, solve, then verify
    // intermediate symbols can regenerate source data via LT encoding.
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: usize = @intCast(kp + si.s + si.h);
    const sym_size: usize = 1;

    var a = try cm.buildConstraintMatrix(allocator, kp);
    defer a.deinit();

    const d = try allocator.alloc(Symbol, l);
    var d_init: usize = 0;
    defer {
        for (d[0..d_init]) |sym| sym.deinit();
        allocator.free(d);
    }

    for (0..s + h) |i| {
        d[i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
    }
    for (0..kp) |i| {
        d[s + h + i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
        d[s + h + i].data[0] = @intCast((i + 1) % 256);
    }

    var source_copy: [10]u8 = undefined;
    for (0..kp) |i| source_copy[i] = d[s + h + i].data[0];

    const result = try pi_solver.solve(allocator, &a, d, kp);
    defer allocator.free(result.ops.ops);

    // Verify: LT encoding of intermediate symbols regenerates source
    for (0..kp) |i| {
        var regenerated = try raptorq.encoder.ltEncode(allocator, kp, d, @intCast(i));
        defer regenerated.deinit();
        try std.testing.expectEqual(source_copy[i], regenerated.data[0]);
    }
}

test "PI solver repair symbol recovery" {
    const allocator = std.testing.allocator;

    // Full RFC pipeline: build constraint matrix, solve, verify intermediate symbols
    // can regenerate source data via LT encoding.
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: usize = @intCast(kp + si.s + si.h);
    const sym_size: usize = 4;

    // Build encoding constraint matrix
    var a = try cm.buildConstraintMatrix(allocator, kp);
    defer a.deinit();

    // D vector: S+H zeros, then K' source symbols
    const d = try allocator.alloc(Symbol, l);
    var d_init: usize = 0;
    defer {
        for (d[0..d_init]) |sym| sym.deinit();
        allocator.free(d);
    }

    for (0..s + h) |i| {
        d[i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
    }
    for (0..kp) |i| {
        d[s + h + i] = try Symbol.init(allocator, sym_size);
        d_init += 1;
        for (d[s + h + i].data, 0..) |*v, j| {
            v.* = @intCast((i * sym_size + j + 1) % 256);
        }
    }

    // Save source symbols for verification
    var source_copy: [10][4]u8 = undefined;
    for (0..kp) |i| @memcpy(&source_copy[i], d[s + h + i].data);

    // Solve
    const result = try pi_solver.solve(allocator, &a, d, kp);
    defer allocator.free(result.ops.ops);

    // Regenerate source symbols 0..K'-1 via LT encoding from intermediate symbols
    for (0..kp) |i| {
        var regenerated = try raptorq.encoder.ltEncode(allocator, kp, d, @intCast(i));
        defer regenerated.deinit();
        try std.testing.expectEqualSlices(u8, &source_copy[i], regenerated.data);
    }
}

test "PI solver underdetermined detection" {
    const allocator = std.testing.allocator;

    // Use K'=10 constraint matrix with a zeroed column to make it singular
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const l: u32 = kp + si.s + si.h;

    var m = try cm.buildConstraintMatrix(allocator, kp);
    defer m.deinit();

    // Zero out column 0 to make the system singular
    var row: u32 = 0;
    while (row < l) : (row += 1) {
        m.set(row, 0, Octet.ZERO);
    }

    const syms = try allocator.alloc(Symbol, l);
    var init_count: usize = 0;
    defer {
        for (syms[0..init_count]) |s| s.deinit();
        allocator.free(syms);
    }
    for (syms) |*s| {
        s.* = try Symbol.init(allocator, 1);
        init_count += 1;
    }

    const result = pi_solver.solve(allocator, &m, syms, kp);
    try std.testing.expectError(error.SingularMatrix, result);
}

test "PI solver determinism" {
    const allocator = std.testing.allocator;

    // Same constraint matrix + symbol data must yield same intermediate symbols
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s: usize = @intCast(si.s);
    const h: usize = @intCast(si.h);
    const l: usize = @intCast(kp + si.s + si.h);
    const sym_size: usize = 4;

    var results: [2][27][4]u8 = undefined;

    for (0..2) |run| {
        var a = try cm.buildConstraintMatrix(allocator, kp);
        defer a.deinit();

        const d = try allocator.alloc(Symbol, l);
        var d_init: usize = 0;
        defer {
            for (d[0..d_init]) |sym| sym.deinit();
            allocator.free(d);
        }

        for (0..s + h) |i| {
            d[i] = try Symbol.init(allocator, sym_size);
            d_init += 1;
        }
        for (0..kp) |i| {
            d[s + h + i] = try Symbol.init(allocator, sym_size);
            d_init += 1;
            for (d[s + h + i].data, 0..) |*v, j| {
                v.* = @intCast((i * sym_size + j + 1) % 256);
            }
        }

        const result = try pi_solver.solve(allocator, &a, d, kp);
        defer allocator.free(result.ops.ops);

        for (0..l) |i| @memcpy(&results[run][i], d[i].data);
    }

    // Both runs must produce identical intermediate symbols
    for (0..@as(usize, @intCast(l))) |i| {
        try std.testing.expectEqualSlices(u8, &results[0][i], &results[1][i]);
    }
}
