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

test "PI solver with identity system" {
    const allocator = std.testing.allocator;

    // A = I(4): solving Ix = b gives x = b
    var m = try OctetMatrix.identity(allocator, 4);
    defer m.deinit();

    var syms: [4]Symbol = undefined;
    for (&syms, 0..) |*s, idx| {
        s.* = try Symbol.init(allocator, 8);
        for (s.data, 0..) |*d, j| d.* = @intCast((idx * 8 + j) % 256);
    }
    defer for (&syms) |s| s.deinit();

    // Save expected values
    var expected: [4][8]u8 = undefined;
    for (&expected, 0..) |*e, idx| @memcpy(e, syms[idx].data);

    const result = try pi_solver.solve(allocator, &m, &syms, 4);
    defer allocator.free(result.ops.ops);

    for (0..4) |idx| {
        try std.testing.expectEqualSlices(u8, &expected[idx], syms[idx].data);
    }
}

test "PI solver with known small system" {
    const allocator = std.testing.allocator;

    // 4x4 upper triangular system:
    // [1 1 0 0]   [x0]   [a^b      ]
    // [0 1 1 0] * [x1] = [b^c      ]
    // [0 0 1 1]   [x2]   [c^d      ]
    // [0 0 0 1]   [x3]   [d        ]
    // Solution: x3=d, x2=c, x1=b, x0=a
    var m = try OctetMatrix.init(allocator, 4, 4);
    defer m.deinit();
    m.set(0, 0, Octet.ONE);
    m.set(0, 1, Octet.ONE);
    m.set(1, 1, Octet.ONE);
    m.set(1, 2, Octet.ONE);
    m.set(2, 2, Octet.ONE);
    m.set(2, 3, Octet.ONE);
    m.set(3, 3, Octet.ONE);

    const a: u8 = 10;
    const b: u8 = 20;
    const c: u8 = 30;
    const d: u8 = 40;

    var syms: [4]Symbol = undefined;
    for (&syms) |*s| s.* = try Symbol.init(allocator, 1);
    defer for (&syms) |s| s.deinit();

    syms[0].data[0] = a ^ b;
    syms[1].data[0] = b ^ c;
    syms[2].data[0] = c ^ d;
    syms[3].data[0] = d;

    const result = try pi_solver.solve(allocator, &m, &syms, 4);
    defer allocator.free(result.ops.ops);

    try std.testing.expectEqual(a, syms[0].data[0]);
    try std.testing.expectEqual(b, syms[1].data[0]);
    try std.testing.expectEqual(c, syms[2].data[0]);
    try std.testing.expectEqual(d, syms[3].data[0]);
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

    // Singular matrix: all-zero row makes system unsolvable
    var m = try OctetMatrix.init(allocator, 3, 3);
    defer m.deinit();
    m.set(0, 0, Octet.ONE);
    m.set(0, 1, Octet.init(2));
    m.set(1, 0, Octet.init(3));
    m.set(1, 1, Octet.init(4));
    // Row 2 is all zeros -> singular

    var syms: [3]Symbol = undefined;
    for (&syms) |*s| s.* = try Symbol.init(allocator, 1);
    defer for (&syms) |s| s.deinit();

    const result = pi_solver.solve(allocator, &m, &syms, 3);
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
